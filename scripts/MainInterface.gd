extends Node3D


const PlayerController := preload("res://scripts/PlayerController.gd")
const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")
const InventorySystemScript := preload("res://scripts/InventorySystem.gd")
const CraftingSystemScript := preload("res://scripts/CraftingSystem.gd")
const GameHudScript := preload("res://scripts/GameHud.gd")
const HeldItemSystemScript := preload("res://scripts/HeldItemSystem.gd")
const ItemVisualFactoryScript := preload("res://scripts/ItemVisualFactory.gd")
const VisualAssetRegistryScript := preload("res://scripts/visual/VisualAssetRegistry.gd")
const StaticItemAssetRegistryScript := preload("res://scripts/visual/StaticItemAssetRegistry.gd")
const AnimatedAssetRegistryScript := preload("res://scripts/visual/AnimatedAssetRegistry.gd")
const ObjectiveSystemScript := preload("res://scripts/ObjectiveSystem.gd")
const StructureSystemScript := preload("res://scripts/StructureSystem.gd")
const UtilityBlockSystemScript := preload("res://scripts/UtilityBlockSystem.gd")
const SaveSystemScript := preload("res://scripts/SaveSystem.gd")
const RuntimePerformanceMonitorScript := preload("res://scripts/perf/RuntimePerformanceMonitor.gd")
const SurvivalSystemScript := preload("res://scripts/SurvivalSystem.gd")
const HostileSystemScript := preload("res://scripts/HostileSystem.gd")
const ProgressionSystemScript := preload("res://scripts/ProgressionSystem.gd")
const EquipmentSystemScript := preload("res://scripts/EquipmentSystem.gd")
const ContractSystemScript := preload("res://scripts/ContractSystem.gd")
const AudioEffectsSystemScript := preload("res://scripts/AudioEffectsSystem.gd")
const PlayerProjectileSystemScript := preload("res://scripts/PlayerProjectileSystem.gd")
const WeatherSystemScript := preload("res://scripts/WeatherSystem.gd")
const TutorialSystemScript := preload("res://scripts/TutorialSystem.gd")
const NpcSystemScript := preload("res://scripts/NpcSystem.gd")
const StoryEventBusScript := preload("res://scripts/story/StoryEventBus.gd")
const StoryDirectorScript := preload("res://scripts/story/StoryDirector.gd")
const StoryQuestSystemScript := preload("res://scripts/story/StoryQuestSystem.gd")
const RegionStoryGeneratorScript := preload("res://scripts/story/RegionStoryGenerator.gd")
const StorySitePlacementScript := preload("res://scripts/story/data/StorySitePlacement.gd")
const StoryWorldOverlaySystemScript := preload("res://scripts/story/StoryWorldOverlaySystem.gd")
const WorldmarkInfluenceSystemScript := preload("res://scripts/story/WorldmarkInfluenceSystem.gd")
const StoryJournalModelScript := preload("res://scripts/story/StoryJournalModel.gd")
const StoryDialogueRouterScript := preload("res://scripts/story/StoryDialogueRouter.gd")
const WorldmarkEncounterControllerScript := preload("res://scripts/story/encounters/WorldmarkEncounterController.gd")
const SettlementStateSystemScript := preload("res://scripts/story/SettlementStateSystem.gd")
const RegionAftermathSystemScript := preload("res://scripts/story/RegionAftermathSystem.gd")
const StoryAccessibilitySettingsScript := preload("res://scripts/story/StoryAccessibilitySettings.gd")
const StoryDebugToolsScript := preload("res://scripts/story/tools/StoryDebugTools.gd")

const CELL := 1.35
const CHUNK_SIZE := 28
const RENDER_DISTANCE := 3
const MIN_HEIGHT := 4.0
const MAX_HEIGHT := 120.0
const WATER_LEVEL := 11.1
const DAY_LENGTH := 600.0
const SUNRISE_TIME := 0.0
const CLOCK_DISPLAY_OFFSET := 0.25
const DAWN_START_CLOCK := 5.25 / 24.0
const DAY_FULL_CLOCK := 7.0 / 24.0
const DUSK_START_CLOCK := 18.25 / 24.0
const NIGHT_FULL_CLOCK := 20.25 / 24.0
const MOONRISE_CLOCK := 18.5 / 24.0
const MOONSET_CLOCK := 6.5 / 24.0
const SLEEP_FADE_OUT_SECONDS := 0.55
const SLEEP_HOLD_SECONDS := 0.45
const SLEEP_FADE_IN_SECONDS := 0.70
const INTERACT_RANGE := 10.5
const ACTION_REACH := CELL * 1.85
const PLACEMENT_RANGE := CELL * 2.65
const MELEE_RANGE := CELL * 2.65
const SKY_RADIUS := 640.0
const BREAK_RESET_SECONDS := 2.4
const STRUCTURE_REGION_CELLS := CHUNK_SIZE * 5
const STRUCTURE_SPAWN_CHANCE := 0.26
const TOWN_REGION_CELLS := CHUNK_SIZE * 10
const TOWN_SPAWN_CHANCE := 0.18
const TOWN_RADIUS_CELLS := 30
const BEACON_CHARGE_REQUIRED := 100.0
const BEACON_RAID_THRESHOLDS := [25.0, 55.0, 85.0]
const MAP_SAMPLE_GRID := 24
const CHUNK_ASSET_CACHE_LIMIT := 96
const PLAYTEST_CASE_SPECS := [
    { "id": "town", "label": "Town", "detail": "doors, paths, interiors", "validates": "town flattening, double doors, path collision, traders" },
    { "id": "mine", "label": "Mine", "detail": "ore, rocks, loot points", "validates": "ore readability, mining requirements, loot, cave props" },
    { "id": "camp", "label": "Camp", "detail": "ambush, barricades, loot", "validates": "hostile camps, traps, ranged combat, camp rewards" },
    { "id": "forest", "label": "Forest", "detail": "trees, forage, wildlife", "validates": "tree fall, forage drops, wildlife drops, biome props" },
    { "id": "mountain", "label": "Mountain", "detail": "steep terrain, stone, snow", "validates": "slope movement, mountain props, snow forage, ore props" },
    { "id": "water", "label": "Water", "detail": "shoreline, fishing, camp", "validates": "shoreline placement, fishing, campfire utility, water adjacency" },
    { "id": "combat", "label": "Combat Arena", "detail": "cover, bow, enemies", "validates": "enemy awareness, leashing, projectile blocking, dodgeability" },
    { "id": "collapse", "label": "Collapse Test", "detail": "structural integrity", "validates": "support checks, collapse drops, floating structure removal" }
]
const NON_STRUCTURAL_BLOCK_TYPES := {
    "cobblestonePath": true,
    "door": true,
    "bed": true,
    "glass": true,
    "torch": true,
    "spikeTrap": true,
    "wardLantern": true,
    "sanctuaryBeacon": true,
    "riftAnchor": true
}

const BIOME_COLORS := {
    "ocean": Color(0.24, 0.58, 0.68),
    "beach": Color(0.82, 0.72, 0.46),
    "plains": Color(0.48, 0.76, 0.34),
    "forest": Color(0.31, 0.60, 0.31),
    "taiga": Color(0.28, 0.52, 0.43),
    "swamp": Color(0.34, 0.43, 0.25),
    "desert": Color(0.82, 0.66, 0.36),
    "savanna": Color(0.66, 0.67, 0.34),
    "town": Color(0.43, 0.67, 0.38),
    "alpine": Color(0.50, 0.55, 0.53),
    "tundra": Color(0.58, 0.66, 0.58),
    "snow": Color(0.86, 0.91, 0.90)
}


func _ready() -> void: pass
func playtest_progress(label: String) -> void: pass
func setup_save_system() -> void: pass
func apply_world_seed(new_seed: String, remember := false) -> void: pass
func random_world_seed(exclude_seed := "") -> String: return ""
func setup_game_systems() -> void: pass
func setup_story_systems() -> void: pass
func story_region_id_for_cell(cell: Vector2i) -> String: return ""
func story_region_id_for_world_position(position: Vector3) -> String: return ""
func emit_story_event(event_type: String, subject_id := "", region_id := "", dedupe_key := "", position := Vector3.INF, payload := {}) -> bool: return false
func update_story_region_entry(cell: Vector2i, position: Vector3, biome: String) -> void: pass
func interact_story_dialogue_node(node: Node) -> bool: return false
func interact_story_node(node: Node) -> bool: return false
func start_story_encounter_from_site(site: Dictionary, position: Vector3) -> bool: return false
func damage_story_worldmark(amount: float, source := "player") -> bool: return false
func try_release_story_worldmark() -> bool: return false
func run_story_debug_command(command: String, args := {}) -> Dictionary: return {}
func debug_story_dump() -> Dictionary: return {}
func setup_visual_asset_registry() -> void: pass
func setup_static_item_asset_registry() -> void: pass
func setup_animated_asset_registry() -> void: pass
func grant_starter_inventory() -> void: pass
func reset_crafting_unlocks(initial_groups := []) -> void: pass
func unlock_crafting_group(group_id: String, reason := "") -> bool: return false
func unlock_all_crafting_groups_for_tests() -> void: pass
func _sync_inventory_totals() -> void: pass
func save_world(show_message := true) -> bool: return false
func try_load_world(show_message := false) -> bool: return false
func start_new_game(show_message := true) -> bool: return false
func reset_runtime_world_state() -> void: pass
func create_save_snapshot() -> Dictionary: return {}
func apply_save_snapshot(snapshot: Dictionary) -> bool: return false
func snapshot_exploration() -> Dictionary: return {}
func restore_exploration(snapshot_value) -> void: pass
func snapshot_height_edits() -> Array: return []
func restore_height_edits(entries) -> void: pass
func restore_removed_props(entries) -> void: pass
func restore_player_state(state) -> void: pass
func snapshot_player_blocks() -> Array: return []
func restore_player_blocks(entries) -> void: pass
func clear_player_blocks() -> void: pass
func clear_all_blocks() -> void: pass
func serialize_slots(slots_value) -> Array: return []
func restore_slots(slots_value, size: int) -> Array: return []
func serialize_furnace_state(state_value) -> Dictionary: return {}
func restore_furnace_state(state_value) -> Dictionary: return {}
func serialize_single_slot(slot_value) -> Dictionary: return {}
func restore_single_slot(slot_value) -> Dictionary: return {}
func reload_chunks() -> void: pass
func vector3_to_array(value: Vector3) -> Array: return []
func array_to_vector3(value, fallback: Vector3) -> Vector3: return Vector3.ZERO
func optional_vector3(value): return null
func array_to_vector3i(value, fallback: Vector3i) -> Vector3i: return Vector3i.ZERO
func setup_noise() -> void: pass
func make_noise(salt: int, frequency: float, octaves: int) -> FastNoiseLite: return null
func setup_materials() -> void: pass
func make_material(color: Color, roughness: float = 0.82, transparent: bool = false) -> StandardMaterial3D: return null
func make_emissive_material(color: Color, energy: float) -> StandardMaterial3D: return null
func make_unshaded_material(color: Color) -> StandardMaterial3D: return null
func setup_environment() -> void: pass
func setup_break_overlay() -> void: pass
func make_sky_body(node_name: String, material: Material, radius: float) -> MeshInstance3D: return null
func setup_player() -> void: pass
func setup_hostiles() -> void: pass
func setup_npc_system() -> void: pass
func setup_player_projectiles() -> void: pass
func setup_held_item() -> void: pass
func find_spawn_position() -> Vector3: return Vector3.ZERO
func find_spawn_cell(max_variation: float) -> Vector2i: return Vector2i.ZERO
func height_variation_cell(x: int, z: int, radius: int) -> float: return 0.0
func setup_hud() -> void: pass
func setup_tutorial_system() -> void: pass
func setup_audio_effects() -> void: pass
func play_feedback(effect_name: String, position := Vector3.INF, color := Color.WHITE, count := 0) -> void: pass
func refresh_intro_knock_audio() -> void: pass
func show_tutorial_dialogue(fallback_message: String) -> void: pass
func capture_mouse_if_no_modal() -> void: pass
func disable_collision_shapes_recursive(node: Node) -> void: pass
func spawn_falling_tree_visual(tree: Node3D) -> void: pass
func feedback_color_for_material(material_id: String) -> Color: return Color.WHITE
func _process(delta: float) -> void: pass
func profiled_ms(start_usec: int) -> float: return 0.0
func update_sky(delta: float) -> void: pass
func update_local_light_rig_lod(delta: float) -> void: pass
func update_terrain_local_light_uniforms() -> void: pass
func update_music_state(observer: Vector3, day: float) -> void: pass
func apply_weather_lighting(weather: Dictionary, day: float) -> void: pass
func update_survival(delta: float) -> void: pass
func handle_collapse_if_needed() -> bool: return false
func respawn_player() -> void: pass
func respawn_position() -> Vector3: return Vector3.ZERO
func sleep_at_bed(block: Node) -> bool: return false
func start_sleep_transition(rest_quality: float, wake_message: String) -> void: pass
func update_sleep_transition(delta: float) -> void: pass
func apply_sleep_transition() -> void: pass
func clock_time_text() -> String: return ""
func clock_phase() -> float: return 0.0
func clock_day_factor() -> float: return 0.0
func clock_night_factor() -> float: return 0.0
func daylight_progress(phase: float) -> float: return 0.0
func wrapped_clock_progress(start: float, end: float, phase: float) -> float: return 0.0
func clock_in_wrapped_range(phase: float, start: float, end: float) -> bool: return false
func bed_respawn_point(block: Node) -> Vector3: return Vector3.ZERO
func shelter_state_at_player(delta: float) -> Dictionary: return {}
func shelter_state_at(position: Vector3) -> Dictionary: return {}
func inventory_stacks() -> Array: return []
func drop_inventory_at(position: Vector3) -> int: return 0
func spawn_pickup_stack(item_id: String, count: int, position: Vector3) -> Node3D: return null
func create_pickup_node(item_id: String) -> Node3D: return null
func acquire_pickup_node(item_id: String) -> Node3D: return null
func recycle_pickup(pickup: Dictionary) -> void: pass
func pickup_pool_stats() -> Dictionary: return {}
func update_dropped_pickups(delta: float) -> void: pass
func clear_dropped_pickups() -> void: pass
func register_wildlife(body: StaticBody3D, rng: RandomNumberGenerator, cold := false) -> void: pass
func random_horizontal_direction(rng: RandomNumberGenerator = null) -> Vector3: return Vector3.ZERO
func update_wildlife(delta: float) -> void: pass
func update_single_wildlife(body: StaticBody3D, delta: float) -> void: pass
func move_wildlife(body: StaticBody3D, displacement: Vector3) -> float: return 0.0
func wildlife_blocked_at(position: Vector3) -> bool: return false
func update_hostiles(delta: float) -> void: pass
func update_npcs(delta: float) -> void: pass
func update_beacon_charge(delta: float) -> void: pass
func first_sanctuary_beacon() -> StaticBody3D: return null
func beacon_threat_count(beacon: Node3D) -> int: return 0
func trigger_beacon_raids(beacon: StaticBody3D, delta: float) -> int: return 0
func raid_stage_for_charge(charge: float) -> int: return 0
func establish_sanctuary() -> void: pass
func victory_stats() -> Array: return []
func update_break_reset(delta: float) -> void: pass
func reset_break_progress() -> void: pass
func orient_directional_light(light: DirectionalLight3D, sky_direction: Vector3) -> void: pass
func _input(event: InputEvent) -> void: pass
func should_accept_mouse_look() -> bool: return false
func _unhandled_input(event: InputEvent) -> void: pass
func select_hotbar_delta(delta: int) -> int: return 0
func update_hud_frame(delta: float) -> void: pass
func update_hud(message: String = "", throttled: bool = false) -> void: pass
func hud_refresh_stats() -> Dictionary: return {}
func update_exploration_state(cell: Vector2i, biome: String) -> void: pass
func discover_landmarks_near(position: Vector3, radius: float = CELL * 8.0) -> int: return 0
func discover_landmark(tier: String, key: String, position: Vector3) -> bool: return false
func landmark_label_for_tier(tier: String) -> String: return ""
func discover_shrine_cache(block: Node) -> bool: return false
func award_discovery_xp(event: Dictionary) -> void: pass
func trigger_landmark_ambush(position: Vector3, tier: String, label: String) -> int: return 0
func update_objectives_and_contracts() -> void: pass
func objective_state() -> Dictionary: return {}
func structure_counts() -> Dictionary: return {}
func generated_tier_counts() -> Dictionary: return {}
func placed_block_count() -> int: return 0
func has_any_tool(totals: Dictionary) -> bool: return false
func has_compass() -> bool: return false
func has_map() -> bool: return false
func has_navigation_beacon() -> bool: return false
func heading_degrees() -> float: return 0.0
func navigation_heading_text() -> String: return ""
func navigation_map_state() -> Dictionary: return {}
func add_map_point(points: Array, kind: String, label: String, offset: Vector2, size: float, radius: float) -> void: pass
func navigation_marker_for(body: Node, block_type: String) -> Dictionary: return {}
func cardinal_for_degrees(degrees: float) -> String: return ""
func cardinal_for_offset(offset: Vector2) -> String: return ""
func navigation_waypoints_text(points: Array) -> String: return ""
func map_marker_summary(points: Array) -> String: return ""
func map_terrain_samples(center_cell: Vector2i, radius: float) -> Array: return []
func map_color_for_sample(biome: String, height: float) -> Color: return Color.WHITE
func _on_ui_slot_clicked(index: int) -> void: pass
func _on_ui_slot_moved(from_index: int, to_index: int) -> void: pass
func _on_craft_requested(recipe_id: String) -> void: pass
func _on_utility_action_requested(action: String, payload) -> void: pass
func _on_dialogue_closed(context) -> void: pass
func _on_resume_requested() -> void: pass
func _on_new_game_requested() -> void: pass
func _on_recipe_crafted(recipe_id: String, output: String, amount: int) -> void: pass
func _on_objective_completed(objective: Dictionary) -> void: pass
func _on_utility_changed() -> void: pass
func _on_utility_processed(block_type: String, output_item: String) -> void: pass
func _on_utility_traded(trade: Dictionary) -> void: pass
func _on_survival_changed() -> void: pass
func _on_progression_changed(state: Dictionary, leveled: bool) -> void: pass
func apply_progression_bonuses(state: Dictionary) -> void: pass
func award_progression(reason: String, amount: int) -> bool: return false
func award_craft_xp(recipe_id: String) -> void: pass
func award_break_xp(material_id: String) -> void: pass
func award_hostile_xp(variant: String) -> void: pass
func award_place_xp(block_type: String) -> void: pass
func _on_teleport_requested(value: String) -> void: pass
func _on_setting_changed(setting: String, value) -> void: pass
func _on_playtest_requested(case_id: String) -> void: pass
func _on_playtest_cleanup_requested() -> void: pass
func apply_runtime_settings() -> void: pass
func apply_runtime_setting(setting: String, value, sync_hud: bool = true) -> void: pass
func apply_local_light_shadows(root: Node = null) -> void: pass
func update_performance_overlay(delta: float) -> void: pass
func debug_performance_state() -> Dictionary: return {}
func count_nodes_with_meta(node: Node, key: String, expected: String = "") -> int: return 0
func count_visual_nodes(node: Node) -> int: return 0
func count_physics_bodies(node: Node) -> int: return 0
func _on_equipment_changed() -> void: pass
func _on_equipment_slot_clicked(slot: String) -> void: pass
func _on_contracts_changed() -> void: pass
func _on_contract_rewarded(contract: Dictionary) -> void: pass
func parse_teleport_coords(value: String) -> Dictionary: return {}
func teleport_to(value: String) -> bool: return false
func teleport_to_cell(cell: Vector2i, message: String = "") -> bool: return false
func run_playtest_case(case_id: String) -> bool: return false
func playtest_case_specs() -> Array: return []
func playtest_case_target(case_id: String) -> Dictionary: return {}
func setup_playtest_case(case_id: String, cell: Vector2i) -> void: pass
func cleanup_playtest_case_assets() -> void: pass
func cleanup_playtest_nodes(root: Node) -> void: pass
func playtest_case_counts() -> Dictionary: return {}
func count_playtest_nodes(root: Node) -> int: return 0
func count_playtest_blocks() -> int: return 0
func count_playtest_hostiles() -> int: return 0
func playtest_rng(case_id: String, cell: Vector2i) -> RandomNumberGenerator: return null
func playtest_position(cell: Vector2i, offset: Vector2i = Vector2i.ZERO, lift: float = 0.0) -> Vector3: return Vector3.ZERO
func mark_playtest_node(node: Node, case_id: String) -> void: pass
func make_playtest_prop(case_id: String, prop_type: String, position: Vector3, rng: RandomNumberGenerator, biome: String = "", ore_type: String = "") -> Node: return null
func setup_playtest_town_case(cell: Vector2i) -> void: pass
func setup_playtest_mine_case(cell: Vector2i) -> void: pass
func setup_playtest_forest_case(cell: Vector2i) -> void: pass
func setup_playtest_mountain_case(cell: Vector2i) -> void: pass
func setup_playtest_water_case(cell: Vector2i) -> void: pass
func setup_playtest_camp_case(cell: Vector2i) -> void: pass
func setup_playtest_combat_case(cell: Vector2i) -> void: pass
func spawn_playtest_enemy(case_id: String, position: Vector3, variant: String) -> Node: return null
func find_biome_playtest_cell(biomes: Array, min_height: float, max_height: float, require_flat: bool) -> Vector2i: return Vector2i.ZERO
func find_standalone_structure_target(kind: String) -> Dictionary: return {}
func create_playtest_ground_block(base_cell: Vector2i, offset: Vector2i, block_type: String, case_id: String, dy: int = 0) -> Node: return null
func create_playtest_structure_block(cell_x: int, cell_z: int, level: float, dy: int, block_type: String, case_id: String = "collapse") -> Node: return null
func create_playtest_collapse_case(base_cell: Vector2i) -> void: pass
func focused_interaction_hit() -> Dictionary: return {}
func use_or_place() -> void: pass
func try_use_active_consumable() -> bool: return false
func fish_with_rod() -> bool: return false
func find_fishing_spot() -> Dictionary: return {}
func is_utility_block(block_type: String) -> bool: return false
func request_player_door_use(door: Node, actor: Node = null, actor_kind := "player", metadata := {}): return null
func request_door_state(door: Node, desired_open: bool, actor: Node = null, actor_kind := "system", metadata := {}): return null
func update_chunks(force: bool = false) -> void: pass
func create_chunk(cx: int, cz: int) -> void: pass
func chunk_assets(cx: int, cz: int) -> Dictionary: return {}
func touch_chunk_asset_cache_key(key: Vector2i) -> void: pass
func prune_chunk_asset_cache() -> void: pass
func invalidate_chunk_asset_cache(key: Vector2i) -> void: pass
func clear_chunk_asset_cache() -> void: pass
func chunk_asset_cache_stats() -> Dictionary: return {}
func rebuild_chunk(cx: int, cz: int) -> void: pass
func rebuild_chunks_around_cell(cell: Vector2i) -> void: pass
func build_chunk_mesh(cx: int, cz: int) -> Mesh: return null
func terrain_vertex_local_cached(height_cache: Dictionary, cell_x: int, cell_z: int, origin_cell_x: int, origin_cell_z: int) -> Vector3: return Vector3.ZERO
func add_cached_vertex(st: SurfaceTool, point: Vector3, color_cache: Dictionary, normal_cache: Dictionary, cell_x: int, cell_z: int) -> void: pass
func add_vertex(st: SurfaceTool, point: Vector3, cell_x: int, cell_z: int) -> void: pass
func terrain_normal_for_cell_cached(height_cache: Dictionary, cell_x: int, cell_z: int) -> Vector3: return Vector3.UP
func terrain_normal_for_cell(cell_x: int, cell_z: int) -> Vector3: return Vector3.UP
func terrain_height_from_cache(height_cache: Dictionary, cell_x: int, cell_z: int) -> float: return 0.0
func terrain_vertex_local(cell_x: int, cell_z: int, origin_cell_x: int, origin_cell_z: int) -> Vector3: return Vector3.ZERO
func add_chunk_skirts(st: SurfaceTool, start_x: int, start_z: int, bottom_y: float) -> void: pass
func add_skirt_quad( st: SurfaceTool, ax: int, az: int, bx: int, bz: int, origin_x: int, origin_z: int, bottom_y: float ) -> void: pass
func add_skirt_vertex(st: SurfaceTool, point: Vector3, cell_x: int, cell_z: int, normal: Vector3) -> void: pass
func skirt_outward_normal(ax: int, az: int, bx: int, bz: int, origin_x: int, origin_z: int) -> Vector3: return Vector3.UP
func spawn_chunk_props(chunk: Node3D, cx: int, cz: int) -> void: pass
func spawn_chunk_detail_batches(chunk: Node3D, cx: int, cz: int) -> void: pass
func add_detail_for_biome(batches: Dictionary, local_position: Vector3, biome: String, height: float, rng: RandomNumberGenerator) -> void: pass
func append_flower_detail(batches: Dictionary, local_position: Vector3, rng: RandomNumberGenerator) -> void: pass
func append_detail_transform(batches: Dictionary, detail_type: String, origin: Vector3, yaw: float, scale: Vector3) -> void: pass
func spawn_detail_batch(parent: Node3D, detail_type: String, transforms: Array) -> void: pass
func detail_material(detail_type: String) -> Material: return null
func detail_mesh(detail_type: String) -> Mesh: return null
func make_tree(parent: Node, prop_id: String, position: Vector3, biome: String, rng: RandomNumberGenerator): return null
func make_rock(parent: Node, prop_id: String, position: Vector3, rng: RandomNumberGenerator): return null
func make_ore_cluster(parent: Node, prop_id: String, position: Vector3, ore_type: String, rng: RandomNumberGenerator, count: int = 3) -> Array: return []
func make_ore(parent: Node, prop_id: String, position: Vector3, ore_type: String, rng: RandomNumberGenerator): return null
func make_forage(parent: Node, prop_id: String, position: Vector3, biome: String, rng: RandomNumberGenerator): return null
func make_wildlife(parent: Node, prop_id: String, position: Vector3, biome: String, rng: RandomNumberGenerator): return null
func place_selected_block() -> void: pass
func should_face_player(block_type: String) -> bool: return false
func snapped_player_yaw() -> float: return 0.0
func fallback_ground_placement_hit(max_distance: float) -> Dictionary: return {}
func placement_from_hit(hit: Dictionary, block_type: String) -> Dictionary: return {}
func placement_within_action_reach(placement: Dictionary) -> bool: return false
func hit_within_action_reach(hit: Dictionary) -> bool: return false
func placement_surface_height(x: float, z: float, block_type: String) -> float: return 0.0
func dominant_cell_offset(normal: Vector3) -> Vector3i: return Vector3i.ZERO
func block_collision_profile(block_type: String) -> Dictionary: return {}
func add_block_mesh(parent: Node3D, size: Vector3, offset: Vector3, material_key: String, rotation := Vector3.ZERO) -> MeshInstance3D: return null
func add_workbench_visual(parent: Node3D) -> void: pass
func add_chest_visual(parent: Node3D) -> void: pass
func add_bed_visual(parent: Node3D) -> void: pass
func add_anvil_visual(parent: Node3D) -> void: pass
func add_furnace_visual(parent: Node3D) -> void: pass
func add_campfire_visual(parent: Node3D) -> void: pass
func add_torch_visual(parent: Node3D) -> void: pass
func add_spike_trap_visual(parent: Node3D) -> void: pass
func add_ward_object_visual(parent: Node3D, block_type: String) -> void: pass
func add_door_visual(parent: Node3D, secondary: bool) -> void: pass
func add_door_interaction_proxy(parent: StaticBody3D, collider_size: Vector3, collider_offset: Vector3) -> void: pass
func interaction_block_from_collider(collider: Node) -> Node: return null
func add_ore_block_visual(parent: Node3D, block_type: String, size: Vector3, offset: Vector3) -> void: pass
func add_trader_stall_visual(parent: Node3D) -> void: pass
func create_block(cell: Vector3i, block_type: String, options: Dictionary = {}) -> StaticBody3D: return null
func is_structural_block_type(block_type: String) -> bool: return false
func block_bottom_y(block: Node3D) -> float: return 0.0
func block_touches_terrain(block: Node3D) -> bool: return false
func adjacent_structure_blocks(block: Node) -> Array: return []
func connected_structure_component(start: Node, visited: Dictionary) -> Array: return []
func structure_component_has_grounded_base(component: Array) -> bool: return false
func drop_stored_items_for_block(block: Node3D) -> void: pass
func collapse_structure_component(component: Array) -> int: return 0
func collapse_unsupported_structures() -> int: return 0
func trap_damage_at(position: Vector3, delta: float = 0.0) -> float: return 0.0
func light_safety_at(position: Vector3, include_beacon := true, range: float = CELL * 9.0) -> float: return 0.0
func destroy_target() -> void: pass
func play_melee_miss() -> void: pass
func strike_effect_for_material(material_id: String) -> String: return ""
func break_target_for_hit(hit: Dictionary, collider: Node, kind: String) -> Dictionary: return {}
func complete_destroy_target(hit: Dictionary, collider: Node, kind: String, material_id: String) -> void: pass
func complete_break_objectives(material_id: String) -> void: pass
func is_station_near(station_id: String) -> bool: return false
func terrain_material_id_for_cell(x: int, z: int) -> String: return ""
func unmet_tool_requirement_message(material_id: String) -> String: return ""
func active_tool_info() -> Dictionary: return {}
func tool_class_for_item(item_id: String) -> String: return ""
func tool_tier_for_item(item_id: String) -> int: return 0
func required_tool_label(tool_class: String, tier: int) -> String: return ""
func tool_power_for_material(material_id: String) -> float: return 0.0
func try_fire_ranged() -> bool: return false
func _on_player_projectile_hostile_hit(variant: String, defeated: bool, position: Vector3) -> void: pass
func _on_player_projectile_story_worldmark_hit(resolved: bool, position: Vector3) -> void: pass
func show_break_overlay(hit_position: Vector3, normal: Vector3, ratio: float) -> void: pass
func add_crack_line(mesh: ImmediateMesh, a: Vector3, b: Vector3) -> void: pass
func height_at_world(x: float, z: float) -> float: return 0.0
func terrain_height_cell(x: int, z: int) -> float: return 0.0
func base_height_cell(x: int, z: int) -> float: return 0.0
func natural_base_height_cell(x: int, z: int) -> float: return 0.0
func biome_at_cell(x: int, z: int) -> String: return ""
func town_region_at_cell(x: int, z: int) -> Dictionary: return {}
func town_region(region_x: int, region_z: int) -> Dictionary: return {}
func hash01(text: String) -> float: return 0.0
func tree_chance(biome: String) -> float: return 0.0
func forage_for_biome(biome: String) -> Dictionary: return {}
func forage_chance(biome: String) -> float: return 0.0
func wildlife_chance(biome: String, height: float) -> float: return 0.0
func rock_chance(biome: String, height: float) -> float: return 0.0
func ore_for_cell(biome: String, height: float, rng: RandomNumberGenerator) -> String: return ""
func noise01(noise: FastNoiseLite, x: float, z: float) -> float: return 0.0
func smoothstep_range(value: float, low: float, high: float) -> float: return 0.0
func hash_string(text: String) -> int: return 0
func world_to_cell(value: float) -> int: return 0
func cell_to_chunk(x: int, z: int) -> Vector2i: return Vector2i.ZERO
func world_to_chunk(x: float, z: float) -> Vector2i: return Vector2i.ZERO
