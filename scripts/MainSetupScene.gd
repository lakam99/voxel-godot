extends "res://scripts/MainSaveState.gd"

const DEFAULT_VISUAL_LIGHT_LAYER := 1
const SHADOW_AUTHORITATIVE_LIGHT_MASK := DEFAULT_VISUAL_LIGHT_LAYER
const STREAMING_FRAME_DEFER_NONCRITICAL_MS := 8.0
const FRAME_BUDGET_DEFER_OPTIONAL_MS := 11.0
const FRAME_BUDGET_DEFER_SIMULATION_MS := 11.5
const FRAME_BUDGET_DEFER_REMAINING_MS := 20.0
const DEFERRED_NPC_SIMULATION_DELTA_CAP := 1.0
const DEFERRED_NPC_FORCE_UPDATE_INTERVAL := 0.10
const DEFERRED_NPC_HEAVY_FRAME_FORCE_UPDATE_INTERVAL := 0.30
const NPC_SIMULATION_MAX_STEP_DELTA := 1.0 / 30.0
const DEFERRED_HOSTILE_SIMULATION_DELTA_CAP := 0.50
const DEFERRED_HOSTILE_FORCE_UPDATE_INTERVAL := 0.10
const HOSTILE_SIMULATION_MAX_STEP_DELTA := 1.0 / 30.0
const WATER_MESH_RADIUS_CELLS := 160
const WATER_MESH_STEP_CELLS := 4
const WATER_MESH_REBUILD_STEP_CELLS := 16
const WATER_MESH_BUILD_MAX_CELLS_PER_FRAME := 128
const WATER_MESH_BUILD_BUDGET_MS := 2.0
const WORLD_EDIT_FOLLOWUP_BUDGET_MS := 0.45
const WORLD_EDIT_FOLLOWUP_MAX_WORK_UNITS := 512

var last_requested_mouse_mode: int = Input.MOUSE_MODE_VISIBLE
var water_mesh_key := Vector2i(999999, 999999)
var water_mesh_requested_key := Vector2i(999999, 999999)
var water_mesh_build_state := {}
var deferred_npc_simulation_delta := 0.0
var deferred_hostile_simulation_delta := 0.0

func set_game_mouse_mode(mode: int) -> void:
    last_requested_mouse_mode = mode
    Input.set_mouse_mode(mode)

func setup_materials() -> void:
    terrain_material = load("res://resources/visual/terrain_material.tres") as Material
    if terrain_material == null:
        var fallback_terrain := StandardMaterial3D.new()
        fallback_terrain.vertex_color_use_as_albedo = true
        fallback_terrain.roughness = 0.86
        fallback_terrain.cull_mode = BaseMaterial3D.CULL_DISABLED
        terrain_material = fallback_terrain

    materials["woodBlock"] = make_building_material(Color(0.58, 0.34, 0.16), Color(0.35, 0.18, 0.07), 0.88, 0.18, 0.10, 0.30, 14.5, Color(0.19, 0.09, 0.035))
    materials["stoneBlock"] = make_building_material(Color(0.52, 0.57, 0.54), Color(0.33, 0.37, 0.35), 0.90, 0.18, 0.14)
    materials["dirtBlock"] = make_building_material(Color(0.43, 0.31, 0.20), Color(0.28, 0.19, 0.12), 0.92, 0.16, 0.07)
    materials["glass"] = make_material(Color(0.55, 0.82, 0.92, 0.42), 0.12, true)
    materials["cobblestonePath"] = make_building_material(Color(0.42, 0.46, 0.42), Color(0.26, 0.30, 0.28), 0.88, 0.16, 0.22)
    materials["workbench"] = make_building_material(Color(0.56, 0.32, 0.14), Color(0.32, 0.15, 0.06), 0.86, 0.16, 0.08, 0.34, 15.0, Color(0.18, 0.08, 0.03))
    materials["anvil"] = make_building_material(Color(0.24, 0.26, 0.26), Color(0.42, 0.44, 0.42), 0.74, 0.10, 0.06)
    materials["door"] = make_building_material(Color(0.34, 0.17, 0.07), Color(0.55, 0.30, 0.12), 0.86, 0.15, 0.05, 0.38, 16.0, Color(0.15, 0.065, 0.026))
    materials["bed"] = make_material(Color(0.60, 0.24, 0.24), 0.82)
    materials["chest"] = make_material(Color(0.50, 0.29, 0.12), 0.78)
    materials["chestBand"] = make_material(Color(0.19, 0.16, 0.12), 0.64)
    materials["bedPillow"] = make_material(Color(0.86, 0.82, 0.72), 0.76)
    materials["bedBlanket"] = make_material(Color(0.66, 0.21, 0.19), 0.80)
    materials["hingeMetal"] = make_material(Color(0.78, 0.64, 0.32), 0.46)
    materials["furnaceMouth"] = make_material(Color(0.08, 0.07, 0.06), 0.92)
    materials["furnaceGlow"] = make_emissive_material(Color(1.0, 0.66, 0.36), 0.50)
    materials["flame"] = make_emissive_material(Color(1.0, 0.73, 0.42), 0.72)
    materials["traderStall"] = make_material(Color(0.62, 0.38, 0.18), 0.78)
    materials["traderCloth"] = make_material(Color(0.79, 0.29, 0.25), 0.74)
    materials["traderClothLight"] = make_material(Color(0.86, 0.77, 0.55), 0.76)
    materials["furnace"] = make_building_material(Color(0.34, 0.36, 0.34), Color(0.20, 0.22, 0.21), 0.90, 0.12, 0.14)
    materials["campfire"] = make_material(Color(0.64, 0.34, 0.12), 0.78)
    materials["torch"] = make_material(Color(0.80, 0.52, 0.22), 0.72)
    materials["flame"] = make_emissive_material(Color(1.0, 0.62, 0.28), 0.42)
    materials["spikeTrap"] = make_material(Color(0.38, 0.31, 0.25), 0.86)
    materials["wardLantern"] = make_material(Color(0.72, 0.58, 0.28), 0.42)
    materials["sanctuaryBeacon"] = make_material(Color(0.54, 0.74, 0.92), 0.34)
    materials["riftAnchor"] = make_material(Color(0.42, 0.30, 0.62), 0.52)
    materials["trunk"] = make_material(Color(0.33, 0.18, 0.10), 0.86)
    materials["leaf"] = make_material(Color(0.17, 0.45, 0.19), 0.78)
    materials["rock"] = make_material(Color(0.40, 0.45, 0.43), 0.92)
    materials["oreBase"] = make_material(Color(0.30, 0.34, 0.33), 0.94)
    materials["copperOre"] = make_material(Color(0.84, 0.43, 0.20), 0.58)
    materials["ironOre"] = make_material(Color(0.76, 0.79, 0.74), 0.62)
    materials["copperVein"] = make_material(Color(0.78, 0.36, 0.17), 0.60)
    materials["ironVein"] = make_material(Color(0.72, 0.75, 0.70), 0.64)
    materials["copperOreGlow"] = make_emissive_material(Color(1.0, 0.54, 0.24), 0.26)
    materials["ironOreGlow"] = make_emissive_material(Color(0.88, 0.93, 0.86), 0.20)
    materials["wildlife"] = make_material(Color(0.58, 0.43, 0.30), 0.84)
    materials["wildlifeDark"] = make_material(Color(0.29, 0.22, 0.16), 0.86)
    materials["berryBush"] = make_material(Color(0.20, 0.48, 0.20), 0.82)
    materials["berryFruit"] = make_material(Color(0.82, 0.14, 0.20), 0.62)
    materials["aloePatch"] = make_material(Color(0.34, 0.66, 0.38), 0.80)
    materials["mushroomCluster"] = make_material(Color(0.73, 0.68, 0.54), 0.86)
    materials["mushroomCap"] = make_material(Color(0.64, 0.28, 0.42), 0.78)
    materials["frostHerbPatch"] = make_material(Color(0.70, 0.90, 0.92), 0.58)
    materials["detailGrass"] = make_detail_material(Color(0.34, 0.68, 0.27), 0.86, 0.018)
    materials["detailFlower"] = make_detail_material(Color(0.95, 0.64, 0.32), 0.72, 0.010)
    materials["detailReed"] = make_detail_material(Color(0.42, 0.55, 0.24), 0.86, 0.026)
    materials["detailPebble"] = make_detail_material(Color(0.48, 0.51, 0.48), 0.92, 0.0)
    materials["detailSnow"] = make_detail_material(Color(0.88, 0.93, 0.91), 0.78, 0.0)
    materials["detailScrub"] = make_detail_material(Color(0.50, 0.56, 0.26), 0.88, 0.014)
    materials["detailLeaf"] = make_detail_material(Color(0.48, 0.38, 0.18), 0.88, 0.004)
    materials["roofWood"] = make_building_material(Color(0.48, 0.23, 0.10), Color(0.28, 0.12, 0.05), 0.88, 0.16, 0.06, 0.28, 13.0, Color(0.15, 0.06, 0.025))
    materials["roofStone"] = make_building_material(Color(0.40, 0.46, 0.45), Color(0.25, 0.29, 0.28), 0.90, 0.17, 0.16)
    materials["trimWood"] = make_building_material(Color(0.30, 0.15, 0.06), Color(0.48, 0.24, 0.09), 0.88, 0.12, 0.04, 0.32, 15.0, Color(0.13, 0.05, 0.02))
    materials["trimStone"] = make_building_material(Color(0.36, 0.39, 0.37), Color(0.56, 0.58, 0.54), 0.88, 0.12, 0.10)
    materials["rawFish"] = make_material(Color(0.42, 0.72, 0.78), 0.52)
    materials["cookedFish"] = make_material(Color(0.78, 0.42, 0.24), 0.74)
    var water_material := load("res://resources/visual/water_material.tres") as Material
    if water_material == null:
        water_material = make_material(Color(0.30, 0.70, 0.78, 0.46), 0.20, true)
    if water_material is BaseMaterial3D:
        (water_material as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
    materials["water"] = water_material
    var lava_material := make_emissive_material(Color(1.0, 0.34, 0.08, 0.92), 0.95)
    lava_material.cull_mode = BaseMaterial3D.CULL_DISABLED
    materials["lava"] = lava_material
    materials["sunDisc"] = make_unshaded_material(Color(1.0, 0.82, 0.38))
    materials["moonDisc"] = make_unshaded_material(Color(0.72, 0.78, 0.94))

func make_material(color: Color, roughness: float = 0.82, transparent: bool = false) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = roughness
    if transparent:
        material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    return material

func make_detail_material(color: Color, roughness: float, wind_strength: float) -> ShaderMaterial:
    var material := ShaderMaterial.new()
    material.shader = load("res://resources/visual/detail_material.gdshader") as Shader
    material.set_shader_parameter("base_color", color)
    material.set_shader_parameter("roughness", roughness)
    material.set_shader_parameter("wind_strength", wind_strength)
    return material

func make_building_material(
    color: Color,
    accent: Color,
    roughness: float,
    breakup_strength: float,
    grid_strength: float,
    grain_strength: float = 0.0,
    grain_scale: float = 13.0,
    grain_color: Color = Color(0.20, 0.10, 0.04)
) -> ShaderMaterial:
    var material := ShaderMaterial.new()
    material.shader = load("res://resources/visual/building_material.gdshader") as Shader
    material.set_shader_parameter("base_color", color)
    material.set_shader_parameter("accent_color", accent)
    material.set_shader_parameter("roughness", roughness)
    material.set_shader_parameter("breakup_strength", breakup_strength)
    material.set_shader_parameter("grid_strength", grid_strength)
    material.set_shader_parameter("grain_strength", grain_strength)
    material.set_shader_parameter("grain_scale", grain_scale)
    material.set_shader_parameter("grain_color", grain_color)
    return material

func make_emissive_material(color: Color, energy: float) -> StandardMaterial3D:
    var material := make_material(color, 0.48)
    material.emission_enabled = true
    material.emission = color
    material.emission_energy_multiplier = energy
    return material

func make_unshaded_material(color: Color) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = 1.0
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    return material

func setup_visual_style() -> void:
    if visual_style == null:
        visual_style = DEFAULT_VISUAL_STYLE.duplicate(true)

func setup_environment() -> void:
    setup_visual_style()
    world_environment = WorldEnvironment.new()
    var env := Environment.new()
    sky_material = ProceduralSkyMaterial.new()
    sky_resource = Sky.new()
    sky_resource.sky_material = sky_material
    env.background_mode = Environment.BG_SKY
    env.sky = sky_resource
    env.background_color = visual_style.day_sky_horizon
    env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
    env.ambient_light_color = visual_style.ambient_day
    env.ambient_light_energy = visual_style.ambient_max_energy
    env.ambient_light_sky_contribution = visual_style.ambient_sky_contribution
    env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    env.tonemap_exposure = visual_style.tonemap_exposure
    env.tonemap_white = visual_style.tonemap_white
    env.fog_enabled = true
    env.fog_light_color = visual_style.fog_day
    env.fog_light_energy = visual_style.fog_light_energy
    env.fog_density = visual_style.fog_density_day
    env.fog_sky_affect = visual_style.fog_sky_affect
    env.fog_sun_scatter = visual_style.fog_sun_scatter
    env.set("ssao_enabled", visual_style.ssao_enabled)
    env.set("ssao_radius", visual_style.ssao_radius)
    env.set("ssao_intensity", visual_style.ssao_intensity)
    env.set("ssao_power", visual_style.ssao_power)
    world_environment.environment = env
    add_child(world_environment)

    sun = DirectionalLight3D.new()
    sun.name = "Sun"
    sun.light_color = visual_style.sun_color_day
    sun.light_energy = visual_style.sun_max_energy
    sun.light_cull_mask = SHADOW_AUTHORITATIVE_LIGHT_MASK
    sun.shadow_enabled = true
    configure_directional_shadow_style(sun, visual_style.sun_angular_distance)
    add_child(sun)

    moon = DirectionalLight3D.new()
    moon.name = "Moon"
    moon.light_color = visual_style.moon_color
    moon.light_energy = visual_style.moon_max_energy
    moon.light_cull_mask = SHADOW_AUTHORITATIVE_LIGHT_MASK
    moon.shadow_enabled = false
    configure_directional_shadow_style(moon, visual_style.moon_angular_distance)
    add_child(moon)

    sun_visual = make_sky_body("SunDisc", materials["sunDisc"], visual_style.sun_disc_radius)
    moon_visual = make_sky_body("MoonDisc", materials["moonDisc"], visual_style.moon_disc_radius)
    add_child(sun_visual)
    add_child(moon_visual)

    water = MeshInstance3D.new()
    water.name = "Water"
    water.material_override = materials["water"]
    water.position.y = WATER_LEVEL
    water.mesh = ArrayMesh.new()
    add_child(water)

    weather_system = WeatherSystemScript.new()
    weather_system.name = "Weather"
    weather_system.setup(self, seed_hash, biome_environment_catalog)
    add_child(weather_system)
    update_sky(0.0)

func configure_directional_shadow_style(light: DirectionalLight3D, angular_distance: float) -> void:
    light.set("directional_shadow_max_distance", visual_style.shadow_max_distance)
    light.set("directional_shadow_fade_start", visual_style.shadow_fade_start)
    light.set("shadow_blur", visual_style.shadow_blur)
    light.set("light_angular_distance", angular_distance)

func setup_break_overlay() -> void:
    break_material = StandardMaterial3D.new()
    break_material.albedo_color = Color(0.05, 0.045, 0.035, 0.95)
    break_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    break_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    break_overlay = MeshInstance3D.new()
    break_overlay.name = "BreakageOverlay"
    break_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    var prime_mesh := ImmediateMesh.new()
    prime_mesh.surface_begin(Mesh.PRIMITIVE_LINES, break_material)
    prime_mesh.surface_add_vertex(Vector3(0.0, -10000.0, 0.0))
    prime_mesh.surface_add_vertex(Vector3(0.01, -10000.0, 0.0))
    prime_mesh.surface_end()
    break_overlay.mesh = prime_mesh
    break_overlay.visible = true
    add_child(break_overlay)

func make_sky_body(node_name: String, material: Material, radius: float) -> MeshInstance3D:
    var mesh := SphereMesh.new()
    mesh.radius = radius
    mesh.height = radius * 2.0
    mesh.radial_segments = 32
    mesh.rings = 16
    var body := MeshInstance3D.new()
    body.name = node_name
    body.mesh = mesh
    body.material_override = material
    body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return body

func setup_player() -> void:
    player = CharacterBody3D.new()
    player.name = "Player"
    player.set_script(PlayerController)
    player.main = self
    player.survival = survival_system
    player.position = find_spawn_position()
    add_child(player)

func setup_hostiles() -> void:
    hostile_system = HostileSystemScript.new()
    hostile_system.name = "Hostiles"
    hostile_system.setup(self, player, survival_system, inventory_system)
    add_child(hostile_system)

func setup_npc_system() -> void:
    npc_system = NpcSystemScript.new()
    npc_system.name = "NPCs"
    add_child(npc_system)
    npc_system.setup(self, hostile_system)

func setup_player_projectiles() -> void:
    player_projectiles = PlayerProjectileSystemScript.new()
    player_projectiles.name = "PlayerProjectiles"
    player_projectiles.setup(player, inventory_system, hostile_system, ItemCatalogScript.ITEMS, blocks)
    player_projectiles.hostile_hit.connect(_on_player_projectile_hostile_hit)
    player_projectiles.story_worldmark_hit.connect(_on_player_projectile_story_worldmark_hit)
    add_child(player_projectiles)

func setup_held_item() -> void:
    if not player or not player.camera:
        return
    held_item = HeldItemSystemScript.new()
    held_item.name = "HeldItem"
    player.camera.add_child(held_item)
    held_item.setup(inventory_system, static_item_asset_registry)

func find_spawn_position() -> Vector3:
    var best_cell := find_spawn_cell(CELL * 0.35)
    if best_cell == Vector2i(999999, 999999):
        best_cell = find_spawn_cell(CELL * 0.9)
    if best_cell == Vector2i(999999, 999999):
        best_cell = find_spawn_cell(CELL * 1.6)
    if best_cell == Vector2i(999999, 999999):
        best_cell = Vector2i(0, 28)
    var spawn_height: float = surface_y_at_cell(Vector3i(best_cell.x, 0, best_cell.y))
    return Vector3(best_cell.x * CELL, spawn_height + 5.0, best_cell.y * CELL)

func find_spawn_cell(max_variation: float) -> Vector2i:
    var best_cell := Vector2i(999999, 999999)
    var best_score: float = -999999.0
    for z in range(-72, 73):
        for x in range(-72, 73):
            var h: float = surface_y_at_cell(Vector3i(x, 0, z))
            if h <= WATER_LEVEL + 2.4:
                continue
            var variation: float = height_variation_cell(x, z, 2)
            if variation > max_variation:
                continue
            var biome: String = surface_biome_at_cell(Vector3i(x, 0, z))
            var biome_score: float = 0.0
            if biome == "plains" or biome == "forest" or biome == "savanna":
                biome_score = 18.0
            elif biome == "beach":
                biome_score = 6.0
            elif biome == "alpine" or biome == "snow":
                biome_score = -20.0
            var distance_penalty: float = Vector2(float(x), float(z)).length() * 0.18
            var score: float = biome_score - variation * 8.0 - distance_penalty
            if score > best_score:
                best_score = score
                best_cell = Vector2i(x, z)
    return best_cell

func height_variation_cell(x: int, z: int, radius: int) -> float:
    var center_height: float = surface_y_at_cell(Vector3i(x, 0, z))
    var max_delta := 0.0
    for dz in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            var sample_height: float = surface_y_at_cell(Vector3i(x + dx, 0, z + dz))
            max_delta = max(max_delta, abs(sample_height - center_height))
    return max_delta

func setup_hud() -> void:
    hud = GameHudScript.new()
    hud.name = "HUD"
    add_child(hud)
    hud.setup(inventory_system, crafting_system, objective_system, equipment_system, contract_system, story_journal_model)
    hud.slot_clicked.connect(_on_ui_slot_clicked)
    hud.slot_moved.connect(_on_ui_slot_moved)
    hud.craft_requested.connect(_on_craft_requested)
    hud.utility_action_requested.connect(_on_utility_action_requested)
    hud.teleport_requested.connect(_on_teleport_requested)
    hud.equipment_slot_clicked.connect(_on_equipment_slot_clicked)
    hud.setting_changed.connect(_on_setting_changed)
    hud.playtest_requested.connect(_on_playtest_requested)
    hud.playtest_cleanup_requested.connect(_on_playtest_cleanup_requested)
    hud.resume_requested.connect(_on_resume_requested)
    hud.new_game_requested.connect(_on_new_game_requested)
    hud.quit_requested.connect(_on_quit_requested)
    hud.dialogue_closed.connect(_on_dialogue_closed)
    hud.set_settings_state(runtime_settings)
    hud.set_playtest_cases(playtest_case_specs())
    apply_runtime_settings()

func setup_tutorial_system() -> void:
    tutorial_system = TutorialSystemScript.new()
    tutorial_system.name = "TutorialSystem"
    add_child(tutorial_system)
    tutorial_system.setup(self)

func setup_audio_effects() -> void:
    audio_effects = AudioEffectsSystemScript.new()
    audio_effects.name = "AudioEffects"
    add_child(audio_effects)
    if audio_effects.has_method("prime_materials"):
        var feedback_colors := [
            Color(0.72, 0.68, 0.58),
            Color(0.39, 0.27, 0.16),
            Color(0.82, 0.72, 0.46),
            Color(0.86, 0.91, 0.90),
            BIOME_COLORS["plains"].lightened(0.12)
        ]
        for material_value in materials.values():
            var material := material_value as StandardMaterial3D
            if material != null:
                feedback_colors.append(material.albedo_color)
        audio_effects.prime_materials(feedback_colors)

func play_feedback(effect_name: String, position := Vector3.INF, color := Color.WHITE, count := 0) -> void:
    if audio_effects == null:
        return
    audio_effects.play(effect_name)
    if count <= 0:
        return
    var effect_position: Vector3 = position
    if effect_position == Vector3.INF:
        effect_position = player.global_position + Vector3(0.0, 1.25, 0.0) if player else Vector3.ZERO
    audio_effects.burst(effect_position, color, count)

func refresh_intro_knock_audio() -> void:
    if audio_effects == null:
        return
    var should_knock: bool = tutorial_system != null and tutorial_system.has_method("should_loop_intro_knock") and bool(tutorial_system.should_loop_intro_knock())
    if should_knock and audio_effects.has_method("start_knock_loop"):
        audio_effects.start_knock_loop()
    elif audio_effects.has_method("stop_knock_loop"):
        audio_effects.stop_knock_loop()

func show_tutorial_dialogue(fallback_message: String) -> void:
    if tutorial_system == null or hud == null or not tutorial_system.has_method("dialogue_payload"):
        update_hud(fallback_message)
        return
    var dialogue: Dictionary = tutorial_system.dialogue_payload()
    if dialogue.is_empty():
        update_hud(fallback_message)
        return
    if tutorial_system.has_method("focus_dialogue_npc"):
        tutorial_system.focus_dialogue_npc()
    hud.show_dialogue(
        String(dialogue.get("speaker", "Villager")),
        String(dialogue.get("role", "")),
        String(dialogue.get("text", fallback_message)),
        dialogue
    )
    set_game_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    update_hud("", true)

func capture_mouse_if_no_modal() -> void:
    if hud == null:
        set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)
        return
    if not (
        hud.is_inventory_open()
        or hud.is_utility_open()
        or hud.is_teleport_open()
        or hud.is_objectives_open()
        or hud.is_contracts_open()
        or hud.is_settings_open()
        or hud.is_playtest_open()
        or hud.is_game_menu_open()
        or hud.is_dialogue_open()
    ):
        set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func disable_collision_shapes_recursive(node: Node) -> void:
    for child in node.get_children():
        var collider := child as CollisionShape3D
        if collider:
            collider.disabled = true
        disable_collision_shapes_recursive(child)

func spawn_falling_tree_visual(tree: Node3D) -> void:
    if tree == null or tree.get_parent() == null:
        return
    var visual := tree.duplicate() as Node3D
    if visual == null:
        return
    visual.name = "FallingTree"
    tree.get_parent().add_child(visual)
    visual.global_transform = tree.global_transform
    visual.set_meta("kind", "falling")
    disable_collision_shapes_recursive(visual)

    var target_rotation := visual.rotation
    var fall_axis_z := true
    var direction := 1.0
    if player:
        var offset := player.global_position - tree.global_position
        fall_axis_z = abs(offset.x) > abs(offset.z)
        direction = sign(offset.x) if fall_axis_z else -sign(offset.z)
        if is_zero_approx(direction):
            direction = 1.0
    if fall_axis_z:
        target_rotation.z += direction * (PI / 2.15)
    else:
        target_rotation.x += direction * (PI / 2.15)

    var tween := create_tween()
    tween.set_trans(Tween.TRANS_SINE)
    tween.set_ease(Tween.EASE_IN_OUT)
    tween.tween_property(visual, "rotation", target_rotation, 1.15)
    tween.tween_interval(0.25)
    tween.tween_callback(Callable(visual, "queue_free"))

func feedback_color_for_material(material_id: String) -> Color:
    var key := material_id
    if key == "tree":
        key = "trunk"
    elif key == "grass":
        return BIOME_COLORS["plains"].lightened(0.12)
    elif key == "dirt" or key == "mud":
        return Color(0.39, 0.27, 0.16)
    elif key == "sand":
        return Color(0.82, 0.72, 0.46)
    elif key == "snow":
        return Color(0.86, 0.91, 0.90)
    elif key == "stone":
        key = "stoneBlock"
    if materials.has(key):
        var material := materials[key] as StandardMaterial3D
        if material:
            return material.albedo_color
    return Color(0.72, 0.68, 0.58)

func update_water_surface_mesh() -> void:
    if water == null or player == null:
        return
    var center_cell := Vector2i(roundi(player.position.x / CELL), roundi(player.position.z / CELL))
    var key := Vector2i(
        floori(float(center_cell.x) / float(WATER_MESH_REBUILD_STEP_CELLS)),
        floori(float(center_cell.y) / float(WATER_MESH_REBUILD_STEP_CELLS))
    )
    if key != water_mesh_key and key != water_mesh_requested_key:
        water_mesh_requested_key = key
    if water_mesh_build_state.is_empty():
        if water_mesh_requested_key == water_mesh_key:
            return
        water_mesh_build_state = begin_water_surface_mesh_build(water_mesh_requested_key)
    var advanced := advance_water_surface_mesh_build(water_mesh_build_state)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.increment_counter("water_surface_cells_processed", int(advanced.get("processed", 0)))
    if not bool(advanced.get("complete", false)):
        return
    var completed_key: Vector2i = water_mesh_build_state.get("key", water_mesh_requested_key)
    var mesh_center: Vector2i = water_mesh_build_state.get("centerCell", Vector2i.ZERO)
    water.position = Vector3(float(mesh_center.x) * CELL, WATER_LEVEL, float(mesh_center.y) * CELL)
    water.mesh = water_surface_mesh_from_build_state(water_mesh_build_state)
    water_mesh_key = completed_key
    water_mesh_build_state = {}
    if runtime_perf_monitor != null:
        runtime_perf_monitor.increment_counter("water_surface_rebuilds_completed")

func begin_water_surface_mesh_build(key: Vector2i) -> Dictionary:
    var mesh_center := Vector2i(key.x * WATER_MESH_REBUILD_STEP_CELLS, key.y * WATER_MESH_REBUILD_STEP_CELLS)
    var grid_width := ceili(float(WATER_MESH_RADIUS_CELLS * 2) / float(WATER_MESH_STEP_CELLS))
    return {
        "key": key,
        "centerCell": mesh_center,
        "cursor": 0,
        "gridWidth": grid_width,
        "totalCells": grid_width * grid_width,
        "vertices": PackedVector3Array(),
        "normals": PackedVector3Array(),
        "uvs": PackedVector2Array(),
        "indices": PackedInt32Array()
    }

func advance_water_surface_mesh_build(state: Dictionary) -> Dictionary:
    if state.is_empty():
        return {"complete": true, "processed": 0}
    var started_usec := Time.get_ticks_usec()
    var center_cell: Vector2i = state.get("centerCell", Vector2i.ZERO)
    var grid_width := int(state.get("gridWidth", 0))
    var total_cells := int(state.get("totalCells", 0))
    var cursor := int(state.get("cursor", 0))
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var uvs := PackedVector2Array()
    var indices := PackedInt32Array()
    if state.get("vertices", PackedVector3Array()) is PackedVector3Array:
        vertices = state.get("vertices", PackedVector3Array())
    if state.get("normals", PackedVector3Array()) is PackedVector3Array:
        normals = state.get("normals", PackedVector3Array())
    if state.get("uvs", PackedVector2Array()) is PackedVector2Array:
        uvs = state.get("uvs", PackedVector2Array())
    if state.get("indices", PackedInt32Array()) is PackedInt32Array:
        indices = state.get("indices", PackedInt32Array())
    var origin_x := float(center_cell.x) * CELL
    var origin_z := float(center_cell.y) * CELL
    var half := WATER_MESH_RADIUS_CELLS
    var step := WATER_MESH_STEP_CELLS
    var processed := 0
    while cursor < total_cells and processed < WATER_MESH_BUILD_MAX_CELLS_PER_FRAME:
        if processed > 0 and profiled_ms(started_usec) >= WATER_MESH_BUILD_BUDGET_MS:
            break
        var x_index := cursor % grid_width
        var z_index := cursor / grid_width
        var x_offset := -half + x_index * step
        var z_offset := -half + z_index * step
        var sample_x := center_cell.x + x_offset + step / 2
        var sample_z := center_cell.y + z_offset + step / 2
        if water_surface_cell_has_natural_water(sample_x, sample_z):
            var base_index := vertices.size()
            var x0 := float(center_cell.x + x_offset) * CELL - origin_x
            var z0 := float(center_cell.y + z_offset) * CELL - origin_z
            var x1 := float(center_cell.x + x_offset + step) * CELL - origin_x
            var z1 := float(center_cell.y + z_offset + step) * CELL - origin_z
            vertices.append(Vector3(x0, 0.0, z0))
            vertices.append(Vector3(x1, 0.0, z0))
            vertices.append(Vector3(x0, 0.0, z1))
            vertices.append(Vector3(x1, 0.0, z1))
            normals.append(Vector3.UP)
            normals.append(Vector3.UP)
            normals.append(Vector3.UP)
            normals.append(Vector3.UP)
            uvs.append(Vector2(float(center_cell.x + x_offset), float(center_cell.y + z_offset)))
            uvs.append(Vector2(float(center_cell.x + x_offset + step), float(center_cell.y + z_offset)))
            uvs.append(Vector2(float(center_cell.x + x_offset), float(center_cell.y + z_offset + step)))
            uvs.append(Vector2(float(center_cell.x + x_offset + step), float(center_cell.y + z_offset + step)))
            indices.append(base_index)
            indices.append(base_index + 2)
            indices.append(base_index + 1)
            indices.append(base_index + 1)
            indices.append(base_index + 2)
            indices.append(base_index + 3)
        cursor += 1
        processed += 1
    state["cursor"] = cursor
    state["vertices"] = vertices
    state["normals"] = normals
    state["uvs"] = uvs
    state["indices"] = indices
    return {
        "complete": cursor >= total_cells,
        "processed": processed
    }

func water_surface_mesh_from_build_state(state: Dictionary) -> ArrayMesh:
    var mesh := ArrayMesh.new()
    var vertices: PackedVector3Array = state.get("vertices", PackedVector3Array())
    if vertices.is_empty():
        return mesh
    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = state.get("normals", PackedVector3Array())
    arrays[Mesh.ARRAY_TEX_UV] = state.get("uvs", PackedVector2Array())
    arrays[Mesh.ARRAY_INDEX] = state.get("indices", PackedInt32Array())
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func water_surface_cell_has_natural_water(cell_x: int, cell_z: int) -> bool:
    var surface_y := 0.0
    if world_generation_system != null and world_generation_system.has_method("terrain_reference_surface_y_for_cell"):
        surface_y = float(world_generation_system.call("terrain_reference_surface_y_for_cell", Vector3i(cell_x, 0, cell_z)))
    else:
        surface_y = natural_surface_y_at_cell(Vector3i(cell_x, 0, cell_z))
    return surface_y <= float(WATER_LEVEL) + 0.30

func advance_world_clock(delta: float) -> bool:
    var freeze_intro_night: bool = tutorial_system != null and tutorial_system.has_method("should_freeze_intro_night") and bool(tutorial_system.should_freeze_intro_night())
    if freeze_intro_night:
        time_of_day = 0.86
    else:
        time_of_day = fposmod(time_of_day + delta / DAY_LENGTH, 1.0)
    return freeze_intro_night

func _process(delta: float) -> void:
    var frame_start := Time.get_ticks_usec()
    var trace_post_startup := post_startup_trace_frames > 0
    if trace_post_startup:
        startup_loading_step.emit("Runtime frame: start")
    if runtime_perf_monitor != null:
        runtime_perf_monitor.begin_frame(delta)
    world_elapsed += delta
    if player:
        if trace_post_startup:
            startup_loading_step.emit("Runtime frame: chunks")
        var chunk_start := Time.get_ticks_usec()
        update_chunks(false)
        perf_chunk_ms = profiled_ms(chunk_start)
        if runtime_perf_monitor != null:
            runtime_perf_monitor.observe_duration("chunk", perf_chunk_ms)
        if trace_post_startup:
            startup_loading_step.emit("Runtime frame: chunks done %.2fms" % perf_chunk_ms)
        var water_surface_start: int = runtime_perf_monitor.begin_section("water_surface") if runtime_perf_monitor != null else Time.get_ticks_usec()
        update_water_surface_mesh()
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("water_surface", water_surface_start)
    var defer_noncritical_frame_work := perf_chunk_ms >= STREAMING_FRAME_DEFER_NONCRITICAL_MS
    var world_edit_start: int = runtime_perf_monitor.begin_section("world_edit_followup") if runtime_perf_monitor != null else Time.get_ticks_usec()
    process_world_edit_followups()
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("world_edit_followup", world_edit_start)
    var tutorial_realtime_simulation := tutorial_realtime_simulation_required()
    if trace_post_startup:
        startup_loading_step.emit("Runtime frame: sky")
    var sky_start := Time.get_ticks_usec()
    update_sky(delta)
    update_local_light_rig_lod(delta)
    perf_sky_ms = profiled_ms(sky_start)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("sky", perf_sky_ms)
    if trace_post_startup:
        startup_loading_step.emit("Runtime frame: sky done %.2fms" % perf_sky_ms)
    var sleep_transition_start: int = runtime_perf_monitor.begin_section("sleep_transition") if runtime_perf_monitor != null else Time.get_ticks_usec()
    update_sleep_transition(delta)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("sleep_transition", sleep_transition_start)
    var utility_start := Time.get_ticks_usec()
    var defer_utility := should_defer_frame_work(frame_start, defer_noncritical_frame_work, FRAME_BUDGET_DEFER_OPTIONAL_MS)
    if defer_utility:
        perf_utility_ms = 0.0
        increment_defer_counter("streaming_frame_utility_deferred", "frame_budget_utility_deferred", defer_noncritical_frame_work)
    elif utility_system:
        utility_system.update(delta)
        perf_utility_ms = profiled_ms(utility_start)
    else:
        perf_utility_ms = 0.0
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("utility", perf_utility_ms)
    var pickups_start := Time.get_ticks_usec()
    var defer_pickups := should_defer_frame_work(frame_start, defer_noncritical_frame_work, FRAME_BUDGET_DEFER_OPTIONAL_MS)
    if defer_pickups:
        perf_pickups_ms = 0.0
        increment_defer_counter("streaming_frame_pickups_deferred", "frame_budget_pickups_deferred", defer_noncritical_frame_work)
    else:
        update_dropped_pickups(delta)
        perf_pickups_ms = profiled_ms(pickups_start)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("pickups", perf_pickups_ms)
    var wildlife_start: int = runtime_perf_monitor.begin_section("wildlife") if runtime_perf_monitor != null else Time.get_ticks_usec()
    var defer_wildlife := should_defer_frame_work(frame_start, defer_noncritical_frame_work, FRAME_BUDGET_DEFER_OPTIONAL_MS)
    if defer_wildlife:
        increment_defer_counter("streaming_frame_wildlife_deferred", "frame_budget_wildlife_deferred", defer_noncritical_frame_work)
    else:
        update_wildlife(delta)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("wildlife", wildlife_start)
    var survival_start := Time.get_ticks_usec()
    var defer_survival := should_defer_frame_work(frame_start, defer_noncritical_frame_work, FRAME_BUDGET_DEFER_OPTIONAL_MS)
    if defer_survival:
        perf_survival_ms = 0.0
        increment_defer_counter("streaming_frame_survival_deferred", "frame_budget_survival_deferred", defer_noncritical_frame_work)
    else:
        update_survival(delta)
        perf_survival_ms = profiled_ms(survival_start)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("survival", perf_survival_ms)
    var hostiles_start := Time.get_ticks_usec()
    var hostile_defer_requested := not tutorial_realtime_simulation and should_defer_frame_work(frame_start, defer_noncritical_frame_work, FRAME_BUDGET_DEFER_SIMULATION_MS)
    var hostile_deferred_total := minf(deferred_hostile_simulation_delta + delta, DEFERRED_HOSTILE_SIMULATION_DELTA_CAP)
    var defer_hostiles := hostile_defer_requested and hostile_deferred_total < DEFERRED_HOSTILE_FORCE_UPDATE_INTERVAL
    if defer_hostiles:
        perf_hostiles_ms = 0.0
        deferred_hostile_simulation_delta = hostile_deferred_total
        increment_defer_counter("streaming_frame_hostiles_deferred", "frame_budget_hostiles_deferred", defer_noncritical_frame_work)
    else:
        var hostile_delta := minf(hostile_deferred_total, HOSTILE_SIMULATION_MAX_STEP_DELTA)
        deferred_hostile_simulation_delta = maxf(0.0, hostile_deferred_total - hostile_delta)
        if hostile_defer_requested and runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("frame_budget_hostiles_forced_after_defer")
        if deferred_hostile_simulation_delta > 0.0001 and runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("frame_budget_hostiles_delta_carried")
        update_hostiles(hostile_delta)
        perf_hostiles_ms = profiled_ms(hostiles_start)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hostiles", perf_hostiles_ms)
    if trace_post_startup:
        startup_loading_step.emit("Runtime frame: npcs")
    var npc_start := Time.get_ticks_usec()
    var heavy_after_hostiles := not tutorial_realtime_simulation and profiled_ms(frame_start) >= FRAME_BUDGET_DEFER_SIMULATION_MS
    var npc_defer_requested := not tutorial_realtime_simulation and (should_defer_frame_work(frame_start, defer_noncritical_frame_work, FRAME_BUDGET_DEFER_SIMULATION_MS) or heavy_after_hostiles)
    var npc_deferred_total := minf(deferred_npc_simulation_delta + delta, DEFERRED_NPC_SIMULATION_DELTA_CAP)
    var npc_force_interval := DEFERRED_NPC_HEAVY_FRAME_FORCE_UPDATE_INTERVAL if heavy_after_hostiles else DEFERRED_NPC_FORCE_UPDATE_INTERVAL
    var defer_npc := npc_defer_requested and npc_deferred_total < npc_force_interval
    if defer_npc:
        perf_npc_ms = 0.0
        deferred_npc_simulation_delta = npc_deferred_total
        increment_defer_counter("streaming_frame_npc_deferred", "frame_budget_npc_deferred", defer_noncritical_frame_work)
    else:
        var npc_delta := minf(npc_deferred_total, NPC_SIMULATION_MAX_STEP_DELTA)
        deferred_npc_simulation_delta = maxf(0.0, npc_deferred_total - npc_delta)
        if npc_defer_requested and runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("frame_budget_npc_forced_after_defer")
        if deferred_npc_simulation_delta > 0.0001 and runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("frame_budget_npc_delta_carried")
        update_npcs(npc_delta)
        perf_npc_ms = profiled_ms(npc_start)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("update_npcs", perf_npc_ms)
    if trace_post_startup:
        startup_loading_step.emit("Runtime frame: npcs done %.2fms" % perf_npc_ms)
    var aftermath_collapse_start: int = runtime_perf_monitor.begin_section("aftermath_collapse") if runtime_perf_monitor != null else Time.get_ticks_usec()
    if region_aftermath_system:
        region_aftermath_system.update(delta)
    handle_collapse_if_needed()
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("aftermath_collapse", aftermath_collapse_start)
    var defer_remaining_frame_work := defer_noncritical_frame_work or profiled_ms(frame_start) >= FRAME_BUDGET_DEFER_REMAINING_MS
    var beacon_start := Time.get_ticks_usec()
    if defer_remaining_frame_work:
        perf_beacon_ms = 0.0
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("frame_budget_beacon_deferred")
    else:
        update_beacon_charge(delta)
        perf_beacon_ms = profiled_ms(beacon_start)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("beacon", perf_beacon_ms)
    if defer_remaining_frame_work:
        perf_autosave_ms = 0.0
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("frame_budget_autosave_deferred")
    else:
        process_autosave(delta)
    var break_start := Time.get_ticks_usec()
    update_break_reset(delta)
    perf_break_ms = profiled_ms(break_start)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("break", perf_break_ms)
    var hud_start := Time.get_ticks_usec()
    if defer_remaining_frame_work:
        perf_hud_ms = 0.0
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("frame_budget_hud_deferred")
    else:
        update_hud_frame(delta)
        perf_hud_ms = profiled_ms(hud_start)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud", perf_hud_ms)
    var performance_overlay_start: int = runtime_perf_monitor.begin_section("performance_overlay") if runtime_perf_monitor != null else Time.get_ticks_usec()
    update_performance_overlay(delta)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("performance_overlay", performance_overlay_start)
    perf_frame_ms = profiled_ms(frame_start)
    if runtime_perf_monitor != null:
        perf_frame_ms = runtime_perf_monitor.end_frame()
        perf_route_plan_ms = runtime_perf_monitor.section_ms("route_planning")
        perf_nav_snapshot_ms = runtime_perf_monitor.section_ms("navigation_snapshot_rebuild")
        perf_job_scan_ms = runtime_perf_monitor.section_ms("job_forage_scan")
    if trace_post_startup:
        startup_loading_step.emit("Runtime frame: done %.2fms" % perf_frame_ms)
        post_startup_trace_frames -= 1

func profiled_ms(start_usec: int) -> float:
    return float(Time.get_ticks_usec() - start_usec) / 1000.0

func tutorial_realtime_simulation_required() -> bool:
    if tutorial_system == null:
        return false
    if tutorial_system.has_method("state"):
        var state: Dictionary = tutorial_system.call("state")
        return bool(state.get("started", false)) and not bool(state.get("finalNightComplete", false))
    return bool(tutorial_system.get("started")) and not bool(tutorial_system.get("final_night_complete"))

func should_defer_frame_work(frame_start_usec: int, streaming_deferred: bool, budget_ms: float) -> bool:
    return streaming_deferred or profiled_ms(frame_start_usec) >= budget_ms

func increment_defer_counter(streaming_counter: String, budget_counter: String, streaming_deferred: bool) -> void:
    if runtime_perf_monitor == null:
        return
    runtime_perf_monitor.increment_counter(streaming_counter if streaming_deferred else budget_counter)
