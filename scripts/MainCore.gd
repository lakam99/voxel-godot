extends "res://scripts/MainInterface.gd"

signal startup_loading_step(message)
signal startup_loading_completed
signal startup_loading_failed(message)

const DEFAULT_VISUAL_STYLE := preload("res://resources/visual/gamecube_style.tres")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const StartupReadinessResultScript := preload("res://scripts/world/StartupReadinessResult.gd")
const StartupWorkProgressTrackerScript := preload("res://scripts/perf/StartupWorkProgressTracker.gd")
const GeneratedStructurePlayerClearanceScript := preload("res://scripts/world/GeneratedStructurePlayerClearance.gd")
const GameLaunchOptionsScript := preload("res://scripts/world/GameLaunchOptions.gd")
const WorldStreamingCoordinatorScript := preload("res://scripts/world/WorldStreamingCoordinator.gd")
const ActorPhysicalStreamingDemandScript := preload("res://scripts/world/ActorPhysicalStreamingDemand.gd")
const NativeCollisionAdmissionBarrierScript := preload("res://scripts/terrain/NativeCollisionAdmissionBarrier.gd")
const GeneratedContentViewPriorityScript := preload("res://scripts/world/GeneratedContentViewPriority.gd")
const RegionalNavigationPublicationScript := preload("res://scripts/world/RegionalNavigationPublication.gd")
const WorldLoadingOverlayScript := preload("res://scripts/world/WorldLoadingOverlay.gd")
const NativeTerrainLoadTransactionScript := preload("res://scripts/terrain/NativeTerrainLoadTransaction.gd")
const NavigationMarkerIndexScript := preload("res://scripts/hud/NavigationMarkerIndex.gd")
const INITIAL_NAVMESH_PRIME_TILE_LIMIT := 32
const INITIAL_NAV_CHANGE_DRAIN_EVENT_LIMIT := 64
const INITIAL_NAV_CHANGE_DRAIN_ITERATION_LIMIT := 16
const INITIAL_READINESS_TIMEOUT_SECONDS := 120.0
const FINAL_TERRAIN_EXPANSION_TIMEOUT_SECONDS := 180.0
const VOXEL_SHUTDOWN_TASK_DRAIN_TIMEOUT_SECONDS := 30.0
const AUTOSAVE_ACTIVITY_MAX_DEFER_SECONDS := 30.0
const STREAMING_FORECAST_SECONDS := 1.5
const STREAMING_FORECAST_MAX_CELLS := 16.0
const STREAMING_STATIONARY_FORECAST_SECONDS := 1.0
const GAMEPLAY_REGIONAL_NAVIGATION_BUDGET_USEC := 1500

var seed_text := "atlas-1492"
var seed_hash := 1
var startup_mode := "auto"
var launch_options := GameLaunchOptionsScript.parse(OS.get_cmdline_user_args())
var startup_overlay: CanvasLayer
var startup_operation_active := false
var shutdown_requested := false
var startup_loading_active := false
var startup_loading_started_usec := 0
var startup_loading_last_step_usec := 0
var startup_loading_timeline: Array[Dictionary] = []
var startup_work_progress = StartupWorkProgressTrackerScript.new()
var startup_readiness_domains := {}
var startup_loading_failure_result := {}
var world_streaming = WorldStreamingCoordinatorScript.new()
var regional_navigation = RegionalNavigationPublicationScript.new()
var streaming_requests: Dictionary = {}
var streaming_request_bounds: Dictionary = {}
var streaming_request_priorities: Dictionary = {}
var streaming_request_foreground_tiles: Dictionary = {}
var streaming_request_foreground_bounds: Dictionary = {}
var streaming_request_peripheral_margins: Dictionary = {}
var streaming_applied_revision := -1
var streaming_applied_source_revision := -1
var streaming_requested_source_revision := -1
var streaming_applied_view_revision := -1
var streaming_active := false
var streaming_player_cell := Vector2i(2147483647,2147483647)
var streaming_demand_error := ""
var streaming_actor_physical_demand_diagnostics := {"actorCount":0,"ownerCount":0,"groups":[]}
var startup_loading_max_step := {}
var runtime_loading_active := false
var streaming_loading_overlay_active := false
var streaming_loading_message := ""
var streaming_loading_request_owner := ""
var streaming_loading_overlay_holds: Dictionary = {}
var streaming_loading_overlay_serial := 0
var runtime_relocation_active := false
var gameplay_publication_deadline_usec := 0
var npc_navigation_publication_permitted := true
var gameplay_publication_lane := -1
var gameplay_publication_frame_token := -1
var gameplay_publication_frame_started_usec := 0
var gameplay_publication_citadel_claimed_frame := -1
var gameplay_publication_max_atom_usec := 0
var gameplay_publication_overrun_count := 0
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
var _native_collision_admission_barrier: RefCounted
var _native_collision_admission_owner_id := 0
## Reserved loading-only composition seam. Normal boot leaves this null; it
## never participates in terrain queries, collision publication, or readiness.
var native_terrain_load_transaction
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
var startup_chunk_loading_diagnostics := {}
var pending_chunk_prop_spawns := {}
var pending_chunk_terrain_refreshes := {}
var pending_chunk_collision_refreshes := {}
var pending_generated_volume_exposure_scans := {}
var volume_edit_markers := {}
var town_region_cache := {}
var town_slope_apron_cache := {}
var blocks := {}
var navigation_marker_index = NavigationMarkerIndexScript.new()
var removed_props := {}
var removed_props_revision := 0
var inventory := {}
var inventory_system
var crafting_system
var objective_system
var world_generation_system
var terrain_meshing_service
var world_edit_followup_queue
var last_destroy_target_metrics := {}
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
var player_motion_combat
var weather_system
var environment_wind_system
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
var biome_environment_catalog
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
var wildlife_update_cursor := 0
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
# Runtime light-safety queries occur in several gameplay loops. This contains
# only the small set of block types which can affect the answer. Entries retain
# object instance IDs rather than node references so queued/deleted sources can
# resolve to null safely during a later gameplay query.
var light_safety_sources := {}
var light_safety_sources_initialized := false
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

func native_collision_admit_motion(body: PhysicsBody3D, motion: Vector3) -> bool:
    if _native_collision_admission_owner_id == 0:
        return true
    if not _native_collision_admission_barrier is NativeCollisionAdmissionBarrierScript:
        return false
    return _native_collision_admission_barrier.admit_motion(body, motion)

func native_collision_admission_bound() -> bool:
    return _native_collision_admission_owner_id != 0

func native_collision_register_moving_actor(body: PhysicsBody3D) -> bool:
    if _native_collision_admission_owner_id == 0:
        return true
    if not _native_collision_admission_barrier is NativeCollisionAdmissionBarrierScript:
        return false
    return _native_collision_admission_barrier.register_moving_actor(body)

func native_collision_admit_placement(body: PhysicsBody3D, proposed_transform: Transform3D) -> bool:
    if _native_collision_admission_owner_id == 0:
        return true
    if not _native_collision_admission_barrier is NativeCollisionAdmissionBarrierScript:
        return false
    return _native_collision_admission_barrier.admit_placement(body, proposed_transform)

func bind_native_collision_admission(owner: Node, barrier: RefCounted) -> bool:
    if owner == null or not is_instance_valid(owner) or owner.get_instance_id() <= 0 \
            or _native_collision_admission_owner_id != 0 \
            or not barrier is NativeCollisionAdmissionBarrierScript \
            or not barrier.is_active():
        return false
    _native_collision_admission_owner_id = owner.get_instance_id()
    _native_collision_admission_barrier = barrier
    if hostile_system != null and hostile_system.has_method("set_native_collision_admission_required"):
        hostile_system.set_native_collision_admission_required(true)
    return true

func unbind_native_collision_admission(owner: Node) -> bool:
    if owner == null or not is_instance_valid(owner) \
            or owner.get_instance_id() != _native_collision_admission_owner_id \
            or _native_collision_admission_barrier == null \
            or _native_collision_admission_barrier.is_active():
        return false
    _native_collision_admission_owner_id = 0
    _native_collision_admission_barrier = null
    if hostile_system != null and hostile_system.has_method("set_native_collision_admission_required"):
        hostile_system.set_native_collision_admission_required(false)
    return true

func _ready() -> void:
    if get_tree() != null:
        get_tree().auto_accept_quit = false
    startup_loading_active = true
    set_process(false)
    set_process_unhandled_input(false)
    set_physics_process(false)
    startup_overlay = WorldLoadingOverlayScript.new()
    startup_overlay.name = "WorldLoading"
    add_child(startup_overlay)
    call_deferred("_run_startup_boot")

func _run_startup_boot() -> void:
    startup_operation_active = true
    await _run_deferred_startup_boot()
    startup_operation_active = false

func wait_for_startup_loading_complete(timeout_seconds := 240.0, allow_diagnostic_setup := false) -> bool:
    # Observe the production lifecycle. Node.ready, a generator, or inactive
    # loading flags alone cannot establish gameplay readiness after a failure.
    var deadline := Time.get_ticks_msec() + int(maxf(timeout_seconds, 0.0) * 1000.0)
    while is_inside_tree() and not is_queued_for_deletion() and not shutdown_requested:
        if not startup_loading_failure_result.is_empty():
            return false
        if not startup_loading_active and not runtime_loading_active:
            if String(startup_readiness_domains.get("gameplay", {}).get("status", "")) == "ready":
                return true
            if allow_diagnostic_setup and String(startup_readiness_domains.get("diagnostic_fast_boot", {}).get("status", "")) == "excluded":
                return true
        if Time.get_ticks_msec() >= deadline:
            return false
        await get_tree().process_frame
    return false

func _run_deferred_startup_boot() -> void:
    begin_startup_loading_timeline()
    await startup_loading_yield("Preparing world", "startup", "pending")
    if shutdown_requested:
        apply_startup_loading_failure_state(StartupReadinessResultScript.failed("startup_cancelled"))
        return
    playtest_progress("main_ready_start")
    var requested_startup_mode := startup_mode.strip_edges()
    if requested_startup_mode == "":
        requested_startup_mode = "auto"
    var underground_visual_fast_boot := OS.get_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT").strip_edges() == "1"
    var digging_visual_fast_boot := OS.get_environment("VOXEL_DIGGING_VISUAL_FAST_BOOT").strip_edges() == "1"
    var runtime_perf_fast_boot := OS.get_environment("VOXEL_RUNTIME_PERF_FAST_BOOT").strip_edges() == "1"
    var skip_synchronous_world_boot := underground_visual_fast_boot or digging_visual_fast_boot or runtime_perf_fast_boot
    if skip_synchronous_world_boot:
        await startup_loading_yield("Diagnostic fast boot excludes gameplay readiness", "diagnostic_fast_boot", "excluded", {
            "undergroundVisual": underground_visual_fast_boot,
            "diggingVisual": digging_visual_fast_boot,
            "runtimePerformance": runtime_perf_fast_boot,
            "gameplayAcceptance": false
        })
    setup_save_system()
    await startup_loading_yield("Selecting world", "world_seed", "pending")
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
    await startup_loading_yield("Preparing terrain systems", "systems", "pending")
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
    await startup_loading_yield("Preparing scene", "scene", "pending")
    if shutdown_requested:
        apply_startup_loading_failure_state(StartupReadinessResultScript.failed("startup_cancelled"))
        return
    setup_audio_effects()
    if not is_instance_valid(audio_effects):
        apply_startup_loading_failure_state(StartupReadinessResultScript.failed("audio_startup_owner_missing"))
        return
    while not audio_effects.startup_preparation_ready():
        var audio_state: Dictionary = audio_effects.startup_preparation_state()
        if shutdown_requested or bool(audio_state.get("cancelled", false)):
            audio_effects.shutdown_audio()
            apply_startup_loading_failure_state(StartupReadinessResultScript.failed(
                "startup_cancelled" if shutdown_requested else "audio_startup_cancelled"))
            return
        await startup_loading_yield("Preparing audio %d/%d" % [
            int(audio_state.get("completedJobs", 0)), int(audio_state.get("totalJobs", 0))],
            "scene", "pending", {"audio": audio_state})
        if not is_instance_valid(audio_effects):
            apply_startup_loading_failure_state(StartupReadinessResultScript.failed("audio_startup_owner_missing"))
            return
        if not shutdown_requested:
            audio_effects.advance_startup_preparation()
    setup_break_overlay()
    setup_tutorial_system()

    setup_player()
    if player != null:
        player.set_physics_process(false)
    setup_hostiles()
    setup_npc_system()
    set_registered_npc_physics_enabled(false)
    setup_player_projectiles()
    setup_player_motion_combat()
    setup_held_item()
    setup_hud()
    playtest_progress("main_scene_nodes_done")
    await startup_loading_yield("Loading save", "save_restore", "pending")
    var loaded := false
    if requested_startup_mode != "new_game":
        loaded = try_load_world()
    if requested_startup_mode == "continue" and not loaded:
        await stop_startup_loading(StartupReadinessResultScript.failed(
            "continue_save_restore_failed",
            {},
            [],
            {
                "requestedMode": requested_startup_mode,
                "activeSeed": active_seed,
                "selectedSeed": seed_text
            }
        ))
        return
    var tutorial_result := StartupReadinessResultScript.ready({}, {
        "tutorialActive": false,
        "mode": "continue" if loaded else "new_game"
    })
    playtest_progress("main_load_done")
    if not loaded and tutorial_system and not skip_synchronous_world_boot and not launch_options.skipTutorial:
        if autosave_enabled:
            apply_world_seed(random_world_seed(seed_text), true)
        if not tutorial_system.has_method("start_new_world_staged"):
            await stop_startup_loading(StartupReadinessResultScript.failed("missing_staged_tutorial_startup"))
            return
        tutorial_result = normalized_startup_result(
            await tutorial_system.call("start_new_world_staged"),
            "invalid_staged_tutorial_startup_result"
        )
        if not startup_result_is_ready(tutorial_result):
            await stop_startup_loading(tutorial_result, "tutorial_startup_failed")
            return
        playtest_progress("main_tutorial_start_done")
    elif loaded and tutorial_system and bool(tutorial_system.get("started")) and not skip_synchronous_world_boot:
        # Snapshot restoration only restores data and retires chunk presenters.
        # Bind those saved/scenario inputs before staged town publication.
        var restore_authority_result := normalized_startup_result(
            await reinitialize_voxel_terrain_authority_staged(), "terrain_authority_reset_failed"
        )
        if not startup_result_is_ready(restore_authority_result):
            await stop_startup_loading(restore_authority_result)
            return
        if not tutorial_system.has_method("complete_restore_world_staged"):
            await stop_startup_loading(StartupReadinessResultScript.failed("missing_staged_tutorial_restore"))
            return
        tutorial_result = normalized_startup_result(
            await tutorial_system.call("complete_restore_world_staged"),
            "invalid_staged_tutorial_restore_result"
        )
        if not startup_result_is_ready(tutorial_result):
            await stop_startup_loading(tutorial_result, "tutorial_restore_readiness_failed")
            return
    if loaded:
        await startup_loading_yield("Saved world restored", "save_restore", "ready", {
            "requestedMode": requested_startup_mode,
            "seed": seed_text,
            "tutorial": tutorial_result.get("metrics", {})
        })
    var interactive_underground_message := "" if skip_synchronous_world_boot else apply_interactive_underground_launch_if_requested()
    if not skip_synchronous_world_boot:
        var terrain_result := normalized_startup_result(
            await bootstrap_initial_chunks_staged(),
            "invalid_terrain_readiness_result"
        )
        if not startup_result_is_ready(terrain_result):
            await stop_startup_loading(terrain_result, "terrain_collision_not_ready")
            return
        # The player request can retain terrain beyond the urgent spawn chunks
        # when a generated town contributes homes, doors, or other physical
        # dependencies.  Settle that complete physical closure before capturing
        # navigation. Otherwise later chunk/prop publication changes the tile
        # source revisions and startup builds the same NPC route tiles twice.
        var physical_region_result := normalized_startup_result(
            await wait_for_initial_region_physical_readiness(),
            "invalid_initial_region_physical_readiness_result"
        )
        if not startup_result_is_ready(physical_region_result):
            await stop_startup_loading(physical_region_result, "initial_region_physical_not_ready")
            return
        var terrain_expansion_result := normalized_startup_result(
            await wait_for_final_voxel_view_distance(),
            "invalid_final_terrain_expansion_result"
        )
        if not startup_result_is_ready(terrain_expansion_result):
            await stop_startup_loading(terrain_expansion_result, "final_terrain_expansion_not_ready")
            return
        var navigation_change_result := normalized_startup_result(
            await drain_initial_navigation_changes_staged(),
            "invalid_navigation_change_readiness_result"
        )
        if not startup_result_is_ready(navigation_change_result):
            await stop_startup_loading(navigation_change_result, "navigation_changes_not_ready")
            return
        var navigation_result := normalized_startup_result(
            await prime_initial_navigation_snapshot_staged(),
            "invalid_navigation_readiness_result"
        )
        if not startup_result_is_ready(navigation_result):
            await stop_startup_loading(navigation_result, "navigation_not_ready")
            return
        var terrain_runtime_after_navigation=get("voxel_terrain_runtime")
        if terrain_runtime_after_navigation != null and is_instance_valid(terrain_runtime_after_navigation) \
                and terrain_runtime_after_navigation.has_method("release_startup_auxiliary_publication_chunks"):
            terrain_runtime_after_navigation.call("release_startup_auxiliary_publication_chunks")
        await startup_loading_yield("Finalizing startup", "startup", "pending", {
            "tutorial": tutorial_result.get("metrics", {}),
            "terrain": terrain_result.get("metrics", {}),
            "navigationChanges": navigation_change_result.get("metrics", {}),
            "navigation": navigation_result.get("metrics", {})
        })
        playtest_progress("main_initial_chunks_queued")
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
    if skip_synchronous_world_boot:
        await startup_loading_yield("Diagnostic fast boot ready", "diagnostic_fast_boot", "excluded", {
            "playerPhysicsEnabled": false,
            "npcPhysicsEnabled": false,
            "gameplayAcceptance": false
        })
    else:
        var physics_gate_result := startup_physics_gate_readiness()
        if not startup_result_is_ready(physics_gate_result):
            await stop_startup_loading(physics_gate_result, "gameplay_physics_gate_failed")
            return
        var presentation_result := await wait_for_initial_terrain_presentation()
        if not startup_result_is_ready(presentation_result):
            await stop_startup_loading(presentation_result, "terrain_presentation_not_ready")
            return
        var region_result := await wait_for_initial_region_readiness()
        if not startup_result_is_ready(region_result):
            await stop_startup_loading(region_result, "initial_region_not_ready")
            return
        await startup_loading_yield(
            "Gameplay prerequisites ready",
            "gameplay",
            "ready",
            physics_gate_result.get("metrics", {})
        )
    if shutdown_requested:
        apply_startup_loading_failure_state(StartupReadinessResultScript.failed("startup_cancelled"))
        return
    startup_loading_active = false
    post_startup_trace_frames = 3
    var enable_gameplay := not skip_synchronous_world_boot and not shutdown_requested
    set_process(enable_gameplay)
    set_process_unhandled_input(enable_gameplay)
    set_physics_process(enable_gameplay)
    if player != null:
        player.set_physics_process(enable_gameplay)
    set_registered_npc_physics_enabled(enable_gameplay)
    if startup_overlay != null:
        startup_overlay.hide()
    startup_loading_completed.emit()

func request_final_voxel_view_distance() -> void:
    var voxel_runtime = get("voxel_terrain_runtime")
    if voxel_runtime != null and is_instance_valid(voxel_runtime) and voxel_runtime.has_method("request_final_view_distance_expansion"):
        voxel_runtime.call("request_final_view_distance_expansion")

func wait_for_final_voxel_view_distance() -> Dictionary:
    var runtime = get("voxel_terrain_runtime")
    if runtime == null or not is_instance_valid(runtime):
        return StartupReadinessResultScript.failed("missing_voxel_terrain_expansion_authority")
    if not runtime.has_method("request_final_view_distance_expansion") \
        or not runtime.has_method("final_view_distance_expansion_state"):
        return StartupReadinessResultScript.failed("missing_voxel_terrain_expansion_contract")
    runtime.call("request_final_view_distance_expansion")
    var started_usec := Time.get_ticks_usec()
    var state: Dictionary = {}
    while float(Time.get_ticks_usec() - started_usec) / 1000000.0 < FINAL_TERRAIN_EXPANSION_TIMEOUT_SECONDS:
        if shutdown_requested:
            return StartupReadinessResultScript.failed("startup_cancelled")
        state = normalized_startup_result(
            runtime.call("final_view_distance_expansion_state"),
            "invalid_final_terrain_expansion_state"
        )
        if startup_result_is_ready(state):
            await startup_loading_yield("Nearby terrain drawn", "terrain_view_expansion", "ready", state.get("metrics", {}))
            return state
        if String(state.get("status", "")) == StartupReadinessResultScript.STATUS_FAILED \
            and String(state.get("reason", "")) != "terrain_generation_pending":
            return state
        process_pending_chunk_loads(world_to_chunk(player.position.x, player.position.z))
        if pending_chunk_loads.is_empty():
            call("process_streaming_structure_work")
            process_pending_chunk_prop_spawns()
        await startup_loading_yield("Drawing nearby terrain", "terrain_view_expansion", "pending", state.get("metrics", {}))
    return StartupReadinessResultScript.failed(
        "final_terrain_expansion_timeout",
        {},
        [],
        state.get("metrics", {}).merged({"timeoutSeconds": FINAL_TERRAIN_EXPANSION_TIMEOUT_SECONDS}, true)
    )

func begin_startup_loading_timeline() -> void:
    startup_loading_started_usec = Time.get_ticks_usec()
    startup_loading_last_step_usec = startup_loading_started_usec
    startup_loading_timeline.clear()
    startup_work_progress.reset()
    startup_readiness_domains.clear()
    startup_loading_failure_result.clear()
    startup_loading_max_step.clear()

func startup_loading_yield(message: String, domain := "general", status := "pending", metrics := {}) -> void:
    # Main/native processing can be disabled during staged seed reset. Keep
    # old publication work draining without dispatching against a partial world.
    if structure_system != null:
        structure_system.advance_citadel_publication()
    if streaming_active:
        apply_streaming_region_demand()
    # Local-light rigs can be published while the regular gameplay process is
    # disabled. Apply the same visibility and shadow budgets during loading so
    # newly prepared structures cannot turn a loading frame into an unbounded
    # omni-shadow render pass.
    if player != null:
        update_local_light_rig_lod(0.25)
    var now_usec := Time.get_ticks_usec()
    if startup_loading_started_usec <= 0:
        startup_loading_started_usec = now_usec
        startup_loading_last_step_usec = now_usec
    var normalized_domain := String(domain).strip_edges()
    if normalized_domain == "":
        normalized_domain = "general"
    var normalized_status := String(status).strip_edges()
    if normalized_status == "":
        normalized_status = "pending"
    var normalized_metrics: Dictionary = metrics.duplicate(true) if metrics is Dictionary else {}
    startup_work_progress.observe(normalized_domain, normalized_status, normalized_metrics, now_usec)
    var timeline_row := {
        "message": message,
        "domain": normalized_domain,
        "status": normalized_status,
        "metrics": normalized_metrics,
        "elapsedMs": float(now_usec - startup_loading_started_usec) / 1000.0,
        "stepMs": float(now_usec - startup_loading_last_step_usec) / 1000.0,
        "completedWorkRevision": startup_work_progress.completed_revision
    }
    if startup_loading_max_step.is_empty() \
        or float(timeline_row.get("stepMs", 0.0)) > float(startup_loading_max_step.get("stepMs", 0.0)):
        startup_loading_max_step = timeline_row.duplicate(true)
    startup_loading_timeline.append(timeline_row)
    startup_readiness_domains[normalized_domain] = timeline_row.duplicate(true)
    if startup_loading_timeline.size() > 256:
        startup_loading_timeline.pop_front()
    startup_loading_last_step_usec = now_usec
    startup_loading_step.emit(message)
    if startup_overlay != null:
        startup_overlay.set_message(message)
    if hud != null and hud.has_method("set_loading_message"):
        hud.set_loading_message(message)
    await get_tree().process_frame

func normalized_startup_result(value, fallback_reason: String) -> Dictionary:
    if shutdown_requested and (startup_loading_active or runtime_loading_active):
        return StartupReadinessResultScript.failed("startup_cancelled")
    if value is Dictionary:
        var result: Dictionary = value
        if bool(StartupReadinessResultScript.validate(result).get("ok", false)):
            return result.duplicate(true)
    return StartupReadinessResultScript.failed(fallback_reason, {}, [], {
        "invalidResultType": type_string(typeof(value))
    })

func startup_result_is_ready(value) -> bool:
    return value is Dictionary and String((value as Dictionary).get("status", "")) == StartupReadinessResultScript.STATUS_READY

func stop_startup_loading(result_value, fallback_reason := "startup_readiness_failed") -> void:
    var reason := apply_startup_loading_failure_state(result_value, fallback_reason)
    await startup_loading_yield(
        "Load failed: %s" % reason,
        "startup",
        "failed",
        startup_loading_failure_result.get("metrics", {})
    )

func apply_startup_loading_failure_state(result_value, fallback_reason := "startup_readiness_failed") -> String:
    var result := normalized_startup_result(result_value, fallback_reason)
    var reason := String(result.get("reason", fallback_reason)).strip_edges()
    if reason == "":
        reason = fallback_reason
        result["reason"] = reason
    var terrain_runtime=get("voxel_terrain_runtime")
    if terrain_runtime != null and is_instance_valid(terrain_runtime) \
            and terrain_runtime.has_method("abort_startup_auxiliary_publication_chunks"):
        terrain_runtime.call("abort_startup_auxiliary_publication_chunks")
    set_process(false)
    set_process_unhandled_input(false)
    set_physics_process(false)
    if player != null:
        player.velocity = Vector3.ZERO
        player.set_physics_process(false)
    set_registered_npc_physics_enabled(false)
    startup_loading_failure_result = result.duplicate(true)
    if startup_overlay != null:
        startup_overlay.set_message("Load failed: %s" % reason)
    startup_loading_active = false
    runtime_loading_active = false
    startup_loading_failed.emit(reason)
    return reason

func registered_npc_entries() -> Array:
    if npc_system == null or not (npc_system.get("npcs") is Array):
        return []
    return npc_system.get("npcs")

func set_registered_npc_physics_enabled(enabled: bool) -> void:
    # Bodies are moved by the shared execution service as well as their own
    # callbacks. Loading owns both gates; navigation preparation remains
    # available through the staged publication calls below.
    var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
    if autonomy is Node and is_instance_valid(autonomy):
        autonomy.set_physics_process(enabled)
    for entry_value in registered_npc_entries():
        if not (entry_value is Dictionary):
            continue
        var body := (entry_value as Dictionary).get("body") as Node
        if body != null and is_instance_valid(body):
            body.set_physics_process(enabled)

func startup_physics_gate_readiness() -> Dictionary:
    var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
    var autonomy_enabled: bool = autonomy is Node and is_instance_valid(autonomy) and autonomy.is_physics_processing()
    var enabled_npc_ids: Array[String] = []
    var registered_npc_count := 0
    for entry_value in registered_npc_entries():
        if not (entry_value is Dictionary):
            continue
        var entry: Dictionary = entry_value
        var body := entry.get("body") as Node
        if body == null or not is_instance_valid(body):
            continue
        registered_npc_count += 1
        if body.is_physics_processing():
            enabled_npc_ids.append(String(entry.get("id", "unknown")))
    var metrics := {
        "mainProcessEnabled": is_processing(),
        "mainInputEnabled": is_processing_unhandled_input(),
        "mainPhysicsEnabled": is_physics_processing(),
        "playerPhysicsEnabled": player != null and player.is_physics_processing(),
        "npcPhysicsEnabled": not enabled_npc_ids.is_empty(),
        "npcExecutionEnabled": autonomy_enabled,
        "enabledNpcIds": enabled_npc_ids,
        "registeredNpcCount": registered_npc_count,
        "diagnosticFastBoot": false
    }
    if player == null:
        return StartupReadinessResultScript.failed("missing_player_at_gameplay_physics_gate", {}, [], metrics)
    if bool(metrics.get("mainProcessEnabled", false)) \
        or bool(metrics.get("mainInputEnabled", false)) \
        or bool(metrics.get("mainPhysicsEnabled", false)) \
        or bool(metrics.get("playerPhysicsEnabled", false)) \
        or bool(metrics.get("npcExecutionEnabled", false)) \
        or bool(metrics.get("npcPhysicsEnabled", false)):
        return StartupReadinessResultScript.failed("gameplay_physics_enabled_before_readiness", {}, [], metrics)
    return StartupReadinessResultScript.ready({}, metrics)

func reinitialize_voxel_terrain_authority_staged() -> Dictionary:
    if shutdown_requested:
        return StartupReadinessResultScript.failed("startup_cancelled")
    var runtime = get("voxel_terrain_runtime")
    var reset_result := StartupReadinessResultScript.ready({}, {})
    if runtime == null or not is_instance_valid(runtime):
        if not has_method("ensure_voxel_terrain_authority") \
            or not bool(call("ensure_voxel_terrain_authority")):
            return StartupReadinessResultScript.failed("voxel_terrain_authority_initialization_failed", {}, [], {
                "seed": seed_text
            })
        runtime = get("voxel_terrain_runtime")
    elif not runtime.generation_context_current():
        if not runtime.has_method("reset_for_current_seed_staged"):
            return StartupReadinessResultScript.failed("voxel_terrain_seed_reset_api_missing", {}, [], {
                "expectedSeed": seed_text,
                "configuredSeed": String(runtime.get("configured_seed"))
            })
        reset_result = normalized_startup_result(
            await runtime.call("reset_for_current_seed_staged"),
            "invalid_voxel_terrain_seed_reset_result"
        )
        if not startup_result_is_ready(reset_result):
            return reset_result
    if runtime == null or not is_instance_valid(runtime) \
        or not bool(runtime.get("authority_ready")) \
        or String(runtime.get("configured_seed")) != seed_text:
        return StartupReadinessResultScript.failed("voxel_terrain_authority_seed_mismatch", {}, [], {
            "expectedSeed": seed_text,
            "configuredSeed": String(runtime.get("configured_seed")) if runtime != null else ""
        })
    return StartupReadinessResultScript.ready({}, {
        "seed": seed_text,
        "authorityReady": true,
        "reset": reset_result.get("metrics", {}) if reset_result is Dictionary else {}
    })

func bootstrap_initial_chunks_staged(urgent_radius := 1) -> Dictionary:
    if player == null:
        return StartupReadinessResultScript.failed("missing_player_for_terrain_readiness")
    var center := world_to_chunk(player.position.x, player.position.z)
    var urgent_keys := initial_gameplay_chunk_keys(urgent_radius)
    if urgent_keys.is_empty():
        return StartupReadinessResultScript.failed("missing_required_gameplay_chunks")
    # Initial deferred boot formerly created this authority lazily in create_chunk.
    # Source admission now precedes chunk creation, so initialize it first here.
    var authority_result: Dictionary = await reinitialize_voxel_terrain_authority_staged()
    if not startup_result_is_ready(authority_result):
        return authority_result
    var site_runtime = get("voxel_terrain_runtime")
    if site_runtime == null:
        return StartupReadinessResultScript.failed("missing_voxel_terrain_for_site_admission")
    world_streaming.configure("")
    if not regional_navigation.configure(self):
        return StartupReadinessResultScript.failed(regional_navigation.last_rejection)
    world_streaming.configure(seed_text, {"terrain":site_runtime, "structures":structure_system, "navigation":regional_navigation})
    streaming_requests.clear()
    streaming_request_bounds.clear()
    streaming_request_priorities.clear()
    streaming_request_foreground_tiles.clear()
    streaming_request_foreground_bounds.clear()
    streaming_request_peripheral_margins.clear()
    streaming_applied_revision = -1
    streaming_applied_source_revision = -1
    streaming_requested_source_revision = -1
    streaming_applied_view_revision = -1
    streaming_active = true
    streaming_player_cell = Vector2i(floori(player.global_position.x/(CELL*32.0)),floori(player.global_position.z/(CELL*32.0)))
    var foreground: Dictionary = player_foreground_streaming_intent()
    if foreground.is_empty():
        return StartupReadinessResultScript.failed("missing_player_foreground_streaming_geometry")
    if not retain_streaming_region("player", WorldStreamingCoordinatorScript.playable_bounds(player.global_position), 0,
            foreground.navigationTiles, foreground.bounds):
        return StartupReadinessResultScript.failed(streaming_demand_error)
    world_streaming.set_request_view_intent(int(streaming_requests.player),player_streaming_view_intent(player.global_position))
    # Keep existing scenario requirements in addition to the nearby player area.
    for key in urgent_keys:
        if not retain_streaming_region("startup:%s" % key, Rect2i(key*CHUNK_SIZE,Vector2i.ONE*CHUNK_SIZE), 1,
                [], Rect2i(), WorldStreamingCoordinatorScript.RELEASE_HYSTERESIS_MS, 0):
            return StartupReadinessResultScript.failed(streaming_demand_error)
    if not apply_streaming_region_demand():
        return StartupReadinessResultScript.failed(streaming_demand_error)
    var site_admission_result: Dictionary = await site_runtime.wait_for_site_admission(urgent_keys)
    if not startup_result_is_ready(site_admission_result):
        return site_admission_result
    for key in urgent_keys:
        if not chunks.has(key):
            queue_chunk_load(key)
    last_center_chunk = center
    var total := urgent_keys.size()
    var started_usec := Time.get_ticks_usec()
    while count_loaded_chunks(urgent_keys) < total:
        if shutdown_requested: return StartupReadinessResultScript.failed("startup_cancelled")
        # The ordinary player-view streamer may prune a distant scenario/NPC
        # chunk while Continue restores the player far from the tutorial town.
        # Startup still owns that explicit physical-readiness request. Keep it
        # retryable until publication instead of waiting on a queue entry that
        # no longer exists.
        var missing_rows: Array[Dictionary] = []
        for key in urgent_keys:
            if not chunks.has(key):
                var admission: Dictionary = site_runtime.admit_gameplay_chunk(key) \
                    if site_runtime != null else {}
                if String(admission.get("status", "pending")) == "failed":
                    return StartupReadinessResultScript.failed(
                        "initial_gameplay_chunk_site_admission_failed", {}, [key], {
                            "chunk": key,
                            "sourceReason": String(admission.get("reason", "terrain_site_admission_failed"))
                        }
                    )
                missing_rows.append({"key":key,"admissionStatus":String(admission.get("status","missing_runtime")),
                    "admissionReason":String(admission.get("reason","")),"queuedBeforeRetry":pending_chunk_loads.has(key)})
                queue_chunk_load(key)
        var loaded := count_loaded_chunks(urgent_keys)
        await startup_loading_yield("Loading terrain %d/%d" % [loaded, total], "terrain_chunks", "pending", {
            "loadedChunkCount": loaded,
            "requiredChunkCount": total
        })
        process_pending_chunk_loads(center)
        startup_chunk_loading_diagnostics = {"loadedChunkCount":count_loaded_chunks(urgent_keys),
            "requiredChunkCount":total,"missing":missing_rows,"pendingChunkLoads":pending_chunk_loads.size()}
        if float(Time.get_ticks_usec() - started_usec) / 1000000.0 >= INITIAL_READINESS_TIMEOUT_SECONDS:
            return StartupReadinessResultScript.failed("initial_gameplay_chunk_loading_timeout", {}, [], {
                "loadedChunkCount": count_loaded_chunks(urgent_keys),
                "requiredChunkCount": total,
                "timeoutSeconds": INITIAL_READINESS_TIMEOUT_SECONDS
            })
    startup_chunk_loading_diagnostics = {"loadedChunkCount":total,"requiredChunkCount":total,
        "missing":[],"pendingChunkLoads":pending_chunk_loads.size()}
    var collision_result := normalized_startup_result(
        await wait_for_initial_voxel_collision_publication(urgent_keys),
        "invalid_voxel_collision_readiness_result"
    )
    if not startup_result_is_ready(collision_result):
        return collision_result
    var player_collision_result := normalized_startup_result(
        await wait_for_initial_player_collision_publication(),
        "invalid_player_collision_readiness_result"
    )
    if not startup_result_is_ready(player_collision_result):
        return player_collision_result
    process_pending_chunk_prop_spawns()
    last_center_chunk = Vector2i(999999, 999999)
    var metrics := {
        "loadedChunkCount": total,
        "requiredChunkCount": total,
        "voxelCollision": collision_result.get("metrics", {}),
        "playerCollision": player_collision_result.get("metrics", {})
    }
    await startup_loading_yield("Terrain collision ready", "terrain_collision", "ready", metrics)
    return StartupReadinessResultScript.ready({}, metrics)

func initial_gameplay_chunk_keys(urgent_radius := 1) -> Array[Vector2i]:
    var unique := {}
    if player != null:
        for key in WorldStreamingCoordinatorScript.chunks_for_bounds(WorldStreamingCoordinatorScript.playable_bounds(player.position)):
            unique[key] = true
        var player_center := world_to_chunk(player.position.x, player.position.z)
        for dz in range(-urgent_radius, urgent_radius + 1):
            for dx in range(-urgent_radius, urgent_radius + 1):
                unique[Vector2i(player_center.x + dx, player_center.y + dz)] = true
    for entry_value in registered_npc_entries():
        if not (entry_value is Dictionary):
            continue
        var entry: Dictionary = entry_value
        if not npc_requires_physical_startup_streaming(entry):
            continue
        var body_value = entry.get("body")
        var body := body_value as Node3D if is_instance_valid(body_value) else null
        if body != null:
            unique[world_to_chunk(body.global_position.x, body.global_position.z)] = true
        for field in ["homePosition", "porchPosition", "doorPosition", "guardPosition"]:
            var position_value = entry.get(field, null)
            if position_value is Vector3:
                var position: Vector3 = position_value
                unique[world_to_chunk(position.x, position.z)] = true
        for field in ["homeCell", "porchCell", "doorCell", "guardCell"]:
            var cell_value = entry.get(field, null)
            if cell_value is Vector2i:
                var cell: Vector2i = cell_value
                unique[world_to_chunk(float(cell.x) * CELL, float(cell.y) * CELL)] = true
    var result: Array[Vector2i] = []
    for key_value in unique.keys():
        if key_value is Vector2i:
            result.append(key_value)
    result.sort_custom(func(a: Vector2i, b: Vector2i):
        return a.x < b.x if a.x != b.x else a.y < b.y
    )
    return result

## Startup must retain physical chunks for actors whose lifecycle has not fully
## transferred to abstract simulation. Requiring both facts to agree is
## deliberately fail-closed for restored or mid-transition NPC state.
func npc_requires_physical_startup_streaming(entry: Dictionary) -> bool:
    return String(entry.get("simulationLod", "active")) != "abstract" \
        or not bool(entry.get("abstractSimulated", false))

## The foreground request has two separate responsibilities: it proves the
## actual capsule is safe, and it tells asynchronous owners what must be ready
## before the capsule gets there. Publishing the raw one-cell capsule bounds
## as the request identity caused a full dependency-closure replacement every
## 1.35 metres, which repeatedly held the real player while the same nearby
## terrain reacquired its acknowledgement. Keep the proof exact elsewhere;
## make this ownership envelope stable at navigation-tile granularity and carry
## the short forecast inside it.
func player_foreground_streaming_intent(lead_position := Vector3.INF) -> Dictionary:
    if player == null or not is_instance_valid(player): return {}
    return foreground_streaming_intent_for_position(player.global_position,lead_position)

func foreground_streaming_intent_for_position(position: Vector3, lead_position := Vector3.INF) -> Dictionary:
    if player == null or not is_instance_valid(player): return {}
    var collider := player.get_node_or_null("PlayerCollider") as CollisionShape3D
    var capsule := collider.shape as CapsuleShape3D if collider != null else null
    if capsule == null or capsule.radius <= 0.0: return {}
    # Read the production capsule and engine contact margin. The XZ extent
    # accounts for any authored node scale without changing that authority.
    var transform := collider.global_transform
    var horizontal_scale := maxf(Vector2(transform.basis.x.x,transform.basis.z.x).length(),
        Vector2(transform.basis.x.z,transform.basis.z.z).length())
    var radius := capsule.radius * horizontal_scale + maxf(player.safe_margin,0.0)
    # Preserve the authored collider's horizontal offset while allowing a
    # destination to be retained before the player/camera is moved there.
    var center := position + (transform.origin-player.global_position)
    var low := Vector2i(floori((center.x-radius)/CELL),floori((center.z-radius)/CELL))
    var high := Vector2i(ceili((center.x+radius)/CELL),ceili((center.z+radius)/CELL))
    var capsule_bounds := Rect2i(low,high-low)
    if not WorldStreamingCoordinatorScript.valid_bounds(capsule_bounds): return {}
    var demand_bounds := capsule_bounds
    if lead_position.is_finite():
        var lead_low := Vector2i(floori((lead_position.x-radius)/CELL),floori((lead_position.z-radius)/CELL))
        var lead_high := Vector2i(ceili((lead_position.x+radius)/CELL),ceili((lead_position.z+radius)/CELL))
        demand_bounds = demand_bounds.merge(Rect2i(lead_low,lead_high-lead_low))
    # Navigation publication already owns 16x16-cell tiles. The aligned
    # envelope stays identical while the player crosses ordinary cells, and
    # the lead tile is requested before a sprint reaches its edge.
    var tile_low := Vector2i(floori(float(demand_bounds.position.x)/16.0),floori(float(demand_bounds.position.y)/16.0))
    var tile_high := Vector2i(floori(float(demand_bounds.end.x-1)/16.0),floori(float(demand_bounds.end.y-1)/16.0))
    var bounds := Rect2i(tile_low*16,(tile_high-tile_low+Vector2i.ONE)*16)
    if not WorldStreamingCoordinatorScript.valid_bounds(bounds): return {}
    var tiles: Array[Vector2i] = []
    for z in range(tile_low.y,tile_high.y+1):
        for x in range(tile_low.x,tile_high.x+1): tiles.append(Vector2i(x,z))
    return {"bounds":bounds,"capsuleBounds":capsule_bounds,"navigationTiles":tiles,"capsuleRadius":capsule.radius,
        "safeMargin":player.safe_margin,"radiusXZ":Vector2(radius,radius),"leadPosition":lead_position if lead_position.is_finite() else Vector3.INF}

func player_streaming_view_intent(predicted_position: Vector3) -> Dictionary:
    if player == null or not is_instance_valid(player): return {}
    var camera := player.get("camera") as Camera3D
    var origin := camera.global_position if camera != null and is_instance_valid(camera) else player.global_position
    var forward := -camera.global_basis.z if camera != null and is_instance_valid(camera) else -player.global_basis.z
    forward.y = 0.0
    var fov := camera.fov if camera != null and is_instance_valid(camera) else 72.0
    return GeneratedContentViewPriorityScript.normalize({
        "origin":origin,"forward":forward,"predictedOrigin":predicted_position,
        "horizontalFovDegrees":fov,"farDistance":GeneratedContentViewPriorityScript.DEFAULT_FAR_DISTANCE
    })

func retain_streaming_region(owner: String, bounds: Rect2i, priority: int, foreground_navigation_tiles: Array = [],
		foreground_bounds := Rect2i(), member_hysteresis_ms := WorldStreamingCoordinatorScript.RELEASE_HYSTERESIS_MS,
		peripheral_margin_cells := WorldStreamingCoordinatorScript.RENDER_CELL_SIZE) -> bool:
    if streaming_request_bounds.get(owner) == bounds and streaming_request_priorities.get(owner) == priority \
            and streaming_request_foreground_tiles.get(owner,[]) == foreground_navigation_tiles \
            and streaming_request_foreground_bounds.get(owner,Rect2i()) == foreground_bounds \
            and int(streaming_request_peripheral_margins.get(owner,WorldStreamingCoordinatorScript.RENDER_CELL_SIZE)) == peripheral_margin_cells: return true
    var request_id: int = int(streaming_requests.get(owner,0))
    if request_id > 0:
        if not world_streaming.replace_region(request_id,bounds,priority,owner,foreground_navigation_tiles,foreground_bounds,member_hysteresis_ms,peripheral_margin_cells):
            streaming_demand_error = world_streaming.last_rejection
            return false # Existing intent stays owned; the next update retries.
    else:
        request_id = world_streaming.request_region(bounds,priority,owner,foreground_navigation_tiles,foreground_bounds,member_hysteresis_ms,peripheral_margin_cells)
        if request_id == 0:
            streaming_demand_error = world_streaming.last_rejection
            return false
    streaming_requests[owner] = request_id
    streaming_request_bounds[owner] = bounds
    streaming_request_priorities[owner] = priority
    streaming_request_foreground_tiles[owner] = foreground_navigation_tiles.duplicate()
    if foreground_bounds.has_area(): streaming_request_foreground_bounds[owner] = foreground_bounds
    else: streaming_request_foreground_bounds.erase(owner)
    streaming_request_peripheral_margins[owner] = peripheral_margin_cells
    streaming_demand_error = ""
    return true

func apply_streaming_region_demand(advance_budget_usec := 4000) -> bool:
    var monitor = runtime_perf_monitor
    # Main/NPC processing is disabled while the loading screen owns startup.
    # Consume queued chunk/terrain navigation changes here through the same
    # bounded service used in gameplay, before publication evaluates a tile.
    if npc_system != null and npc_system.has_method("process_pending_navigation_changes"):
        npc_system.process_pending_navigation_changes()
    var advance_start: int = monitor.begin_section("streaming_coordinator_advance") if monitor != null else 0
    world_streaming.advance(-1, advance_budget_usec)
    if monitor != null:
        monitor.end_section("streaming_coordinator_advance", advance_start)
    var runtime = get("voxel_terrain_runtime")
    if structure_system == null or runtime == null: return false
    if streaming_applied_view_revision != world_streaming.view_revision():
        var view_start: int = monitor.begin_section("streaming_view_intent_handoff") if monitor != null else 0
        if not structure_system.citadel_publication.set_retained_view_intents(world_streaming.retained_view_intents()):
            streaming_demand_error = "structure_view_intent_rejected"
            return false
        streaming_applied_view_revision = world_streaming.view_revision()
        if monitor != null: monitor.end_section("streaming_view_intent_handoff",view_start)
    var source_start: int = monitor.begin_section("streaming_source_request_handoff") if monitor != null else 0
    var coordinator_ready: bool = world_streaming.advance_retained_source_snapshot(750,96)
    var source_requests_accepted := true
    if coordinator_ready:
        var source_revision: int = world_streaming.source_manifest_revision()
        if streaming_applied_source_revision != source_revision:
            if streaming_requested_source_revision != source_revision:
                if structure_system.citadel_publication.request_retained_source_requests(
                        source_revision,world_streaming.borrow_retained_source_snapshot()):
                    streaming_requested_source_revision = source_revision
                else:
                    source_requests_accepted = false
            var source_state: Dictionary = structure_system.citadel_publication.advance_retained_source_requests(750,96)
            if source_state.get("status") == "failed": source_requests_accepted = false
            elif source_state.get("status") == "ready" and int(source_state.get("revision",-1)) == source_revision:
                streaming_applied_source_revision = source_revision
                streaming_requested_source_revision = -1
                # Source ownership never carries scheduling-only view state.
                # Replay the current view only after the new owners exist.
                streaming_applied_view_revision = -1
    if monitor != null:
        var coordinator_metrics: Dictionary = world_streaming.source_snapshot_compile_metrics()
        var consumer_metrics: Dictionary = structure_system.citadel_publication.retained_source_request_compile_metrics()
        monitor.observe_gauge("streaming_source_coordinator_owner_units",float(coordinator_metrics.get("ownerUnits",0)))
        monitor.observe_gauge("streaming_source_coordinator_admission_units",float(coordinator_metrics.get("admissionUnits",0)))
        monitor.observe_gauge("streaming_source_coordinator_navigation_units",float(coordinator_metrics.get("navigationUnits",0)))
        monitor.observe_gauge("streaming_source_coordinator_binding_units",float(coordinator_metrics.get("bindingUnits",0)))
        monitor.observe_gauge("streaming_source_coordinator_group_units",float(coordinator_metrics.get("groupUnits",0)))
        monitor.observe_gauge("streaming_source_coordinator_phase",float([
            "idle","owner","admission","navigation","navigation_hash","site","groups",
            "foreground_groups","ready"].find(String(coordinator_metrics.get("phase","idle")))))
        monitor.observe_gauge("streaming_source_consumer_owner_units",float(consumer_metrics.get("ownerUnits",0)))
        monitor.observe_gauge("streaming_source_consumer_admission_units",float(consumer_metrics.get("admissionUnits",0)))
        monitor.observe_gauge("streaming_source_consumer_navigation_units",float(consumer_metrics.get("navigationUnits",0)))
        monitor.observe_gauge("streaming_source_consumer_binding_units",float(consumer_metrics.get("bindingUnits",0)))
        monitor.observe_gauge("streaming_source_consumer_group_units",float(consumer_metrics.get("groupUnits",0)))
        monitor.observe_gauge("streaming_source_consumer_phase",float([
            "idle","owner","admission","navigation","navigation_hash","discovery_priority","admission_hash",
            "site","groups","foreground_navigation","foreground_navigation_hash","foreground_groups",
            "foreground_group_heap","foreground_group_order","foreground_eligibility","ready"].find(String(consumer_metrics.get("phase","idle")))))
        monitor.observe_gauge("streaming_source_requested_revision",float(streaming_requested_source_revision))
        monitor.observe_gauge("streaming_source_applied_revision",float(streaming_applied_source_revision))
    if monitor != null:
        monitor.end_section("streaming_source_request_handoff", source_start)
    if not source_requests_accepted:
        streaming_demand_error = "structure_region_demand_rejected"
        return false
    if streaming_applied_revision != world_streaming.revision():
        var chunks_start: int = monitor.begin_section("streaming_chunk_request_handoff") if monitor != null else 0
        var retained: Dictionary = world_streaming.retained_gameplay_chunks()
        runtime.set_retained_gameplay_chunks(retained)
        for key: Vector2i in retained:
            if not chunks.has(key): queue_chunk_load(key)
        if monitor != null:
            monitor.end_section("streaming_chunk_request_handoff", chunks_start)
        streaming_applied_revision = world_streaming.revision()
    streaming_demand_error = ""
    return true

func streaming_source_handoff_complete() -> bool:
    if structure_system == null or not world_streaming.source_snapshot_ready(): return false
    var revision: int = world_streaming.source_manifest_revision()
    return streaming_applied_source_revision == revision \
        and structure_system.citadel_publication.retained_source_committed_revision() == revision

func update_streaming_region_demand() -> void:
    if not streaming_active or player == null: return
    var monitor = runtime_perf_monitor
    var intent_start: int = monitor.begin_section("streaming_player_intent") if monitor != null else 0
    # Quantized updates plus the extra 43.2m retention ring cover reversals
    # without rebuilding demand on every movement frame.
    var cell := Vector2i(floori(player.global_position.x/(CELL*32.0)),floori(player.global_position.z/(CELL*32.0)))
    var anchor := Vector3((float(cell.x)+0.5)*CELL*32.0,player.global_position.y,(float(cell.y)+0.5)*CELL*32.0)
    var movement := Vector3(player.velocity.x,0.0,player.velocity.z)
    var facing := -player.global_basis.z
    facing.y = 0.0
    facing = facing.normalized()
    var forecast := bounded_streaming_forecast_position(player.global_position,movement,facing)
    var current_foreground: Dictionary = player_foreground_streaming_intent()
    if current_foreground.is_empty():
        streaming_demand_error = "missing_player_foreground_streaming_geometry"
        return
    # The retained ring changes at the coarse cell boundary. Foreground tiles
    # track the actual capsule inside that ring, so startup and movement never
    # wait for its entire 64m publication closure.
    var player_bounds: Rect2i = WorldStreamingCoordinatorScript.playable_bounds(anchor).grow(16) if cell != streaming_player_cell \
        else streaming_request_bounds.get("player",WorldStreamingCoordinatorScript.playable_bounds(anchor).grow(16))
    # The established player request remains its completed safe base while the
    # player crosses normal cells. Replacing it only at the coarse retention
    # boundary keeps its acknowledged terrain alive during a foreground refresh.
    if cell != streaming_player_cell:
        if retain_streaming_region("player",player_bounds,0,current_foreground.navigationTiles,current_foreground.bounds):
            streaming_player_cell = cell
    var active_owners := {"player":true}
    active_owners["predicted_traversal"] = true
    if not streaming_loading_request_owner.is_empty() and streaming_requests.has(streaming_loading_request_owner):
        active_owners[streaming_loading_request_owner] = true
    # The independently retryable foreground request promotes the next actual
    # movement tile before the capsule reaches it. A pending forecast cannot
    # revoke the already-ready player request; the coordinator chooses the
    # completed enclosing request until this one is acknowledged.
    var forecast_foreground: Dictionary = player_foreground_streaming_intent(forecast)
    if forecast_foreground.is_empty():
        streaming_demand_error = "missing_player_forecast_streaming_geometry"
    else:
        var forecast_retained := retain_streaming_region("predicted_traversal",forecast_foreground.bounds,0,
            forecast_foreground.navigationTiles,forecast_foreground.bounds,0)
        # The bounded forecast already has an admitted retained request. Hand its
        # scheduling-only corridor to the one native terrain viewer so its collision
        # work can lead the player without creating a second terrain authority.
        var terrain_runtime = get("voxel_terrain_runtime")
        if forecast_retained and terrain_runtime != null and terrain_runtime.has_method("set_foreground_collision_demand"):
            terrain_runtime.call("set_foreground_collision_demand",player.global_position,forecast)
    var view_intent := player_streaming_view_intent(forecast)
    for owner in ["player","predicted_traversal"]:
        var request_id := int(streaming_requests.get(owner,0))
        if request_id>0 and not world_streaming.set_request_view_intent(request_id,view_intent):
            streaming_demand_error=world_streaming.last_rejection
    if monitor != null:
        monitor.end_section("streaming_player_intent", intent_start)
    var actors_start: int = monitor.begin_section("streaming_actor_intents") if monitor != null else 0
    var npc_autonomy = npc_system.get("autonomy_system") if npc_system != null else null
    var physical_actor_rows: Array[Dictionary] = []
    for entry in registered_npc_entries():
        if npc_autonomy != null and npc_autonomy.has_method("requires_physical_streaming") \
                and not bool(npc_autonomy.requires_physical_streaming(entry)):
            continue
        var body = entry.get("body") if entry is Dictionary else null
        if not is_instance_valid(body) or not body.is_inside_tree(): continue
        physical_actor_rows.append({
            "actorId": String(entry.get("id", "")),
            "bodyInstanceId": body.get_instance_id(),
            "chunk": world_to_chunk(body.global_position.x,body.global_position.z)
        })
    var actor_demand: Dictionary = ActorPhysicalStreamingDemandScript.aggregate(physical_actor_rows)
    streaming_actor_physical_demand_diagnostics = actor_demand.duplicate(true)
    for group_value in actor_demand.get("groups", []):
        var group: Dictionary = group_value
        var key := String(group.get("owner", ""))
        var chunk: Vector2i = group.get("chunk", Vector2i.ZERO)
        if key == "": continue
        active_owners[key] = true
        retain_streaming_region(key,Rect2i(chunk*CHUNK_SIZE,Vector2i.ONE*CHUNK_SIZE),1,
            [],Rect2i(),WorldStreamingCoordinatorScript.RELEASE_HYSTERESIS_MS,0)
    if monitor != null:
        monitor.observe_gauge("streaming_physical_actor_count",float(actor_demand.get("actorCount",0)))
        monitor.observe_gauge("streaming_physical_actor_owner_count",float(actor_demand.get("ownerCount",0)))
    if monitor != null:
        monitor.end_section("streaming_actor_intents", actors_start)
    var releases_start: int = monitor.begin_section("streaming_owner_releases") if monitor != null else 0
    for owner in streaming_requests.keys():
        if active_owners.has(owner): continue
        world_streaming.release_region(streaming_requests[owner])
        streaming_requests.erase(owner)
        streaming_request_bounds.erase(owner)
        streaming_request_priorities.erase(owner)
        streaming_request_foreground_tiles.erase(owner)
        streaming_request_foreground_bounds.erase(owner)
        streaming_request_peripheral_margins.erase(owner)
    if monitor != null:
        monitor.end_section("streaming_owner_releases", releases_start)
    var advance_budget_usec := 4000
    if gameplay_publication_deadline_usec > 0:
        advance_budget_usec = 0
        if gameplay_publication_lane == 0:
            advance_budget_usec = mini(
                GAMEPLAY_REGIONAL_NAVIGATION_BUDGET_USEC,
                maxi(0, gameplay_publication_deadline_usec - Time.get_ticks_usec())
            )
    apply_streaming_region_demand(advance_budget_usec)

## The broad player request already retains a 64 m playable radius plus its
## coarse-cell margin. Forecasting only needs to promote the next navigation
## tile; multiplying sprint velocity by eight seconds retained a moving corridor
## hundreds of metres long and repeatedly rebuilt terrain/navigation far ahead.
func bounded_streaming_forecast_position(position: Vector3, movement: Vector3, facing: Vector3) -> Vector3:
    var horizontal_movement := Vector3(movement.x,0.0,movement.z)
    var horizontal_facing := Vector3(facing.x,0.0,facing.z).normalized()
    var direction := horizontal_movement.normalized() if horizontal_movement.length_squared()>=0.1 else horizontal_facing
    if direction.length_squared()<=0.0: return position
    var lead_metres := minf(CELL*STREAMING_FORECAST_MAX_CELLS,
        horizontal_movement.length()*STREAMING_FORECAST_SECONDS) if horizontal_movement.length_squared()>=0.1 \
        else minf(CELL*STREAMING_FORECAST_MAX_CELLS,PlayerController.WALK_SPEED*STREAMING_STATIONARY_FORECAST_SECONDS)
    return position+direction*lead_metres

## Navigation capture consumes authoritative terrain facts. Refuse to start a
## tile while its gameplay terrain/collision publication is incomplete, so a
## later chunk-loaded revision cannot invalidate and restart the same capture.
func navigation_terrain_publication_readiness(bounds: Rect2i) -> Dictionary:
    var runtime = get("voxel_terrain_runtime")
    if runtime==null or not is_instance_valid(runtime) or not runtime.has_method("region_publication_readiness"):
        return {"status":"pending","reason":"navigation_terrain_owner_unavailable"}
    return runtime.region_publication_readiness(bounds)

func reset_streaming_region_demand() -> void:
    streaming_active = false
    streaming_actor_physical_demand_diagnostics = {"actorCount":0,"ownerCount":0,"groups":[]}
    if structure_system != null and structure_system.citadel_publication != null:
        structure_system.citadel_publication.cancel_retained_source_request_compile()
    world_streaming.configure("")
    streaming_requests.clear()
    streaming_request_bounds.clear()
    streaming_request_priorities.clear()
    streaming_request_foreground_tiles.clear()
    streaming_request_foreground_bounds.clear()
    streaming_request_peripheral_margins.clear()
    streaming_applied_revision = -1
    streaming_applied_source_revision = -1
    streaming_requested_source_revision = -1
    streaming_applied_view_revision = -1
    var runtime = get("voxel_terrain_runtime")
    if runtime != null: runtime.clear_retained_gameplay_chunks()

func wait_for_initial_terrain_presentation() -> Dictionary:
    var runtime = get("voxel_terrain_runtime")
    if not is_instance_valid(runtime) or player == null:
        return StartupReadinessResultScript.failed("missing_terrain_presentation_authority")
    return normalized_startup_result(
        await runtime.wait_for_spawn_presentation(player.global_position, INITIAL_READINESS_TIMEOUT_SECONDS),
        "invalid_terrain_presentation_result"
    )

func wait_for_initial_region_readiness() -> Dictionary:
    if not streaming_active or not streaming_request_bounds.has("player") or not streaming_request_foreground_bounds.has("player"):
        return StartupReadinessResultScript.failed("initial_region_demand_missing")
    var started := Time.get_ticks_msec()
    var state: Dictionary = {}
    while float(Time.get_ticks_msec()-started)/1000.0 < INITIAL_READINESS_TIMEOUT_SECONDS:
        if shutdown_requested: return StartupReadinessResultScript.failed("startup_cancelled")
        if not apply_streaming_region_demand():
            return StartupReadinessResultScript.failed(streaming_demand_error)
        process_pending_chunk_loads(world_to_chunk(player.position.x,player.position.z))
        if pending_chunk_loads.is_empty():
            call("process_streaming_structure_work")
            process_pending_chunk_prop_spawns()
        state = world_streaming.region_readiness(streaming_request_foreground_bounds.player,int(streaming_requests.get("player",-1)))
        if state.status == "ready" and streaming_source_handoff_complete():
            await startup_loading_yield("Nearby world ready", "initial_region", "ready", state)
            return StartupReadinessResultScript.ready({}, state)
        if state.status == "failed":
            return StartupReadinessResultScript.failed("initial_region_dependency_failed", {}, state.get("missing",[]), state)
        var progress := {"bounds":state.get("bounds"), "closedBounds":state.get("closedBounds"),
            "status":state.status, "missing":state.get("missing",[]), "domains":{},
            "coordinatorMaxAdvanceUsec":world_streaming.max_advance_usec,
            "navigationQueue":regional_navigation._stats(),
            "terrainRetainedReason":get("voxel_terrain_runtime").retained_activation_reason}
        for domain in state.get("domains",{}):
            var owner: Dictionary = state.domains[domain]
            progress.domains[domain] = {"status":owner.get("status"),"reason":owner.get("reason"),
                "missingChunks":owner.get("missingChunks",[]).size(),
                "missingItems":owner.get("missing",[]).size(),
                "unresolvedCrossings":owner.get("unresolvedCrossingIds",[]).size()}
        await startup_loading_yield("Preparing nearby world", "initial_region", "pending", progress)
    return StartupReadinessResultScript.failed("initial_region_readiness_timeout", {}, state.get("missing",[]), state)

func wait_for_initial_region_physical_readiness() -> Dictionary:
    if not streaming_active or not streaming_request_bounds.has("player") or not streaming_request_foreground_bounds.has("player"):
        return StartupReadinessResultScript.failed("initial_region_demand_missing")
    var started := Time.get_ticks_msec()
    var state: Dictionary = {}
    while float(Time.get_ticks_msec()-started)/1000.0 < INITIAL_READINESS_TIMEOUT_SECONDS:
        if shutdown_requested: return StartupReadinessResultScript.failed("startup_cancelled")
        if not apply_streaming_region_demand():
            return StartupReadinessResultScript.failed(streaming_demand_error)
        process_pending_chunk_loads(world_to_chunk(player.position.x,player.position.z))
        if pending_chunk_loads.is_empty():
            call("process_streaming_structure_work")
            process_pending_chunk_prop_spawns()
        state = world_streaming.initial_physical_readiness(
            streaming_request_foreground_bounds.player,
            int(streaming_requests.get("player",-1))
        )
        if state.status == "ready" and streaming_source_handoff_complete():
            await startup_loading_yield("Nearby terrain and structures ready", "initial_region_physical", "ready", state)
            return StartupReadinessResultScript.ready({}, state)
        if state.status == "failed":
            return StartupReadinessResultScript.failed("initial_region_physical_dependency_failed", {}, state.get("missing",[]), state)
        var progress := {"bounds":state.get("bounds"), "closedBounds":state.get("closedBounds"),
            "status":state.status, "missing":state.get("missing",[]), "domains":{},
            "coordinatorMaxAdvanceUsec":world_streaming.max_advance_usec,
            "terrainRetainedReason":get("voxel_terrain_runtime").retained_activation_reason}
        for domain in state.get("domains",{}):
            var owner: Dictionary = state.domains[domain]
            progress.domains[domain] = {"status":owner.get("status"),"reason":owner.get("reason"),
                "missingChunks":owner.get("missingChunks",[]).size(),
                "missingItems":owner.get("missing",[]).size(),
                "unresolvedCrossings":owner.get("unresolvedCrossingIds",[]).size()}
        await startup_loading_yield("Preparing nearby terrain and structures", "initial_region_physical", "pending", progress)
    return StartupReadinessResultScript.failed("initial_region_physical_readiness_timeout", {}, state.get("missing",[]), state)

func wait_for_initial_voxel_collision_publication(chunk_keys: Array[Vector2i]) -> Dictionary:
    var runtime = get("voxel_terrain_runtime")
    if runtime == null or not is_instance_valid(runtime) or not runtime.has_method("gameplay_chunks_published"):
        return StartupReadinessResultScript.failed("missing_voxel_collision_publication_authority")
    if runtime.has_method("configure_startup_collision_bounds"):
        # Navigation priming below includes every registered actor's ordinary
        # home/porch route, even when that dormant actor does not require a
        # gameplay chunk container at the restored player position. Native
        # terrain coverage must include those same endpoints long enough to
        # apply their authoritative town edits before snapshot publication.
        runtime.call("configure_startup_collision_bounds", chunk_keys, initial_navigation_terrain_chunk_keys())
    var started_usec := Time.get_ticks_usec()
    while true:
        if shutdown_requested: return StartupReadinessResultScript.failed("startup_cancelled")
        if runtime.has_method("secondary_viewer_admission_failure"):
            var admission_failure_value = runtime.call("secondary_viewer_admission_failure")
            if admission_failure_value is Dictionary and not (admission_failure_value as Dictionary).is_empty():
                var admission_failure: Dictionary = admission_failure_value
                return StartupReadinessResultScript.failed(
                    "startup_auxiliary_terrain_admission_failed", {}, [], {
                        "admissionFailure": admission_failure.duplicate(true)
                    }
                )
        if bool(runtime.call("gameplay_chunks_published", chunk_keys)):
            break
        var published := int(runtime.call("published_gameplay_chunk_count", chunk_keys))
        await startup_loading_yield("Loading terrain collision %d/%d" % [published, chunk_keys.size()], "terrain_collision", "pending", {
            "publishedChunkCount": published,
            "requiredChunkCount": chunk_keys.size()
        })
        if float(Time.get_ticks_usec() - started_usec) / 1000000.0 >= INITIAL_READINESS_TIMEOUT_SECONDS:
            var diagnostics := {}
            if runtime.has_method("gameplay_publication_diagnostics"):
                diagnostics = runtime.call("gameplay_publication_diagnostics", chunk_keys)
            return StartupReadinessResultScript.failed("voxel_collision_publication_timeout", {}, [], {
                "publishedChunkCount": published,
                "requiredChunkCount": chunk_keys.size(),
                "timeoutSeconds": INITIAL_READINESS_TIMEOUT_SECONDS,
                "diagnostics": diagnostics
            })
    var diagnostics := {}
    if runtime.has_method("gameplay_publication_diagnostics"):
        diagnostics = runtime.call("gameplay_publication_diagnostics", chunk_keys)
    return StartupReadinessResultScript.ready({}, {
        "publishedChunkCount": chunk_keys.size(),
        "requiredChunkCount": chunk_keys.size(),
        "publicationElapsedMs": float(Time.get_ticks_usec() - started_usec) / 1000.0,
        "diagnostics": diagnostics
    })


func wait_for_initial_player_collision_publication() -> Dictionary:
    var runtime = get("voxel_terrain_runtime")
    if runtime == null or not is_instance_valid(runtime) or player == null:
        return StartupReadinessResultScript.failed("missing_player_collision_proof_authority")
    var proof_method := "collision_mesh_ready_for_body_position" \
        if runtime.has_method("collision_mesh_ready_for_body_position") else "collision_proof_for_world_position"
    if not runtime.has_method(proof_method):
        return StartupReadinessResultScript.failed("missing_player_collision_proof_authority")
    var started_usec := Time.get_ticks_usec()
    var footprint_radius := 0.35
    var acknowledged_scene_ids: Array = []
    while true:
        if shutdown_requested: return StartupReadinessResultScript.failed("startup_cancelled")
        # Collision proof is allowed to wait only for the geometry occupied by
        # the real player capsule.  This explicit dispatch is the counterpart
        # to the drain-only startup yield below: without it, an unstarted
        # foreground packet can remain pending forever while loading merely
        # observes its missing receipt.
        var foreground: Dictionary = player_foreground_streaming_intent()
        if foreground.is_empty() or not foreground.get("bounds") is Rect2i:
            return StartupReadinessResultScript.failed("missing_player_foreground_streaming_geometry")
        var publication_bounds: Rect2i = foreground.bounds
        if structure_system != null:
            structure_system.advance_citadel_publication(publication_bounds, true)
        var proof: Dictionary = runtime.call(proof_method, player.global_position, footprint_radius)
        if bool(proof.get("passed", false)) and structure_system != null:
            var publication: Dictionary = structure_system.citadel_physical_publication_state(publication_bounds)
            proof["structurePublication"] = publication
            if publication.status == "failed":
                return StartupReadinessResultScript.failed("player_landmark_publication_failed", {}, [], {"proof":proof})
            if publication.status != "ready":
                proof["passed"] = false
                proof["reason"] = publication.reason
            elif publication.get("required",false):
                if publication.sceneInstanceIds != acknowledged_scene_ids:
                    if float(Time.get_ticks_usec() - started_usec) / 1000000.0 >= INITIAL_READINESS_TIMEOUT_SECONDS:
                        return StartupReadinessResultScript.failed("player_collision_publication_timeout", {}, [], {"timeoutSeconds":INITIAL_READINESS_TIMEOUT_SECONDS,"lastProof":proof})
                    await get_tree().physics_frame
                    await startup_loading_yield("Checking landmark collision at player spawn")
                    acknowledged_scene_ids = publication.sceneInstanceIds.duplicate()
                    continue
                var clearance: Dictionary = GeneratedStructurePlayerClearanceScript.inspect(player)
                proof["playerCapsuleClearance"] = clearance
                if not clearance.passed:
                    return StartupReadinessResultScript.failed("player_landmark_capsule_not_clear", {}, [], {"proof":proof})
        if bool(proof.get("passed", false)):
            player.set_meta("startup_terrain_collision_proof", proof)
            return StartupReadinessResultScript.ready({}, {
                "playerCollisionPassed": true,
                "proofMethod": proof_method,
                "proof": proof
            })
        await startup_loading_yield("Loading buildings at player spawn" if proof.has("structurePublication") else "Loading terrain collision at player spawn", "terrain_collision", "pending", {
            "playerCollisionPassed": false,
            "proofMethod": proof_method,
            "proofReason": String(proof.get("reason", "pending"))
        })
        if float(Time.get_ticks_usec() - started_usec) / 1000000.0 >= INITIAL_READINESS_TIMEOUT_SECONDS:
            return StartupReadinessResultScript.failed("player_collision_publication_timeout", {}, [], {
                "timeoutSeconds": INITIAL_READINESS_TIMEOUT_SECONDS,
                "lastProof": proof
            })
    return StartupReadinessResultScript.failed("player_collision_publication_loop_ended")



func count_loaded_chunks(keys: Array[Vector2i]) -> int:
    var count := 0
    for key in keys:
        if chunks.has(key):
            count += 1
    return count

func drain_initial_navigation_changes_staged() -> Dictionary:
    if npc_system == null:
        return StartupReadinessResultScript.failed("missing_npc_system_for_navigation_readiness")
    var entries := registered_npc_entries()
    if entries.is_empty():
        return StartupReadinessResultScript.ready({}, {
            "registeredNpcCount": 0,
            "processedEventCount": 0,
            "remainingEventCount": 0
        })
    var autonomy = npc_system.get("autonomy_system")
    if autonomy == null or not autonomy.has_method("process_navigation_changes"):
        return StartupReadinessResultScript.failed("missing_navigation_change_processor")
    if not autonomy.has_method("pending_navigation_change_count"):
        return StartupReadinessResultScript.failed("missing_navigation_change_readiness_query")
    var iterations := 0
    var processed_event_count := 0
    var started_usec := Time.get_ticks_usec()
    while true:
        if shutdown_requested: return StartupReadinessResultScript.failed("startup_cancelled")
        var pending := int(autonomy.call("pending_navigation_change_count"))
        if pending <= 0:
            var metrics := {
                "registeredNpcCount": entries.size(),
                "iterationCount": iterations,
                "processedEventCount": processed_event_count,
                "remainingEventCount": 0
            }
            await startup_loading_yield("Navigation changes ready", "navigation_changes", "ready", metrics)
            return StartupReadinessResultScript.ready({}, metrics)
        if float(Time.get_ticks_usec() - started_usec) / 1000000.0 >= INITIAL_READINESS_TIMEOUT_SECONDS:
            return StartupReadinessResultScript.failed("navigation_change_drain_timeout", {}, [], {
                "registeredNpcCount": entries.size(),
                "iterationCount": iterations,
                "processedEventCount": processed_event_count,
                "remainingEventCount": pending,
                "timeoutSeconds": INITIAL_READINESS_TIMEOUT_SECONDS
            })
        await startup_loading_yield("Preparing navigation changes %d" % pending, "navigation_changes", "pending", {
            "registeredNpcCount": entries.size(),
            "iterationCount": iterations,
            "processedEventCount": processed_event_count,
            "remainingEventCount": pending
        })
        var processed_value = autonomy.call("process_navigation_changes", INITIAL_NAV_CHANGE_DRAIN_EVENT_LIMIT, -1)
        if processed_value is Array:
            processed_event_count += (processed_value as Array).size()
        iterations += 1
    return StartupReadinessResultScript.failed("navigation_change_drain_loop_ended")

func prime_initial_navigation_snapshot_staged() -> Dictionary:
    if npc_system == null:
        return StartupReadinessResultScript.failed("missing_npc_system_for_navigation_snapshot")
    var pathing = npc_system.get("pathing")
    var navigation_world = pathing.get("navigation_world") if pathing != null else null
    if navigation_world == null or not navigation_world.has_method("build_snapshot"):
        return StartupReadinessResultScript.failed("missing_generated_navigation_world")
    var entries: Array = registered_npc_entries()
    if entries.is_empty():
        return StartupReadinessResultScript.ready({}, {
            "registeredNpcCount": 0,
            "publishedTileCount": 0,
            "navigationMapReady": false,
            "reason": "no_registered_npcs"
        })
    var entry := {}
    if not entries.is_empty() and entries[0] is Dictionary:
        entry = entries[0]
    await startup_loading_yield("Preparing NPC navigation snapshot", "navigation_snapshot", "pending", {
        "registeredNpcCount": entries.size()
    })
    var snapshot_value = navigation_world.call("build_snapshot", entry, true, false)
    if not (snapshot_value is Dictionary) or (snapshot_value as Dictionary).is_empty():
        return StartupReadinessResultScript.failed("initial_navigation_snapshot_empty", {}, [], {
            "registeredNpcCount": entries.size()
        })
    var tile_wait_started_usec := Time.get_ticks_usec()
    var tile_result := normalized_startup_result(
        await prime_initial_navigation_tiles_staged(navigation_world, entries),
        "invalid_navigation_tile_readiness_result"
    )
    while tile_result.get("status") == "pending" and float(Time.get_ticks_usec()-tile_wait_started_usec)/1000000.0 < INITIAL_READINESS_TIMEOUT_SECONDS:
        if shutdown_requested: return StartupReadinessResultScript.failed("startup_cancelled")
        await startup_loading_yield("Waiting for current navigation revisions", "navigation_tiles", "pending", tile_result.get("metrics", {}))
        tile_result = normalized_startup_result(await prime_initial_navigation_tiles_staged(navigation_world, entries), "invalid_navigation_tile_readiness_result")
    if not startup_result_is_ready(tile_result):
        return tile_result
    var map_result := normalized_startup_result(
        await wait_for_initial_navigation_map_readiness(),
        "invalid_navigation_map_readiness_result"
    )
    if not startup_result_is_ready(map_result):
        return map_result
    var metrics := {
        "registeredNpcCount": entries.size(),
        "snapshotRevision": String((snapshot_value as Dictionary).get("revision", "")),
        "tiles": tile_result.get("metrics", {}),
        "navigationMap": map_result.get("metrics", {})
    }
    await startup_loading_yield("NPC navigation ready", "navigation_snapshot", "ready", metrics)
    return StartupReadinessResultScript.ready({}, metrics)

func initial_navigation_route_delegate():
    if npc_system == null:
        return null
    var pathing = npc_system.get("pathing")
    if pathing == null:
        return null
    var coordinator = pathing.get("coordinator")
    if coordinator == null:
        return null
    return coordinator.get("route_delegate")

func publish_startup_navmesh_tile(navigation_world, route_delegate, tile_key: String) -> Dictionary:
    if navigation_world == null or route_delegate == null or tile_key == "":
        return { "ok": false, "reason": "missing_navigation_tile_publication_input" }
    if not navigation_world.has_method("build_navmesh_tile_snapshot"):
        return { "ok": false, "reason": "navigation_tile_snapshot_api_missing" }
    var navmesh_world = route_delegate.get("navmesh_world")
    if navmesh_world == null or not navmesh_world.has_method("register_tile_snapshot"):
        return { "ok": false, "reason": "navmesh_tile_registration_api_missing" }
    var snapshot_started_usec := Time.get_ticks_usec()
    var snapshot: Dictionary = navigation_world.call("build_navmesh_tile_snapshot", tile_key)
    var snapshot_ms := float(Time.get_ticks_usec() - snapshot_started_usec) / 1000.0
    if snapshot.is_empty():
        return { "ok": false, "reason": "empty_navigation_tile_snapshot", "snapshotMs": snapshot_ms }
    if String(snapshot.get("publicationStatus", "ready")) != "ready":
        return {"ok":false,"status":snapshot.get("publicationStatus","pending"),"reason":snapshot.get("reason","navigation_source_pending"),"snapshotMs":snapshot_ms}
    var register_started_usec := Time.get_ticks_usec()
    var result: Dictionary = navmesh_world.call("register_tile_snapshot", snapshot)
    var register_ms := float(Time.get_ticks_usec() - register_started_usec) / 1000.0
    if String(result.get("status", "")) in ["pending", "failed", "rejected"]:
        return {"ok":false,"status":"failed" if result.status == "rejected" else result.status,
            "reason":result.get("reason","navigation_publication_pending"),"snapshotMs":snapshot_ms,"registerMs":register_ms}
    var sync_ms := 0.0
    if navmesh_world.has_method("sync_navigation_map_if_dirty"):
        var sync_started_usec := Time.get_ticks_usec()
        navmesh_world.call("sync_navigation_map_if_dirty")
        sync_ms = float(Time.get_ticks_usec() - sync_started_usec) / 1000.0
    var source_key := String(snapshot.get("sourceKey", ""))
    if source_key == "" or not navigation_world.has_method("navmesh_tile_source_key_for_tile") or not navmesh_world.has_method("tile_publication_readiness"):
        return { "ok": false, "status": "failed", "reason": "navigation_publication_receipt_missing" }
    var current_source_key := String(navigation_world.call("navmesh_tile_source_key_for_tile", tile_key))
    var receipt: Dictionary = navmesh_world.call("tile_publication_readiness", tile_key, current_source_key)
    var status := String(receipt.get("status", "pending"))
    return {
        "ok": status == "ready" and bool(receipt.get("completeSurfaceCoverage", false)) and source_key == current_source_key,
        "status": status,
        "reason": String(receipt.get("reason", "")),
        "receipt": navigation_publication_observation(receipt),
        "registration": {"status": result.get("status", ""), "installed": result.get("installed", false)},
        "snapshotMs": snapshot_ms,
        "registerMs": register_ms,
        "syncMs": sync_ms
    }

func navigation_publication_observation(receipt: Dictionary) -> Dictionary:
    # Canonical descriptor bindings remain at the owner. Keep loading telemetry
    # compact instead of copying full geometry signatures into every step.
    var observation := receipt.duplicate(false)
    observation["signature"] = String(receipt.get("signature", "")).sha256_text()
    observation["signatureEncoding"] = "sha256_of_descriptor_stable_signature"
    return observation

func prime_initial_navigation_tiles_staged(navigation_world, entries: Array) -> Dictionary:
    if not NpcConstantsScript.NPC_NAV_ENABLE_STARTUP_TILE_PRIMING:
        return StartupReadinessResultScript.failed("startup_navigation_tile_priming_disabled")
    if navigation_world == null:
        return StartupReadinessResultScript.failed("missing_navigation_world_for_tile_publication")

    var route_delegate = initial_navigation_route_delegate()
    if route_delegate == null:
        return StartupReadinessResultScript.failed("missing_navigation_route_delegate")
    var navmesh_world = route_delegate.get("navmesh_world")
    if navmesh_world == null or not navmesh_world.has_method("tile_region_status"):
        return StartupReadinessResultScript.failed("missing_navmesh_tile_publication_authority")

    var tile_keys := {}
    for entry_value in entries:
        if tile_keys.size() >= INITIAL_NAVMESH_PRIME_TILE_LIMIT:
            break
        if entry_value is Dictionary:
            prime_navigation_tiles_for_entry(navigation_world, entry_value, tile_keys)

    var keys: Array = tile_keys.keys()
    keys.sort()
    var total := mini(keys.size(), INITIAL_NAVMESH_PRIME_TILE_LIMIT)
    if total <= 0:
        return StartupReadinessResultScript.failed("no_startup_navigation_tiles_derived", {}, [], {
            "registeredNpcCount": entries.size()
        })
    var published := 0
    var tile_timings: Array[Dictionary] = []
    var publication_started_usec := Time.get_ticks_usec()
    for tile_key_value in keys:
        if published >= INITIAL_NAVMESH_PRIME_TILE_LIMIT:
            break
        var tile_key := String(tile_key_value)
        await startup_loading_yield("Preparing NPC route tiles %d/%d" % [published, total], "navigation_tiles", "pending", {
            "publishedTileCount": published,
            "requiredTileCount": total,
            "tileKey": tile_key
        })
        var publish_result: Dictionary = publish_startup_navmesh_tile(navigation_world, route_delegate, tile_key)
        while String(publish_result.get("status", "")) == "pending" and float(Time.get_ticks_usec()-publication_started_usec)/1000000.0 < INITIAL_READINESS_TIMEOUT_SECONDS:
            if shutdown_requested: return StartupReadinessResultScript.failed("startup_cancelled")
            await startup_loading_yield("Waiting for navigation publication", "navigation_tiles", "pending", {"tileKey": tile_key, "publication": publish_result})
            publish_result = publish_startup_navmesh_tile(navigation_world, route_delegate, tile_key)
        tile_timings.append({
            "tileKey": tile_key,
            "snapshotMs": float(publish_result.get("snapshotMs", 0.0)),
            "registerMs": float(publish_result.get("registerMs", 0.0)),
            "syncMs": float(publish_result.get("syncMs", 0.0))
        })
        if not bool(publish_result.get("ok", false)):
            return StartupReadinessResultScript.failed("startup_navigation_tile_publication_failed", {}, [], {
                "publishedTileCount": published,
                "requiredTileCount": total,
                "failedTileKey": tile_key,
                "tileStatus": navmesh_world.call("tile_region_status", tile_key),
                "publish": publish_result
            })
        var tile_status: Dictionary = navmesh_world.call("tile_region_status", tile_key)
        if not bool(tile_status.get("installed", false)) or bool(tile_status.get("dirty", false)):
            return StartupReadinessResultScript.failed("startup_navigation_tile_not_installed", {}, [], {
                "publishedTileCount": published,
                "requiredTileCount": total,
                "failedTileKey": tile_key,
                "tileStatus": tile_status
            })
        published += 1
    var publication_receipts: Array[Dictionary] = []
    for tile_key_value in keys.slice(0, total):
        var tile_key := String(tile_key_value)
        var current_key := String(navigation_world.call("navmesh_tile_source_key_for_tile", tile_key))
        var receipt: Dictionary = navmesh_world.call("tile_publication_readiness", tile_key, current_key)
        if receipt.get("status") != "ready" or not bool(receipt.get("completeSurfaceCoverage", false)):
            return StartupReadinessResultScript.pending("startup_navigation_revision_changed", {}, [tile_key], {"publication": navigation_publication_observation(receipt)})
        publication_receipts.append(navigation_publication_observation(receipt))
    var metrics := {
        "publishedTileCount": published,
        "requiredTileCount": total,
        "tileKeys": keys.slice(0, total),
        "tileTimings": tile_timings,
        "publicationReceipts": publication_receipts
    }
    await startup_loading_yield("NPC route tiles ready", "navigation_tiles", "ready", metrics)
    return StartupReadinessResultScript.ready({}, metrics)

func wait_for_initial_navigation_map_readiness() -> Dictionary:
    var route_delegate = initial_navigation_route_delegate()
    if route_delegate == null:
        return StartupReadinessResultScript.failed("missing_navigation_route_delegate")
    var navmesh_world = route_delegate.get("navmesh_world")
    if navmesh_world == null or not navmesh_world.has_method("navigation_map_readiness"):
        return StartupReadinessResultScript.failed("missing_navigation_map_readiness_authority")
    var started_usec := Time.get_ticks_usec()
    while true:
        if shutdown_requested: return StartupReadinessResultScript.failed("startup_cancelled")
        if navmesh_world.has_method("sync_navigation_map_if_dirty"):
            navmesh_world.call("sync_navigation_map_if_dirty")
        var readiness_value = navmesh_world.call("navigation_map_readiness")
        if not (readiness_value is Dictionary):
            return StartupReadinessResultScript.failed("invalid_navigation_map_readiness")
        var readiness: Dictionary = readiness_value
        if bool(readiness.get("ready", false)):
            await startup_loading_yield("Navigation map ready", "navigation_map", "ready", readiness)
            return StartupReadinessResultScript.ready({}, readiness)
        var reason := String(readiness.get("reason", "navigation_map_pending"))
        if reason in ["navmesh_backend_disabled", "missing_navigation_map", "missing_navmesh_regions"]:
            return StartupReadinessResultScript.failed(reason, {}, [], readiness)
        if float(Time.get_ticks_usec() - started_usec) / 1000000.0 >= INITIAL_READINESS_TIMEOUT_SECONDS:
            var timeout_metrics := readiness.duplicate(true)
            timeout_metrics["timeoutSeconds"] = INITIAL_READINESS_TIMEOUT_SECONDS
            return StartupReadinessResultScript.failed("navigation_map_readiness_timeout", {}, [], timeout_metrics)
        await startup_loading_yield("Waiting for navigation map", "navigation_map", "pending", readiness)
    return StartupReadinessResultScript.failed("navigation_map_readiness_loop_ended")

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
    if not NpcConstantsScript.NPC_NAV_ENABLE_STARTUP_TILE_PRIMING:
        return
    if navigation_world == null:
        return

    var route_delegate = initial_navigation_route_delegate()
    if route_delegate == null:
        return

    var tile_keys := {}
    for entry_value in entries:
        if tile_keys.size() >= INITIAL_NAVMESH_PRIME_TILE_LIMIT:
            break
        if entry_value is Dictionary:
            prime_navigation_tiles_for_entry(navigation_world, entry_value, tile_keys)

    var published := 0
    for tile_key_value in tile_keys.keys():
        if published >= INITIAL_NAVMESH_PRIME_TILE_LIMIT:
            break
        if publish_startup_navmesh_tile(navigation_world, route_delegate, String(tile_key_value)):
            published += 1

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
    if structure_system != null:
        structure_system.configure_citadel_terrain_admission()
    if weather_system and weather_system.has_method("reset_for_seed"):
        playtest_progress("apply_seed_weather_reset")
        weather_system.reset_for_seed(seed_hash)
    if environment_wind_system and environment_wind_system.has_method("reset_for_seed"):
        environment_wind_system.reset_for_seed(seed_hash)
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
    var deterministic_test_sequence := OS.get_environment("VOXEL_PLAYTEST") != "" \
        or OS.get_environment("VOXEL_NORMAL_RUNTIME_PERF_RUN_TOKEN").strip_edges() != "" \
        or OS.get_environment("VOXEL_WORLD_STREAMING_LOADING_MATRIX_TOKEN").strip_edges() != ""
    if forced_test_seed != "" and deterministic_test_sequence:
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
    # Initial demand is captured by the staged bootstrap after this placement.
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
    setup_biome_environment_catalog()
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
    world_edit_followup_queue = WorldEditFollowupQueueScript.new()
    world_edit_followup_queue.setup(self)
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
    if not visual_asset_registry.setup(biome_environment_catalog):
        push_warning("Generated visual asset registry loaded with fallbacks: %s" % str(visual_asset_registry.last_errors))

func setup_biome_environment_catalog() -> void:
    biome_environment_catalog = BiomeEnvironmentCatalogScript.new()
    if not biome_environment_catalog.setup():
        push_warning("Biome environment catalog loaded with bounded fallbacks: %s" % str(biome_environment_catalog.last_errors))

func prewarm_runtime_visuals_staged() -> void:
    if visual_asset_registry != null and visual_asset_registry.has_method("cached_asset_ids"):
        var asset_ids: Array[String] = visual_asset_registry.call("cached_asset_ids")
        for index in range(asset_ids.size()):
            var visual := visual_asset_registry.instantiate_asset(asset_ids[index]) as Node3D
            var prewarm_node: Node3D = visual
            if visual != null:
                visual.name = "RuntimeVisualPrewarm_%d" % index
                if asset_ids[index].begins_with("rock_"):
                    var rock_body := StaticBody3D.new()
                    rock_body.name = "RuntimeRockPrewarm_%d" % index
                    rock_body.add_child(visual)
                    var collider := CollisionShape3D.new()
                    var shape := SphereShape3D.new()
                    shape.radius = 0.8
                    collider.shape = shape
                    rock_body.add_child(collider)
                    prewarm_node = rock_body
                prewarm_node.position = Vector3(0.0, -10000.0, 0.0)
                add_child(prewarm_node)
            await startup_loading_yield(
                "Preparing world visuals %d/%d" % [index + 1, asset_ids.size()],
                "scene",
                "pending",
                {"warmedAssetCount": index + 1, "requiredAssetCount": asset_ids.size()}
            )
            if prewarm_node != null:
                prewarm_node.queue_free()
    if hostile_system != null and hostile_system.has_method("prewarm_visuals_staged"):
        await startup_loading_yield("Preparing hostile visuals", "scene", "pending")
        var hostile_metrics = await hostile_system.call("prewarm_visuals_staged")
        await startup_loading_yield("Hostile visuals ready", "scene", "pending", hostile_metrics)

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
    # Initial boot restores data synchronously; its caller owns publication.
    # Runtime callers must await try_load_world_staged instead.
    if not startup_loading_active or runtime_loading_active or shutdown_requested:
        return false
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

func try_load_world_staged(show_message := false, snapshot_override: Dictionary = {}) -> bool:
    # The optional in-memory snapshot uses the same runtime cutover as F9.
    if startup_operation_active or startup_loading_active or runtime_loading_active or shutdown_requested:
        return false
    if snapshot_override.is_empty() and (save_system == null or (not autosave_enabled and not show_message)):
        return false
    # Keep ownership through failure presentation too: stop_startup_loading
    # clears loading flags before its final yield, but shutdown must still wait.
    startup_operation_active = true
    var previous_processing := quiesce_runtime_world_for_loading("Loading saved world")
    var loaded := await run_runtime_world_load_staged(show_message, snapshot_override, previous_processing)
    runtime_loading_active = false
    startup_operation_active = false
    _refresh_streaming_loading_overlay()
    return loaded

func quiesce_runtime_world_for_loading(message: String) -> Dictionary:
    var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
    var previous := {
        "process": is_processing(), "input": is_processing_unhandled_input(),
        "physics": is_physics_processing(),
        "playerPhysics": player != null and player.is_physics_processing(),
        "npcPhysics": [],
        "npcExecutionOwner": autonomy,
        "npcExecutionEnabled": autonomy is Node and is_instance_valid(autonomy) and autonomy.is_physics_processing()
    }
    for entry_value in registered_npc_entries():
        if not (entry_value is Dictionary):
            continue
        var body := (entry_value as Dictionary).get("body") as Node
        if is_instance_valid(body):
            previous.npcPhysics.append({"body": body, "enabled": body.is_physics_processing()})
    runtime_loading_active = true
    set_process(false)
    set_process_unhandled_input(false)
    set_physics_process(false)
    set_registered_npc_physics_enabled(false)
    if player != null:
        player.set_physics_process(false)
        player.velocity = Vector3.ZERO
    if hud != null and hud.has_method("show_loading_overlay"):
        hud.show_loading_overlay(message)
    return previous

## Runtime streaming keeps Main and publication owners active while the player
## is held by authoritative collision/readiness. This presentation is shared by
## ordinary traversal and explicit relocation; it does not claim that the
## startup/runtime world-reset lifecycle owns the pending work.
func show_streaming_loading_overlay(message := "Preparing nearby world…", owner := "runtime_streaming") -> void:
    var next_message := String(message).strip_edges()
    if next_message.is_empty():
        next_message = "Preparing nearby world…"
    var owner_key := String(owner).strip_edges()
    if owner_key.is_empty(): owner_key = "runtime_streaming"
    streaming_loading_overlay_serial += 1
    streaming_loading_overlay_holds[owner_key] = {"message":next_message,"serial":streaming_loading_overlay_serial}
    _refresh_streaming_loading_overlay()

func hide_streaming_loading_overlay(owner := "runtime_streaming") -> void:
    streaming_loading_overlay_holds.erase(String(owner))
    _refresh_streaming_loading_overlay()

func _refresh_streaming_loading_overlay() -> void:
    streaming_loading_overlay_active = not streaming_loading_overlay_holds.is_empty()
    streaming_loading_message = ""
    var latest_serial := -1
    for hold: Dictionary in streaming_loading_overlay_holds.values():
        if int(hold.get("serial",-1))>latest_serial:
            latest_serial=int(hold.serial)
            streaming_loading_message=String(hold.message)
    if streaming_loading_overlay_active:
        if hud != null and hud.has_method("show_loading_overlay"):
            hud.show_loading_overlay(streaming_loading_message)
        return
    # A save load, New Game, or shutdown may share the same HUD presentation.
    # Only its owning lifecycle may remove it.
    if not startup_loading_active and not runtime_loading_active and not shutdown_requested \
            and hud != null and hud.has_method("hide_loading_overlay"):
        hud.hide_loading_overlay()

func prepare_streaming_destination_staged(position: Vector3, owner := "runtime_relocation") -> Dictionary:
    if not streaming_active or player == null or not is_instance_valid(player):
        return StartupReadinessResultScript.failed("streaming_destination_owner_unavailable")
    if not streaming_loading_request_owner.is_empty() and streaming_loading_request_owner != owner:
        return StartupReadinessResultScript.failed("streaming_destination_operation_busy")
    var foreground := foreground_streaming_intent_for_position(position)
    if foreground.is_empty():
        return StartupReadinessResultScript.failed("streaming_destination_geometry_invalid")
    var retained_bounds := WorldStreamingCoordinatorScript.playable_bounds(position).grow(16)
    streaming_loading_request_owner = owner
    if not retain_streaming_region(owner,retained_bounds,0,foreground.navigationTiles,foreground.bounds):
        streaming_loading_request_owner = ""
        return StartupReadinessResultScript.failed(streaming_demand_error)
    var request_id := int(streaming_requests.get(owner,0))
    var expected_seed := seed_text
    var started := Time.get_ticks_msec()
    var state: Dictionary = {}
    while float(Time.get_ticks_msec()-started)/1000.0<INITIAL_READINESS_TIMEOUT_SECONDS:
        if shutdown_requested or seed_text != expected_seed or int(streaming_requests.get(owner,0)) != request_id:
            return StartupReadinessResultScript.failed("startup_cancelled")
        if not apply_streaming_region_demand():
            return StartupReadinessResultScript.failed(streaming_demand_error)
        process_pending_chunk_loads(world_to_chunk(position.x,position.z))
        if pending_chunk_loads.is_empty():
            call("process_streaming_structure_work")
            process_pending_chunk_prop_spawns()
        state = world_streaming.region_readiness(foreground.bounds,request_id)
        if state.get("status") == "ready" and streaming_source_handoff_complete():
            var runtime = get("voxel_terrain_runtime")
            if runtime == null or not is_instance_valid(runtime):
                return StartupReadinessResultScript.failed("missing_terrain_presentation_authority")
            var remaining_seconds := maxf(0.1,INITIAL_READINESS_TIMEOUT_SECONDS-float(Time.get_ticks_msec()-started)/1000.0)
            var presentation := normalized_startup_result(
                await runtime.wait_for_spawn_presentation(position,remaining_seconds),
                "invalid_streaming_destination_presentation_result")
            if not startup_result_is_ready(presentation): return presentation
            var final_state := streaming_destination_readiness(position,owner,request_id,expected_seed)
            if final_state.get("status") != "ready":
                return StartupReadinessResultScript.failed(String(final_state.get("reason","streaming_destination_changed")),{},final_state.get("missing",[]),final_state)
            return StartupReadinessResultScript.ready({}, {
                "owner":owner,"requestId":request_id,"worldSeed":expected_seed,"position":position,"regional":final_state.regional,
                "presentation":presentation.get("metrics",{})
            })
        if state.get("status") == "failed":
            return StartupReadinessResultScript.failed("streaming_destination_dependency_failed",{},state.get("missing",[]),state)
        await startup_loading_yield("Preparing destination…","streaming_destination","pending",{
            "owner":owner,"position":position,"reason":state.get("reason",""),"missing":state.get("missing",[])
        })
    return StartupReadinessResultScript.failed("streaming_destination_timeout",{},state.get("missing",[]),state)

func streaming_destination_readiness(position: Vector3, owner: String, request_id: int, expected_seed := "") -> Dictionary:
    if shutdown_requested or not expected_seed.is_empty() and seed_text != expected_seed:
        return {"status":"failed","reason":"startup_cancelled"}
    if request_id<=0 or int(streaming_requests.get(owner,0))!=request_id:
        return {"status":"failed","reason":"streaming_destination_request_changed"}
    var foreground := foreground_streaming_intent_for_position(position)
    if foreground.is_empty(): return {"status":"failed","reason":"streaming_destination_geometry_invalid"}
    var regional: Dictionary = world_streaming.region_readiness(foreground.bounds,request_id)
    if regional.get("status")!="ready":
        return {"status":regional.get("status","pending"),"reason":regional.get("reason","streaming_destination_pending"),
            "missing":regional.get("missing",[]),"regional":regional}
    var runtime = get("voxel_terrain_runtime")
    if runtime==null or not is_instance_valid(runtime):
        return {"status":"failed","reason":"missing_terrain_presentation_authority","regional":regional}
    var presentation: Dictionary = runtime.spawn_presentation_state(position)
    if not presentation.get("ready",false):
        return {"status":"pending","reason":presentation.get("reason","streaming_destination_presentation_pending"),
            "regional":regional,"presentation":presentation}
    return {"status":"ready","reason":"","regional":regional,"presentation":presentation}

func release_streaming_destination(owner := "runtime_relocation") -> void:
    var request_id := int(streaming_requests.get(owner,0))
    if request_id>0: world_streaming.release_region(request_id)
    streaming_requests.erase(owner)
    streaming_request_bounds.erase(owner)
    streaming_request_priorities.erase(owner)
    streaming_request_foreground_tiles.erase(owner)
    streaming_request_foreground_bounds.erase(owner)
    streaming_request_peripheral_margins.erase(owner)
    if streaming_loading_request_owner==owner: streaming_loading_request_owner=""
    if not shutdown_requested: apply_streaming_region_demand()

func run_runtime_world_load_staged(show_message: bool, snapshot_override: Dictionary, previous_processing: Dictionary) -> bool:
    # Paint the loading UI before reading the slot. Poll the existing writer
    # without joining a live worker inside SaveSystem.load(). No owner has been
    # replaced yet, so a missing/wrong-seed slot can safely leave play intact.
    await startup_loading_yield("Reading saved world", "save_restore", "pending")
    var save_wait_started := Time.get_ticks_msec()
    while save_system != null and save_system.has_async_save_pending():
        if shutdown_requested or Time.get_ticks_msec() - save_wait_started >= 30000:
            await stop_startup_loading(StartupReadinessResultScript.failed("runtime_load_save_drain_cancelled_or_timed_out"))
            return false
        save_system.poll_async_save(false)
        await startup_loading_yield("Waiting for pending save", "save_restore", "pending")
    if shutdown_requested:
        await stop_startup_loading(StartupReadinessResultScript.failed("startup_cancelled"))
        return false
    var snapshot: Dictionary = snapshot_override if not snapshot_override.is_empty() else save_system.load(seed_text)
    if snapshot.is_empty() or String(snapshot.get("seed", seed_text)) != seed_text:
        if hud != null and hud.has_method("hide_loading_overlay"):
            hud.hide_loading_overlay()
        set_process(bool(previous_processing.process))
        set_process_unhandled_input(bool(previous_processing.input))
        set_physics_process(bool(previous_processing.physics))
        if player != null:
            player.set_physics_process(bool(previous_processing.playerPhysics))
        for entry: Dictionary in previous_processing.npcPhysics:
            if is_instance_valid(entry.body): entry.body.set_physics_process(bool(entry.enabled))
        var autonomy = previous_processing.get("npcExecutionOwner")
        if autonomy is Node and is_instance_valid(autonomy):
            autonomy.set_physics_process(bool(previous_processing.get("npcExecutionEnabled", false)))
        if show_message:
            update_hud("No save for %s" % seed_text if snapshot.is_empty() else "Load failed: save seed mismatch")
        return false
    begin_startup_loading_timeline()
    playtest_progress("runtime_load_staged_start")
    await startup_loading_yield("Clearing previous world", "world_reset", "pending")
    if not await retire_generated_scenes_before_world_reset():
        await stop_startup_loading(StartupReadinessResultScript.failed("generated_scene_retirement_failed"))
        return false
    if shutdown_requested:
        await stop_startup_loading(StartupReadinessResultScript.failed("startup_cancelled"))
        return false
    # Preserve owner instances (and save format), replace their state. Resetting
    # StructureSystem advances its admission generation even for the same seed;
    # native terrain must then rebuild from the restored edits, including edits
    # removed by loading an older snapshot.
    reset_runtime_world_state(false)
    # Removing old light-emitting blocks can write light deltas during reset.
    # Start the incoming save with a clean volume even when it has no deltas.
    if world_generation_system != null:
        world_generation_system.reset_terrain_volume_authority()
    await startup_loading_yield("Restoring saved state", "save_restore", "pending")
    if shutdown_requested:
        await stop_startup_loading(StartupReadinessResultScript.failed("startup_cancelled"))
        return false
    if not apply_save_snapshot(snapshot):
        await stop_startup_loading(StartupReadinessResultScript.failed("runtime_save_restore_failed"))
        return false
    # Tutorial.restore has now restored/reserved scenario inputs but has not
    # expanded the town. Bind current native inputs before staged scene work.
    var authority_result := normalized_startup_result(
        await reinitialize_voxel_terrain_authority_staged(), "terrain_authority_reset_failed"
    )
    if not startup_result_is_ready(authority_result):
        await stop_startup_loading(authority_result)
        return false
    var tutorial_result := StartupReadinessResultScript.ready({}, {"mode": "continue", "tutorialActive": false})
    if tutorial_system and bool(tutorial_system.get("started")):
        if not tutorial_system.has_method("complete_restore_world_staged"):
            await stop_startup_loading(StartupReadinessResultScript.failed("missing_staged_tutorial_restore"))
            return false
        tutorial_result = normalized_startup_result(
            await tutorial_system.call("complete_restore_world_staged"), "invalid_staged_tutorial_restore_result"
        )
    if not startup_result_is_ready(tutorial_result):
        await stop_startup_loading(tutorial_result, "tutorial_restore_readiness_failed")
        return false
    await startup_loading_yield("Saved world restored", "save_restore", "ready", {
        "seed": seed_text, "tutorial": tutorial_result.get("metrics", {}),
        "terrainAuthority": authority_result.get("metrics", {})
    })
    var publication_result := await prepare_runtime_world_publication_staged()
    if not startup_result_is_ready(publication_result):
        await stop_startup_loading(publication_result)
        return false
    refresh_intro_knock_audio()
    if show_message:
        update_hud("Loaded saved world")
    var completed := await complete_runtime_world_loading_staged(tutorial_result, publication_result)
    if completed:
        reset_autosave_dirty_tracking(false)
        playtest_progress("runtime_load_staged_done")
    return completed


func start_new_game_staged(show_message := true) -> bool:
    if startup_operation_active or startup_loading_active or runtime_loading_active or shutdown_requested:
        return false
    startup_operation_active = true
    var started := await run_new_game_staged(show_message)
    runtime_loading_active = false
    startup_operation_active = false
    _refresh_streaming_loading_overlay()
    return started

func run_new_game_staged(show_message: bool) -> bool:
    quiesce_runtime_world_for_loading("Starting new game")
    begin_startup_loading_timeline()
    playtest_progress("new_game_staged_start")
    await startup_loading_yield("Starting new game")
    if not await retire_generated_scenes_before_world_reset():
        await stop_startup_loading(StartupReadinessResultScript.failed("generated_scene_retirement_failed"))
        return false
    var previous_seed := seed_text
    if save_system:
        playtest_progress("new_game_staged_delete_save")
        save_system.delete(previous_seed)
    await startup_loading_yield("Choosing new world")
    apply_world_seed(random_world_seed(previous_seed), true)
    await startup_loading_yield("Resetting world")
    reset_runtime_world_state(false)
    await startup_loading_yield("Clearing previous world", "terrain_authority", "pending")
    var tutorial_result := StartupReadinessResultScript.failed("missing_tutorial_system")
    if launch_options.skipTutorial:
        if tutorial_system: tutorial_system.restore({})
        if player: player.position = find_spawn_position()
        tutorial_result = normalized_startup_result(await reinitialize_voxel_terrain_authority_staged(), "terrain_authority_reset_failed")
    elif tutorial_system:
        playtest_progress("new_game_staged_start_tutorial")
        if not tutorial_system.has_method("start_new_world_staged"):
            await stop_startup_loading(StartupReadinessResultScript.failed("missing_staged_tutorial_startup"))
            return false
        tutorial_result = normalized_startup_result(
            await tutorial_system.call("start_new_world_staged", reinitialize_voxel_terrain_authority_staged),
            "invalid_staged_tutorial_startup_result"
        )
    if not startup_result_is_ready(tutorial_result):
        await stop_startup_loading(tutorial_result, "tutorial_startup_failed")
        return false
    await startup_loading_yield("Reloading terrain")
    reload_chunks(true)
    var publication_result := await prepare_runtime_world_publication_staged()
    if not startup_result_is_ready(publication_result):
        await stop_startup_loading(publication_result)
        return false
    if tutorial_system and not launch_options.skipTutorial:
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
        update_hud("New game started")
    reset_autosave_dirty_tracking(true, "new_game")
    var completed := await complete_runtime_world_loading_staged(tutorial_result, publication_result)
    if completed:
        playtest_progress("new_game_staged_done")
    return completed

func prepare_runtime_world_publication_staged() -> Dictionary:
    var terrain_result := normalized_startup_result(
        await bootstrap_initial_chunks_staged(), "invalid_terrain_readiness_result"
    )
    if not startup_result_is_ready(terrain_result):
        return terrain_result
    var physical_region_result := normalized_startup_result(
        await wait_for_initial_region_physical_readiness(), "invalid_initial_region_physical_readiness_result"
    )
    if not startup_result_is_ready(physical_region_result):
        return physical_region_result
    var terrain_expansion_result := normalized_startup_result(
        await wait_for_final_voxel_view_distance(), "invalid_final_terrain_expansion_result"
    )
    if not startup_result_is_ready(terrain_expansion_result):
        return terrain_expansion_result
    var navigation_change_result := normalized_startup_result(
        await drain_initial_navigation_changes_staged(), "invalid_navigation_change_readiness_result"
    )
    if not startup_result_is_ready(navigation_change_result):
        return navigation_change_result
    var navigation_result := normalized_startup_result(
        await prime_initial_navigation_snapshot_staged(), "invalid_navigation_readiness_result"
    )
    if not startup_result_is_ready(navigation_result):
        return navigation_result
    # New Game and Continue use this shared publication path rather than the
    # initial boot path above. Navigation has now consumed the collision-backed
    # snapshot, so its temporary distant terrain demand can be released.
    var terrain_runtime_after_navigation=get("voxel_terrain_runtime")
    if terrain_runtime_after_navigation != null and is_instance_valid(terrain_runtime_after_navigation) \
            and terrain_runtime_after_navigation.has_method("release_startup_auxiliary_publication_chunks"):
        terrain_runtime_after_navigation.call("release_startup_auxiliary_publication_chunks")
    return StartupReadinessResultScript.ready({}, {
        "terrain": terrain_result.get("metrics", {}),
        "physicalRegion": physical_region_result.get("metrics", {}),
        "terrainExpansion": terrain_expansion_result.get("metrics", {}),
        "navigationChanges": navigation_change_result.get("metrics", {}),
        "navigation": navigation_result.get("metrics", {})
    })


func initial_navigation_terrain_chunk_keys() -> Array[Vector2i]:
    var pathing = npc_system.get("pathing") if npc_system != null else null
    var navigation_world = pathing.get("navigation_world") if pathing != null else null
    if navigation_world == null:
        return []
    # Retain exactly the terrain closure that the startup navigation publisher
    # will consume. An endpoint's 28-cell gameplay chunk is insufficient: one
    # 16-cell navigation tile (including its one-cell capture halo) can overlap
    # as many as four gameplay chunks, especially across zero/negative seams.
    var tile_keys := {}
    for entry_value in registered_npc_entries():
        if tile_keys.size() >= INITIAL_NAVMESH_PRIME_TILE_LIMIT:
            break
        if entry_value is Dictionary:
            prime_navigation_tiles_for_entry(navigation_world, entry_value, tile_keys)
    var unique := {}
    for tile_key_value in tile_keys:
        var coordinates := String(tile_key_value).split(",")
        if coordinates.size() != 2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int():
            continue
        var tile := Vector2i(int(coordinates[0]), int(coordinates[1]))
        var capture_bounds := Rect2i(
            tile * NpcConstantsScript.NAV_TILE_CELL_SIZE,
            Vector2i.ONE * NpcConstantsScript.NAV_TILE_CELL_SIZE
        ).grow(1)
        for chunk_key in WorldStreamingCoordinatorScript.chunks_for_bounds(capture_bounds):
            unique[chunk_key] = true
    var keys: Array[Vector2i]=[]
    for key_value in unique: keys.append(key_value)
    keys.sort_custom(func(a: Vector2i,b: Vector2i): return a.x < b.x if a.x != b.x else a.y < b.y)
    return keys

func complete_runtime_world_loading_staged(tutorial_result: Dictionary, publication_result: Dictionary) -> bool:
    var physics_gate_result := normalized_startup_result(startup_physics_gate_readiness(), "gameplay_physics_gate_failed")
    if not startup_result_is_ready(physics_gate_result):
        await stop_startup_loading(physics_gate_result, "gameplay_physics_gate_failed")
        return false
    var presentation_result := await wait_for_initial_terrain_presentation()
    if not startup_result_is_ready(presentation_result):
        await stop_startup_loading(presentation_result, "terrain_presentation_not_ready")
        return false
    var region_result := await wait_for_initial_region_readiness()
    if not startup_result_is_ready(region_result):
        await stop_startup_loading(region_result, "initial_region_not_ready")
        return false
    physics_gate_result = normalized_startup_result(startup_physics_gate_readiness(), "gameplay_physics_gate_failed")
    if not startup_result_is_ready(physics_gate_result):
        await stop_startup_loading(physics_gate_result, "gameplay_physics_gate_failed")
        return false
    var gameplay_metrics: Dictionary = physics_gate_result.get("metrics", {}).duplicate(true)
    gameplay_metrics["tutorial"] = tutorial_result.get("metrics", {})
    gameplay_metrics.merge(publication_result.get("metrics", {}), true)
    gameplay_metrics["presentation"] = presentation_result.get("metrics", {})
    gameplay_metrics["region"] = region_result.get("metrics", {})
    await startup_loading_yield("Gameplay prerequisites ready", "gameplay", "ready", gameplay_metrics)
    if shutdown_requested:
        await stop_startup_loading(StartupReadinessResultScript.failed("startup_cancelled"))
        return false
    runtime_loading_active = false
    _refresh_streaming_loading_overlay()
    set_process(not shutdown_requested)
    set_process_unhandled_input(not shutdown_requested)
    set_physics_process(not shutdown_requested)
    if player != null:
        player.set_physics_process(not shutdown_requested)
    set_registered_npc_physics_enabled(not shutdown_requested)
    return not shutdown_requested

func request_graceful_quit(exit_code := 0) -> void:
    if shutdown_requested:
        return
    shutdown_requested = true
    if hud != null and hud.has_method("show_loading_overlay"):
        hud.show_loading_overlay("Saving and exiting")
    set_process(false)
    set_process_unhandled_input(false)
    # Terrain shutdown yields across frames while the native voxel engine drains.
    # Stop all gameplay physics first: otherwise Main/NPC physics can submit new
    # streaming, navigation, or collision work against an authority already
    # being retired.
    set_physics_process(false)
    set_registered_npc_physics_enabled(false)
    if player != null:
        player.velocity = Vector3.ZERO
        player.set_physics_process(false)
    call_deferred("_graceful_quit_deferred", exit_code)

func _graceful_quit_deferred(exit_code: int) -> void:
    # A startup/reset coroutine owns its source registries until it returns.
    # Drain it before retiring those same owners; never race two lifecycles.
    while startup_operation_active or runtime_loading_active or runtime_relocation_active:
        await get_tree().process_frame
    # A cancelled initial load or reset has only partial durable state. Never
    # replace the last valid save with a snapshot of that unfinished world.
    var save_ready_world := not startup_loading_active and startup_loading_failure_result.is_empty() \
        and String(startup_readiness_domains.get("gameplay", {}).get("status", "")) == "ready"
    runtime_loading_active = true
    set_process(false)
    set_process_unhandled_input(false)
    set_physics_process(false)
    set_registered_npc_physics_enabled(false)
    if player != null:
        player.velocity = Vector3.ZERO
        player.set_physics_process(false)
    # Release audio playbacks while the audio server still has frames to drain,
    # rather than waiting for node destruction during engine shutdown.
    if is_instance_valid(audio_effects):
        audio_effects.shutdown_audio()
    await startup_loading_yield("Saving and exiting")
    if save_system != null and save_system.has_method("has_async_save_pending"):
        await wait_for_async_save_before_quit()
    if save_ready_world and autosave_enabled and save_system != null and autosave_dirty:
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
    # Streamed structures retire their shared door/resource bindings while the
    # NPC registry still exists. Only then release the navigation owner/map.
    await wait_for_npc_navigation_before_quit()
    get_tree().quit(exit_code)

func retire_generated_scenes_before_world_reset() -> bool:
    if shutdown_requested: return false
    reset_streaming_region_demand()
    var deadline := Time.get_ticks_msec() + 30000
    var autonomy = npc_system.get("autonomy_system") if is_instance_valid(npc_system) else null
    var navigation = autonomy.get("navmesh_world") if is_instance_valid(autonomy) else null
    if navigation != null:
        navigation.begin_publication_reset()
        while true:
            if shutdown_requested or Time.get_ticks_msec() >= deadline: return false
            if not navigation.advance_publication().get("busy",true): break
            await startup_loading_yield("Clearing previous navigation")
    if structure_system == null:
        return navigation == null or navigation.finish_publication_reset()
    var publication = structure_system.citadel_publication
    publication.begin_world_reset()
    deadline = Time.get_ticks_msec() + 30000
    while not publication.world_reset_ready():
        if shutdown_requested or Time.get_ticks_msec() >= deadline: return false
        # startup_loading_yield already advances this queue once per frame.
        await startup_loading_yield("Clearing previous landmarks")
    return not shutdown_requested and (navigation == null or navigation.finish_publication_reset())

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

func wait_for_npc_navigation_before_quit() -> void:
    if npc_system == null or not is_instance_valid(npc_system):
        return
    var autonomy = npc_system.get("autonomy_system")
    var navigation = autonomy.get("navmesh_world") if is_instance_valid(autonomy) else null
    if navigation != null:
        navigation.request_publication_shutdown()
        while not navigation.advance_publication().get("shutdownComplete", false):
            await startup_loading_yield("Stopping navigation preparation")
    if npc_system.has_method("shutdown_for_process_exit"):
        npc_system.call("shutdown_for_process_exit")
        # NavigationServer3D retires RIDs on physics frames.  Give it two full
        # physics/process cycles after the explicit map release instead of
        # relying on the engine's final shutdown order.
        await get_tree().physics_frame
        await startup_loading_yield("Stopping NPC navigation")
        await get_tree().physics_frame
        await startup_loading_yield("Stopping NPC navigation")

func wait_for_terrain_workers_before_quit() -> void:
    reset_streaming_region_demand()
    if structure_system != null:
        var admission = structure_system.citadel_terrain_admission
        var publication = structure_system.citadel_publication
        publication.request_shutdown()
        admission.request_shutdown()
        while true:
            var source_done := bool(admission.advance().get("shutdownComplete",false))
            var publication_done := bool(publication.advance().get("shutdownComplete",false))
            if source_done and publication_done: break
            await startup_loading_yield("Stopping citadel preparation")
    var voxel_runtime = get("voxel_terrain_runtime")
    if voxel_runtime != null and is_instance_valid(voxel_runtime) and voxel_runtime.has_method("begin_shutdown"):
        voxel_runtime.call("begin_shutdown")
        await startup_loading_yield("Stopping voxel terrain")
        await startup_loading_yield("Stopping voxel terrain")
        if voxel_runtime.has_method("voxel_engine_pending_task_count"):
            var voxel_drain_started_usec := Time.get_ticks_usec()
            var pending_voxel_tasks := int(voxel_runtime.call("voxel_engine_pending_task_count"))
            while pending_voxel_tasks > 0 \
                and float(Time.get_ticks_usec() - voxel_drain_started_usec) / 1000000.0 < VOXEL_SHUTDOWN_TASK_DRAIN_TIMEOUT_SECONDS:
                await startup_loading_yield("Stopping voxel terrain: %d tasks" % pending_voxel_tasks)
                pending_voxel_tasks = int(voxel_runtime.call("voxel_engine_pending_task_count"))
            if pending_voxel_tasks > 0:
                push_warning("Voxel terrain shutdown task drain timed out with %d tasks pending" % pending_voxel_tasks)
    if terrain_meshing_service == null or not terrain_meshing_service.has_method("clear_jobs"):
        return
    await startup_loading_yield("Stopping terrain jobs")
    terrain_meshing_service.call("clear_jobs", false)
    var guard := 0
    while guard < 600:
        if terrain_meshing_service.has_method("collect_retired_worker_tasks"):
            terrain_meshing_service.call("collect_retired_worker_tasks", false)
        if terrain_meshing_service.has_method("advance_retired_payload_cleanup"):
            terrain_meshing_service.call("advance_retired_payload_cleanup", false)
        var pending_count := int(terrain_meshing_service.call("shutdown_pending_work_count")) if terrain_meshing_service.has_method("shutdown_pending_work_count") else 0
        if pending_count <= 0:
            break
        await startup_loading_yield("Stopping terrain jobs")
        guard += 1
    # The final join is deliberately blocking only after all normal frames have
    # been used to drain the workers.  No native mesh payload may outlive the
    # scene tree or its GDExtension backend during process shutdown.
    terrain_meshing_service.call("clear_jobs", true)

func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST:
        request_graceful_quit()
