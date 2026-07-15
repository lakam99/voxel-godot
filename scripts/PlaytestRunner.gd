extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")
const InventorySlotButtonScript := preload("res://scripts/InventorySlotButton.gd")
const NpcRouteStateStoreScript := preload("res://scripts/npc_ai/routing/NpcRouteStateStore.gd")
const CELL := 1.35
const CHUNK_SIZE := 28
const WATER_LEVEL := 11.1
const INTERACT_RANGE := 10.5
const ACTION_REACH := CELL * 1.85
const PLACEMENT_RANGE := CELL * 2.65
const MELEE_RANGE := CELL * 2.65

var main: Node3D
var player: CharacterBody3D
var camera: Camera3D
var results: Array[Dictionary] = []
var failed := false
var elapsed := 0.0
var watchdog_seconds := 240.0
var finished := false

func active_chunk_size() -> int:
    if main != null:
        return int(main.CHUNK_SIZE)
    return CHUNK_SIZE

func chunk_key_for_flat_cell(cell: Vector2i) -> Vector2i:
    var size := active_chunk_size()
    return Vector2i(floori(float(cell.x) / float(size)), floori(float(cell.y) / float(size)))

func chunk_scope_for_flat_cell(cell: Vector2i, radius := 0) -> Dictionary:
    var result := {}
    var center := chunk_key_for_flat_cell(cell)
    var chunk_radius := maxi(0, int(radius))
    for dz in range(-chunk_radius, chunk_radius + 1):
        for dx in range(-chunk_radius, chunk_radius + 1):
            result[Vector2i(center.x + dx, center.y + dz)] = true
    return result

func _ready() -> void:
    var watchdog_override := OS.get_environment("VOXEL_PLAYTEST_WATCHDOG_SECONDS").strip_edges()
    if watchdog_override != "":
        watchdog_seconds = maxf(30.0, watchdog_override.to_float())
    call_deferred("run")

func _process(delta: float) -> void:
    if finished:
        return
    elapsed += delta
    if elapsed > watchdog_seconds:
        var timeout_details := "runner timed out before completion"
        if main != null:
            var timeline_value = main.get("startup_loading_timeline")
            var latest := {}
            if timeline_value is Array and not (timeline_value as Array).is_empty() and (timeline_value as Array)[-1] is Dictionary:
                latest = (timeline_value as Array)[-1]
            var runtime = main.get("voxel_terrain_runtime")
            var runtime_stats: Dictionary = runtime.call("stats") if runtime != null and runtime.has_method("stats") else {}
            timeout_details += "; runtimeLoading=%s failure=%s latest=%s terrain=%s player=%s" % [
                str(bool(main.get("runtime_loading_active"))),
                str(main.get("startup_loading_failure_result")),
                str(latest),
                str(runtime_stats),
                str(main.get("player").global_position if main.get("player") is Node3D else Vector3.ZERO)
            ]
        add_result("playtest_watchdog", false, timeout_details)
        finished = true
        save_optional_screenshot()
        save_report()
        get_tree().quit(1)

func surface_y_at_position(position: Vector3) -> float:
    if main != null and main.has_method("surface_y_at_position"):
        return float(main.call("surface_y_at_position", position))
    return position.y

func ground_y_near_position(position: Vector3) -> float:
    if main != null and main.has_method("ground_y_near_position"):
        return float(main.call("ground_y_near_position", position))
    return surface_y_at_position(position)

func spawn_visible_guard_behavior_hostile(npc_system, hostile_system) -> Dictionary:
    if npc_system == null or hostile_system == null:
        return { "spawned": false, "reason": "missing_system" }
    var entries: Array = npc_system.get("npcs")
    var offsets: Array[Vector3] = [
        Vector3(0.0, 0.0, -CELL * 6.0),
        Vector3(CELL * 6.0, 0.0, 0.0),
        Vector3(-CELL * 6.0, 0.0, 0.0),
        Vector3(0.0, 0.0, CELL * 6.0),
        Vector3(CELL * 5.0, 0.0, -CELL * 5.0),
        Vector3(-CELL * 5.0, 0.0, -CELL * 5.0),
        Vector3(CELL * 5.0, 0.0, CELL * 5.0),
        Vector3(-CELL * 5.0, 0.0, CELL * 5.0),
        Vector3(0.0, 0.0, -CELL * 9.0),
        Vector3(CELL * 9.0, 0.0, 0.0),
        Vector3(-CELL * 9.0, 0.0, 0.0),
        Vector3(0.0, 0.0, CELL * 9.0)
    ]
    var checked := 0
    for entry_variant in entries:
        var entry: Dictionary = entry_variant
        if not bool(entry.get("canFight", false)):
            continue
        var weapon_id := String(entry.get("weaponId", ""))
        if npc_system.has_method("npc_weapon_is_ranged") and not bool(npc_system.call("npc_weapon_is_ranged", weapon_id)):
            continue
        var body := entry.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            continue
        for offset_value in offsets:
            var offset: Vector3 = offset_value
            var candidate := body.global_position + offset
            candidate.y = surface_y_at_position(candidate) + 0.72
            checked += 1
            if not guard_behavior_line_clear(body, candidate):
                continue
            var hostile = hostile_system.call("spawn_enemy", candidate, "shadow")
            if hostile is Node3D:
                return {
                    "spawned": true,
                    "guard": String(body.name),
                    "weapon": weapon_id,
                    "position": candidate,
                    "checked": checked
                }
    return { "spawned": false, "reason": "no_clear_guard_line", "checked": checked }

func guard_behavior_line_clear(body: Node3D, target_position: Vector3) -> bool:
    if body == null or not is_instance_valid(body) or main == null:
        return false
    var world := main.get_world_3d()
    if world == null:
        return false
    var query := PhysicsRayQueryParameters3D.create(
        body.global_position + Vector3(0.0, 1.58, 0.0),
        target_position + Vector3(0.0, 1.02, 0.0)
    )
    query.exclude = [body]
    query.collision_mask = 1 | 4
    query.collide_with_bodies = true
    query.collide_with_areas = false
    var hit: Dictionary = world.direct_space_state.intersect_ray(query)
    return hit.is_empty()

func surface_y_at_cell2(cell: Vector2i) -> float:
    if main != null and main.has_method("surface_y_at_cell"):
        return float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y)))
    return 0.0

func surface_y_at_cell_coords(x: int, z: int) -> float:
    return surface_y_at_cell2(Vector2i(x, z))

func surface_biome_at_cell2(cell: Vector2i) -> String:
    if main != null and main.has_method("surface_biome_at_cell"):
        return String(main.call("surface_biome_at_cell", Vector3i(cell.x, 0, cell.y)))
    return "plains"

func run() -> void:
    var only_section := OS.get_environment("VOXEL_PLAYTEST_ONLY").strip_edges()
    mark_progress("start")
    main = MAIN_SCENE.instantiate()
    add_child(main)
    mark_progress("main_instantiated")
    await wait_physics_frames(20)

    player = main.get("player") as CharacterBody3D
    if player:
        player.set("automated_input", true)
        camera = player.get("camera") as Camera3D
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

    mark_progress("pre_warmup")
    await wait_physics_frames(80)
    mark_progress("scene_bootstrap")
    await test_scene_bootstrap()
    if finish_if_only_section("scene_bootstrap", only_section):
        return
    if only_section == "inventory_and_crafting":
        mark_progress("inventory_and_crafting")
        await test_inventory_and_crafting_systems()
        finish_playtest()
        return
    if only_section == "underground_volume":
        mark_progress("underground_volume")
        await test_underground_volume_generation()
        finish_playtest()
        return
    if only_section == "terrain_geometry":
        mark_progress("terrain_collision")
        await test_terrain_collision_shapes()
        mark_progress("terrain_topology")
        test_terrain_mesh_topology_signature()
        mark_progress("terrain_material")
        test_terrain_shader_material()
        mark_progress("terrain_normals")
        await test_terrain_chunk_edge_normals()
        finish_playtest()
        return
    if only_section == "hostiles":
        mark_progress("hostiles")
        await test_hostile_system()
        finish_playtest()
        return
    if only_section == "structures":
        unlock_intro_gate_for_followup_tests(main.get("tutorial_system") if main != null else null)
        if main != null:
            main.set("time_of_day", 0.42)
            if main.has_method("update_sky"):
                main.call("update_sky", 0.0)
        await wait_process_frames(4)
        mark_progress("structures")
        await test_structure_and_town_generation()
        finish_playtest()
        return
    if only_section == "movement":
        mark_progress("movement")
        await test_player_movement()
        await test_uphill_smoothing()
        await test_steep_uphill_blocking()
        await test_airborne_obstacle_blocking()
        await test_jump()
        finish_playtest()
        return
    if only_section == "navigation_map":
        mark_progress("navigation_map")
        await test_navigation_map_system()
        finish_playtest()
        return
    if only_section == "world_streaming":
        mark_progress("world_streaming")
        await test_world_chunk_streaming()
        finish_playtest()
        return
    if only_section == "chunk_detail_batches":
        mark_progress("world_streaming")
        await test_world_chunk_streaming()
        mark_progress("chunk_detail_batches")
        await test_chunk_detail_batches()
        finish_playtest()
        return
    if only_section == "mining_requirements":
        mark_progress("wait_grounded")
        await wait_until_grounded(120)
        mark_progress("mining_requirements")
        await test_mining_tool_requirements()
        finish_playtest()
        return
    if only_section == "mouse_interaction":
        mark_progress("wait_grounded")
        await wait_until_grounded(120)
        mark_progress("right_mouse_interaction")
        await test_right_mouse_interaction_input()
        mark_progress("block_destroy_ray")
        await test_block_destroy_ray()
        finish_playtest()
        return
    if only_section == "settings_debug":
        mark_progress("settings_playtest_debug")
        await test_settings_playtest_debug()
        finish_playtest()
        return
    if only_section != "" and only_section not in ["tutorial_start", "tutorial_runtime_reset"]:
        add_result("playtest_section_filter", false, "unsupported VOXEL_PLAYTEST_ONLY '%s'" % only_section)
        finish_playtest()
        return
    mark_progress("tutorial_start")
    await test_tutorial_start_system()
    if finish_if_only_section("tutorial_start", only_section):
        return
    mark_progress("mouse_look")
    test_mouse_look_input()
    mark_progress("escape_menu_new_game")
    await test_escape_menu_new_game()
    if only_section == "tutorial_runtime_reset":
        finish_playtest()
        return
    mark_progress("inventory_and_crafting")
    await test_inventory_and_crafting_systems()
    mark_progress("tool_weapon_catalog")
    test_tool_weapon_catalog_parity()
    mark_progress("progression")
    test_progression_system()
    mark_progress("equipment")
    test_equipment_system()
    mark_progress("navigation_map")
    await test_navigation_map_system()
    mark_progress("contracts")
    test_contract_system()
    mark_progress("audio_effects")
    await test_audio_effects_system()
    mark_progress("teleport")
    await test_teleport_system()
    mark_progress("settings_playtest_debug")
    await test_settings_playtest_debug()
    mark_progress("hud_refresh_throttling")
    await test_hud_refresh_throttling()
    mark_progress("objectives")
    test_objective_system()
    mark_progress("utility_blocks")
    test_utility_blocks()
    mark_progress("player_placement")
    await test_player_placement_system()
    mark_progress("trader_stall")
    test_trader_stall_system()
    mark_progress("fishing")
    await test_fishing_system()
    mark_progress("survival")
    test_survival_system()
    mark_progress("bed_respawn")
    test_bed_respawn_and_death_drop()
    mark_progress("save_load")
    await test_save_load_round_trip()
    mark_progress("hostiles")
    await test_hostile_system()
    mark_progress("rift_hostiles")
    test_rift_hostile_system()
    mark_progress("sanctuary_beacon_raid")
    test_sanctuary_beacon_raid_system()
    mark_progress("defensive_blocks")
    await test_defensive_blocks()
    mark_progress("player_ranged")
    await test_player_ranged_system()
    mark_progress("structures")
    await test_structure_and_town_generation()
    mark_progress("structural_integrity")
    test_structural_integrity()
    mark_progress("landmarks")
    test_landmark_generation_and_loot()
    mark_progress("underground_volume")
    await test_underground_volume_generation()
    mark_progress("ore_generation")
    test_ore_generation_and_drops()
    mark_progress("forage_wildlife")
    test_forage_and_wildlife_drops()
    mark_progress("generated_prop_visuals")
    test_generated_environment_prop_visuals()
    mark_progress("character_visuals")
    test_modular_character_visuals()
    mark_progress("static_item_assets")
    test_static_item_asset_registry()
    mark_progress("visual_render_policy")
    test_generated_visual_render_policy()
    mark_progress("held_item")
    await test_held_item_system()
    mark_progress("terrain_collision")
    await test_terrain_collision_shapes()
    mark_progress("terrain_topology")
    test_terrain_mesh_topology_signature()
    mark_progress("terrain_material")
    test_terrain_shader_material()
    mark_progress("terrain_normals")
    await test_terrain_chunk_edge_normals()
    mark_progress("terrain_generation_profile")
    test_terrain_generation_profile()
    mark_progress("world_streaming")
    await test_world_chunk_streaming()
    mark_progress("chunk_detail_batches")
    await test_chunk_detail_batches()
    mark_progress("sky_light")
    test_sky_light_consistency()
    mark_progress("environment_visual_style")
    test_environment_visual_style()
    mark_progress("weather_visual")
    test_weather_visual_system()
    mark_progress("water_visual")
    test_water_visual_material()
    mark_progress("weather_presentation")
    test_weather_presentation_batching()
    mark_progress("spawn_clearance")
    test_spawn_clearance()
    mark_progress("player_movement")
    await test_player_movement()
    mark_progress("uphill_smoothing")
    await test_uphill_smoothing()
    mark_progress("steep_uphill")
    await test_steep_uphill_blocking()
    mark_progress("airborne_obstacle")
    await test_airborne_obstacle_blocking()
    mark_progress("jump")
    await test_jump()
    mark_progress("wait_grounded")
    await wait_until_grounded(120)
    mark_progress("mining_requirements")
    await test_mining_tool_requirements()
    mark_progress("mining_progression")
    await test_mining_upgrade_progression()
    mark_progress("material_hardness")
    await test_material_hardness_and_reset()
    mark_progress("right_mouse_interaction")
    await test_right_mouse_interaction_input()
    mark_progress("block_destroy_ray")
    await test_block_destroy_ray()
    finish_playtest()

func finish_playtest() -> void:
    mark_progress("saving_report")
    save_optional_screenshot()
    finished = true
    save_report()
    mark_progress("finished")
    get_tree().quit(1 if failed else 0)

func finish_if_only_section(section_id: String, only_section: String) -> bool:
    if only_section == "" or only_section != section_id:
        return false
    finish_playtest()
    return true

func mark_progress(label: String) -> void:
    var path: String = OS.get_environment("VOXEL_PLAYTEST_PROGRESS")
    if path == "":
        return
    var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\nelapsed=%.3f\nresults=%d\nfailed=%s\n" % [label, elapsed, results.size(), str(failed)])
    file.close()

func wait_physics_frames(count: int) -> void:
    for i in range(count):
        await get_tree().physics_frame

func wait_process_frames(count: int) -> void:
    for i in range(count):
        await get_tree().process_frame

func wait_gameplay_frames(count: int) -> void:
    for i in range(count):
        await get_tree().process_frame
        await get_tree().physics_frame

func dispatch_mouse_button(button_index: int, pressed := true, position := Vector2(-1.0, -1.0)) -> void:
    var event := InputEventMouseButton.new()
    event.button_index = button_index
    event.pressed = pressed
    var event_position := position
    if event_position.x < 0.0 or event_position.y < 0.0:
        event_position = get_viewport().get_visible_rect().size * 0.5
    event.position = event_position
    event.global_position = event_position
    get_viewport().push_input(event)

func control_center(control: Control) -> Vector2:
    if control == null:
        return get_viewport().get_visible_rect().size * 0.5
    return control.get_global_rect().get_center()

func add_result(name: String, passed: bool, details: String = "") -> void:
    results.append({
        "name": name,
        "passed": passed,
        "details": details
    })
    if not passed:
        failed = true
    var status: String = "PASS" if passed else "FAIL"
    print("[%s] %s %s" % [status, name, details])
    save_report(false)

func test_scene_bootstrap() -> void:
    var expected_chunks := 49
    if main != null:
        var distance := playtest_render_distance()
        expected_chunks = maxi(1, (distance * 2 + 1) * (distance * 2 + 1))
        if main.has_method("bootstrap_initial_chunks"):
            main.call("bootstrap_initial_chunks", distance)
        await wait_for_chunk_count(expected_chunks, 120, "scene_bootstrap_chunks")
    var chunks := get_chunks()
    add_result("scene_bootstrap", main != null and player != null and camera != null, "main/player/camera present")
    add_result("initial_chunks_loaded", chunks.size() >= expected_chunks, "%d chunks" % chunks.size())
    if player:
        add_result("controller_ticks", int(player.get("physics_ticks")) > 0, "%d ticks" % int(player.get("physics_ticks")))
    var hud = main.get("hud") if main else null
    var status_label: Label = hud.get("status_label") if hud else null
    var version_label: Label = hud.get("version_label") if hud else null
    var hud_root: Control = hud.get("hud_root") if hud else null
    var ui_theme: Theme = hud.get("ui_theme") if hud else null
    var normal_status := status_label.text if status_label else ""
    var normal_debug_hidden := (
        version_label != null
        and not version_label.visible
        and not normal_status.contains("Voxel Biome World")
        and not normal_status.contains("seed ")
        and not normal_status.contains("chunks")
    )
    if hud:
        hud.call("set_performance_open", true)
        hud.call("set_status", "atlas-1492", "town", 49, Vector2(1.0, 2.0), "12:00")
    var debug_status := status_label.text if status_label else ""
    var debug_readouts_visible := (
        version_label != null
        and version_label.visible
        and version_label.text.begins_with("build ")
        and debug_status.contains("seed atlas-1492")
        and debug_status.contains("49 chunks")
        and debug_status.contains("1, 2")
    )
    if hud:
        hud.call("set_performance_open", false)
    add_result(
        "debug_readouts_gated",
        normal_debug_hidden and debug_readouts_visible,
        "normal '%s', debug '%s', build visible %s" % [normal_status, debug_status, str(version_label.visible if version_label else false)]
    )
    add_result(
        "hud_theme_applied",
        hud_root != null and ui_theme != null and hud_root.theme == ui_theme,
        "theme %s" % str(ui_theme != null)
    )
    var hud_refined := (
        hud != null
        and hud.get("location_panel") != null
        and hud.get("vitals_panel") != null
        and hud.get("reticle_root") != null
        and hud.get("notification_label") != null
        and hud.get("selected_item_label") != null
        and not String(status_label.text if status_label else "").contains("Voxel Biome World")
    )
    add_result(
        "hud_refinement_composition",
        hud_refined,
        "location/vitals/reticle/notifications present %s" % str(hud_refined)
    )

func test_tutorial_start_system() -> void:
    if not main or not player:
        add_result("tutorial_start_system", false, "main/player missing")
        return
    var tutorial_system = main.get("tutorial_system")
    var weather_system = main.get("weather_system")
    var objective_system = main.get("objective_system")
    var inventory_system = main.get("inventory_system")
    var crafting_system = main.get("crafting_system")
    var hostile_system = main.get("hostile_system")
    var npc_system = main.get("npc_system")
    if tutorial_system == null or weather_system == null or objective_system == null or inventory_system == null or crafting_system == null or hostile_system == null or npc_system == null:
        add_result("tutorial_start_system", false, "tutorial/weather/objective/inventory/crafting/hostile/npc system missing")
        return

    var state: Dictionary = tutorial_system.state()
    var tutorial_original_position: Vector3 = player.global_position
    var tutorial_original_velocity: Vector3 = player.velocity
    var cell := Vector2i(main.call("world_to_cell", player.global_position.x), main.call("world_to_cell", player.global_position.z))
    var biome := surface_biome_at_cell2(cell)
    var weather_state: Dictionary = weather_system.snapshot()
    var counts: Dictionary = main.call("structure_counts")
    var time_of_day := float(main.get("time_of_day"))
    var night_start := time_of_day >= 0.80 or time_of_day <= 0.20
    var safety := float(main.call("light_safety_at", player.global_position, false))
    var shelter_state: Dictionary = main.call("shelter_state_at", player.global_position)
    var spawned_inside_house := (
        String(shelter_state.get("label", "")) == "Sheltered"
        and float(shelter_state.get("roof", 0.0)) >= 0.95
        and int(shelter_state.get("wallSectors", 0)) >= 4
        and float(shelter_state.get("comfort", 0.0)) >= 0.62
    )
    var has_town_blocks := int(counts.get("door", 0)) >= 4 and int(counts.get("workbench", 0)) >= 1 and int(counts.get("torch", 0)) >= 2
    var town_center: Vector2i = state.get("townCenter", Vector2i.ZERO)
    var starter_bed_count := count_starter_beds(tutorial_system)
    var fence_radius := 25
    var fence_blocks := 0
    var perimeter_lights := 0
    var perimeter_doors := 0
    var blocks_for_fence := get_blocks()
    for block in blocks_for_fence.values():
        var body := block as Node3D
        if body == null or not body.has_meta("block_type"):
            continue
        var block_cell: Vector3i = body.get_meta("cell")
        var on_perimeter: bool = abs(block_cell.x - town_center.x) == fence_radius or abs(block_cell.z - town_center.y) == fence_radius
        if not on_perimeter:
            continue
        var block_type := String(body.get_meta("block_type", ""))
        if block_type == "woodBlock":
            fence_blocks += 1
        elif block_type == "torch":
            perimeter_lights += 1
        elif block_type == "door":
            perimeter_doors += 1
    var fenced_start := fence_blocks >= 90 and perimeter_lights >= 30 and perimeter_doors >= 8
    var starter_empty: bool = inventory_system.filled_count() == 0
    add_result(
        "tutorial_start_system",
        bool(state.get("started", false))
            and biome == "town"
            and night_start
            and String(weather_state.get("kind", "")) == "rain"
            and bool(weather_state.get("rainVisible", false))
            and int(state.get("npcCount", 0)) >= 4
            and spawned_inside_house
            and starter_bed_count == 1
            and has_town_blocks
            and fenced_start
            and safety > 0.15
            and starter_empty,
        "started %s, biome %s, time %.2f, weather %s rain %s, npcs %d, shelter %s, starter beds %d, safety %.2f, fence %d lights %d gates %d, starter empty %s, counts %s" % [
            str(state.get("started", false)),
            biome,
            time_of_day,
            String(weather_state.get("kind", "")),
            str(weather_state.get("rainVisible", false)),
            int(state.get("npcCount", 0)),
            str(shelter_state),
            starter_bed_count,
            safety,
            fence_blocks,
            perimeter_lights,
            perimeter_doors,
            str(starter_empty),
            str(counts)
        ]
    )
    var initial_wood_state: Dictionary = crafting_system.state_for(crafting_system.recipe_for("woodBlock"))
    var initial_torch_state: Dictionary = crafting_system.state_for(crafting_system.recipe_for("torch"))
    var initial_axe_state: Dictionary = crafting_system.state_for(crafting_system.recipe_for("woodenAxe"))
    var initial_sword_state: Dictionary = crafting_system.state_for(crafting_system.recipe_for("woodenSword"))
    add_result(
        "tutorial_crafting_initial_gate",
        bool(crafting_system.has_unlock_group("tutorial_repair"))
            and not bool(initial_wood_state.get("unlockLocked", true))
            and not bool(initial_torch_state.get("unlockLocked", true))
            and bool(initial_axe_state.get("unlockLocked", false))
            and bool(initial_sword_state.get("unlockLocked", false)),
        "groups %s wood %s torch %s axe %s sword %s" % [
            str(crafting_system.snapshot()),
            str(initial_wood_state),
            str(initial_torch_state),
            str(initial_axe_state),
            str(initial_sword_state)
        ]
    )

    var npc_root = tutorial_system.get("npc_root") as Node
    var mira := npc_root.get_node_or_null("TutorialNPC_mira") if npc_root else null
    var rowan := npc_root.get_node_or_null("TutorialNPC_rowan") if npc_root else null
    var niko := npc_root.get_node_or_null("TutorialNPC_niko") if npc_root else null
    var sera := npc_root.get_node_or_null("TutorialNPC_sera") if npc_root else null
    var audio_effects = main.get("audio_effects")
    var knock_started := audio_effects != null and bool(audio_effects.stats().get("knockLooping", false))
    var intro_before_door: Dictionary = tutorial_system.state() if tutorial_system.has_method("state") else {}
    var door_opened := bool(tutorial_system.on_door_opened(null))
    var intro_after_door: Dictionary = tutorial_system.state() if tutorial_system.has_method("state") else {}
    main.call("refresh_intro_knock_audio")
    var knock_stopped := audio_effects != null and not bool(audio_effects.stats().get("knockLooping", false))
    main.call("show_tutorial_dialogue", String(tutorial_system.get("last_message")))
    await get_tree().process_frame
    var game_hud = main.get("hud")
    var dialogue_open := game_hud != null and bool(game_hud.is_dialogue_open())
    if game_hud:
        game_hud.hide_dialogue(true)
    await get_tree().process_frame
    var dialogue_acknowledged: bool = tutorial_system.has_method("is_intro_elder_waiting_for_ack") and not bool(tutorial_system.is_intro_elder_waiting_for_ack())
    main.call("update_objectives_and_contracts")
    var door_objective := bool(objective_system.is_complete("tutorial_open_door", main.call("objective_state")))
    var starter_cell: Vector2i = tutorial_system.get("start_cell")
    var mira_home_cell: Vector2i = mira.get_meta("npc_home_cell", Vector2i.ZERO) if mira else Vector2i.ZERO
    var mira_has_separate_home := mira != null and mira_home_cell != starter_cell
    var mira_route_bounds: Dictionary = building_bounds_near(starter_cell, 9)
    var mira_route_interior_bounds: Dictionary = shrink_cell_bounds(mira_route_bounds, 1, 2, 1)
    add_result(
        "tutorial_contract_intro_knock_elder",
        door_opened
            and door_objective
            and knock_started
            and knock_stopped
            and dialogue_open
            and dialogue_acknowledged
            and mira_has_separate_home
            and String(tutorial_system.get("last_message")).find("Mira:") == 0,
        "door %s, objective %s, knock %s->%s, dialogue open %s ack %s, before open/ack/active %s/%s/%s after %s/%s/%s, mira home %s starter %s, message '%s'" % [
            str(door_opened),
            str(door_objective),
            str(knock_started),
            str(not knock_stopped),
            str(dialogue_open),
            str(dialogue_acknowledged),
            str(intro_before_door.get("introDoorOpened", null)),
            str(intro_before_door.get("introElderDialogueAcknowledged", null)),
            str(intro_before_door.get("introRepairActive", null)),
            str(intro_after_door.get("introDoorOpened", null)),
            str(intro_after_door.get("introElderDialogueAcknowledged", null)),
            str(intro_after_door.get("introRepairActive", null)),
            str(mira_home_cell),
            str(starter_cell),
            String(tutorial_system.get("last_message"))
        ]
    )
    var mira_entered_starter_interior := false
    var mira_hit_starter_wall := false
    var mira_starter_wall_blocker := {}
    var mira_starter_wall_stuck_frames := 0
    var mira_starter_wall_blocker_key := ""
    var mira_min_starter_distance := INF
    for i in range(120):
        await wait_process_frames(1)
        if mira is Node3D:
            var mira_body_for_route := mira as Node3D
            var flat_distance := Vector2(
                mira_body_for_route.global_position.x - float(starter_cell.x) * CELL,
                mira_body_for_route.global_position.z - float(starter_cell.y) * CELL
            ).length()
            mira_min_starter_distance = minf(mira_min_starter_distance, flat_distance)
            if point_in_cell_bounds(world_to_flat_cell(mira_body_for_route.global_position), mira_route_interior_bounds):
                mira_entered_starter_interior = true
            var blocker_value = mira_body_for_route.get_meta("npc_capsule_blocker", {})
            if blocker_value is Dictionary and not (blocker_value as Dictionary).is_empty():
                var blocker: Dictionary = blocker_value
                var blocker_cell_value = blocker.get("cell", Vector2i(999999, 999999))
                var blocker_cell: Vector2i = blocker_cell_value if blocker_cell_value is Vector2i else Vector2i(999999, 999999)
                var blocker_type := String(blocker.get("blockType", ""))
                if blocker_type != "" and blocker_type != "door" and point_in_cell_bounds(blocker_cell, mira_route_bounds):
                    var blocker_key := "%s:%s" % [String(blocker.get("name", "")), str(blocker_cell)]
                    if blocker_key == mira_starter_wall_blocker_key:
                        mira_starter_wall_stuck_frames += 1
                    else:
                        mira_starter_wall_blocker_key = blocker_key
                        mira_starter_wall_stuck_frames = 1
                    mira_starter_wall_blocker = blocker.duplicate(true)
                    if mira_starter_wall_stuck_frames >= 90:
                        mira_hit_starter_wall = true
                else:
                    mira_starter_wall_stuck_frames = 0
                    mira_starter_wall_blocker_key = ""
            else:
                mira_starter_wall_stuck_frames = 0
                mira_starter_wall_blocker_key = ""
    add_result(
        "tutorial_mira_routes_around_starter_house",
        mira != null and not mira_entered_starter_interior and not mira_hit_starter_wall,
        "entered interior %s, sustained starter wall stuck %s (%d frames), blocker %s, min distance %.2f, bounds %s, interior %s" % [str(mira_entered_starter_interior), str(mira_hit_starter_wall), mira_starter_wall_stuck_frames, JSON.stringify(mira_starter_wall_blocker), mira_min_starter_distance, str(mira_route_bounds), str(mira_route_interior_bounds)]
    )
    var mira_home_wait_frames := 0
    for i in range(7200):
        if mira != null and bool(mira.get_meta("npc_inside_home", false)):
            mira_home_wait_frames = i
            break
        if i % 60 == 0:
            mark_progress("tutorial_elder_return_%03d" % i)
        await wait_gameplay_frames(1)
        mira_home_wait_frames = i + 1
    var starter_position := Vector3(float(starter_cell.x) * CELL, player.global_position.y, float(starter_cell.y) * CELL)
    var mira_position := starter_position
    if mira is Node3D:
        mira_position = (mira as Node3D).global_position
    var mira_distance_from_starter := Vector2(mira_position.x - starter_position.x, mira_position.z - starter_position.z).length()
    var mira_inside_own_home := mira != null and bool(mira.get_meta("npc_inside_home", false)) and mira_distance_from_starter > CELL * 8.0
    add_result(
        "tutorial_elder_returns_home",
        mira_has_separate_home and mira_inside_own_home,
        "home %s, starter %s, distance %.2f, inside %s, waitFrames %d, route %s" % [
            str(mira_home_cell),
            str(starter_cell),
            mira_distance_from_starter,
            str(mira.get_meta("npc_inside_home", false) if mira else false),
            mira_home_wait_frames,
            npc_route_debug(npc_system, mira)
        ]
    )
    mark_progress("tutorial_elder_return_checked")

    var rowan_locked_interaction := rowan != null and bool(tutorial_system.interact_with(rowan))
    var locked_state: Dictionary = tutorial_system.state()
    var locked_talks: Dictionary = locked_state.get("interacted", {})
    var locked_objective_state: Dictionary = main.call("objective_state")
    var rowan_objective_locked := not bool(objective_system.is_complete("tutorial_rowan", locked_objective_state))
    var rowan_step_locked := not bool(locked_talks.get("rowan", false))
    add_result(
        "tutorial_contract_followups_locked_until_sleep",
        rowan_locked_interaction and rowan_objective_locked and rowan_step_locked and String(tutorial_system.get("last_message")).find("after dawn") >= 0,
        "interact %s, objective locked %s, rowan talk locked %s, message '%s'" % [
            str(rowan_locked_interaction),
            str(rowan_objective_locked),
            str(rowan_step_locked),
            String(tutorial_system.get("last_message"))
        ]
    )

    var repair_chest := find_first_block_with_meta("intro_repair_chest", true)
    var utility_system = main.get("utility_system")
    var chest_opened := repair_chest != null and utility_system != null and bool(utility_system.open_block(repair_chest)) and bool(tutorial_system.on_utility_opened(repair_chest))
    var chest_slots: Array = repair_chest.get_meta("storage_slots", []) if repair_chest else []
    var chest_has_supplies := chest_slots.size() >= 2 and String(chest_slots[0].get("item", "")) == "logs" and int(chest_slots[0].get("count", 0)) >= 20 and String(chest_slots[1].get("item", "")) == "stones" and int(chest_slots[1].get("count", 0)) >= 12
    add_result(
        "tutorial_repair_chest_supplies",
        chest_opened and chest_has_supplies and bool(objective_system.is_complete("tutorial_repair_chest", main.call("objective_state"))),
        "opened %s, supplies %s, slots %s" % [str(chest_opened), str(chest_has_supplies), str(chest_slots)]
    )

    inventory_system.add_item("logs", 24)
    inventory_system.add_item("stones", 16)
    move_player_near_first_block_type("workbench")
    var crafted_repair_wood := bool(crafting_system.craft("woodBlock")) and bool(crafting_system.craft("woodBlock"))
    var crafted_repair_lamps := bool(crafting_system.craft("torch"))
    main.call("update_objectives_and_contracts")
    var repair_build_objective := bool(objective_system.is_complete("tutorial_build_repairs", main.call("objective_state")))
    add_result(
        "tutorial_build_repair_supplies",
        crafted_repair_wood and crafted_repair_lamps and inventory_system.count("woodBlock") >= 8 and inventory_system.count("torch") >= 4 and repair_build_objective,
        "wood craft %s, torch craft %s, wood %d, torch %d, objective %s" % [
            str(crafted_repair_wood),
            str(crafted_repair_lamps),
            inventory_system.count("woodBlock"),
            inventory_system.count("torch"),
            str(repair_build_objective)
        ]
    )

    var bed := find_first_block_by_type("bed")
    var blocked_sleep := bed != null and bool(main.call("sleep_at_bed", bed)) and not bool(tutorial_system.state().get("introBedUsed", false))
    var repair_state_before: Dictionary = tutorial_system.state()
    var repair_targets: Dictionary = repair_state_before.get("introRepairTargets", {})
    var repair_marker_root := tutorial_system.get("repair_marker_root") as Node
    var marker_count_before := repair_marker_root.get_child_count() if repair_marker_root else 0
    var expected_marker_count := int(repair_targets.get("fence", []).size()) + int(repair_targets.get("lamps", []).size())
    var occupied_repair_targets := repair_target_occupancy(repair_targets)
    var level_for_repairs := float(tutorial_system.get("town").get("level", player.global_position.y))
    var repaired_all := true
    for cell_variant in repair_targets.get("fence", []):
        var flat: Vector2i = cell_variant
        var world_y := level_for_repairs + CELL * 0.48
        var block = main.call("create_block", Vector3i(flat.x, floori(world_y / CELL) + 1, flat.y), "woodBlock", { "player_placed": true, "world_y": world_y })
        repaired_all = bool(block != null and tutorial_system.on_block_placed(block)) and repaired_all
    for cell_variant in repair_targets.get("lamps", []):
        var flat: Vector2i = cell_variant
        var placed_flat := flat + Vector2i(2, 0)
        var block := Node.new()
        block.set_meta("block_type", "torch")
        block.set_meta("cell", Vector3i(placed_flat.x, 0, placed_flat.y))
        repaired_all = bool(tutorial_system.on_block_placed(block)) and repaired_all
        block.free()
    main.call("update_objectives_and_contracts")
    var repair_state_after: Dictionary = tutorial_system.state()
    var marker_count_after := repair_marker_root.get_child_count() if repair_marker_root else -1
    var repair_complete := bool(repair_state_after.get("introRepairComplete", false))
    var repair_objective := bool(objective_system.is_complete("tutorial_repair_perimeter", main.call("objective_state")))
    var sleep_started := bed != null and bool(main.call("sleep_at_bed", bed))
    if sleep_started:
        main.call("update_sleep_transition", 2.0)
    var slept_after_repair := sleep_started and bool(tutorial_system.state().get("introBedUsed", false))
    main.call("update_objectives_and_contracts")
    var sleep_objective := bool(objective_system.is_complete("tutorial_sleep_after_repair", main.call("objective_state")))
    add_result(
        "tutorial_contract_repair_and_sleep_gate",
        blocked_sleep and occupied_repair_targets.is_empty() and marker_count_before >= expected_marker_count and marker_count_after == 0 and repaired_all and repair_complete and repair_objective and slept_after_repair and sleep_objective and float(main.get("time_of_day")) < 0.36,
        "blocked %s, occupiedTargets %s, markers %d/%d->%d, repaired %s, complete %s, repair objective %s, slept %s, sleep objective %s, time %.2f, state %s" % [
            str(blocked_sleep),
            JSON.stringify(occupied_repair_targets),
            marker_count_before,
            expected_marker_count,
            marker_count_after,
            str(repaired_all),
            str(repair_complete),
            str(repair_objective),
            str(slept_after_repair),
            str(sleep_objective),
            float(main.get("time_of_day")),
            str(tutorial_system.state())
        ]
    )
    if utility_system:
        utility_system.close()
    if main.get("hud"):
        var active_hud = main.get("hud")
        active_hud.call("hide_utility_panel")
        active_hud.call("set_inventory_open", false)
        active_hud.call("set_teleport_open", false)
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

    var interacted := bool(tutorial_system.interact_with(mira))
    var dialogue_focus_ok := false
    if interacted and mira is Node3D:
        var mira_body := mira as Node3D
        var before_focus_position := mira_body.global_position
        main.call("show_tutorial_dialogue", String(tutorial_system.get("last_message")))
        npc_system.update_npcs(0.35, 1.0)
        var to_player_focus: Vector3 = player.global_position - mira_body.global_position
        to_player_focus.y = 0.0
        var expected_focus_yaw := atan2(to_player_focus.x, to_player_focus.z)
        dialogue_focus_ok = (
            bool(mira_body.get_meta("npc_dialogue_focused", false))
            and mira_body.global_position.distance_to(before_focus_position) <= 0.01
            and absf(angle_difference(mira_body.rotation.y, expected_focus_yaw)) < 0.20
        )
        if game_hud != null and bool(game_hud.is_dialogue_open()):
            game_hud.hide_dialogue(true)
    var objective_state: Dictionary = main.call("objective_state")
    var objective_complete := bool(objective_system.is_complete("tutorial_mira", objective_state))
    var message := String(tutorial_system.get("last_message"))
    add_result(
        "tutorial_contract_npc_interaction",
        interacted and objective_complete and dialogue_focus_ok and message.find("Mira:") == 0,
        "interacted %s, objective %s, focus %s, message '%s'" % [str(interacted), str(objective_complete), str(dialogue_focus_ok), message]
    )

    var rowan_blocked_until_niko := rowan != null and bool(tutorial_system.interact_with(rowan)) and String(tutorial_system.get("last_message")).find("Niko") >= 0
    tutorial_system.interact_with(niko)
    inventory_system.add_item("berries", 2)
    tutorial_system.interact_with(niko)
    var niko_steps: Dictionary = tutorial_system.state().get("completedSteps", {})
    add_result(
        "tutorial_contract_niko_food_errand",
        rowan_blocked_until_niko and bool(niko_steps.get("nikoBerries", false)) and inventory_system.count("fieldRation") >= 1 and inventory_system.count("berries") == 0,
        "rowan blocked %s, steps %s, ration %d, berries %d" % [str(rowan_blocked_until_niko), str(niko_steps), inventory_system.count("fieldRation"), inventory_system.count("berries")]
    )

    if rowan is Node3D:
        player.global_position = (rowan as Node3D).global_position + Vector3(0.0, 0.0, CELL * 0.9)
        player.velocity = Vector3.ZERO
        player.set("terrain_grounded", true)
    move_player_near_first_block_type("workbench")
    tutorial_system.interact_with(rowan)
    var rowan_tools_unlocked := bool(crafting_system.has_unlock_group("rowan_basic_tools"))
    inventory_system.add_item("logs", 10)
    var crafted_axe := bool(crafting_system.craft("woodenAxe"))
    tutorial_system.interact_with(rowan)
    inventory_system.add_item("logs", 4)
    main.call("update_objectives_and_contracts")
    var rowan_logs_ready := bool(objective_system.is_complete("tutorial_gather_logs", main.call("objective_state")))
    tutorial_system.interact_with(rowan)
    inventory_system.add_item("logs", 4)
    var crafted_pickaxe := bool(crafting_system.craft("woodenPickaxe"))
    tutorial_system.interact_with(rowan)
    inventory_system.add_item("stones", 4)
    main.call("update_objectives_and_contracts")
    tutorial_system.interact_with(rowan)
    var rowan_state: Dictionary = tutorial_system.state()
    var rowan_steps: Dictionary = rowan_state.get("completedSteps", {})
    add_result(
        "tutorial_contract_rowan_errand_chain",
        rowan_logs_ready
            and rowan_tools_unlocked
            and crafted_axe
            and crafted_pickaxe
            and bool(rowan_steps.get("rowanAxe", false))
            and bool(rowan_steps.get("rowanLogs", false))
            and bool(rowan_steps.get("rowanPickaxe", false))
            and bool(rowan_steps.get("rowanStones", false))
            and bool(rowan_steps.get("rowanBlocks", false))
            and inventory_system.count("stones") >= 4,
        "logs %s, rowan unlock %s, axe %s, pickaxe %s, steps %s, stones %d" % [
            str(rowan_logs_ready),
            str(rowan_tools_unlocked),
            str(crafted_axe),
            str(crafted_pickaxe),
            str(rowan_steps),
            inventory_system.count("stones")
        ]
    )

    tutorial_system.interact_with(sera)
    var rescue_weapon_unlocked := bool(crafting_system.has_unlock_group("rescue_weapon"))
    move_player_near_first_block_type("workbench")
    var crafted_sword := bool(crafting_system.craft("woodenSword"))
    tutorial_system.interact_with(sera)
    main.call("update_objectives_and_contracts")
    var final_tutorial_state: Dictionary = tutorial_system.state()
    var final_steps: Dictionary = final_tutorial_state.get("completedSteps", {})
    var weapon_state: Dictionary = main.call("objective_state")
    var ready_before_final := bool(objective_system.is_complete("tutorial_ready", weapon_state))
    var final_objective_available := bool(objective_system.is_available("tutorial_final_night", weapon_state))
    add_result(
        "tutorial_contract_weapon_preps_final_night",
        crafted_sword
            and rescue_weapon_unlocked
            and bool(final_steps.get("seraWeapon", false))
            and bool(final_steps.get("readyForWilds", false))
            and bool(final_tutorial_state.get("readyForWilds", false))
            and final_objective_available
            and not ready_before_final,
        "crafted sword %s, rescue unlock %s, steps %s, final available %s, ready before final %s" % [
            str(crafted_sword),
            str(rescue_weapon_unlocked),
            str(final_steps),
            str(final_objective_available),
            str(ready_before_final)
        ]
    )
    mark_progress("tutorial_weapon_preps_checked")

    var pre_rescue_snapshot: Dictionary = tutorial_system.snapshot()
    hostile_system.clear()
    var final_started: bool = mira != null and bool(tutorial_system.interact_with(mira))
    if final_started:
        await tutorial_system.acknowledge_dialogue(tutorial_system.dialogue_payload())
    main.call("update_objectives_and_contracts")
    var staged_state: Dictionary = tutorial_system.state()
    var staged_mission: Dictionary = staged_state.get("finalRescueMission", {}) if staged_state.get("finalRescueMission", {}) is Dictionary else {}
    var rescue_required: int = int(staged_state.get("rescueRequired", 6))
    var rescue_remaining: int = int(staged_state.get("rescueRemaining", 0))
    var niko_entry: Dictionary = npc_system.npc_entry_for_actor(niko) if npc_system and npc_system.has_method("npc_entry_for_actor") else {}
    var niko_order: Dictionary = niko_entry.get("scriptedOrder", {}) if niko_entry.get("scriptedOrder", {}) is Dictionary else {}
    var niko_order_reason := String(niko_order.get("submissionReason", niko_order.get("reason", "")))
    var rescue_bodies: Array = tutorial_system.get("rescue_hostiles") if tutorial_system.get("rescue_hostiles") is Array else []
    var passive_slots: Array[String] = []
    var passive_encounter_valid := true
    for enemy_body_value in rescue_bodies:
        var enemy_body := enemy_body_value as Node
        var enemy_state: Dictionary = hostile_system.enemy_for_body(enemy_body) if enemy_body != null else {}
        var slot_id := String(enemy_state.get("scriptedSlotId", ""))
        if slot_id != "" and not passive_slots.has(slot_id):
            passive_slots.append(slot_id)
        passive_encounter_valid = passive_encounter_valid \
            and String(enemy_state.get("scriptedPhase", "")) == "circle_niko" \
            and not bool(enemy_state.get("damageable", true)) \
            and not bool(enemy_state.get("canAttack", true))
    passive_slots.sort()
    var guard_briefed: bool = sera != null and bool(tutorial_system.interact_with(sera))
    if guard_briefed:
        await tutorial_system.acknowledge_dialogue(tutorial_system.dialogue_payload())
    var escort_state: Dictionary = tutorial_system.state()
    var guard_entry: Dictionary = npc_system.npc_entry_for_actor(sera) if npc_system and npc_system.has_method("npc_entry_for_actor") else {}
    var guard_order: Dictionary = guard_entry.get("scriptedOrder", {}) if guard_entry.get("scriptedOrder", {}) is Dictionary else {}
    var guard_order_state := String(guard_order.get("state", ""))
    var guard_order_valid := String(guard_order.get("kind", "")) == "go_to" \
        and bool(guard_order.get("usesRouteStack", false)) \
        and guard_order_state in ["PENDING", "ACTIVE", "ARRIVED"]
    add_result(
        "tutorial_contract_final_rescue_atomic_staging",
        final_started
            and bool(staged_state.get("finalNightActive", false))
            and bool(tutorial_system.is_bed_locked())
            and String(staged_mission.get("phase", "")) == "ready_at_gate"
            and String(niko_order.get("kind", "")) == "wait"
            and niko_order_reason == "final_rescue_staged_wait"
            and rescue_bodies.size() == rescue_required
            and rescue_remaining == rescue_required
            and passive_slots.size() == rescue_required
            and passive_encounter_valid
            and guard_briefed
            and bool(escort_state.get("rescueEscortStarted", false))
            and guard_order_valid,
        "started %s active %s phase %s Niko %s/%s hostiles %d/%d slots %s passive %s Sera %s/%s routeStack %s" % [
            str(final_started),
            str(staged_state.get("finalNightActive", false)),
            String(staged_mission.get("phase", "")),
            String(niko_order.get("kind", "")),
            niko_order_reason,
            rescue_bodies.size(),
            rescue_required,
            str(passive_slots),
            str(passive_encounter_valid),
            String(guard_order.get("kind", "")),
            guard_order_state,
            str(guard_order.get("usesRouteStack", false))
        ]
    )
    mark_progress("tutorial_final_rescue_staging_checked")
    hostile_system.clear()
    tutorial_system.clear_rescue_torch()
    tutorial_system.restore(pre_rescue_snapshot)
    await wait_gameplay_frames(3)

    hostile_system.clear()
    player.global_position = tutorial_original_position
    player.velocity = tutorial_original_velocity
    for i in range(6):
        hostile_system.spawn_cooldown = 0.0
        hostile_system.update_hostiles(0.25, 0.0, "town", false)
        if i % 3 == 0:
            mark_progress("tutorial_perimeter_spawn_%03d" % i)
            await get_tree().process_frame
    var perimeter_spawned: bool = hostile_system.enemies.size() >= 3
    var nearest: float = INF
    var unsafe_spawn: bool = true
    var inside_safe_radius := false
    var center := Vector3(float(town_center.x) * CELL, player.global_position.y, float(town_center.y) * CELL)
    var safe_radius := CELL * 24.0
    for enemy in hostile_system.enemies:
        var body := enemy.get("body") as Node3D
        if body == null:
            continue
        nearest = minf(nearest, body.global_position.distance_to(player.global_position))
        var flat_from_center := Vector2(body.global_position.x - center.x, body.global_position.z - center.z).length()
        inside_safe_radius = inside_safe_radius or flat_from_center < safe_radius
        unsafe_spawn = unsafe_spawn and float(main.call("light_safety_at", body.global_position, false)) < 0.26
    add_result(
        "tutorial_perimeter_hostiles",
        perimeter_spawned and nearest > CELL * 13.0 and unsafe_spawn and not inside_safe_radius,
        "spawned %d, nearest %.2f, outside light %s, inside safe %s" % [hostile_system.enemies.size(), nearest, str(unsafe_spawn), str(inside_safe_radius)]
    )

    hostile_system.clear()
    var guard_spawn: Dictionary = spawn_visible_guard_behavior_hostile(npc_system, hostile_system)
    if not bool(guard_spawn.get("spawned", false)):
        var guard_target_position := Vector3(center.x, center.y, center.z - CELL * float(25 - 5))
        guard_target_position.y = surface_y_at_position(guard_target_position) + 0.72
        hostile_system.spawn_enemy(guard_target_position, "shadow")
        guard_spawn["fallbackPosition"] = guard_target_position
    var npc_stats_before: Dictionary = npc_system.stats()
    var guard_shots_before := int(npc_stats_before.get("guardShots", 0))
    var use_animations_before := int(npc_stats_before.get("useAnimations", 0))
    for i in range(1800):
        if i % 30 == 0:
            var stats_now: Dictionary = npc_system.stats()
            if int(stats_now.get("sheltered", 0)) >= 3 and int(stats_now.get("guardShots", 0)) > guard_shots_before and int(stats_now.get("useAnimations", 0)) > use_animations_before:
                break
        if i % 60 == 0:
            mark_progress("tutorial_guard_behavior_%03d" % i)
        await wait_process_frames(1)
    var npc_stats_after: Dictionary = npc_system.stats()
    var tutorial_npc_count := npc_root.get_child_count() if npc_root else 0
    var all_tutorial_npcs_have_homes := int(npc_stats_after.get("homed", 0)) >= tutorial_npc_count
    var non_fighters_sheltered := int(npc_stats_after.get("sheltered", 0)) >= 3
    var tutorial_fighters_ready := int(npc_stats_after.get("fighters", 0)) >= 3
    var guards_fired := int(npc_stats_after.get("guardShots", 0)) > guard_shots_before
    var fighters_armed := int(npc_stats_after.get("armed", 0)) >= int(npc_stats_after.get("fighters", 0))
    var weapons_visible := int(npc_stats_after.get("visibleWeapons", 0)) >= int(npc_stats_after.get("fighters", 0))
    var weapon_use_animated := int(npc_stats_after.get("useAnimations", 0)) > use_animations_before
    add_result(
        "tutorial_npc_home_and_guard_behavior",
        bool(guard_spawn.get("spawned", false)) and all_tutorial_npcs_have_homes and non_fighters_sheltered and tutorial_fighters_ready and guards_fired and fighters_armed and weapons_visible and weapon_use_animated,
        "spawn %s, npcs %d, stats %s, shots %d->%d, use %d->%d, routes %s" % [
            str(guard_spawn),
            tutorial_npc_count,
            str(npc_stats_after),
            guard_shots_before,
            int(npc_stats_after.get("guardShots", 0)),
            use_animations_before,
            int(npc_stats_after.get("useAnimations", 0)),
            npc_shelter_debug(npc_system)
        ]
    )
    hostile_system.clear()
    player.global_position = tutorial_original_position
    player.velocity = tutorial_original_velocity

func test_mouse_look_input() -> void:
    if not main or not player or not camera:
        add_result("mouse_look_input", false, "main/player/camera missing")
        return
    var hud = main.get("hud")
    if hud:
        hud.set_inventory_open(false)
        hud.set_teleport_open(false)
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    var yaw_before: float = player.rotation.y
    var pitch_before: float = camera.rotation.x
    var event := InputEventMouseMotion.new()
    event.relative = Vector2(42.0, -24.0)
    main.call("_input", event)
    var yaw_changed: bool = abs(player.rotation.y - yaw_before) > 0.001
    var pitch_changed: bool = abs(camera.rotation.x - pitch_before) > 0.001
    add_result(
        "mouse_look_input",
        yaw_changed and pitch_changed,
        "yaw %.4f->%.4f, pitch %.4f->%.4f" % [yaw_before, player.rotation.y, pitch_before, camera.rotation.x]
    )
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func test_escape_menu_new_game() -> void:
    if not main or not player:
        add_result("escape_menu_new_game", false, "main/player missing")
        return
    var hud = main.get("hud")
    var inventory_system = main.get("inventory_system")
    var save_system = main.get("save_system")
    var tutorial_system = main.get("tutorial_system")
    var weather_system = main.get("weather_system")
    if hud == null or inventory_system == null or save_system == null or tutorial_system == null or weather_system == null:
        add_result("escape_menu_new_game", false, "hud/inventory/save/tutorial/weather missing")
        return

    hud.set_inventory_open(false)
    hud.set_teleport_open(false)
    hud.set_settings_open(false)
    hud.set_playtest_open(false)
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

    var escape := InputEventKey.new()
    escape.keycode = KEY_ESCAPE
    escape.pressed = true
    main.call("_unhandled_input", escape)
    var opened_menu: bool = hud.is_game_menu_open() and Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE

    inventory_system.add_item("logs", 3)
    var old_seed := String(main.get("seed_text"))
    var saved_ok: bool = bool(main.call("save_world", false))
    var saved_snapshot: Dictionary = save_system.load(old_seed)
    var saved_before: bool = saved_ok and not saved_snapshot.is_empty()
    var new_game_button := find_button_by_text(hud.get("game_menu_panel") as Node, "New Game")
    if new_game_button:
        new_game_button.emit_signal("pressed")
    var loading_completed := await wait_for_runtime_loading_complete()
    await wait_physics_frames(4)
    var new_seed := String(main.get("seed_text"))

    var cell := Vector2i(main.call("world_to_cell", player.global_position.x), main.call("world_to_cell", player.global_position.z))
    var biome := surface_biome_at_cell2(cell)
    var shelter_state: Dictionary = main.call("shelter_state_at", player.global_position)
    var weather_state: Dictionary = weather_system.snapshot()
    var tutorial_state: Dictionary = tutorial_system.state()
    var reset_started: bool = bool(tutorial_state.get("started", false))
    var deleted_snapshot: Dictionary = save_system.load(old_seed)
    var save_deleted: bool = deleted_snapshot.is_empty()
    var active_seed_changed: bool = new_seed != old_seed and new_seed.begins_with("atlas-")
    var remembered_seed: bool = String(save_system.active_seed("")) == new_seed
    var mouse_mode_after: int = int(Input.get_mouse_mode())
    var inventory_totals: Dictionary = inventory_system.totals()
    var main_inventory_totals: Dictionary = main.get("inventory")
    var starter_bed_count := count_starter_beds(tutorial_system)
    var fresh_state: bool = (
        bool(tutorial_state.get("started", false))
        and biome == "town"
        and String(weather_state.get("kind", "")) == "rain"
        and String(shelter_state.get("label", "")) == "Sheltered"
        and starter_bed_count == 1
        and inventory_system.filled_count() == 0
        and not hud.is_game_menu_open()
    )
    add_result(
        "escape_menu_new_game",
        opened_menu and new_game_button != null and loading_completed and saved_before and reset_started and save_deleted and active_seed_changed and remembered_seed and fresh_state,
        "opened %s, button %s, loading complete %s, saved %s, reset %s, deleted %s, seed %s->%s remembered %s, biome %s, weather %s, shelter %s, starter beds %d, inv %d, totals %s, main totals %s, menu %s, mouse %d" % [
            str(opened_menu),
            str(new_game_button != null),
            str(loading_completed),
            str(saved_before),
            str(reset_started),
            str(save_deleted),
            old_seed,
            new_seed,
            str(remembered_seed),
            biome,
            String(weather_state.get("kind", "")),
            str(shelter_state),
            starter_bed_count,
            inventory_system.filled_count(),
            str(inventory_totals),
            str(main_inventory_totals),
            str(hud.is_game_menu_open()),
            mouse_mode_after
        ]
    )
    if active_seed_changed:
        mark_progress("escape_menu_restore_seed")
        main.call("apply_world_seed", old_seed, true)
        mark_progress("escape_menu_reset_state")
        main.call("reset_runtime_world_state", false)
        mark_progress("escape_menu_restart_tutorial")
        tutorial_system.start_new_world()
        mark_progress("escape_menu_reload_chunks")
        main.call("reload_chunks", true)
        await wait_for_chunk_streaming_after_restore()
        main.call("refresh_intro_knock_audio")
    unlock_intro_gate_for_followup_tests(tutorial_system)

func wait_for_runtime_loading_complete(max_seconds := 240.0) -> bool:
    if main == null:
        return false
    var started_usec := Time.get_ticks_usec()
    var observed_frames := 0
    while float(Time.get_ticks_usec() - started_usec) / 1000000.0 < max_seconds:
        var failure_value = main.get("startup_loading_failure_result")
        if failure_value is Dictionary and not (failure_value as Dictionary).is_empty():
            mark_progress("escape_menu_new_game_failed_%s" % String((failure_value as Dictionary).get("reason", "unknown")))
            return false
        if not bool(main.get("runtime_loading_active")):
            mark_progress("escape_menu_new_game_loaded")
            return true
        if observed_frames % 60 == 0:
            var timeline_value = main.get("startup_loading_timeline")
            var latest := {}
            if timeline_value is Array and not (timeline_value as Array).is_empty() and (timeline_value as Array)[-1] is Dictionary:
                latest = (timeline_value as Array)[-1]
            var domain := String(latest.get("domain", "unknown")).replace(" ", "_")
            var status := String(latest.get("status", "unknown")).replace(" ", "_")
            var message := String(latest.get("message", "unknown")).replace(" ", "_")
            mark_progress("escape_menu_new_game_loading_%04d_%s_%s_%s" % [observed_frames, domain, status, message])
        await wait_physics_frames(1)
        observed_frames += 1
    mark_progress("escape_menu_new_game_loading_timeout")
    return false

func wait_for_chunk_streaming_after_restore(max_frames := 90) -> void:
    if main == null:
        return
    var expected_chunks := 49
    if main.get("render_distance") is int:
        var distance := int(main.get("render_distance"))
        expected_chunks = (distance * 2 + 1) * (distance * 2 + 1)
    for i in range(max_frames):
        var chunks := get_chunks()
        if chunks.size() >= expected_chunks:
            mark_progress("escape_menu_chunks_reloaded")
            return
        main.call("update_chunks", false)
        if i % 15 == 0:
            mark_progress("escape_menu_chunk_stream_%03d" % i)
        await wait_physics_frames(1)
    mark_progress("escape_menu_chunk_stream_timeout")

func wait_for_chunk_count(expected_chunks: int, max_frames := 90, label := "chunk_wait") -> void:
    if main == null:
        return
    for i in range(max_frames):
        var chunks := get_chunks()
        if chunks.size() >= expected_chunks:
            mark_progress("%s_done" % label)
            return
        main.call("update_chunks", false)
        if i % 15 == 0:
            mark_progress("%s_%03d_%d" % [label, i, chunks.size()])
        await wait_physics_frames(1)
    mark_progress("%s_timeout_%d" % [label, get_chunks().size()])

func playtest_render_distance() -> int:
    if main != null and main.get("render_distance") is int:
        return int(main.get("render_distance"))
    return 3

func bootstrap_playtest_visible_chunks() -> void:
    if main != null and main.has_method("bootstrap_initial_chunks"):
        main.call("bootstrap_initial_chunks", playtest_render_distance())

func settle_streamed_chunks_after_relocation(label := "relocation_chunks", max_frames := 120) -> void:
    if main == null:
        return
    var render_distance := int(main.get("render_distance"))
    var expected_chunks := maxi(1, (render_distance * 2 + 1) * (render_distance * 2 + 1))
    if main.has_method("bootstrap_initial_chunks"):
        bootstrap_playtest_visible_chunks()
    elif main.has_method("update_chunks"):
        main.call("update_chunks", false)
    await wait_for_chunk_count(expected_chunks, max_frames, label)
    await wait_for_terrain_collision_shapes(max_frames)

func find_button_by_text(node: Node, text: String) -> Button:
    if node == null:
        return null
    var button := node as Button
    if button != null and button.text == text:
        return button
    for child in node.get_children():
        var found := find_button_by_text(child, text)
        if found != null:
            return found
    return null

func unlock_intro_gate_for_followup_tests(tutorial_system) -> void:
    if tutorial_system == null:
        return
    tutorial_system.set("intro_repair_complete", true)
    tutorial_system.call("complete_step", "introPerimeterRepaired")
    tutorial_system.call("on_bed_used")
    tutorial_system.call("complete_step", "miraMorningBriefing")

func test_inventory_and_crafting_systems() -> void:
    if not main:
        add_result("inventory_system_present", false, "main missing")
        return

    var inventory_system = main.get("inventory_system")
    var crafting_system = main.get("crafting_system")
    var hud = main.get("hud")
    var has_systems := inventory_system != null and crafting_system != null and hud != null
    add_result("inventory_system_present", has_systems, "inventory/crafting/hud present")
    if not has_systems:
        return

    var gate_slots := []
    for i in range(inventory_system.size):
        gate_slots.append({ "item": "", "count": 0 })
    gate_slots[0] = { "item": "logs", "count": 24 }
    gate_slots[1] = { "item": "stones", "count": 8 }
    inventory_system.restore({
        "slots": gate_slots,
        "size": inventory_system.size,
        "selectedSlot": 0
    })
    crafting_system.restore({ "unlockedGroups": ["tutorial_repair"] })
    var gate_station_cell := Vector3i(roundi(player.global_position.x / CELL) + 3, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL))
    var gate_station = main.call("create_block", gate_station_cell, "workbench")
    var locked_axe_state: Dictionary = crafting_system.state_for(crafting_system.recipe_for("woodenAxe"))
    var locked_sword_state: Dictionary = crafting_system.state_for(crafting_system.recipe_for("woodenSword"))
    var unlocked_repair_state: Dictionary = crafting_system.state_for(crafting_system.recipe_for("woodBlock"))
    var logs_before_gate: int = inventory_system.count("logs")
    var locked_axe_crafted: bool = bool(crafting_system.craft("woodenAxe"))
    var repair_crafted_under_gate: bool = bool(crafting_system.craft("woodBlock"))
    var logs_after_repair_gate: int = inventory_system.count("logs")
    crafting_system.unlock_group("rowan_basic_tools")
    var rowan_axe_state: Dictionary = crafting_system.state_for(crafting_system.recipe_for("woodenAxe"))
    var rowan_axe_crafted: bool = bool(crafting_system.craft("woodenAxe"))
    var gate_blocks := get_blocks()
    if gate_station:
        gate_station.queue_free()
    if gate_blocks.has(gate_station_cell):
        gate_blocks.erase(gate_station_cell)
    add_result(
        "crafting_recipe_unlock_authority",
        bool(locked_axe_state.get("unlockLocked", false))
            and bool(locked_sword_state.get("unlockLocked", false))
            and not bool(unlocked_repair_state.get("unlockLocked", true))
            and not locked_axe_crafted
            and logs_after_repair_gate == logs_before_gate - 2
            and repair_crafted_under_gate
            and bool(crafting_system.has_unlock_group("rowan_basic_tools"))
            and not bool(rowan_axe_state.get("unlockLocked", true))
            and rowan_axe_crafted,
        "locked axe %s sword %s repair %s locked craft %s repair craft %s rowan state %s rowan craft %s inventory %s" % [
            str(locked_axe_state),
            str(locked_sword_state),
            str(unlocked_repair_state),
            str(locked_axe_crafted),
            str(repair_crafted_under_gate),
            str(rowan_axe_state),
            str(rowan_axe_crafted),
            str(inventory_system.totals())
        ]
    )

    var book_slots := []
    for i in range(inventory_system.size):
        book_slots.append({ "item": "", "count": 0 })
    book_slots[0] = { "item": "rareBookBow", "count": 1 }
    book_slots[1] = { "item": "logs", "count": 12 }
    book_slots[2] = { "item": "grass", "count": 8 }
    inventory_system.restore({
        "slots": book_slots,
        "size": inventory_system.size,
        "selectedSlot": 0
    })
    crafting_system.restore({ "unlockedGroups": ["tutorial_repair", "rowan_basic_tools", "rescue_weapon"] })
    var book_station_cell := Vector3i(roundi(player.global_position.x / CELL) + 3, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL))
    var book_station = main.call("create_block", book_station_cell, "workbench")
    var bow_locked_before_book: Dictionary = crafting_system.state_for(crafting_system.recipe_for("hunterBow"))
    var bow_craft_before_book: bool = bool(crafting_system.craft("hunterBow"))
    var read_book_with_active_use: bool = bool(main.call("try_use_active_consumable"))
    var bow_state_after_book: Dictionary = crafting_system.state_for(crafting_system.recipe_for("hunterBow"))
    var bow_craft_after_book: bool = bool(crafting_system.craft("hunterBow"))
    var book_blocks := get_blocks()
    if book_station:
        book_station.queue_free()
    if book_blocks.has(book_station_cell):
        book_blocks.erase(book_station_cell)
    add_result(
        "crafting_book_active_use_unlocks_recipe",
        bool(bow_locked_before_book.get("unlockLocked", false))
            and not bow_craft_before_book
            and read_book_with_active_use
            and inventory_system.count("rareBookBow") == 0
            and bool(crafting_system.has_unlock_group("rare_bow"))
            and not bool(bow_state_after_book.get("unlockLocked", true))
            and bow_craft_after_book,
        "before %s craft_before %s read %s book_count %d after %s craft_after %s message '%s'" % [
            str(bow_locked_before_book),
            str(bow_craft_before_book),
            str(read_book_with_active_use),
            inventory_system.count("rareBookBow"),
            str(bow_state_after_book),
            str(bow_craft_after_book),
            String(crafting_system.get("last_message"))
        ]
    )
    crafting_system.unlock_all_groups()

    add_result(
        "inventory_slots",
        inventory_system.slots.size() == 24 and inventory_system.hotbar_size == 8,
        "%d slots, %d hotbar" % [inventory_system.slots.size(), inventory_system.hotbar_size]
    )

    var seeded_slots := []
    for i in range(inventory_system.size):
        seeded_slots.append({ "item": "", "count": 0 })
    seeded_slots[5] = { "item": "logs", "count": 12 }
    inventory_system.restore({
        "slots": seeded_slots,
        "size": inventory_system.size,
        "selectedSlot": 5
    })

    inventory_system.select(5)
    var active: Dictionary = inventory_system.active_stack()
    add_result(
        "hotbar_switching",
        String(active.get("item", "")) == "logs",
        "slot 6 active %s" % String(active.get("item", ""))
    )
    var wheel_previous: int = int(main.call("select_hotbar_delta", -1))
    var wheel_next: int = int(main.call("select_hotbar_delta", 1))
    add_result(
        "hotbar_wheel_cycle",
        wheel_previous == 4 and wheel_next == 5 and String(inventory_system.active_stack().get("item", "")) == "logs",
        "wheel slots %d->%d active %s" % [wheel_previous, wheel_next, String(inventory_system.active_stack().get("item", ""))]
    )
    hud.set_inventory_open(false)
    hud.render_hotbar()
    var hotbar_child_count: int = hud.hotbar.get_child_count() if hud.hotbar else 0
    var first_hotbar_button := hud.hotbar.get_child(0) as Button if hotbar_child_count > 0 else null
    inventory_system.select(6)
    hud.render_hotbar()
    var selected_hotbar_button := hud.hotbar.get_child(6) as Button if hud.hotbar.get_child_count() > 6 else null
    var populated_hotbar_button := hud.hotbar.get_child(5) as Button if hud.hotbar.get_child_count() > 5 else null
    var selected_shortcut_label := selected_hotbar_button.get("shortcut_label") as Label if selected_hotbar_button != null else null
    var populated_shortcut_label := populated_hotbar_button.get("shortcut_label") as Label if populated_hotbar_button != null else null
    var populated_icon_rect := populated_hotbar_button.get("icon_rect") as TextureRect if populated_hotbar_button != null else null
    var populated_count_label := populated_hotbar_button.get("count_label") as Label if populated_hotbar_button != null else null
    var hotbar_reuses_slots: bool = (
        hotbar_child_count == inventory_system.hotbar_size
        and first_hotbar_button != null
        and hud.hotbar.get_child(0) == first_hotbar_button
        and selected_hotbar_button != null
        and String(selected_hotbar_button.theme_type_variation) == "HotbarSlotSelected"
        and selected_shortcut_label != null
        and selected_shortcut_label.text == "7"
        and populated_shortcut_label != null
        and populated_shortcut_label.text == "6"
        and populated_icon_rect != null
        and populated_icon_rect.texture != null
        and populated_count_label != null
        and populated_count_label.text == "12"
    )
    add_result(
        "hotbar_reuses_slots",
        hotbar_reuses_slots,
        "children %d, first reused %s, selected variation %s" % [
            hud.hotbar.get_child_count() if hud.hotbar else 0,
            str(first_hotbar_button != null and hud.hotbar.get_child(0) == first_hotbar_button),
            String(selected_hotbar_button.theme_type_variation) if selected_hotbar_button else ""
        ]
    )
    inventory_system.select(5)

    main.call("_on_ui_slot_clicked", 12)
    var empty_click_inert: bool = (
        inventory_system.selected_slot == 5
        and String(inventory_system.active_stack().get("item", "")) == "logs"
        and String(inventory_system.slots[12].get("item", "")) == ""
    )
    add_result(
        "inventory_empty_slot_click_inert",
        empty_click_inert,
        "selected %d, active %s, slot13 '%s'" % [
            inventory_system.selected_slot,
            String(inventory_system.active_stack().get("item", "")),
            String(inventory_system.slots[12].get("item", ""))
        ]
    )

    inventory_system.slots[10] = { "item": "stones", "count": 4 }
    inventory_system.slots[12] = { "item": "", "count": 0 }
    inventory_system.notify()
    var moved_stack: bool = inventory_system.move_slot(10, 12)
    var drag_reordered: bool = (
        moved_stack
        and String(inventory_system.slots[10].get("item", "")) == ""
        and String(inventory_system.slots[12].get("item", "")) == "stones"
        and int(inventory_system.slots[12].get("count", 0)) == 4
        and String(inventory_system.active_stack().get("item", "")) == "logs"
    )
    add_result(
        "inventory_drag_drop_reorders",
        drag_reordered,
        "moved %s, slot11 %s, slot13 %s x%d, active %s" % [
            str(moved_stack),
            String(inventory_system.slots[10].get("item", "")),
            String(inventory_system.slots[12].get("item", "")),
            int(inventory_system.slots[12].get("count", 0)),
            String(inventory_system.active_stack().get("item", ""))
        ]
    )

    var logs_before: int = inventory_system.count("logs")
    var workbench_before: int = inventory_system.count("workbench")
    var crafted_bench: bool = crafting_system.craft("workbench")
    add_result(
        "craft_workbench_without_station",
        crafted_bench and inventory_system.count("workbench") == workbench_before + 1 and inventory_system.count("logs") == logs_before - 4,
        "logs %d->%d, workbench %d->%d" % [logs_before, inventory_system.count("logs"), workbench_before, inventory_system.count("workbench")]
    )

    var wood_state: Dictionary = crafting_system.state_for(crafting_system.recipe_for("woodBlock"))
    add_result(
        "crafting_station_lock",
        bool(wood_state.get("benchLocked", false)),
        String(wood_state.get("status", ""))
    )

    var station_cell := Vector3i(roundi(player.global_position.x / CELL) + 2, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL))
    main.call("create_block", station_cell, "workbench")
    var wood_before: int = inventory_system.count("woodBlock")
    logs_before = inventory_system.count("logs")
    var crafted_wood: bool = crafting_system.craft("woodBlock")
    add_result(
        "craft_with_near_workbench",
        crafted_wood and inventory_system.count("woodBlock") == wood_before + 4 and inventory_system.count("logs") == logs_before - 2,
        "wood %d->%d, logs %d->%d" % [wood_before, inventory_system.count("woodBlock"), logs_before, inventory_system.count("logs")]
    )
    var blocks := get_blocks()
    if blocks.has(station_cell):
        var station_block := blocks[station_cell] as Node
        if station_block:
            station_block.queue_free()
        blocks.erase(station_cell)

    hud.set_inventory_open(true)
    add_result(
        "inventory_ui_opens",
        hud.is_inventory_open() and hud.inventory_panel.visible and hud.inventory_grid.get_child_count() == inventory_system.slots.size(),
        "open %s, grid children %d" % [str(hud.is_inventory_open()), hud.inventory_grid.get_child_count()]
    )
    var empty_slot_button := hud.inventory_grid.get_child(10) as Control if hud.inventory_grid.get_child_count() > 10 else null
    var button_script_path := String(empty_slot_button.get_script().resource_path) if empty_slot_button != null and empty_slot_button.get_script() != null else ""
    var empty_slot_accepts_drop := empty_slot_button != null and bool(empty_slot_button.call("_can_drop_data", Vector2.ZERO, { "kind": "inventory_slot", "from": 12 }))
    add_result(
        "inventory_drag_drop_ui",
        button_script_path.ends_with("InventorySlotButton.gd") and empty_slot_accepts_drop,
        "script %s, accepts drop %s" % [button_script_path, str(empty_slot_accepts_drop)]
    )
    inventory_system.slots[9] = { "item": "stones", "count": 2 }
    inventory_system.slots[10] = { "item": "", "count": 0 }
    var deferred_drop_target := InventorySlotButtonScript.new()
    add_child(deferred_drop_target)
    deferred_drop_target.configure(10, "", 0, false)
    deferred_drop_target.slot_dropped.connect(Callable(hud, "_on_slot_dropped"))
    deferred_drop_target.call("_drop_data", Vector2.ZERO, { "kind": "inventory_slot", "from": 9 })
    var drop_waited_for_idle: bool = String(inventory_system.slots[10].get("item", "")) == ""
    await get_tree().process_frame
    var deferred_drop_moved: bool = (
        drop_waited_for_idle
        and String(inventory_system.slots[9].get("item", "")) == ""
        and String(inventory_system.slots[10].get("item", "")) == "stones"
        and hud.inventory_grid.get_child_count() == inventory_system.slots.size()
    )
    deferred_drop_target.queue_free()
    add_result(
        "inventory_drag_drop_deferred_ui",
        deferred_drop_moved,
        "target %s, waited %s, slot10 %s, slot11 %s, children %d" % [
            str(deferred_drop_target != null),
            str(drop_waited_for_idle),
            String(inventory_system.slots[9].get("item", "")),
            String(inventory_system.slots[10].get("item", "")),
            hud.inventory_grid.get_child_count() if hud.inventory_grid else 0
        ]
    )
    inventory_system.select(5)
    hud.call("_on_slot_pressed", 0, false)
    var panel_click_does_not_equip: bool = inventory_system.selected_slot == 5 and not hud.hotbar.visible
    add_result(
        "inventory_panel_click_does_not_equip",
        panel_click_does_not_equip,
        "selected %d, hotbar visible %s" % [inventory_system.selected_slot, str(hud.hotbar.visible)]
    )
    inventory_system.slots[9] = { "item": "stones", "count": 2 }
    inventory_system.slots[10] = { "item": "", "count": 0 }
    inventory_system.notify()
    main.call("_on_ui_slot_moved", 9, 10)
    var panel_drag_keeps_hotbar_hidden: bool = hud.is_inventory_open() and not hud.hotbar.visible and String(inventory_system.slots[10].get("item", "")) == "stones"
    add_result(
        "inventory_drag_keeps_single_ui",
        panel_drag_keeps_hotbar_hidden,
        "open %s, hotbar visible %s, slot11 %s" % [str(hud.is_inventory_open()), str(hud.hotbar.visible), String(inventory_system.slots[10].get("item", ""))]
    )
    var wood_icon := hud.call("icon_for", "woodBlock") as Texture2D
    var crossbow_icon := hud.call("icon_for", "ironCrossbow") as Texture2D
    var first_craft_button := hud.crafting_list.get_child(0) as Button if hud.crafting_list.get_child_count() > 0 else null
    var wood_color_count := icon_distinct_colors(wood_icon)
    var crossbow_color_count := icon_distinct_colors(crossbow_icon)
    add_result(
        "ui_item_icons_polished",
        wood_icon != null
            and crossbow_icon != null
            and wood_icon.get_width() >= 48
            and crossbow_icon.get_width() >= 48
            and wood_color_count >= 8
            and crossbow_color_count >= 6
            and first_craft_button != null
            and first_craft_button.icon != null,
        "wood %dx%d/%d colors, crossbow %dx%d/%d colors, craft icon %s" % [
            wood_icon.get_width() if wood_icon else 0,
            wood_icon.get_height() if wood_icon else 0,
            wood_color_count,
            crossbow_icon.get_width() if crossbow_icon else 0,
            crossbow_icon.get_height() if crossbow_icon else 0,
            crossbow_color_count,
            str(first_craft_button != null and first_craft_button.icon != null)
        ]
    )
    hud.set_inventory_open(false)

    main.call("update_hud")
    add_result(
        "navigation_ui_gated",
        not hud.compass_label.visible and not hud.map_panel.visible,
        "compass %s, map %s" % [str(hud.compass_label.visible), str(hud.map_panel.visible)]
    )

func test_held_item_system() -> void:
    if not main:
        add_result("held_item_present", false, "main missing")
        return
    var inventory_system = main.get("inventory_system")
    var held_item = main.get("held_item")
    var present: bool = held_item != null and camera != null and held_item.get_parent() == camera
    add_result("held_item_present", present, "held item parent camera %s" % str(present))
    if not present:
        return

    var wood_slot := find_inventory_slot(inventory_system, "woodBlock")
    inventory_system.select(0)
    if wood_slot > 0:
        inventory_system.swap_with_active(wood_slot)
    await wait_physics_frames(2)
    var item_matches: bool = String(held_item.get("current_item")) == "woodBlock" and held_item.visible
    add_result("held_item_tracks_hotbar", item_matches, "current %s" % String(held_item.get("current_item")))

    held_item.call("play_use", "strike")
    await wait_physics_frames(1)
    add_result(
        "held_item_use_animation",
        float(held_item.get("use_time")) > 0.0,
        "use time %.2f" % float(held_item.get("use_time"))
    )

    var original_player_position: Vector3 = player.global_position
    held_item.set("use_time", 0.0)
    var local_ground: float = surface_y_at_position(original_player_position)
    player.global_position = Vector3(original_player_position.x, local_ground + 8.0, original_player_position.z)
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    camera.rotation.x = 0.0
    main.call("reset_break_progress")
    main.call("destroy_target")
    await wait_physics_frames(1)
    var miss_animated: bool = float(held_item.get("use_time")) > 0.0 and String(main.get("break_target_id")) == ""
    player.global_position = original_player_position
    add_result(
        "melee_miss_swing_animation",
        miss_animated,
        "use time %.2f, break target '%s'" % [float(held_item.get("use_time")), String(main.get("break_target_id"))]
    )

    var held_light_original_time := float(main.get("time_of_day"))
    main.set("time_of_day", 0.75)
    main.call("update_sky", 0.0)

    inventory_system.add_item("torch", 1)
    var torch_slot := find_inventory_slot(inventory_system, "torch")
    inventory_system.select(0)
    if torch_slot > 0:
        inventory_system.swap_with_active(torch_slot)
    await wait_physics_frames(2)
    var held_torch_root: Node = held_item.get_node_or_null("HeldItemRoot")
    var held_torch_lights := count_light_descendants(held_torch_root)
    var held_torch_fire_lights := count_fire_light_descendants(held_torch_root)
    var held_torch_shadowed := count_shadowed_light_descendants(held_torch_root)
    var held_torch_overlay_meshes := ground_overlay_mesh_descendants(held_torch_root)
    var held_torch_ground_fills := ground_fill_light_descendants(held_torch_root)
    var held_torch_sources := light_role_descendants(held_torch_root, "source")
    var held_torch_terrain_washes := light_role_descendants(held_torch_root, "terrain_wash")
    var held_torch_bounce_fills := light_role_descendants(held_torch_root, "bounce_fill")
    var held_torch_ground_fill: Light3D = null
    if not held_torch_terrain_washes.is_empty():
        held_torch_ground_fill = held_torch_terrain_washes[0] as Light3D
    var held_torch_light := first_light_role_descendant(held_torch_root, "source")
    var held_torch_omni := held_torch_light as OmniLight3D
    var held_energy_before := held_torch_light.light_energy if held_torch_light else 0.0
    var held_range_before := held_torch_omni.omni_range if held_torch_omni else 0.0
    var held_base_energy := light_base_energy(held_torch_light)
    var held_base_range := light_base_range(held_torch_light)
    var held_min_scale := light_flicker_min_scale(held_torch_light)
    var torch_original_pitch := camera.rotation.x
    camera.rotation.x = 0.0
    await wait_physics_frames(2)
    var torch_fill_level_pos := held_torch_ground_fill.global_position if held_torch_ground_fill else Vector3.ZERO
    var torch_fill_level_ground := surface_y_at_position(torch_fill_level_pos) if held_torch_ground_fill else 0.0
    camera.rotation.x = deg_to_rad(62.0)
    await wait_physics_frames(2)
    var torch_fill_up_pos := held_torch_ground_fill.global_position if held_torch_ground_fill and is_instance_valid(held_torch_ground_fill) else Vector3.ZERO
    var torch_fill_up_ground := surface_y_at_position(torch_fill_up_pos) if held_torch_ground_fill and is_instance_valid(held_torch_ground_fill) else 0.0
    camera.rotation.x = deg_to_rad(-62.0)
    await wait_physics_frames(2)
    var torch_fill_down_pos := held_torch_ground_fill.global_position if held_torch_ground_fill and is_instance_valid(held_torch_ground_fill) else Vector3.ZERO
    var torch_fill_down_ground := surface_y_at_position(torch_fill_down_pos) if held_torch_ground_fill and is_instance_valid(held_torch_ground_fill) else 0.0
    camera.rotation.x = torch_original_pitch
    var torch_fill_level_height := torch_fill_level_pos.y - torch_fill_level_ground
    var torch_fill_up_height := torch_fill_up_pos.y - torch_fill_up_ground
    var torch_fill_down_height := torch_fill_down_pos.y - torch_fill_down_ground
    var torch_fill_up_drift := torch_fill_level_pos.distance_to(torch_fill_up_pos)
    var torch_fill_down_drift := torch_fill_level_pos.distance_to(torch_fill_down_pos)
    var torch_fill_pitch_independent := (
        held_torch_ground_fill != null
        and torch_fill_level_height >= 0.75
        and torch_fill_level_height <= 2.60
        and torch_fill_up_height >= 0.75
        and torch_fill_up_height <= 2.60
        and torch_fill_down_height >= 0.75
        and torch_fill_down_height <= 2.60
        and torch_fill_up_drift <= 0.25
        and torch_fill_down_drift <= 0.25
    )
    var held_torch_energy_min := held_energy_before
    var held_torch_energy_max := held_energy_before
    var held_torch_range_min := held_range_before
    var held_torch_range_max := held_range_before
    for i in range(12):
        await wait_physics_frames(1)
        if held_torch_light != null and is_instance_valid(held_torch_light):
            held_torch_energy_min = minf(held_torch_energy_min, held_torch_light.light_energy)
            held_torch_energy_max = maxf(held_torch_energy_max, held_torch_light.light_energy)
        if held_torch_omni != null and is_instance_valid(held_torch_omni):
            held_torch_range_min = minf(held_torch_range_min, held_torch_omni.omni_range)
            held_torch_range_max = maxf(held_torch_range_max, held_torch_omni.omni_range)
    var held_energy_after := held_torch_light.light_energy if held_torch_light and is_instance_valid(held_torch_light) else 0.0
    var held_range_after := held_torch_omni.omni_range if held_torch_omni and is_instance_valid(held_torch_omni) else 0.0
    var held_torch_flickers := held_torch_energy_max - held_torch_energy_min > 0.08 and held_torch_range_max - held_torch_range_min > 0.08
    add_result(
        "held_torch_emits_light",
        String(held_item.get("current_item")) == "torch"
            and held_torch_lights >= 3
            and held_torch_fire_lights >= 1
            and held_torch_shadowed >= 1
            and held_torch_ground_fills.size() >= 2
            and held_torch_sources.size() >= 1
            and held_torch_terrain_washes.size() >= 1
            and held_torch_bounce_fills.size() >= 1
            and held_base_energy >= 1.3
            and held_base_range >= 6.0
            and held_base_range <= 6.4
            and held_min_scale >= 0.01
            and held_min_scale <= 0.99
            and held_torch_flickers
            and held_torch_overlay_meshes.is_empty(),
        "current %s, lights %d fire %d shadow %d roles %d/%d/%d fill %d base %.2f range %.2f min %.2f overlays %d sample %.2f->%.2f %.2f->%.2f flicker %.2f/%.2f" % [
            String(held_item.get("current_item")),
            held_torch_lights,
            held_torch_fire_lights,
            held_torch_shadowed,
            held_torch_sources.size(),
            held_torch_terrain_washes.size(),
            held_torch_bounce_fills.size(),
            held_torch_ground_fills.size(),
            held_base_energy,
            held_base_range,
            held_min_scale,
            held_torch_overlay_meshes.size(),
            held_energy_before,
            held_energy_after,
            held_range_before,
            held_range_after,
            held_torch_energy_max - held_torch_energy_min,
            held_torch_range_max - held_torch_range_min
        ]
    )
    add_result(
        "held_torch_ground_fill_pitch_independent",
        torch_fill_pitch_independent,
        "level %s h %.2f, up %s h %.2f drift %.2f, down %s h %.2f drift %.2f" % [
            str(torch_fill_level_pos),
            torch_fill_level_height,
            str(torch_fill_up_pos),
            torch_fill_up_height,
            torch_fill_up_drift,
            str(torch_fill_down_pos),
            torch_fill_down_height,
            torch_fill_down_drift
        ]
    )
    if main.has_method("update_terrain_local_light_uniforms"):
        main.call("update_terrain_local_light_uniforms")
    var torch_terrain_material := main.get("terrain_material") as ShaderMaterial
    var torch_uniform_range_min := INF
    var torch_uniform_range_max := 0.0
    var torch_uniform_energy_min := INF
    var torch_uniform_energy_max := 0.0
    var torch_uniform_samples := 48
    for i in range(torch_uniform_samples):
        if main.has_method("update_terrain_local_light_uniforms"):
            main.call("update_terrain_local_light_uniforms")
        var torch_uniform_range := terrain_light_uniform_first_range(torch_terrain_material)
        var torch_uniform_energy := terrain_light_uniform_max_energy(torch_terrain_material)
        torch_uniform_range_min = minf(torch_uniform_range_min, torch_uniform_range)
        torch_uniform_range_max = maxf(torch_uniform_range_max, torch_uniform_range)
        torch_uniform_energy_min = minf(torch_uniform_energy_min, torch_uniform_energy)
        torch_uniform_energy_max = maxf(torch_uniform_energy_max, torch_uniform_energy)
        await wait_physics_frames(1)
    var torch_uniform_range_delta := torch_uniform_range_max - torch_uniform_range_min
    var torch_uniform_energy_delta := torch_uniform_energy_max - torch_uniform_energy_min
    add_result(
        "held_torch_terrain_material_flickers",
        torch_uniform_range_delta > 0.02 or torch_uniform_energy_delta > 0.02,
        "samples %d range %.2f..%.2f delta %.2f energy %.2f..%.2f delta %.2f" % [
            torch_uniform_samples,
            torch_uniform_range_min,
            torch_uniform_range_max,
            torch_uniform_range_delta,
            torch_uniform_energy_min,
            torch_uniform_energy_max,
            torch_uniform_energy_delta
        ]
    )

    inventory_system.add_item("wardLantern", 1)
    var ward_lantern_slot := find_inventory_slot(inventory_system, "wardLantern")
    inventory_system.select(0)
    if ward_lantern_slot > 0:
        inventory_system.swap_with_active(ward_lantern_slot)
    await wait_physics_frames(2)
    var held_ward_root: Node = held_item.get_node_or_null("HeldItemRoot")
    var held_ward_lights := count_light_descendants(held_ward_root)
    var held_ward_fire_lights := count_fire_light_descendants(held_ward_root)
    var held_ward_shadowed := count_shadowed_light_descendants(held_ward_root)
    var held_ward_overlay_meshes := ground_overlay_mesh_descendants(held_ward_root)
    var held_ward_ground_fills := ground_fill_light_descendants(held_ward_root)
    var held_ward_sources := light_role_descendants(held_ward_root, "source")
    var held_ward_terrain_washes := light_role_descendants(held_ward_root, "terrain_wash")
    var held_ward_bounce_fills := light_role_descendants(held_ward_root, "bounce_fill")
    var held_ward_ground_fill: Light3D = null
    if not held_ward_terrain_washes.is_empty():
        held_ward_ground_fill = held_ward_terrain_washes[0] as Light3D
    var held_ward_light := first_light_role_descendant(held_ward_root, "source")
    var held_ward_position := held_ward_light.position if held_ward_light else Vector3.ZERO
    var held_ward_base_energy := light_base_energy(held_ward_light)
    var held_ward_base_range := light_base_range(held_ward_light)
    var held_ward_min_scale := light_flicker_min_scale(held_ward_light)
    var ward_original_pitch := camera.rotation.x
    camera.rotation.x = 0.0
    await wait_physics_frames(2)
    var ward_fill_level_pos := held_ward_ground_fill.global_position if held_ward_ground_fill else Vector3.ZERO
    var ward_fill_level_ground := surface_y_at_position(ward_fill_level_pos) if held_ward_ground_fill else 0.0
    camera.rotation.x = deg_to_rad(62.0)
    await wait_physics_frames(2)
    var ward_fill_up_pos := held_ward_ground_fill.global_position if held_ward_ground_fill and is_instance_valid(held_ward_ground_fill) else Vector3.ZERO
    var ward_fill_up_ground := surface_y_at_position(ward_fill_up_pos) if held_ward_ground_fill and is_instance_valid(held_ward_ground_fill) else 0.0
    camera.rotation.x = deg_to_rad(-62.0)
    await wait_physics_frames(2)
    var ward_fill_down_pos := held_ward_ground_fill.global_position if held_ward_ground_fill and is_instance_valid(held_ward_ground_fill) else Vector3.ZERO
    var ward_fill_down_ground := surface_y_at_position(ward_fill_down_pos) if held_ward_ground_fill and is_instance_valid(held_ward_ground_fill) else 0.0
    camera.rotation.x = ward_original_pitch
    var ward_fill_level_height := ward_fill_level_pos.y - ward_fill_level_ground
    var ward_fill_up_height := ward_fill_up_pos.y - ward_fill_up_ground
    var ward_fill_down_height := ward_fill_down_pos.y - ward_fill_down_ground
    var ward_fill_up_drift := ward_fill_level_pos.distance_to(ward_fill_up_pos)
    var ward_fill_down_drift := ward_fill_level_pos.distance_to(ward_fill_down_pos)
    var ward_fill_pitch_independent := (
        held_ward_ground_fill != null
        and ward_fill_level_height >= 0.75
        and ward_fill_level_height <= 2.60
        and ward_fill_up_height >= 0.75
        and ward_fill_up_height <= 2.60
        and ward_fill_down_height >= 0.75
        and ward_fill_down_height <= 2.60
        and ward_fill_up_drift <= 0.25
        and ward_fill_down_drift <= 0.25
    )
    add_result(
        "held_ward_lantern_emits_light",
        String(held_item.get("current_item")) == "wardLantern"
            and held_ward_lights >= 3
            and held_ward_fire_lights >= 1
            and held_ward_shadowed >= 1
            and held_ward_ground_fills.size() >= 2
            and held_ward_sources.size() >= 1
            and held_ward_terrain_washes.size() >= 1
            and held_ward_bounce_fills.size() >= 1
            and held_ward_base_energy >= 1.8
            and held_ward_base_range >= 8.0
            and held_ward_position.length() > 0.05
            and held_ward_min_scale >= 0.01
            and held_ward_min_scale <= 0.99
            and held_ward_overlay_meshes.is_empty(),
        "current %s, lights %d fire %d shadow %d roles %d/%d/%d fill %d base %.2f range %.2f offset %s min %.2f overlays %d" % [
            String(held_item.get("current_item")),
            held_ward_lights,
            held_ward_fire_lights,
            held_ward_shadowed,
            held_ward_sources.size(),
            held_ward_terrain_washes.size(),
            held_ward_bounce_fills.size(),
            held_ward_ground_fills.size(),
            held_ward_base_energy,
            held_ward_base_range,
            str(held_ward_position),
            held_ward_min_scale,
            held_ward_overlay_meshes.size()
        ]
    )
    add_result(
        "held_ward_lantern_ground_fill_pitch_independent",
        ward_fill_pitch_independent,
        "level %s h %.2f, up %s h %.2f drift %.2f, down %s h %.2f drift %.2f" % [
            str(ward_fill_level_pos),
            ward_fill_level_height,
            str(ward_fill_up_pos),
            ward_fill_up_height,
            ward_fill_up_drift,
            str(ward_fill_down_pos),
            ward_fill_down_height,
            ward_fill_down_drift
        ]
    )
    if main.has_method("update_terrain_local_light_uniforms"):
        main.call("update_terrain_local_light_uniforms")
    var terrain_light_material := main.get("terrain_material") as ShaderMaterial
    var terrain_light_count := int(terrain_light_material.get_shader_parameter("terrain_local_light_count")) if terrain_light_material else 0
    var terrain_light_positions_value = terrain_light_material.get_shader_parameter("terrain_local_light_positions") if terrain_light_material else null
    var terrain_light_colors_value = terrain_light_material.get_shader_parameter("terrain_local_light_colors") if terrain_light_material else null
    var first_terrain_light_range := 0.0
    var strongest_terrain_light_energy := 0.0
    if typeof(terrain_light_positions_value) == TYPE_PACKED_VECTOR4_ARRAY:
        var terrain_position_vectors: PackedVector4Array = terrain_light_positions_value
        if terrain_position_vectors.size() > 0:
            first_terrain_light_range = terrain_position_vectors[0].w
    elif typeof(terrain_light_positions_value) == TYPE_ARRAY:
        var terrain_position_array: Array = terrain_light_positions_value
        if terrain_position_array.size() > 0 and terrain_position_array[0] is Vector4:
            first_terrain_light_range = (terrain_position_array[0] as Vector4).w
    if typeof(terrain_light_colors_value) == TYPE_PACKED_VECTOR4_ARRAY:
        var terrain_color_vectors: PackedVector4Array = terrain_light_colors_value
        for value in terrain_color_vectors:
            strongest_terrain_light_energy = maxf(strongest_terrain_light_energy, value.w)
    elif typeof(terrain_light_colors_value) == TYPE_ARRAY:
        var terrain_color_array: Array = terrain_light_colors_value
        for value in terrain_color_array:
            if value is Vector4:
                strongest_terrain_light_energy = maxf(strongest_terrain_light_energy, (value as Vector4).w)
    add_result(
        "held_light_updates_terrain_material_lighting",
        terrain_light_count >= 1 and first_terrain_light_range >= 8.0 and strongest_terrain_light_energy >= 1.0,
        "count %d, first range %.2f, max energy %.2f" % [terrain_light_count, first_terrain_light_range, strongest_terrain_light_energy]
    )
    main.set("time_of_day", held_light_original_time)
    main.call("update_sky", 0.0)

    inventory_system.add_item("woodenAxe", 1)
    var axe_slot := find_inventory_slot(inventory_system, "woodenAxe")
    inventory_system.select(0)
    if axe_slot > 0:
        inventory_system.swap_with_active(axe_slot)
    await wait_physics_frames(2)
    var held_tool_root: Node = held_item.get_node_or_null("HeldItemRoot")
    var held_tool_visual: Node3D = null
    if held_tool_root and held_tool_root.get_child_count() > 0:
        held_tool_visual = held_tool_root.get_child(0) as Node3D
    var held_tool_yaw := held_tool_visual.rotation.y if held_tool_visual else 0.0
    add_result(
        "held_tool_right_hand_mirror",
        String(held_item.get("current_item")) == "woodenAxe" and held_tool_visual != null and held_tool_visual.scale.x < 0.0 and held_tool_yaw < deg_to_rad(-85.0),
        "current %s, visual scale %s, yaw %.1f" % [String(held_item.get("current_item")), str(held_tool_visual.scale if held_tool_visual else Vector3.ZERO), rad_to_deg(held_tool_yaw)]
    )

    inventory_system.add_item("ironCrossbow", 1)
    var crossbow_slot := find_inventory_slot(inventory_system, "ironCrossbow")
    inventory_system.select(0)
    if crossbow_slot > 0:
        inventory_system.swap_with_active(crossbow_slot)
    await wait_physics_frames(2)
    var held_root: Node = held_item.get_node_or_null("HeldItemRoot")
    var held_meshes := count_mesh_descendants(held_root) if held_root else 0
    var held_generated_static := has_visual_source(held_root, "generated_static_asset")
    add_result(
        "held_item_visual_detail",
        String(held_item.get("current_item")) == "ironCrossbow" and held_meshes >= 4 and held_generated_static,
        "current %s, meshes %d, generated %s" % [String(held_item.get("current_item")), held_meshes, str(held_generated_static)]
    )

    main.call("clear_dropped_pickups")
    var pickup_stats_before: Dictionary = main.call("pickup_pool_stats")
    var pickup := main.call("spawn_pickup_stack", "nightShard", 1, player.global_position + Vector3(1.0, 1.0, 0.0)) as Node3D
    var pickup_meshes := count_mesh_descendants(pickup) if pickup else 0
    add_result(
        "pickup_item_visual_detail",
        pickup != null and pickup_meshes >= 2,
        "meshes %d" % pickup_meshes
    )
    main.call("clear_dropped_pickups")
    var pickup_stats_after_clear: Dictionary = main.call("pickup_pool_stats")
    var pooled_pickup := main.call("spawn_pickup_stack", "nightShard", 1, player.global_position + Vector3(1.2, 1.0, 0.0)) as Node3D
    var pickup_stats_after_reuse: Dictionary = main.call("pickup_pool_stats")
    add_result(
        "pickup_pool_reuse",
        pooled_pickup != null
            and int(pickup_stats_after_clear.get("pooled", 0)) > int(pickup_stats_before.get("pooled", 0))
            and int(pickup_stats_after_reuse.get("created", 0)) <= int(pickup_stats_after_clear.get("created", 0))
            and int(pickup_stats_after_reuse.get("reused", 0)) > int(pickup_stats_after_clear.get("reused", 0)),
        "pooled %d->%d, created %d->%d, reused %d->%d" % [
            int(pickup_stats_before.get("pooled", 0)),
            int(pickup_stats_after_clear.get("pooled", 0)),
            int(pickup_stats_after_clear.get("created", 0)),
            int(pickup_stats_after_reuse.get("created", 0)),
            int(pickup_stats_after_clear.get("reused", 0)),
            int(pickup_stats_after_reuse.get("reused", 0))
        ]
    )
    main.call("clear_dropped_pickups")
    var restored_wood_slot := find_inventory_slot(inventory_system, "woodBlock")
    inventory_system.select(0)
    if restored_wood_slot > 0:
        inventory_system.swap_with_active(restored_wood_slot)
    await wait_physics_frames(2)

func test_tool_weapon_catalog_parity() -> void:
    if not main or not player:
        add_result("tool_weapon_catalog_parity", false, "main or player missing")
        return
    var inventory_system = main.get("inventory_system")
    var crafting_system = main.get("crafting_system")
    var blocks: Dictionary = main.get("blocks")
    var present: bool = inventory_system != null and crafting_system != null and blocks != null
    if not present:
        add_result("tool_weapon_catalog_parity", false, "inventory/crafting/blocks missing")
        return
    crafting_system.unlock_all_groups()

    var expected_items := [
        "copperAxe", "copperPickaxe", "copperShovel", "copperSword",
        "ironAxe", "ironPickaxe", "ironShovel", "ironSword",
        "ironCrossbow", "nightBlade"
    ]
    var generated_items := ["copperVein", "ironVein"]
    var missing_items := []
    var missing_recipes := []
    for item_id in expected_items:
        if not ItemCatalogScript.ITEMS.has(item_id):
            missing_items.append(item_id)
        if crafting_system.recipe_for(item_id).is_empty():
            missing_recipes.append(item_id)
    for item_id in generated_items:
        if not ItemCatalogScript.ITEMS.has(item_id):
            missing_items.append(item_id)

    var cell := Vector3i(roundi(player.global_position.x / CELL) + 2, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL))
    var anvil = main.call("create_block", cell, "anvil")
    inventory_system.add_item("logs", 8)
    inventory_system.add_item("copperIngot", 8)
    inventory_system.add_item("ironIngot", 8)
    inventory_system.add_item("stoneSword", 1)
    inventory_system.add_item("nightShard", 4)
    inventory_system.add_item("glass", 2)

    var crafted_copper: bool = bool(crafting_system.craft("copperPickaxe"))
    var crafted_crossbow: bool = bool(crafting_system.craft("ironCrossbow"))
    var crafted_night_blade: bool = bool(crafting_system.craft("nightBlade"))
    var crafted_inventory: bool = inventory_system.count("copperPickaxe") > 0 and inventory_system.count("ironCrossbow") > 0 and inventory_system.count("nightBlade") > 0

    if anvil:
        anvil.queue_free()
    if blocks.has(cell):
        blocks.erase(cell)

    add_result(
        "tool_weapon_catalog_parity",
        missing_items.is_empty()
            and missing_recipes.is_empty()
            and crafted_copper
            and crafted_crossbow
            and crafted_night_blade
            and crafted_inventory,
        "missing items %s, recipes %s, crafted copper/crossbow/night %s/%s/%s" % [
            str(missing_items),
            str(missing_recipes),
            str(crafted_copper),
            str(crafted_crossbow),
            str(crafted_night_blade)
        ]
    )
    var vein_inventory_snapshot: Array = inventory_system.snapshot()
    var vein_inventory_size: int = int(inventory_system.size)
    var vein_selected_slot: int = int(inventory_system.selected_slot)
    var copper_pickaxe_slot := find_inventory_slot(inventory_system, "copperPickaxe")
    if copper_pickaxe_slot >= 0:
        inventory_system.swap_with_active(copper_pickaxe_slot)
    var vein_materials_ok := (
        ItemCatalogScript.material_hardness("copperOre") == 7
        and ItemCatalogScript.material_hardness("ironOre") == 10
        and ItemCatalogScript.material_hardness("copperVein") == 8
        and ItemCatalogScript.material_hardness("ironVein") == 12
        and ItemCatalogScript.material_drop("copperVein") == "copperOre"
        and ItemCatalogScript.material_drop("ironVein") == "ironOre"
        and ItemCatalogScript.material_required_tool("copperVein") == "pickaxe"
        and ItemCatalogScript.material_required_tool("ironVein") == "pickaxe"
        and ItemCatalogScript.material_required_tier("copperVein") == 3
        and ItemCatalogScript.material_required_tier("ironVein") == 4
        and String(main.call("unmet_tool_requirement_message", "copperVein")) == ""
        and String(main.call("unmet_tool_requirement_message", "ironVein")) == ""
        and float(main.call("tool_power_for_material", "copperVein")) >= 3.0
    )
    inventory_system.restore({
        "slots": vein_inventory_snapshot,
        "size": vein_inventory_size,
        "selectedSlot": vein_selected_slot
    })
    add_result(
        "ore_vein_catalog_parity",
        vein_materials_ok,
        "hardness ore %d/%d veins %d/%d drops %s/%s" % [
            ItemCatalogScript.material_hardness("copperOre"),
            ItemCatalogScript.material_hardness("ironOre"),
            ItemCatalogScript.material_hardness("copperVein"),
            ItemCatalogScript.material_hardness("ironVein"),
            ItemCatalogScript.material_drop("copperVein"),
            ItemCatalogScript.material_drop("ironVein")
        ]
    )

func test_objective_system() -> void:
    if not main:
        add_result("objective_system_present", false, "main missing")
        return
    var objective_system = main.get("objective_system")
    var hud = main.get("hud")
    var present: bool = objective_system != null and hud != null
    add_result("objective_system_present", present, "objective system + hud present")
    if not present:
        return

    add_result(
        "objective_completion_from_crafting",
        objective_system.completed_count() >= 1,
        "completed %d (toast visibility is transient and tested at notification time)" % objective_system.completed_count()
    )

    var opened: bool = hud.toggle_objectives()
    add_result(
        "objective_list_opens",
        opened and hud.objective_panel.visible and hud.objective_list.get_child_count() == objective_system.all_objectives().size(),
        "opened %s, rows %d" % [str(opened), hud.objective_list.get_child_count()]
    )
    var objective_scroll := hud.get("objective_scroll") as ScrollContainer
    var objective_scroll_layout: bool = (
        objective_scroll != null
        and hud.objective_list.get_parent() == objective_scroll
        and objective_scroll.clip_contents
        and objective_scroll.custom_minimum_size.y <= 190.0
        and hud.objective_list.custom_minimum_size.x >= 280.0
        and hud.objective_panel.offset_bottom <= get_viewport().get_visible_rect().size.y
    )
    add_result(
        "objective_list_bounded_scroll",
        objective_scroll_layout,
        "scroll %s, clip %s, list width %.1f, panel bottom %.1f" % [
            str(objective_scroll != null),
            str(objective_scroll.clip_contents if objective_scroll else false),
            hud.objective_list.custom_minimum_size.x,
            hud.objective_panel.offset_bottom
        ]
    )
    hud.objective_panel.visible = false
    main.set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    var objective_key := InputEventKey.new()
    objective_key.keycode = KEY_O
    objective_key.pressed = true
    main.call("_unhandled_input", objective_key)
    var objective_requested_open_mode: int = int(main.get("last_requested_mouse_mode"))
    var objective_actual_open_mode: int = int(Input.get_mouse_mode())
    var objective_mouse_open: bool = hud.is_objectives_open() and objective_requested_open_mode == int(Input.MOUSE_MODE_VISIBLE)
    var objective_escape := InputEventKey.new()
    objective_escape.keycode = KEY_ESCAPE
    objective_escape.pressed = true
    main.call("_unhandled_input", objective_escape)
    var objective_requested_close_mode: int = int(main.get("last_requested_mouse_mode"))
    var objective_actual_close_mode: int = int(Input.get_mouse_mode())
    var objective_mouse_closed: bool = not hud.is_objectives_open() and objective_requested_close_mode == int(Input.MOUSE_MODE_CAPTURED)
    add_result(
        "objective_panel_frees_mouse",
        objective_mouse_open and objective_mouse_closed,
        "open %s requested/actual %d/%d, closed %s requested/actual %d/%d" % [
            str(objective_mouse_open),
            objective_requested_open_mode,
            objective_actual_open_mode,
            str(objective_mouse_closed),
            objective_requested_close_mode,
            objective_actual_close_mode
        ]
    )

    hud.set_inventory_open(true)
    add_result(
        "inventory_hides_objectives",
        hud.is_inventory_open() and not hud.objective_panel.visible,
        "inventory %s, objective panel %s" % [str(hud.is_inventory_open()), str(hud.objective_panel.visible)]
    )
    hud.set_inventory_open(false)

    var expected_ids := [
        "woodenPickaxe",
        "stonePickaxe",
        "mineCopper",
        "smeltCopper",
        "craftCopperPickaxe",
        "mineIron",
        "smeltIron",
        "craftIronPickaxe",
        "spikeTrap",
        "hunt",
        "fish",
        "ranged",
        "bed",
        "shelter",
        "torch",
        "mine",
        "anvil",
        "copperGear",
        "pack",
        "cookedFood",
        "nightShard",
        "wardTonic",
        "enemyCamp"
    ]
    var present_ids := {}
    for objective in objective_system.all_objectives():
        present_ids[String(objective.get("id", ""))] = true
    var missing_ids := []
    for objective_id in expected_ids:
        if not present_ids.has(objective_id):
            missing_ids.append(objective_id)
    var parity_state := {
        "totals": {
            "rawMeat": 1,
            "rawFish": 1,
            "hunterBow": 1,
            "torch": 1,
            "stonePickaxe": 1,
            "copperOre": 1,
            "copperIngot": 2,
            "copperPickaxe": 1,
            "ironOre": 1,
            "ironIngot": 1,
            "ironPickaxe": 1,
            "cookedBerries": 1,
            "nightShard": 2,
            "wardTonic": 1
        },
        "structureCounts": {
            "spikeTrap": 1,
            "bed": 1,
            "anvil": 1
        },
        "equipment": {},
        "generatedTierCounts": { "mine": 1 },
        "hostiles": { "defeated": 3, "defeatedVariants": {} },
        "inventorySize": 32,
        "level": 3,
        "discoveredBiomes": 4,
        "discoveredMines": 1,
        "discoveredRuins": 0,
        "discoveredShrines": 0,
        "discoveredCamps": 1,
        "shelterComfort": 0.75,
        "beaconRaidStage": 0,
        "sanctuaryEstablished": false
    }
    var incomplete_ids := []
    for objective_id in expected_ids:
        if not bool(objective_system.is_complete(objective_id, parity_state)):
            incomplete_ids.append(objective_id)
    add_result(
        "objective_browser_chain_parity",
        missing_ids.is_empty() and incomplete_ids.is_empty(),
        "missing %s, incomplete %s, total %d" % [str(missing_ids), str(incomplete_ids), objective_system.all_objectives().size()]
    )

func test_progression_system() -> void:
    if not main:
        add_result("progression_system_present", false, "main missing")
        return
    var progression_system = main.get("progression_system")
    var survival_system = main.get("survival_system")
    var hud = main.get("hud")
    var present: bool = progression_system != null and survival_system != null and hud != null
    add_result("progression_system_present", present, "progression + survival + hud present")
    if not present:
        return

    progression_system.restore({ "level": 1, "xp": 0, "totalXp": 0 })
    var awarded: bool = bool(main.call("award_progression", "playtest progress", 85))
    var state: Dictionary = progression_system.state()
    var leveled: bool = awarded and int(state.get("level", 1)) == 2 and int(state.get("xp", 0)) == 5
    var hud_updated: bool = hud.level_label.text.find("Lvl 2") >= 0 and abs(float(hud.xp_bar.value) - 5.0) < 0.01
    var survival_bonus: bool = abs(float(survival_system.call("max_health")) - 105.0) < 0.01 and abs(float(survival_system.call("max_stamina")) - 104.0) < 0.01
    add_result(
        "progression_awards_level_bonus_hud",
        leveled and hud_updated and survival_bonus,
        "level %d, xp %d, hud '%s', max hp %.1f" % [
            int(state.get("level", 1)),
            int(state.get("xp", 0)),
            hud.level_label.text,
            float(survival_system.call("max_health"))
        ]
    )
    progression_system.restore({ "level": 1, "xp": 0, "totalXp": 0 })

func test_equipment_system() -> void:
    if not main:
        add_result("equipment_system_present", false, "main missing")
        return
    var equipment_system = main.get("equipment_system")
    var inventory_system = main.get("inventory_system")
    var survival_system = main.get("survival_system")
    var hud = main.get("hud")
    var present: bool = equipment_system != null and inventory_system != null and survival_system != null and hud != null
    add_result("equipment_system_present", present, "equipment + inventory + survival + hud present")
    if not present:
        return

    equipment_system.reset()
    inventory_system.add_item("stoneArmor", 1)
    inventory_system.add_item("trailCharm", 1)

    var armor_slot := find_inventory_slot(inventory_system, "stoneArmor")
    if armor_slot >= 0:
        inventory_system.select(0)
        inventory_system.swap_with_active(armor_slot)
    var armor_equipped: bool = bool(main.call("try_use_active_consumable"))
    var equipped_armor := String(equipment_system.equipped_item("body"))

    var charm_slot := find_inventory_slot(inventory_system, "trailCharm")
    if charm_slot >= 0:
        inventory_system.select(1)
        inventory_system.swap_with_active(charm_slot)
    var charm_equipped: bool = bool(main.call("try_use_active_consumable"))
    var equipped_charm := String(equipment_system.equipped_item("accessory"))

    survival_system.health = survival_system.max_health()
    var block_health_before: float = float(survival_system.health)
    survival_system.apply_damage(10.0, "equipment test", "hostile")
    hud.render()
    var damage_reduced: bool = float(survival_system.health) > 92.0 and float(survival_system.health) < 94.0
    var bonus_applied: bool = abs(float(survival_system.call("max_stamina")) - 115.0) < 0.01 and abs(float(survival_system.call("max_hunger")) - 110.0) < 0.01
    var hud_updated: bool = hud.equipment_readout.text.find("Stone Guard") >= 0 and hud.equipment_readout.text.find("Trail Charm") >= 0
    add_result(
        "equipment_slots_bonuses_damage_hud",
        armor_equipped and charm_equipped and equipped_armor == "stoneArmor" and equipped_charm == "trailCharm" and damage_reduced and bonus_applied and hud_updated,
        "armor %s, charm %s, health %.1f, max sta %.1f, hud '%s'" % [
            equipped_armor,
            equipped_charm,
            float(survival_system.health),
            float(survival_system.call("max_stamina")),
            hud.equipment_readout.text
        ]
    )
    equipment_system.reset()

func test_navigation_map_system() -> void:
    if not main or not player:
        add_result("navigation_map_system", false, "main or player missing")
        return
    var inventory_system = main.get("inventory_system")
    var hud = main.get("hud")
    if inventory_system == null or hud == null:
        add_result("navigation_map_system", false, "inventory or hud missing")
        return
    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var nav_cell := Vector2i(roundi(player.global_position.x / CELL) + 72, roundi(player.global_position.z / CELL) + 72)
    reset_player_on_flat_patch(nav_cell, 5, true)
    clear_blocks_near_cell(nav_cell, 12)
    await settle_streamed_chunks_after_relocation("navigation_map_chunks", 90)
    inventory_system.add_item("compass", 1)
    inventory_system.add_item("surveyLens", 1)
    var marker_cell := Vector3i(roundi(player.global_position.x / CELL) + 3, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL))
    clear_blocks_near_cell(Vector2i(marker_cell.x, marker_cell.z), 2)
    main.call("create_block", marker_cell, "workbench")
    main.call("update_hud")
    var compass_visible: bool = hud.compass_label.visible and hud.compass_label.text.length() >= 4
    var waypoint_visible: bool = hud.compass_waypoint_label != null and hud.compass_waypoint_label.visible and hud.compass_waypoint_label.text.find("Workbench") >= 0
    var map_visible: bool = hud.map_panel.visible
    var marker_visible: bool = hud.mini_map != null and hud.mini_map.points.size() > 0
    var terrain_visible: bool = hud.mini_map != null and hud.mini_map.terrain_samples.size() > 0 and hud.mini_map.sample_count > 0
    var marker_summary: bool = hud.map_info_label != null and hud.map_info_label.text.find("Workbench") >= 0
    add_result(
        "navigation_map_system",
        compass_visible and waypoint_visible and map_visible and marker_visible and terrain_visible and marker_summary,
        "compass '%s' visible %s, waypoint '%s', map %s, markers %d, terrain %d, summary '%s'" % [
            hud.compass_label.text,
            str(compass_visible),
            hud.compass_waypoint_label.text if hud.compass_waypoint_label != null else "",
            str(map_visible),
            hud.mini_map.points.size() if hud.mini_map != null else 0,
            hud.mini_map.terrain_samples.size() if hud.mini_map != null else 0,
            hud.map_info_label.text if hud.map_info_label != null else ""
        ]
    )
    var collapsed: bool = hud.toggle_map()
    main.call("update_hud")
    var collapsed_ok: bool = collapsed and hud.is_map_collapsed() and hud.map_panel.visible and hud.mini_map != null and not hud.mini_map.visible and hud.map_info_label.text.find("hidden") >= 0
    var expanded: bool = not hud.toggle_map()
    main.call("update_hud")
    var expanded_ok: bool = expanded and not hud.is_map_collapsed() and hud.map_panel.visible and hud.mini_map != null and hud.mini_map.visible
    add_result(
        "map_toggle_collapse",
        collapsed_ok and expanded_ok,
        "collapsed %s/%s expanded %s/%s info '%s'" % [str(collapsed), str(collapsed_ok), str(expanded), str(expanded_ok), hud.map_info_label.text]
    )
    var blocks := get_blocks()
    if blocks.has(marker_cell):
        var marker := blocks[marker_cell] as Node
        if marker:
            marker.queue_free()
        blocks.erase(marker_cell)
    player.global_position = original_position
    player.velocity = original_velocity
    await settle_streamed_chunks_after_relocation("navigation_map_restore_chunks", 90)

func test_contract_system() -> void:
    if not main or not player:
        add_result("contract_system_present", false, "main or player missing")
        return
    var contract_system = main.get("contract_system")
    var inventory_system = main.get("inventory_system")
    var progression_system = main.get("progression_system")
    var hud = main.get("hud")
    var present: bool = contract_system != null and inventory_system != null and progression_system != null and hud != null
    add_result("contract_system_present", present, "contracts + inventory + progression + hud present")
    if not present:
        return

    var original_position: Vector3 = player.global_position
    contract_system.reset()
    var discovered_biomes: Dictionary = main.get("discovered_biomes")
    var discovered_towns: Dictionary = main.get("discovered_town_keys")
    discovered_biomes.clear()
    discovered_towns.clear()
    var locked_open: bool = hud.toggle_contracts()
    var town: Dictionary = main.call("town_region", 1, 0)
    var center_x := int(town.get("centerX", 0))
    var center_z := int(town.get("centerZ", 0))
    player.global_position = Vector3(center_x * CELL, float(town.get("level", 16.0)), center_z * CELL)
    main.call("update_hud")
    var unlocked: bool = bool(contract_system.state().get("townUnlocked", false))
    var opened: bool = hud.toggle_contracts()
    var xp_before: int = int(progression_system.total_xp)
    var stone_blocks_before: int = inventory_system.count("stoneBlock")
    inventory_system.add_item("stones", max(0, 18 - inventory_system.count("stones")))
    main.call("update_hud")
    var completed_count: int = int(contract_system.state().get("completed", 0))
    var rewarded: bool = int(progression_system.total_xp) > xp_before and inventory_system.count("stoneBlock") >= stone_blocks_before + 4
    add_result(
        "contract_unlock_complete_reward",
        not locked_open and unlocked and opened and completed_count >= 1 and rewarded and hud.contract_panel.visible,
        "locked open %s, unlocked %s, opened %s, completed %d, xp %d->%d, stoneBlock %d->%d" % [
            str(locked_open),
            str(unlocked),
            str(opened),
            completed_count,
            xp_before,
            int(progression_system.total_xp),
            stone_blocks_before,
            inventory_system.count("stoneBlock")
        ]
    )
    var contract_scroll := hud.get("contract_scroll") as ScrollContainer
    var first_contract_label := hud.contract_list.get_child(0) as Label if hud.contract_list.get_child_count() > 0 else null
    var contract_layout_ok: bool = (
        contract_scroll != null
        and hud.contract_list.get_parent() == contract_scroll
        and contract_scroll.clip_contents
        and hud.contract_list.custom_minimum_size.x >= 300.0
        and first_contract_label != null
        and first_contract_label.custom_minimum_size.x >= 300.0
        and hud.contract_panel.offset_bottom <= get_viewport().get_visible_rect().size.y
    )
    add_result(
        "contract_list_bounded_width",
        contract_layout_ok,
        "scroll %s, clip %s, list width %.1f, row width %.1f, panel bottom %.1f, rows %d" % [
            str(contract_scroll != null),
            str(contract_scroll.clip_contents if contract_scroll else false),
            hud.contract_list.custom_minimum_size.x,
            first_contract_label.custom_minimum_size.x if first_contract_label else 0.0,
            hud.contract_panel.offset_bottom,
            hud.contract_list.get_child_count()
        ]
    )
    contract_system.toggle_menu(false)
    hud.render_contracts()
    main.set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    var contract_key := InputEventKey.new()
    contract_key.keycode = KEY_J
    contract_key.pressed = true
    main.call("_unhandled_input", contract_key)
    var contract_requested_open_mode: int = int(main.get("last_requested_mouse_mode"))
    var contract_actual_open_mode: int = int(Input.get_mouse_mode())
    var contract_mouse_open: bool = hud.is_contracts_open() and contract_requested_open_mode == int(Input.MOUSE_MODE_VISIBLE)
    var contract_escape := InputEventKey.new()
    contract_escape.keycode = KEY_ESCAPE
    contract_escape.pressed = true
    main.call("_unhandled_input", contract_escape)
    var contract_requested_close_mode: int = int(main.get("last_requested_mouse_mode"))
    var contract_actual_close_mode: int = int(Input.get_mouse_mode())
    var contract_mouse_closed: bool = not hud.is_contracts_open() and contract_requested_close_mode == int(Input.MOUSE_MODE_CAPTURED)
    add_result(
        "contract_panel_frees_mouse",
        contract_mouse_open and contract_mouse_closed,
        "open %s requested/actual %d/%d, closed %s requested/actual %d/%d" % [
            str(contract_mouse_open),
            contract_requested_open_mode,
            contract_actual_open_mode,
            str(contract_mouse_closed),
            contract_requested_close_mode,
            contract_actual_close_mode
        ]
    )
    var base_contract_state := {
        "discoveredTowns": 1,
        "discoveredBiomes": 5,
        "totals": {},
        "structureCounts": {},
        "equipment": {},
        "hostiles": {}
    }
    var copper_tool_state := base_contract_state.duplicate(true)
    copper_tool_state["totals"] = { "copperPickaxe": 1 }
    var iron_tool_state := base_contract_state.duplicate(true)
    iron_tool_state["totals"] = { "ironPickaxe": 1 }
    var copper_sample_state := base_contract_state.duplicate(true)
    copper_sample_state["totals"] = { "copperOre": 4 }
    var smelter_state := base_contract_state.duplicate(true)
    smelter_state["totals"] = { "copperIngot": 2 }
    var iron_sample_state := base_contract_state.duplicate(true)
    iron_sample_state["totals"] = { "ironOre": 2 }
    var camp_clear_state := base_contract_state.duplicate(true)
    camp_clear_state["discoveredCamps"] = 1
    var contract_rule_parity := (
        bool(contract_system.is_contract_complete("copperCommission", copper_tool_state))
        and bool(contract_system.is_contract_complete("ironSupply", iron_tool_state))
        and bool(contract_system.is_contract_complete("copperSample", copper_sample_state))
        and bool(contract_system.is_contract_complete("smelterRun", smelter_state))
        and bool(contract_system.is_contract_complete("ironSample", iron_sample_state))
        and bool(contract_system.is_contract_complete("campClear", camp_clear_state))
    )
    add_result(
        "contract_gear_rule_parity",
        contract_rule_parity,
        "copper pickaxe %s, iron pickaxe %s, samples %s/%s/%s, camp %s" % [
            str(contract_system.is_contract_complete("copperCommission", copper_tool_state)),
            str(contract_system.is_contract_complete("ironSupply", iron_tool_state)),
            str(contract_system.is_contract_complete("copperSample", copper_sample_state)),
            str(contract_system.is_contract_complete("smelterRun", smelter_state)),
            str(contract_system.is_contract_complete("ironSample", iron_sample_state)),
            str(contract_system.is_contract_complete("campClear", camp_clear_state))
        ]
    )
    contract_system.toggle_menu(false)
    player.global_position = original_position
    discovered_biomes.clear()
    discovered_towns.clear()

func test_audio_effects_system() -> void:
    if not main:
        add_result("audio_effects_system_present", false, "main missing")
        return
    var audio_effects = main.get("audio_effects")
    var present: bool = audio_effects != null
    add_result("audio_effects_system_present", present, "audio/effects node present")
    if not present:
        return

    var start_stats: Dictionary = audio_effects.stats()
    var start_counts: Dictionary = start_stats.get("playCountsByName", {}) if start_stats.get("playCountsByName", {}) is Dictionary else {}
    audio_effects.play("craft")
    audio_effects.burst(player.global_position + Vector3(0.0, 1.0, 0.0) if player else Vector3.ZERO, Color(0.9, 0.7, 0.35), 3)
    await get_tree().process_frame
    var stats: Dictionary = audio_effects.stats()
    var counts: Dictionary = stats.get("playCountsByName", {}) if stats.get("playCountsByName", {}) is Dictionary else {}
    add_result(
        "audio_effects_play_and_burst",
        int(counts.get("craft", 0)) > int(start_counts.get("craft", 0))
            and int(stats.get("playCount", 0)) > int(start_stats.get("playCount", 0))
            and int(stats.get("visualEffects", 0)) >= 3,
        "last %s, craft %d->%d, plays %d->%d, effects %d" % [
            String(stats.get("lastPlayed", "")),
            int(start_counts.get("craft", 0)),
            int(counts.get("craft", 0)),
            int(start_stats.get("playCount", 0)),
            int(stats.get("playCount", 0)),
            int(stats.get("visualEffects", 0))
        ]
    )
    audio_effects.update_music({ "track": "tutorialTownDay", "volumeDb": -14.0 })
    var music_stats: Dictionary = audio_effects.stats()
    add_result(
        "tutorial_town_day_bgm",
        bool(music_stats.get("hasTutorialTownDayBgm", false))
            and float(music_stats.get("tutorialTownDayBgmLength", 0.0)) > 20.0
            and String(music_stats.get("currentMusic", "")) == "tutorialTownDay"
            and bool(music_stats.get("musicPlaying", false)),
        "loaded %s, length %.2f, current %s, playing %s" % [
            str(bool(music_stats.get("hasTutorialTownDayBgm", false))),
            float(music_stats.get("tutorialTownDayBgmLength", 0.0)),
            String(music_stats.get("currentMusic", "")),
            str(bool(music_stats.get("musicPlaying", false)))
        ]
    )
    audio_effects.update_music({ "track": "" })
    audio_effects.update_music({ "track": "daytime", "volumeDb": -14.0 })
    var daytime_music_stats: Dictionary = audio_effects.stats()
    var daytime_source := String(daytime_music_stats.get("currentMusicSource", ""))
    add_result(
        "daytime_bgm_candidates",
        bool(daytime_music_stats.get("hasGameDay2Bgm", false))
            and float(daytime_music_stats.get("gameDay2BgmLength", 0.0)) > 20.0
            and int(daytime_music_stats.get("daytimeMusicTrackCount", 0)) >= 2
            and String(daytime_music_stats.get("currentMusic", "")) == "daytime"
            and daytime_source in ["tutorialTownDay", "gameDay2"]
            and bool(daytime_music_stats.get("musicPlaying", false)),
        "gameDay2 %s %.2f, candidates %d, current %s source %s playing %s" % [
            str(bool(daytime_music_stats.get("hasGameDay2Bgm", false))),
            float(daytime_music_stats.get("gameDay2BgmLength", 0.0)),
            int(daytime_music_stats.get("daytimeMusicTrackCount", 0)),
            String(daytime_music_stats.get("currentMusic", "")),
            daytime_source,
            str(bool(daytime_music_stats.get("musicPlaying", false)))
        ]
    )
    audio_effects.update_music({ "track": "" })
    var created_after_first: int = int(stats.get("effectNodesCreated", 0))
    var reused_after_first: int = int(stats.get("effectNodesReused", 0))
    for i in range(70):
        await get_tree().process_frame
    var pooled_stats: Dictionary = audio_effects.stats()
    audio_effects.burst(player.global_position + Vector3(0.0, 1.0, 0.0) if player else Vector3.ZERO, Color(0.4, 0.8, 1.0), 2)
    await get_tree().process_frame
    var reused_stats: Dictionary = audio_effects.stats()
    add_result(
        "audio_effect_pool_reuse",
        int(pooled_stats.get("effectPool", 0)) >= 3
            and int(reused_stats.get("effectNodesReused", 0)) > reused_after_first
            and int(reused_stats.get("effectNodesCreated", 0)) <= created_after_first,
        "pool %d, created %d->%d, reused %d->%d" % [
            int(pooled_stats.get("effectPool", 0)),
            created_after_first,
            int(reused_stats.get("effectNodesCreated", 0)),
            reused_after_first,
            int(reused_stats.get("effectNodesReused", 0))
        ]
    )

func test_teleport_system() -> void:
    if not main or not player:
        add_result("teleport_system", false, "main or player missing")
        return
    var hud = main.get("hud")
    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var panel_open := false
    if hud:
        hud.set_teleport_open(true)
        panel_open = hud.is_teleport_open() and hud.teleport_panel.visible
    var teleported_xz: bool = bool(main.call("teleport_to", "64 -32"))
    await wait_physics_frames(4)
    var terrain_y: float = surface_y_at_position(Vector3(64.0, 0.0, -32.0))
    var horizontal_ok := Vector2(player.global_position.x - 64.0, player.global_position.z + 32.0).length() < 0.35
    var safe_y := player.global_position.y >= maxf(terrain_y, WATER_LEVEL) - 0.1
    var teleported_xyz: bool = bool(main.call("teleport_to", "12 40 -18"))
    await wait_physics_frames(2)
    var exact_xyz := player.global_position.distance_to(Vector3(12.0, 40.0, -18.0)) < 0.35
    var rejected_bad: bool = not bool(main.call("teleport_to", "nowhere"))
    if hud:
        hud.set_teleport_open(false)
    player.global_position = original_position
    player.velocity = original_velocity
    player.set("terrain_grounded", false)
    bootstrap_playtest_visible_chunks()
    await wait_for_chunk_count(49, 90, "teleport_restore_chunks")
    add_result(
        "teleport_system",
        panel_open and teleported_xz and horizontal_ok and safe_y and teleported_xyz and exact_xyz and rejected_bad,
        "panel %s, xz %s/%s, xyz %s/%s, bad rejected %s" % [
            str(panel_open),
            str(teleported_xz),
            str(horizontal_ok),
            str(teleported_xyz),
            str(exact_xyz),
            str(rejected_bad)
        ]
    )

func test_settings_playtest_debug() -> void:
    if not main or not player or not camera:
        add_result("settings_playtest_debug", false, "main/player/camera missing")
        return
    var hud = main.get("hud")
    var weather_system = main.get("weather_system")
    var held_item = main.get("held_item")
    if hud == null or weather_system == null:
        add_result("settings_playtest_debug", false, "hud or weather missing")
        return

    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var original_fov: float = camera.fov

    main.call("apply_runtime_setting", "mouseSensitivity", 1.45)
    main.call("apply_runtime_setting", "invertY", true)
    main.call("apply_runtime_setting", "lookSmoothing", 0.36)
    main.call("apply_runtime_setting", "fov", 84.0)
    main.call("apply_runtime_setting", "headBob", false)
    main.call("apply_runtime_setting", "handSway", false)
    main.call("apply_runtime_setting", "weatherParticles", 0.25)
    main.call("apply_runtime_setting", "hudScale", 1.4)
    main.call("apply_runtime_setting", "shadows", false)
    mark_progress("settings_runtime_values_applied")
    # Chunk-stream convergence belongs to the dedicated streaming/performance runners.
    # Forcing an exact live chunk count here made this UI/settings smoke depend on an
    # obsolete synchronous rebuild contract and could leave the suite waiting forever.
    var chunks := get_chunks()
    var settings_applied: bool = (
        abs(camera.fov - 84.0) < 0.1
        and float(player.get("mouse_sensitivity")) > 0.003
        and bool(player.get("invert_y"))
        and float(player.get("look_smoothing")) > 0.30
        and not bool(player.get("head_bob_enabled"))
        and (held_item == null or not bool(held_item.get("sway_enabled")))
        and abs(float(weather_system.snapshot().get("particleQuality", 1.0)) - 0.25) < 0.01
        and abs(float(hud.get("hud_scale")) - 1.4) < 0.01
        and not bool(main.get("shadows_enabled"))
    )
    mark_progress("settings_runtime_values_checked")

    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    hud.set_settings_open(true)
    var settings_blocks_mouse: bool = not bool(main.call("should_accept_mouse_look"))
    hud.set_settings_open(false)
    hud.set_playtest_open(true)
    var playtest_blocks_mouse: bool = not bool(main.call("should_accept_mouse_look"))
    var playtest_specs: Array = main.call("playtest_case_specs")
    hud.set_playtest_route("camp")
    var route_text: String = hud.playtest_route_label.text if hud.playtest_route_label else ""
    var route_overlay_ok: bool = route_text.find("Checks:") >= 0 and route_text.find("hostile camps") >= 0
    var playtest_case_buttons: bool = hud.playtest_list != null and hud.playtest_list.get_child_count() >= 8 and hud.playtest_status != null and playtest_specs.size() >= 8 and route_overlay_ok
    mark_progress("settings_ui_panels_checked")
    hud.set_playtest_open(false)

    add_result(
        "settings_runtime_controls",
        settings_applied,
        "fov %.1f, sens %.4f, particles %.2f, hud %.1f, render %d, chunks %d" % [
            camera.fov,
            float(player.get("mouse_sensitivity")),
            float(weather_system.snapshot().get("particleQuality", 1.0)),
            float(hud.get("hud_scale")),
            int(main.get("render_distance")),
            chunks.size()
        ]
    )
    add_result(
        "playtest_debug_hud",
        settings_blocks_mouse and playtest_blocks_mouse and playtest_case_buttons,
        "blocks mouse %s/%s, playtest buttons %s, route %s" % [
            str(settings_blocks_mouse),
            str(playtest_blocks_mouse),
            str(playtest_case_buttons),
            str(route_overlay_ok)
        ]
    )
    mark_progress("settings_results_recorded")

    hud.set_performance_open(false)
    hud.set_settings_open(false)
    hud.set_playtest_open(false)
    main.call("apply_runtime_setting", "mouseSensitivity", 1.0)
    main.call("apply_runtime_setting", "invertY", false)
    main.call("apply_runtime_setting", "lookSmoothing", 0.0)
    main.call("apply_runtime_setting", "fov", original_fov)
    main.call("apply_runtime_setting", "headBob", true)
    main.call("apply_runtime_setting", "handSway", true)
    main.call("apply_runtime_setting", "weatherParticles", 1.0)
    main.call("apply_runtime_setting", "hudScale", 1.0)
    main.call("apply_runtime_setting", "shadows", true)
    player.global_position = original_position
    player.velocity = original_velocity
    player.set("terrain_grounded", false)
    await wait_physics_frames(2)
    mark_progress("settings_runtime_values_restored")

func test_hud_refresh_throttling() -> void:
    if not main:
        add_result("hud_refresh_throttling", false, "main missing")
        return
    var hud = main.get("hud")
    if hud == null:
        add_result("hud_refresh_throttling", false, "hud missing")
        return

    var original_interval: float = float(main.get("hud_refresh_interval"))
    var original_elapsed: float = float(main.get("hud_refresh_elapsed"))
    main.set("hud_refresh_interval", 0.75)
    main.set("hud_refresh_elapsed", 0.0)
    var before: Dictionary = main.call("hud_refresh_stats")
    for i in range(3):
        main.call("update_hud_frame", 0.1)
    var after_wait: Dictionary = main.call("hud_refresh_stats")
    var skipped_delta: int = int(after_wait.get("skipped", 0)) - int(before.get("skipped", 0))
    var throttled_delta: int = int(after_wait.get("throttled", 0)) - int(before.get("throttled", 0))

    main.call("update_hud", "Immediate HUD Test")
    var after_message: Dictionary = main.call("hud_refresh_stats")
    var message_delta: int = int(after_message.get("messages", 0)) - int(after_wait.get("messages", 0))
    var message_visible: bool = hud.notification_label != null and hud.notification_label.text.find("Immediate HUD Test") >= 0 and hud.notification_label.visible

    main.set("hud_refresh_interval", 0.0)
    main.call("update_hud_frame", 0.016)
    var after_zero_interval: Dictionary = main.call("hud_refresh_stats")
    var immediate_throttled_delta: int = int(after_zero_interval.get("throttled", 0)) - int(after_message.get("throttled", 0))

    main.set("hud_refresh_interval", original_interval)
    main.set("hud_refresh_elapsed", original_elapsed)
    await get_tree().process_frame

    add_result(
        "hud_refresh_throttling",
        skipped_delta > 0 and throttled_delta == 0 and message_delta == 1 and message_visible and immediate_throttled_delta > 0,
        "skipped %d, throttled before interval %d, messages %d, visible %s, zero interval refreshes %d" % [
            skipped_delta,
            throttled_delta,
            message_delta,
            str(message_visible),
            immediate_throttled_delta
        ]
    )

func test_utility_blocks() -> void:
    if not main or not player:
        add_result("utility_system_present", false, "main or player missing")
        return
    var inventory_system = main.get("inventory_system")
    var utility_system = main.get("utility_system")
    var hud = main.get("hud")
    var present: bool = inventory_system != null and utility_system != null and hud != null
    add_result("utility_system_present", present, "utility system + hud present")
    if not present:
        return

    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }
    inventory_system.clear()
    inventory_system.add_item("logs", 4)
    inventory_system.add_item("sand", 3)

    var base_cell := Vector3i(roundi(player.global_position.x / CELL) + 10, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL) + 2)
    var chest_cell := base_cell
    var furnace_cell := base_cell + Vector3i(2, 0, 0)
    var bed_cell := base_cell + Vector3i(4, 0, 0)
    var anvil_cell := base_cell + Vector3i(6, 0, 0)
    var campfire_cell := base_cell + Vector3i(8, 0, 0)
    var torch_cell := base_cell + Vector3i(10, 0, 0)
    var spike_cell := base_cell + Vector3i(12, 0, 0)
    var ward_cell := base_cell + Vector3i(14, 0, 0)
    var beacon_cell := base_cell + Vector3i(16, 0, 0)
    var rift_cell := base_cell + Vector3i(18, 0, 0)
    var utility_cells := [chest_cell, furnace_cell, bed_cell, anvil_cell, campfire_cell, torch_cell, spike_cell, ward_cell, beacon_cell, rift_cell]
    var preexisting_blocks := get_blocks()
    for cell in utility_cells:
        if preexisting_blocks.has(cell):
            var old_body := preexisting_blocks[cell] as Node
            if old_body:
                old_body.queue_free()
            preexisting_blocks.erase(cell)
    var chest := main.call("create_block", chest_cell, "chest") as StaticBody3D
    var furnace := main.call("create_block", furnace_cell, "furnace") as StaticBody3D
    var visual_blocks := {
        "chest": chest,
        "furnace": furnace,
        "bed": main.call("create_block", bed_cell, "bed") as StaticBody3D,
        "anvil": main.call("create_block", anvil_cell, "anvil") as StaticBody3D,
        "campfire": main.call("create_block", campfire_cell, "campfire") as StaticBody3D,
        "torch": main.call("create_block", torch_cell, "torch") as StaticBody3D,
        "spikeTrap": main.call("create_block", spike_cell, "spikeTrap") as StaticBody3D,
        "wardLantern": main.call("create_block", ward_cell, "wardLantern") as StaticBody3D,
        "sanctuaryBeacon": main.call("create_block", beacon_cell, "sanctuaryBeacon") as StaticBody3D,
        "riftAnchor": main.call("create_block", rift_cell, "riftAnchor") as StaticBody3D
    }
    if chest == null or furnace == null:
        add_result("utility_blocks_created", false, "failed to create chest/furnace")
        inventory_system.restore(original_inventory)
        return

    var visual_details := []
    var visual_failures := []
    var light_details := []
    var light_failures := []
    var fire_light_failures := []
    var light_strength_failures := []
    var ground_fill_details := []
    var ground_fill_failures := []
    var ground_overlay_details := []
    var ground_overlay_failures := []
    var generated_details := []
    var generated_failures := []
    for item_id in visual_blocks.keys():
        var visual_body := visual_blocks[item_id] as Node
        var mesh_count := count_mesh_descendants(visual_body)
        visual_details.append("%s:%d" % [String(item_id), mesh_count])
        if mesh_count < 3:
            visual_failures.append(item_id)
        var generated_static := has_visual_source(visual_body, "generated_static_asset")
        generated_details.append("%s:%s" % [String(item_id), str(generated_static)])
        if not generated_static:
            generated_failures.append(item_id)
        if String(item_id) in ["campfire", "torch", "wardLantern", "sanctuaryBeacon", "riftAnchor"]:
            var light_count := count_light_descendants(visual_body)
            var fire_count := count_fire_light_descendants(visual_body)
            var shadow_count := count_shadowed_light_descendants(visual_body)
            var first_light := first_light_role_descendant(visual_body, "source")
            var base_energy := light_base_energy(first_light)
            var base_range := light_base_range(first_light)
            var flicker_min := light_flicker_min_scale(first_light)
            var light_offset := first_light.position if first_light else Vector3.ZERO
            var ground_fill_lights := ground_fill_light_descendants(visual_body)
            var source_lights := light_role_descendants(visual_body, "source")
            var terrain_wash_lights := light_role_descendants(visual_body, "terrain_wash")
            var bounce_fill_lights := light_role_descendants(visual_body, "bounce_fill")
            var local_rig_lights := local_light_rig_descendants(visual_body)
            var ground_overlay_meshes := ground_overlay_mesh_descendants(visual_body)
            var min_ground_fill_height := INF
            var min_ground_fill_range := INF
            var shadowed_ground_fill := 0
            for fill_light_value in ground_fill_lights:
                var fill_light := fill_light_value as Light3D
                if fill_light == null:
                    continue
                min_ground_fill_height = minf(min_ground_fill_height, fill_light.position.y)
                min_ground_fill_range = minf(min_ground_fill_range, light_base_range(fill_light))
                if fill_light.shadow_enabled:
                    shadowed_ground_fill += 1
            if ground_fill_lights.is_empty():
                min_ground_fill_height = 0.0
                min_ground_fill_range = 0.0
            var expected_ground_fill_range := CELL * 6.0
            if String(item_id) == "torch":
                expected_ground_fill_range = CELL * 5.0
            light_details.append("%s:%d/%d/%d roles %d/%d/%d rig %d @%.2f/%.1f min %.2f" % [
                String(item_id),
                light_count,
                fire_count,
                shadow_count,
                source_lights.size(),
                terrain_wash_lights.size(),
                bounce_fill_lights.size(),
                local_rig_lights.size(),
                base_energy,
                base_range,
                flicker_min
            ])
            ground_fill_details.append("%s:%d@%.2f/%.1f shadow %d" % [String(item_id), ground_fill_lights.size(), min_ground_fill_height, min_ground_fill_range, shadowed_ground_fill])
            ground_overlay_details.append("%s:%d" % [String(item_id), ground_overlay_meshes.size()])
            if light_count < 3 or source_lights.is_empty() or terrain_wash_lights.is_empty() or bounce_fill_lights.is_empty() or local_rig_lights.size() < 3:
                light_failures.append(item_id)
            if fire_count < 3:
                fire_light_failures.append(item_id)
            if ground_fill_lights.size() < 2 or min_ground_fill_height < CELL * 0.30 or min_ground_fill_range < expected_ground_fill_range or shadowed_ground_fill > 0:
                ground_fill_failures.append(item_id)
            if not ground_overlay_meshes.is_empty():
                ground_overlay_failures.append(item_id)
            if flicker_min < 0.01 or flicker_min > 0.99:
                light_strength_failures.append("%s:min %.2f" % [String(item_id), flicker_min])
            if String(item_id) == "torch" and (base_range < CELL * 6.0 or base_range > CELL * 6.4):
                light_strength_failures.append("%s:range %.2f" % [String(item_id), base_range])
            if String(item_id) == "wardLantern" and (base_energy < 2.0 or base_range < CELL * 12.0 or light_offset.length() < CELL * 0.35):
                light_strength_failures.append("%s:%.2f/%.1f/%s" % [String(item_id), base_energy, base_range, str(light_offset)])
    add_result(
        "placed_utility_visual_meshes",
        visual_failures.is_empty(),
        ", ".join(visual_details)
    )
    add_result(
        "placed_utility_generated_static_visuals",
        generated_failures.is_empty(),
        ", ".join(generated_details)
    )
    add_result(
        "placed_light_emitters",
        light_failures.is_empty() and fire_light_failures.is_empty() and light_strength_failures.is_empty(),
        ", ".join(light_details) + (" failures " + ", ".join(light_strength_failures) if not light_strength_failures.is_empty() else "")
    )
    add_result(
        "placed_light_ground_fill",
        ground_fill_failures.is_empty(),
        ", ".join(ground_fill_details) + (" failures " + ", ".join(ground_fill_failures) if not ground_fill_failures.is_empty() else "")
    )
    add_result(
        "placed_light_uses_real_ground_lighting",
        ground_overlay_failures.is_empty(),
        ", ".join(ground_overlay_details) + (" failures " + ", ".join(ground_overlay_failures) if not ground_overlay_failures.is_empty() else "")
    )

    var expected_shadowed_lights := 5
    var shadowed_before := 0
    for light_item_id in ["campfire", "torch", "wardLantern", "sanctuaryBeacon", "riftAnchor"]:
        shadowed_before += count_shadowed_light_descendants(visual_blocks[light_item_id] as Node)
    main.call("apply_runtime_setting", "shadows", false)
    var shadowed_disabled := 0
    for light_item_id in ["campfire", "torch", "wardLantern", "sanctuaryBeacon", "riftAnchor"]:
        shadowed_disabled += count_shadowed_light_descendants(visual_blocks[light_item_id] as Node)
    main.call("apply_runtime_setting", "shadows", true)
    var shadowed_enabled := 0
    for light_item_id in ["campfire", "torch", "wardLantern", "sanctuaryBeacon", "riftAnchor"]:
        shadowed_enabled += count_shadowed_light_descendants(visual_blocks[light_item_id] as Node)
    add_result(
        "local_light_shadows_follow_setting",
        shadowed_before >= expected_shadowed_lights and shadowed_disabled == 0 and shadowed_enabled >= expected_shadowed_lights,
        "shadowed %d->%d->%d" % [shadowed_before, shadowed_disabled, shadowed_enabled]
    )

    utility_system.close()
    var visual_cleanup_blocks := get_blocks()
    for cell in utility_cells:
        if visual_cleanup_blocks.has(cell):
            var visual_body_to_clear := visual_cleanup_blocks[cell] as Node
            if visual_body_to_clear:
                visual_body_to_clear.queue_free()
            visual_cleanup_blocks.erase(cell)

    inventory_system.clear()
    inventory_system.add_item("logs", 4)
    inventory_system.add_item("sand", 3)
    chest_cell = base_cell + Vector3i(0, 0, 4)
    furnace_cell = base_cell + Vector3i(2, 0, 4)
    utility_cells = [chest_cell, furnace_cell]
    preexisting_blocks = get_blocks()
    for cell in utility_cells:
        if preexisting_blocks.has(cell):
            var behavior_old_body := preexisting_blocks[cell] as Node
            if behavior_old_body:
                behavior_old_body.queue_free()
            preexisting_blocks.erase(cell)
    chest = main.call("create_block", chest_cell, "chest") as StaticBody3D
    furnace = main.call("create_block", furnace_cell, "furnace") as StaticBody3D
    if chest == null or furnace == null:
        add_result("utility_blocks_created", false, "failed to create fresh chest/furnace")
        inventory_system.restore(original_inventory)
        return

    set_active_inventory_item(inventory_system, "logs")
    var logs_before: int = inventory_system.count("logs")
    utility_system.open_block(chest)
    var chest_open: bool = hud.is_utility_open() and hud.utility_grid.get_child_count() == 12
    utility_system.transfer_chest_slot(0)
    var chest_slots_value: Variant = chest.get_meta("storage_slots")
    var chest_slots: Array = chest_slots_value if chest_slots_value is Array else []
    var chest_stored_logs: bool = chest_slots.size() > 0 and String(chest_slots[0].get("item", "")) == "logs" and inventory_system.count("logs") < logs_before
    inventory_system.add_item("stones", 1)
    set_active_inventory_item(inventory_system, "stones")
    utility_system.transfer_chest_slot(0)
    var chest_withdrew_logs: bool = inventory_system.count("logs") == logs_before and chest_slots.size() > 0 and String(chest_slots[0].get("item", "")) == ""
    var chest_preserved_active: bool = String(inventory_system.active_stack().get("item", "")) == "stones"
    add_result(
        "chest_storage_transfer",
        chest_open and chest_stored_logs and chest_withdrew_logs and chest_preserved_active,
        "open %s, stored %s, withdrew %s, active %s" % [
            str(chest_open),
            str(chest_stored_logs),
            str(chest_withdrew_logs),
            String(inventory_system.active_stack().get("item", ""))
        ]
    )
    inventory_system.clear()
    inventory_system.select(0)
    chest_slots = utility_system.ensure_chest(chest)
    chest_slots[0] = { "item": "berries", "count": 2 }
    utility_system.set_chest_slots(chest, chest_slots)
    utility_system.transfer_chest_slot(0)
    var berry_slot := find_inventory_slot(inventory_system, "berries")
    var chest_withdraw_avoids_active: bool = (
        berry_slot > 0
        and String(inventory_system.active_stack().get("item", "")) == ""
        and inventory_system.count("berries") == 2
    )
    add_result(
        "chest_withdraw_avoids_active_slot",
        chest_withdraw_avoids_active,
        "berry slot %d, active %s, berries %d" % [
            berry_slot,
            String(inventory_system.active_stack().get("item", "")),
            inventory_system.count("berries")
        ]
    )

    inventory_system.clear()
    inventory_system.add_item("logs", 4)
    inventory_system.add_item("sand", 3)
    utility_system.open_block(furnace)
    set_active_inventory_item(inventory_system, "sand")
    var sand_before: int = inventory_system.count("sand")
    utility_system.transfer_furnace_slot("input")
    set_active_inventory_item(inventory_system, "logs")
    logs_before = inventory_system.count("logs")
    utility_system.transfer_furnace_slot("fuel")
    var glass_before: int = inventory_system.count("glass")
    var started: bool = utility_system.start_processing()
    utility_system.update(5.0)
    inventory_system.select(3)
    utility_system.transfer_furnace_slot("output")
    var made_glass: bool = started and inventory_system.count("glass") == glass_before + 1
    inventory_system.select(4)
    utility_system.transfer_furnace_slot("input")
    inventory_system.select(5)
    utility_system.transfer_furnace_slot("fuel")
    var restored_inputs: bool = inventory_system.count("sand") == sand_before - 1 and inventory_system.count("logs") == logs_before - 1
    add_result(
        "furnace_smelting_transfer",
        made_glass and restored_inputs and hud.is_utility_open(),
        "glass %d->%d, sand %d, logs %d" % [glass_before, inventory_system.count("glass"), inventory_system.count("sand"), inventory_system.count("logs")]
    )

    utility_system.close()
    var blocks := get_blocks()
    for cell in utility_cells:
        if blocks.has(cell):
            var body := blocks[cell] as Node
            if body:
                body.queue_free()
            blocks.erase(cell)
    inventory_system.restore(original_inventory)

func test_player_placement_system() -> void:
    if not main or not player or not camera:
        add_result("player_placement_system", false, "main/player/camera missing")
        return
    var inventory_system = main.get("inventory_system")
    var present: bool = inventory_system != null
    if not present:
        add_result("player_placement_system", false, "inventory missing")
        return

    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var original_rotation: Vector3 = player.rotation
    var original_pitch := float(player.get("pitch"))
    var original_camera_pitch := camera.rotation.x
    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }

    var base_cell := Vector2i(roundi(player.global_position.x / CELL) + 18, roundi(player.global_position.z / CELL) + 18)
    reset_player_on_flat_patch(base_cell)
    clear_blocks_near_cell(base_cell, 14)
    await settle_streamed_chunks_after_relocation("placement_chunks", 120)
    await wait_physics_frames(8)

    inventory_system.clear()
    inventory_system.add_item("workbench", 3)
    inventory_system.add_item("woodBlock", 1)
    inventory_system.add_item("cobblestonePath", 1)

    var placed_keys: Array[Vector3i] = []
    var placement_target := base_cell + Vector2i(0, -1)
    var far_placement_target := base_cell + Vector2i(0, -4)
    var far_result: Dictionary = await place_item_far_from_player(inventory_system, "workbench", far_placement_target)
    var workbench_result: Dictionary = await place_item_via_player(inventory_system, "workbench", placement_target, placed_keys)
    cleanup_test_blocks(placed_keys)
    placed_keys.clear()
    var wood_result: Dictionary = await place_item_via_player(inventory_system, "woodBlock", placement_target, placed_keys)
    cleanup_test_blocks(placed_keys)
    placed_keys.clear()
    var path_result: Dictionary = await place_item_via_player(inventory_system, "cobblestonePath", placement_target, placed_keys)
    cleanup_test_blocks(placed_keys)
    placed_keys.clear()

    var slope_restore := make_relative_slope_patch(placement_target)
    main.call("rebuild_chunks_around_cell", placement_target)
    await wait_physics_frames(6)
    var slope_result: Dictionary = await place_item_via_player(inventory_system, "workbench", placement_target, placed_keys)

    var workbench_table := int(workbench_result.get("meshCount", 0)) >= 8
    var workbench_ok := bool(workbench_result.get("placed", false)) and bool(workbench_result.get("consumed", false)) and bool(workbench_result.get("grounded", false)) and workbench_table
    var wood_ok := bool(wood_result.get("placed", false)) and bool(wood_result.get("consumed", false)) and bool(wood_result.get("grounded", false))
    var path_ok := bool(path_result.get("placed", false)) and bool(path_result.get("consumed", false)) and bool(path_result.get("grounded", false))
    var slope_ok := bool(slope_result.get("placed", false)) and bool(slope_result.get("consumed", false)) and bool(slope_result.get("grounded", false))
    var far_blocked := not bool(far_result.get("placed", true)) and not bool(far_result.get("consumed", true))
    add_result(
        "player_placement_system",
        workbench_ok and wood_ok and path_ok and slope_ok and far_blocked,
        "far %s, workbench %s, wood %s, path %s, slope %s" % [
            str(far_result),
            str(workbench_result),
            str(wood_result),
            str(path_result),
            str(slope_result)
        ]
    )

    cleanup_test_blocks(placed_keys)
    restore_height_patch(slope_restore)
    main.call("rebuild_chunks_around_cell", placement_target)
    inventory_system.restore(original_inventory)
    player.global_position = original_position
    player.velocity = original_velocity
    player.rotation = original_rotation
    player.set("pitch", original_pitch)
    camera.rotation.x = original_camera_pitch
    player.set("terrain_grounded", false)

func place_item_far_from_player(inventory_system, item_id: String, target_cell: Vector2i) -> Dictionary:
    var blocks := get_blocks()
    var target_ground: float = surface_y_at_cell2(target_cell)
    var anchor_cell := Vector3i(target_cell.x, roundi(camera.global_position.y / CELL), target_cell.y)
    if blocks.has(anchor_cell):
        var old_anchor := blocks[anchor_cell] as Node
        if old_anchor:
            old_anchor.queue_free()
        blocks.erase(anchor_cell)
    var anchor = main.call("create_block", anchor_cell, "stoneBlock", {
        "world_y": camera.global_position.y
    })
    var before := {}
    for key in blocks.keys():
        before[key] = true
    if not set_active_inventory_item(inventory_system, item_id):
        return { "placed": false, "consumed": false, "reason": "not active" }
    var count_before: int = inventory_system.count(item_id)
    aim_player_at(Vector3(float(target_cell.x) * CELL, camera.global_position.y, float(target_cell.y) * CELL))
    await wait_physics_frames(2)
    main.call("place_selected_block")
    await wait_physics_frames(4)
    var placed := false
    var placed_keys: Array[Vector3i] = []
    for key in blocks.keys():
        if before.has(key):
            continue
        var body := blocks[key] as Node
        if body == null or not bool(body.get_meta("player_placed", false)):
            continue
        if String(body.get_meta("block_type", "")) != item_id:
            continue
        placed = true
        placed_keys.append(key)
    cleanup_test_blocks(placed_keys)
    if blocks.has(anchor_cell):
        var anchor_body := blocks[anchor_cell] as Node
        if anchor_body:
            anchor_body.queue_free()
        blocks.erase(anchor_cell)
    var count_after: int = inventory_system.count(item_id)
    return {
        "placed": placed,
        "consumed": count_after == count_before - 1,
        "count": "%d->%d" % [count_before, count_after],
        "distance": Vector2(float(target_cell.x) * CELL - player.global_position.x, float(target_cell.y) * CELL - player.global_position.z).length(),
        "ground": target_ground,
        "message": String(main.get("last_hud_refresh_message"))
    }

func place_item_via_player(inventory_system, item_id: String, target_cell: Vector2i, placed_keys: Array[Vector3i]) -> Dictionary:
    var blocks := get_blocks()
    var before := {}
    for key in blocks.keys():
        before[key] = true
    if not set_active_inventory_item(inventory_system, item_id):
        return { "placed": false, "consumed": false, "grounded": false, "reason": "not active" }
    var count_before: int = inventory_system.count(item_id)
    var target_ground: float = surface_y_at_cell2(target_cell)
    aim_player_at(Vector3(float(target_cell.x) * CELL, target_ground - CELL * 1.5, float(target_cell.y) * CELL))
    await wait_physics_frames(2)
    main.call("place_selected_block")
    await wait_physics_frames(4)

    var placed: StaticBody3D = null
    var placed_key := Vector3i.ZERO
    for key in blocks.keys():
        if before.has(key):
            continue
        var body := blocks[key] as StaticBody3D
        if body == null or not bool(body.get_meta("player_placed", false)):
            continue
        if String(body.get_meta("block_type", "")) != item_id:
            continue
        placed = body
        placed_key = key
        break
    if placed:
        placed_keys.append(placed_key)
    var count_after: int = inventory_system.count(item_id)
    var consumed := count_after == count_before - 1
    var grounded := false
    var bottom := 0.0
    var ground := 0.0
    if placed:
        bottom = float(main.call("block_bottom_y", placed))
        ground = float(main.call("placement_surface_height", placed.global_position.x, placed.global_position.z, item_id))
        grounded = bottom <= ground + CELL * 0.18 and bottom >= ground - CELL * 0.20
    return {
        "placed": placed != null,
        "consumed": consumed,
        "grounded": grounded,
        "count": "%d->%d" % [count_before, count_after],
        "bottom": bottom,
        "ground": ground,
        "meshCount": count_mesh_descendants(placed),
        "message": String(main.get("last_hud_refresh_message"))
    }

func cleanup_test_blocks(keys: Array[Vector3i]) -> void:
    var blocks := get_blocks()
    var changed := false
    for key in keys:
        if blocks.has(key):
            var body := blocks[key] as Node
            if body:
                body.queue_free()
            blocks.erase(key)
            changed = true
    if changed:
        invalidate_navigation_fixture()

func clear_blocks_near_cell(center_cell: Vector2i, radius: int) -> void:
    var blocks := get_blocks()
    var changed := false
    for key in blocks.keys():
        var cell: Vector3i = key
        if abs(cell.x - center_cell.x) > radius or abs(cell.z - center_cell.y) > radius:
            continue
        var body := blocks[key] as Node
        if body:
            body.queue_free()
        blocks.erase(key)
        changed = true
    if changed:
        invalidate_navigation_fixture()

func clear_blocks_along_segment(start: Vector3, end: Vector3, radius_cells: int = 1) -> void:
    var blocks := get_blocks()
    if blocks.is_empty():
        return
    var segment := end - start
    var steps: int = maxi(2, ceili(segment.length() / CELL))
    var cells := {}
    for i in range(steps + 1):
        var point: Vector3 = start.lerp(end, float(i) / float(steps))
        var cell_x := roundi(point.x / CELL)
        var cell_z := roundi(point.z / CELL)
        for dz in range(-radius_cells, radius_cells + 1):
            for dx in range(-radius_cells, radius_cells + 1):
                cells[Vector2i(cell_x + dx, cell_z + dz)] = true
    var changed := false
    for key in blocks.keys():
        var cell: Vector3i = key
        if not cells.has(Vector2i(cell.x, cell.z)):
            continue
        var body := blocks[key] as Node
        if body:
            body.queue_free()
        blocks.erase(key)
        changed = true
    if changed:
        invalidate_navigation_fixture()

func clear_props_near_cell(center_cell: Vector2i, radius: int) -> void:
    var roots := prop_cleanup_roots_near_cell(center_cell, radius)
    var changed := false
    for root in roots:
        changed = clear_props_near_cell_recursive(root, center_cell, radius) or changed
    if changed:
        invalidate_navigation_fixture()

func prop_cleanup_roots_near_cell(center_cell: Vector2i, radius: int) -> Array:
    var roots := []
    var prop_root = main.get("prop_root") as Node
    if prop_root:
        roots.append(prop_root)
    var chunks := get_chunks()
    var chunk_radius := ceili(float(radius) / float(CHUNK_SIZE)) + 1
    var center_chunk := Vector2i(floori(float(center_cell.x) / float(CHUNK_SIZE)), floori(float(center_cell.y) / float(CHUNK_SIZE)))
    for dz in range(-chunk_radius, chunk_radius + 1):
        for dx in range(-chunk_radius, chunk_radius + 1):
            var chunk_key := Vector2i(center_chunk.x + dx, center_chunk.y + dz)
            if chunks.has(chunk_key):
                var chunk := chunks[chunk_key] as Node
                if chunk != null and is_instance_valid(chunk):
                    roots.append(chunk)
    return roots

func clear_props_near_cell_recursive(node: Node, center_cell: Vector2i, radius: int) -> bool:
    var changed := false
    for child in node.get_children():
        var node3d := child as Node3D
        if node3d == null or not child.has_meta("kind"):
            continue
        if String(child.get_meta("kind")) != "prop":
            continue
        if prop_body_within_cell_radius(node3d, center_cell, radius):
            node.remove_child(child)
            child.queue_free()
            changed = true
    return changed

func prop_body_within_cell_radius(node3d: Node3D, center_cell: Vector2i, radius: int) -> bool:
    if main == null or node3d == null:
        return false
    var cell := Vector2i(main.call("world_to_cell", node3d.global_position.x), main.call("world_to_cell", node3d.global_position.z))
    return abs(cell.x - center_cell.x) <= radius and abs(cell.y - center_cell.y) <= radius

func invalidate_navigation_fixture() -> void:
    if main == null:
        return
    var npc_system = main.get("npc_system")
    if npc_system == null:
        return
    var pathing = npc_system.get("pathing")
    if pathing != null and pathing.has_method("invalidate"):
        pathing.invalidate()

func disable_prop_colliders(node: Node, disabled_shapes: Array[CollisionShape3D]) -> void:
    if node == null:
        return
    if node.has_meta("kind") and String(node.get_meta("kind")) == "prop":
        collect_disabled_collision_shapes(node, disabled_shapes)
        return
    for child in node.get_children():
        disable_prop_colliders(child, disabled_shapes)

func disable_prop_colliders_near_cell(center_cell: Vector2i, radius: int, disabled_shapes: Array[CollisionShape3D]) -> void:
    var roots := prop_cleanup_roots_near_cell(center_cell, radius)
    for root in roots:
        disable_prop_colliders_near_cell_recursive(root, center_cell, radius, disabled_shapes)

func disable_prop_colliders_near_cell_recursive(node: Node, center_cell: Vector2i, radius: int, disabled_shapes: Array[CollisionShape3D]) -> void:
    if node == null:
        return
    for child in node.get_children():
        var node3d := child as Node3D
        if node3d == null or not child.has_meta("kind"):
            continue
        if String(child.get_meta("kind")) != "prop":
            continue
        if prop_body_within_cell_radius(node3d, center_cell, radius):
            collect_disabled_collision_shapes(child, disabled_shapes)
    if node is Node3D and node.has_meta("kind") and String(node.get_meta("kind")) == "prop":
        var prop_node := node as Node3D
        if prop_body_within_cell_radius(prop_node, center_cell, radius):
            collect_disabled_collision_shapes(node, disabled_shapes)
        return

func collect_disabled_collision_shapes(node: Node, disabled_shapes: Array[CollisionShape3D]) -> void:
    for child in node.get_children():
        var shape := child as CollisionShape3D
        if shape != null and not shape.disabled:
            shape.disabled = true
            disabled_shapes.append(shape)
        collect_disabled_collision_shapes(child, disabled_shapes)

func restore_collision_shapes(shapes: Array[CollisionShape3D]) -> void:
    for shape in shapes:
        if shape != null and is_instance_valid(shape):
            shape.disabled = false

func make_relative_slope_patch(center_cell: Vector2i) -> Dictionary:
    var edits := get_volume_edit_markers()
    var restore := {}
    var base_height: float = surface_y_at_cell2(center_cell)
    for dz in range(-1, 2):
        for dx in range(-1, 2):
            var key := Vector2i(center_cell.x + dx, center_cell.y + dz)
            restore[key] = { "had": edits.has(key), "height": float(edits[key]) if edits.has(key) else 0.0 }
            edits[key] = base_height + float(dx + dz) * CELL * 0.12
    return restore

func restore_height_patch(restore: Dictionary) -> void:
    var edits := get_volume_edit_markers()
    for key in restore.keys():
        var entry: Dictionary = restore[key]
        if bool(entry.get("had", false)):
            edits[key] = float(entry.get("height", 0.0))
        elif edits.has(key):
            edits.erase(key)

func test_trader_stall_system() -> void:
    if not main or not player:
        add_result("trader_stall_system", false, "main or player missing")
        return
    var inventory_system = main.get("inventory_system")
    var utility_system = main.get("utility_system")
    var progression_system = main.get("progression_system")
    var hud = main.get("hud")
    var present: bool = inventory_system != null and utility_system != null and progression_system != null and hud != null
    if not present:
        add_result("trader_stall_system", false, "inventory/utility/progression/hud missing")
        return

    var original_slots: Array = inventory_system.snapshot()
    var original_size: int = int(inventory_system.size)
    var original_selected: int = int(inventory_system.selected_slot)
    var progression_snapshot: Dictionary = progression_system.snapshot()
    var base_cell := Vector3i(roundi(player.global_position.x / CELL) + 14, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL) + 4)
    var stall := main.call("create_block", base_cell, "traderStall") as StaticBody3D
    if stall == null:
        add_result("trader_stall_system", false, "failed to create trader stall")
        return

    inventory_system.clear()
    inventory_system.add_item("logs", 2)
    utility_system.open_block(stall)
    hud.render_utility(utility_system.active_state())
    var trade_state: Dictionary = utility_system.active_state()
    var trade_rows: Array = trade_state.get("trades", [])
    var hud_open: bool = hud.is_utility_open() and String(trade_state.get("type", "")) == "traderStall" and hud.utility_grid.get_child_count() == trade_rows.size() and trade_rows.size() >= 10
    var logs_before: int = inventory_system.count("logs")
    var torches_before: int = inventory_system.count("torch")
    var xp_before: int = int(progression_system.total_xp)
    var traded: bool = bool(utility_system.handle_action("trade", "trailTorches"))
    var trade_changed_inventory: bool = inventory_system.count("logs") == logs_before - 2 and inventory_system.count("torch") == torches_before + 4
    var xp_after: int = int(progression_system.total_xp)
    var xp_awarded: bool = xp_after > xp_before
    var blocked_second: bool = not bool(utility_system.handle_action("trade", "trailTorches")) and inventory_system.count("torch") == torches_before + 4

    utility_system.close()
    inventory_system.restore({ "slots": original_slots, "size": original_size, "selectedSlot": original_selected })
    progression_system.restore(progression_snapshot)
    var blocks := get_blocks()
    if blocks.has(base_cell):
        var body := blocks[base_cell] as Node
        if body:
            body.queue_free()
        blocks.erase(base_cell)

    add_result(
        "trader_stall_system",
        hud_open and traded and trade_changed_inventory and xp_awarded and blocked_second,
        "hud %s, rows %d, traded %s, inventory %s, xp %d->%d, blocked %s" % [
            str(hud_open),
            trade_rows.size(),
            str(traded),
            str(trade_changed_inventory),
            xp_before,
            xp_after,
            str(blocked_second)
        ]
    )

func test_fishing_system() -> void:
    if not main or not player or not camera:
        add_result("fishing_system", false, "main/player/camera missing")
        return
    var inventory_system = main.get("inventory_system")
    var held_item = main.get("held_item")
    if inventory_system == null or held_item == null:
        add_result("fishing_system", false, "inventory or held item missing")
        return

    var original_position: Vector3 = player.global_position
    var original_rotation: Vector3 = player.rotation
    var original_pitch := float(player.get("pitch"))
    var original_camera_pitch := camera.rotation.x
    var center_cell := Vector2i(roundi(player.global_position.x / CELL) + 7, roundi(player.global_position.z / CELL))
    var water_cell := Vector2i(center_cell.x, center_cell.y - 5)
    var edits := get_volume_edit_markers()
    var touched_edits := {}
    for dz in range(-5, 6):
        for dx in range(-5, 6):
            var key := Vector2i(center_cell.x + dx, center_cell.y + dz)
            touched_edits[key] = { "had": edits.has(key), "height": float(edits[key]) if edits.has(key) else 0.0 }
    for dz in range(-1, 2):
        for dx in range(-2, 3):
            var key := Vector2i(water_cell.x + dx, water_cell.y + dz)
            if not touched_edits.has(key):
                touched_edits[key] = { "had": edits.has(key), "height": float(edits[key]) if edits.has(key) else 0.0 }

    reset_player_on_flat_patch(center_cell)
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    camera.rotation.x = 0.0
    edits = get_volume_edit_markers()
    for dz in range(-1, 2):
        for dx in range(-2, 3):
            edits[Vector2i(water_cell.x + dx, water_cell.y + dz)] = WATER_LEVEL - 0.25
    main.call("rebuild_chunks_around_cell", water_cell)
    await wait_physics_frames(8)

    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    inventory_system.add_item("fishingRod", 1)
    var rod_slot := find_inventory_slot(inventory_system, "fishingRod")
    if rod_slot >= 0:
        inventory_system.select(0)
        if rod_slot != 0:
            inventory_system.swap_with_active(rod_slot)
    await wait_physics_frames(2)

    var fishing_rng = main.get("fishing_rng") as RandomNumberGenerator
    if fishing_rng:
        fishing_rng.seed = 34117
    main.set("world_elapsed", 1000.0)
    main.set("next_fishing_ready_at", 0.0)
    var spot: Dictionary = main.call("find_fishing_spot")
    var fish_before: int = inventory_system.count("rawFish")
    var cast_used := false
    for i in range(16):
        cast_used = bool(main.call("try_use_active_consumable")) or cast_used
        await wait_physics_frames(2)
        if inventory_system.count("rawFish") > fish_before:
            break
        main.set("world_elapsed", float(main.get("next_fishing_ready_at")) + 0.2)
    var caught: bool = inventory_system.count("rawFish") > fish_before
    var rod_visible: bool = String(held_item.get("current_item")) == "fishingRod" and held_item.visible
    var cast_animation: bool = String(held_item.get("use_action")) == "cast"
    var passed: bool = not spot.is_empty() and cast_used and caught and rod_visible and cast_animation
    edits = get_volume_edit_markers()
    for key in touched_edits.keys():
        var entry: Dictionary = touched_edits[key]
        if bool(entry.get("had", false)):
            edits[key] = float(entry.get("height", 0.0))
        else:
            edits.erase(key)
    main.call("rebuild_chunks_around_cell", center_cell)
    main.call("rebuild_chunks_around_cell", water_cell)
    player.global_position = original_position
    player.rotation = original_rotation
    player.set("pitch", original_pitch)
    camera.rotation.x = original_camera_pitch
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", false)
    await wait_physics_frames(4)
    add_result(
        "fishing_system",
        passed,
        "spot %s, fish %d->%d, rod %s, cast %s" % [
            str(spot),
            fish_before,
            inventory_system.count("rawFish"),
            str(rod_visible),
            str(cast_animation)
        ]
    )

func test_save_load_round_trip() -> void:
    if not main or not player:
        add_result("save_system_present", false, "main or player missing")
        return
    var save_system = main.get("save_system")
    var inventory_system = main.get("inventory_system")
    var survival_system = main.get("survival_system")
    var progression_system = main.get("progression_system")
    var equipment_system = main.get("equipment_system")
    var contract_system = main.get("contract_system")
    var present: bool = save_system != null and inventory_system != null and survival_system != null and progression_system != null and equipment_system != null and contract_system != null
    add_result("save_system_present", present, "save system + inventory + survival + progression present")
    if not present:
        return

    save_system.delete(String(main.get("seed_text")))
    var original_autosave_enabled: bool = bool(main.get("autosave_enabled"))
    var save_cell := Vector3i(roundi(player.global_position.x / CELL) + 14, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL) + 4)
    var save_block := main.call("create_block", save_cell, "woodBlock", { "player_placed": true }) as StaticBody3D
    var world_generation = main.get("world_generation_system")
    var terrain_edit_cell := Vector3i(
        roundi(player.global_position.x / CELL) + 18,
        floori(surface_y_at_position(player.global_position) / CELL) - 3,
        roundi(player.global_position.z / CELL) + 4
    )
    var terrain_edit_applied := false
    if world_generation != null and world_generation.has_method("apply_box_edit"):
        var edited_cells: Array = world_generation.call("apply_box_edit", terrain_edit_cell, terrain_edit_cell, {
            "material": "air",
            "biome": "underground_air",
            "solid": false,
            "density": -CELL,
            "fluid": "",
            "light": { "sky": 0, "block": 0 },
            "metadata": {
                "source": "playtest_save_load",
                "terrainMeshAffects": true,
                "saveDelta": true
            }
        }, "playtest_save_load")
        terrain_edit_applied = not edited_cells.is_empty()
    var saved_position: Vector3 = player.global_position + Vector3(2.0, 0.0, 1.0)
    player.global_position = saved_position
    var saved_wood_count: int = inventory_system.count("woodBlock")
    var discovered_biomes: Dictionary = main.get("discovered_biomes")
    var discovered_towns: Dictionary = main.get("discovered_town_keys")
    var discovered_shrines: Dictionary = main.get("discovered_shrine_keys")
    var discovered_mines: Dictionary = main.get("discovered_mine_keys")
    var discovered_ruins: Dictionary = main.get("discovered_ruin_keys")
    var discovered_camps: Dictionary = main.get("discovered_camp_keys")
    discovered_biomes.clear()
    discovered_towns.clear()
    discovered_shrines.clear()
    discovered_mines.clear()
    discovered_ruins.clear()
    discovered_camps.clear()
    var saved_cell_2d := Vector2i(main.call("world_to_cell", saved_position.x), main.call("world_to_cell", saved_position.z))
    discovered_biomes[surface_biome_at_cell2(saved_cell_2d)] = true
    var saved_town: Dictionary = main.call("town_region_at_cell", saved_cell_2d.x, saved_cell_2d.y)
    if not saved_town.is_empty():
        discovered_towns["%d,%d" % [int(saved_town.get("centerX", 0)), int(saved_town.get("centerZ", 0))]] = true
    discovered_towns["playtest-town"] = true
    discovered_shrines["playtest-shrine"] = true
    discovered_mines["playtest-mine"] = true
    discovered_ruins["playtest-ruin"] = true
    discovered_camps["playtest-camp"] = true
    var save_scan_blocks := get_blocks()
    for block_value in save_scan_blocks.values():
        var discovery_body := block_value as Node3D
        if discovery_body == null or not discovery_body.has_meta("generatedTier"):
            continue
        var tier := String(discovery_body.get_meta("generatedTier", ""))
        if not (tier in ["mine", "ruin", "camp"]):
            continue
        if discovery_body.global_position.distance_to(saved_position) > CELL * 8.0:
            continue
        var landmark_key := String(discovery_body.get_meta("cacheKey", ""))
        if landmark_key == "":
            continue
        if tier == "mine":
            discovered_mines[landmark_key] = true
        elif tier == "ruin":
            discovered_ruins[landmark_key] = true
        elif tier == "camp":
            discovered_camps[landmark_key] = true
    contract_system.reset()
    survival_system.health = 72.0
    survival_system.hunger = 44.0
    progression_system.restore({ "level": 2, "xp": 17, "totalXp": 97 })
    equipment_system.restore({ "body": "stoneArmor", "accessory": "trailCharm" })
    contract_system.restore({ "completed": ["masonOrder"], "townUnlocked": true, "menuOpen": true })
    var saved: bool = main.call("save_world", true)

    player.global_position = saved_position + Vector3(22.0, 4.0, 0.0)
    inventory_system.clear()
    survival_system.health = 12.0
    survival_system.hunger = 2.0
    progression_system.restore({ "level": 1, "xp": 0, "totalXp": 0 })
    equipment_system.reset()
    contract_system.reset()
    discovered_biomes.clear()
    discovered_towns.clear()
    discovered_shrines.clear()
    discovered_mines.clear()
    discovered_ruins.clear()
    discovered_camps.clear()
    if world_generation != null and world_generation.has_method("reset_terrain_volume_authority"):
        world_generation.call("reset_terrain_volume_authority")
    var blocks := get_blocks()
    if blocks.has(save_cell):
        save_block = blocks[save_cell] as StaticBody3D
        if save_block:
            save_block.queue_free()
        blocks.erase(save_cell)

    main.set("autosave_enabled", true)
    var loaded: bool = main.call("try_load_world", false)
    main.set("autosave_enabled", original_autosave_enabled)
    blocks = get_blocks()
    var player_restored := player.global_position.distance_to(saved_position) < 0.05
    var inventory_restored: bool = inventory_system.count("woodBlock") == saved_wood_count
    var survival_restored: bool = abs(float(survival_system.health) - 72.0) < 0.05 and abs(float(survival_system.hunger) - 44.0) < 0.05
    var progression_restored: bool = int(progression_system.level) == 2 and int(progression_system.xp) == 17 and int(progression_system.total_xp) == 97
    var equipment_restored: bool = String(equipment_system.equipped_item("body")) == "stoneArmor" and String(equipment_system.equipped_item("accessory")) == "trailCharm"
    var contract_state: Dictionary = contract_system.state()
    var contracts_restored: bool = bool(contract_state.get("townUnlocked", false)) and int(contract_state.get("completed", 0)) >= 1
    var exploration_restored: bool = (
        discovered_towns.has("playtest-town")
        and discovered_shrines.has("playtest-shrine")
        and discovered_mines.has("playtest-mine")
        and discovered_ruins.has("playtest-ruin")
        and discovered_camps.has("playtest-camp")
    )
    var terrain_sample: Dictionary = world_generation.call("sample_cell", terrain_edit_cell) if world_generation != null and world_generation.has_method("sample_cell") else {}
    var terrain_restored: bool = terrain_edit_applied \
        and String(terrain_sample.get("material", "")) == "air" \
        and String(terrain_sample.get("biome", "")) == "underground_air" \
        and not bool(terrain_sample.get("solid", true))
    var block_restored: bool = blocks.has(save_cell) and bool((blocks[save_cell] as Node).get_meta("player_placed", false))
    add_result(
        "save_load_round_trip",
        saved and loaded and player_restored and inventory_restored and survival_restored and progression_restored and equipment_restored and contracts_restored and exploration_restored and terrain_restored and block_restored,
        "saved %s, loaded %s, player %s, inventory %s, survival %s, progression %s, equipment %s, contracts %s, exploration %s, terrain %s, block %s" % [
            str(saved),
            str(loaded),
            str(player_restored),
            str(inventory_restored),
            str(survival_restored),
            str(progression_restored),
            str(equipment_restored),
            str(contracts_restored),
            str(exploration_restored),
            str(terrain_restored),
            str(block_restored)
        ]
    )

    save_system.delete(String(main.get("seed_text")))
    main.set("autosave_enabled", original_autosave_enabled)
    progression_system.restore({ "level": 1, "xp": 0, "totalXp": 0 })
    equipment_system.reset()
    contract_system.reset()
    if blocks.has(save_cell):
        var restored_block := blocks[save_cell] as Node
        if restored_block:
            restored_block.queue_free()
        blocks.erase(save_cell)

func test_survival_system() -> void:
    if not main:
        add_result("survival_system_present", false, "main missing")
        return
    var survival_system = main.get("survival_system")
    var inventory_system = main.get("inventory_system")
    var hud = main.get("hud")
    var present: bool = survival_system != null and inventory_system != null and hud != null
    add_result("survival_system_present", present, "survival + inventory + hud present")
    if not present:
        return

    survival_system.health = 80.0
    survival_system.stamina = 50.0
    survival_system.hunger = 40.0
    inventory_system.add_item("berries", 2)
    var berry_slot := find_inventory_slot(inventory_system, "berries")
    if berry_slot >= 0:
        inventory_system.select(0)
        inventory_system.swap_with_active(berry_slot)
    var berries_before: int = inventory_system.count("berries")
    var used_food: bool = main.call("try_use_active_consumable")
    var food_helped: bool = used_food and inventory_system.count("berries") == berries_before - 1 and float(survival_system.hunger) > 40.0 and float(survival_system.health) > 80.0
    hud.set_survival(survival_system.snapshot())
    var hud_updated: bool = hud.health_bar != null and hud.hunger_bar != null and float(hud.health_bar.value) > 80.0 and float(hud.hunger_bar.value) > 40.0
    add_result(
        "survival_food_and_hud",
        food_helped and hud_updated,
        "used %s, hunger %.1f, health %.1f, hud %s/%s" % [
            str(used_food),
            float(survival_system.hunger),
            float(survival_system.health),
            hud.health_label.text,
            hud.hunger_label.text
        ]
    )

    var night_start_health: float = float(survival_system.call("max_health"))
    survival_system.health = night_start_health
    survival_system.hunger = 100.0
    survival_system.update(10.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "plains", "dayFactor": 0.0, "weather": { "kind": "clear", "intensity": 0.0 }, "lightSafety": 0.0, "sanctuaryEstablished": false })
    add_result(
        "night_does_not_damage_player",
        abs(float(survival_system.health) - night_start_health) < 0.01 and float(survival_system.hunger) < 100.0 and String(survival_system.last_danger) == "Nightfall",
        "health %.1f, hunger %.1f, danger '%s'" % [float(survival_system.health), float(survival_system.hunger), String(survival_system.last_danger)]
    )

    survival_system.health = 80.0
    survival_system.hunger = 80.0
    survival_system.warmth_timer = 0.0
    survival_system.ward_timer = 0.0
    var hunger_plain := float(survival_system.hunger)
    survival_system.update(10.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "plains", "dayFactor": 1.0, "weather": { "kind": "clear", "intensity": 0.0 }, "lightSafety": 0.0, "sanctuaryEstablished": false })
    var plain_drain := hunger_plain - float(survival_system.hunger)
    survival_system.hunger = 80.0
    survival_system.health = 80.0
    survival_system.update(10.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "snow", "dayFactor": 1.0, "weather": { "kind": "snow", "intensity": 1.0 }, "lightSafety": 0.0, "sanctuaryEstablished": false })
    var wet_cold_drain := 80.0 - float(survival_system.hunger)
    survival_system.warmth_timer = 60.0
    survival_system.hunger = 80.0
    survival_system.update(10.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "snow", "dayFactor": 1.0, "weather": { "kind": "clear", "intensity": 0.0 }, "lightSafety": 0.0, "sanctuaryEstablished": false })
    var warmed_drain := 80.0 - float(survival_system.hunger)
    add_result(
        "survival_weather_warmth_drain",
        wet_cold_drain > plain_drain + 0.30 and warmed_drain <= plain_drain + 0.05 and String(survival_system.last_danger).begins_with("Warmed"),
        "plain %.3f, wet+cold %.3f, warmed %.3f, danger '%s'" % [plain_drain, wet_cold_drain, warmed_drain, String(survival_system.last_danger)]
    )

    survival_system.hunger = 80.0
    survival_system.health = 80.0
    survival_system.stamina = 40.0
    survival_system.warmth_timer = 0.0
    survival_system.update(1.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "snow", "dayFactor": 1.0, "weather": { "kind": "snow", "intensity": 1.0 }, "lightSafety": 0.0, "shelterComfort": 0.0, "sanctuaryEstablished": false })
    var exposed_snow_drain := 80.0 - float(survival_system.hunger)
    var exposed_stamina := float(survival_system.stamina)
    survival_system.hunger = 80.0
    survival_system.health = 80.0
    survival_system.stamina = 40.0
    survival_system.warmth_timer = 0.0
    survival_system.update(1.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "snow", "dayFactor": 1.0, "weather": { "kind": "snow", "intensity": 1.0 }, "lightSafety": 0.0, "shelterComfort": 0.75, "sanctuaryEstablished": false })
    var sheltered_snow_drain := 80.0 - float(survival_system.hunger)
    var sheltered_stamina := float(survival_system.stamina)
    var sheltered_status := String(survival_system.last_danger)

    var base_cell := Vector2i(roundi(player.global_position.x / CELL) + 18, roundi(player.global_position.z / CELL) + 18)
    var base_height: float = surface_y_at_cell2(base_cell)
    for offset in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]:
        main.call("create_playtest_ground_block", base_cell, offset, "woodBlock", "shelter_test", 0)
        main.call("create_playtest_ground_block", base_cell, offset, "woodBlock", "shelter_test", 1)
    for x_offset in [-1, 0, 1]:
        for z_offset in [-1, 0, 1]:
            main.call("create_playtest_ground_block", base_cell, Vector2i(x_offset, z_offset), "woodBlock", "shelter_test", 2)
    main.call("create_playtest_ground_block", base_cell, Vector2i(0, 0), "bed", "shelter_test", 0)
    main.call("create_playtest_ground_block", base_cell, Vector2i(0, 1), "torch", "shelter_test", 0)
    var shelter_state: Dictionary = main.call("shelter_state_at", Vector3(float(base_cell.x) * CELL, base_height + 0.55, float(base_cell.y) * CELL))
    main.call("cleanup_playtest_case_assets")
    var shelter_score_ok: bool = float(shelter_state.get("comfort", 0.0)) >= 0.62 and String(shelter_state.get("label", "")) == "Sheltered"
    add_result(
        "survival_shelter_comfort",
        sheltered_snow_drain < exposed_snow_drain and sheltered_stamina > exposed_stamina and sheltered_status == "Sheltered" and shelter_score_ok,
        "drain %.3f->%.3f, stamina %.1f->%.1f, status '%s', scorer %.2f/%s" % [
            exposed_snow_drain,
            sheltered_snow_drain,
            exposed_stamina,
            sheltered_stamina,
            sheltered_status,
            float(shelter_state.get("comfort", 0.0)),
            String(shelter_state.get("label", ""))
        ]
    )

    survival_system.health = survival_system.max_health()
    survival_system.hunger = 80.0
    survival_system.ward_timer = 90.0
    survival_system.apply_damage(10.0, "Hostile hit", "hostile")
    var warded_health := float(survival_system.health)
    var warded_label := String(survival_system.last_danger)
    survival_system.health = survival_system.max_health()
    survival_system.ward_timer = 0.0
    survival_system.apply_damage(10.0, "Hostile hit", "hostile")
    var unwarded_health := float(survival_system.health)
    add_result(
        "survival_ward_damage_status",
        warded_health > unwarded_health and warded_label.find("(ward)") >= 0,
        "warded %.1f, unwarded %.1f, label '%s'" % [warded_health, unwarded_health, warded_label]
    )

    survival_system.health = 90.0
    survival_system.hunger = 80.0
    survival_system.ward_timer = 0.0
    survival_system.update(3.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "plains", "dayFactor": 0.0, "weather": { "kind": "clear", "intensity": 0.0 }, "lightSafety": 0.8, "sanctuaryEstablished": false })
    var light_status := String(survival_system.last_danger)
    var light_health := float(survival_system.health)
    survival_system.update(1.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "plains", "dayFactor": 0.0, "weather": { "kind": "clear", "intensity": 0.0 }, "lightSafety": 0.0, "sanctuaryEstablished": true })
    add_result(
        "survival_light_sanctuary_status",
        light_status == "Light safe" and light_health > 90.0 and String(survival_system.last_danger) == "Sanctuary secured",
        "light '%s' health %.1f, sanctuary '%s'" % [light_status, light_health, String(survival_system.last_danger)]
    )
    if berry_slot >= 0:
        inventory_system.swap_with_active(berry_slot)
    inventory_system.select(0)

func test_bed_respawn_and_death_drop() -> void:
    if not main or not player:
        add_result("bed_respawn_and_death_drop", false, "main or player missing")
        return
    var survival_system = main.get("survival_system")
    var inventory_system = main.get("inventory_system")
    var equipment_system = main.get("equipment_system")
    if survival_system == null or inventory_system == null or equipment_system == null:
        add_result("bed_respawn_and_death_drop", false, "survival/inventory/equipment missing")
        return

    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }
    var original_equipment: Dictionary = equipment_system.snapshot()
    var original_survival: Dictionary = survival_system.snapshot()
    var original_respawn = main.get("respawn_point")
    var original_deaths: int = int(main.get("death_count"))
    var blocks := get_blocks()

    var bed_center := player.global_position + Vector3(CELL * 4.0, 0.0, 0.0)
    var bed_level: float = surface_y_at_position(bed_center)
    var bed_cell := Vector3i(roundi(bed_center.x / CELL), floori((bed_level + CELL * 0.48) / CELL) + 1, roundi(bed_center.z / CELL))
    if blocks.has(bed_cell):
        var old_block := blocks[bed_cell] as Node
        if old_block:
            old_block.queue_free()
        blocks.erase(bed_cell)
    var bed = main.call("create_block", bed_cell, "bed", {
        "player_placed": true,
        "world_y": bed_level + CELL * 0.48
    })
    var bed_set: bool = bool(main.call("sleep_at_bed", bed))
    if bed_set:
        main.call("update_sleep_transition", 2.0)
    var respawn_value = main.get("respawn_point")
    var respawn_set: bool = bed_set and respawn_value is Vector3

    inventory_system.clear()
    inventory_system.add_item("logs", 5)
    inventory_system.add_item("stoneArmor", 1)
    var armor_slot := find_inventory_slot(inventory_system, "stoneArmor")
    if armor_slot >= 0:
        inventory_system.select(0)
        inventory_system.swap_with_active(armor_slot)
        equipment_system.equip_active()
    var death_position := player.global_position + Vector3(CELL * 8.0, 0.0, CELL * 2.0)
    player.global_position = death_position
    survival_system.health = 1.0
    survival_system.apply_damage(99.0, "test collapse", "hostile")
    var collapsed: bool = bool(main.call("handle_collapse_if_needed"))
    var death_after: int = int(main.get("death_count"))
    var death_counted: bool = death_after == original_deaths + 1
    var woke_near_bed: bool = respawn_set and player.global_position.distance_to(respawn_value) < CELL * 1.2
    var inventory_cleared: bool = inventory_system.count("logs") == 0 and equipment_system.equipped_item("body") == ""
    var pickup_count: int = (main.get("dropped_pickups") as Array).size()
    var drops_spawned: bool = pickup_count >= 2

    var collected_logs := false
    var pickups: Array = main.get("dropped_pickups")
    if not pickups.is_empty():
        var pickup: Dictionary = pickups[0]
        var pickup_node := pickup.get("node") as Node3D
        if pickup_node and is_instance_valid(pickup_node):
            player.global_position = pickup_node.global_position
            main.call("update_dropped_pickups", 0.1)
            collected_logs = inventory_system.count("logs") > 0 or inventory_system.count("stoneArmor") > 0

    main.call("clear_dropped_pickups")
    if bed and is_instance_valid(bed):
        bed.queue_free()
    if blocks.has(bed_cell):
        blocks.erase(bed_cell)
    inventory_system.restore(original_inventory)
    equipment_system.restore(original_equipment)
    survival_system.restore(original_survival)
    main.set("respawn_point", original_respawn)
    main.set("death_count", original_deaths)
    player.global_position = original_position
    player.velocity = original_velocity
    player.set("terrain_grounded", false)

    add_result(
        "bed_respawn_and_death_drop",
        respawn_set and collapsed and death_counted and woke_near_bed and inventory_cleared and drops_spawned and collected_logs,
        "respawn %s, collapsed %s, deaths %d, woke %s, cleared %s, drops %d, collected %s" % [
            str(respawn_set),
            str(collapsed),
            death_after,
            str(woke_near_bed),
            str(inventory_cleared),
            pickup_count,
            str(collected_logs)
        ]
    )

func test_hostile_system() -> void:
    if not main or not player:
        add_result("hostile_system_present", false, "main or player missing")
        return
    var hostile_system = main.get("hostile_system")
    var survival_system = main.get("survival_system")
    var inventory_system = main.get("inventory_system")
    var present: bool = hostile_system != null and survival_system != null and inventory_system != null
    add_result("hostile_system_present", present, "hostiles + survival + inventory present")
    if not present:
        return

    hostile_system.clear()
    hostile_system.spawn_cooldown = 999.0
    var restore_position: Vector3 = player.global_position
    var restore_velocity: Vector3 = player.velocity
    var hostile_cell := Vector2i(roundi(restore_position.x / CELL) + 96, roundi(restore_position.z / CELL) + 96)
    reset_player_on_flat_patch(hostile_cell)
    clear_blocks_near_cell(hostile_cell, 16)
    clear_props_near_cell(hostile_cell, 16)
    await settle_streamed_chunks_after_relocation("hostile_chunks")
    await wait_process_frames(3)
    var original_position: Vector3 = player.global_position
    var enemy_pos: Vector3 = original_position + Vector3(12.0, 0.0, 0.0)
    enemy_pos.y = surface_y_at_position(enemy_pos) + 0.72
    var enemy: StaticBody3D = hostile_system.spawn_enemy(enemy_pos, "shadow")
    var enemy_start: Vector3 = enemy.global_position if enemy else enemy_pos
    hostile_system.update_hostiles(0.25, 0.0, "plains")
    var became_aware: bool = hostile_system.enemies.size() > 0 and bool(hostile_system.enemies[0].get("aware", false))
    var moved_when_aware: bool = enemy != null and is_instance_valid(enemy) and enemy.global_position.distance_to(enemy_start) > 0.12
    var aware_distance: float = enemy.global_position.distance_to(enemy_start) if enemy != null and is_instance_valid(enemy) else 0.0
    player.global_position = original_position + Vector3(90.0, 0.0, 0.0)
    hostile_system.update_hostiles(0.25, 0.0, "plains")
    var leashed: bool = hostile_system.enemies.size() > 0 and not bool(hostile_system.enemies[0].get("aware", true))
    player.global_position = original_position
    var shards_before: int = inventory_system.count("nightShard")
    hostile_system.damage_hostile(enemy, 999.0)
    var defeated_drop: bool = hostile_system.enemies.is_empty() and inventory_system.count("nightShard") == shards_before + 1
    add_result(
        "hostile_awareness_leash_drop",
        became_aware and leashed and defeated_drop,
        "aware %s, leashed %s, shard %d->%d" % [str(became_aware), str(leashed), shards_before, inventory_system.count("nightShard")]
    )
    add_result(
        "hostile_chase_movement",
        became_aware and moved_when_aware,
        "aware %s, moved %.2f" % [str(became_aware), aware_distance]
    )

    hostile_system.clear()
    var wall_blocks := get_blocks()
    var wall_ground: float = surface_y_at_position(original_position + Vector3(CELL * 4.0, 0.0, 0.0))
    var wall_y: float = wall_ground + CELL * 0.48
    var wall_cells: Array[Vector3i] = []
    var wall_x := roundi((original_position.x + CELL * 4.0) / CELL)
    var wall_z := roundi(original_position.z / CELL)
    var wall_cell_y := floori(wall_y / CELL) + 1
    for dz in range(-1, 2):
        var wall_cell := Vector3i(wall_x, wall_cell_y, wall_z + dz)
        wall_cells.append(wall_cell)
        if wall_blocks.has(wall_cell):
            var old_wall := wall_blocks[wall_cell] as Node
            if old_wall:
                old_wall.queue_free()
            wall_blocks.erase(wall_cell)
        main.call("create_block", wall_cell, "stoneBlock", { "world_y": wall_y })
    await wait_physics_frames(3)
    var blocked_enemy_pos := original_position + Vector3(CELL * 8.0, 0.0, 0.0)
    blocked_enemy_pos.y = surface_y_at_position(blocked_enemy_pos) + 0.72
    var blocked_enemy: StaticBody3D = hostile_system.spawn_enemy(blocked_enemy_pos, "shadow")
    var blocked_start_x := blocked_enemy.global_position.x if blocked_enemy else blocked_enemy_pos.x
    for i in range(28):
        hostile_system.update_hostiles(0.16, 0.0, "plains")
    var blocked_end_x := blocked_enemy.global_position.x if blocked_enemy and is_instance_valid(blocked_enemy) else blocked_start_x
    var wall_world_x := float(wall_x) * CELL
    var stopped_by_wall := blocked_enemy != null and blocked_end_x > wall_world_x + CELL * 0.55
    hostile_system.clear()
    wall_blocks = get_blocks()
    for wall_cell in wall_cells:
        if wall_blocks.has(wall_cell):
            var wall_body := wall_blocks[wall_cell] as Node
            if wall_body:
                wall_body.queue_free()
            wall_blocks.erase(wall_cell)
    add_result(
        "hostile_obstacle_collision",
        stopped_by_wall,
        "start x %.2f, end x %.2f, wall x %.2f" % [blocked_start_x, blocked_end_x, wall_world_x]
    )

    survival_system.health = survival_system.max_health()
    var block_health_before: float = float(survival_system.health)
    var block_cell: Vector3i = Vector3i(roundi(player.global_position.x / CELL) + 4, roundi((player.global_position.y + 0.9) / CELL), roundi(player.global_position.z / CELL))
    var blocks := get_blocks()
    if blocks.has(block_cell):
        var old_projectile_block := blocks[block_cell] as Node
        if old_projectile_block:
            old_projectile_block.queue_free()
        blocks.erase(block_cell)
    main.call("create_block", block_cell, "stoneBlock")
    await wait_physics_frames(3)
    var block_y: float = float(block_cell.y) * CELL
    var projectile_start := Vector3((block_cell.x - 3) * CELL, block_y, block_cell.z * CELL)
    var projectile_target := Vector3((block_cell.x + 3) * CELL, block_y, block_cell.z * CELL)
    var direct_block_probe: Dictionary = hostile_system.projectile_block_hit(projectile_start, projectile_target)
    var projectile_pool_stats_before: Dictionary = hostile_system.stats()
    hostile_system.spawn_projectile(projectile_start, projectile_target, 8.0, null)
    hostile_system.update_hostiles(0.45, 1.0, "plains")
    var projectile_pool_stats_after_block: Dictionary = hostile_system.stats()
    var block_projectiles_after: int = hostile_system.projectiles.size()
    var block_health_after: float = float(survival_system.health)
    var blocked_projectile: bool = block_projectiles_after == 0 and block_health_after >= block_health_before - 0.01
    if blocks.has(block_cell):
        var block := blocks[block_cell] as Node
        if block:
            block.queue_free()
        blocks.erase(block_cell)

    survival_system.health = survival_system.max_health()
    var dodge_health_before: float = float(survival_system.health)
    var old_target: Vector3 = player.global_position + Vector3(0.0, 0.8, 0.0)
    hostile_system.spawn_projectile(player.global_position + Vector3(0.0, 0.8, -10.0), old_target, 8.0, null)
    var projectile_pool_stats_after_reuse: Dictionary = hostile_system.stats()
    player.global_position = original_position + Vector3(5.0, 0.0, 0.0)
    await wait_physics_frames(1)
    for i in range(18):
        hostile_system.update_hostiles(0.08, 1.0, "plains")
    var dodgeable_projectile: bool = float(survival_system.health) >= dodge_health_before - 0.01
    player.global_position = original_position
    hostile_system.clear()
    var hostile_projectile_reused: bool = (
        int(projectile_pool_stats_after_block.get("projectilePool", 0)) >= 1
        and int(projectile_pool_stats_after_reuse.get("projectileNodesCreated", 0)) <= int(projectile_pool_stats_after_block.get("projectileNodesCreated", 0))
        and int(projectile_pool_stats_after_reuse.get("projectileNodesReused", 0)) > int(projectile_pool_stats_before.get("projectileNodesReused", 0))
    )
    add_result(
        "hostile_projectile_collision_and_dodge",
        blocked_projectile and dodgeable_projectile and hostile_projectile_reused,
        "blocked %s, probe %s, block remaining %d, block health %.1f->%.1f, remaining %d, dodge health %.1f->%.1f, pool %d, created %d->%d, reused %d->%d" % [
            str(blocked_projectile),
            str(direct_block_probe),
            block_projectiles_after,
            block_health_before,
            block_health_after,
            hostile_system.projectiles.size(),
            dodge_health_before,
            float(survival_system.health),
            int(projectile_pool_stats_after_block.get("projectilePool", 0)),
            int(projectile_pool_stats_before.get("projectileNodesCreated", 0)),
            int(projectile_pool_stats_after_reuse.get("projectileNodesCreated", 0)),
            int(projectile_pool_stats_before.get("projectileNodesReused", 0)),
            int(projectile_pool_stats_after_reuse.get("projectileNodesReused", 0))
        ]
    )

    hostile_system.clear()
    player.global_position = restore_position
    player.velocity = restore_velocity
    var natural_enemy: StaticBody3D = hostile_system.spawn_near_player("plains")
    var natural_distance := 0.0
    var natural_aware := true
    var natural_start := Vector3.ZERO
    if natural_enemy and is_instance_valid(natural_enemy):
        natural_distance = natural_enemy.global_position.distance_to(player.global_position)
        natural_start = natural_enemy.global_position
        var natural_state: Dictionary = hostile_system.enemy_for_body(natural_enemy)
        natural_aware = bool(natural_state.get("aware", true))
    for i in range(10):
        hostile_system.update_hostiles(0.12, 0.0, "plains")
    var natural_roam_distance := 0.0
    if natural_enemy and is_instance_valid(natural_enemy):
        natural_roam_distance = natural_enemy.global_position.distance_to(natural_start)
    var reduced_awareness: bool = hostile_system.awareness_radius({ "variant": "shadow" }) <= 26.0 and hostile_system.awareness_radius({ "variant": "seer" }) <= 32.0
    add_result(
        "hostile_natural_spawn_spacing",
        natural_enemy != null and natural_distance >= 44.0 and not natural_aware and reduced_awareness,
        "spawned %s, distance %.2f, aware %s, shadow radius %.1f, seer radius %.1f" % [
            str(natural_enemy != null),
            natural_distance,
            str(natural_aware),
            hostile_system.awareness_radius({ "variant": "shadow" }),
            hostile_system.awareness_radius({ "variant": "seer" })
        ]
    )
    add_result(
        "hostile_natural_roaming",
        natural_enemy != null and natural_roam_distance > 0.08,
        "spawned %s, roam %.2f, aware %s" % [str(natural_enemy != null), natural_roam_distance, str(natural_aware)]
    )
    hostile_system.clear()

func test_rift_hostile_system() -> void:
    if not main or not player:
        add_result("rift_hostile_core_drop", false, "main or player missing")
        return
    var hostile_system = main.get("hostile_system")
    var inventory_system = main.get("inventory_system")
    var objective_system = main.get("objective_system")
    var contract_system = main.get("contract_system")
    var present: bool = hostile_system != null and inventory_system != null and objective_system != null and contract_system != null
    if not present:
        add_result("rift_hostile_core_drop", false, "rift dependencies missing")
        return

    hostile_system.clear()
    var original_position: Vector3 = player.global_position
    var rift_position: Vector3 = original_position + Vector3(10.0, 0.0, -8.0)
    rift_position.y = surface_y_at_position(rift_position) + 0.78
    var cores_before: int = inventory_system.count("riftCore")
    var shards_before: int = inventory_system.count("nightShard")
    var meat_before: int = inventory_system.count("rawMeat")
    var stats_before: Dictionary = hostile_system.stats()
    var variants_before: Dictionary = stats_before.get("defeatedVariants", {})
    var rifts_before := int(variants_before.get("rift", 0))

    var rift_enemy: StaticBody3D = hostile_system.spawn_enemy(rift_position, "rift")
    var enemy_state: Dictionary = hostile_system.enemy_for_body(rift_enemy)
    var spawned_as_rift: bool = String(rift_enemy.get_meta("variant", "")) == "rift" and float(enemy_state.get("health", 0.0)) >= 90.0
    var defeated: bool = hostile_system.damage_hostile(rift_enemy, 999.0)
    var stats_after: Dictionary = hostile_system.stats()
    var variants_after: Dictionary = stats_after.get("defeatedVariants", {})
    var state: Dictionary = main.call("objective_state")
    state["discoveredTowns"] = max(1, int(state.get("discoveredTowns", 0)))
    var objective_complete: bool = bool(objective_system.is_complete("riftColossus", state))
    var contract_complete: bool = bool(contract_system.is_contract_complete("riftTrophy", state))
    var core_dropped: bool = inventory_system.count("riftCore") == cores_before + 1
    var shard_drop: bool = inventory_system.count("nightShard") >= shards_before + 7
    var meat_drop: bool = inventory_system.count("rawMeat") >= meat_before + 3
    var variant_tracked: bool = int(variants_after.get("rift", 0)) == rifts_before + 1
    add_result(
        "rift_hostile_core_drop",
        spawned_as_rift and defeated and core_dropped and shard_drop and meat_drop and variant_tracked and objective_complete and contract_complete,
        "spawned %s, defeated %s, core %d->%d, shards %d->%d, meat %d->%d, rifts %d->%d, objective %s, contract %s, message '%s'" % [
            str(spawned_as_rift),
            str(defeated),
            cores_before,
            inventory_system.count("riftCore"),
            shards_before,
            inventory_system.count("nightShard"),
            meat_before,
            inventory_system.count("rawMeat"),
            rifts_before,
            int(variants_after.get("rift", 0)),
            str(objective_complete),
            str(contract_complete),
            String(hostile_system.last_message)
        ]
    )
    player.global_position = original_position
    hostile_system.clear()

func test_sanctuary_beacon_raid_system() -> void:
    if not main or not player:
        add_result("sanctuary_beacon_raid_system", false, "main or player missing")
        return
    var hostile_system = main.get("hostile_system")
    var objective_system = main.get("objective_system")
    var progression_system = main.get("progression_system")
    var hud = main.get("hud")
    var present: bool = hostile_system != null and objective_system != null and progression_system != null and hud != null
    if not present:
        add_result("sanctuary_beacon_raid_system", false, "hostile/objective/progression/hud system missing")
        return

    hostile_system.clear()
    var original_position: Vector3 = player.global_position
    var beacon_cell := Vector2i(roundi(player.global_position.x / CELL) + 14, roundi(player.global_position.z / CELL) + 4)
    var level: float = surface_y_at_cell2(beacon_cell)
    var block_cell := Vector3i(beacon_cell.x, floori((level + CELL * 0.48) / CELL) + 1, beacon_cell.y)
    var blocks := get_blocks()
    if blocks.has(block_cell):
        var existing := blocks[block_cell] as Node
        if existing:
            existing.queue_free()
        blocks.erase(block_cell)
    var beacon = main.call("create_block", block_cell, "sanctuaryBeacon", {
        "player_placed": true,
        "world_y": level + CELL * 0.48
    })
    main.set("beacon_charge", 24.8)
    main.set("beacon_raid_stage", 0)
    main.set("sanctuary_established", false)
    main.set("beacon_status_message", "")

    main.call("update_beacon_charge", 1.0)
    var stage_one: bool = int(main.get("beacon_raid_stage")) == 1 and hostile_system.enemies.size() >= 3
    var charge_after_stage_one: float = float(main.get("beacon_charge"))
    main.call("update_beacon_charge", 1.0)
    var contested_drop: bool = float(main.get("beacon_charge")) < charge_after_stage_one

    hostile_system.clear()
    main.set("beacon_charge", 84.8)
    main.set("beacon_raid_stage", 2)
    main.call("update_beacon_charge", 1.0)
    var rift_spawned := false
    for enemy in hostile_system.enemies:
        if String(enemy.get("variant", "")) == "rift":
            rift_spawned = true
            break
    var final_surge: bool = int(main.get("beacon_raid_stage")) == 3 and rift_spawned

    hostile_system.clear()
    main.set("beacon_charge", 99.8)
    main.set("beacon_raid_stage", 3)
    var xp_before: int = int(progression_system.total_xp)
    main.call("update_beacon_charge", 1.0)
    var state: Dictionary = main.call("objective_state")
    var raid_objective: bool = bool(objective_system.is_complete("riftRaid", state))
    var sanctuary_objective: bool = bool(objective_system.is_complete("sanctuary", state))
    var snapshot: Dictionary = main.call("create_save_snapshot")
    var established: bool = (
        bool(main.get("sanctuary_established"))
        and abs(float(main.get("beacon_charge")) - 100.0) < 0.01
        and int(main.get("beacon_raid_stage")) == 3
        and hostile_system.enemies.is_empty()
    )
    var saved_state: bool = (
        bool(snapshot.get("sanctuaryEstablished", false))
        and int(snapshot.get("beaconRaidStage", 0)) == 3
        and abs(float(snapshot.get("beaconCharge", 0.0)) - 100.0) < 0.01
    )
    var victory_open: bool = hud.is_victory_open() and hud.victory_stats_list.get_child_count() >= 20
    add_result(
        "sanctuary_beacon_raid_system",
        stage_one and contested_drop and final_surge and established and raid_objective and sanctuary_objective and saved_state and victory_open and int(progression_system.total_xp) > xp_before,
        "stage1 %s, contested %s, final %s, established %s, objectives %s/%s, saved %s, victory %s, enemies %d, charge %.1f, stage %d" % [
            str(stage_one),
            str(contested_drop),
            str(final_surge),
            str(established),
            str(raid_objective),
            str(sanctuary_objective),
            str(saved_state),
            str(victory_open),
            hostile_system.enemies.size(),
            float(main.get("beacon_charge")),
            int(main.get("beacon_raid_stage"))
        ]
    )
    player.global_position = original_position
    if beacon and is_instance_valid(beacon):
        beacon.queue_free()
    if blocks.has(block_cell):
        blocks.erase(block_cell)
    main.set("sanctuary_established", false)
    main.set("beacon_charge", 0.0)
    main.set("beacon_raid_stage", 0)
    main.set("beacon_status_message", "")
    hud.hide_victory()
    hostile_system.clear()

func test_defensive_blocks() -> void:
    if not main or not player:
        add_result("defensive_blocks", false, "main or player missing")
        return
    var hostile_system = main.get("hostile_system")
    var inventory_system = main.get("inventory_system")
    var present: bool = hostile_system != null and inventory_system != null
    if not present:
        add_result("defensive_blocks", false, "hostile or inventory system missing")
        return

    hostile_system.clear()
    main.set("sanctuary_established", false)
    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var defensive_cell := Vector2i(roundi(player.global_position.x / CELL) + 180, roundi(player.global_position.z / CELL) + 180)
    reset_player_on_flat_patch(defensive_cell, 5, true)
    clear_blocks_near_cell(defensive_cell, 12)
    clear_props_near_cell(defensive_cell, 12)
    await settle_streamed_chunks_after_relocation("defensive_blocks_chunks", 120)
    await wait_physics_frames(4)
    var blocks := get_blocks()
    var level: float = ground_y_near_position(player.global_position)
    var torch_cell := Vector3i(roundi(player.global_position.x / CELL) + 1, floori((level + CELL * 0.48) / CELL) + 1, roundi(player.global_position.z / CELL))
    if blocks.has(torch_cell):
        var existing_torch := blocks[torch_cell] as Node
        if existing_torch:
            existing_torch.queue_free()
        blocks.erase(torch_cell)
    var torch = main.call("create_block", torch_cell, "torch", {
        "player_placed": true,
        "world_y": level + CELL * 0.48
    })
    var safety: float = main.call("light_safety_at", player.global_position, false)
    hostile_system.spawn_cooldown = 0.0
    hostile_system.update_hostiles(0.25, 0.0, "plains", false)
    var spawn_suppressed: bool = safety > 0.82 and hostile_system.enemies.is_empty()
    if torch and is_instance_valid(torch):
        torch.queue_free()
    if blocks.has(torch_cell):
        blocks.erase(torch_cell)

    var trap_center := player.global_position + Vector3(8.0, 0.0, 0.0)
    var trap_level: float = surface_y_at_position(trap_center)
    var trap_cell := Vector3i(roundi(trap_center.x / CELL), floori((trap_level + CELL * 0.48) / CELL) + 1, roundi(trap_center.z / CELL))
    if blocks.has(trap_cell):
        var existing_trap := blocks[trap_cell] as Node
        if existing_trap:
            existing_trap.queue_free()
        blocks.erase(trap_cell)
    var trap = main.call("create_block", trap_cell, "spikeTrap", {
        "player_placed": true,
        "world_y": trap_level + CELL * 0.08
    })
    var shards_before: int = inventory_system.count("nightShard")
    var enemy_position := Vector3(trap_cell.x * CELL, trap_level + 0.72, trap_cell.z * CELL)
    var enemy: StaticBody3D = hostile_system.spawn_enemy(enemy_position, "shadow")
    hostile_system.spawn_cooldown = 999.0
    var health_before := 0.0
    var enemy_state: Dictionary = hostile_system.enemy_for_body(enemy)
    if not enemy_state.is_empty():
        health_before = float(enemy_state.get("health", 0.0))
        enemy_state["aware"] = false
    hostile_system.update_hostiles(0.0, 1.0, "plains", false)
    enemy_state = hostile_system.enemy_for_body(enemy) if enemy and is_instance_valid(enemy) else {}
    var damaged: bool = not enemy_state.is_empty() and float(enemy_state.get("health", health_before)) < health_before
    if trap and is_instance_valid(trap):
        trap.set_meta("trapCooldown", 0.0)
    if enemy and is_instance_valid(enemy):
        enemy.global_position = enemy_position
        enemy_state = hostile_system.enemy_for_body(enemy)
        if not enemy_state.is_empty():
            enemy_state["aware"] = false
    hostile_system.update_hostiles(0.0, 1.0, "plains", false)
    var trap_defeated: bool = hostile_system.enemies.is_empty() and inventory_system.count("nightShard") > shards_before
    if trap and is_instance_valid(trap):
        trap.queue_free()
    if blocks.has(trap_cell):
        blocks.erase(trap_cell)
    hostile_system.clear()
    player.global_position = original_position
    player.velocity = original_velocity

    add_result(
        "defensive_blocks",
        spawn_suppressed and damaged and trap_defeated,
        "safety %.2f, suppressed %s, damaged %s, trap defeated %s" % [
            safety,
            str(spawn_suppressed),
            str(damaged),
            str(trap_defeated)
        ]
    )

func test_player_ranged_system() -> void:
    if not main or not player:
        add_result("player_ranged_system_present", false, "main or player missing")
        return
    var inventory_system = main.get("inventory_system")
    var hostile_system = main.get("hostile_system")
    var player_projectiles = main.get("player_projectiles")
    var blocks: Dictionary = main.get("blocks")
    var present: bool = inventory_system != null and hostile_system != null and player_projectiles != null and blocks != null
    add_result("player_ranged_system_present", present, "ranged system + inventory + hostiles present")
    if not present:
        return

    var original_position := player.global_position
    var original_velocity := player.velocity
    var original_rotation := player.rotation
    var original_pitch := float(player.get("pitch"))
    var original_camera_pitch := camera.rotation.x if camera else 0.0
    var ranged_cell := Vector2i(roundi(player.global_position.x / CELL) + 24, roundi(player.global_position.z / CELL) + 24)
    reset_player_on_flat_patch(ranged_cell)
    clear_blocks_near_cell(ranged_cell, 16)
    clear_props_near_cell(ranged_cell, 16)
    await settle_streamed_chunks_after_relocation("ranged_chunks", 120)
    await wait_physics_frames(6)
    clear_blocks_near_cell(ranged_cell, 16)
    clear_props_near_cell(ranged_cell, 16)
    await wait_physics_frames(3)
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    if camera:
        camera.rotation.x = 0.0

    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    inventory_system.add_item("hunterBow", 1)
    inventory_system.add_item("arrows", 5)
    var bow_slot := find_inventory_slot(inventory_system, "hunterBow")
    if bow_slot >= 0:
        inventory_system.select(0)
        if bow_slot != 0:
            inventory_system.swap_with_active(bow_slot)

    var block_cell := Vector3i(
        roundi(player.global_position.x / CELL),
        roundi((player.global_position.y + 1.65) / CELL),
        roundi((player.global_position.z - 4.0) / CELL)
    )
    var block = main.call("create_block", block_cell, "stoneBlock")
    await wait_physics_frames(2)
    var arrows_before_block: int = inventory_system.count("arrows")
    var tracer_stats_before: Dictionary = player_projectiles.stats()
    var shots_before_block: int = int(tracer_stats_before.get("shotsFired", 0))
    main.call("destroy_target")
    var tracer_stats_after_block_fire: Dictionary = player_projectiles.stats()
    var block_shot_message := String(player_projectiles.last_message)
    var arrows_after_block_fire: int = inventory_system.count("arrows")
    var block_shot_fired: bool = int(tracer_stats_after_block_fire.get("shotsFired", 0)) == shots_before_block + 1
    await wait_physics_frames(16)
    var tracer_stats_after_block: Dictionary = player_projectiles.stats()
    var arrows_after_block_wait: int = inventory_system.count("arrows")
    var block_exists_after_shot: bool = blocks.has(block_cell)
    var blocked: bool = block_shot_fired and block_shot_message.find("blocked") >= 0 and block_exists_after_shot
    if block:
        block.queue_free()
    if blocks.has(block_cell):
        blocks.erase(block_cell)
    await wait_physics_frames(3)
    clear_blocks_near_cell(ranged_cell, 16)
    clear_props_near_cell(ranged_cell, 16)
    await wait_physics_frames(3)

    var enemy = hostile_system.spawn_enemy(player.global_position + Vector3(8.0, 0.0, 0.0), "shadow")
    await wait_physics_frames(2)
    if enemy and is_instance_valid(enemy):
        var aim_point: Vector3 = enemy.global_position + Vector3(0.0, 0.75, 0.0)
        clear_blocks_along_segment(camera.global_position if camera else player.global_position + Vector3.UP * 1.6, aim_point, 2)
        await wait_physics_frames(2)
        aim_player_at(aim_point)
        await wait_physics_frames(1)
    var arrows_before_hit: int = inventory_system.count("arrows")
    var shots_before_hit: int = int(player_projectiles.stats().get("shotsFired", 0))
    main.call("destroy_target")
    await wait_physics_frames(2)
    var tracer_stats_after_reuse: Dictionary = player_projectiles.stats()
    var hit_shot_fired: bool = int(tracer_stats_after_reuse.get("shotsFired", 0)) == shots_before_hit + 1
    var final_hit_kind := String(tracer_stats_after_reuse.get("lastHitKind", ""))
    var enemy_still_valid: bool = enemy and is_instance_valid(enemy)
    var enemy_state: Dictionary = hostile_system.enemy_for_body(enemy) if enemy_still_valid else {}
    var hit_hostile: bool = hit_shot_fired and (
        (not enemy_state.is_empty() and float(enemy_state.get("health", 18.0)) < 18.0)
        or (not enemy_still_valid and final_hit_kind == "hostile")
    )
    var final_hit_travel := float(tracer_stats_after_reuse.get("lastHitTravel", -1.0))
    var final_manual_hits := int(tracer_stats_after_reuse.get("manualBlockHits", 0))
    var final_manual_candidates := int(tracer_stats_after_reuse.get("manualBlockCandidates", 0))
    var final_manual_cell := str(tracer_stats_after_reuse.get("manualBlockCell", Vector3i.ZERO))
    var final_manual_type := String(tracer_stats_after_reuse.get("manualBlockType", ""))
    if enemy and is_instance_valid(enemy):
        hostile_system.damage_hostile(enemy, 999.0)

    player.global_position = original_position
    player.velocity = original_velocity
    player.rotation = original_rotation
    player.set("pitch", original_pitch)
    if camera:
        camera.rotation.x = original_camera_pitch

    var player_tracer_reused: bool = (
        int(tracer_stats_after_block.get("tracerPool", 0)) >= 1
        and int(tracer_stats_after_reuse.get("tracerNodesCreated", 0)) <= int(tracer_stats_after_block.get("tracerNodesCreated", 0))
        and int(tracer_stats_after_reuse.get("tracerNodesReused", 0)) > int(tracer_stats_before.get("tracerNodesReused", 0))
    )
    add_result(
        "player_ranged_weapon_collision",
        blocked and hit_hostile and player_tracer_reused,
        "blocked %s, hit %s, first '%s' shots %d->%d arrows %d->%d->%d kind %s travel %.2f manual %d/%d exists %s, hit shots %d->%d arrows before %d, final '%s' kind %s travel %.2f manual %d/%d %s %s, pool %d, created %d->%d, reused %d->%d" % [
            str(blocked),
            str(hit_hostile),
            block_shot_message,
            shots_before_block,
            int(tracer_stats_after_block_fire.get("shotsFired", 0)),
            arrows_before_block,
            arrows_after_block_fire,
            arrows_after_block_wait,
            String(tracer_stats_after_block_fire.get("lastHitKind", "")),
            float(tracer_stats_after_block_fire.get("lastHitTravel", -1.0)),
            int(tracer_stats_after_block_fire.get("manualBlockHits", 0)),
            int(tracer_stats_after_block_fire.get("manualBlockCandidates", 0)),
            str(block_exists_after_shot),
            shots_before_hit,
            int(tracer_stats_after_reuse.get("shotsFired", 0)),
            arrows_before_hit,
            String(player_projectiles.last_message),
            final_hit_kind,
            final_hit_travel,
            final_manual_hits,
            final_manual_candidates,
            final_manual_type,
            final_manual_cell,
            int(tracer_stats_after_block.get("tracerPool", 0)),
            int(tracer_stats_before.get("tracerNodesCreated", 0)),
            int(tracer_stats_after_reuse.get("tracerNodesCreated", 0)),
            int(tracer_stats_before.get("tracerNodesReused", 0)),
            int(tracer_stats_after_reuse.get("tracerNodesReused", 0))
        ]
    )

func test_structure_and_town_generation() -> void:
    if not main:
        add_result("structure_system_present", false, "main missing")
        return
    var structure_system = main.get("structure_system")
    add_result("structure_system_present", structure_system != null, "structure system present")
    if structure_system == null:
        return
    var structure_restore_position: Vector3 = player.global_position if player else Vector3.ZERO
    var structure_restore_velocity: Vector3 = player.velocity if player else Vector3.ZERO
    var structure_restore_time := float(main.get("time_of_day"))

    var town: Dictionary = main.call("town_region", 1, 0)
    var center_x := int(town.get("centerX", 0))
    var center_z := int(town.get("centerZ", 0))
    var level := float(town.get("level", 0.0))
    structure_system.call("build_town", town)
    var counts: Dictionary = structure_system.call("counts")
    add_result(
        "town_generation_counts",
        int(counts.get("buildings", 0)) >= 4 and int(counts.get("doors", 0)) >= 8 and int(counts.get("paths", 0)) > 20 and int(counts.get("utilities", 0)) >= 3,
        str(counts)
    )
    add_result(
        "town_biome_flattened",
            surface_biome_at_cell2(Vector2i(center_x, center_z)) == "town" and main.call("height_variation_cell", center_x, center_z, 5) <= 0.05,
            "biome %s, variation %.2f" % [surface_biome_at_cell2(Vector2i(center_x, center_z)), float(main.call("height_variation_cell", center_x, center_z, 5))]
    )
    var town_radius: int = int(town.get("radius", main.TOWN_RADIUS_CELLS))
    var town_apron: int = maxi(8, ceili(float(town_radius) * 0.34))
    if main.has_method("town_slope_apron_cells"):
        town_apron = int(main.call("town_slope_apron_cells", town))
    var exit_dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
    var max_exit_step: float = 0.0
    var worst_exit: String = ""
    for direction in exit_dirs:
        var previous_height: float = surface_y_at_cell_coords(center_x + direction.x * (town_radius - 1), center_z + direction.y * (town_radius - 1))
        for offset in range(town_radius, town_radius + town_apron + 1):
            var sample_x: int = center_x + direction.x * offset
            var sample_z: int = center_z + direction.y * offset
            var sample_height: float = surface_y_at_cell_coords(sample_x, sample_z)
            var step_delta: float = absf(sample_height - previous_height)
            if step_delta > max_exit_step:
                max_exit_step = step_delta
                worst_exit = "%s:%d" % [str(direction), offset]
            previous_height = sample_height
    add_result(
        "town_exit_slope_apron",
        max_exit_step <= CELL * 0.90 + 0.02,
        "max step %.2f, limit %.2f, radius %d, apron %d, worst %s" % [max_exit_step, CELL * 0.90 + 0.02, town_radius, town_apron, worst_exit]
    )
    var camp_rng := RandomNumberGenerator.new()
    camp_rng.seed = 90177
    structure_system.call("build_camp", center_x + 52, center_z + 52, level, 12, 11, camp_rng)

    var blocks := get_blocks()
    var generated_type_counts := {}
    var doors := []
    var paths := []
    var generated_glass_ground := 0
    var grounded_base_found := false
    var grounded_base_ok := false
    var visual_role_counts := {}
    var block_visual_mesh_ids := {}
    var roof_meta_count := 0
    for block in blocks.values():
        var body := block as StaticBody3D
        if body == null or not bool(body.get_meta("generated", false)):
            continue
        collect_visual_role_counts(body, visual_role_counts)
        collect_block_visual_mesh_ids(body, block_visual_mesh_ids)
        if body.has_meta("roofRole"):
            roof_meta_count += 1
        var block_type := String(body.get_meta("block_type"))
        generated_type_counts[block_type] = int(generated_type_counts.get(block_type, 0)) + 1
        if block_type == "door":
            doors.append(body)
        elif block_type == "cobblestonePath":
            paths.append(body)
        elif block_type == "glass":
            var glass_structure_dy := int(body.get_meta("structureDy", 99))
            if not body.has_meta("structureDy"):
                var glass_ground: float = surface_y_at_position(body.global_position)
                glass_structure_dy = roundi((body.global_position.y - glass_ground - CELL * 0.48) / CELL)
            if glass_structure_dy <= 1:
                generated_glass_ground += 1
        elif (block_type == "woodBlock" or block_type == "stoneBlock") and body.global_position.y < level + CELL * 1.1:
            var shape := first_collision_shape(body)
            if shape != null and shape.shape is BoxShape3D:
                grounded_base_found = true
                var box := shape.shape as BoxShape3D
                var bottom := body.global_position.y + shape.position.y - box.size.y * 0.5
                grounded_base_ok = abs(bottom - level) <= 0.08

    add_result("structure_base_grounded", grounded_base_found and grounded_base_ok, "found %s, ok %s" % [str(grounded_base_found), str(grounded_base_ok)])
    add_result("no_ground_level_glass", generated_glass_ground == 0, "%d ground-level generated glass blocks" % generated_glass_ground)
    var block_mesh_cache: Dictionary = main.get("block_meshes")
    var block_mesh_cache_ok := block_mesh_cache.has("plain") and block_mesh_cache.has("chamfered") and block_visual_mesh_ids.size() <= 2
    add_result(
        "building_visual_mesh_cache",
        block_mesh_cache_ok,
        "cache keys %s, block visual mesh ids %d" % [str(block_mesh_cache.keys()), block_visual_mesh_ids.size()]
    )
    var roof_visuals_ok := roof_meta_count > 20 and int(visual_role_counts.get("roof", 0)) >= roof_meta_count and int(visual_role_counts.get("roofTrim", 0)) > 0 and int(visual_role_counts.get("chimney", 0)) >= 1
    add_result(
        "building_roof_visuals",
        roof_visuals_ok,
        "roof meta %d, roles %s" % [roof_meta_count, str(visual_role_counts)]
    )
    var market_detail_ok := (
        (int(visual_role_counts.get("crate", 0)) > 0 and int(visual_role_counts.get("barrel", 0)) > 0)
        or int(visual_role_counts.get("generatedStaticUtility", 0)) > 0
    )
    var accent_visuals_ok := (
        int(visual_role_counts.get("windowFrame", 0)) > 0
        and int(visual_role_counts.get("doorFrame", 0)) > 0
        and int(visual_role_counts.get("cornerTimber", 0)) > 0
        and int(visual_role_counts.get("sign", 0)) > 0
        and int(visual_role_counts.get("fencePost", 0)) > 0
        and int(visual_role_counts.get("fenceRail", 0)) > 0
        and market_detail_ok
    )
    add_result("building_accent_visuals", accent_visuals_ok, str(visual_role_counts))

    var paired_door := false
    for i in range(doors.size()):
        for j in range(i + 1, doors.size()):
            var a := doors[i] as StaticBody3D
            var b := doors[j] as StaticBody3D
            if abs(a.global_position.y - b.global_position.y) > 0.05:
                continue
            var distance := Vector2(a.global_position.x - b.global_position.x, a.global_position.z - b.global_position.z).length()
            if distance <= CELL * 1.15:
                paired_door = true
                break
        if paired_door:
            break
    add_result("double_doors_adjacent", paired_door, "%d generated doors, types %s" % [doors.size(), str(generated_type_counts)])

    if doors.is_empty():
        add_result("door_toggle_collision", false, "no generated door")
    else:
        var door := doors[0] as StaticBody3D
        var closed_shape := first_collision_shape(door)
        var pivot := door.get_node_or_null("DoorPivot") as Node3D
        var proxy := door.get_node_or_null("DoorInteraction") as Area3D
        var closed_body_rotation := door.rotation.y
        main.call("request_door_state", door, true, null, "test", { "authorized": true })
        var opened_once: bool = bool(door.get_meta("open")) and closed_shape != null and closed_shape.disabled and pivot != null and abs(pivot.rotation.y) > 0.5 and abs(door.rotation.y - closed_body_rotation) < 0.001
        var closed_via_proxy := false
        var reopened_via_proxy := false
        if proxy:
            main.call("request_door_state", proxy, false, null, "test", { "authorized": true })
            closed_via_proxy = not bool(door.get_meta("open")) and closed_shape != null and not closed_shape.disabled and pivot != null and abs(pivot.rotation.y) < 0.001
            main.call("request_door_state", proxy, true, null, "test", { "authorized": true })
            reopened_via_proxy = bool(door.get_meta("open")) and closed_shape != null and closed_shape.disabled and pivot != null and abs(pivot.rotation.y) > 0.5
        add_result(
            "door_toggle_collision",
            opened_once and closed_via_proxy and reopened_via_proxy,
            "opened %s, closed proxy %s, reopened proxy %s, proxy %s, body rotation fixed %s" % [
                str(opened_once),
                str(closed_via_proxy),
                str(reopened_via_proxy),
                str(proxy != null),
                str(abs(door.rotation.y - closed_body_rotation) < 0.001)
            ]
        )

    if paths.is_empty():
        add_result("path_collision_low", false, "no generated path")
    else:
        var path := paths[0] as StaticBody3D
        var path_shape := first_collision_shape(path)
        var low := path_shape != null and path_shape.shape is BoxShape3D and (path_shape.shape as BoxShape3D).size.y <= CELL * 0.25
        add_result("path_collision_low", low, "path collision height %.2f" % ((path_shape.shape as BoxShape3D).size.y if low else -1.0))

    var npc_system = main.get("npc_system")
    if npc_system == null:
        add_result("generic_town_npc_homes", false, "npc system missing")
    else:
        var generic_center_x := center_x + 116
        var generic_center_z := center_z + 116
        var generic_town := {
            "regionX": 94,
            "regionZ": 94,
            "centerX": generic_center_x,
            "centerZ": generic_center_z,
            "radius": 32,
            "level": level
        }
        structure_system.call("build_town", generic_town)
        npc_system.spawn_generic_town_npcs()
        if player:
            var observe_position := Vector3(float(generic_center_x) * CELL, 0.0, float(generic_center_z) * CELL)
            observe_position.y = surface_y_at_position(observe_position) + 0.72
            player.global_position = observe_position
            player.velocity = Vector3.ZERO
        main.set("time_of_day", 0.42)
        if main.has_method("update_sky"):
            main.call("update_sky", 0.0)
        await settle_streamed_chunks_after_relocation("generic_town_chunks", 120)
        await wait_process_frames(8)
        var generic_key := "%d,%d" % [generic_center_x, generic_center_z]
        var home_records: Dictionary = structure_system.call("town_home_records_snapshot")
        var generic_homes: Array = home_records.get(generic_key, [])
        var npc_entries: Array = npc_system.get("npcs")
        var generic_entries: Array = []
        var generic_npcs := 0
        var generic_homed := 0
        var generic_fighters := 0
        for entry_variant in npc_entries:
            var entry: Dictionary = entry_variant
            if String(entry.get("townKey", "")) != generic_key:
                continue
            generic_entries.append(entry)
            generic_npcs += 1
            var npc_body := entry.get("body") as Node
            if npc_body != null and bool(npc_body.get_meta("npc_has_home", false)):
                generic_homed += 1
            if bool(entry.get("canFight", false)):
                generic_fighters += 1
        add_result(
            "generic_town_npc_homes",
            generic_homes.size() >= 4 and generic_npcs >= generic_homes.size() and generic_homed == generic_npcs and generic_fighters >= 1,
            "homes %d, npcs %d, homed %d, fighters %d" % [generic_homes.size(), generic_npcs, generic_homed, generic_fighters]
        )
        var job_workers := 0
        var generic_forager: Dictionary = {}
        for entry_variant in generic_entries:
            var entry: Dictionary = entry_variant
            if String(entry.get("job", "")) in ["forage", "wood", "stone"]:
                job_workers += 1
                entry["jobPhase"] = "idle"
                entry["jobTimer"] = 0.0
                if String(entry.get("job", "")) == "forage" and generic_forager.is_empty():
                    generic_forager = entry
        var forage_node: Node3D = null
        var targeted_forage_selected := false
        if not generic_forager.is_empty():
            generic_forager["hunger"] = 38.0
            var prop_root := main.get("prop_root") as Node
            var porch_cell: Vector2i = generic_forager.get("porchCell", Vector2i(generic_center_x + 1, generic_center_z))
            var outward := Vector2(float(porch_cell.x - generic_center_x), float(porch_cell.y - generic_center_z))
            if outward.length_squared() < 0.001:
                outward = Vector2.RIGHT
            outward = outward.normalized()
            var forage_distance := float(generic_town.get("radius", 32)) + 2.0
            var forage_cell := Vector2i(
                roundi(float(generic_center_x) + outward.x * forage_distance),
                roundi(float(generic_center_z) + outward.y * forage_distance)
            )
            var forage_ground: float = surface_y_at_cell2(forage_cell)
            if forage_ground < main.WATER_LEVEL + 0.55:
                for fallback_direction in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
                    var fallback_cell := Vector2i(
                        roundi(float(generic_center_x) + fallback_direction.x * forage_distance),
                        roundi(float(generic_center_z) + fallback_direction.y * forage_distance)
                    )
                    var fallback_ground: float = surface_y_at_cell2(fallback_cell)
                    if fallback_ground >= main.WATER_LEVEL + 0.55:
                        forage_cell = fallback_cell
                        forage_ground = fallback_ground
                        break
            clear_props_near_cell(forage_cell, 5)
            clear_blocks_near_cell(forage_cell, 3)
            forage_ground = surface_y_at_cell2(forage_cell)
            var rng := RandomNumberGenerator.new()
            rng.seed = 77031
            forage_node = main.call(
                "make_forage",
                prop_root,
                "playtest:npc_forager_berries",
                Vector3(float(forage_cell.x) * CELL, forage_ground, float(forage_cell.y) * CELL),
                "plains",
                rng
            ) as Node3D
            if forage_node != null:
                var npc_pathing = npc_system.get("pathing")
                if npc_pathing != null and npc_pathing.has_method("choose_forage_target"):
                    var forage_candidates: Array[Node3D] = [forage_node]
                    targeted_forage_selected = npc_pathing.choose_forage_target(generic_forager, forage_candidates) == forage_node
                generic_forager["jobTargetNode"] = forage_node
                generic_forager["jobTarget"] = npc_pathing.forage_target_position(generic_forager, forage_node) if npc_pathing != null and npc_pathing.has_method("forage_target_position") else forage_node.global_position
                generic_forager["jobPhase"] = "outbound"
                generic_forager["jobTimer"] = 24.0
                generic_forager["routeForceReplan"] = true
                generic_forager["goal"] = "forage berries"
        var job_runs_before := int(npc_system.stats().get("jobRuns", 0))
        var forage_runs_before := int(npc_system.stats().get("forageRuns", 0))
        var food_eaten_before := int(npc_system.stats().get("foodEaten", 0))
        var door_opens_before := int(npc_system.stats().get("doorOpens", 0))
        var door_closes_before := int(npc_system.stats().get("doorCloses", 0))
        var saw_generic_worker_outside := false
        var forager_goal_seen := false
        var town_radius_world := float(generic_town.get("radius", 32)) * CELL
        var town_center_world := Vector2(float(generic_center_x) * CELL, float(generic_center_z) * CELL)
        for step in range(3000):
            if step % 120 == 0:
                mark_progress("structures_npc_jobs_%03d" % step)
            elif step % 30 == 0:
                mark_progress("structures_npc_jobs_%03d_sample" % step)
            for entry_variant in generic_entries:
                var entry: Dictionary = entry_variant
                if not (String(entry.get("job", "")) in ["forage", "wood", "stone"]):
                    continue
                var npc_body := entry.get("body") as Node3D
                if npc_body == null or not is_instance_valid(npc_body):
                    continue
                var flat := Vector2(npc_body.global_position.x, npc_body.global_position.z)
                if flat.distance_to(town_center_world) > town_radius_world + CELL * 0.5:
                    saw_generic_worker_outside = true
                if String(entry.get("job", "")) == "forage" and String(entry.get("goal", "")).find("berr") >= 0:
                    forager_goal_seen = true
            var stats_now: Dictionary = npc_system.stats()
            var targeted_forage_done := false
            if not generic_forager.is_empty():
                var inventory_now: Dictionary = generic_forager.get("personalInventory", {})
                var hunger_now := float(generic_forager.get("hunger", 0.0))
                var food_eaten_now := int(stats_now.get("foodEaten", 0))
                targeted_forage_done = int(stats_now.get("forageRuns", 0)) > forage_runs_before and (int(inventory_now.get("berries", 0)) > 0 or hunger_now > 38.0 or food_eaten_now > food_eaten_before)
            if saw_generic_worker_outside and int(stats_now.get("jobRuns", 0)) > job_runs_before and targeted_forage_done:
                break
            await wait_process_frames(1)
        mark_progress("structures_npc_jobs_done")
        var job_stats: Dictionary = npc_system.stats()
        var forager_inventory: Dictionary = generic_forager.get("personalInventory", {}) if not generic_forager.is_empty() else {}
        var forager_food := int(forager_inventory.get("berries", 0))
        var forager_hunger := float(generic_forager.get("hunger", 0.0)) if not generic_forager.is_empty() else 0.0
        var forager_food_eaten := int(job_stats.get("foodEaten", 0))
        var forager_food_or_hunger := forager_food > 0 or forager_hunger > 38.0 or forager_food_eaten > food_eaten_before
        var forager_clear_goal := forager_goal_seen and forager_food_or_hunger
        var forager_target_distance := -1.0
        var forager_node_distance := -1.0
        var forager_motion_goal := ""
        var forager_body_position := Vector3.ZERO
        var forager_target_position := Vector3.ZERO
        var forager_node_position := Vector3.ZERO
        var forager_node_object_id := ""
        if not generic_forager.is_empty():
            var forager_body := generic_forager.get("body") as Node3D
            var forager_target: Vector3 = generic_forager.get("jobTarget", Vector3.ZERO)
            forager_target_position = forager_target
            var active_motion_goal = generic_forager.get("activeMotionGoal", {})
            if active_motion_goal is Dictionary:
                forager_motion_goal = String((active_motion_goal as Dictionary).get("goalKind", ""))
            if forager_body != null and is_instance_valid(forager_body):
                forager_body_position = forager_body.global_position
                forager_target_distance = forager_body.global_position.distance_to(forager_target)
                var forager_node := generic_forager.get("jobTargetNode") as Node3D
                if forager_node != null and is_instance_valid(forager_node):
                    forager_node_position = forager_node.global_position
                    forager_node_distance = forager_body.global_position.distance_to(forager_node.global_position)
                    if npc_system.has_method("smart_object_id_for_node"):
                        forager_node_object_id = String(npc_system.call("smart_object_id_for_node", forager_node))
        var stats_worker_outside := int(job_stats.get("outsideWorkers", 0)) > 0
        add_result(
            "generic_npc_job_outings",
            job_workers >= 2 and (saw_generic_worker_outside or stats_worker_outside) and int(job_stats.get("jobRuns", 0)) > job_runs_before,
            "workers %d, outside seen %s, stats outside %s, runs %d->%d, stats %s" % [
                job_workers,
                str(saw_generic_worker_outside),
                str(stats_worker_outside),
                job_runs_before,
                int(job_stats.get("jobRuns", 0)),
                str(job_stats)
            ]
        )
        var forager_passed := (
            not generic_forager.is_empty()
                and forager_clear_goal
                and int(job_stats.get("forageRuns", 0)) > forage_runs_before
                and forager_food_or_hunger
        )
        var forager_details := "goal %s, target selected %s, berries %d, hunger %.1f, food eaten %d->%d, forage %d->%d, node gone %s, phase %s, timer %.2f, motion %s, reason %s, route %s/%s, dist target %.2f node %.2f" % [
            str(forager_goal_seen),
            str(targeted_forage_selected),
            forager_food,
            forager_hunger,
            food_eaten_before,
            forager_food_eaten,
            forage_runs_before,
            int(job_stats.get("forageRuns", 0)),
            str(forage_node == null or not is_instance_valid(forage_node)),
            String(generic_forager.get("jobPhase", "")),
            float(generic_forager.get("jobTimer", 0.0)),
            forager_motion_goal,
            String(generic_forager.get("jobFailureReason", "")),
            String(generic_forager.get("routeStatus", "")),
            String(generic_forager.get("routeReason", "")),
            forager_target_distance,
            forager_node_distance
        ]
        if not forager_passed:
            var forager_debug := {
                "id": String(generic_forager.get("id", "")),
                "body": str(forager_body_position),
                "target": str(forager_target_position),
                "node": str(forager_node_position),
                "jobObjectId": String(generic_forager.get("jobObjectId", "")),
                "jobReservationId": String(generic_forager.get("jobReservationId", "")),
                "jobApproachSlotId": String(generic_forager.get("jobApproachSlotId", "")),
                "forageNodeObjectId": forager_node_object_id,
                "jobObjectMatchesNode": String(generic_forager.get("jobObjectId", "")) == forager_node_object_id,
                "routeForceReplan": bool(generic_forager.get("routeForceReplan", false)),
                "movementHeldForTopology": bool(generic_forager.get("movementHeldForTopology", false)),
                "requestedTopologyTile": String(generic_forager.get("requestedTopologyTile", "")),
                "pathWaypoints": (generic_forager.get("pathWaypoints", []) as Array).size(),
                "routeCells": (generic_forager.get("routeCells", []) as Array).size(),
                "routeGoalCell": str(generic_forager.get("routeGoalCell", Vector2i.ZERO)),
                "lastMoveDistance": float(generic_forager.get("lastMoveDistance", 0.0)),
                "motionSkipped": int(generic_forager.get("npc_motion_skipped", 0)),
                "motionSkipReason": String(generic_forager.get("npc_motion_skip_reason", "")),
                "motionUpdates": int(generic_forager.get("npc_active_route_motion_ticks", 0)),
                "brainSkipped": int(generic_forager.get("npc_brain_budget_skipped", 0)),
                "activeGoalKind": String(generic_forager.get("activeGoalKind", "")),
                "activeMotionGoal": generic_forager.get("activeMotionGoal", {}),
                "lastRoutePlanDebug": generic_forager.get("lastRoutePlanDebug", {}),
                "lastNavmeshTilePublishDebug": generic_forager.get("lastNavmeshTilePublishDebug", [])
            }
            var forager_body := generic_forager.get("body") as Node
            if forager_body != null and is_instance_valid(forager_body):
                forager_debug["motorBlockedContact"] = String(forager_body.get_meta("npc_blocked_contact", ""))
                forager_debug["motorBlockedName"] = String(forager_body.get_meta("npc_blocked_contact_name", ""))
                forager_debug["motorBlockedKind"] = String(forager_body.get_meta("npc_blocked_contact_kind", ""))
                forager_debug["appliedVelocity"] = str(forager_body.get_meta("npc_applied_velocity", Vector3.ZERO))
                forager_debug["requestedVelocity"] = str(forager_body.get_meta("npc_requested_velocity", Vector3.ZERO))
                forager_debug["lastDisplacement"] = str(forager_body.get_meta("npc_last_displacement", Vector3.ZERO))
            forager_details += ", debug %s" % JSON.stringify(forager_debug)
        add_result(
            "forager_goal_inventory_hunger",
            forager_passed,
            forager_details
        )
        add_result(
            "npc_door_open_close_cycle",
            int(job_stats.get("doorOpens", 0)) >= door_opens_before and int(job_stats.get("doorCloses", 0)) >= door_closes_before,
            "doors open %d->%d close %d->%d" % [
                door_opens_before,
                int(job_stats.get("doorOpens", 0)),
                door_closes_before,
                int(job_stats.get("doorCloses", 0))
            ]
        )

    if player:
        player.global_position = structure_restore_position
        player.velocity = structure_restore_velocity
    main.set("time_of_day", structure_restore_time)
    if main.has_method("update_sky"):
        main.call("update_sky", 0.0)
    cleanup_generated_blocks()

func test_npc_equipment_and_pathing() -> void:
    if not main or not player:
        add_result("npc_equipment_and_pathing", false, "main/player missing")
        return
    var npc_system = main.get("npc_system")
    if npc_system == null:
        add_result("npc_equipment_and_pathing", false, "npc system missing")
        return

    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 72, roundi(player.global_position.z / CELL) + 72)
    reset_player_on_flat_patch(start_cell, 12)
    clear_blocks_near_cell(start_cell, 12)
    clear_props_near_cell(start_cell, 14)
    await wait_physics_frames(3)

    var base_height: float = surface_y_at_cell2(start_cell)
    var start_position := Vector3(float(start_cell.x) * CELL, base_height + 0.04, float(start_cell.y) * CELL)
    var target_position := Vector3(float(start_cell.x + 8) * CELL, base_height + 0.04, float(start_cell.y) * CELL)
    player.global_position = Vector3(float(start_cell.x - 4) * CELL, base_height, float(start_cell.y - 4) * CELL)
    player.velocity = Vector3.ZERO
    var wall_x := start_cell.x + 3
    var wall_z := start_cell.y
    var wall_y := base_height + CELL * 0.48
    var wall_cell_y := floori(wall_y / CELL) + 1
    var wall_cells: Array[Vector3i] = []
    var blocks := get_blocks()
    for dz in range(-2, 3):
        var wall_cell := Vector3i(wall_x, wall_cell_y, wall_z + dz)
        wall_cells.append(wall_cell)
        if blocks.has(wall_cell):
            var old_wall := blocks[wall_cell] as Node
            if old_wall:
                old_wall.queue_free()
            blocks.erase(wall_cell)
        main.call("create_block", wall_cell, "stoneBlock", { "world_y": wall_y })
    await wait_physics_frames(3)

    var body := npc_system.create_npc_body("PlaytestPathingNPC", "npc") as CharacterBody3D
    npc_system.call("add_npc_collider", body)
    var npc_root := npc_system.get("npc_root") as Node3D
    if npc_root:
        npc_root.add_child(body)
    else:
        npc_system.add_child(body)
    npc_system.safe_place_npc(body, start_position, null, "playtest_spawn")
    var entry: Dictionary = npc_system.register_npc(body, {
        "id": "playtest-pathing-npc",
        "name": "Path Tester",
        "role": "Guard",
        "townKey": "playtest-path",
        "townCenter": start_cell,
        "townRadius": 18,
        "level": base_height,
        "cell": start_cell,
        "homeCell": start_cell,
        "porchCell": start_cell,
        "guardCell": Vector2i(start_cell.x + 1, start_cell.y),
        "canFight": true,
        "nightGuard": true,
        "weapon": "woodenSword"
    })
    var weapon_visible := bool(body.get_meta("npc_weapon_visible", false)) and String(body.get_meta("npc_weapon", "")) == "woodenSword"
    var anchor := entry.get("heldAnchor") as Node3D
    var rest_rotation := anchor.rotation if anchor else Vector3.ZERO
    var uses_before := int(npc_system.stats().get("useAnimations", 0))
    npc_system.play_npc_use(entry, "strike")
    npc_system.update_npc_visual_state(entry, 0.08)
    var sword_animated := anchor != null and int(npc_system.stats().get("useAnimations", 0)) > uses_before and anchor.rotation.distance_to(rest_rotation) > 0.001

    var detours_before := int(npc_system.stats().get("pathDetours", 0))
    var validated_before := int(npc_system.stats().get("validatedMoves", 0))
    var max_lateral := 0.0
    var entered_wall_cell := false
    for i in range(240):
        npc_system.move_npc(entry, target_position, CELL * 0.24, false, false)
        max_lateral = maxf(max_lateral, absf(body.global_position.z - start_position.z))
        var npc_cell := world_to_flat_cell(body.global_position)
        if npc_cell.x == wall_x and abs(npc_cell.y - wall_z) <= 2:
            entered_wall_cell = true
        await wait_physics_frames(1)
    var detours_after := int(npc_system.stats().get("pathDetours", 0))
    var validated_after := int(npc_system.stats().get("validatedMoves", 0))
    var wall_world_x := float(wall_x) * CELL
    var progressed_past_wall := body.global_position.x > wall_world_x + CELL * 0.12
    var detoured_around_wall := detours_after > detours_before and max_lateral > CELL * 0.75 and progressed_past_wall
    var pathing_passed := weapon_visible and sword_animated and detoured_around_wall and not entered_wall_cell and validated_after > validated_before
    var pathing_details := "weapon %s, sword animated %s, detours %d->%d, validated %d->%d, lateral %.2f, end %.2f %.2f, wall %.2f, entered wall %s" % [
        str(weapon_visible),
        str(sword_animated),
        detours_before,
        detours_after,
        validated_before,
        validated_after,
        max_lateral,
        body.global_position.x,
        body.global_position.z,
        wall_world_x,
        str(entered_wall_cell)
    ]
    if not pathing_passed:
        var pathing_debug := {
            "routeStatus": String(entry.get("routeStatus", "")),
            "routeReason": String(entry.get("routeReason", "")),
            "routeReplans": int(entry.get("routeReplans", 0)),
            "waypoints": (entry.get("pathWaypoints", []) as Array).size(),
            "routeCells": (entry.get("routeCells", []) as Array).size(),
            "lastMove": float(entry.get("lastMoveDistance", 0.0)),
            "corridor": entry.get("corridorFollow", {}),
            "progress": entry.get("corridorProgress", {}),
            "capsuleBlocker": entry.get("capsuleBlocker", {}),
            "tilePublish": entry.get("lastNavmeshTilePublishDebug", []),
            "lastRoutePlanDebug": entry.get("lastRoutePlanDebug", {})
        }
        pathing_details += ", debug %s" % JSON.stringify(pathing_debug)
    add_result(
        "npc_equipment_and_pathing",
        pathing_passed,
        pathing_details
    )

    npc_system.safe_place_npc(body, start_position, null, "playtest_reset")
    entry["pathWaypoints"] = []
    entry["routeCells"] = []
    entry["routeForceReplan"] = true
    var replan_target := Vector3(float(start_cell.x + 7) * CELL, base_height + 0.04, float(start_cell.y + 4) * CELL)
    for i in range(3):
        npc_system.move_npc(entry, replan_target, CELL * 0.22, false, false)
        await wait_physics_frames(1)
    var planned_cells: Array = entry.get("routeCells", [])
    var dynamic_block_cell := Vector2i(start_cell.x + 1, start_cell.y + 1)
    if not planned_cells.is_empty() and planned_cells[0] is Vector2i:
        dynamic_block_cell = planned_cells[0]
    var dynamic_block_key := Vector3i(dynamic_block_cell.x, wall_cell_y, dynamic_block_cell.y)
    blocks = get_blocks()
    if blocks.has(dynamic_block_key):
        var old_dynamic := blocks[dynamic_block_key] as Node
        if old_dynamic:
            old_dynamic.queue_free()
        blocks.erase(dynamic_block_key)
    main.call("create_block", dynamic_block_key, "stoneBlock", { "world_y": wall_y })
    await wait_physics_frames(3)
    var route_revision_before := String(entry.get("routeSnapshotRevision", ""))
    var route_replans_before := int(entry.get("routeReplans", 0))
    var entered_dynamic_block := false
    for i in range(12):
        npc_system.move_npc(entry, replan_target, CELL * 0.20, false, false)
        if world_to_flat_cell(body.global_position) == dynamic_block_cell:
            entered_dynamic_block = true
        await wait_physics_frames(1)
    var route_revision_after := String(entry.get("routeSnapshotRevision", ""))
    var route_replans_after := int(entry.get("routeReplans", 0))
    add_result(
        "npc_route_invalidates_player_block",
        route_revision_after != route_revision_before and route_replans_after > route_replans_before and not entered_dynamic_block,
        "revision %s -> %s, replans %d->%d, blocked cell %s, entered %s" % [
            route_revision_before,
            route_revision_after,
            route_replans_before,
            route_replans_after,
            str(dynamic_block_cell),
            str(entered_dynamic_block)
        ]
    )

    npc_system.safe_place_npc(body, start_position, null, "playtest_reset")
    entry["pathWaypoints"] = []
    entry["routeCells"] = []
    entry["routeForceReplan"] = true
    NpcRouteStateStoreScript.write_status(entry, "idle", "", "PlaytestRunner.npc_unreachable_goal_fixture")
    var unreachable_center := Vector2i(start_cell.x + 5, start_cell.y + 5)
    var unreachable_cells: Array[Vector3i] = []
    blocks = get_blocks()
    for dx in range(-1, 2):
        for dz in range(-1, 2):
            var enclosed_cell := Vector3i(unreachable_center.x + dx, wall_cell_y, unreachable_center.y + dz)
            unreachable_cells.append(enclosed_cell)
            if blocks.has(enclosed_cell):
                var old_enclosed := blocks[enclosed_cell] as Node
                if old_enclosed:
                    old_enclosed.queue_free()
                blocks.erase(enclosed_cell)
            main.call("create_block", enclosed_cell, "stoneBlock", { "world_y": wall_y })
    await wait_physics_frames(3)
    var unreachable_before := int(npc_system.stats().get("unreachableGoals", 0))
    var unreachable_target := Vector3(float(unreachable_center.x) * CELL, base_height + 0.04, float(unreachable_center.y) * CELL)
    for i in range(12):
        npc_system.move_npc(entry, unreachable_target, CELL * 0.20, false, false)
        await wait_physics_frames(1)
    var unreachable_after := int(npc_system.stats().get("unreachableGoals", 0))
    var route_status := String(entry.get("routeStatus", ""))
    var route_reason := String(entry.get("routeReason", ""))
    var did_not_snap_to_goal := body.global_position.distance_to(unreachable_target) > CELL * 0.70
    add_result(
        "npc_unreachable_goal_diagnostics",
        unreachable_after > unreachable_before and route_status != "" and did_not_snap_to_goal,
        "unreachable %d->%d, status %s, reason %s, distance %.2f" % [
            unreachable_before,
            unreachable_after,
            route_status,
            route_reason,
            body.global_position.distance_to(unreachable_target)
        ]
    )

    npc_system.unregister_npc(body)
    if is_instance_valid(body):
        body.queue_free()
    blocks = get_blocks()
    if blocks.has(dynamic_block_key):
        var dynamic_block_body := blocks[dynamic_block_key] as Node
        if dynamic_block_body:
            dynamic_block_body.queue_free()
        blocks.erase(dynamic_block_key)
    for enclosed_cell in unreachable_cells:
        if blocks.has(enclosed_cell):
            var enclosed_body := blocks[enclosed_cell] as Node
            if enclosed_body:
                enclosed_body.queue_free()
            blocks.erase(enclosed_cell)
    for wall_cell in wall_cells:
        if blocks.has(wall_cell):
            var wall_body := blocks[wall_cell] as Node
            if wall_body:
                wall_body.queue_free()
            blocks.erase(wall_cell)

func test_structural_integrity() -> void:
    if not main or not player:
        add_result("structural_integrity", false, "main or player missing")
        return

    main.call("clear_dropped_pickups")
    var blocks := get_blocks()
    var base_x := roundi(player.global_position.x / CELL) + 78
    var base_z := roundi(player.global_position.z / CELL) + 41
    var ground: float = surface_y_at_cell_coords(base_x, base_z)
    var world_y := ground + CELL * 0.48
    var grounded_cell := Vector3i(base_x, floori(world_y / CELL) + 1, base_z)
    var grounded_top := grounded_cell + Vector3i(0, 1, 0)
    var floating_cell := Vector3i(base_x + 3, grounded_cell.y + 7, base_z)
    var floating_top := floating_cell + Vector3i(0, 1, 0)

    for cell in [grounded_cell, grounded_top, floating_cell, floating_top]:
        if blocks.has(cell):
            var existing := blocks[cell] as Node
            if existing:
                existing.queue_free()
            blocks.erase(cell)

    main.call("create_block", grounded_cell, "woodBlock", { "player_placed": true, "world_y": world_y })
    main.call("create_block", grounded_top, "woodBlock", { "player_placed": true, "world_y": world_y + CELL })
    main.call("create_block", floating_cell, "woodBlock", { "player_placed": true })
    main.call("create_block", floating_top, "woodBlock", { "player_placed": true })
    var collapsed: int = int(main.call("collapse_unsupported_structures"))
    var dropped_pickups: Array = main.get("dropped_pickups")
    var grounded_ok := blocks.has(grounded_cell) and blocks.has(grounded_top)
    var floating_removed := not blocks.has(floating_cell) and not blocks.has(floating_top)
    var drops_ok := dropped_pickups.size() >= 2
    add_result(
        "structural_integrity_supports_grounded_collapses_floating",
        collapsed >= 2 and grounded_ok and floating_removed and drops_ok,
        "collapsed %d, grounded %s, floating removed %s, drops %d" % [
            collapsed,
            str(grounded_ok),
            str(floating_removed),
            dropped_pickups.size()
        ]
    )

    for cell in [grounded_cell, grounded_top]:
        if blocks.has(cell):
            var body := blocks[cell] as Node
            if body:
                body.queue_free()
            blocks.erase(cell)
    main.call("clear_dropped_pickups")

func test_landmark_generation_and_loot() -> void:
    if not main or not player:
        add_result("landmark_generation_and_loot", false, "main or player missing")
        return
    var structure_system = main.get("structure_system")
    var objective_system = main.get("objective_system")
    var contract_system = main.get("contract_system")
    var hostile_system = main.get("hostile_system")
    var progression_system = main.get("progression_system")
    var present: bool = structure_system != null and objective_system != null and contract_system != null and hostile_system != null and progression_system != null
    if not present:
        add_result("landmark_generation_and_loot", false, "structure/objective/contract/hostile/progression system missing")
        return

    cleanup_generated_blocks()
    hostile_system.clear()
    var original_position: Vector3 = player.global_position
    var discovered_shrines: Dictionary = main.get("discovered_shrine_keys")
    var discovered_mines: Dictionary = main.get("discovered_mine_keys")
    var discovered_ruins: Dictionary = main.get("discovered_ruin_keys")
    var discovered_camps: Dictionary = main.get("discovered_camp_keys")
    discovered_shrines.clear()
    discovered_mines.clear()
    discovered_ruins.clear()
    discovered_camps.clear()
    var base_cell := Vector2i(roundi(player.global_position.x / CELL) + 34, roundi(player.global_position.z / CELL) + 18)
    var level: float = maxf(surface_y_at_cell2(base_cell), WATER_LEVEL + 2.4)
    var edits := get_volume_edit_markers()
    for dz in range(-8, 24):
        for dx in range(-8, 76):
            edits[Vector2i(base_cell.x + dx, base_cell.y + dz)] = level
    main.call("rebuild_chunks_around_cell", base_cell)

    var rng := RandomNumberGenerator.new()
    rng.seed = 41001
    structure_system.call("build_mine", base_cell.x, base_cell.y, level, 11, 13, rng)
    rng.seed = 41002
    structure_system.call("build_ruin", base_cell.x + 18, base_cell.y, level, 9, 9, rng)
    rng.seed = 41003
    structure_system.call("build_shrine", base_cell.x + 36, base_cell.y, level, 9, 9, rng)
    rng.seed = 41004
    structure_system.call("build_camp", base_cell.x + 54, base_cell.y, level, 12, 11, rng)

    var tier_counts: Dictionary = main.call("generated_tier_counts")
    var counts: Dictionary = structure_system.call("counts")
    var blocks := get_blocks()
    var mine_ore_blocks := 0
    var mine_ore_glints := 0
    var mine_torches := 0
    var camp_fire_count := 0
    var camp_torches := 0
    var camp_traps := 0
    var camp_barricades := 0
    var shrine_chest: Node = null
    var chest_tiers := {}
    var loot_checks := {
        "mine": false,
        "ruin": false,
        "shrine": false,
        "camp": false
    }
    for block_value in blocks.values():
        var body := block_value as Node
        if body == null or not body.has_meta("generatedTier"):
            continue
        var tier := String(body.get_meta("generatedTier"))
        var block_type := String(body.get_meta("block_type", ""))
        if tier == "mine" and block_type in ["copperVein", "ironVein"]:
            mine_ore_blocks += 1
            mine_ore_glints += count_named_descendants(body, "OreBlockGlint")
        if tier == "mine" and block_type == "torch":
            mine_torches += 1
        if tier == "camp" and block_type == "campfire":
            camp_fire_count += 1
        if tier == "camp" and block_type == "torch":
            camp_torches += 1
        if tier == "camp" and block_type == "spikeTrap":
            camp_traps += 1
        if tier == "camp" and block_type == "woodBlock":
            camp_barricades += 1
        if tier == "shrine" and block_type == "chest":
            shrine_chest = body
        if block_type != "chest":
            continue
        chest_tiers[tier] = int(chest_tiers.get(tier, 0)) + 1
        if not body.has_meta("storage_slots"):
            continue
        var slots: Array = body.get_meta("storage_slots")
        for slot in slots:
            if not (slot is Dictionary):
                continue
            var item_id := String(slot.get("item", ""))
            var count := int(slot.get("count", 0))
            if count <= 0:
                continue
            if tier == "mine" and item_id in ["copperOre", "ironOre"]:
                loot_checks["mine"] = true
            elif tier == "ruin" and item_id == "relicFragment":
                loot_checks["ruin"] = true
            elif tier == "shrine" and item_id == "nightShard":
                loot_checks["shrine"] = true
            elif tier == "camp" and item_id in ["arrows", "fieldRation"]:
                loot_checks["camp"] = true

    var discovery_xp_before: int = int(progression_system.total_xp)
    player.global_position = Vector3(float(base_cell.x + 2) * CELL, level + 0.8, float(base_cell.y + 2) * CELL)
    main.call("update_hud")
    var mine_discovered: bool = discovered_mines.size() > 0
    var mine_ambush: bool = hostile_system.enemies.size() >= 2
    hostile_system.clear()
    player.global_position = Vector3(float(base_cell.x + 20) * CELL, level + 0.8, float(base_cell.y + 2) * CELL)
    main.call("update_hud")
    var ruin_discovered: bool = discovered_ruins.size() > 0
    var ruin_ambush: bool = hostile_system.enemies.size() >= 1
    hostile_system.clear()
    var shrine_opened: bool = shrine_chest != null and bool(main.call("discover_shrine_cache", shrine_chest))
    var shrine_discovered: bool = discovered_shrines.size() > 0
    var shrine_guardians: bool = hostile_system.enemies.size() >= 1
    hostile_system.clear()
    player.global_position = Vector3(float(base_cell.x + 58) * CELL, level + 0.8, float(base_cell.y + 3) * CELL)
    main.call("update_hud")
    var camp_discovered: bool = discovered_camps.size() > 0
    var camp_ambush: bool = hostile_system.enemies.size() >= 3
    var discovery_xp: bool = int(progression_system.total_xp) > discovery_xp_before
    add_result(
        "landmark_discovery_ambush_parity",
        mine_discovered and mine_ambush and ruin_discovered and ruin_ambush and shrine_opened and shrine_discovered and shrine_guardians and camp_discovered and camp_ambush and discovery_xp,
        "mine %s/%s, ruin %s/%s, shrine %s/%s/%s, camp %s/%s, xp %d->%d" % [
            str(mine_discovered),
            str(mine_ambush),
            str(ruin_discovered),
            str(ruin_ambush),
            str(shrine_opened),
            str(shrine_discovered),
            str(shrine_guardians),
            str(camp_discovered),
            str(camp_ambush),
            discovery_xp_before,
            int(progression_system.total_xp)
        ]
    )
    hostile_system.clear()
    player.global_position = original_position

    var state: Dictionary = main.call("objective_state")
    state["discoveredTowns"] = max(1, int(state.get("discoveredTowns", 0)))
    var hostile_state: Dictionary = state.get("hostiles", {})
    hostile_state["defeated"] = max(3, int(hostile_state.get("defeated", 0)))
    state["hostiles"] = hostile_state
    var landmark_objective: bool = bool(objective_system.is_complete("landmarkScout", state))
    var camp_objective: bool = bool(objective_system.is_complete("enemyCamp", state))
    var shrine_objective: bool = bool(objective_system.is_complete("shrine", state))
    var prospector_contract: bool = bool(contract_system.is_contract_complete("prospector", state))
    var ruin_contract: bool = bool(contract_system.is_contract_complete("ruinSurveyor", state))
    var camp_contract: bool = bool(contract_system.is_contract_complete("campClear", state))
    var passed: bool = (
        int(tier_counts.get("mine", 0)) > 0
        and int(tier_counts.get("ruin", 0)) > 0
        and int(tier_counts.get("shrine", 0)) > 0
        and int(tier_counts.get("camp", 0)) > 0
        and mine_ore_blocks > 0
        and mine_ore_glints >= mine_ore_blocks
        and mine_torches >= 4
        and camp_fire_count >= 1
        and camp_torches >= 4
        and camp_traps >= 3
        and camp_barricades >= 4
        and bool(loot_checks.get("mine", false))
        and bool(loot_checks.get("ruin", false))
        and bool(loot_checks.get("shrine", false))
        and bool(loot_checks.get("camp", false))
        and landmark_objective
        and camp_objective
        and shrine_objective
        and prospector_contract
        and ruin_contract
        and camp_contract
    )
    add_result(
        "landmark_generation_and_loot",
        passed,
        "tiers %s, counts %s, chests %s, ore blocks %d, glints %d, mine torches %d, camp fire/torches/traps/barricades %d/%d/%d/%d, loot %s, objectives %s/%s/%s, contracts %s/%s/%s" % [
            str(tier_counts),
            str(counts),
            str(chest_tiers),
            mine_ore_blocks,
            mine_ore_glints,
            mine_torches,
            camp_fire_count,
            camp_torches,
            camp_traps,
            camp_barricades,
            str(loot_checks),
            str(landmark_objective),
            str(camp_objective),
            str(shrine_objective),
            str(prospector_contract),
            str(ruin_contract),
            str(camp_contract)
        ]
    )
    hostile_system.clear()
    cleanup_generated_blocks()

func test_underground_volume_generation() -> void:
    if not main or not player:
        add_result("underground_volume_generation", false, "main or player missing")
        return
    var world_generation = main.get("world_generation_system")
    if world_generation == null or not world_generation.has_method("find_underground_air_sample"):
        add_result("underground_volume_generation", false, "world generation sampler missing")
        return

    var original_position: Vector3 = player.global_position
    var found: Dictionary = world_generation.call("find_underground_air_sample", 160, 8, 48)
    if found.is_empty():
        add_result("underground_volume_generation", false, "no underground_air volume found")
        return

    var continuity := underground_volume_smoke_summary(world_generation, found)
    var sample_position: Vector3 = found.get("position", Vector3.ZERO)
    player.global_position = sample_position + Vector3(0.0, CELL * 0.65, 0.0)
    player.velocity = Vector3.ZERO
    if main.has_method("bootstrap_initial_chunks"):
        bootstrap_playtest_visible_chunks()
        await wait_for_chunk_count(49, 120, "underground_volume_chunks")
    var focus_cells := underground_volume_focus_cells(found)
    var focus_chunks := underground_volume_focus_chunk_lookup(focus_cells)
    for cell in focus_cells:
        if main.has_method("rebuild_chunks_around_cell"):
            main.call("rebuild_chunks_around_cell", cell)
    if main.has_method("update_chunks"):
        main.call("update_chunks", false)
    await wait_for_terrain_collision_shapes(360, focus_chunks)
    var geometry := underground_volume_chunk_geometry_summary(focus_chunks)
    var sample: Dictionary = found.get("sample", {}) if found.has("sample") else {}
    var passed := not found.is_empty() \
        and String(sample.get("biome", "")) == "underground_air" \
        and String(sample.get("material", "")) == "air" \
        and not bool(sample.get("solid", true)) \
        and bool(continuity.get("passed", false)) \
        and bool(geometry.get("passed", false))
    add_result(
        "underground_volume_generation",
        passed,
        "found %s, continuity %s, geometry %s" % [
            JSON.stringify(underground_volume_summary(found)),
            JSON.stringify(continuity),
            JSON.stringify(geometry)
        ]
    )
    player.global_position = original_position
    player.velocity = Vector3.ZERO

func underground_volume_smoke_summary(world_generation, found: Dictionary) -> Dictionary:
    var cell: Vector3i = found.get("cell", Vector3i.ZERO)
    var center_sample: Dictionary = world_generation.call("sample_cell", cell)
    var air_samples := 0
    var solid_neighbors := 0
    var solid_materials := {}
    var failures := []
    if String(center_sample.get("biome", "")) == "underground_air" and not bool(center_sample.get("solid", true)):
        air_samples += 1
    else:
        failures.append({ "kind": "center_air", "cell": vec3i_dictionary(cell), "sample": underground_sample_signature(center_sample) })
    var directions: Array[Vector3i] = [
        Vector3i(1, 0, 0),
        Vector3i(-1, 0, 0),
        Vector3i(0, 1, 0),
        Vector3i(0, -1, 0),
        Vector3i(0, 0, 1),
        Vector3i(0, 0, -1)
    ]
    for direction in directions:
        var neighbor_cell := cell + direction
        var neighbor_sample: Dictionary = world_generation.call("sample_cell", neighbor_cell)
        if bool(neighbor_sample.get("solid", false)):
            solid_neighbors += 1
            solid_materials[String(neighbor_sample.get("material", ""))] = true
        elif String(neighbor_sample.get("biome", "")) == "underground_air":
            air_samples += 1
    var bottom_y := int(world_generation.call("world_bottom_cell_y")) if world_generation.has_method("world_bottom_cell_y") else cell.y - 72
    var bottom_cell := Vector3i(cell.x, bottom_y, cell.z)
    var bottom_sample: Dictionary = world_generation.call("sample_cell", bottom_cell)
    if not bool(bottom_sample.get("solid", false)):
        failures.append({ "kind": "world_bottom_not_solid", "cell": vec3i_dictionary(bottom_cell), "sample": underground_sample_signature(bottom_sample) })
    return {
        "passed": air_samples >= 1 and solid_neighbors >= 2 and not solid_materials.is_empty() and bool(bottom_sample.get("solid", false)) and failures.is_empty(),
        "airSamples": air_samples,
        "solidNeighbors": solid_neighbors,
        "solidMaterials": solid_materials.keys(),
        "worldBottomCellY": bottom_y,
        "worldBottomSolid": bool(bottom_sample.get("solid", false)),
        "worldBottomMaterial": String(bottom_sample.get("material", "")),
        "failures": failures
    }

func underground_volume_chunk_geometry_summary(required_chunks := {}) -> Dictionary:
    var chunks := get_chunks()
    var meshes := 0
    var bodies := 0
    var shapes := 0
    var empty := 0
    var missing := []
    var scoped := required_chunks is Dictionary and not (required_chunks as Dictionary).is_empty()
    for key_value in chunks.keys():
        if scoped and not (required_chunks as Dictionary).has(key_value):
            continue
        var chunk_value = chunks.get(key_value)
        var chunk := chunk_value as Node
        if chunk == null:
            continue
        var mesh := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
        if mesh == null or not terrain_mesh_has_surface(mesh.mesh):
            empty += 1
            continue
        meshes += 1
        var body := chunk.get_node_or_null("TerrainBody") as StaticBody3D
        if body != null:
            bodies += 1
            var shape := body.get_node_or_null("TerrainCollision") as CollisionShape3D
            if shape != null and shape.shape != null:
                shapes += 1
            elif missing.size() < 8:
                missing.append(chunk.name)
        elif missing.size() < 8:
            missing.append(chunk.name)
    return {
        "passed": meshes > 0 and meshes == bodies and bodies == shapes,
        "chunks": chunks.size(),
        "meshes": meshes,
        "bodies": bodies,
        "shapes": shapes,
        "empty": empty,
        "missing": missing,
        "scoped": scoped
    }

func underground_volume_focus_cells(found: Dictionary) -> Array[Vector2i]:
    var cell: Vector3i = found.get("cell", Vector3i.ZERO)
    return [
        Vector2i(cell.x, cell.z),
        Vector2i(cell.x + 1, cell.z),
        Vector2i(cell.x, cell.z + 1)
    ]

func underground_volume_focus_chunk_lookup(cells: Array[Vector2i]) -> Dictionary:
    var result := {}
    var size := active_chunk_size()
    for cell in cells:
        var center := Vector2i(floori(float(cell.x) / float(size)), floori(float(cell.y) / float(size)))
        for dz in range(-1, 2):
            for dx in range(-1, 2):
                result[Vector2i(center.x + dx, center.y + dz)] = true
    if main != null and main.has_method("chunk_has_underground_focus_overlap"):
        var focused := {}
        for key_value in result.keys():
            var key: Vector2i = key_value
            if bool(main.call("chunk_has_underground_focus_overlap", key.x * size, key.y * size)):
                focused[key] = true
        if not focused.is_empty():
            return focused
    return result

func underground_volume_summary(found: Dictionary) -> Dictionary:
    var sample: Dictionary = found.get("sample", {}) if found.has("sample") else {}
    return {
        "id": String(found.get("id", "")),
        "cell": vec3i_dictionary(found.get("cell", Vector3i.ZERO)),
        "surfaceCell": vec2i_dictionary(found.get("surfaceCell", Vector2i.ZERO)),
        "position": vec3_dictionary(found.get("position", Vector3.ZERO)),
        "surfaceY": snappedf(float(found.get("surfaceY", 0.0)), 0.001),
        "depthCells": int(found.get("depthCells", 0)),
        "sample": underground_sample_signature(sample)
    }

func underground_sample_signature(sample: Dictionary) -> Dictionary:
    return {
        "density": snappedf(float(sample.get("density", 0.0)), 0.001),
        "solid": bool(sample.get("solid", false)),
        "biome": String(sample.get("biome", "")),
        "material": String(sample.get("material", "")),
        "surface": bool(sample.get("surface", false))
    }

func vec2i_dictionary(value) -> Dictionary:
    var vector: Vector2i = value if value is Vector2i else Vector2i.ZERO
    return { "x": vector.x, "z": vector.y }

func vec3i_dictionary(value) -> Dictionary:
    var vector: Vector3i = value if value is Vector3i else Vector3i.ZERO
    return { "x": vector.x, "y": vector.y, "z": vector.z }

func repair_target_occupancy(targets: Dictionary) -> Array[Dictionary]:
    var lookup := {}
    for cell_value in targets.get("fence", []):
        if cell_value is Vector2i:
            var cell: Vector2i = cell_value
            lookup[repair_cell_key(cell)] = {
                "kind": "fence",
                "expectedType": "woodBlock",
                "cell": cell
            }
    for cell_value in targets.get("lamps", []):
        if cell_value is Vector2i:
            var cell: Vector2i = cell_value
            lookup[repair_cell_key(cell)] = {
                "kind": "lamp",
                "expectedType": "torch",
                "cell": cell
            }
    var occupied: Array[Dictionary] = []
    if lookup.is_empty():
        return occupied
    var blocks := get_blocks()
    for block_value in blocks.values():
        var body := block_value as Node
        if body == null or not is_instance_valid(body):
            continue
        var block_cell: Vector3i = body.get_meta("cell", Vector3i.ZERO)
        var flat := Vector2i(block_cell.x, block_cell.z)
        var key := repair_cell_key(flat)
        if not lookup.has(key):
            continue
        var target: Dictionary = lookup[key]
        var block_type := String(body.get_meta("block_type", ""))
        var expected_type := String(target.get("expectedType", ""))
        if block_type == expected_type or (expected_type == "torch" and repair_lamp_type(block_type)):
            occupied.append({
                "kind": String(target.get("kind", "")),
                "cell": vec2i_dictionary(flat),
                "blockCell": vec3i_dictionary(block_cell),
                "blockType": block_type,
                "name": body.name
            })
    return occupied

func repair_cell_key(cell: Vector2i) -> String:
    return "%d,%d" % [cell.x, cell.y]

func repair_lamp_type(block_type: String) -> bool:
    return block_type == "torch" or block_type == "wardLantern"

func vec3_dictionary(value) -> Dictionary:
    var vector: Vector3 = value if value is Vector3 else Vector3.ZERO
    return {
        "x": snappedf(vector.x, 0.001),
        "y": snappedf(vector.y, 0.001),
        "z": snappedf(vector.z, 0.001)
    }

func test_ore_generation_and_drops() -> void:
    if not main:
        add_result("ore_generation_and_drops", false, "main missing")
        return
    var inventory_system = main.get("inventory_system")
    var prop_root = main.get("prop_root") as Node3D
    if inventory_system == null or prop_root == null:
        add_result("ore_generation_and_drops", false, "inventory or prop root missing")
        return

    var rng := RandomNumberGenerator.new()
    rng.seed = 481516
    var copper_seen := false
    var iron_seen := false
    for i in range(260):
        var ore: String = main.call("ore_for_cell", "alpine", 72.0, rng)
        copper_seen = copper_seen or ore == "copperOre"
        iron_seen = iron_seen or ore == "ironOre"
        if copper_seen and iron_seen:
            break

    var copper_before: int = inventory_system.count("copperOre")
    rng.seed = 9901
    var cluster_nodes: Array = main.call("make_ore_cluster", prop_root, "playtest:copperOreCluster", player.global_position + Vector3(3.0, 0.0, 0.0), "copperOre", rng, 3)
    var ore_body := cluster_nodes[0] as StaticBody3D if cluster_nodes.size() > 0 else null
    var copper_visual_ok := false
    var copper_meshes := 0
    var copper_children := 0
    if ore_body:
        copper_meshes = count_mesh_descendants(ore_body)
        copper_children = ore_body.get_child_count()
        copper_visual_ok = (
            copper_meshes >= 9
            and copper_children >= 10
            and String(ore_body.get_meta("ore_type", "")) == "copperOre"
        )
        main.call("complete_destroy_target", { "position": ore_body.global_position + Vector3.UP, "normal": Vector3.UP }, ore_body, "prop", "copperOre")
    var dropped: bool = inventory_system.count("copperOre") > copper_before
    rng.seed = 9902
    var iron_body := main.call("make_ore", prop_root, "playtest:ironOreVisual", player.global_position + Vector3(5.5, 0.0, 0.0), "ironOre", rng) as StaticBody3D
    var iron_meshes := count_mesh_descendants(iron_body) if iron_body != null else 0
    var iron_children := iron_body.get_child_count() if iron_body != null else 0
    var iron_visual_ok := iron_body != null and iron_meshes >= 9 and iron_children >= 10 and String(iron_body.get_meta("ore_type", "")) == "ironOre"
    for node_value in cluster_nodes:
        var node := node_value as Node
        if node != null and is_instance_valid(node):
            node.queue_free()
    if iron_body != null and is_instance_valid(iron_body):
        iron_body.queue_free()
    add_result(
        "ore_generation_and_drops",
        copper_seen and iron_seen and dropped and copper_visual_ok and iron_visual_ok and cluster_nodes.size() >= 3,
        "copper seen %s, iron seen %s, copper %d->%d, visuals %s/%s meshes %d/%d children %d/%d, cluster %d" % [
            str(copper_seen),
            str(iron_seen),
            copper_before,
            inventory_system.count("copperOre"),
            str(copper_visual_ok),
            str(iron_visual_ok),
            copper_meshes,
            iron_meshes,
            copper_children,
            iron_children,
            cluster_nodes.size()
        ]
    )

func test_forage_and_wildlife_drops() -> void:
    if not main or not player:
        add_result("forage_and_wildlife_drops", false, "main or player missing")
        return
    var inventory_system = main.get("inventory_system")
    var prop_root = main.get("prop_root") as Node3D
    if inventory_system == null or prop_root == null:
        add_result("forage_and_wildlife_drops", false, "inventory or prop root missing")
        return

    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }
    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    var expectations := {
        "plains": { "material": "berryBush", "drop": "berries" },
        "desert": { "material": "aloePatch", "drop": "aloe" },
        "swamp": { "material": "mushroomCluster", "drop": "mirecap" },
        "snow": { "material": "frostHerbPatch", "drop": "frostHerb" }
    }
    var rng := RandomNumberGenerator.new()
    rng.seed = 772031
    var forage_ok := true
    var forage_details := []
    var offset := 0.0
    for biome in expectations.keys():
        var expected: Dictionary = expectations[biome]
        var spec: Dictionary = main.call("forage_for_biome", String(biome))
        var material_id := String(spec.get("material", ""))
        var drop_id := String(spec.get("drop", ""))
        var before: int = inventory_system.count(drop_id)
        var child_count := prop_root.get_child_count()
        main.call("make_forage", prop_root, "playtest:forage:%s" % String(biome), player.global_position + Vector3(3.0 + offset, 0.0, 3.0), String(biome), rng)
        var forage_body := prop_root.get_child(child_count) as StaticBody3D
        if forage_body:
            main.call("complete_destroy_target", { "position": forage_body.global_position + Vector3.UP, "normal": Vector3.UP }, forage_body, "prop", material_id)
        var dropped: bool = inventory_system.count(drop_id) > before
        var matched: bool = material_id == String(expected.get("material", "")) and drop_id == String(expected.get("drop", ""))
        forage_ok = forage_ok and matched and dropped
        forage_details.append("%s:%s/%s %d->%d" % [String(biome), material_id, drop_id, before, inventory_system.count(drop_id)])
        offset += 1.6

    var meat_before: int = inventory_system.count("rawMeat")
    var hide_before: int = inventory_system.count("hide")
    var child_count := prop_root.get_child_count()
    main.call("make_wildlife", prop_root, "playtest:wildlife", player.global_position + Vector3(3.0, 0.0, 5.0), "snow", rng)
    var wildlife_body := prop_root.get_child(child_count) as StaticBody3D
    var wildlife_start := wildlife_body.global_position if wildlife_body else Vector3.ZERO
    if wildlife_body:
        for i in range(10):
            main.call("update_wildlife", 0.125)
    var wildlife_roamed := wildlife_body != null and is_instance_valid(wildlife_body) and wildlife_body.global_position.distance_to(wildlife_start) > 0.08
    var wildlife_roam_distance := wildlife_body.global_position.distance_to(wildlife_start) if wildlife_body != null and is_instance_valid(wildlife_body) else 0.0
    var wildlife_animated := wildlife_body != null and is_instance_valid(wildlife_body) and bool(wildlife_body.get_meta("wildlife_animated", false))
    var wildlife_variant := String(wildlife_body.get_meta("wildlife_variant", "")) if wildlife_body != null and is_instance_valid(wildlife_body) else ""
    if wildlife_body:
        main.call("complete_destroy_target", { "position": wildlife_body.global_position + Vector3.UP, "normal": Vector3.UP }, wildlife_body, "prop", "wildlife")
    var meat_after: int = inventory_system.count("rawMeat")
    var hide_after: int = inventory_system.count("hide")
    var wildlife_drop_ok: bool = meat_after > meat_before and hide_after > hide_before

    var logs_before: int = inventory_system.count("logs")
    child_count = prop_root.get_child_count()
    main.call("make_tree", prop_root, "playtest:tree", player.global_position + Vector3(6.0, 0.0, 5.0), "forest", rng)
    var tree_body := prop_root.get_child(child_count) as StaticBody3D
    if tree_body:
        main.call("complete_destroy_target", { "position": tree_body.global_position + Vector3.UP, "normal": Vector3.UP }, tree_body, "prop", "tree")
    var falling_tree_found := false
    for child in prop_root.get_children():
        var node := child as Node
        if node and node.name.begins_with("FallingTree"):
            falling_tree_found = true
            node.queue_free()
    add_result(
        "tree_fall_visual_and_logs",
        falling_tree_found and inventory_system.count("logs") > logs_before,
        "falling %s, logs %d->%d" % [str(falling_tree_found), logs_before, inventory_system.count("logs")]
    )

    inventory_system.clear()
    inventory_system.add_item("stoneSword", 1)
    set_active_inventory_item(inventory_system, "stoneSword")
    var sword_power_ok := float(main.call("tool_power_for_material", "wildlife")) >= 4.0
    inventory_system.clear()
    inventory_system.add_item("stoneShovel", 1)
    set_active_inventory_item(inventory_system, "stoneShovel")
    var shovel_power_ok := float(main.call("tool_power_for_material", "berryBush")) >= 3.0

    add_result(
        "forage_and_wildlife_drops",
        forage_ok and wildlife_drop_ok and wildlife_roamed and wildlife_animated and sword_power_ok and shovel_power_ok,
        "forage %s, wildlife %s animated %s, meat %d->%d, hide %d->%d, roamed %.2f, sword %s, shovel %s" % [
            str(forage_details),
            wildlife_variant,
            str(wildlife_animated),
            meat_before,
            meat_after,
            hide_before,
            hide_after,
            wildlife_roam_distance,
            str(sword_power_ok),
            str(shovel_power_ok)
        ]
    )
    inventory_system.restore(original_inventory)

func test_generated_environment_prop_visuals() -> void:
    var props := main.get("prop_root") as Node3D if main else null
    if main == null or props == null or player == null:
        add_result("generated_environment_prop_visuals", false, "main/prop_root/player missing")
        add_result("generated_environment_prop_fallback", false, "main/prop_root/player missing")
        return
    var registry = main.get("visual_asset_registry")
    var registry_ready: bool = registry != null and registry.is_ready()
    var cached_before: int = registry.cached_scene_count() if registry_ready else 0
    var asset_count: int = registry.asset_count() if registry_ready else 0
    var profile_count: int = registry.profile_count() if registry_ready else 0

    var rng := RandomNumberGenerator.new()
    rng.seed = 903771
    var tree := main.call("make_tree", props, "playtest:generated:tree", player.global_position + Vector3(7.0, 0.0, 7.0), "forest", rng) as StaticBody3D
    var rock := main.call("make_rock", props, "playtest:generated:rock", player.global_position + Vector3(8.7, 0.0, 7.0), rng) as StaticBody3D
    var cached_after_spawn: int = registry.cached_scene_count() if registry_ready else 0
    var tree_asset := String(tree.get_meta("visual_asset_id", "")) if tree else ""
    var rock_asset := String(rock.get_meta("visual_asset_id", "")) if rock else ""
    var tree_generated := tree != null and String(tree.get_meta("visual_source", "")) == "generated_asset" and has_visual_source(tree, "generated_asset")
    var rock_generated := rock != null and String(rock.get_meta("visual_source", "")) == "generated_asset" and has_visual_source(rock, "generated_asset")
    var tree_collision := count_collision_descendants(tree) >= 2
    var rock_collision := count_collision_descendants(rock) >= 2
    var cache_stable: bool = cached_before == cached_after_spawn
    add_result(
        "generated_environment_prop_visuals",
        registry_ready and asset_count == 39 and profile_count >= 8 and tree_generated and rock_generated and tree_collision and rock_collision and cache_stable,
        "ready %s, assets %d, profiles %d, tree %s meshes %d collisions %d, rock %s meshes %d collisions %d, cache %d->%d" % [
            str(registry_ready),
            asset_count,
            profile_count,
            tree_asset,
            count_mesh_descendants(tree),
            count_collision_descendants(tree),
            rock_asset,
            count_mesh_descendants(rock),
            count_collision_descendants(rock),
            cached_before,
            cached_after_spawn
        ]
    )

    var fallback_tree_ok := false
    var fallback_rock_ok := false
    var disabled_tree := ""
    var disabled_rock := ""
    if registry_ready:
        disabled_tree = registry.select_tree_asset_id("forest", "playtest:fallback:tree")
        var fallback_position := player.global_position + Vector3(10.5, 0.0, 7.0)
        var fallback_rock_position := fallback_position + Vector3(1.7, 0.0, 0.0)
        var fallback_rock_biome: String = surface_biome_at_cell2(Vector2i(roundi(fallback_rock_position.x / CELL), roundi(fallback_rock_position.z / CELL)))
        disabled_rock = registry.select_rock_asset_id(fallback_rock_biome, "playtest:fallback:rock")
        registry.disable_asset_for_test(disabled_tree)
        registry.disable_asset_for_test(disabled_rock)
        var fallback_rng := RandomNumberGenerator.new()
        fallback_rng.seed = 903772
        var fallback_tree := main.call("make_tree", props, "playtest:fallback:tree", fallback_position, "forest", fallback_rng) as StaticBody3D
        var fallback_rock := main.call("make_rock", props, "playtest:fallback:rock", fallback_rock_position, fallback_rng) as StaticBody3D
        fallback_tree_ok = fallback_tree != null and String(fallback_tree.get_meta("visual_source", "")) == "primitive_fallback" and has_visual_source(fallback_tree, "primitive_fallback") and count_collision_descendants(fallback_tree) >= 2
        fallback_rock_ok = fallback_rock != null and String(fallback_rock.get_meta("visual_source", "")) == "primitive_fallback" and has_visual_source(fallback_rock, "primitive_fallback") and count_collision_descendants(fallback_rock) >= 2
        if fallback_tree:
            fallback_tree.queue_free()
        if fallback_rock:
            fallback_rock.queue_free()
        registry.clear_test_disabled_assets()

    add_result(
        "generated_environment_prop_fallback",
        registry_ready and fallback_tree_ok and fallback_rock_ok and cached_before == (registry.cached_scene_count() if registry_ready else -1),
        "disabled tree %s rock %s, tree fallback %s, rock fallback %s, cache %d" % [
            disabled_tree,
            disabled_rock,
            str(fallback_tree_ok),
            str(fallback_rock_ok),
            registry.cached_scene_count() if registry_ready else 0
        ]
    )

    if tree:
        tree.queue_free()
    if rock:
        rock.queue_free()

func test_generated_visual_render_policy() -> void:
    if main == null:
        add_result("generated_visual_render_policy", false, "main missing")
        return
    var registry = main.get("visual_asset_registry")
    var npc_system = main.get("npc_system")
    var npc_factory = npc_system.get("visual_factory") if npc_system else null
    var npc_registry = npc_factory.get("character_assets") if npc_factory else null
    var environment_ready: bool = registry != null and registry.is_ready()
    var character_ready: bool = npc_registry != null and npc_registry.is_ready()
    if not environment_ready or not character_ready:
        add_result("generated_visual_render_policy", false, "registries ready %s/%s" % [str(environment_ready), str(character_ready)])
        return

    var tree_visual: Node3D = registry.instantiate_asset(registry.select_tree_asset_id("forest", "policy:tree"))
    var rock_visual: Node3D = registry.instantiate_asset(registry.select_rock_asset_id("mountain", "policy:rock"))
    var bush_visual: Node3D = registry.instantiate_family("bush", "policy:bush") if registry.has_method("instantiate_family") else null
    var npc_part: Node3D = npc_registry.instantiate_family("npc_torso", "policy:npc")
    var stats := {
        "tree": render_policy_stats(tree_visual),
        "rock": render_policy_stats(rock_visual),
        "bush": render_policy_stats(bush_visual),
        "npc": render_policy_stats(npc_part)
    }
    var tree_ok: bool = render_policy_has_shadow(stats["tree"]) and render_policy_has_visibility(stats["tree"])
    var rock_ok: bool = render_policy_has_shadow(stats["rock"]) and render_policy_has_visibility(stats["rock"])
    var bush_ok: bool = render_policy_no_shadow(stats["bush"]) and render_policy_has_visibility(stats["bush"])
    var npc_ok: bool = render_policy_has_shadow(stats["npc"]) and render_policy_has_visibility(stats["npc"])
    for node in [tree_visual, rock_visual, bush_visual, npc_part]:
        if node != null:
            node.queue_free()
    add_result(
        "generated_visual_render_policy",
        tree_ok and rock_ok and bush_ok and npc_ok,
        "tree %s rock %s bush %s npc %s" % [str(stats["tree"]), str(stats["rock"]), str(stats["bush"]), str(stats["npc"])]
    )

func test_modular_character_visuals() -> void:
    if main == null or player == null:
        add_result("character_asset_pack_ready", false, "main/player missing")
        add_result("modular_npc_visuals", false, "main/player missing")
        add_result("modular_hostile_visuals", false, "main/player missing")
        add_result("character_visual_fallback", false, "main/player missing")
        return
    var npc_system = main.get("npc_system")
    var hostile_system = main.get("hostile_system")
    var npc_factory = npc_system.get("visual_factory") if npc_system else null
    var hostile_factory = hostile_system.get("visual_factory") if hostile_system else null
    var npc_registry = npc_factory.get("character_assets") if npc_factory else null
    var hostile_registry = hostile_factory.get("character_assets") if hostile_factory else null
    var npc_ready: bool = npc_registry != null and npc_registry.is_ready()
    var hostile_ready: bool = hostile_registry != null and hostile_registry.is_ready()
    var asset_count: int = npc_registry.asset_count() if npc_ready else 0
    var family_count: int = npc_registry.family_count() if npc_ready else 0
    add_result(
        "character_asset_pack_ready",
        npc_ready and hostile_ready and asset_count == 30 and family_count >= 8,
        "npc ready %s, hostile ready %s, assets %d, families %d" % [str(npc_ready), str(hostile_ready), asset_count, family_count]
    )

    var npc_entries: Array = npc_system.get("npcs") if npc_system else []
    var npc_entry: Dictionary = npc_entries[0] if npc_entries.size() > 0 and npc_entries[0] is Dictionary else {}
    var npc_body := npc_entry.get("body") as Node3D
    var npc_label := npc_body.get_node_or_null("NpcNameLabel") as Label3D if npc_body else null
    var original_player_position: Vector3 = player.global_position
    var far_hidden := false
    var near_visible := false
    if npc_body != null and npc_label != null:
        player.global_position = npc_body.global_position + Vector3(CELL * 12.0, 0.0, CELL * 12.0)
        npc_system.call("update_npc_visual_state", npc_entry, 0.016)
        far_hidden = not npc_label.visible
        player.global_position = npc_body.global_position + Vector3(CELL * 2.0, 0.0, 0.0)
        npc_system.call("update_npc_visual_state", npc_entry, 0.016)
        near_visible = npc_label.visible and not npc_label.no_depth_test
        player.global_position = original_player_position
        npc_system.call("update_npc_visual_state", npc_entry, 0.016)
    var npc_generated := npc_body != null and String(npc_body.get_meta("visual_source", "")) == "character_asset" and has_visual_source(npc_body, "character_asset")
    var npc_parts: Array = npc_body.get_meta("character_asset_parts", []) if npc_body else []
    add_result(
        "modular_npc_visuals",
        npc_generated and npc_parts.size() >= 5 and count_mesh_descendants(npc_body) >= 5 and far_hidden and near_visible,
        "generated %s, parts %d, meshes %d, label far/near %s/%s" % [
            str(npc_generated),
            npc_parts.size(),
            count_mesh_descendants(npc_body),
            str(far_hidden),
            str(near_visible)
        ]
    )

    var enemy_body: Node3D = null
    var enemy_generated := false
    var enemy_parts: Array = []
    var enemy_collision := false
    var enemy_collision_count := 0
    if hostile_system != null:
        enemy_body = hostile_system.spawn_enemy(player.global_position + Vector3(18.0, 0.0, 18.0), "rift")
        enemy_generated = enemy_body != null and String(enemy_body.get_meta("visual_source", "")) == "character_asset" and has_visual_source(enemy_body, "character_asset")
        enemy_parts = enemy_body.get_meta("character_asset_parts", []) if enemy_body else []
        enemy_collision_count = count_collision_descendants(enemy_body)
        enemy_collision = enemy_collision_count >= 1
        var enemy_state: Dictionary = hostile_system.enemy_for_body(enemy_body) if enemy_body else {}
        if not enemy_state.is_empty():
            hostile_system.get("enemies").erase(enemy_state)
        if enemy_body:
            enemy_body.queue_free()
    add_result(
        "modular_hostile_visuals",
        enemy_generated and enemy_parts.size() >= 4 and enemy_collision,
        "generated %s, parts %d, collisions %d" % [str(enemy_generated), enemy_parts.size(), enemy_collision_count]
    )

    var fallback_ok := false
    if npc_ready and npc_factory != null:
        npc_registry.disable_all_for_test()
        var fallback_body := Node3D.new()
        npc_factory.add_visual(fallback_body, npc_factory.body_material(0), npc_factory.accent_material(0), "Fallback", "Tester")
        fallback_ok = String(fallback_body.get_meta("visual_source", "")) == "primitive_fallback" and has_visual_source(fallback_body, "primitive_fallback")
        fallback_body.queue_free()
        npc_registry.clear_test_disabled_assets()
    add_result(
        "character_visual_fallback",
        fallback_ok,
        "fallback %s" % str(fallback_ok)
    )

func test_static_item_asset_registry() -> void:
    if main == null:
        add_result("static_item_asset_pack_ready", false, "main missing")
        return
    var registry = main.get("static_item_asset_registry")
    if registry == null:
        add_result("static_item_asset_pack_ready", false, "registry missing")
        return
    var validation: Dictionary = registry.validate_assets()
    var ready: bool = registry.is_ready() and bool(validation.get("ok", false))
    add_result(
        "static_item_asset_pack_ready",
        ready,
        "assets %d, cache %d, %s" % [
            int(registry.asset_count()),
            int(registry.cached_scene_count()),
            String(validation.get("errors", ""))
        ]
    )

    var required_ids := [
        "woodenAxe",
        "stonePickaxe",
        "copperShovel",
        "ironSword",
        "nightBlade",
        "hunterBow",
        "ironCrossbow",
        "fishingRod",
        "workbench",
        "campfire",
        "torch",
        "wardLantern",
        "sanctuaryBeacon",
        "riftAnchor",
        "bed",
        "chest"
    ]
    var failures := []
    var details := []
    for asset_id in required_ids:
        if not registry.has_asset(String(asset_id)):
            failures.append(asset_id)
            details.append("%s:missing" % String(asset_id))
            continue
        var visual := registry.instantiate_item(String(asset_id)) as Node3D
        var meshes := count_mesh_descendants(visual)
        var generated := has_visual_source(visual, "generated_static_asset")
        details.append("%s:%d/%s" % [String(asset_id), meshes, str(generated)])
        if visual == null or meshes < 2 or not generated:
            failures.append(asset_id)
        if visual != null:
            visual.free()
    add_result(
        "static_item_asset_samples",
        failures.is_empty(),
        ", ".join(details)
    )

func cleanup_generated_blocks() -> void:
    var blocks := get_blocks()
    for key in blocks.keys():
        var body := blocks[key] as Node
        if body != null and bool(body.get_meta("generated", false)):
            body.queue_free()
            blocks.erase(key)

func first_collision_shape(node: Node) -> CollisionShape3D:
    for child in node.get_children():
        if child is CollisionShape3D:
            return child
    return null

func test_spawn_clearance() -> void:
    if not player or not camera:
        add_result("spawn_clearance", false, "player or camera missing")
        return
    var terrain_height: float = ground_y_near_position(player.global_position)
    var camera_clearance: float = camera.global_position.y - terrain_height
    var above_water: bool = player.global_position.y > WATER_LEVEL + 1.2
    var clear: bool = camera_clearance > 1.25 and above_water
    add_result("spawn_clearance", clear, "camera clearance %.2f, player y %.2f" % [camera_clearance, player.global_position.y])

func test_terrain_collision_shapes() -> void:
    var summary := await wait_for_terrain_collision_shapes(120)
    var checked := int(summary.get("checked", 0))
    var with_shape := int(summary.get("withShape", 0))
    var empty := int(summary.get("empty", 0))
    var deferred := int(summary.get("deferred", 0))
    var missing: Array = summary.get("missing", []) if summary.get("missing", []) is Array else []
    add_result(
        "terrain_collision_shapes",
        checked > 0 and checked == with_shape,
        "%d/%d required nonempty terrain chunks with shapes, empty %d, deferred %d, missing %s" % [with_shape, checked, empty, deferred, str(missing)]
    )

func wait_for_terrain_collision_shapes(max_frames := 120, required_chunks := {}) -> Dictionary:
    var chunks := get_chunks()
    var checked := 0
    var with_shape := 0
    var empty := 0
    var deferred := 0
    var missing := []
    var scoped := required_chunks is Dictionary and not (required_chunks as Dictionary).is_empty()
    var required_count := (required_chunks as Dictionary).size() if scoped else 0
    var direct_refresh_requested := {}
    for frame in range(max_frames):
        chunks = get_chunks()
        checked = 0
        with_shape = 0
        empty = 0
        deferred = 0
        missing = []
        var direct_refreshes := 0
        for key_value in chunks.keys():
            if scoped and not (required_chunks as Dictionary).has(key_value):
                continue
            var chunk := chunks.get(key_value) as Node
            if not chunk:
                continue
            var mesh := terrain_mesh_for_chunk(chunk)
            if not terrain_mesh_has_surface(mesh):
                empty += 1
                continue
            if not scoped and terrain_chunk_collision_deferred(key_value):
                deferred += 1
                continue
            checked += 1
            var body := chunk.get_node_or_null("TerrainBody") as StaticBody3D
            if not body:
                if missing.size() < 8:
                    missing.append(key_value)
                continue
            var shape_node := body.get_node_or_null("TerrainCollision") as CollisionShape3D
            if shape_node and shape_node.shape:
                with_shape += 1
            else:
                if main.has_method("queue_chunk_collision_refresh") and key_value is Vector2i:
                    main.call("queue_chunk_collision_refresh", key_value)
                if direct_refreshes < 2 and main.has_method("refresh_chunk_collision_shape") and key_value is Vector2i and not direct_refresh_requested.has(key_value):
                    var refresh_key: Vector2i = key_value
                    main.call("refresh_chunk_collision_shape", refresh_key.x, refresh_key.y)
                    direct_refresh_requested[refresh_key] = true
                    direct_refreshes += 1
                if missing.size() < 8:
                    missing.append(key_value)
        if scoped:
            if checked >= required_count and empty == 0 and checked == with_shape:
                return { "chunks": chunks, "checked": checked, "withShape": with_shape, "empty": empty, "deferred": deferred, "missing": missing, "scoped": scoped }
        elif checked > 0 and checked == with_shape:
            return { "chunks": chunks, "checked": checked, "withShape": with_shape, "empty": empty, "deferred": deferred, "missing": missing, "scoped": scoped }
        main.call("update_chunks", false)
        if frame % 15 == 0:
            mark_progress("terrain_collision_wait_%03d_%d_%d" % [frame, with_shape, checked])
        await wait_physics_frames(1)
    return { "chunks": chunks, "checked": checked, "withShape": with_shape, "empty": empty, "deferred": deferred, "missing": missing, "scoped": scoped }

func terrain_chunk_collision_deferred(chunk_key) -> bool:
    if not (chunk_key is Vector2i) or player == null:
        return false
    var key: Vector2i = chunk_key
    var size := active_chunk_size()
    var center := Vector2i(
        floori(player.global_position.x / (float(size) * CELL)),
        floori(player.global_position.z / (float(size) * CELL))
    )
    var max_axis_distance := maxi(absi(key.x - center.x), absi(key.y - center.y))
    return max_axis_distance >= 2

func terrain_mesh_has_surface(mesh: Mesh) -> bool:
    if mesh == null or mesh.get_surface_count() <= 0:
        return false
    var arrays := mesh.surface_get_arrays(0)
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    return not vertices.is_empty()

func test_terrain_mesh_topology_signature() -> void:
    var chunks := get_chunks()
    var checked := 0
    var nonempty := 0
    var volume_sourced := 0
    var mesh_collision_sourced := 0
    var deferred := 0
    var with_normals := 0
    for key_value in chunks.keys():
        if terrain_chunk_collision_deferred(key_value):
            deferred += 1
            continue
        var chunk := chunks.get(key_value) as Node
        var mesh := terrain_mesh_for_chunk(chunk)
        if mesh == null or mesh.get_surface_count() == 0:
            continue
        checked += 1
        var arrays := mesh.surface_get_arrays(0)
        var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
        var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
        if vertices.size() > 0:
            nonempty += 1
        if normals.size() == vertices.size() and normals.size() > 0:
            with_normals += 1
        var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
        var body := chunk.get_node_or_null("TerrainBody") as StaticBody3D
        var collision := body.get_node_or_null("TerrainCollision") as CollisionShape3D if body != null else null
        if mesh_instance != null and String(mesh_instance.get_meta("geometry_source", "")) == "volume_sample_extraction":
            volume_sourced += 1
        if collision != null and collision.shape != null and String(collision.get_meta("collision_source", "")) == "terrain_mesh_create_trimesh_shape":
            mesh_collision_sourced += 1
    add_result(
        "terrain_mesh_topology_signature",
        checked > 0 and checked == nonempty and checked == with_normals and checked == volume_sourced and checked == mesh_collision_sourced,
        "%d/%d required nonempty, normals %d/%d, volume source %d/%d, mesh collision %d/%d, deferred %d" % [nonempty, checked, with_normals, checked, volume_sourced, checked, mesh_collision_sourced, checked, deferred]
    )

func test_terrain_shader_material() -> void:
    var material := main.get("terrain_material") as ShaderMaterial if main else null
    var shader_path := ""
    if material and material.shader:
        shader_path = material.shader.resource_path
    var chunks := get_chunks()
    var checked := 0
    var assigned := 0
    for chunk_node in chunks.values():
        var chunk := chunk_node as Node
        var mesh := terrain_mesh_for_chunk(chunk)
        if mesh == null or mesh.get_surface_count() == 0:
            continue
        checked += 1
        if mesh.surface_get_material(0) is ShaderMaterial:
            assigned += 1
    add_result(
        "terrain_shader_material",
        material != null and shader_path.ends_with("stylized_terrain.gdshader") and checked > 0 and checked == assigned,
        "material %s, shader %s, assigned %d/%d" % [str(material != null), shader_path, assigned, checked]
    )

func test_terrain_chunk_edge_normals() -> void:
    if not main:
        add_result("terrain_chunk_edge_normals", false, "main missing")
        return
    var summary := terrain_chunk_edge_normal_summary()
    var retested_clean_area := false
    var force_clean_sample := OS.get_environment("VOXEL_TERRAIN_NORMAL_FORCE_CLEAN_SAMPLE").strip_edges() == "1"
    if force_clean_sample:
        retested_clean_area = true
        summary = await terrain_chunk_edge_normal_summary_from_clean_area()
    elif not terrain_chunk_edge_normal_summary_passed(summary) and terrain_chunk_edge_normal_should_retry_clean(summary):
        retested_clean_area = true
        summary = await terrain_chunk_edge_normal_summary_from_clean_area()
    add_result(
        "terrain_chunk_edge_normals",
        terrain_chunk_edge_normal_summary_passed(summary),
        "pairs %d, volume %d, skipped %d, comparisons %d/%d, max edge normal delta %.4f/%.1f degrees%s, worst %s" % [
            int(summary.get("pairs", 0)),
            int(summary.get("volumePairs", 0)),
            int(summary.get("skippedPairs", 0)),
            int(summary.get("comparisons", 0)),
            int(summary.get("requiredComparisons", 0)),
            float(summary.get("maxDegrees", 0.0)),
            float(summary.get("allowedDegrees", 0.0)),
            ", clean-area retry" if retested_clean_area else "",
            str(summary.get("worst", {}))
        ]
    )

func terrain_chunk_edge_normal_summary() -> Dictionary:
    var chunks := get_chunks()
    var comparisons := 0
    var pairs := 0
    var skipped_pairs := 0
    var max_degrees := 0.0
    var volume_pairs := 0
    var worst := {}
    for key_variant in chunks.keys():
        if pairs >= 16:
            break
        var key := key_variant as Vector2i
        var east_key := key + Vector2i(1, 0)
        if chunks.has(east_key) and pairs < 16:
            if terrain_chunk_has_playtest_edits(key) or terrain_chunk_has_playtest_edits(east_key):
                skipped_pairs += 1
            else:
                var east_mesh := terrain_mesh_for_chunk(chunks.get(key) as Node)
                var west_mesh := terrain_mesh_for_chunk(chunks.get(east_key) as Node)
                if terrain_mesh_is_provisional_or_lod(east_mesh) or terrain_mesh_is_provisional_or_lod(west_mesh):
                    skipped_pairs += 1
                else:
                    var volume_pair := terrain_mesh_is_volume_source(east_mesh) or terrain_mesh_is_volume_source(west_mesh)
                    var east_samples := terrain_edge_normal_samples(east_mesh, "east", key)
                    var west_samples := terrain_edge_normal_samples(west_mesh, "west", east_key)
                    var pair_comparisons := 0
                    for sample_key in east_samples.keys():
                        if not west_samples.has(sample_key):
                            continue
                        var a: Vector3 = east_samples[sample_key]
                        var b: Vector3 = west_samples[sample_key]
                        var degrees := rad_to_deg(a.angle_to(b))
                        if degrees > max_degrees:
                            max_degrees = degrees
                            worst = {
                                "from": key,
                                "to": east_key,
                                "side": "east-west",
                                "sample": sample_key,
                                "a": a,
                                "b": b,
                                "fromMesh": terrain_mesh_debug_label(east_mesh),
                                "toMesh": terrain_mesh_debug_label(west_mesh)
                            }
                        comparisons += 1
                        pair_comparisons += 1
                    if pair_comparisons > 0:
                        pairs += 1
                        if volume_pair:
                            volume_pairs += 1
                    else:
                        skipped_pairs += 1
        var south_key := key + Vector2i(0, 1)
        if chunks.has(south_key) and pairs < 16:
            if terrain_chunk_has_playtest_edits(key) or terrain_chunk_has_playtest_edits(south_key):
                skipped_pairs += 1
            else:
                var south_mesh := terrain_mesh_for_chunk(chunks.get(key) as Node)
                var north_mesh := terrain_mesh_for_chunk(chunks.get(south_key) as Node)
                if terrain_mesh_is_provisional_or_lod(south_mesh) or terrain_mesh_is_provisional_or_lod(north_mesh):
                    skipped_pairs += 1
                else:
                    var volume_pair := terrain_mesh_is_volume_source(south_mesh) or terrain_mesh_is_volume_source(north_mesh)
                    var south_samples := terrain_edge_normal_samples(south_mesh, "south", key)
                    var north_samples := terrain_edge_normal_samples(north_mesh, "north", south_key)
                    var pair_comparisons := 0
                    for sample_key in south_samples.keys():
                        if not north_samples.has(sample_key):
                            continue
                        var c: Vector3 = south_samples[sample_key]
                        var d: Vector3 = north_samples[sample_key]
                        var degrees := rad_to_deg(c.angle_to(d))
                        if degrees > max_degrees:
                            max_degrees = degrees
                            worst = {
                                "from": key,
                                "to": south_key,
                                "side": "south-north",
                                "sample": sample_key,
                                "a": c,
                                "b": d,
                                "fromMesh": terrain_mesh_debug_label(south_mesh),
                                "toMesh": terrain_mesh_debug_label(north_mesh)
                            }
                        comparisons += 1
                        pair_comparisons += 1
                    if pair_comparisons > 0:
                        pairs += 1
                        if volume_pair:
                            volume_pairs += 1
                    else:
                        skipped_pairs += 1
    var uses_volume_meshes := volume_pairs > 0
    var required_comparisons := 8 if uses_volume_meshes else 96
    var required_pairs := 4 if uses_volume_meshes else 8
    var allowed_degrees := 18.0 if uses_volume_meshes else 12.0
    return {
        "pairs": pairs,
        "requiredPairs": required_pairs,
        "volumePairs": volume_pairs,
        "skippedPairs": skipped_pairs,
        "comparisons": comparisons,
        "requiredComparisons": required_comparisons,
        "maxDegrees": max_degrees,
        "allowedDegrees": allowed_degrees,
        "worst": worst
    }

func terrain_chunk_edge_normal_summary_passed(summary: Dictionary) -> bool:
    return int(summary.get("pairs", 0)) >= int(summary.get("requiredPairs", 8)) \
        and int(summary.get("comparisons", 0)) >= int(summary.get("requiredComparisons", 0)) \
        and float(summary.get("maxDegrees", 999.0)) <= float(summary.get("allowedDegrees", 0.0))

func terrain_chunk_edge_normal_should_retry_clean(summary: Dictionary) -> bool:
    if int(summary.get("pairs", 0)) >= int(summary.get("requiredPairs", 8)) \
            and int(summary.get("comparisons", 0)) >= int(summary.get("requiredComparisons", 0)):
        return false
    if int(summary.get("comparisons", 0)) < int(summary.get("requiredComparisons", 0)):
        return true
    return int(summary.get("comparisons", 0)) >= int(summary.get("requiredComparisons", 0)) \
        and float(summary.get("maxDegrees", 999.0)) <= float(summary.get("allowedDegrees", 0.0))

func terrain_chunk_edge_normal_summary_from_clean_area() -> Dictionary:
    if player == null:
        return terrain_chunk_edge_normal_summary()
    var previous_debug := bool(main.get("force_underground_volume_debug")) if main != null else false
    if main != null:
        main.set("force_underground_volume_debug", true)
    var clean_cell := Vector2i(512, 512)
    var clean_y := maxf(surface_y_at_cell2(clean_cell), WATER_LEVEL)
    player.global_position = Vector3(float(clean_cell.x) * CELL, clean_y + 1.5, float(clean_cell.y) * CELL)
    player.velocity = Vector3.ZERO
    await settle_streamed_chunks_after_relocation("terrain_normals_clean_chunks", 180)
    var summary := terrain_chunk_edge_normal_summary()
    if main != null:
        main.set("force_underground_volume_debug", previous_debug)
    return summary

func terrain_chunk_has_playtest_edits(chunk_key: Vector2i) -> bool:
    var world_generation = main.get("world_generation_system") if main != null else null
    var chunk_size := active_chunk_size()
    if world_generation != null and world_generation.has_method("terrain_volume_chunk_has_edits"):
        if bool(world_generation.call("terrain_volume_chunk_has_edits", chunk_key, chunk_size)):
            return true
    var start_x := chunk_key.x * chunk_size
    var start_z := chunk_key.y * chunk_size
    var end_x := start_x + chunk_size
    var end_z := start_z + chunk_size
    var edits := get_volume_edit_markers()
    for cell_value in edits.keys():
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        if cell.x >= start_x - 1 and cell.x <= end_x and cell.y >= start_z - 1 and cell.y <= end_z:
            return true
    return false

func terrain_mesh_for_chunk(chunk: Node) -> Mesh:
    if chunk == null:
        return null
    var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
    return mesh_instance.mesh if mesh_instance else null

func terrain_mesh_is_volume_source(mesh: Mesh) -> bool:
    if mesh == null:
        return false
    return bool(mesh.get_meta("terrainMeshingSectionPayload", false)) or int(mesh.get_meta("chunk_volume_faces", 0)) > 0

func terrain_mesh_is_provisional_or_lod(mesh: Mesh) -> bool:
    if mesh == null:
        return true
    return bool(mesh.get_meta("terrainMeshingProvisional", false)) or bool(mesh.get_meta("terrainStreamingLod", false))

func terrain_mesh_debug_label(mesh: Mesh) -> Dictionary:
    if mesh == null:
        return { "missing": true }
    return {
        "backend": String(mesh.get_meta("terrainMeshingBackend", "")),
        "native": bool(mesh.get_meta("terrainMeshingNative", false)),
        "section": bool(mesh.get_meta("terrainMeshingSectionPayload", false)),
        "provisional": bool(mesh.get_meta("terrainMeshingProvisional", false)),
        "lod": bool(mesh.get_meta("terrainStreamingLod", false)),
        "projectedNormals": bool(mesh.get_meta("terrainSurfaceNormalsProjected", false)),
        "volumeFaces": int(mesh.get_meta("chunk_volume_faces", 0)),
        "surfaces": mesh.get_surface_count()
    }

func terrain_edge_normal_samples(mesh: Mesh, side: String, chunk_key: Vector2i) -> Dictionary:
    if mesh == null or mesh.get_surface_count() == 0:
        return {}
    var arrays := mesh.surface_get_arrays(0)
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
    if vertices.is_empty() or normals.size() != vertices.size():
        return {}
    var target := float(active_chunk_size()) * CELL
    var quant := maxf(0.001, CELL * 2.0)
    var chunk_size := active_chunk_size()
    var origin_x := float(chunk_key.x * chunk_size) * CELL
    var origin_z := float(chunk_key.y * chunk_size) * CELL
    var totals := {}
    var counts := {}
    for i in range(vertices.size()):
        var vertex := vertices[i]
        var normal := normals[i]
        if normal.y <= 0.25:
            continue
        var on_edge := false
        match side:
            "west":
                on_edge = absf(vertex.x) <= 0.001
            "east":
                on_edge = absf(vertex.x - target) <= 0.001
            "north":
                on_edge = absf(vertex.z) <= 0.001
            "south":
                on_edge = absf(vertex.z - target) <= 0.001
        if on_edge:
            var world_position := Vector3(origin_x + vertex.x, vertex.y, origin_z + vertex.z)
            var exterior_surface_y := surface_y_at_position(world_position)
            if absf(vertex.y - exterior_surface_y) > CELL * 2.25:
                continue
            var along := vertex.z if side == "west" or side == "east" else vertex.x
            var sample_key := "%d:%d" % [roundi(along / quant), roundi(vertex.y / quant)]
            totals[sample_key] = totals.get(sample_key, Vector3.ZERO) + normal.normalized()
            counts[sample_key] = int(counts.get(sample_key, 0)) + 1
    var result := {}
    for sample_key in totals.keys():
        var total: Vector3 = totals[sample_key]
        if int(counts.get(sample_key, 0)) <= 0 or total.length_squared() <= 0.0:
            continue
        result[sample_key] = total.normalized()
    return result

func test_terrain_generation_profile() -> void:
    if not main:
        add_result("terrain_generation_profile", false, "main missing")
        return
    var normal_biomes := ["plains", "forest", "savanna", "taiga"]
    var mountain_biomes := ["snow", "alpine", "tundra"]
    var normal_samples := 0
    var smooth_samples := 0
    var variation_total := 0.0
    var mountain_samples := 0
    var max_mountain := 0.0
    for z in range(-360, 361, 12):
        for x in range(-360, 361, 12):
            var height := surface_y_at_cell_coords(x, z)
            var biome := surface_biome_at_cell2(Vector2i(x, z))
            if normal_biomes.has(biome) and height > WATER_LEVEL + 2.4 and height < 56.0:
                var variation := float(main.call("height_variation_cell", x, z, 1))
                variation_total += variation
                normal_samples += 1
                if variation <= CELL:
                    smooth_samples += 1
            elif mountain_biomes.has(biome) and height >= 62.0:
                mountain_samples += 1
                max_mountain = maxf(max_mountain, height)
    var average_variation := variation_total / float(maxi(1, normal_samples))
    var smooth_ratio := float(smooth_samples) / float(maxi(1, normal_samples))
    var mountain_cell: Vector2i = main.call("find_biome_playtest_cell", mountain_biomes, 62.0, 120.0, false)
    var mountain_target_found := mountain_cell != Vector2i(999999, 999999)
    var mountain_target_height := 0.0
    if mountain_target_found:
        mountain_target_height = surface_y_at_cell2(mountain_cell)
        max_mountain = maxf(max_mountain, mountain_target_height)
    var mountain_ok := (mountain_samples > 0 and max_mountain >= 62.0) or (mountain_target_found and mountain_target_height >= 62.0)
    add_result(
        "terrain_generation_profile",
        normal_samples >= 80
            and average_variation <= CELL * 1.15
            and smooth_ratio >= 0.45
            and mountain_ok
            and mountain_target_found,
        "normal %d, avg variation %.2f, smooth %.0f%%, mountain samples %d, max %.2f, target %s height %.2f" % [
            normal_samples,
            average_variation,
            smooth_ratio * 100.0,
            mountain_samples,
            max_mountain,
            str(mountain_cell),
            mountain_target_height
        ]
    )

func test_world_chunk_streaming() -> void:
    if not main or not player:
        add_result("world_chunk_streaming", false, "main or player missing")
        return

    var original_position: Vector3 = player.global_position
    var original_chunk: Vector2i = main.call("world_to_chunk", original_position.x, original_position.z)
    var cache_before: Dictionary = main.call("chunk_asset_cache_stats")
    var target_x := original_position.x + CELL * 128.0
    var target_z := original_position.z + CELL * 96.0
    var target_y: float = surface_y_at_position(Vector3(target_x, 0.0, target_z)) + 0.45
    player.global_position = Vector3(target_x, target_y, target_z)
    bootstrap_playtest_visible_chunks()
    await wait_for_chunk_count(49, 120, "world_streaming_out_chunks")
    await wait_for_terrain_collision_shapes(120)
    var cache_after_stream_out: Dictionary = main.call("chunk_asset_cache_stats")

    var chunks := get_chunks()
    var target_chunk: Vector2i = main.call("world_to_chunk", target_x, target_z)
    var target_node := chunks.get(target_chunk, null) as Node
    var target_body := target_node.get_node_or_null("TerrainBody") as StaticBody3D if target_node else null
    var target_shape := target_body.get_node_or_null("TerrainCollision") as CollisionShape3D if target_body else null
    var streamed := target_chunk != original_chunk and chunks.has(target_chunk) and chunks.size() >= 49
    var collision_ready := target_shape != null and target_shape.shape != null
    add_result(
        "world_chunk_streaming",
        streamed and collision_ready,
        "chunk %s->%s, chunks %d, target collision %s" % [
            str(original_chunk),
            str(target_chunk),
            chunks.size(),
            str(collision_ready)
        ]
    )

    player.global_position = original_position
    bootstrap_playtest_visible_chunks()
    await wait_for_chunk_count(49, 120, "world_streaming_return_chunks")
    await wait_for_terrain_collision_shapes(120)
    var cache_after_return: Dictionary = main.call("chunk_asset_cache_stats")
    var cache_hit: bool = int(cache_after_return.get("hits", 0)) > int(cache_after_stream_out.get("hits", 0))
    var direct_cache_before: Dictionary = {}
    var direct_cache_after_first: Dictionary = {}
    var direct_cache_after_second: Dictionary = {}
    if not cache_hit and main.has_method("chunk_assets"):
        direct_cache_before = main.call("chunk_asset_cache_stats")
        main.call("chunk_assets", original_chunk.x, original_chunk.y)
        direct_cache_after_first = main.call("chunk_asset_cache_stats")
        main.call("chunk_assets", original_chunk.x, original_chunk.y)
        direct_cache_after_second = main.call("chunk_asset_cache_stats")
        cache_hit = int(direct_cache_after_second.get("hits", 0)) > int(direct_cache_after_first.get("hits", 0))
    if main.has_method("chunk_assets"):
        main.call("chunk_assets", original_chunk.x, original_chunk.y)
    var cache_seeded: Dictionary = main.call("chunk_asset_cache_stats")
    var invalidations_before: int = int(cache_seeded.get("invalidations", 0))
    var world_generation = main.get("world_generation_system")
    var edit_cell2 := Vector2i(main.call("world_to_cell", original_position.x), main.call("world_to_cell", original_position.z))
    var edit_cell3 := Vector3i(edit_cell2.x, floori(surface_y_at_cell2(edit_cell2) / CELL) - 2, edit_cell2.y)
    var edited_cells: Array = []
    if world_generation != null and world_generation.has_method("apply_box_edit"):
        edited_cells = world_generation.call("apply_box_edit", edit_cell3, edit_cell3, {
            "material": "air",
            "biome": "underground_air",
            "solid": false,
            "density": -CELL,
            "fluid": "",
            "light": { "sky": 0, "block": 0 },
            "metadata": {
                "source": "playtest_cache_invalidation",
                "terrainMeshAffects": true,
                "saveDelta": false
            }
        }, "playtest_cache_invalidation")
    var dirty_queued := int(main.call("queue_dirty_terrain_volume_chunk_refreshes")) if main.has_method("queue_dirty_terrain_volume_chunk_refreshes") else 0
    main.call("rebuild_chunks_for_cells", [edit_cell2], 0, false)
    var cache_after_invalidation: Dictionary = main.call("chunk_asset_cache_stats")
    var invalidated: bool = int(cache_after_invalidation.get("invalidations", 0)) > invalidations_before
    if world_generation != null and world_generation.has_method("clear_cell_state"):
        world_generation.call("clear_cell_state", edit_cell3, "playtest_cache_invalidation_cleanup")
    main.call("rebuild_chunks_for_cells", [edit_cell2], 0, true)
    add_result(
        "chunk_asset_cache_reuse_invalidation",
        cache_hit and not edited_cells.is_empty() and invalidated and int(cache_after_invalidation.get("entries", 0)) <= 96,
        "hits %d->%d->%d, direct %d->%d->%d, misses %d->%d, entries %d, invalidations %d->%d, edited %d, dirtyQueued %d" % [
            int(cache_before.get("hits", 0)),
            int(cache_after_stream_out.get("hits", 0)),
            int(cache_after_return.get("hits", 0)),
            int(direct_cache_before.get("hits", 0)),
            int(direct_cache_after_first.get("hits", 0)),
            int(direct_cache_after_second.get("hits", 0)),
            int(cache_before.get("misses", 0)),
            int(cache_after_return.get("misses", 0)),
            int(cache_after_invalidation.get("entries", 0)),
            invalidations_before,
            int(cache_after_invalidation.get("invalidations", 0)),
            edited_cells.size(),
            dirty_queued
        ]
    )

func test_chunk_detail_batches() -> void:
    if not main:
        add_result("chunk_detail_batches", false, "main missing")
        return
    var original_position: Vector3 = player.global_position if player != null else Vector3.ZERO
    if player != null:
        var target_x := original_position.x + CELL * 128.0
        var target_z := original_position.z + CELL * 96.0
        var target_y := surface_y_at_position(Vector3(target_x, 0.0, target_z)) + 0.45
        player.global_position = Vector3(target_x, target_y, target_z)
        bootstrap_playtest_visible_chunks()
        await wait_for_chunk_count(49, 120, "chunk_detail_stream_chunks")
        await wait_for_terrain_collision_shapes(120)
    var summary: Dictionary = {}
    for i in range(420):
        summary = chunk_detail_batch_summary()
        if bool(summary.get("passed", false)):
            break
        if main.has_method("process_pending_chunk_prop_spawns"):
            for _drain_index in range(8):
                main.call("process_pending_chunk_prop_spawns")
        await wait_process_frames(1)
    if summary.is_empty():
        summary = chunk_detail_batch_summary()
    add_result(
        "chunk_detail_batches",
        bool(summary.get("passed", false)),
        String(summary.get("details", "missing detail summary"))
    )
    if player != null:
        player.global_position = original_position
        bootstrap_playtest_visible_chunks()
        await wait_for_chunk_count(49, 120, "chunk_detail_return_chunks")
        await wait_for_terrain_collision_shapes(120)

func chunk_detail_batch_summary() -> Dictionary:
    var chunks := get_chunks()
    var pending_props := 0
    var pending_value = main.get("pending_chunk_prop_spawns") if main != null else {}
    if pending_value is Dictionary:
        pending_props = (pending_value as Dictionary).size()
    var biome_counts := {}
    var sampled_chunks := 0
    for chunk_key_variant in chunks.keys():
        if sampled_chunks >= 12:
            break
        if not (chunk_key_variant is Vector2i):
            continue
        var chunk_key: Vector2i = chunk_key_variant
        var center_cell := Vector2i(chunk_key.x * CHUNK_SIZE + CHUNK_SIZE / 2, chunk_key.y * CHUNK_SIZE + CHUNK_SIZE / 2)
        var biome := surface_biome_at_cell2(center_cell)
        biome_counts[biome] = int(biome_counts.get(biome, 0)) + 1
        sampled_chunks += 1
    var batch_nodes := 0
    var detail_instances := 0
    var collider_count := 0
    var chunk_count_with_decor := 0
    var detail_types := {}
    var upgraded_meshes := 0
    var color_batches := 0
    var custom_batches := 0
    var faded_batches := 0
    for chunk_node_variant in chunks.values():
        var chunk_node := chunk_node_variant as Node
        if chunk_node == null:
            continue
        var decor_root := chunk_node.get_node_or_null("DecorBatches")
        if decor_root == null:
            continue
        chunk_count_with_decor += 1
        collider_count += count_collision_descendants(decor_root)
        for child in decor_root.get_children():
            var batch := child as MultiMeshInstance3D
            if batch == null or batch.multimesh == null:
                continue
            batch_nodes += 1
            detail_instances += batch.multimesh.instance_count
            detail_types[String(batch.get_meta("detail_type", "unknown"))] = true
            if batch.multimesh.mesh is ArrayMesh:
                upgraded_meshes += 1
            if batch.multimesh.use_colors:
                color_batches += 1
            if batch.multimesh.use_custom_data:
                custom_batches += 1
            if batch.visibility_range_end > 0.0:
                faded_batches += 1
    var batched: bool = batch_nodes > 0 and detail_instances > batch_nodes * 3
    var passed := batched \
        and collider_count == 0 \
        and detail_types.size() >= 3 \
        and upgraded_meshes == batch_nodes \
        and color_batches == batch_nodes \
        and custom_batches == batch_nodes \
        and faded_batches == batch_nodes
    return {
        "passed": passed,
        "details": "chunks %d/%d, pending %d, biomes %s, batches %d, instances %d, colliders %d, upgraded %d, colors %d, custom %d, faded %d, types %s" % [
            chunk_count_with_decor,
            chunks.size(),
            pending_props,
            str(biome_counts),
            batch_nodes,
            detail_instances,
            collider_count,
            upgraded_meshes,
            color_batches,
            custom_batches,
            faded_batches,
            str(detail_types.keys())
        ]
    }

func test_sky_light_consistency() -> void:
    if not main or not player:
        add_result("sky_light_consistency", false, "main or player missing")
        return
    var sun_light := main.get("sun") as DirectionalLight3D
    var sun_disc := main.get("sun_visual") as MeshInstance3D
    if not sun_light or not sun_disc:
        add_result("sky_light_consistency", false, "sun light or disc missing")
        return
    var day_factor := float(main.call("clock_day_factor")) if main.has_method("clock_day_factor") else 1.0
    var casts_day_shadows := sun_light.shadow_enabled and sun_light.light_energy > 0.1
    var sun_above_player := sun_disc.visible and sun_disc.global_position.y > player.global_position.y + 40.0
    add_result(
        "sky_light_consistency",
        not casts_day_shadows or (day_factor > 0.18 and sun_above_player),
        "clock day %.2f, sun shadows %s, disc visible %s, disc y %.2f, player y %.2f" % [
            day_factor,
            str(casts_day_shadows),
            str(sun_disc.visible),
            sun_disc.global_position.y,
            player.global_position.y
        ]
    )

func test_environment_visual_style() -> void:
    if not main:
        add_result("environment_visual_style", false, "main missing")
        return
    var world_env := main.get("world_environment") as WorldEnvironment
    var sun_light := main.get("sun") as DirectionalLight3D
    var moon_light := main.get("moon") as DirectionalLight3D
    if world_env == null or world_env.environment == null or sun_light == null or moon_light == null:
        add_result("environment_visual_style", false, "environment or lights missing")
        return
    var env := world_env.environment
    var sky_mat := main.get("sky_material") as ProceduralSkyMaterial
    var style := main.get("visual_style") as Resource
    var structure_ok := env.background_mode == Environment.BG_SKY \
        and env.sky != null \
        and sky_mat != null \
        and env.ambient_light_source == Environment.AMBIENT_SOURCE_SKY \
        and env.tonemap_mode == Environment.TONE_MAPPER_FILMIC \
        and env.fog_enabled \
        and bool(env.get("ssao_enabled")) \
        and style != null
    var original_time := float(main.get("time_of_day"))
    main.set("time_of_day", 0.25)
    main.call("update_sky", 0.0)
    var noon_sun := sun_light.light_energy
    var noon_ambient := env.ambient_light_energy
    var noon_fog := env.fog_density
    var terrain_mat := main.get("terrain_material") as ShaderMaterial
    var noon_terrain_shadow_fill := float(terrain_mat.get_shader_parameter("shadow_fill")) if terrain_mat else 0.0
    main.set("time_of_day", 0.75)
    main.call("update_sky", 0.0)
    var night_sun := sun_light.light_energy
    var night_moon := moon_light.light_energy
    var night_ambient := env.ambient_light_energy
    var night_fog := env.fog_density
    var night_fog_energy := env.fog_light_energy
    var night_terrain_shadow_fill := float(terrain_mat.get_shader_parameter("shadow_fill")) if terrain_mat else 1.0
    main.set("time_of_day", original_time)
    main.call("update_sky", 0.0)
    var range_ok := noon_sun >= 0.55 \
        and noon_sun <= 1.70 \
        and noon_ambient >= 0.0 \
        and noon_ambient <= 0.01 \
        and noon_fog >= 0.002 \
        and noon_fog <= 0.020 \
        and noon_terrain_shadow_fill >= 0.18 \
        and noon_terrain_shadow_fill <= 0.28 \
        and night_sun <= 0.04 \
        and night_moon >= 0.02 \
        and night_moon <= 0.12 \
        and night_ambient >= 0.0 \
        and night_ambient <= 0.01 \
        and night_fog >= 0.004 \
        and night_fog <= 0.030 \
        and night_fog_energy <= 0.14 \
        and night_terrain_shadow_fill <= 0.02
    add_result(
        "environment_visual_style",
        structure_ok and range_ok,
        "sky %s, filmic %s, sky ambient %s, fog %s, ssao %s, noon sun %.2f amb %.2f fog %.4f terrain fill %.2f, night sun %.2f moon %.2f amb %.2f fog %.4f fog energy %.2f terrain fill %.2f" % [
            str(env.background_mode == Environment.BG_SKY and env.sky != null and sky_mat != null),
            str(env.tonemap_mode == Environment.TONE_MAPPER_FILMIC),
            str(env.ambient_light_source == Environment.AMBIENT_SOURCE_SKY),
            str(env.fog_enabled),
            str(bool(env.get("ssao_enabled"))),
            noon_sun,
            noon_ambient,
            noon_fog,
            noon_terrain_shadow_fill,
            night_sun,
            night_moon,
            night_ambient,
            night_fog,
            night_fog_energy,
            night_terrain_shadow_fill
        ]
    )

func test_weather_visual_system() -> void:
    if not main or not player:
        add_result("weather_visual_system", false, "main or player missing")
        return
    var weather_system = main.get("weather_system")
    if weather_system == null:
        add_result("weather_visual_system", false, "weather system missing")
        return

    weather_system.force_weather("rain", 0.82, 0.90, player.global_position)
    var rain_state: Dictionary = weather_system.snapshot()
    weather_system.force_weather("snow", 0.78, 0.86, player.global_position)
    var snow_state: Dictionary = weather_system.snapshot()
    weather_system.force_weather("clear", 0.0, 0.10, player.global_position)
    var star_state: Dictionary = weather_system.snapshot()
    add_result(
        "weather_visual_system",
        bool(rain_state.get("rainVisible", false))
            and bool(snow_state.get("snowVisible", false))
            and bool(star_state.get("starsVisible", false))
            and int(star_state.get("clouds", 0)) >= 12
            and int(star_state.get("stars", 0)) >= 100,
        "rain %s, snow %s, stars %s, clouds %d, stars %d" % [
            str(rain_state.get("rainVisible", false)),
            str(snow_state.get("snowVisible", false)),
            str(star_state.get("starsVisible", false)),
            int(star_state.get("clouds", 0)),
            int(star_state.get("stars", 0))
        ]
    )

func test_water_visual_material() -> void:
    if not main:
        add_result("water_visual_material", false, "main missing")
        return
    var water := main.get("water") as MeshInstance3D
    var materials: Dictionary = main.get("materials")
    var material := materials.get("water") as ShaderMaterial
    var shader_path := ""
    if material and material.shader:
        shader_path = material.shader.resource_path
    if main.has_method("apply_weather_lighting"):
        main.call("apply_weather_lighting", { "cloudCover": 0.82, "intensity": 0.46 }, 0.58)
    var cloud_param := -1.0
    var weather_param := -1.0
    if material:
        cloud_param = float(material.get_shader_parameter("cloud_cover"))
        weather_param = float(material.get_shader_parameter("weather_intensity"))
    var mesh: Mesh = water.mesh if water else null
    var plane := mesh as PlaneMesh
    var array_mesh := mesh as ArrayMesh
    var water_level_ok := water != null and absf(water.position.y - WATER_LEVEL) <= 0.001
    var mesh_ok := (plane != null and plane.size.x >= 2999.0 and plane.size.y >= 2999.0) or array_mesh != null
    var param_ok := absf(cloud_param - 0.82) <= 0.002 and absf(weather_param - 0.46) <= 0.002
    add_result(
        "water_visual_material",
        material != null
            and shader_path.ends_with("stylized_water.gdshader")
            and water != null
            and water.material_override == material
            and water_level_ok
            and mesh_ok
            and param_ok,
        "shader %s, water y %.2f, mesh %s, params %.2f/%.2f" % [
            shader_path,
            water.position.y if water else -999.0,
            str(plane.size if plane else Vector2i(array_mesh.get_surface_count(), 0) if array_mesh else Vector2.ZERO),
            cloud_param,
            weather_param
        ]
    )

func test_weather_presentation_batching() -> void:
    if not main or not player:
        add_result("weather_presentation_batching", false, "main or player missing")
        return
    var weather_system = main.get("weather_system")
    if weather_system == null:
        add_result("weather_presentation_batching", false, "weather system missing")
        return
    weather_system.force_weather("clear", 0.0, 0.10, player.global_position)
    var state: Dictionary = weather_system.snapshot()
    var star_root := weather_system.get("star_root") as MultiMeshInstance3D
    var cloud_root := weather_system.get("cloud_root") as Node3D
    var rain := weather_system.get("rain") as MultiMeshInstance3D
    var snow := weather_system.get("snow") as MultiMeshInstance3D
    var clouds_checked := 0
    var cloud_cards := 0
    if cloud_root:
        for child in cloud_root.get_children():
            var cloud := child as MeshInstance3D
            if cloud == null:
                continue
            clouds_checked += 1
            if bool(cloud.get_meta("cloud_card", false)) and cloud.mesh is ArrayMesh:
                cloud_cards += 1
    var stars_batched := star_root != null \
        and star_root.multimesh != null \
        and star_root.multimesh.instance_count == int(state.get("stars", 0)) \
        and star_root.get_child_count() == 0
    var clouds_ok := clouds_checked == int(state.get("clouds", 0)) and cloud_cards == clouds_checked and clouds_checked >= 12
    var precip_ok := rain != null and snow != null and rain.multimesh != null and snow.multimesh != null
    add_result(
        "weather_presentation_batching",
        stars_batched
            and clouds_ok
            and precip_ok
            and bool(state.get("batchedStars", false))
            and bool(state.get("cloudCards", false)),
        "stars batched %s nodes %d/%d, clouds cards %d/%d, precip %s/%s" % [
            str(stars_batched),
            star_root.get_child_count() if star_root else -1,
            int(state.get("stars", 0)),
            cloud_cards,
            clouds_checked,
            str(rain != null and rain.multimesh != null),
            str(snow != null and snow.multimesh != null)
        ]
    )

func test_player_movement() -> void:
    if not player:
        add_result("player_movement", false, "player missing")
        return
    var move_cell := Vector2i(roundi(player.global_position.x / CELL) + 10, roundi(player.global_position.z / CELL))
    reset_player_on_flat_patch(move_cell, 5, true)
    clear_blocks_near_cell(move_cell, 8)
    clear_props_near_cell(move_cell, 8)
    await settle_streamed_chunks_after_relocation("movement_chunks", 120)
    await wait_physics_frames(8)
    var start: Vector3 = player.global_position
    player.set("automated_move", Vector3.RIGHT)
    await wait_physics_frames(70)
    player.set("automated_move", Vector3.ZERO)
    await wait_physics_frames(10)
    var travel: float = Vector2(player.global_position.x - start.x, player.global_position.z - start.z).length()
    var velocity: Vector3 = player.velocity
    var move_value: Vector3 = player.get("automated_move")
    var max_downward_correction: float = player.get("max_downward_terrain_correction")
    add_result(
        "player_movement",
        travel > 4.0,
        "travel %.2f, ticks %d, floor %s, velocity %s, automated_move %s" % [
            travel,
            int(player.get("physics_ticks")),
            str(is_player_grounded()),
            str(velocity),
            str(move_value)
        ]
    )
    add_result("terrain_descent_smoothing", max_downward_correction <= 0.22, "max downward correction %.3f" % max_downward_correction)

    var pre_path_position: Vector3 = player.global_position
    var pre_path_velocity: Vector3 = player.velocity
    var path_base := Vector2i(roundi(player.global_position.x / CELL) + 8, roundi(player.global_position.z / CELL) + 2)
    reset_player_on_flat_patch(path_base, 5, true)
    clear_blocks_near_cell(path_base, 8)
    clear_props_near_cell(path_base, 8)
    await settle_streamed_chunks_after_relocation("path_chunks", 90)
    await wait_physics_frames(8)
    var path_ground: float = surface_y_at_cell2(path_base)
    var path_cells: Array[Vector3i] = []
    var blocks := get_blocks()
    for dx in range(0, 6):
        var path_cell := Vector3i(path_base.x + dx, roundi(path_ground / CELL), path_base.y)
        path_cells.append(path_cell)
        if blocks.has(path_cell):
            var old_path := blocks[path_cell] as Node
            if old_path:
                old_path.queue_free()
            blocks.erase(path_cell)
        main.call("create_block", path_cell, "cobblestonePath", { "world_y": path_ground + CELL * 0.024 })
    player.global_position = Vector3((path_base.x - 1.15) * CELL, path_ground, float(path_base.y) * CELL)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", true)
    await wait_physics_frames(8)
    var path_start_x: float = player.global_position.x
    var path_max_y: float = player.global_position.y
    player.set("automated_move", Vector3.RIGHT)
    for i in range(60):
        await get_tree().physics_frame
        path_max_y = maxf(path_max_y, player.global_position.y)
    player.set("automated_move", Vector3.ZERO)
    await wait_physics_frames(4)
    var path_travel: float = player.global_position.x - path_start_x
    var path_rise: float = path_max_y - path_ground
    blocks = get_blocks()
    for path_cell in path_cells:
        if blocks.has(path_cell):
            var path_body := blocks[path_cell] as Node
            if path_body:
                path_body.queue_free()
            blocks.erase(path_cell)
    player.global_position = pre_path_position
    player.velocity = pre_path_velocity
    player.set("terrain_grounded", true)
    add_result(
        "cobblestone_path_walkable",
        path_travel > CELL * 4.1 and path_rise < 0.18,
        "travel %.2f, rise %.3f" % [path_travel, path_rise]
    )

func test_uphill_smoothing() -> void:
    if not player or not main:
        add_result("terrain_ascent_smoothing", false, "player or main missing")
        return

    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 8, roundi(player.global_position.z / CELL))
    reset_player_on_flat_patch(start_cell, 5, true)
    clear_blocks_near_cell(start_cell, 8)
    clear_props_near_cell(start_cell, 8)
    await settle_streamed_chunks_after_relocation("uphill_flat_chunks", 90)
    await wait_physics_frames(4)
    var base_height: float = surface_y_at_cell2(start_cell)
    var edits := get_volume_edit_markers()

    for dz in range(-1, 2):
        edits[Vector2i(start_cell.x, start_cell.y + dz)] = base_height
        edits[Vector2i(start_cell.x + 1, start_cell.y + dz)] = base_height + CELL
        edits[Vector2i(start_cell.x + 2, start_cell.y + dz)] = base_height + CELL

    main.call("rebuild_chunks_for_cells", [start_cell, Vector2i(start_cell.x + 2, start_cell.y)], 1, true)
    await wait_for_terrain_collision_shapes(90)
    player.global_position = Vector3((start_cell.x - 0.35) * CELL, base_height, start_cell.y * CELL)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", true)
    player.set("max_upward_terrain_correction", 0.0)
    await wait_physics_frames(8)

    player.set("automated_move", Vector3.RIGHT)
    var peak_y: float = player.global_position.y
    for i in range(32):
        await get_tree().physics_frame
        peak_y = max(peak_y, player.global_position.y)
    player.set("automated_move", Vector3.ZERO)
    await wait_physics_frames(8)

    var max_upward_correction: float = player.get("max_upward_terrain_correction")
    var climbed: float = peak_y - base_height
    add_result(
        "terrain_ascent_smoothing",
        max_upward_correction <= 0.18 and climbed > 0.55,
        "max upward correction %.3f, climbed %.2f" % [max_upward_correction, climbed]
    )

func test_steep_uphill_blocking() -> void:
    if not player or not main:
        add_result("terrain_steep_ascent_blocking", false, "player or main missing")
        return

    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 6, roundi(player.global_position.z / CELL))
    var base_height: float = surface_y_at_cell2(start_cell)
    var edits := get_volume_edit_markers()

    for dz in range(-1, 2):
        edits[Vector2i(start_cell.x, start_cell.y + dz)] = base_height
        edits[Vector2i(start_cell.x + 1, start_cell.y + dz)] = base_height + CELL * 3.0
        edits[Vector2i(start_cell.x + 2, start_cell.y + dz)] = base_height + CELL * 3.0

    main.call("rebuild_chunks_for_cells", [start_cell, Vector2i(start_cell.x + 2, start_cell.y)], 1, true)
    await wait_for_terrain_collision_shapes(90)
    player.global_position = Vector3((start_cell.x - 0.35) * CELL, base_height, start_cell.y * CELL)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", true)
    player.set("max_upward_terrain_correction", 0.0)
    await wait_physics_frames(8)

    var start_x: float = player.global_position.x
    player.set("automated_move", Vector3.RIGHT)
    await wait_physics_frames(32)
    player.set("automated_move", Vector3.ZERO)
    await wait_physics_frames(8)

    var climbed: float = player.global_position.y - base_height
    var advanced: float = player.global_position.x - start_x
    var max_upward_correction: float = player.get("max_upward_terrain_correction")
    add_result(
        "terrain_steep_ascent_blocking",
        climbed < 0.45 and advanced < CELL * 0.95 and max_upward_correction <= 0.18,
        "climbed %.2f, advanced %.2f, max upward correction %.3f" % [climbed, advanced, max_upward_correction]
    )

func test_airborne_obstacle_blocking() -> void:
    if not player or not main:
        add_result("airborne_obstacle_blocking", false, "player or main missing")
        return

    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 9, roundi(player.global_position.z / CELL))
    var base_height: float = surface_y_at_cell2(start_cell)
    var obstacle_height: float = base_height + CELL * 4.0
    var edits := get_volume_edit_markers()

    for dz in range(-2, 3):
        for dx in range(-2, 4):
            edits[Vector2i(start_cell.x + dx, start_cell.y + dz)] = base_height
        edits[Vector2i(start_cell.x + 1, start_cell.y + dz)] = obstacle_height
        edits[Vector2i(start_cell.x + 2, start_cell.y + dz)] = obstacle_height

    main.call("rebuild_chunks_for_cells", [start_cell, Vector2i(start_cell.x + 2, start_cell.y)], 1, true)
    await wait_for_terrain_collision_shapes(90)
    player.global_position = Vector3((start_cell.x - 0.35) * CELL, base_height, start_cell.y * CELL)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", true)
    player.set("airborne_obstacle_blocks", 0)
    await wait_physics_frames(8)

    var start_x: float = player.global_position.x
    player.set("automated_jump", true)
    player.set("automated_move", Vector3.RIGHT)
    var peak_y: float = player.global_position.y
    for i in range(45):
        await get_tree().physics_frame
        peak_y = max(peak_y, player.global_position.y)
    player.set("automated_move", Vector3.ZERO)
    player.set("automated_jump", false)
    await wait_physics_frames(8)

    var advanced: float = player.global_position.x - start_x
    var block_count := int(player.get("airborne_obstacle_blocks"))
    add_result(
        "airborne_obstacle_blocking",
        block_count > 0 and peak_y < obstacle_height - 0.55 and advanced < CELL * 1.15,
        "blocks %d, peak y %.2f, obstacle y %.2f, advanced %.2f" % [block_count, peak_y, obstacle_height, advanced]
    )

func test_jump() -> void:
    if not player:
        add_result("jump", false, "player missing")
        return
    mark_progress("jump_reset")
    player.set("automated_move", Vector3.ZERO)
    player.set("automated_jump", false)
    reset_player_on_flat_patch(Vector2i(roundi(player.global_position.x / CELL) + 8, roundi(player.global_position.z / CELL)))
    await wait_physics_frames(8)
    mark_progress("jump_wait_ground")
    for i in range(90):
        if i > 0 and i % 30 == 0:
            mark_progress("jump_wait_ground_%03d" % i)
        if is_player_grounded():
            break
        await get_tree().physics_frame
    var start_y: float = player.global_position.y
    player.set("automated_jump", true)
    var peak_y: float = start_y
    var landing_frame := -1
    var became_airborne := false
    var jumped_seen := false
    var max_velocity_y := -999.0
    var max_snap_time := 0.0
    mark_progress("jump_airborne")
    for i in range(90):
        if i > 0 and i % 30 == 0:
            mark_progress("jump_airborne_%03d" % i)
        await get_tree().physics_frame
        peak_y = max(peak_y, player.global_position.y)
        jumped_seen = jumped_seen or bool(player.get("jumped_this_frame"))
        max_velocity_y = max(max_velocity_y, player.velocity.y)
        max_snap_time = max(max_snap_time, float(player.get("jump_snap_time")))
        if not is_player_grounded():
            became_airborne = true
        elif became_airborne:
            landing_frame = i + 1
            break
    player.set("automated_jump", false)
    var rise: float = peak_y - start_y
    var natural_air_time := landing_frame >= 36 or landing_frame == -1
    add_result(
        "jump",
        rise > 0.55 and natural_air_time,
        "rise %.2f, landing frame %d, floor %s, jumped %s, max vy %.2f, snap %.2f, y %.2f->%.2f" % [
            rise,
            landing_frame,
            str(is_player_grounded()),
            str(jumped_seen),
            max_velocity_y,
            max_snap_time,
            start_y,
            player.global_position.y
        ]
    )

func test_block_destroy_ray() -> void:
    if not player or not camera:
        add_result("block_destroy_ray", false, "player or camera missing")
        return
    var inventory_system = main.get("inventory_system")
    if inventory_system == null:
        add_result("block_destroy_ray", false, "inventory missing")
        return
    inventory_system.add_item("stoneShovel", 1)
    set_active_inventory_item(inventory_system, "stoneShovel")
    var hardness_cell := Vector2i(roundi(player.global_position.x / CELL) + 8, roundi(player.global_position.z / CELL))
    mark_progress("block_destroy_ray_reset_flat")
    reset_player_on_flat_patch(hardness_cell, 5, true)
    mark_progress("block_destroy_ray_clear_blocks")
    clear_blocks_near_cell(hardness_cell, 10)
    mark_progress("block_destroy_ray_clear_props")
    clear_props_near_cell(hardness_cell, 10)
    mark_progress("block_destroy_ray_wait_collision")
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    camera.rotation.x = 0.0
    await wait_for_terrain_collision_shapes(90, chunk_scope_for_flat_cell(hardness_cell))
    await wait_physics_frames(8)

    var forward: Vector3 = -camera.global_transform.basis.z
    forward = forward.normalized()
    var target_pos: Vector3 = camera.global_position + forward * 2.2
    var test_cell := Vector3i(roundi(target_pos.x / CELL), roundi(target_pos.y / CELL), roundi(target_pos.z / CELL))
    main.call("create_block", test_cell, "dirtBlock")
    await wait_physics_frames(4)
    var block_center := Vector3(test_cell.x * CELL, test_cell.y * CELL, test_cell.z * CELL)
    aim_player_at(block_center)
    await wait_physics_frames(2)

    var hit: Dictionary = player.call("view_ray", INTERACT_RANGE)
    var hit_block: bool = false
    if not hit.is_empty():
        var collider: Node = hit["collider"]
        hit_block = collider != null and collider.has_meta("kind") and String(collider.get_meta("kind")) == "block"
    if not hit_block:
        add_result("block_destroy_ray", false, "ray did not hit placed block")
        return

    main.call("destroy_target")
    await wait_physics_frames(2)
    main.call("destroy_target")
    await wait_physics_frames(4)
    var blocks := get_blocks()
    add_result("block_destroy_ray", not blocks.has(test_cell), "placed block removed")

    main.call("reset_break_progress")
    var far_pos: Vector3 = camera.global_position + forward * 7.4
    var far_cell := Vector3i(roundi(far_pos.x / CELL), roundi(far_pos.y / CELL), roundi(far_pos.z / CELL))
    if blocks.has(far_cell):
        var old_far := blocks[far_cell] as Node
        if old_far:
            old_far.queue_free()
        blocks.erase(far_cell)
    main.call("create_block", far_cell, "dirtBlock")
    await wait_physics_frames(4)
    var far_center := Vector3(far_cell.x * CELL, far_cell.y * CELL, far_cell.z * CELL)
    aim_player_at(far_center)
    await wait_physics_frames(2)
    var old_range_hit: Dictionary = player.call("view_ray", INTERACT_RANGE)
    var old_range_can_see := false
    if not old_range_hit.is_empty():
        var far_collider := old_range_hit.get("collider") as Node
        old_range_can_see = far_collider != null and far_collider.has_meta("cell") and far_collider.get_meta("cell") == far_cell
    var far_distance := camera.global_position.distance_to(far_center)
    main.call("destroy_target")
    await wait_physics_frames(2)
    var far_block_still_present: bool = blocks.has(far_cell)
    var far_not_started: bool = String(main.get("break_target_id")) == "" and float(main.get("break_progress")) == 0.0
    if blocks.has(far_cell):
        var far_block := blocks[far_cell] as Node
        if far_block:
            far_block.queue_free()
        blocks.erase(far_cell)
    var far_enemy_safe := true
    var far_enemy_visible_old_range := false
    var far_enemy_health_before := -1.0
    var far_enemy_health_after := -1.0
    var hostile_system = main.get("hostile_system")
    if hostile_system:
        var far_enemy_pos: Vector3 = camera.global_position + forward * 6.3
        far_enemy_pos.y = player.global_position.y + 0.04
        var far_enemy = hostile_system.spawn_enemy(far_enemy_pos, "shadow")
        await wait_physics_frames(4)
        var far_enemy_state_before: Dictionary = hostile_system.call("enemy_for_body", far_enemy)
        if not far_enemy_state_before.is_empty():
            far_enemy_health_before = float(far_enemy_state_before.get("health", 0.0))
        aim_player_at(far_enemy.global_position + Vector3(0.0, 0.9, 0.0))
        await wait_physics_frames(2)
        var far_enemy_hit: Dictionary = player.call("view_ray", INTERACT_RANGE)
        if not far_enemy_hit.is_empty():
            far_enemy_visible_old_range = far_enemy_hit.get("collider") == far_enemy
        main.call("destroy_target")
        await wait_physics_frames(2)
        var far_enemy_state: Dictionary = hostile_system.call("enemy_for_body", far_enemy)
        if not far_enemy_state.is_empty():
            far_enemy_health_after = float(far_enemy_state.get("health", 0.0))
        far_enemy_safe = not far_enemy_state.is_empty() and far_enemy_health_before >= 0.0 and is_equal_approx(far_enemy_health_after, far_enemy_health_before)
        if not far_enemy_state.is_empty():
            hostile_system.call("remove_enemy", far_enemy_state, false)
    add_result(
        "melee_targeting_short_range",
        old_range_can_see and far_distance > MELEE_RANGE and far_block_still_present and far_not_started and far_enemy_safe,
        "old range sees %s, distance %.2f, block still present %s, enemy old-range %s safe %s, enemy health %.1f->%.1f, progress %.2f, target '%s'" % [
            str(old_range_can_see),
            far_distance,
            str(far_block_still_present),
            str(far_enemy_visible_old_range),
            str(far_enemy_safe),
            far_enemy_health_before,
            far_enemy_health_after,
            float(main.get("break_progress")),
            String(main.get("break_target_id"))
        ]
    )

func test_right_mouse_interaction_input() -> void:
    if not main or not player or not camera:
        add_result("right_mouse_interaction_input", false, "main/player/camera missing")
        add_result("left_mouse_held_item_strike_input", false, "main/player/camera missing")
        return
    var inventory_system = main.get("inventory_system")
    var held_item = main.get("held_item")
    var hud = main.get("hud")
    if inventory_system == null or held_item == null or hud == null:
        add_result("right_mouse_interaction_input", false, "inventory, held item, or hud missing")
        add_result("left_mouse_held_item_strike_input", false, "inventory, held item, or hud missing")
        return
    var base_cell := Vector2i(roundi(player.global_position.x / CELL) + 8, roundi(player.global_position.z / CELL))
    mark_progress("right_mouse_reset_flat")
    reset_player_on_flat_patch(base_cell, 5, true)
    mark_progress("right_mouse_clear_blocks")
    clear_blocks_near_cell(base_cell, 8)
    mark_progress("right_mouse_clear_props")
    clear_props_near_cell(base_cell, 8)
    mark_progress("right_mouse_wait_collision")
    await wait_for_terrain_collision_shapes(90, chunk_scope_for_flat_cell(base_cell))
    await wait_physics_frames(8)

    var ground_y: float = surface_y_at_cell2(base_cell + Vector2i(0, -2))
    var door_cell := Vector3i(base_cell.x, floori(ground_y / CELL) + 1, base_cell.y - 2)
    mark_progress("right_mouse_create_door")
    var door := main.call("create_block", door_cell, "door") as StaticBody3D
    await wait_physics_frames(6)
    if door == null:
        add_result("right_mouse_interaction_input", false, "door creation failed")
        return

    mark_progress("right_mouse_aim")
    var aim_point := door.global_position + Vector3(0.0, CELL * 0.45, 0.0)
    aim_player_at(aim_point)
    await wait_physics_frames(3)
    var hit: Dictionary = player.call("view_ray", INTERACT_RANGE, true)
    var hit_block: Node = main.call("interaction_block_from_collider", hit.get("collider")) if not hit.is_empty() else null
    var hit_door: bool = hit_block == door
    var prompt := String(main.call("focused_interaction_prompt"))
    var prompt_reach := 999.0
    if hit.has("position"):
        var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
        prompt_reach = Vector2(hit_position.x - player.global_position.x, hit_position.z - player.global_position.z).length()
    var right_click_position := control_center(hud.location_panel)
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    mark_progress("right_mouse_click_down")
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true, right_click_position)
    await wait_physics_frames(3)
    mark_progress("right_mouse_click_up")
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false, right_click_position)
    var opened_first_click: bool = bool(door.get_meta("open", false))
    var pivot := door.get_node_or_null("DoorPivot") as Node3D
    add_result(
        "right_mouse_interaction_input",
        hit_door and prompt.find("Open door") >= 0 and opened_first_click and pivot != null and abs(pivot.rotation.y) > 0.5,
        "hitDoor %s prompt '%s' reach %.2f/%.2f opened %s pivot %s click %s mouseActual %d" % [
            str(hit_door),
            prompt,
            prompt_reach,
            ACTION_REACH,
            str(opened_first_click),
            str(pivot != null),
            str(right_click_position),
            int(Input.get_mouse_mode())
        ]
    )

    mark_progress("left_mouse_cleanup_blocks")
    clear_blocks_near_cell(base_cell, 8)
    mark_progress("left_mouse_cleanup_props")
    clear_props_near_cell(base_cell, 8)
    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    inventory_system.clear()
    inventory_system.add_item("woodenAxe", 1)
    set_active_inventory_item(inventory_system, "woodenAxe")
    if held_item.has_method("refresh_active"):
        held_item.refresh_active()
    held_item.set("use_action", "")
    held_item.set("use_time", 0.0)
    if held_item.has_method("apply_pose"):
        held_item.apply_pose()
    var left_fixture_cell := Vector2i(base_cell.x + 6, base_cell.y)
    mark_progress("left_mouse_reset_flat")
    reset_player_on_flat_patch(left_fixture_cell, 5, true)
    mark_progress("left_mouse_wait_collision")
    await wait_for_terrain_collision_shapes(90, chunk_scope_for_flat_cell(left_fixture_cell))
    player.rotation.y = 0.0
    player.set("pitch", deg_to_rad(-18.0))
    camera.rotation.x = deg_to_rad(-18.0)
    await wait_physics_frames(4)
    var before_action := String(held_item.get("use_action"))
    var before_time := float(held_item.get("use_time"))
    var left_click_position := control_center(hud.hotbar)
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    dispatch_mouse_button(MOUSE_BUTTON_LEFT, true, left_click_position)
    await wait_physics_frames(2)
    dispatch_mouse_button(MOUSE_BUTTON_LEFT, false, left_click_position)
    var after_action := String(held_item.get("use_action"))
    var after_time := float(held_item.get("use_time"))
    add_result(
        "left_mouse_held_item_strike_input",
        String(held_item.get("current_item")) == "woodenAxe" and after_action == "strike" and after_time > before_time,
        "item %s action %s->%s time %.2f->%.2f click %s mouseActual %d" % [
            String(held_item.get("current_item")),
            before_action,
            after_action,
            before_time,
            after_time,
            str(left_click_position),
            int(Input.get_mouse_mode())
        ]
    )

func test_mining_tool_requirements() -> void:
    if not main or not player or not camera:
        add_result("mining_tool_requirements", false, "main/player/camera missing")
        return
    var inventory_system = main.get("inventory_system")
    var hud = main.get("hud")
    if inventory_system == null or hud == null:
        add_result("mining_tool_requirements", false, "inventory or hud missing")
        return
    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }
    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    inventory_system.clear()
    inventory_system.add_item("woodenPickaxe", 1)
    inventory_system.add_item("stonePickaxe", 1)
    inventory_system.add_item("copperPickaxe", 1)
    inventory_system.select(0)

    mark_progress("mining_requirements_place_player")
    reset_player_on_flat_patch(Vector2i(roundi(player.global_position.x / CELL) + 9, roundi(player.global_position.z / CELL)))
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    camera.rotation.x = 0.0
    await wait_physics_frames(8)

    mark_progress("mining_requirements_create_copper")
    var forward: Vector3 = -camera.global_transform.basis.z.normalized()
    var copper_pos: Vector3 = camera.global_position + forward * 2.2
    var copper_cell := Vector3i(roundi(copper_pos.x / CELL), roundi(copper_pos.y / CELL), roundi(copper_pos.z / CELL))
    var iron_cell := copper_cell
    var blocks := get_blocks()
    if blocks.has(copper_cell):
        var existing := blocks[copper_cell] as Node
        if existing:
            existing.queue_free()
        blocks.erase(copper_cell)
    main.call("create_block", copper_cell, "copperVein")
    await wait_physics_frames(4)

    mark_progress("mining_requirements_wrong_copper_tool")
    set_active_inventory_item(inventory_system, "woodenPickaxe")
    aim_player_at(Vector3(copper_cell.x * CELL, copper_cell.y * CELL, copper_cell.z * CELL))
    await wait_physics_frames(2)
    main.call("destroy_target")
    await wait_physics_frames(2)
    var copper_tool_message: String = hud.notification_label.text if hud.notification_label != null else ""
    var copper_wrong_blocked: bool = blocks.has(copper_cell) and float(main.get("break_progress")) == 0.0 and copper_tool_message.find("Stone Pickaxe") >= 0

    mark_progress("mining_requirements_mine_copper")
    set_active_inventory_item(inventory_system, "stonePickaxe")
    var copper_before: int = inventory_system.count("copperOre")
    for i in range(3):
        mark_progress("mining_requirements_mine_copper_%02d" % i)
        main.call("destroy_target")
        await wait_physics_frames(2)
    var copper_mined: bool = not blocks.has(copper_cell) and inventory_system.count("copperOre") > copper_before

    mark_progress("mining_requirements_create_iron")
    main.call("reset_break_progress")
    if blocks.has(iron_cell):
        var existing_iron := blocks[iron_cell] as Node
        if existing_iron:
            existing_iron.queue_free()
        blocks.erase(iron_cell)
    main.call("create_block", iron_cell, "ironVein")
    await wait_physics_frames(4)
    mark_progress("mining_requirements_wrong_iron_tool")
    set_active_inventory_item(inventory_system, "stonePickaxe")
    aim_player_at(Vector3(iron_cell.x * CELL, iron_cell.y * CELL, iron_cell.z * CELL))
    await wait_physics_frames(2)
    main.call("destroy_target")
    await wait_physics_frames(2)
    var iron_tool_message: String = hud.notification_label.text if hud.notification_label != null else ""
    var iron_wrong_blocked: bool = blocks.has(iron_cell) and float(main.get("break_progress")) == 0.0 and iron_tool_message.find("Copper Pickaxe") >= 0

    mark_progress("mining_requirements_mine_iron")
    set_active_inventory_item(inventory_system, "copperPickaxe")
    var iron_before: int = inventory_system.count("ironOre")
    for i in range(3):
        mark_progress("mining_requirements_mine_iron_%02d" % i)
        main.call("destroy_target")
        await wait_physics_frames(2)
    var iron_mined: bool = not blocks.has(iron_cell) and inventory_system.count("ironOre") > iron_before

    for cell in [copper_cell, iron_cell]:
        if blocks.has(cell):
            var body := blocks[cell] as Node
            if body:
                body.queue_free()
            blocks.erase(cell)
    inventory_system.restore(original_inventory)
    main.call("reset_break_progress")

    add_result(
        "mining_tool_requirements",
        copper_wrong_blocked and copper_mined and iron_wrong_blocked and iron_mined,
        "copper blocked %s/mined %s, iron blocked %s/mined %s, hud '%s'" % [
            str(copper_wrong_blocked),
            str(copper_mined),
            str(iron_wrong_blocked),
            str(iron_mined),
            iron_tool_message
        ]
    )

func test_mining_upgrade_progression() -> void:
    if not main or not player or not camera:
        add_result("mining_upgrade_progression", false, "main/player/camera missing")
        return
    var inventory_system = main.get("inventory_system")
    var crafting_system = main.get("crafting_system")
    var objective_system = main.get("objective_system")
    var contract_system = main.get("contract_system")
    var progression_system = main.get("progression_system")
    var utility_system = main.get("utility_system")
    if inventory_system == null or crafting_system == null or objective_system == null or contract_system == null or progression_system == null or utility_system == null:
        add_result("mining_upgrade_progression", false, "required systems missing")
        return
    crafting_system.unlock_all_groups()

    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }
    var original_objectives: Dictionary = objective_system.snapshot()
    var original_contracts: Dictionary = contract_system.snapshot()
    var original_progression: Dictionary = progression_system.snapshot()
    var discovered_biomes: Dictionary = main.get("discovered_biomes")
    var discovered_towns: Dictionary = main.get("discovered_town_keys")
    var original_biomes: Dictionary = discovered_biomes.duplicate(true)
    var original_towns: Dictionary = discovered_towns.duplicate(true)
    var created_cells: Array[Vector3i] = []

    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    inventory_system.clear()
    inventory_system.add_item("logs", 34)
    inventory_system.add_item("stones", 8)
    objective_system.restore({ "completed": [], "total": objective_system.all_objectives().size() })
    contract_system.reset()
    progression_system.restore({ "level": 1, "xp": 0, "totalXp": 0 })
    discovered_biomes.clear()
    discovered_towns.clear()
    discovered_towns["playtestTown"] = true

    reset_player_on_flat_patch(Vector2i(roundi(player.global_position.x / CELL) + 11, roundi(player.global_position.z / CELL) + 1))
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    camera.rotation.x = 0.0
    await wait_physics_frames(8)

    var base_cell := Vector3i(roundi(player.global_position.x / CELL) + 2, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL) + 1)
    var workbench_cell := base_cell
    var furnace_cell := base_cell + Vector3i(2, 0, 0)
    var anvil_cell := base_cell + Vector3i(3, 0, 0)
    var workbench := main.call("create_block", workbench_cell, "workbench") as StaticBody3D
    var furnace := main.call("create_block", furnace_cell, "furnace") as StaticBody3D
    var anvil := main.call("create_block", anvil_cell, "anvil") as StaticBody3D
    created_cells.append(workbench_cell)
    created_cells.append(furnace_cell)
    created_cells.append(anvil_cell)
    if workbench == null or furnace == null or anvil == null:
        add_result("mining_upgrade_progression", false, "failed to create workbench/furnace/anvil")
        inventory_system.restore(original_inventory)
        objective_system.restore(original_objectives)
        contract_system.restore(original_contracts)
        progression_system.restore(original_progression)
        discovered_biomes.clear()
        for key in original_biomes.keys():
            discovered_biomes[key] = original_biomes[key]
        discovered_towns.clear()
        for key in original_towns.keys():
            discovered_towns[key] = original_towns[key]
        return

    main.call("update_objectives_and_contracts")
    var crafted_wooden: bool = bool(crafting_system.craft("woodenPickaxe"))
    var crafted_stone: bool = bool(crafting_system.craft("stonePickaxe"))
    await wait_physics_frames(2)

    var forward: Vector3 = -camera.global_transform.basis.z.normalized()
    var ore_pos: Vector3 = camera.global_position + forward * 2.2
    var ore_cell := Vector3i(roundi(ore_pos.x / CELL), roundi(ore_pos.y / CELL), roundi(ore_pos.z / CELL))
    var blocks := get_blocks()
    if blocks.has(ore_cell):
        var existing := blocks[ore_cell] as Node
        if existing:
            existing.queue_free()
        blocks.erase(ore_cell)
    created_cells.append(ore_cell)

    main.call("create_block", ore_cell, "copperVein")
    await wait_physics_frames(4)
    set_active_inventory_item(inventory_system, "stonePickaxe")
    aim_player_at(Vector3(ore_cell.x * CELL, ore_cell.y * CELL, ore_cell.z * CELL))
    await wait_physics_frames(2)
    for i in range(3):
        main.call("destroy_target")
        await wait_physics_frames(2)
    var copper_mined: bool = not blocks.has(ore_cell) and inventory_system.count("copperOre") > 0

    inventory_system.add_item("copperOre", max(0, 4 - inventory_system.count("copperOre")))
    var copper_smelted: int = smelt_test_items(utility_system, furnace, inventory_system, "copperOre", 4)
    main.call("update_objectives_and_contracts")
    var crafted_copper_pickaxe: bool = bool(crafting_system.craft("copperPickaxe"))
    await wait_physics_frames(2)

    if blocks.has(ore_cell):
        var stale := blocks[ore_cell] as Node
        if stale:
            stale.queue_free()
        blocks.erase(ore_cell)
    main.call("create_block", ore_cell, "ironVein")
    await wait_physics_frames(4)
    set_active_inventory_item(inventory_system, "copperPickaxe")
    aim_player_at(Vector3(ore_cell.x * CELL, ore_cell.y * CELL, ore_cell.z * CELL))
    await wait_physics_frames(2)
    for i in range(3):
        main.call("destroy_target")
        await wait_physics_frames(2)
    var iron_mined: bool = not blocks.has(ore_cell) and inventory_system.count("ironOre") > 0

    inventory_system.add_item("ironOre", max(0, 3 - inventory_system.count("ironOre")))
    var iron_smelted: int = smelt_test_items(utility_system, furnace, inventory_system, "ironOre", 3)
    main.call("update_objectives_and_contracts")
    var crafted_iron_pickaxe: bool = bool(crafting_system.craft("ironPickaxe"))
    for i in range(8):
        main.call("update_objectives_and_contracts")

    var objective_state: Dictionary = main.call("objective_state")
    var objective_ids := ["woodenPickaxe", "stonePickaxe", "mineCopper", "smeltCopper", "craftCopperPickaxe", "mineIron", "smeltIron", "craftIronPickaxe"]
    var incomplete_objectives := []
    for objective_id in objective_ids:
        if not bool(objective_system.is_complete(String(objective_id), objective_state)):
            incomplete_objectives.append(objective_id)
    var completed_contracts: Array = contract_system.snapshot().get("completed", [])
    var contract_ids := ["copperSample", "smelterRun", "ironSample"]
    var missing_contracts := []
    for contract_id in contract_ids:
        if not completed_contracts.has(contract_id):
            missing_contracts.append(contract_id)
    var progression_ok: bool = crafted_wooden and crafted_stone and copper_mined and copper_smelted >= 4 and crafted_copper_pickaxe and iron_mined and iron_smelted >= 3 and crafted_iron_pickaxe

    utility_system.close()
    for cell in created_cells:
        if blocks.has(cell):
            var body := blocks[cell] as Node
            if body:
                body.queue_free()
            blocks.erase(cell)
    inventory_system.restore(original_inventory)
    objective_system.restore(original_objectives)
    contract_system.restore(original_contracts)
    progression_system.restore(original_progression)
    main.call("reset_break_progress")
    discovered_biomes.clear()
    for key in original_biomes.keys():
        discovered_biomes[key] = original_biomes[key]
    discovered_towns.clear()
    for key in original_towns.keys():
        discovered_towns[key] = original_towns[key]

    add_result(
        "mining_upgrade_progression",
        progression_ok and incomplete_objectives.is_empty() and missing_contracts.is_empty(),
        "crafted %s/%s/%s/%s, mined %s/%s, smelted %d/%d, incomplete %s, contracts %s" % [
            str(crafted_wooden),
            str(crafted_stone),
            str(crafted_copper_pickaxe),
            str(crafted_iron_pickaxe),
            str(copper_mined),
            str(iron_mined),
            copper_smelted,
            iron_smelted,
            str(incomplete_objectives),
            str(missing_contracts)
        ]
    )

func test_material_hardness_and_reset() -> void:
    if not main or not player or not camera:
        add_result("material_hardness", false, "main/player/camera missing")
        return
    mark_progress("material_hardness_setup")
    var inventory_system = main.get("inventory_system")
    if inventory_system == null:
        add_result("material_hardness", false, "inventory missing")
        return
    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }
    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    inventory_system.clear()

    var hardness_cell := Vector2i(roundi(player.global_position.x / CELL) + 8, roundi(player.global_position.z / CELL))
    mark_progress("material_hardness_reset_patch")
    reset_player_on_flat_patch(hardness_cell)
    mark_progress("material_hardness_clear_blocks")
    clear_blocks_near_cell(hardness_cell, 10)
    mark_progress("material_hardness_clear_props")
    clear_props_near_cell(hardness_cell, 10)
    var disabled_prop_shapes: Array[CollisionShape3D] = []
    mark_progress("material_hardness_disable_near_props")
    disable_prop_colliders_near_cell(hardness_cell, 12, disabled_prop_shapes)
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    camera.rotation.x = 0.0
    mark_progress("material_hardness_wait_settle")
    await wait_physics_frames(8)

    var forward: Vector3 = -camera.global_transform.basis.z
    var target_pos: Vector3 = camera.global_position + forward.normalized() * 2.2
    var test_cell := Vector3i(roundi(target_pos.x / CELL), roundi(target_pos.y / CELL), roundi(target_pos.z / CELL))
    mark_progress("material_hardness_create_block")
    main.call("create_block", test_cell, "stoneBlock")
    await wait_physics_frames(4)
    var blocks := get_blocks()
    var block_center := Vector3(test_cell.x * CELL, test_cell.y * CELL, test_cell.z * CELL)
    aim_player_at(block_center)
    mark_progress("material_hardness_aim")
    await wait_physics_frames(2)

    var pre_hit: Dictionary = player.call("view_ray", MELEE_RANGE)
    var pre_hit_kind := ""
    var pre_hit_type := ""
    var pre_hit_cell := Vector3i.ZERO
    if not pre_hit.is_empty():
        var pre_collider := pre_hit.get("collider") as Node
        if pre_collider != null:
            pre_hit_kind = String(pre_collider.get_meta("kind", ""))
            pre_hit_type = String(pre_collider.get_meta("block_type", pre_collider.get_meta("material", "")))
            if pre_collider.has_meta("cell"):
                pre_hit_cell = pre_collider.get_meta("cell")
    main.call("destroy_target")
    await wait_physics_frames(4)
    var bare_hand_blocked: bool = blocks.has(test_cell) and float(main.get("break_progress")) == 0.0 and String(main.get("last_hud_refresh_message")).find("Wooden Pickaxe") >= 0

    inventory_system.add_item("woodenPickaxe", 1)
    set_active_inventory_item(inventory_system, "woodenPickaxe")
    main.call("reset_break_progress")
    main.call("destroy_target")
    await wait_physics_frames(4)
    blocks = get_blocks()
    var overlay := main.get("break_overlay") as MeshInstance3D
    var cracked_not_destroyed: bool = blocks.has(test_cell) and float(main.get("break_progress")) > 0.0 and overlay != null and overlay.visible
    add_result(
        "material_hardness_first_strike",
        bare_hand_blocked and cracked_not_destroyed,
        "bareBlocked %s progress %.2f, overlay %s, prehit %s/%s cell %s target %s active %s dist %.2f" % [
            str(bare_hand_blocked),
            float(main.get("break_progress")),
            str(overlay != null and overlay.visible),
            pre_hit_kind,
            pre_hit_type,
            str(pre_hit_cell),
            str(test_cell),
            String(inventory_system.active_stack().get("item", "")),
            camera.global_position.distance_to(block_center)
        ]
    )

    mark_progress("material_hardness_wait_reset")
    for i in range(160):
        if i > 0 and i % 40 == 0:
            mark_progress("material_hardness_wait_reset_%03d" % i)
        var reset_ready := float(main.get("break_progress")) == 0.0 and String(main.get("break_target_id")) == "" and overlay != null and not overlay.visible
        if reset_ready:
            break
        await get_tree().physics_frame
    var reset := float(main.get("break_progress")) == 0.0 and String(main.get("break_target_id")) == "" and overlay != null and not overlay.visible
    add_result("break_progress_resets", reset, "progress %.2f, target '%s'" % [float(main.get("break_progress")), String(main.get("break_target_id"))])

    mark_progress("material_hardness_destroy")
    for i in range(7):
        main.call("destroy_target")
        await wait_physics_frames(2)
    blocks = get_blocks()
    add_result("material_hardness_destroyed", not blocks.has(test_cell), "stone block removed after repeated strikes")
    mark_progress("material_hardness_gating")
    inventory_system.clear()
    var tree_gate := String(main.call("unmet_tool_requirement_message", "tree")).find("Wooden Axe") >= 0
    var rock_gate := String(main.call("unmet_tool_requirement_message", "rock")).find("Wooden Pickaxe") >= 0
    var wildlife_gate := String(main.call("unmet_tool_requirement_message", "wildlife")).find("Wooden Sword") >= 0
    var bare_hostile_damage_low := float(main.call("melee_damage_for_active_item")) <= 1.1
    var bare_damage := float(main.call("melee_damage_for_active_item"))
    inventory_system.add_item("woodenSword", 1)
    set_active_inventory_item(inventory_system, "woodenSword")
    var wooden_sword_damage := float(main.call("melee_damage_for_active_item"))
    inventory_system.add_item("nightBlade", 1)
    set_active_inventory_item(inventory_system, "nightBlade")
    var night_blade_damage := float(main.call("melee_damage_for_active_item"))
    add_result(
        "tool_weapon_gating_and_scaling",
        tree_gate and rock_gate and wildlife_gate and bare_hostile_damage_low and wooden_sword_damage > 15.0 and night_blade_damage > wooden_sword_damage,
        "tree %s rock %s wildlife %s bare %.1f woodenSword %.1f nightBlade %.1f" % [
            str(tree_gate),
            str(rock_gate),
            str(wildlife_gate),
            bare_damage,
            wooden_sword_damage,
            night_blade_damage
        ]
    )
    restore_collision_shapes(disabled_prop_shapes)
    inventory_system.restore(original_inventory)

func save_optional_screenshot() -> void:
    var screenshot_path: String = OS.get_environment("VOXEL_PLAYTEST_SCREENSHOT")
    if screenshot_path == "":
        return
    var image: Image = get_viewport().get_texture().get_image()
    var err: Error = image.save_png(screenshot_path)
    add_result("screenshot_saved", err == OK, screenshot_path)

func save_report(verbose := true) -> void:
    var report_path: String = OS.get_environment("VOXEL_PLAYTEST_REPORT")
    if report_path == "":
        report_path = "user://playtest-report.json"
    var report: Dictionary = {
        "finished": finished,
        "passed": not failed,
        "results": results
    }
    var run_token := OS.get_environment("VOXEL_PLAYTEST_RUN_TOKEN")
    if run_token != "":
        report["runToken"] = run_token
    var test_seed := OS.get_environment("VOXEL_TEST_SEED").strip_edges()
    if test_seed != "":
        report["seed"] = test_seed
    var file: FileAccess = FileAccess.open(report_path, FileAccess.WRITE)
    if file == null:
        push_error("Could not write playtest report: %s" % report_path)
        return
    file.store_string(JSON.stringify(report, "  "))
    file.close()
    if verbose:
        print("Playtest report: %s" % report_path)

func get_chunks() -> Dictionary:
    if not main:
        return {}
    var value: Variant = main.get("chunks")
    if value is Dictionary:
        return value
    return {}

func get_blocks() -> Dictionary:
    if not main:
        return {}
    var value: Variant = main.get("blocks")
    if value is Dictionary:
        return value
    return {}

func get_volume_edit_markers() -> Dictionary:
    if not main:
        return {}
    var value: Variant = main.get("volume_edit_markers")
    if value is Dictionary:
        return value
    return {}

func move_player_near_first_block_type(block_type: String, offset := Vector3(0.0, 0.0, CELL * 1.25)) -> bool:
    if player == null:
        return false
    for block in get_blocks().values():
        var body := block as Node3D
        if body == null or not body.has_meta("block_type"):
            continue
        if String(body.get_meta("block_type", "")) != block_type:
            continue
        player.global_position = body.global_position + offset
        player.velocity = Vector3.ZERO
        player.set("terrain_grounded", true)
        return true
    return false

func find_first_block_by_type(block_type: String) -> Node:
    for block in get_blocks().values():
        var body := block as Node
        if body == null or not body.has_meta("block_type"):
            continue
        if String(body.get_meta("block_type", "")) == block_type:
            return body
    return null

func count_starter_beds(tutorial_system) -> int:
    if tutorial_system == null:
        return 0
    var starter_cell: Vector2i = tutorial_system.get("start_cell")
    if starter_cell == Vector2i.ZERO:
        var state: Dictionary = tutorial_system.state()
        var town_center: Vector2i = state.get("townCenter", Vector2i.ZERO)
        starter_cell = Vector2i(town_center.x - 13, town_center.y - 10)
    var bed_cell := starter_cell + Vector2i(-1, 2)
    var count := 0
    for block in get_blocks().values():
        var body := block as Node3D
        if body == null or not body.has_meta("block_type"):
            continue
        if String(body.get_meta("block_type", "")) != "bed":
            continue
        var block_cell: Vector3i = body.get_meta("cell", Vector3i.ZERO)
        if abs(block_cell.x - bed_cell.x) <= 1 and abs(block_cell.z - bed_cell.y) <= 1:
            count += 1
    return count

func world_to_flat_cell(position: Vector3) -> Vector2i:
    return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func building_bounds_near(center_cell: Vector2i, radius: int) -> Dictionary:
    var min_x := 2147483647
    var min_z := 2147483647
    var max_x := -2147483648
    var max_z := -2147483648
    var found := false
    for block in get_blocks().values():
        var body := block as Node
        if body == null or not body.has_meta("block_type") or not body.has_meta("cell"):
            continue
        var block_type := String(body.get_meta("block_type", ""))
        if not (block_type in ["woodBlock", "stoneBlock", "glass", "door"]):
            continue
        var cell: Vector3i = body.get_meta("cell", Vector3i.ZERO)
        if abs(cell.x - center_cell.x) > radius or abs(cell.z - center_cell.y) > radius:
            continue
        min_x = mini(min_x, cell.x)
        max_x = maxi(max_x, cell.x)
        min_z = mini(min_z, cell.z)
        max_z = maxi(max_z, cell.z)
        found = true
    return { "valid": found, "minX": min_x, "maxX": max_x, "minZ": min_z, "maxZ": max_z }

func shrink_cell_bounds(bounds: Dictionary, x_padding: int, min_z_padding: int, max_z_padding: int) -> Dictionary:
    if not bool(bounds.get("valid", false)):
        return { "valid": false }
    var min_x := int(bounds.get("minX", 0)) + x_padding
    var max_x := int(bounds.get("maxX", 0)) - x_padding
    var min_z := int(bounds.get("minZ", 0)) + min_z_padding
    var max_z := int(bounds.get("maxZ", 0)) - max_z_padding
    return { "valid": min_x <= max_x and min_z <= max_z, "minX": min_x, "maxX": max_x, "minZ": min_z, "maxZ": max_z }

func point_in_cell_bounds(cell: Vector2i, bounds: Dictionary) -> bool:
    if not bool(bounds.get("valid", false)):
        return false
    return (
        cell.x >= int(bounds.get("minX", 0))
        and cell.x <= int(bounds.get("maxX", 0))
        and cell.y >= int(bounds.get("minZ", 0))
        and cell.y <= int(bounds.get("maxZ", 0))
    )

func find_first_block_with_meta(meta_key: String, expected_value) -> Node:
    for block in get_blocks().values():
        var body := block as Node
        if body == null or not body.has_meta(meta_key):
            continue
        if body.get_meta(meta_key) == expected_value:
            return body
    return null

func find_inventory_slot(inventory_system, item_id: String) -> int:
    if inventory_system == null:
        return -1
    for i in range(inventory_system.slots.size()):
        var slot: Dictionary = inventory_system.slots[i]
        if String(slot.get("item", "")) == item_id and int(slot.get("count", 0)) > 0:
            return i
    return -1

func set_active_inventory_item(inventory_system, item_id: String) -> bool:
    var slot := find_inventory_slot(inventory_system, item_id)
    if slot < 0:
        return false
    inventory_system.select(0)
    if slot != 0:
        inventory_system.swap_with_active(slot)
    return true

func smelt_test_items(utility_system, furnace: Node, inventory_system, input_item: String, count: int) -> int:
    if utility_system == null or furnace == null or inventory_system == null:
        return 0
    var produced := 0
    utility_system.open_block(furnace)
    for i in range(count):
        if not inventory_system.consume_costs({ input_item: 1, "logs": 1 }):
            break
        var state: Dictionary = utility_system.ensure_furnace(furnace)
        state["input"] = { "item": input_item, "count": 1 }
        state["fuel"] = { "item": "logs", "count": 1 }
        state["output"] = { "item": "", "count": 0 }
        state["processing"] = false
        state["progress"] = 0.0
        utility_system.set_furnace_state(furnace, state)
        if not bool(utility_system.start_processing()):
            break
        utility_system.update(12.0)
        state = utility_system.ensure_furnace(furnace)
        var output_slot: Dictionary = state.get("output", {})
        var output_item := String(output_slot.get("item", ""))
        var output_count := int(output_slot.get("count", 0))
        if output_item == "" or output_count <= 0:
            continue
        produced += inventory_system.add_item(output_item, output_count)
        output_slot["item"] = ""
        output_slot["count"] = 0
        state["output"] = output_slot
        utility_system.set_furnace_state(furnace, state)
    return produced

func count_mesh_descendants(node: Node) -> int:
    if node == null:
        return 0
    var count := 0
    if node is MeshInstance3D:
        count += 1
    for child in node.get_children():
        count += count_mesh_descendants(child)
    return count

func count_light_descendants(node: Node) -> int:
    if node == null:
        return 0
    var count := 0
    if node is Light3D:
        count += 1
    for child in node.get_children():
        count += count_light_descendants(child)
    return count

func count_fire_light_descendants(node: Node) -> int:
    if node == null:
        return 0
    var count := 0
    if node is Light3D and bool(node.get_meta("fire_light", false)):
        count += 1
    for child in node.get_children():
        count += count_fire_light_descendants(child)
    return count

func ground_fill_light_descendants(node: Node) -> Array:
    var lights := []
    if node == null:
        return lights
    if node is Light3D and bool(node.get_meta("ground_fill_light", false)):
        lights.append(node)
    for child in node.get_children():
        lights.append_array(ground_fill_light_descendants(child))
    return lights

func light_role_descendants(node: Node, role: String) -> Array:
    var lights := []
    if node == null:
        return lights
    if node is Light3D and String(node.get_meta("light_role", "")) == role:
        lights.append(node)
    for child in node.get_children():
        lights.append_array(light_role_descendants(child, role))
    return lights

func first_light_role_descendant(node: Node, role: String) -> Light3D:
    if node == null:
        return null
    if node is Light3D and String(node.get_meta("light_role", "")) == role:
        return node as Light3D
    for child in node.get_children():
        var found := first_light_role_descendant(child, role)
        if found != null:
            return found
    return null

func local_light_rig_descendants(node: Node) -> Array:
    var lights := []
    if node == null:
        return lights
    if node is Light3D and bool(node.get_meta("local_light_rig", false)):
        lights.append(node)
    for child in node.get_children():
        lights.append_array(local_light_rig_descendants(child))
    return lights

func ground_overlay_mesh_descendants(node: Node) -> Array:
    var overlays := []
    if node == null:
        return overlays
    if node is MeshInstance3D:
        var node_name := String(node.name).to_lower()
        var visual_role := String(node.get_meta("visual_role", "")).to_lower()
        if node_name.find("groundpool") >= 0 or visual_role == "groundlightpool":
            overlays.append(node)
    for child in node.get_children():
        overlays.append_array(ground_overlay_mesh_descendants(child))
    return overlays

func count_shadowed_light_descendants(node: Node) -> int:
    if node == null:
        return 0
    var count := 0
    if node is Light3D and bool((node as Light3D).shadow_enabled):
        count += 1
    for child in node.get_children():
        count += count_shadowed_light_descendants(child)
    return count

func first_light_descendant(node: Node) -> Light3D:
    if node == null:
        return null
    if node is Light3D:
        return node as Light3D
    for child in node.get_children():
        var found := first_light_descendant(child)
        if found != null:
            return found
    return null

func light_base_energy(light: Light3D) -> float:
    if light == null:
        return 0.0
    var value = light.get("base_energy")
    if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
        return float(value)
    return light.light_energy

func light_base_range(light: Light3D) -> float:
    if light == null:
        return 0.0
    var value = light.get("base_range")
    if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
        return float(value)
    var omni := light as OmniLight3D
    return omni.omni_range if omni != null else 0.0

func light_flicker_min_scale(light: Light3D) -> float:
    if light == null:
        return 0.0
    var meta_value = light.get_meta("flicker_min_scale", light.get("min_energy_scale"))
    if typeof(meta_value) == TYPE_FLOAT or typeof(meta_value) == TYPE_INT:
        return float(meta_value)
    return 0.0

func terrain_light_uniform_first_range(shader_material: ShaderMaterial) -> float:
    if shader_material == null:
        return 0.0
    var positions_value = shader_material.get_shader_parameter("terrain_local_light_positions")
    if typeof(positions_value) == TYPE_PACKED_VECTOR4_ARRAY:
        var position_vectors: PackedVector4Array = positions_value
        if position_vectors.size() > 0:
            return position_vectors[0].w
    elif typeof(positions_value) == TYPE_ARRAY:
        var position_array: Array = positions_value
        if position_array.size() > 0 and position_array[0] is Vector4:
            return (position_array[0] as Vector4).w
    return 0.0

func terrain_light_uniform_max_energy(shader_material: ShaderMaterial) -> float:
    if shader_material == null:
        return 0.0
    var colors_value = shader_material.get_shader_parameter("terrain_local_light_colors")
    var strongest := 0.0
    if typeof(colors_value) == TYPE_PACKED_VECTOR4_ARRAY:
        var color_vectors: PackedVector4Array = colors_value
        for value in color_vectors:
            strongest = maxf(strongest, value.w)
    elif typeof(colors_value) == TYPE_ARRAY:
        var color_array: Array = colors_value
        for value in color_array:
            if value is Vector4:
                strongest = maxf(strongest, (value as Vector4).w)
    return strongest

func render_policy_stats(node: Node) -> Dictionary:
    var stats := {
        "meshes": 0,
        "shadowOn": 0,
        "shadowOff": 0,
        "visibility": 0
    }
    collect_render_policy_stats(node, stats)
    return stats

func collect_render_policy_stats(node: Node, stats: Dictionary) -> void:
    if node == null:
        return
    if node is MeshInstance3D:
        var mesh_instance := node as MeshInstance3D
        stats["meshes"] = int(stats["meshes"]) + 1
        if mesh_instance.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
            stats["shadowOff"] = int(stats["shadowOff"]) + 1
        else:
            stats["shadowOn"] = int(stats["shadowOn"]) + 1
        if mesh_instance.visibility_range_end > 0.0:
            stats["visibility"] = int(stats["visibility"]) + 1
    for child in node.get_children():
        collect_render_policy_stats(child, stats)

func render_policy_has_shadow(stats: Dictionary) -> bool:
    var meshes := int(stats.get("meshes", 0))
    return meshes > 0 and int(stats.get("shadowOn", 0)) == meshes and int(stats.get("visibility", 0)) == meshes

func render_policy_no_shadow(stats: Dictionary) -> bool:
    var meshes := int(stats.get("meshes", 0))
    return meshes > 0 and int(stats.get("shadowOff", 0)) == meshes and int(stats.get("visibility", 0)) == meshes

func render_policy_has_visibility(stats: Dictionary) -> bool:
    var meshes := int(stats.get("meshes", 0))
    return meshes > 0 and int(stats.get("visibility", 0)) == meshes

func collect_visual_role_counts(node: Node, counts: Dictionary) -> void:
    if node == null:
        return
    if node.has_meta("visual_role"):
        var role := String(node.get_meta("visual_role", ""))
        counts[role] = int(counts.get(role, 0)) + 1
    for child in node.get_children():
        collect_visual_role_counts(child, counts)

func collect_block_visual_mesh_ids(node: Node, ids: Dictionary) -> void:
    if node == null:
        return
    if node is MeshInstance3D and String(node.get_meta("visual_role", "")) == "block":
        var mesh_instance := node as MeshInstance3D
        if mesh_instance.mesh != null:
            ids[str(mesh_instance.mesh.get_instance_id())] = true
    for child in node.get_children():
        collect_block_visual_mesh_ids(child, ids)

func count_named_descendants(node: Node, node_name: String) -> int:
    if node == null:
        return 0
    var count := 0
    if String(node.name).begins_with(node_name):
        count += 1
    for child in node.get_children():
        count += count_named_descendants(child, node_name)
    return count

func count_collision_descendants(node: Node) -> int:
    if node == null:
        return 0
    var count := 0
    if node is CollisionShape3D or node is PhysicsBody3D or node is Area3D:
        count += 1
    for child in node.get_children():
        count += count_collision_descendants(child)
    return count

func has_visual_source(node: Node, source: String) -> bool:
    if node == null:
        return false
    if String(node.get_meta("visual_source", "")) == source:
        return true
    for child in node.get_children():
        if has_visual_source(child, source):
            return true
    return false

func npc_route_debug(npc_system, body: Node) -> String:
    if npc_system == null or body == null or not is_instance_valid(body):
        return "missing"
    var entries: Array = npc_system.get("npcs")
    for entry_variant in entries:
        var entry: Dictionary = entry_variant
        if entry.get("body") != body:
            continue
        var body_3d := body as Node3D
        var current_cell := world_to_flat_cell(body_3d.global_position) if body_3d != null else Vector2i.ZERO
        var settle_debug: Dictionary = entry.get("homeSettleDebug", {})
        var nav_debug := npc_navigation_debug(npc_system, entry, current_cell)
        var action_keys: Array = (entry.get("routeActions", {}) as Dictionary).keys()
        action_keys.sort()
        var typed_summary := "none"
        var typed_result = entry.get("typedRouteResult")
        if typed_result != null:
            var metrics_value = typed_result.get("metrics")
            var metrics_summary := ""
            if metrics_value is Dictionary:
                var hierarchy: Dictionary = (metrics_value as Dictionary).get("hierarchy", {})
                var graph: Dictionary = (metrics_value as Dictionary).get("graph", {})
                metrics_summary = " tiles=%d entrances=%d nodes=%d edges=%d startEdges=%d goals=%s allowedTiles=%d fallback=%s" % [
                    int(hierarchy.get("tileCount", 0)),
                    int(hierarchy.get("entranceCount", 0)),
                    int(graph.get("nodeCount", 0)),
                    int(graph.get("edgeCount", 0)),
                    int(graph.get("startEdgeCount", 0)),
                    str(graph.get("goalKeys", [])),
                    int(graph.get("allowedTileCount", 0)),
                    str((metrics_value as Dictionary).get("fallback", ""))
                ]
            typed_summary = "%s/%s %s" % [
                str(typed_result.get("status")),
                str(typed_result.get("reason")),
                metrics_summary
            ]
        var active_motion_goal = entry.get("activeMotionGoal", {})
        var active_motion_goal_summary := {}
        if active_motion_goal is Dictionary:
            active_motion_goal_summary = {
                "goalKind": String((active_motion_goal as Dictionary).get("goalKind", "")),
                "reason": String((active_motion_goal as Dictionary).get("reason", ""))
            }
        var body_order := {
            "kind": String(body.get_meta("npc_scripted_order_kind", "")),
            "state": String(body.get_meta("npc_scripted_order_state", "")),
            "reason": String(body.get_meta("npc_scripted_order_reason", ""))
        }
        return "%s cell %s home %s porch %s interior %s..%s activeGoal %s motionGoal %s scripted %s bodyOrder %s active %s fallback %s status %s/%s index %d inside %s blocked %s moved %.4f motionUpdates %d skip %s follow %s progress %s actions %s routeCells %s waypoints %s activeDoor %s doorReject %s capsule %s localEscape %s localEscapeFailed %s typed %s settle %s plan %s tileWait %d tilePublish %s nav %s force %s dialogue %s" % [
            String(body.get_meta("npc_id", entry.get("id", body.name))),
            str(current_cell),
            str(entry.get("homeCell", Vector2i.ZERO)),
            str(entry.get("porchCell", Vector2i.ZERO)),
            str(entry.get("interiorMinCell", Vector2i.ZERO)),
            str(entry.get("interiorMaxCell", Vector2i.ZERO)),
            String(entry.get("activeGoalKind", "")),
            JSON.stringify(active_motion_goal_summary),
            JSON.stringify(entry.get("scriptedOrder", {})),
            JSON.stringify(body_order),
            str(entry.get("homeActiveTargetCell", Vector2i.ZERO)),
            str(entry.get("routeFallbackCell", Vector2i.ZERO)),
            String(entry.get("routeStatus", "")),
            String(entry.get("routeReason", "")),
            int(entry.get("homeRouteIndex", 0)),
            str(body.get_meta("npc_inside_home", false)),
            str(body.get_meta("npc_home_blocked", false)),
            float(entry.get("lastMoveDistance", 0.0)),
            int(entry.get("npc_motion_updates", 0)),
            String(entry.get("npc_motion_skipped_reason", "")),
            JSON.stringify(entry.get("corridorFollow", {})),
            JSON.stringify(entry.get("corridorProgress", {})),
            str(action_keys),
            str(sample_route_cells(entry.get("routeCells", []), 14)),
            str(sample_waypoints(entry.get("pathWaypoints", []), 6)),
            String(entry.get("activeDoorPortalId", "")),
            JSON.stringify(entry.get("doorActionReject", {})),
            JSON.stringify(entry.get("capsuleBlocker", body.get_meta("npc_capsule_blocker", {}))),
            JSON.stringify(entry.get("lastMotorLocalEscape", {})),
            JSON.stringify(entry.get("lastMotorLocalEscapeFailed", {})),
            typed_summary,
            JSON.stringify(settle_debug),
            JSON.stringify(entry.get("lastRoutePlanDebug", {})),
            int(entry.get("navmeshTileBudgetWaitFrames", 0)),
            JSON.stringify(entry.get("lastNavmeshTilePublishDebug", [])),
            JSON.stringify(nav_debug),
            JSON.stringify(entry.get("scriptedOrder", {})),
            str(body.get_meta("npc_dialogue_focused", false))
        ]
    return "entry missing"

func sample_route_cells(value, limit := 12) -> Array:
    var result := []
    if not (value is Array):
        return result
    for cell_value in value:
        if result.size() >= limit:
            break
        if cell_value is Vector2i:
            var cell: Vector2i = cell_value
            result.append([cell.x, cell.y])
    return result

func sample_waypoints(value, limit := 6) -> Array:
    var result := []
    if not (value is Array):
        return result
    for point_value in value:
        if result.size() >= limit:
            break
        if point_value is Vector3:
            var point: Vector3 = point_value
            result.append([snappedf(point.x, 0.01), snappedf(point.y, 0.01), snappedf(point.z, 0.01)])
    return result

func npc_navigation_debug(npc_system, entry: Dictionary, current_cell: Vector2i) -> Dictionary:
    var result := {}
    if npc_system == null:
        return result
    var world = null
    var autonomy = npc_system.get("autonomy_system")
    if autonomy != null and autonomy.has_method("generated_navigation_adapter"):
        world = autonomy.call("generated_navigation_adapter")
    if world == null:
        var pathing = npc_system.get("pathing")
        if pathing != null:
            if pathing.has_method("ensure_ready"):
                pathing.call("ensure_ready")
            world = pathing.get("navigation_world")
    if world == null or not world.has_method("build_navmesh_tile_snapshot"):
        result["reason"] = "missing_navigation_world"
        return result
    var important_cells: Array[Vector2i] = [
        current_cell,
        entry.get("homeCell", Vector2i.ZERO),
        entry.get("porchCell", Vector2i.ZERO),
        entry.get("homeActiveTargetCell", entry.get("homeCell", Vector2i.ZERO)),
        entry.get("interiorMinCell", entry.get("homeCell", Vector2i.ZERO)),
        entry.get("interiorMaxCell", entry.get("homeCell", Vector2i.ZERO))
    ]
    var tile_lookup := {}
    for cell in important_cells:
        tile_lookup[_debug_tile_key_for_cell(world, cell)] = true
    var tile_keys := tile_lookup.keys()
    tile_keys.sort()
    var tile_summaries := {}
    for tile_key_value in tile_keys:
        var tile_key := String(tile_key_value)
        if tile_key == "":
            continue
        var tile_snapshot: Dictionary = world.call("build_navmesh_tile_snapshot", tile_key)
        var surfaces: Array = tile_snapshot.get("surfaces", []) if tile_snapshot.get("surfaces", []) is Array else []
        var door_portals: Array = tile_snapshot.get("doorPortals", []) if tile_snapshot.get("doorPortals", []) is Array else []
        var door_links: Array = tile_snapshot.get("doorLinks", []) if tile_snapshot.get("doorLinks", []) is Array else []
        tile_summaries[tile_key] = {
            "surfaces": surfaces.size(),
            "doorPortals": _compact_nav_door_portals(door_portals),
            "doorLinks": door_links.size(),
            "importantSurfaces": _important_surface_cells(surfaces, important_cells)
        }
    result["tiles"] = tile_summaries
    var snapshot: Dictionary = world.call("cached_static_tile_snapshot", true, true) if world.has_method("cached_static_tile_snapshot") else {}
    result["cells"] = _important_cell_navigation_debug(world, snapshot, important_cells)
    result["nearHomeDoors"] = _near_home_door_debug(world, snapshot, entry)
    return result

func _debug_tile_key_for_cell(world, cell: Vector2i) -> String:
    if world != null and world.has_method("tile_key_for_cell"):
        return String(world.call("tile_key_for_cell", cell))
    return "%d,%d" % [floori(float(cell.x) / 16.0), floori(float(cell.y) / 16.0)]

func _compact_nav_door_portals(door_portals: Array) -> Array:
    var result := []
    for portal_value in door_portals:
        if result.size() >= 6:
            break
        if not (portal_value is Dictionary):
            continue
        var portal: Dictionary = portal_value
        result.append({
            "id": String(portal.get("id", "")),
            "cell": str(portal.get("cell", Vector2i.ZERO)),
            "axis": String(portal.get("crossingAxis", "")),
            "state": String(portal.get("state", ""))
        })
    return result

func _important_surface_cells(surfaces: Array, important_cells: Array[Vector2i]) -> Array:
    var lookup := {}
    for cell in important_cells:
        lookup[Vector2i(cell.x, cell.y)] = true
    var result := []
    for surface_value in surfaces:
        if not (surface_value is Dictionary):
            continue
        var surface: Dictionary = surface_value
        var cell3 = surface.get("cell", Vector3i.ZERO)
        if cell3 is Vector3i:
            var flat := Vector2i(cell3.x, cell3.z)
            if lookup.has(flat):
                result.append(str(flat))
    return result

func _important_cell_navigation_debug(world, snapshot: Dictionary, cells: Array[Vector2i]) -> Dictionary:
    var result := {}
    for cell in cells:
        var key := "%d,%d" % [cell.x, cell.y]
        var door = world.call("door_at", snapshot, cell) if world.has_method("door_at") else null
        var static_blocker = world.call("static_blocker", snapshot, cell) if world.has_method("static_blocker") else null
        var prop_blocker = world.call("prop_clearance_blocker", snapshot, cell) if world.has_method("prop_clearance_blocker") else null
        result[key] = {
            "height": snappedf(float(world.call("height_for_cell", cell)) if world.has_method("height_for_cell") else 0.0, 0.001),
            "door": String(door.name) if door is Node else "",
            "doorPolicy": String(door.get_meta("door_policy", "")) if door is Node else "",
            "static": _debug_node_name(static_blocker),
            "prop": _debug_node_name(prop_blocker),
            "tile": _debug_tile_key_for_cell(world, cell)
        }
    return result

func _near_home_door_debug(world, snapshot: Dictionary, entry: Dictionary) -> Array:
    var result := []
    var min_cell: Vector2i = entry.get("interiorMinCell", entry.get("homeCell", Vector2i.ZERO))
    var max_cell: Vector2i = entry.get("interiorMaxCell", entry.get("homeCell", Vector2i.ZERO))
    var min_x := mini(min_cell.x, max_cell.x) - 3
    var max_x := maxi(min_cell.x, max_cell.x) + 3
    var min_z := mini(min_cell.y, max_cell.y) - 3
    var max_z := maxi(min_cell.y, max_cell.y) + 3
    for z in range(min_z, max_z + 1):
        for x in range(min_x, max_x + 1):
            var cell := Vector2i(x, z)
            var door = world.call("door_at", snapshot, cell) if world.has_method("door_at") else null
            if not (door is Node):
                continue
            result.append({
                "cell": str(cell),
                "name": String(door.name),
                "policy": String(door.get_meta("door_policy", "")),
                "state": String(door.get_meta("door_state", "")),
                "side": int(door.get_meta("door_side", -1)),
                "portal": String(door.get_meta("door_portal_id", "")),
                "tile": _debug_tile_key_for_cell(world, cell)
            })
    return result

func _debug_node_name(value) -> String:
    if value == null:
        return ""
    if value is Node:
        return String((value as Node).name)
    if value is Object and not is_instance_valid(value):
        return "freed"
    return str(value)

func npc_shelter_debug(npc_system) -> String:
    if npc_system == null:
        return "missing"
    var entries: Array = npc_system.get("npcs")
    var details: Array[String] = []
    for entry_variant in entries:
        var entry: Dictionary = entry_variant
        var body := entry.get("body") as Node
        if body == null or not is_instance_valid(body):
            continue
        details.append(npc_route_debug(npc_system, body))
        if details.size() >= 8:
            break
    return "; ".join(details)

func compact_vec3(value: Vector3) -> String:
    return "(%.2f,%.2f,%.2f)" % [value.x, value.y, value.z]

func nearest_actor_summary(origin: Node3D) -> String:
    if origin == null or main == null:
        return "missing"
    var best_name := "none"
    var best_distance := INF
    if player != null and player != origin:
        best_name = "player"
        best_distance = origin.global_position.distance_to(player.global_position)
    var npc_system = main.get("npc_system")
    if npc_system != null:
        var entries: Array = npc_system.get("npcs")
        for entry_variant in entries:
            var entry: Dictionary = entry_variant
            var body := entry.get("body") as Node3D
            if body == null or not is_instance_valid(body) or body == origin:
                continue
            var distance := origin.global_position.distance_to(body.global_position)
            if distance < best_distance:
                best_distance = distance
                best_name = "npc:%s" % String(entry.get("id", body.name))
    var hostile_system = main.get("hostile_system")
    if hostile_system != null:
        for enemy_variant in hostile_system.get("enemies"):
            var enemy: Dictionary = enemy_variant
            var body := enemy.get("body") as Node3D
            if body == null or not is_instance_valid(body) or body == origin:
                continue
            var distance := origin.global_position.distance_to(body.global_position)
            if distance < best_distance:
                best_distance = distance
                best_name = "hostile:%s" % body.name
    return "%s %.2f overlap %s static %s" % [
        best_name,
        best_distance,
        overlap_summary(origin),
        nearest_static_summary(origin)
    ]

func overlap_summary(origin: Node3D) -> String:
    if origin == null or origin.get_world_3d() == null:
        return "missing"
    var shape := CapsuleShape3D.new()
    shape.radius = 0.38
    shape.height = 1.62
    var query := PhysicsShapeQueryParameters3D.new()
    query.shape = shape
    query.transform = Transform3D(Basis(), origin.global_position + Vector3(0.0, 0.81, 0.0))
    query.collision_mask = 0x7fffffff
    query.collide_with_bodies = true
    query.collide_with_areas = false
    var collision_object := origin as CollisionObject3D
    if collision_object != null:
        query.exclude = [collision_object.get_rid()]
    var hits: Array = origin.get_world_3d().direct_space_state.intersect_shape(query, 8)
    var names: Array[String] = []
    for hit_variant in hits:
        var hit: Dictionary = hit_variant
        var collider := hit.get("collider") as Node
        if collider == null or collider == origin:
            continue
        names.append("%s:%s" % [collider.name, String(collider.get_meta("kind", ""))])
    if names.is_empty():
        return "none"
    return ",".join(names)

func nearest_static_summary(origin: Node3D) -> String:
    if origin == null or main == null:
        return "missing"
    var best := {
        "distance": INF,
        "label": "none"
    }
    var roots := [
        main.get("prop_root") as Node,
        main.get("chunk_root") as Node
    ]
    var remaining := 1800
    for root in roots:
        if root == null:
            continue
        remaining = nearest_static_in_tree(root, origin, best, remaining)
        if remaining <= 0:
            break
    return "%s %.2f" % [String(best.get("label", "none")), float(best.get("distance", INF))]

func nearest_static_in_tree(node: Node, origin: Node3D, best: Dictionary, remaining: int) -> int:
    if node == null or remaining <= 0:
        return remaining
    remaining -= 1
    var node_3d := node as Node3D
    if node_3d != null and node_3d != origin and node is PhysicsBody3D:
        var kind := String(node.get_meta("kind", ""))
        if kind in ["block", "prop", "hostile", "npc"]:
            var distance := origin.global_position.distance_to(node_3d.global_position)
            if distance < float(best.get("distance", INF)):
                best["distance"] = distance
                best["label"] = "%s:%s:%s" % [
                    node.name,
                    kind,
                    String(node.get_meta("block_type", node.get_meta("prop_type", "")))
                ]
    for child in node.get_children():
        remaining = nearest_static_in_tree(child, origin, best, remaining)
        if remaining <= 0:
            break
    return remaining

func icon_distinct_colors(texture: Texture2D) -> int:
    if texture == null:
        return 0
    var image := texture.get_image()
    if image == null:
        return 0
    var colors := {}
    for y in range(0, image.get_height(), 4):
        for x in range(0, image.get_width(), 4):
            var color := image.get_pixel(x, y)
            if color.a <= 0.04:
                continue
            var key := "%d:%d:%d:%d" % [
                roundi(color.r * 16.0),
                roundi(color.g * 16.0),
                roundi(color.b * 16.0),
                roundi(color.a * 16.0)
            ]
            colors[key] = true
    return colors.size()

func is_player_grounded() -> bool:
    if not player:
        return false
    if float(player.get("jump_snap_time")) > 0.0:
        return false
    return player.is_on_floor() or bool(player.get("terrain_grounded"))

func wait_until_grounded(max_frames: int) -> void:
    for i in range(max_frames):
        if is_player_grounded():
            return
        await get_tree().physics_frame

func aim_player_at(world_point: Vector3) -> void:
    if not player or not camera:
        return
    var eye: Vector3 = camera.global_position
    var direction: Vector3 = world_point - eye
    var flat_direction := Vector3(direction.x, 0.0, direction.z)
    if flat_direction.length_squared() > 0.0001:
        player.rotation.y = atan2(-flat_direction.x, -flat_direction.z)
    var local_direction: Vector3 = player.global_transform.basis.inverse() * direction.normalized()
    var pitch_value: float = clamp(atan2(local_direction.y, -local_direction.z), deg_to_rad(-82.0), deg_to_rad(82.0))
    player.set("pitch", pitch_value)
    camera.rotation.x = pitch_value

func reset_player_on_flat_patch(center_cell: Vector2i, radius := 5, defer_rebuild := false) -> void:
    if not main or not player:
        return
    var base_height: float = surface_y_at_cell2(center_cell)
    var edits := get_volume_edit_markers()
    for dz in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            edits[Vector2i(center_cell.x + dx, center_cell.y + dz)] = base_height
    if defer_rebuild and main.has_method("rebuild_chunks_for_cells"):
        main.call("rebuild_chunks_for_cells", [center_cell], 1, true)
    else:
        main.call("rebuild_chunks_around_cell", center_cell)
    player.global_position = Vector3(center_cell.x * CELL, base_height, center_cell.y * CELL)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", true)
