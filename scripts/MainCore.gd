extends "res://scripts/MainInterface.gd"

const DEFAULT_VISUAL_STYLE := preload("res://resources/visual/gamecube_style.tres")

var seed_text := "atlas-1492"
var seed_hash := 1
var height_noise: FastNoiseLite
var ridge_noise: FastNoiseLite
var flat_noise: FastNoiseLite
var moisture_noise: FastNoiseLite
var temp_noise: FastNoiseLite

var chunk_root: Node3D
var block_root: Node3D
var prop_root: Node3D
var water: MeshInstance3D
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var sun_visual: MeshInstance3D
var moon_visual: MeshInstance3D
var player: CharacterBody3D
var world_environment: WorldEnvironment
var visual_style: Resource
var sky_resource: Sky
var sky_material: ProceduralSkyMaterial
var visual_capture_active := false
var visual_debug_enabled := false

var terrain_material: Material
var materials := {}
var chunks := {}
var chunk_asset_cache := {}
var chunk_asset_cache_order: Array[Vector2i] = []
var chunk_asset_cache_hits := 0
var chunk_asset_cache_misses := 0
var chunk_asset_cache_invalidations := 0
var volume_edit_markers := {}
var town_region_cache := {}
var town_slope_apron_cache := {}
var blocks := {}
var removed_props := {}
var inventory := {}
var inventory_system
var crafting_system
var objective_system
var world_generation_system
var structure_system
var subsurface_system
var utility_system
var save_system
var survival_system
var hostile_system
var progression_system
var equipment_system
var contract_system
var audio_effects
var player_projectiles
var weather_system
var tutorial_system
var npc_system
var story_event_bus
var story_director
var story_quest_system
var region_story_generator
var story_site_placement
var story_world_overlay_system
var worldmark_influence_system
var story_journal_model
var story_dialogue_router
var worldmark_encounter_controller
var settlement_state_system
var region_aftermath_system
var story_accessibility_settings
var story_debug_tools
var item_visual_factory
var visual_asset_registry
var static_item_asset_registry
var animated_asset_registry
var hud
var held_item
var break_overlay: MeshInstance3D
var break_material: StandardMaterial3D
var break_target_id := ""
var break_progress := 0.0
var break_idle_time := 0.0
var last_center_chunk := Vector2i(999999, 999999)
var world_elapsed := 0.0
var time_of_day := 0.32
var next_fishing_ready_at := 0.0
var fishing_rng := RandomNumberGenerator.new()
var test_seed_sequence := 0
var runtime_perf_monitor = RuntimePerformanceMonitorScript.new()
var autosave_elapsed := 0.0
var autosave_interval_seconds := 60.0
var autosave_enabled := true
var autosave_dirty := false
var autosave_dirty_reasons := {}
var autosave_jobs_started := 0
var autosave_jobs_completed := 0
var autosave_jobs_failed := 0
var autosave_last_player_position := Vector3.INF
var autosave_last_player_rotation_y := INF
var autosave_last_time_bucket := -1
var discovered_biomes := {}
var discovered_town_keys := {}
var discovered_shrine_keys := {}
var discovered_mine_keys := {}
var discovered_ruin_keys := {}
var discovered_camp_keys := {}
var last_story_region_id := ""
var last_survival_health := 100.0
var shelter_sample_elapsed := 0.0
var cached_shelter_comfort := 0.0
var cached_shelter_label := "Exposed"
var beacon_charge := 0.0
var beacon_raid_stage := 0
var sanctuary_established := false
var beacon_status_message := ""
var death_count := 0
var respawn_point = null
var sleep_transition_active := false
var sleep_transition_elapsed := 0.0
var sleep_transition_applied := false
var sleep_transition_rest_quality := 0.0
var sleep_transition_message := ""
var dropped_pickups: Array = []
var pickup_pool := {}
var pickup_nodes_created := 0
var pickup_nodes_reused := 0
var pickup_nodes_discarded := 0
var wildlife_nodes: Array = []
var map_sample_cache_key := ""
var map_sample_cache: Array = []
var navigation_map_state_cache_key := ""
var navigation_map_state_cache := {}
var navigation_map_state_cache_elapsed := 999.0
var navigation_map_state_cache_interval := 0.75
var visual_quality := {
    "decorativeDensity": 0.74,
    "decorativeDetailCap": 72,
    "shadowQuality": 1.0,
    "textureScale": 1.0
}
var runtime_settings := {
    "mouseSensitivity": 1.0,
    "invertY": false,
    "fov": 72.0,
    "renderDistance": 3,
    "shadows": true,
    "weatherParticles": 1.0,
    "hudScale": 1.0,
    "fullscreen": false,
    "lookSmoothing": 0.0,
    "headBob": true,
    "handSway": true,
    "storyTextSpeed": 2.0,
    "storySubtitles": true,
    "storyJournalFontScale": 1.0,
    "storyColorIndependentClues": true,
    "storyReplayDiscoveredText": true,
    "storyControllerNavigation": true
}
var render_distance := RENDER_DISTANCE
var shadows_enabled := true
var performance_visible := false
var perf_elapsed := 0.0
var perf_frame_ms := 0.0
var perf_chunk_ms := 0.0
var perf_sky_ms := 0.0
var perf_utility_ms := 0.0
var perf_pickups_ms := 0.0
var perf_survival_ms := 0.0
var perf_hostiles_ms := 0.0
var perf_beacon_ms := 0.0
var perf_autosave_ms := 0.0
var perf_npc_ms := 0.0
var perf_route_plan_ms := 0.0
var perf_nav_snapshot_ms := 0.0
var perf_job_scan_ms := 0.0
var perf_break_ms := 0.0
var perf_hud_ms := 0.0
var local_light_lod_elapsed := 0.0
var hud_refresh_interval := 0.16
var hud_refresh_elapsed := 0.16
var hud_refresh_count := 0
var hud_throttled_refresh_count := 0
var hud_manual_refresh_count := 0
var hud_message_refresh_count := 0
var hud_skipped_refresh_count := 0
var last_hud_refresh_message := ""
var detail_meshes := {}
var block_meshes := {}

func _ready() -> void:
    playtest_progress("main_ready_start")
    var cave_visual_fast_boot := OS.get_environment("VOXEL_CAVE_VISUAL_FAST_BOOT").strip_edges() == "1"
    setup_save_system()
    var active_seed := ""
    if autosave_enabled and save_system and save_system.has_method("active_seed"):
        active_seed = save_system.active_seed("")
    var forced_test_seed := test_seed_text()
    if forced_test_seed != "":
        seed_text = forced_test_seed
    elif active_seed != "":
        seed_text = active_seed
    apply_world_seed(seed_text, false)
    playtest_progress("main_noise_done")
    setup_materials()
    setup_environment()
    setup_game_systems()
    playtest_progress("main_systems_done")

    chunk_root = Node3D.new()
    chunk_root.name = "Chunks"
    add_child(chunk_root)
    prop_root = Node3D.new()
    prop_root.name = "Props"
    add_child(prop_root)
    block_root = Node3D.new()
    block_root.name = "Blocks"
    add_child(block_root)
    setup_audio_effects()
    setup_break_overlay()
    setup_tutorial_system()

    setup_player()
    setup_hostiles()
    setup_npc_system()
    setup_player_projectiles()
    setup_held_item()
    setup_hud()
    playtest_progress("main_scene_nodes_done")
    var loaded := try_load_world()
    var started_intro_tutorial := false
    playtest_progress("main_load_done")
    if not loaded and tutorial_system and not cave_visual_fast_boot:
        if autosave_enabled:
            apply_world_seed(random_world_seed(seed_text), true)
        started_intro_tutorial = tutorial_system.start_new_world()
        playtest_progress("main_tutorial_start_done")
    if not cave_visual_fast_boot:
        update_chunks(true)
        playtest_progress("main_initial_chunks_done")
    var interactive_cave_message := "" if cave_visual_fast_boot else apply_interactive_cave_launch_if_requested()
    if not cave_visual_fast_boot:
        refresh_intro_knock_audio()
    var ready_message := "Loaded saved world" if loaded else "Godot slice ready"
    if not loaded and tutorial_system and tutorial_system.last_message != "":
        ready_message = tutorial_system.last_message
    if interactive_cave_message != "":
        ready_message = interactive_cave_message
    if not cave_visual_fast_boot:
        update_hud(ready_message)
    reset_autosave_dirty_tracking(not loaded and not cave_visual_fast_boot, "new_world")

func playtest_progress(label: String) -> void:
    var path: String = OS.get_environment("VOXEL_PLAYTEST_PROGRESS")
    if path == "":
        return
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\n" % label)
    file.close()

func setup_save_system() -> void:
    autosave_enabled = OS.get_environment("VOXEL_PLAYTEST") == ""
    var save_path := "user://voxel_biome_world_saves.json" if autosave_enabled else "user://voxel_biome_world_playtest_saves.json"
    save_system = SaveSystemScript.new(save_path)
    autosave_interval_seconds = 60.0

func mark_world_dirty(reason := "world") -> void:
    autosave_dirty = true
    autosave_dirty_reasons[String(reason)] = true

func reset_autosave_dirty_tracking(mark_dirty := false, reason := "reset") -> void:
    autosave_dirty = mark_dirty
    autosave_dirty_reasons.clear()
    if mark_dirty:
        autosave_dirty_reasons[String(reason)] = true
    if player:
        autosave_last_player_position = player.global_position
        autosave_last_player_rotation_y = player.rotation.y
    else:
        autosave_last_player_position = Vector3.INF
        autosave_last_player_rotation_y = INF
    autosave_last_time_bucket = floori(time_of_day * 48.0)

func update_autosave_dirty_state() -> void:
    if player:
        if not is_finite(autosave_last_player_position.x):
            autosave_last_player_position = player.global_position
            autosave_last_player_rotation_y = player.rotation.y
        elif autosave_last_player_position.distance_squared_to(player.global_position) >= 0.20 * 0.20:
            autosave_last_player_position = player.global_position
            mark_world_dirty("player_position")
        if not is_finite(autosave_last_player_rotation_y) or absf(wrapf(player.rotation.y - autosave_last_player_rotation_y, -PI, PI)) >= 0.04:
            autosave_last_player_rotation_y = player.rotation.y
            mark_world_dirty("player_rotation")
    var time_bucket := floori(time_of_day * 48.0)
    if autosave_last_time_bucket != time_bucket:
        autosave_last_time_bucket = time_bucket
        mark_world_dirty("world_time")

func process_autosave(delta: float) -> void:
    var section_start: int = runtime_perf_monitor.begin_section("autosave") if runtime_perf_monitor != null else Time.get_ticks_usec()
    if save_system != null and save_system.has_method("poll_async_save"):
        var async_result: Dictionary = save_system.poll_async_save()
        if not async_result.is_empty():
            autosave_jobs_completed += 1
            if not bool(async_result.get("ok", false)):
                autosave_jobs_failed += 1
                mark_world_dirty("autosave_retry")
            if runtime_perf_monitor != null:
                runtime_perf_monitor.observe_external_duration("autosave_json_stringify_write", float(async_result.get("stringifyWriteMs", 0.0)))
    if not autosave_enabled or save_system == null:
        perf_autosave_ms = runtime_perf_monitor.end_section("autosave", section_start) if runtime_perf_monitor != null else float(Time.get_ticks_usec() - section_start) / 1000.0
        return
    update_autosave_dirty_state()
    autosave_elapsed += delta
    if autosave_elapsed >= autosave_interval_seconds:
        autosave_elapsed = 0.0
        if autosave_dirty:
            var pending := bool(save_system.call("has_async_save_pending")) if save_system.has_method("has_async_save_pending") else false
            if pending:
                mark_world_dirty("autosave_pending")
                if runtime_perf_monitor != null:
                    runtime_perf_monitor.increment_counter("autosave_pending")
            else:
                var snapshot_start: int = runtime_perf_monitor.begin_section("autosave_snapshot") if runtime_perf_monitor != null else Time.get_ticks_usec()
                var snapshot: Dictionary = create_save_snapshot()
                if runtime_perf_monitor != null:
                    runtime_perf_monitor.end_section("autosave_snapshot", snapshot_start)
                var started := false
                if save_system.has_method("save_async"):
                    started = bool(save_system.save_async(seed_text, snapshot))
                else:
                    started = bool(save_system.save(seed_text, snapshot))
                if started:
                    autosave_jobs_started += 1
                    reset_autosave_dirty_tracking(false)
                    if runtime_perf_monitor != null:
                        runtime_perf_monitor.increment_counter("autosave_jobs_started")
                else:
                    mark_world_dirty("autosave_start_failed")
                    if runtime_perf_monitor != null:
                        runtime_perf_monitor.increment_counter("autosave_start_failed")
    perf_autosave_ms = runtime_perf_monitor.end_section("autosave", section_start) if runtime_perf_monitor != null else float(Time.get_ticks_usec() - section_start) / 1000.0

func apply_world_seed(new_seed: String, remember := false) -> void:
    seed_text = new_seed.strip_edges()
    if seed_text == "":
        seed_text = random_world_seed()
    seed_hash = hash_string(seed_text)
    if test_seed_text() != "":
        seed(seed_hash)
    town_region_cache.clear()
    town_slope_apron_cache.clear()
    fishing_rng.seed = hash_string("%s:fishing" % seed_text)
    setup_noise()
    setup_world_generation_system()
    if world_generation_system and world_generation_system.has_method("reset_for_seed"):
        world_generation_system.reset_for_seed()
    if weather_system and weather_system.has_method("reset_for_seed"):
        weather_system.reset_for_seed(seed_hash)
    if region_story_generator and region_story_generator.has_method("setup"):
        region_story_generator.setup(seed_text, seed_hash, TOWN_REGION_CELLS)
    if story_director and story_director.has_method("reset"):
        story_director.reset()
    if story_world_overlay_system and story_world_overlay_system.has_method("reset"):
        story_world_overlay_system.reset()
    if worldmark_influence_system and worldmark_influence_system.has_method("reset"):
        worldmark_influence_system.reset()
    if worldmark_encounter_controller and worldmark_encounter_controller.has_method("reset"):
        worldmark_encounter_controller.reset()
    if settlement_state_system and settlement_state_system.has_method("reset"):
        settlement_state_system.reset()
    if region_aftermath_system and region_aftermath_system.has_method("reset"):
        region_aftermath_system.reset()
    last_story_region_id = ""
    if save_system and remember and save_system.has_method("set_active_seed"):
        save_system.set_active_seed(seed_text)

func random_world_seed(exclude_seed := "") -> String:
    var forced_test_seed := test_seed_text()
    if forced_test_seed != "" and OS.get_environment("VOXEL_PLAYTEST") != "":
        for attempt in range(8):
            var candidate_index: int = test_seed_sequence + attempt
            var stable_value: int = absi(hash_string("%s:test-world:%d" % [forced_test_seed, candidate_index]))
            var generated_test: String = "atlas-%08d" % ((stable_value % 90000000) + 10000000)
            if generated_test != exclude_seed:
                test_seed_sequence = candidate_index + 1
                return generated_test
    var rng := RandomNumberGenerator.new()
    rng.randomize()
    var generated := ""
    for attempt in range(8):
        generated = "atlas-%08d" % rng.randi_range(10000000, 99999999)
        if generated != exclude_seed:
            return generated
    var stamp := int(Time.get_unix_time_from_system())
    return "atlas-%08d" % ((stamp % 90000000) + 10000000)

func test_seed_text() -> String:
    return OS.get_environment("VOXEL_TEST_SEED").strip_edges()

func apply_interactive_cave_launch_if_requested() -> String:
    if OS.get_environment("VOXEL_CAVE_INTERACTIVE").strip_edges() != "1":
        return ""
    if player == null or world_generation_system == null:
        return "Interactive cave launch failed: player or world generation missing"
    neutralize_interactive_cave_tutorial()
    var radius_text := OS.get_environment("VOXEL_CAVE_INTERACTIVE_SEARCH_RADIUS").strip_edges()
    var search_radius := clampi(int(radius_text) if radius_text != "" else 12, 1, 32)
    if not world_generation_system.has_method("find_cave_biome_sample"):
        return "Interactive cave launch failed: cave biome sampler missing"
    var cave_record: Dictionary = world_generation_system.call("find_cave_biome_sample", search_radius)
    var cave_feature: Dictionary = cave_record.get("feature", {}) if cave_record.has("feature") else {}
    if cave_feature.is_empty():
        return "Interactive cave launch failed: no cave biome found within %d regions" % search_radius
    var spawn_cell := interactive_cave_spawn_cell(cave_feature)
    var spawn_position := interactive_cave_spawn_position(cave_feature, spawn_cell)
    player.global_position = spawn_position
    player.velocity = Vector3.ZERO
    aim_player_at_interactive_cave(cave_feature)
    configure_interactive_cave_inventory()
    if OS.get_environment("VOXEL_CAVE_INTERACTIVE_GOD_MODE").strip_edges() == "1" and survival_system != null and survival_system.has_method("set_test_god_mode"):
        survival_system.call("set_test_god_mode", true, "interactive_cave_playtest")
    rebuild_chunks_around_cell(spawn_cell)
    rebuild_chunks_around_cell(cave_feature.get("entranceCell", spawn_cell))
    rebuild_chunks_around_cell(interactive_cave_chamber_cell(cave_feature))
    last_center_chunk = Vector2i(999999, 999999)
    update_chunks(true)
    if hud != null:
        if hud.has_method("hide_dialogue"):
            hud.hide_dialogue(false)
        hud.set_inventory_open(false)
        hud.set_teleport_open(false)
        hud.set_settings_open(false)
        hud.set_playtest_open(false)
        hud.set_game_menu_open(false)
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    write_interactive_cave_launch_info(cave_feature, spawn_position)
    return "Interactive cave biome ready: %s" % String(cave_feature.get("id", "cave"))

func neutralize_interactive_cave_tutorial() -> void:
    if tutorial_system == null:
        return
    tutorial_system.set("intro_repair_active", false)
    tutorial_system.set("intro_repair_complete", true)
    tutorial_system.set("intro_bed_used", true)
    tutorial_system.set("intro_elder_dialogue_acknowledged", true)
    tutorial_system.set("final_night_active", false)
    tutorial_system.set("final_night_complete", true)
    if tutorial_system.has_method("clear_dialogue_focus"):
        tutorial_system.call("clear_dialogue_focus")
    tutorial_system.set("last_dialogue", {})
    var weather = weather_system
    if weather != null and weather.has_method("force_weather"):
        weather.force_weather("clear", 0.0, 0.16, Vector3.ZERO)
    time_of_day = fposmod((13.0 / 24.0) - 0.25, 1.0)
    if has_method("update_sky"):
        call("update_sky", 0.0)

func interactive_cave_spawn_cell(plan: Dictionary) -> Vector2i:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var approach_cells = plan.get("approachCells", [])
    if not (approach_cells is Array) or (approach_cells as Array).is_empty():
        return entrance - inward * 5
    var best_cell := entrance - inward * 5
    var best_depth := INF
    var best_lateral := INF
    var right: Vector2i = plan.get("right", Vector2i(-inward.y, inward.x))
    for cell_value in approach_cells:
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        var delta := cell - entrance
        var depth := float(delta.x * inward.x + delta.y * inward.y)
        var lateral := absf(float(delta.x * right.x + delta.y * right.y))
        if depth < best_depth or (is_equal_approx(depth, best_depth) and lateral < best_lateral):
            best_cell = cell
            best_depth = depth
            best_lateral = lateral
    return best_cell

func interactive_cave_spawn_position(plan: Dictionary, spawn_cell: Vector2i) -> Vector3:
    var x := float(spawn_cell.x) * CELL
    var z := float(spawn_cell.y) * CELL
    var y := surface_y_at_position(Vector3(x, 0.0, z)) + 1.15
    return Vector3(x, y, z)

func interactive_cave_chamber_cell(feature: Dictionary) -> Vector2i:
    var entrance: Vector2i = feature.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = feature.get("inward", Vector2i(0, 1))
    var length_cells := roundi(float(feature.get("length", CELL * 24.0)) / CELL)
    return entrance + inward * length_cells

func aim_player_at_interactive_cave(plan: Dictionary) -> void:
    if player == null:
        return
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var target := Vector3(float(entrance.x) * CELL, player.global_position.y, float(entrance.y) * CELL)
    if target.distance_to(player.global_position) > 0.05:
        player.look_at(target, Vector3.UP)
    player.set("pitch", 0.0)
    var camera := player.get("camera") as Camera3D
    if camera != null:
        camera.rotation.x = 0.0
        camera.make_current()

func configure_interactive_cave_inventory() -> void:
    if inventory_system == null:
        return
    inventory_system.clear()
    inventory_system.add_item("torch", 16)
    inventory_system.add_item("stonePickaxe", 1)
    inventory_system.add_item("fieldRation", 4)
    inventory_system.add_item("stoneSword", 1)
    inventory_system.select(0)

func write_interactive_cave_launch_info(plan: Dictionary, spawn_position: Vector3) -> void:
    var path := OS.get_environment("VOXEL_CAVE_INTERACTIVE_LAUNCH_INFO").strip_edges()
    if path == "":
        return
    var dir := path.get_base_dir()
    if dir != "":
        DirAccess.make_dir_recursive_absolute(dir)
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return
    var report := {
        "seed": seed_text,
        "caveId": String(plan.get("id", "")),
        "kind": "cave-biome",
        "region": vec2i_dictionary(plan.get("region", Vector2i.ZERO)),
        "entranceCell": vec2i_dictionary(plan.get("entranceCell", Vector2i.ZERO)),
        "finalChamberCell": vec2i_dictionary(interactive_cave_chamber_cell(plan)),
        "spawnPosition": vec3_dictionary(spawn_position),
        "godMode": OS.get_environment("VOXEL_CAVE_INTERACTIVE_GOD_MODE").strip_edges() == "1"
    }
    file.store_string(JSON.stringify(report, "  "))
    file.close()

func vec2i_dictionary(value: Vector2i) -> Dictionary:
    return { "x": value.x, "z": value.y }

func vec3_dictionary(value: Vector3) -> Dictionary:
    return {
        "x": snappedf(value.x, 0.001),
        "y": snappedf(value.y, 0.001),
        "z": snappedf(value.z, 0.001)
    }

func setup_game_systems() -> void:
    setup_visual_asset_registry()
    setup_static_item_asset_registry()
    setup_animated_asset_registry()
    item_visual_factory = ItemVisualFactoryScript.new()
    item_visual_factory.set_static_asset_registry(static_item_asset_registry)
    inventory_system = InventorySystemScript.new(
        ItemCatalogScript.ITEMS,
        ItemCatalogScript.INVENTORY_SIZE,
        ItemCatalogScript.MAX_INVENTORY_SIZE,
        ItemCatalogScript.HOTBAR_SIZE
    )
    crafting_system = CraftingSystemScript.new(
        ItemCatalogScript.crafting_recipes(),
        ItemCatalogScript.ITEMS,
        inventory_system,
        Callable(self, "is_station_near")
    )
    objective_system = ObjectiveSystemScript.new()
    setup_world_generation_system()
    subsurface_system = SubsurfaceSystemScript.new()
    subsurface_system.setup(self)
    structure_system = StructureSystemScript.new()
    structure_system.setup(self)
    utility_system = UtilityBlockSystemScript.new()
    utility_system.setup(inventory_system)
    equipment_system = EquipmentSystemScript.new(ItemCatalogScript.ITEMS, inventory_system)
    contract_system = ContractSystemScript.new(ItemCatalogScript.ITEMS)
    survival_system = SurvivalSystemScript.new()
    survival_system.setup(ItemCatalogScript.ITEMS, Callable(inventory_system, "consume_active"))
    survival_system.set_damage_multiplier_provider(Callable(equipment_system, "damage_multiplier"))
    progression_system = ProgressionSystemScript.new()
    if save_system == null:
        setup_save_system()
    setup_story_systems()
    inventory_system.changed.connect(_sync_inventory_totals)
    crafting_system.crafted.connect(_on_recipe_crafted)
    objective_system.completed.connect(_on_objective_completed)
    utility_system.changed.connect(_on_utility_changed)
    utility_system.processed.connect(_on_utility_processed)
    utility_system.traded.connect(_on_utility_traded)
    equipment_system.changed.connect(_on_equipment_changed)
    contract_system.changed.connect(_on_contracts_changed)
    contract_system.rewarded.connect(_on_contract_rewarded)
    survival_system.changed.connect(_on_survival_changed)
    progression_system.changed.connect(_on_progression_changed)
    apply_progression_bonuses(progression_system.state())
    last_survival_health = survival_system.health
    grant_starter_inventory()
    _sync_inventory_totals()

func setup_world_generation_system() -> void:
    if world_generation_system == null:
        world_generation_system = WorldGenerationSystemScript.new()
    world_generation_system.setup(self)

func setup_story_systems() -> void:
    if region_story_generator == null:
        region_story_generator = RegionStoryGeneratorScript.new()
        region_story_generator.name = "RegionStoryGenerator"
        add_child(region_story_generator)
    region_story_generator.setup(seed_text, seed_hash, TOWN_REGION_CELLS)
    if story_event_bus == null:
        story_event_bus = StoryEventBusScript.new()
        story_event_bus.name = "StoryEventBus"
        add_child(story_event_bus)
    story_event_bus.setup(self)
    if story_quest_system == null:
        story_quest_system = StoryQuestSystemScript.new()
        story_quest_system.name = "StoryQuestSystem"
        add_child(story_quest_system)
    story_quest_system.setup(self)
    if story_site_placement == null:
        story_site_placement = StorySitePlacementScript.new()
        story_site_placement.name = "StorySitePlacement"
        add_child(story_site_placement)
    story_site_placement.setup(self, region_story_generator)
    if story_director == null:
        story_director = StoryDirectorScript.new()
        story_director.name = "StoryDirector"
        add_child(story_director)
    story_director.setup(self, story_event_bus, region_story_generator, story_quest_system)
    if worldmark_encounter_controller == null:
        worldmark_encounter_controller = WorldmarkEncounterControllerScript.new()
        worldmark_encounter_controller.name = "WorldmarkEncounterController"
        add_child(worldmark_encounter_controller)
    worldmark_encounter_controller.setup(self, story_director)
    if settlement_state_system == null:
        settlement_state_system = SettlementStateSystemScript.new()
        settlement_state_system.name = "SettlementStateSystem"
        add_child(settlement_state_system)
    settlement_state_system.setup(self, story_director)
    if region_aftermath_system == null:
        region_aftermath_system = RegionAftermathSystemScript.new()
        region_aftermath_system.name = "RegionAftermathSystem"
        add_child(region_aftermath_system)
    region_aftermath_system.setup(self, story_director, settlement_state_system)
    if story_world_overlay_system == null:
        story_world_overlay_system = StoryWorldOverlaySystemScript.new()
        story_world_overlay_system.name = "StoryWorldOverlaySystem"
        add_child(story_world_overlay_system)
    story_world_overlay_system.setup(self, story_director, story_site_placement)
    if worldmark_influence_system == null:
        worldmark_influence_system = WorldmarkInfluenceSystemScript.new()
        worldmark_influence_system.name = "WorldmarkInfluenceSystem"
        add_child(worldmark_influence_system)
    worldmark_influence_system.setup(self, story_director)
    if story_journal_model == null:
        story_journal_model = StoryJournalModelScript.new()
        story_journal_model.name = "StoryJournalModel"
        add_child(story_journal_model)
    story_journal_model.setup(self, story_director)
    if story_dialogue_router == null:
        story_dialogue_router = StoryDialogueRouterScript.new()
        story_dialogue_router.name = "StoryDialogueRouter"
        add_child(story_dialogue_router)
    story_dialogue_router.setup(self, story_director)
    if story_accessibility_settings == null:
        story_accessibility_settings = StoryAccessibilitySettingsScript.new()
        story_accessibility_settings.name = "StoryAccessibilitySettings"
        add_child(story_accessibility_settings)
    story_accessibility_settings.setup(self)
    story_accessibility_settings.apply_runtime_settings(runtime_settings)
    if story_debug_tools == null:
        story_debug_tools = StoryDebugToolsScript.new()
        story_debug_tools.name = "StoryDebugTools"
        add_child(story_debug_tools)
    story_debug_tools.setup(self, story_director)

func story_region_id_for_cell(cell: Vector2i) -> String:
    if story_director != null and story_director.has_method("region_id_for_cell"):
        return String(story_director.region_id_for_cell(cell))
    var region_x := floori(float(cell.x) / float(TOWN_REGION_CELLS))
    var region_z := floori(float(cell.y) / float(TOWN_REGION_CELLS))
    return "r:%d,%d" % [region_x, region_z]

func story_region_id_for_world_position(position: Vector3) -> String:
    if not is_finite(position.x) or not is_finite(position.z):
        return ""
    return story_region_id_for_cell(Vector2i(world_to_cell(position.x), world_to_cell(position.z)))

func emit_story_event(event_type: String, subject_id := "", region_id := "", dedupe_key := "", position := Vector3.INF, payload := {}) -> bool:
    if story_event_bus == null:
        return false
    var final_region_id := region_id
    if final_region_id == "":
        final_region_id = story_region_id_for_world_position(position)
    var event: Dictionary = story_event_bus.emit_event(event_type, subject_id, final_region_id, dedupe_key, position, payload)
    return not event.is_empty()

func maybe_emit_story_countermeasure_prepared(item_id: String, source := "item_acquired") -> bool:
    if not (item_id in ["surveyLens", "wardLantern"]):
        return false
    if story_director == null or inventory_system == null or story_director.quest_system == null:
        return false
    if not story_director.quest_system.has_method("first_quest"):
        return false
    var quest: Dictionary = story_director.quest_system.first_quest()
    if quest.is_empty():
        return false
    var stage := String(quest.get("stage", ""))
    if not (stage in ["optional_find_historical_clue", "prepare_countermeasure_placeholder"]):
        return false
    var facts: Dictionary = quest.get("facts", {}) if quest.get("facts", {}) is Dictionary else {}
    if bool(facts.get("countermeasurePrepared", false)):
        return false
    if inventory_system.count("surveyLens") <= 0 or inventory_system.count("wardLantern") <= 0:
        return false
    var region_id := String(quest.get("affectedRegionId", ""))
    if region_id == "":
        return false
    return emit_story_event(
        "story_countermeasure_prepared",
        "countermeasure:gloam_hart",
        region_id,
        "story_countermeasure_prepared:%s" % region_id,
        Vector3.INF,
        {
            "source": source,
            "triggerItem": item_id,
            "items": ["surveyLens", "wardLantern"]
        }
    )

func update_story_region_entry(cell: Vector2i, position: Vector3, biome: String) -> void:
    if story_event_bus == null:
        return
    var region_id := story_region_id_for_cell(cell)
    if region_id == "" or region_id == last_story_region_id:
        return
    last_story_region_id = region_id
    emit_story_event("story_region_entered", "region:%s" % region_id, region_id, "", position, {
        "cell": [cell.x, cell.y],
        "biome": biome
    })
    if story_world_overlay_system and story_world_overlay_system.has_method("sync_for_region"):
        story_world_overlay_system.sync_for_region(region_id)
    if worldmark_influence_system and worldmark_influence_system.has_method("sync_for_region"):
        worldmark_influence_system.sync_for_region(region_id)

func interact_story_node(node: Node) -> bool:
    if story_world_overlay_system == null or not story_world_overlay_system.has_method("interact_with_node"):
        return false
    return bool(story_world_overlay_system.interact_with_node(node))

func start_story_encounter_from_site(site: Dictionary, position: Vector3) -> bool:
    if worldmark_encounter_controller == null or not worldmark_encounter_controller.has_method("start_encounter_from_site"):
        return false
    return bool(worldmark_encounter_controller.start_encounter_from_site(site, position))

func damage_story_worldmark(amount: float, source := "player") -> bool:
    if worldmark_encounter_controller == null or not worldmark_encounter_controller.has_method("damage_active_encounter"):
        return false
    return bool(worldmark_encounter_controller.damage_active_encounter(amount, source))

func try_release_story_worldmark() -> bool:
    if worldmark_encounter_controller == null or not worldmark_encounter_controller.has_method("try_release_active_encounter"):
        return false
    return bool(worldmark_encounter_controller.try_release_active_encounter())

func story_release_input_state() -> Dictionary:
    if story_director == null or worldmark_encounter_controller == null:
        return { "active": false, "ready": false }
    var active_encounter = worldmark_encounter_controller.get("active_encounter")
    if active_encounter == null or not is_instance_valid(active_encounter):
        return { "active": false, "ready": false }
    var status := String(active_encounter.get("status"))
    var phase := int(active_encounter.get("phase"))
    var region_id := String(worldmark_encounter_controller.get("active_region_id"))
    var quest: Dictionary = {}
    if story_director.get("quest_system") != null and story_director.get("quest_system").has_method("first_quest"):
        quest = story_director.get("quest_system").first_quest()
    var facts_value = quest.get("facts", {})
    var facts: Dictionary = facts_value if facts_value is Dictionary else {}
    var boundary_complete := int(facts.get("boundaryStonesRetuned", 0)) >= 2
    var countermeasure_complete := bool(facts.get("countermeasurePrepared", false))
    var history_found := bool(facts.get("historyClueFound", false))
    var release_route_available := bool(facts.get("releaseRouteAvailable", false))
    var unresolved := true
    if region_id != "" and worldmark_encounter_controller.has_method("worldmark_resolution"):
        unresolved = String(worldmark_encounter_controller.worldmark_resolution(region_id)) == ""
    var valid_release_phase := phase >= 3
    return {
        "active": status == "active",
        "phase": phase,
        "validReleasePhase": valid_release_phase,
        "historyClueFound": history_found,
        "boundaryComplete": boundary_complete,
        "countermeasurePrepared": countermeasure_complete,
        "releaseRouteAvailable": release_route_available,
        "unresolved": unresolved,
        "ready": status == "active"
            and valid_release_phase
            and history_found
            and boundary_complete
            and countermeasure_complete
            and release_route_available
            and unresolved
    }

func story_release_input_prompt() -> String:
    var state := story_release_input_state()
    if bool(state.get("ready", false)):
        return "[R] Release rite ready"
    return ""

func try_story_release_input() -> bool:
    var state := story_release_input_state()
    if not bool(state.get("active", false)):
        return false
    if not bool(state.get("validReleasePhase", false)):
        update_hud("The release rite is not ready")
        return true
    if not bool(state.get("historyClueFound", false)):
        update_hud("You do not know the old rite.")
        return true
    if not bool(state.get("ready", false)):
        update_hud("The release rite is not ready")
        return true
    var released := try_release_story_worldmark()
    var message := "Gloam Hart released" if released else "The release rite is not ready"
    if worldmark_encounter_controller != null:
        var controller_message := String(worldmark_encounter_controller.get("last_message"))
        if controller_message != "":
            message = controller_message
    update_hud(message)
    return true

func run_story_debug_command(command: String, args := {}) -> Dictionary:
    if story_debug_tools == null or not story_debug_tools.has_method("run_command"):
        return { "ok": false, "command": command, "message": "Story debug tools unavailable" }
    return story_debug_tools.run_command(command, args)

func interact_story_dialogue_node(node: Node) -> bool:
    if story_dialogue_router == null or not story_dialogue_router.has_method("interact_with_node"):
        return false
    var response: Dictionary = story_dialogue_router.interact_with_node(node)
    if response.is_empty() or not bool(response.get("handled", false)):
        return false
    if hud and hud.has_method("show_dialogue"):
        hud.show_dialogue(
            String(response.get("speaker", "Resident")),
            String(response.get("role", "")),
            String(response.get("text", "")),
            response
        )
    if npc_system and node is Node3D and player:
        npc_system.focus_dialogue_npc(node, player.global_position)
    return true

func debug_story_dump() -> Dictionary:
    var dump: Dictionary = story_director.debug_story_dump() if story_director != null and story_director.has_method("debug_story_dump") else {
        "currentStoryRegionId": "",
        "quest": {},
        "recentEvents": []
    }
    dump["overlay"] = story_world_overlay_system.debug_state() if story_world_overlay_system != null and story_world_overlay_system.has_method("debug_state") else {}
    dump["influence"] = worldmark_influence_system.debug_state() if worldmark_influence_system != null and worldmark_influence_system.has_method("debug_state") else {}
    dump["journal"] = story_journal_model.state() if story_journal_model != null and story_journal_model.has_method("state") else {}
    dump["encounter"] = worldmark_encounter_controller.debug_state() if worldmark_encounter_controller != null and worldmark_encounter_controller.has_method("debug_state") else {}
    dump["settlement"] = settlement_state_system.debug_state() if settlement_state_system != null and settlement_state_system.has_method("debug_state") else {}
    dump["aftermath"] = region_aftermath_system.debug_state() if region_aftermath_system != null and region_aftermath_system.has_method("debug_state") else {}
    dump["accessibility"] = story_accessibility_settings.state() if story_accessibility_settings != null and story_accessibility_settings.has_method("state") else {}
    dump["debugTools"] = story_debug_tools.debug_state() if story_debug_tools != null and story_debug_tools.has_method("debug_state") else {}
    return dump

func setup_visual_asset_registry() -> void:
    visual_asset_registry = VisualAssetRegistryScript.new()
    if not visual_asset_registry.setup():
        push_warning("Generated visual asset registry loaded with fallbacks: %s" % str(visual_asset_registry.last_errors))

func setup_static_item_asset_registry() -> void:
    static_item_asset_registry = StaticItemAssetRegistryScript.new()
    if not static_item_asset_registry.setup():
        push_warning("Generated static item asset registry loaded with fallbacks: %s" % str(static_item_asset_registry.last_errors))

func setup_animated_asset_registry() -> void:
    animated_asset_registry = AnimatedAssetRegistryScript.new()
    if not animated_asset_registry.setup():
        push_warning("Generated animated asset registry loaded with fallbacks: %s" % str(animated_asset_registry.last_errors))

func grant_starter_inventory() -> void:
    inventory_system.add_item("woodBlock", 32)
    inventory_system.add_item("stoneBlock", 32)
    inventory_system.add_item("dirtBlock", 48)
    inventory_system.add_item("glass", 16)
    inventory_system.add_item("cobblestonePath", 24)
    inventory_system.add_item("logs", 12)
    inventory_system.add_item("stones", 12)
    inventory_system.add_item("sand", 12)
    inventory_system.add_item("dirt", 12)

func reset_crafting_unlocks(initial_groups := []) -> void:
    if crafting_system == null:
        return
    crafting_system.reset_unlocks(initial_groups)
    mark_world_dirty("crafting_unlocks_reset")

func unlock_crafting_group(group_id: String, reason := "") -> bool:
    if crafting_system == null or not crafting_system.has_method("unlock_group"):
        return false
    var changed: bool = bool(crafting_system.unlock_group(group_id))
    if changed:
        mark_world_dirty("crafting_unlock:%s" % group_id)
        if reason != "":
            crafting_system.last_message = "Unlocked: %s" % reason
    return changed

func unlock_all_crafting_groups_for_tests() -> void:
    if crafting_system == null or not crafting_system.has_method("unlock_all_groups"):
        return
    if bool(crafting_system.unlock_all_groups()):
        mark_world_dirty("crafting_unlock:test_all")

func _sync_inventory_totals() -> void:
    if inventory_system:
        inventory = inventory_system.totals()
        mark_world_dirty("inventory")

func save_world(show_message := true) -> bool:
    if save_system == null:
        return false
    if save_system.has_method("poll_async_save"):
        save_system.poll_async_save(true)
    var snapshot_start: int = runtime_perf_monitor.begin_section("autosave_snapshot") if runtime_perf_monitor != null else Time.get_ticks_usec()
    var snapshot: Dictionary = create_save_snapshot()
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("autosave_snapshot", snapshot_start)
    var ok: bool = save_system.save(seed_text, snapshot)
    if ok:
        reset_autosave_dirty_tracking(false)
    if show_message:
        update_hud("World saved" if ok else "Save failed")
    return ok

func try_load_world(show_message := false) -> bool:
    if save_system == null:
        return false
    if not autosave_enabled and not show_message:
        return false
    var snapshot: Dictionary = save_system.load(seed_text)
    if snapshot.is_empty():
        if show_message:
            update_hud("No save for %s" % seed_text)
        return false
    var loaded := apply_save_snapshot(snapshot)
    if loaded:
        reset_autosave_dirty_tracking(false)
    if show_message:
        update_hud("Loaded saved world" if loaded else "Load failed")
    return loaded

func start_new_game(show_message := true) -> bool:
    var previous_seed := seed_text
    if save_system:
        save_system.delete(previous_seed)
    apply_world_seed(random_world_seed(previous_seed), true)
    reset_runtime_world_state()
    var started := false
    if tutorial_system:
        started = tutorial_system.start_new_world()
    last_center_chunk = Vector2i(999999, 999999)
    update_chunks(true)
    if tutorial_system:
        tutorial_system.configure_starting_inventory()
    update_objectives_and_contracts()
    refresh_intro_knock_audio()
    if hud:
        hud.set_game_menu_open(false)
        hud.set_inventory_open(false)
        hud.set_teleport_open(false)
        hud.set_settings_open(false)
        hud.set_playtest_open(false)
        hud.hide_victory()
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    if show_message:
        update_hud("New game started" if started else "New game reset")
    reset_autosave_dirty_tracking(true, "new_game")
    return started
