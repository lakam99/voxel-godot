extends "res://scripts/MainSetupScene.gd"

func update_sky(delta: float) -> void:
    var freeze_intro_night: bool = tutorial_system != null and tutorial_system.has_method("should_freeze_intro_night") and bool(tutorial_system.should_freeze_intro_night())
    if freeze_intro_night:
        time_of_day = 0.86
    else:
        time_of_day = fposmod(time_of_day + delta / DAY_LENGTH, 1.0)
    var phase := clock_phase()
    var day := clock_day_factor()
    var night := clock_night_factor()
    update_fire_light_day_factor(day)
    var sun_progress := daylight_progress(phase)
    var moon_progress := wrapped_clock_progress(MOONRISE_CLOCK, MOONSET_CLOCK, phase)
    if visual_style == null:
        setup_visual_style()
    var warmth: float = float(visual_style.sunset_amount(sun_progress, day))
    var sun_dir := Vector3(lerpf(-0.82, 0.82, sun_progress), maxf(0.025, sin(sun_progress * PI)), -0.34).normalized()
    var moon_dir := Vector3(lerpf(0.78, -0.78, moon_progress), maxf(0.035, sin(moon_progress * PI)), 0.28).normalized()
    orient_directional_light(sun, sun_dir)
    orient_directional_light(moon, moon_dir)

    var observer := Vector3.ZERO
    if player:
        observer = player.global_position
    sun_visual.global_position = observer + sun_dir * SKY_RADIUS
    moon_visual.global_position = observer + moon_dir * SKY_RADIUS
    sun_visual.visible = day > 0.025
    moon_visual.visible = clock_in_wrapped_range(phase, MOONRISE_CLOCK, MOONSET_CLOCK) and night > 0.025

    sun.light_color = visual_style.sun_light_color(warmth)
    sun.light_energy = lerpf(visual_style.sun_min_energy, visual_style.sun_max_energy, day) * (1.0 + warmth * visual_style.sunset_sun_boost)
    sun.shadow_enabled = shadows_enabled and day > 0.18 and sun_visual.visible
    moon.light_color = visual_style.moon_color
    moon.light_energy = lerpf(visual_style.moon_max_energy, visual_style.moon_min_energy, day)
    moon.shadow_enabled = shadows_enabled and night > 0.45 and moon_visual.visible

    apply_environment_style(day, warmth, 0.0)
    if weather_system:
        var cell := Vector2i(world_to_cell(observer.x), world_to_cell(observer.z))
        var biome := biome_at_cell(cell.x, cell.y)
        var weather_state: Dictionary
        if freeze_intro_night:
            weather_system.force_weather("rain", 0.88, 0.94, observer)
            weather_state = weather_system.snapshot()
        else:
            weather_state = weather_system.update_weather(delta, observer, biome, day, time_of_day)
        apply_weather_lighting(weather_state, day)
        if audio_effects and audio_effects.has_method("update_weather_ambience"):
            audio_effects.update_weather_ambience(weather_state)
    elif audio_effects and audio_effects.has_method("update_weather_ambience"):
        audio_effects.update_weather_ambience({ "kind": "clear", "intensity": 0.0 })
    update_music_state(observer, day)

func update_fire_light_day_factor(day: float) -> void:
    for light in get_tree().get_nodes_in_group("fire_lights"):
        if light != null and light.has_method("set_day_factor"):
            light.set_day_factor(day)

func update_local_light_rig_lod(delta: float) -> void:
    local_light_lod_elapsed += delta
    if local_light_lod_elapsed < 0.25:
        update_terrain_local_light_uniforms()
        return
    local_light_lod_elapsed = 0.0
    if player == null or get_tree() == null:
        update_terrain_local_light_uniforms()
        return
    var observer := player.global_position
    var candidates := []
    for light_value in get_tree().get_nodes_in_group("local_light_rig_fill"):
        if not is_instance_valid(light_value):
            continue
        var light := light_value as Light3D
        if light == null:
            continue
        if bool(light.get_meta("held_world_ground_fill", false)):
            if light.has_method("set_lod_visible"):
                light.set_lod_visible(true)
            continue
        var distance := observer.distance_to(light.global_position)
        var max_distance := float(light.get_meta("rig_lod_distance", 56.0))
        if distance <= max_distance:
            candidates.append({ "light": light, "distance": distance })
        elif light.has_method("set_lod_visible"):
            light.set_lod_visible(false)
    candidates.sort_custom(func(a, b): return float(a["distance"]) < float(b["distance"]))
    var max_active := 48
    for index in range(candidates.size()):
        var light := candidates[index]["light"] as Light3D
        if light != null and light.has_method("set_lod_visible"):
            light.set_lod_visible(index < max_active)
    update_terrain_local_light_uniforms()

func update_terrain_local_light_uniforms() -> void:
    var shader_material := terrain_material as ShaderMaterial
    if shader_material == null or get_tree() == null:
        return
    var observer := player.global_position if player != null else Vector3.ZERO
    var candidates := []
    for light_value in get_tree().get_nodes_in_group("local_light_rig_fill"):
        if not is_instance_valid(light_value):
            continue
        var light := light_value as Light3D
        if light == null or not light.visible:
            continue
        var role := String(light.get_meta("light_role", ""))
        if role != "terrain_wash" and role != "bounce_fill":
            continue
        var omni := light as OmniLight3D
        var base_range := float(light.get("base_range"))
        var range := maxf(omni.omni_range if omni != null else base_range, 0.0)
        if range <= 0.01:
            continue
        var cull_range := maxf(base_range, range)
        var distance := observer.distance_to(light.global_position)
        if distance > cull_range + 18.0:
            continue
        candidates.append({ "light": light, "distance": distance, "range": range })
    candidates.sort_custom(func(a, b): return float(a["distance"]) < float(b["distance"]))
    var positions := PackedVector4Array()
    var colors := PackedVector4Array()
    var max_count := mini(12, candidates.size())
    for index in range(max_count):
        var light := candidates[index]["light"] as Light3D
        if light == null:
            continue
        var position := light.global_position
        var range := float(candidates[index]["range"])
        var role := String(light.get_meta("light_role", ""))
        var role_scale := 1.0 if role == "terrain_wash" else 0.72
        positions.append(Vector4(position.x, position.y, position.z, range))
        colors.append(Vector4(light.light_color.r, light.light_color.g, light.light_color.b, maxf(light.light_energy, 0.0) * role_scale))
    while positions.size() < 12:
        positions.append(Vector4.ZERO)
        colors.append(Vector4.ZERO)
    shader_material.set_shader_parameter("terrain_local_light_count", max_count)
    shader_material.set_shader_parameter("terrain_local_light_positions", positions)
    shader_material.set_shader_parameter("terrain_local_light_colors", colors)

func apply_environment_style(day: float, warmth: float, weather_tint: float) -> void:
    if visual_style == null:
        setup_visual_style()
    var tint := clampf(weather_tint, 0.0, visual_style.max_weather_tint)
    if sky_material:
        sky_material.set("sky_top_color", visual_style.sky_top_color(day, warmth, tint))
        sky_material.set("sky_horizon_color", visual_style.sky_horizon_color(day, warmth, tint))
        sky_material.set("ground_horizon_color", visual_style.ground_horizon_color(day, tint))
        sky_material.set("ground_bottom_color", visual_style.ground_bottom)
        sky_material.set("sky_energy_multiplier", visual_style.sky_energy_multiplier)
        sky_material.set("ground_energy_multiplier", visual_style.ground_energy_multiplier)
        sky_material.set("sun_angle_max", visual_style.procedural_sun_angle)
    if world_environment and world_environment.environment:
        var env := world_environment.environment
        env.background_color = visual_style.sky_horizon_color(day, warmth, tint)
        env.ambient_light_color = visual_style.ambient_color(day, tint)
        env.ambient_light_energy = lerpf(visual_style.ambient_min_energy, visual_style.ambient_max_energy, day)
        env.fog_light_color = visual_style.fog_color(day, warmth, tint)
        env.fog_light_energy = lerpf(visual_style.fog_light_energy_night, visual_style.fog_light_energy, day)
        env.fog_density = lerpf(visual_style.fog_density_night, visual_style.fog_density_day, day)
        env.fog_sky_affect = visual_style.fog_sky_affect
        env.fog_sun_scatter = visual_style.fog_sun_scatter

func update_music_state(observer: Vector3, day: float) -> void:
    if audio_effects == null:
        return
    var cell := Vector2i(world_to_cell(observer.x), world_to_cell(observer.z))
    var biome := biome_at_cell(cell.x, cell.y)
    var track := ""
    var music_fade := smoothstep(0.10, 0.46, day)
    if music_fade > 0.01:
        track = "daytime"
    if audio_effects.has_method("update_music"):
        audio_effects.update_music({
            "track": track,
            "volumeDb": lerpf(-42.0, -14.0, music_fade)
        })
    if audio_effects.has_method("update_nature_ambience"):
        var biome_allows_nature := biome != "desert" and biome != "beach" and biome != "ocean"
        var nature_amount := music_fade if biome_allows_nature else 0.0
        audio_effects.update_nature_ambience({
            "amount": nature_amount,
            "volumeDb": -20.0
        })
    if audio_effects.has_method("update_night_ambience"):
        var night_amount := 1.0 - smoothstep(0.12, 0.58, day)
        audio_effects.update_night_ambience({
            "amount": night_amount,
            "volumeDb": -28.0
        })

func apply_weather_lighting(weather: Dictionary, day: float) -> void:
    if visual_style == null:
        setup_visual_style()
    var cloud_cover := float(weather.get("cloudCover", 0.0))
    var weather_intensity := float(weather.get("intensity", 0.0))
    var phase := clock_phase()
    var sun_progress := daylight_progress(phase)
    var warmth: float = float(visual_style.sunset_amount(sun_progress, day))
    var tint_strength: float = float(visual_style.weather_tint_amount(cloud_cover, weather_intensity))
    apply_environment_style(day, warmth, tint_strength)
    var shade := clampf(1.0 - cloud_cover * visual_style.cloud_sun_shade - weather_intensity * visual_style.rain_sun_shade, 0.48, 1.0)
    sun.light_energy *= shade
    moon.light_energy *= clampf(1.0 - cloud_cover * visual_style.cloud_moon_shade - weather_intensity * visual_style.rain_moon_shade, 0.50, 1.0)
    if world_environment and world_environment.environment:
        var env := world_environment.environment
        env.ambient_light_energy = maxf(
            visual_style.ambient_min_energy,
            env.ambient_light_energy * clampf(
                1.0 - weather_intensity * 0.16 - cloud_cover * (1.0 - day) * 0.12,
                visual_style.weather_ambient_floor,
                1.0
            )
        )
        env.fog_density = lerpf(env.fog_density, visual_style.fog_density_weather, tint_strength)
    var water_material := materials.get("water") as ShaderMaterial
    if water_material:
        water_material.set_shader_parameter("cloud_cover", cloud_cover)
        water_material.set_shader_parameter("weather_intensity", weather_intensity)
        water_material.set_shader_parameter("day_factor", day)
        water_material.set_shader_parameter("sunset_warmth", warmth)
        water_material.set_shader_parameter("wave_time", world_elapsed)
    else:
        var fallback_water := materials.get("water") as StandardMaterial3D
        if fallback_water:
            fallback_water.albedo_color = Color(0.30, 0.70, 0.78, 0.46).lerp(Color(0.46, 0.58, 0.56, 0.54), cloud_cover * 0.42 + weather_intensity * 0.22)

func update_survival(delta: float) -> void:
    if survival_system == null or player == null:
        return
    var cell := Vector2i(world_to_cell(player.position.x), world_to_cell(player.position.z))
    var biome := biome_at_cell(cell.x, cell.y)
    var day_factor := clock_day_factor()
    var weather_state: Dictionary = weather_system.snapshot() if weather_system else { "kind": "clear", "intensity": 0.0 }
    var shelter_state := shelter_state_at_player(delta)
    survival_system.update(delta, {
        "moving": bool(player.get("is_moving")),
        "sprinting": bool(player.get("is_sprinting")),
        "jumped": bool(player.get("jumped_this_frame")),
        "biome": biome,
        "dayFactor": day_factor,
        "weather": weather_state,
        "lightSafety": light_safety_at(player.global_position),
        "shelterComfort": float(shelter_state.get("comfort", 0.0)),
        "sanctuaryEstablished": sanctuary_established
    })

func handle_collapse_if_needed() -> bool:
    if survival_system == null or player == null or float(survival_system.health) > 0.0:
        return false
    respawn_player()
    return true

func respawn_player() -> void:
    var death_position := player.global_position
    var dropped_items := drop_inventory_at(death_position)
    death_count += 1
    if utility_system:
        utility_system.close()
    if hud:
        hud.set_inventory_open(false)
        hud.set_teleport_open(false)
    survival_system.reset()
    player.global_position = respawn_position()
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", false)
    update_chunks(true)
    var wake_location := "at your bed" if respawn_point is Vector3 else "near spawn"
    var message := "You collapsed and woke %s" % wake_location
    if dropped_items > 0:
        message = "%s; dropped %d items" % [message, dropped_items]
    play_feedback("damage", death_position, Color(0.74, 0.24, 0.30), 12)
    update_hud(message)

func respawn_position() -> Vector3:
    if respawn_point is Vector3:
        var point: Vector3 = respawn_point
        var ground_y := maxf(height_at_world(point.x, point.z), WATER_LEVEL)
        return Vector3(point.x, maxf(point.y, ground_y + 0.35), point.z)
    return find_spawn_position()

func sleep_at_bed(block: Node) -> bool:
    if block == null or not block.has_meta("block_type") or String(block.get_meta("block_type")) != "bed":
        return false
    if tutorial_system and tutorial_system.has_method("is_bed_locked") and bool(tutorial_system.is_bed_locked()):
        tutorial_system.on_bed_blocked()
        update_hud(tutorial_system.last_message)
        return true
    if sleep_transition_active:
        update_hud("Already resting until sunrise")
        return true
    respawn_point = bed_respawn_point(block)
    var day_factor := clock_day_factor()
    var message := "Respawn set at bed"
    var rest_quality := 0.0
    if block is Node3D:
        var shelter_state := shelter_state_at((block as Node3D).global_position)
        rest_quality = float(shelter_state.get("comfort", 0.0))
    if day_factor <= 0.42:
        message = "Respawn set, slept safely until morning" if rest_quality >= 0.62 else "Respawn set, slept until morning"
        start_sleep_transition(rest_quality, message)
        message = "Resting until sunrise..."
    play_feedback("pickup", (block as Node3D).global_position if block is Node3D else Vector3.INF, feedback_color_for_material("bed"), 6)
    update_hud(message)
    return true

func start_sleep_transition(rest_quality: float, wake_message: String) -> void:
    sleep_transition_active = true
    sleep_transition_elapsed = 0.0
    sleep_transition_applied = false
    sleep_transition_rest_quality = rest_quality
    sleep_transition_message = wake_message
    if hud and hud.has_method("play_sleep_fade"):
        hud.play_sleep_fade(SLEEP_FADE_OUT_SECONDS, SLEEP_HOLD_SECONDS, SLEEP_FADE_IN_SECONDS)

func update_sleep_transition(delta: float) -> void:
    if not sleep_transition_active:
        return
    sleep_transition_elapsed += delta
    if not sleep_transition_applied and sleep_transition_elapsed >= SLEEP_FADE_OUT_SECONDS:
        apply_sleep_transition()
    var total := SLEEP_FADE_OUT_SECONDS + SLEEP_HOLD_SECONDS + SLEEP_FADE_IN_SECONDS
    if sleep_transition_elapsed >= total:
        sleep_transition_active = false
        sleep_transition_elapsed = 0.0

func apply_sleep_transition() -> void:
    if sleep_transition_applied:
        return
    sleep_transition_applied = true
    time_of_day = SUNRISE_TIME
    if survival_system:
        survival_system.rest(sleep_transition_rest_quality)
    if hostile_system:
        hostile_system.clear()
    if tutorial_system and tutorial_system.has_method("on_bed_used"):
        tutorial_system.on_bed_used()
        if tutorial_system.last_message != "":
            sleep_transition_message = tutorial_system.last_message
    update_sky(0.0)
    update_objectives_and_contracts()
    update_hud(sleep_transition_message)

func clock_time_text() -> String:
    var phase := clock_phase()
    return "%02d:%02d" % [floori(phase * 24.0), floori(fposmod(phase * 1440.0, 60.0))]

func clock_phase() -> float:
    return fposmod(time_of_day + CLOCK_DISPLAY_OFFSET, 1.0)

func clock_day_factor() -> float:
    var phase := clock_phase()
    var morning := smoothstep(DAWN_START_CLOCK, DAY_FULL_CLOCK, phase)
    var evening := 1.0 - smoothstep(DUSK_START_CLOCK, NIGHT_FULL_CLOCK, phase)
    return clampf(minf(morning, evening), 0.0, 1.0)

func clock_night_factor() -> float:
    return clampf(1.0 - clock_day_factor(), 0.0, 1.0)

func daylight_progress(phase: float) -> float:
    return clampf((phase - DAWN_START_CLOCK) / (NIGHT_FULL_CLOCK - DAWN_START_CLOCK), 0.0, 1.0)

func wrapped_clock_progress(start: float, end: float, phase: float) -> float:
    var span := fposmod(end - start, 1.0)
    if span <= 0.0:
        return 0.0
    return clampf(fposmod(phase - start, 1.0) / span, 0.0, 1.0)

func clock_in_wrapped_range(phase: float, start: float, end: float) -> bool:
    if start <= end:
        return phase >= start and phase <= end
    return phase >= start or phase <= end

func bed_respawn_point(block: Node) -> Vector3:
    var cell: Vector3i = block.get_meta("cell", Vector3i.ZERO)
    var offsets := [
        Vector2i(1, 0),
        Vector2i(-1, 0),
        Vector2i(0, 1),
        Vector2i(0, -1),
        Vector2i(0, 0)
    ]
    for offset in offsets:
        var target_cell := Vector3i(cell.x + offset.x, cell.y, cell.z + offset.y)
        if offset != Vector2i.ZERO and blocks.has(target_cell):
            continue
        var x := float(target_cell.x) * CELL
        var z := float(target_cell.z) * CELL
        var ground_y := maxf(height_at_world(x, z), WATER_LEVEL)
        var bed_y := (block as Node3D).global_position.y if block is Node3D else ground_y
        return Vector3(x, maxf(ground_y + 0.35, bed_y + CELL * 0.12), z)
    var fallback_x := float(cell.x) * CELL
    var fallback_z := float(cell.z) * CELL
    return Vector3(fallback_x, maxf(height_at_world(fallback_x, fallback_z), WATER_LEVEL) + 0.35, fallback_z)

func shelter_state_at_player(delta: float) -> Dictionary:
    if player == null:
        return { "comfort": 0.0, "label": "Exposed" }
    shelter_sample_elapsed += delta
    if shelter_sample_elapsed >= 0.35:
        shelter_sample_elapsed = 0.0
        var state := shelter_state_at(player.global_position)
        cached_shelter_comfort = float(state.get("comfort", 0.0))
        cached_shelter_label = String(state.get("label", "Exposed"))
    return { "comfort": cached_shelter_comfort, "label": cached_shelter_label }

func shelter_state_at(position: Vector3) -> Dictionary:
    var roof_score := 0.0
    var wall_sectors := {}
    var structural_nearby := 0
    var bed_bonus := 0.0
    var near_light := light_safety_at(position, false, CELL * 7.0)
    for block in blocks.values():
        var body := block as Node3D
        if body == null or not body.has_meta("block_type"):
            continue
        var block_type := String(body.get_meta("block_type", ""))
        var rel := body.global_position - position
        if absf(rel.x) > CELL * 4.2 or absf(rel.z) > CELL * 4.2 or absf(rel.y) > CELL * 5.2:
            continue
        var horizontal := Vector2(rel.x, rel.z).length()
        if block_type == "bed" and horizontal <= CELL * 3.2 and absf(rel.y) < CELL * 1.2:
            bed_bonus = maxf(bed_bonus, 0.08)
        var shelter_block := is_structural_block_type(block_type) or block_type in ["door", "glass"]
        if not shelter_block:
            continue
        if rel.y > CELL * 0.95 and rel.y < CELL * 5.4 and absf(rel.x) < CELL * 1.65 and absf(rel.z) < CELL * 1.65:
            roof_score = 1.0
        if rel.y > -CELL * 0.75 and rel.y < CELL * 2.45 and horizontal > CELL * 0.65 and horizontal < CELL * 3.8:
            var sector := floori(posmod(atan2(rel.z, rel.x) + PI, TAU) / (PI * 0.25))
            wall_sectors[sector] = true
            structural_nearby += 1
    var wall_score: float = minf(1.0, float(wall_sectors.size()) / 5.0)
    var density_score: float = minf(1.0, float(structural_nearby) / 10.0)
    var comfort: float = clampf(
        roof_score * 0.36
        + wall_score * 0.34
        + density_score * 0.12
        + near_light * 0.10
        + bed_bonus,
        0.0,
        1.0
    )
    var label := "Sheltered" if comfort >= 0.62 else ("Covered" if comfort >= 0.38 else "Exposed")
    return {
        "comfort": comfort,
        "label": label,
        "roof": roof_score,
        "wallSectors": wall_sectors.size(),
        "nearLight": near_light
    }

func inventory_stacks() -> Array:
    var result := []
    if inventory_system:
        for slot in inventory_system.snapshot():
            if not (slot is Dictionary):
                continue
            var item_id := String(slot.get("item", ""))
            var count := int(slot.get("count", 0))
            if item_id != "" and count > 0:
                result.append({ "item": item_id, "count": count })
    if equipment_system:
        result.append_array(equipment_system.stacks())
    return result

func drop_inventory_at(position: Vector3) -> int:
    var stacks := inventory_stacks()
    if stacks.is_empty():
        return 0
    var terrain_y := maxf(height_at_world(position.x, position.z), WATER_LEVEL) + 0.65
    var drop_position := Vector3(position.x, maxf(position.y + 0.4, terrain_y), position.z)
    var dropped := 0
    for stack in stacks:
        var item_id := String(stack.get("item", ""))
        var count := int(stack.get("count", 0))
        if item_id == "" or count <= 0:
            continue
        spawn_pickup_stack(item_id, count, drop_position)
        dropped += count
    if inventory_system:
        inventory_system.clear()
    if equipment_system:
        equipment_system.reset()
    _sync_inventory_totals()
    return dropped

func spawn_pickup_stack(item_id: String, count: int, position: Vector3) -> Node3D:
    if count <= 0 or not ItemCatalogScript.ITEMS.has(item_id):
        return null
    var root := acquire_pickup_node(item_id)
    root.name = "Pickup_%s_%d" % [item_id, dropped_pickups.size()]
    var offset := Vector3(randf_range(-0.45, 0.45), 0.0, randf_range(-0.45, 0.45))
    root.position = position + offset
    root.rotation = Vector3.ZERO
    root.scale = Vector3.ONE
    root.visible = true
    if prop_root:
        if root.get_parent() != prop_root:
            if root.get_parent():
                root.get_parent().remove_child(root)
            prop_root.add_child(root)
    elif root.get_parent() == null:
        add_child(root)
    dropped_pickups.append({
        "node": root,
        "item": item_id,
        "count": count,
        "spin": randf_range(0.8, 1.6)
    })
    return root

func create_pickup_node(item_id: String) -> Node3D:
    var root := Node3D.new()
    root.set_meta("pool_item", item_id)
    var visual: Node3D = item_visual_factory.make_pickup(item_id) if item_visual_factory else null
    if visual:
        root.add_child(visual)
    else:
        var mesh := BoxMesh.new()
        mesh.size = Vector3.ONE * 0.42
        var mesh_instance := MeshInstance3D.new()
        mesh_instance.mesh = mesh
        mesh_instance.material_override = materials.get(item_id, materials.get("woodBlock"))
        root.add_child(mesh_instance)
    root.visible = false
    return root

func acquire_pickup_node(item_id: String) -> Node3D:
    var pool: Array = []
    if pickup_pool.has(item_id):
        pool = pickup_pool[item_id]
    var root: Node3D = null
    while not pool.is_empty() and root == null:
        var candidate := pool.pop_back() as Node3D
        if candidate != null and is_instance_valid(candidate):
            root = candidate
    pickup_pool[item_id] = pool
    if root == null:
        root = create_pickup_node(item_id)
        pickup_nodes_created += 1
    else:
        pickup_nodes_reused += 1
    return root

func recycle_pickup(pickup: Dictionary) -> void:
    var item_id := String(pickup.get("item", ""))
    var node := pickup.get("node") as Node3D
    if item_id == "" or node == null or not is_instance_valid(node):
        return
    node.visible = false
    node.scale = Vector3.ONE
    node.position = Vector3(0.0, -9999.0, 0.0)
    var pool: Array = []
    if pickup_pool.has(item_id):
        pool = pickup_pool[item_id]
    if pool.size() < 24:
        pool.append(node)
        pickup_pool[item_id] = pool
    else:
        pickup_nodes_discarded += 1
        node.queue_free()
