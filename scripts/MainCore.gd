extends "res://scripts/MainInterface.gd"

signal startup_loading_step(message)
signal startup_loading_completed
signal startup_loading_failed(message)

const DEFAULT_VISUAL_STYLE := preload("res://resources/visual/gamecube_style.tres")
const INITIAL_NAVMESH_PRIME_TILE_LIMIT := 32
const INITIAL_NAV_CHANGE_DRAIN_EVENT_LIMIT := 64
const INITIAL_NAV_CHANGE_DRAIN_ITERATION_LIMIT := 16
const AUTOSAVE_ACTIVITY_MAX_DEFER_SECONDS := 30.0

var seed_text := "atlas-1492"
var seed_hash := 1
var startup_mode := "auto"
var deferred_startup_boot := false
var startup_loading_active := false
var runtime_loading_active := false
var post_startup_trace_frames := 0
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
var force_underground_volume_debug := false
var force_underground_volume_fine_focus := false

var terrain_material: Material
var materials := {}
var chunks := {}
var chunk_asset_cache := {}
var chunk_asset_cache_order: Array[Vector2i] = []
var chunk_asset_cache_hits := 0
var chunk_asset_cache_misses := 0
var chunk_asset_cache_invalidations := 0
var pending_chunk_loads := {}
var pending_chunk_prop_spawns := {}
var pending_chunk_terrain_refreshes := {}
var pending_chunk_collision_refreshes := {}
var pending_generated_volume_exposure_scans := {}
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
var terrain_meshing_service
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
var autosave_activity_defer_elapsed := 0.0
var autosave_recent_activity_grace := 0.0
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
var light_safety_sample_elapsed := 999.0
var cached_light_safety := 0.0
var cached_light_safety_position := Vector3.INF
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
var map_sample_build_key := ""
var map_sample_build_center_cell := Vector2i.ZERO
var map_sample_build_center_key := Vector2i.ZERO
var map_sample_build_radius := 0.0
var map_sample_build_row := 0
var map_sample_build_samples: Array = []
var map_sample_build_rows_per_call := 2
var navigation_marker_cache_source_key := ""
var navigation_marker_cache: Array = []
var navigation_marker_scan_source_key := ""
var navigation_marker_scan_keys: Array = []
var navigation_marker_scan_index := 0
var navigation_marker_scan_seen := {}
var navigation_marker_scan_budget := 256
var navigation_map_state_cache_key := ""
var navigation_map_state_cache := {}
var navigation_map_state_cache_elapsed := 999.0
var navigation_map_state_cache_interval := 0.75
var block_stats_cache := {}
var block_stats_cache_size := -1
var block_stats_cache_dirty := true
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
var fire_light_day_factor_elapsed := 999.0
var sky_audio_update_elapsed := 999.0
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
    if get_tree() != null:
        get_tree().auto_accept_quit = false
    if deferred_startup_boot:
        startup_loading_active = true
        set_process(false)
        set_process_unhandled_input(false)
        set_physics_process(false)
        call_deferred("_run_deferred_startup_boot")
        return
    playtest_progress("main_ready_start")
    var requested_startup_mode := startup_mode.strip_edges()
    if requested_startup_mode == "":
        requested_startup_mode = "auto"
    var underground_visual_fast_boot := OS.get_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT").strip_edges() == "1"
    var digging_visual_fast_boot := OS.get_environment("VOXEL_DIGGING_VISUAL_FAST_BOOT").strip_edges() == "1"
    var runtime_perf_fast_boot := OS.get_environment("VOXEL_RUNTIME_PERF_FAST_BOOT").strip_edges() == "1"
    var skip_synchronous_world_boot := underground_visual_fast_boot or digging_visual_fast_boot or runtime_perf_fast_boot
    setup_save_system()
    var active_seed := ""
    if autosave_enabled and save_system and save_system.has_method("active_seed"):
        active_seed = save_system.active_seed("")
    var forced_test_seed := test_seed_text()
    if forced_test_seed != "":
        seed_text = forced_test_seed
    elif requested_startup_mode == "new_game":
        seed_text = random_world_seed(active_seed)
    elif active_seed != "":
        seed_text = active_seed
    apply_world_seed(seed_text, requested_startup_mode == "new_game")
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
    var loaded := false
    if requested_startup_mode != "new_game":
        loaded = try_load_world()
    var started_intro_tutorial := false
    playtest_progress("main_load_done")
    if not loaded and tutorial_system and not skip_synchronous_world_boot:
        if autosave_enabled:
            apply_world_seed(random_world_seed(seed_text), true)
        started_intro_tutorial = tutorial_system.start_new_world()
        playtest_progress("main_tutorial_start_done")
    if not skip_synchronous_world_boot:
        bootstrap_initial_chunks()
        drain_initial_navigation_changes()
        prime_initial_navigation_snapshot()
        playtest_progress("main_initial_chunks_queued")
    var interactive_underground_message := "" if skip_synchronous_world_boot else apply_interactive_underground_launch_if_requested()
    if not skip_synchronous_world_boot:
        refresh_intro_knock_audio()
    var ready_message := "Loaded saved world" if loaded else "Godot slice ready"
    if not loaded and tutorial_system and tutorial_system.last_message != "":
        ready_message = tutorial_system.last_message
    if interactive_underground_message != "":
        ready_message = interactive_underground_message
    if not skip_synchronous_world_boot:
        update_hud(ready_message)
    reset_autosave_dirty_tracking(not loaded and not skip_synchronous_world_boot, "new_world")

func _run_deferred_startup_boot() -> void:
    await startup_loading_yield("Preparing world")
    playtest_progress("main_ready_start")
    var requested_startup_mode := startup_mode.strip_edges()
    if requested_startup_mode == "":
        requested_startup_mode = "auto"
    var underground_visual_fast_boot := OS.get_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT").strip_edges() == "1"
    var digging_visual_fast_boot := OS.get_environment("VOXEL_DIGGING_VISUAL_FAST_BOOT").strip_edges() == "1"
    var runtime_perf_fast_boot := OS.get_environment("VOXEL_RUNTIME_PERF_FAST_BOOT").strip_edges() == "1"
    var skip_synchronous_world_boot := underground_visual_fast_boot or digging_visual_fast_boot or runtime_perf_fast_boot
    setup_save_system()
    await startup_loading_yield("Selecting world")
    var active_seed := ""
    if autosave_enabled and save_system and save_system.has_method("active_seed"):
        active_seed = save_system.active_seed("")
    var forced_test_seed := test_seed_text()
    if forced_test_seed != "":
        seed_text = forced_test_seed
    elif requested_startup_mode == "new_game":
        seed_text = random_world_seed(active_seed)
    elif active_seed != "":
        seed_text = active_seed
    apply_world_seed(seed_text, requested_startup_mode == "new_game")
    playtest_progress("main_noise_done")
    await startup_loading_yield("Preparing terrain systems")
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
    await startup_loading_yield("Preparing scene")
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
    await startup_loading_yield("Loading save")
    var loaded := false
    if requested_startup_mode != "new_game":
        loaded = try_load_world()
    var started_intro_tutorial := false
    playtest_progress("main_load_done")
    if not loaded and tutorial_system and not skip_synchronous_world_boot:
        if autosave_enabled:
            apply_world_seed(random_world_seed(seed_text), true)
        if tutorial_system.has_method("start_new_world_staged"):
            started_intro_tutorial = bool(await tutorial_system.call("start_new_world_staged"))
        else:
            started_intro_tutorial = tutorial_system.start_new_world()
        playtest_progress("main_tutorial_start_done")
    if not skip_synchronous_world_boot:
        await bootstrap_initial_chunks_staged()
        await drain_initial_navigation_changes_staged()
        await prime_initial_navigation_snapshot_staged()
        await startup_loading_yield("Finalizing startup")
        playtest_progress("main_initial_chunks_queued")
    var interactive_underground_message := "" if skip_synchronous_world_boot else apply_interactive_underground_launch_if_requested()
    if not skip_synchronous_world_boot:
        await startup_loading_yield("Preparing intro audio")
        refresh_intro_knock_audio()
        await startup_loading_yield("Preparing HUD")
    var ready_message := "Loaded saved world" if loaded else "Godot slice ready"
    if not loaded and tutorial_system and tutorial_system.last_message != "":
        ready_message = tutorial_system.last_message
    if interactive_underground_message != "":
        ready_message = interactive_underground_message
    if not skip_synchronous_world_boot:
        update_hud(ready_message)
    await startup_loading_yield("Resetting save tracking")
    reset_autosave_dirty_tracking(not loaded and not skip_synchronous_world_boot, "new_world")
    await startup_loading_yield("Enabling gameplay")
    startup_loading_active = false
    post_startup_trace_frames = 3
    set_process(true)
    set_process_unhandled_input(true)
    set_physics_process(true)
    if player != null:
        player.set_physics_process(true)
    startup_loading_step.emit("Startup complete")
    startup_loading_completed.emit()

func startup_loading_yield(message: String) -> void:
    startup_loading_step.emit(message)
    if hud != null and hud.has_method("set_loading_message"):
        hud.set_loading_message(message)
    await get_tree().process_frame

func bootstrap_initial_chunks_staged(urgent_radius := 1) -> void:
    if player == null:
        return
    var center := world_to_chunk(player.position.x, player.position.z)
    var urgent_keys: Array[Vector2i] = []
    for dz in range(-urgent_radius, urgent_radius + 1):
        for dx in range(-urgent_radius, urgent_radius + 1):
            var key := Vector2i(center.x + dx, center.y + dz)
            urgent_keys.append(key)
            if not chunks.has(key):
                queue_chunk_load(key)
    last_center_chunk = center
    var total := urgent_keys.size()
    var guard := 0
    while guard < total + 12 and count_loaded_chunks(urgent_keys) < total:
        var loaded := count_loaded_chunks(urgent_keys)
        await startup_loading_yield("Loading terrain %d/%d" % [loaded, total])
        process_pending_chunk_loads(center)
        guard += 1
    process_pending_chunk_prop_spawns()
    last_center_chunk = Vector2i(999999, 999999)
    await startup_loading_yield("Terrain ready")

func count_loaded_chunks(keys: Array[Vector2i]) -> int:
    var count := 0
    for key in keys:
        if chunks.has(key):
            count += 1
    return count

func drain_initial_navigation_changes_staged() -> void:
    if npc_system == null:
        return
    var autonomy = npc_system.get("autonomy_system")
    if autonomy == null or not autonomy.has_method("process_navigation_changes"):
        return
    if not autonomy.has_method("pending_navigation_change_count"):
        return
    var iterations := 0
    while iterations < INITIAL_NAV_CHANGE_DRAIN_ITERATION_LIMIT:
        var pending := int(autonomy.call("pending_navigation_change_count"))
        if pending <= 0:
            break
        await startup_loading_yield("Preparing navigation %d" % pending)
        autonomy.call("process_navigation_changes", INITIAL_NAV_CHANGE_DRAIN_EVENT_LIMIT, -1)
        iterations += 1

func prime_initial_navigation_snapshot_staged() -> void:
    if npc_system == null:
        return
    var pathing = npc_system.get("pathing")
    var navigation_world = pathing.get("navigation_world") if pathing != null else null
    if navigation_world == null or not navigation_world.has_method("build_snapshot"):
        return
    var entries: Array = []
    var entry := {}
    var entries_value = npc_system.get("npcs")
    if entries_value is Array:
        entries = entries_value
    if not entries.is_empty() and entries[0] is Dictionary:
        entry = entries[0]
    await startup_loading_yield("Preparing NPC routes")
    navigation_world.call("build_snapshot", entry, true, false)
    await prime_initial_navigation_tiles_staged(navigation_world, entries)

func prime_initial_navigation_tiles_staged(navigation_world, entries: Array) -> void:
    # Route requests publish the exact navmesh tiles they need through the
    # frame-budgeted route coordinator. Startup must not enqueue broad tile work
    # that can immediately stall the first gameplay frame.
    return

func playtest_progress(label: String) -> void:
    var path: String = OS.get_environment("VOXEL_PLAYTEST_PROGRESS")
    if path == "":
        return
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\n" % label)
    file.close()

func bootstrap_initial_chunks(urgent_radius := 1) -> void:
    if player == null:
        return
    var center := world_to_chunk(player.position.x, player.position.z)
    for dz in range(-urgent_radius, urgent_radius + 1):
        for dx in range(-urgent_radius, urgent_radius + 1):
            var key := Vector2i(center.x + dx, center.y + dz)
            if not chunks.has(key):
                create_chunk(key.x, key.y, true)
    last_center_chunk = Vector2i(999999, 999999)
    update_chunks(false)

func prime_initial_navigation_snapshot() -> void:
    if npc_system == null:
        return
    var pathing = npc_system.get("pathing")
    var navigation_world = pathing.get("navigation_world") if pathing != null else null
    if navigation_world == null or not navigation_world.has_method("build_snapshot"):
        return
    var entries: Array = []
    var entry := {}
    var entries_value = npc_system.get("npcs")
    if entries_value is Array:
        entries = entries_value
    if not entries.is_empty() and entries[0] is Dictionary:
        entry = entries[0]
    navigation_world.call("build_snapshot", entry, true, false)
    prime_initial_navigation_tiles(navigation_world, entries)

func drain_initial_navigation_changes() -> void:
    if npc_system == null:
        return
    var autonomy = npc_system.get("autonomy_system")
    if autonomy == null or not autonomy.has_method("process_navigation_changes"):
        return
    if not autonomy.has_method("pending_navigation_change_count"):
        return
    var iterations := 0
    while iterations < INITIAL_NAV_CHANGE_DRAIN_ITERATION_LIMIT:
        var pending := int(autonomy.call("pending_navigation_change_count"))
        if pending <= 0:
            break
        autonomy.call("process_navigation_changes", INITIAL_NAV_CHANGE_DRAIN_EVENT_LIMIT, -1)
        iterations += 1

func prime_initial_navigation_tiles(navigation_world, entries: Array) -> void:
    # See staged variant above. Initial static snapshot warming is enough for
    # boot; tile publication is handled by live route demand.
    return

func prime_navigation_tiles_for_entry(navigation_world, npc_entry: Dictionary, tile_keys: Dictionary) -> void:
    var body := npc_entry.get("body") as Node3D
    var start := Vector3.ZERO
    if body != null and is_instance_valid(body):
        start = body.global_position
    elif npc_entry.get("porchPosition", null) is Vector3:
        start = npc_entry.get("porchPosition")
    var target_fields := ["homePosition", "porchPosition", "guardPosition"]
    for field in target_fields:
        if tile_keys.size() >= INITIAL_NAVMESH_PRIME_TILE_LIMIT:
            return
        var target_value = npc_entry.get(field, null)
        if not (target_value is Vector3):
            continue
        var target: Vector3 = target_value
        if not is_finite(target.x) or not is_finite(target.z):
            continue
        if navigation_world.has_method("route_navmesh_tile_keys"):
            var route_keys = navigation_world.call("route_navmesh_tile_keys", npc_entry, start, target, true, true, 6)
            if route_keys is Array:
                for route_key in route_keys:
                    if tile_keys.size() >= INITIAL_NAVMESH_PRIME_TILE_LIMIT:
                        return
                    var key := String(route_key)
                    if key != "":
                        tile_keys[key] = true
    if not navigation_world.has_method("tile_key_for_cell"):
        return
    var cell_fields := ["homeCell", "porchCell", "guardCell", "townCenter"]
    for field in cell_fields:
        if tile_keys.size() >= INITIAL_NAVMESH_PRIME_TILE_LIMIT:
            return
        var cell_value = npc_entry.get(field, null)
        if not (cell_value is Vector2i):
            continue
        var tile_key := String(navigation_world.call("tile_key_for_cell", cell_value))
        if tile_key != "":
            tile_keys[tile_key] = true

func setup_save_system() -> void:
    autosave_enabled = OS.get_environment("VOXEL_PLAYTEST") == ""
    var save_path := "user://voxel_biome_world_saves.json" if autosave_enabled else "user://voxel_biome_world_playtest_saves.json"
    var save_path_override := OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges()
    if save_path_override != "":
        save_path = save_path_override
    save_system = SaveSystemScript.new(save_path)
    autosave_interval_seconds = 60.0

func mark_world_dirty(reason := "world") -> void:
    autosave_dirty = true
    autosave_dirty_reasons[String(reason)] = true

func reset_autosave_dirty_tracking(mark_dirty := false, reason := "reset") -> void:
    autosave_dirty = mark_dirty
    autosave_dirty_reasons.clear()
    autosave_activity_defer_elapsed = 0.0
    autosave_recent_activity_grace = 0.0
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
        if autosave_dirty:
            var pending := bool(save_system.call("has_async_save_pending")) if save_system.has_method("has_async_save_pending") else false
            if pending:
                autosave_elapsed = 0.0
                mark_world_dirty("autosave_pending")
                if runtime_perf_monitor != null:
                    runtime_perf_monitor.increment_counter("autosave_pending")
            elif should_defer_autosave_snapshot_for_activity(delta):
                autosave_elapsed = autosave_interval_seconds
                if runtime_perf_monitor != null:
                    runtime_perf_monitor.increment_counter("autosave_activity_deferred")
            else:
                autosave_elapsed = 0.0
                autosave_activity_defer_elapsed = 0.0
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
        else:
            autosave_elapsed = 0.0
            autosave_activity_defer_elapsed = 0.0
    perf_autosave_ms = runtime_perf_monitor.end_section("autosave", section_start) if runtime_perf_monitor != null else float(Time.get_ticks_usec() - section_start) / 1000.0

func should_defer_autosave_snapshot_for_activity(delta: float) -> bool:
    if autosave_activity_defer_elapsed >= AUTOSAVE_ACTIVITY_MAX_DEFER_SECONDS:
        return false
    if player == null:
        return false
    var horizontal_speed := Vector2(player.velocity.x, player.velocity.z).length()
    var sprinting := bool(player.get("automated_sprint")) if player.has_method("get") else false
    var high_activity := horizontal_speed >= CELL * 4.0 or sprinting
    if high_activity:
        autosave_recent_activity_grace = 3.0
    elif autosave_recent_activity_grace > 0.0:
        autosave_recent_activity_grace = maxf(0.0, autosave_recent_activity_grace - maxf(0.0, delta))
        high_activity = true
    if not high_activity:
        return false
    autosave_activity_defer_elapsed += maxf(0.0, delta)
    return true

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
    playtest_progress("apply_seed_setup_noise")
    setup_noise()
    playtest_progress("apply_seed_setup_world_generation")
    setup_world_generation_system()
    if world_generation_system and world_generation_system.has_method("reset_for_seed"):
        playtest_progress("apply_seed_world_generation_reset")
        world_generation_system.reset_for_seed()
    if weather_system and weather_system.has_method("reset_for_seed"):
        playtest_progress("apply_seed_weather_reset")
        weather_system.reset_for_seed(seed_hash)
    if region_story_generator and region_story_generator.has_method("setup"):
        playtest_progress("apply_seed_region_story")
        region_story_generator.setup(seed_text, seed_hash, TOWN_REGION_CELLS)
    if story_director and story_director.has_method("reset"):
        playtest_progress("apply_seed_story_director")
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
        playtest_progress("apply_seed_remember")
        save_system.set_active_seed(seed_text)
    playtest_progress("apply_seed_done")

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

func apply_interactive_underground_launch_if_requested() -> String:
    if OS.get_environment("VOXEL_UNDERGROUND_INTERACTIVE").strip_edges() != "1":
        return ""
    if player == null or world_generation_system == null:
        return "Interactive underground launch failed: player or world generation missing"
    neutralize_interactive_underground_tutorial()
    var radius_text := OS.get_environment("VOXEL_UNDERGROUND_INTERACTIVE_SEARCH_RADIUS").strip_edges()
    var search_radius := clampi(int(radius_text) if radius_text != "" else 12, 1, 64)
    var min_depth_text := OS.get_environment("VOXEL_UNDERGROUND_INTERACTIVE_MIN_DEPTH").strip_edges()
    var max_depth_text := OS.get_environment("VOXEL_UNDERGROUND_INTERACTIVE_MAX_DEPTH").strip_edges()
    var min_depth := clampi(int(min_depth_text) if min_depth_text != "" else 4, 1, 72)
    var max_depth := clampi(int(max_depth_text) if max_depth_text != "" else 30, min_depth, 72)
    if not world_generation_system.has_method("find_underground_air_sample"):
        return "Interactive underground launch failed: underground sampler missing"
    var underground_record: Dictionary = world_generation_system.call("find_underground_air_sample", search_radius, min_depth, max_depth)
    if underground_record.is_empty():
        return "Interactive underground launch failed: no underground_air found within %d search radius" % search_radius
    var sample_cell: Vector3i = underground_record.get("cell", Vector3i.ZERO)
    var sample_position: Vector3 = underground_record.get("position", Vector3.ZERO)
    var spawn_position := sample_position + Vector3(0.0, CELL * 0.65, 0.0)
    player.global_position = spawn_position
    player.velocity = Vector3.ZERO
    force_underground_volume_debug = true
    aim_player_at_interactive_underground(sample_position)
    configure_interactive_underground_inventory()
    if OS.get_environment("VOXEL_UNDERGROUND_INTERACTIVE_GOD_MODE").strip_edges() == "1" and survival_system != null and survival_system.has_method("set_test_god_mode"):
        survival_system.call("set_test_god_mode", true, "interactive_underground_playtest")
    rebuild_chunks_around_cell(Vector2i(sample_cell.x, sample_cell.z))
    bootstrap_initial_chunks()
    if hud != null:
        if hud.has_method("hide_dialogue"):
            hud.hide_dialogue(false)
        hud.set_inventory_open(false)
        hud.set_teleport_open(false)
        hud.set_settings_open(false)
        hud.set_playtest_open(false)
        hud.set_game_menu_open(false)
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    write_interactive_underground_launch_info(underground_record, spawn_position)
    return "Interactive underground volume ready: %s" % String(underground_record.get("id", "underground_air"))

func neutralize_interactive_underground_tutorial() -> void:
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

func aim_player_at_interactive_underground(sample_position: Vector3) -> void:
    if player == null:
        return
    var target := Vector3(sample_position.x + CELL, player.global_position.y, sample_position.z + CELL)
    if target.distance_to(player.global_position) > 0.05:
        player.look_at(target, Vector3.UP)
    player.set("pitch", 0.0)
    var camera := player.get("camera") as Camera3D
    if camera != null:
        camera.rotation.x = 0.0
        camera.make_current()

func configure_interactive_underground_inventory() -> void:
    if inventory_system == null:
        return
    inventory_system.clear()
    inventory_system.add_item("torch", 16)
    inventory_system.add_item("stonePickaxe", 1)
    inventory_system.add_item("fieldRation", 4)
    inventory_system.add_item("stoneSword", 1)
    inventory_system.select(0)

func write_interactive_underground_launch_info(record: Dictionary, spawn_position: Vector3) -> void:
    var path := OS.get_environment("VOXEL_UNDERGROUND_INTERACTIVE_LAUNCH_INFO").strip_edges()
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
        "sampleId": String(record.get("id", "")),
        "kind": "underground-air",
        "cell": vec3i_dictionary(record.get("cell", Vector3i.ZERO)),
        "surfaceCell": vec2i_dictionary(record.get("surfaceCell", Vector2i.ZERO)),
        "depthCells": int(record.get("depthCells", 0)),
        "spawnPosition": vec3_dictionary(spawn_position),
        "godMode": OS.get_environment("VOXEL_UNDERGROUND_INTERACTIVE_GOD_MODE").strip_edges() == "1"
    }
    file.store_string(JSON.stringify(report, "  "))
    file.close()

func vec2i_dictionary(value: Vector2i) -> Dictionary:
    return { "x": value.x, "z": value.y }

func vec3i_dictionary(value: Vector3i) -> Dictionary:
    return { "x": value.x, "y": value.y, "z": value.z }

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
    if terrain_meshing_service == null:
        terrain_meshing_service = TerrainMeshingServiceScript.new()
    terrain_meshing_service.setup(self)

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
    playtest_progress("new_game_start")
    var previous_seed := seed_text
    if save_system:
        playtest_progress("new_game_delete_save")
        save_system.delete(previous_seed)
    playtest_progress("new_game_apply_seed")
    apply_world_seed(random_world_seed(previous_seed), true)
    playtest_progress("new_game_reset_runtime")
    reset_runtime_world_state()
    var started := false
    if tutorial_system:
        playtest_progress("new_game_start_tutorial")
        started = tutorial_system.start_new_world()
    playtest_progress("new_game_bootstrap_chunks")
    bootstrap_initial_chunks()
    if tutorial_system:
        playtest_progress("new_game_starting_inventory")
        tutorial_system.configure_starting_inventory()
    playtest_progress("new_game_objectives")
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
    playtest_progress("new_game_done")
    return started

func start_new_game_staged(show_message := true) -> bool:
    if runtime_loading_active:
        return false
    runtime_loading_active = true
    playtest_progress("new_game_staged_start")
    if hud != null and hud.has_method("show_loading_overlay"):
        hud.show_loading_overlay("Starting new game")
    set_process(false)
    set_process_unhandled_input(false)
    if player != null:
        player.set_physics_process(false)
        player.velocity = Vector3.ZERO
    await startup_loading_yield("Starting new game")
    var previous_seed := seed_text
    if save_system:
        playtest_progress("new_game_staged_delete_save")
        save_system.delete(previous_seed)
    await startup_loading_yield("Choosing new world")
    apply_world_seed(random_world_seed(previous_seed), true)
    await startup_loading_yield("Resetting world")
    reset_runtime_world_state(false)
    var started := false
    if tutorial_system:
        playtest_progress("new_game_staged_start_tutorial")
        if tutorial_system.has_method("start_new_world_staged"):
            started = bool(await tutorial_system.call("start_new_world_staged"))
        else:
            started = tutorial_system.start_new_world()
    await startup_loading_yield("Reloading terrain")
    reload_chunks(true)
    await bootstrap_initial_chunks_staged()
    await drain_initial_navigation_changes_staged()
    await prime_initial_navigation_snapshot_staged()
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
    if hud != null and hud.has_method("hide_loading_overlay"):
        hud.hide_loading_overlay()
    runtime_loading_active = false
    set_process(true)
    set_process_unhandled_input(true)
    if player != null:
        player.set_physics_process(true)
    playtest_progress("new_game_staged_done")
    return started

func request_graceful_quit(exit_code := 0) -> void:
    if runtime_loading_active:
        return
    runtime_loading_active = true
    if hud != null and hud.has_method("show_loading_overlay"):
        hud.show_loading_overlay("Saving and exiting")
    set_process(false)
    set_process_unhandled_input(false)
    if player != null:
        player.velocity = Vector3.ZERO
        player.set_physics_process(false)
    call_deferred("_graceful_quit_deferred", exit_code)

func _graceful_quit_deferred(exit_code: int) -> void:
    await startup_loading_yield("Saving and exiting")
    if save_system != null and save_system.has_method("has_async_save_pending"):
        await wait_for_async_save_before_quit()
    if autosave_enabled and save_system != null and autosave_dirty:
        await startup_loading_yield("Saving world")
        var snapshot: Dictionary = create_save_snapshot()
        var started := false
        if save_system.has_method("save_async"):
            started = bool(save_system.save_async(seed_text, snapshot))
        if started:
            await wait_for_async_save_before_quit()
        else:
            save_system.save(seed_text, snapshot)
    await wait_for_terrain_workers_before_quit()
    get_tree().quit(exit_code)

func wait_for_async_save_before_quit() -> void:
    if save_system == null or not save_system.has_method("has_async_save_pending"):
        return
    var guard := 0
    while bool(save_system.call("has_async_save_pending")) and guard < 600:
        await startup_loading_yield("Saving world")
        if save_system.has_method("poll_async_save"):
            save_system.call("poll_async_save", false)
        guard += 1
    if save_system.has_method("poll_async_save"):
        save_system.call("poll_async_save", true)

func wait_for_terrain_workers_before_quit() -> void:
    if terrain_meshing_service == null or not terrain_meshing_service.has_method("clear_jobs"):
        return
    await startup_loading_yield("Stopping terrain jobs")
    terrain_meshing_service.call("clear_jobs", false)
    var guard := 0
    while guard < 600:
        if terrain_meshing_service.has_method("collect_retired_worker_threads"):
            terrain_meshing_service.call("collect_retired_worker_threads", false)
        var retired_value = terrain_meshing_service.get("retired_worker_threads")
        var retired_count := (retired_value as Array).size() if retired_value is Array else 0
        if retired_count <= 0:
            break
        await startup_loading_yield("Stopping terrain jobs")
        guard += 1
    if terrain_meshing_service.has_method("collect_retired_worker_threads"):
        terrain_meshing_service.call("collect_retired_worker_threads", true)

func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST:
        request_graceful_quit()
