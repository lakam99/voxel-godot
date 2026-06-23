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
var height_edits := {}
var town_region_cache := {}
var blocks := {}
var removed_props := {}
var inventory := {}
var inventory_system
var crafting_system
var objective_system
var structure_system
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
var item_visual_factory
var visual_asset_registry
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
var autosave_elapsed := 0.0
var autosave_enabled := true
var discovered_biomes := {}
var discovered_town_keys := {}
var discovered_shrine_keys := {}
var discovered_mine_keys := {}
var discovered_ruin_keys := {}
var discovered_camp_keys := {}
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
    "fullscreen": false,
    "lookSmoothing": 0.0,
    "headBob": true,
    "handSway": true
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
var perf_break_ms := 0.0
var perf_hud_ms := 0.0
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
    setup_save_system()
    var active_seed := ""
    if autosave_enabled and save_system and save_system.has_method("active_seed"):
        active_seed = save_system.active_seed("")
    if active_seed != "":
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
    if not loaded and tutorial_system:
        if autosave_enabled:
            apply_world_seed(random_world_seed(seed_text), true)
        started_intro_tutorial = tutorial_system.start_new_world()
        playtest_progress("main_tutorial_start_done")
    update_chunks(true)
    playtest_progress("main_initial_chunks_done")
    refresh_intro_knock_audio()
    var ready_message := "Loaded saved world" if loaded else "Godot slice ready"
    if not loaded and tutorial_system and tutorial_system.last_message != "":
        ready_message = tutorial_system.last_message
    update_hud(ready_message)

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

func apply_world_seed(new_seed: String, remember := false) -> void:
    seed_text = new_seed.strip_edges()
    if seed_text == "":
        seed_text = random_world_seed()
    seed_hash = hash_string(seed_text)
    town_region_cache.clear()
    fishing_rng.seed = hash_string("%s:fishing" % seed_text)
    setup_noise()
    if weather_system and weather_system.has_method("reset_for_seed"):
        weather_system.reset_for_seed(seed_hash)
    if save_system and remember and save_system.has_method("set_active_seed"):
        save_system.set_active_seed(seed_text)

func random_world_seed(exclude_seed := "") -> String:
    var rng := RandomNumberGenerator.new()
    rng.randomize()
    var generated := ""
    for attempt in range(8):
        generated = "atlas-%08d" % rng.randi_range(10000000, 99999999)
        if generated != exclude_seed:
            return generated
    var stamp := int(Time.get_unix_time_from_system())
    return "atlas-%08d" % ((stamp % 90000000) + 10000000)

func setup_game_systems() -> void:
    setup_visual_asset_registry()
    item_visual_factory = ItemVisualFactoryScript.new()
    inventory_system = InventorySystemScript.new(
        ItemCatalogScript.ITEMS,
        ItemCatalogScript.INVENTORY_SIZE,
        ItemCatalogScript.MAX_INVENTORY_SIZE,
        ItemCatalogScript.HOTBAR_SIZE
    )
    crafting_system = CraftingSystemScript.new(
        ItemCatalogScript.RECIPES,
        ItemCatalogScript.ITEMS,
        inventory_system,
        Callable(self, "is_station_near")
    )
    objective_system = ObjectiveSystemScript.new()
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

func setup_visual_asset_registry() -> void:
    visual_asset_registry = VisualAssetRegistryScript.new()
    if not visual_asset_registry.setup():
        push_warning("Generated visual asset registry loaded with fallbacks: %s" % str(visual_asset_registry.last_errors))

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

func _sync_inventory_totals() -> void:
    if inventory_system:
        inventory = inventory_system.totals()

func save_world(show_message := true) -> bool:
    if save_system == null:
        return false
    var snapshot: Dictionary = create_save_snapshot()
    var ok: bool = save_system.save(seed_text, snapshot)
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
    return started
