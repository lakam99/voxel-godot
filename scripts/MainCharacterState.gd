extends "res://scripts/MainGameLoop.gd"

func pickup_pool_stats() -> Dictionary:
    var pooled := 0
    for item_id_variant in pickup_pool.keys():
        var pool: Array = pickup_pool[item_id_variant]
        pooled += pool.size()
    return {
        "active": dropped_pickups.size(),
        "pooled": pooled,
        "created": pickup_nodes_created,
        "reused": pickup_nodes_reused,
        "discarded": pickup_nodes_discarded,
        "itemPools": pickup_pool.size()
    }

func update_dropped_pickups(delta: float) -> void:
    if player == null or inventory_system == null:
        return
    for pickup in dropped_pickups.duplicate():
        var node := pickup.get("node") as Node3D
        if node == null or not is_instance_valid(node):
            dropped_pickups.erase(pickup)
            continue
        node.rotate_y(float(pickup.get("spin", 1.0)) * delta)
        node.position.y += sin(world_elapsed * 4.0 + node.position.x) * delta * 0.045
        if node.global_position.distance_to(player.global_position) > CELL * 1.35:
            continue
        var item_id := String(pickup.get("item", ""))
        var count := int(pickup.get("count", 0))
        var collected: int = int(inventory_system.add_item(item_id, count))
        if collected <= 0:
            continue
        count -= collected
        play_feedback("pickup", node.global_position, feedback_color_for_material(item_id), min(10, max(2, collected)))
        maybe_emit_story_countermeasure_prepared(item_id, "pickup")
        if count <= 0:
            dropped_pickups.erase(pickup)
            recycle_pickup(pickup)
        else:
            pickup["count"] = count
    _sync_inventory_totals()

func clear_dropped_pickups() -> void:
    for pickup in dropped_pickups:
        recycle_pickup(pickup)
    dropped_pickups.clear()

func register_wildlife(body: StaticBody3D, rng: RandomNumberGenerator, cold := false) -> void:
    if body == null:
        return
    body.set_meta("wildlife_home", body.global_position)
    body.set_meta("wildlife_direction", random_horizontal_direction(rng))
    body.set_meta("wildlife_timer", rng.randf_range(0.8, 2.6))
    body.set_meta("wildlife_speed", rng.randf_range(0.42, 0.74) * (0.86 if cold else 1.0) * float(body.get_meta("wildlife_speed_multiplier", 1.0)))
    body.set_meta("wildlife_last_move", 0.0)
    if not wildlife_nodes.has(body):
        wildlife_nodes.append(body)

func random_horizontal_direction(rng: RandomNumberGenerator = null) -> Vector3:
    var angle := randf() * TAU
    if rng != null:
        angle = rng.randf() * TAU
    return Vector3(cos(angle), 0.0, sin(angle)).normalized()

func update_wildlife(delta: float) -> void:
    if player == null or wildlife_nodes.is_empty():
        return
    for wildlife_value in wildlife_nodes.duplicate():
        if not is_instance_valid(wildlife_value):
            wildlife_nodes.erase(wildlife_value)
            continue
        var body := wildlife_value as StaticBody3D
        if body == null or not is_instance_valid(body) or not body.is_inside_tree():
            wildlife_nodes.erase(wildlife_value)
            continue
        if not body.has_meta("material") or String(body.get_meta("material", "")) != "wildlife":
            wildlife_nodes.erase(wildlife_value)
            continue
        if body.global_position.distance_to(player.global_position) > CELL * 92.0:
            body.set_meta("wildlife_last_move", 0.0)
            continue
        update_single_wildlife(body, delta)

func update_single_wildlife(body: StaticBody3D, delta: float) -> void:
    var direction: Vector3 = body.get_meta("wildlife_direction", Vector3.ZERO)
    if direction.length_squared() < 0.001:
        direction = random_horizontal_direction()
    var timer: float = float(body.get_meta("wildlife_timer", 0.0)) - delta
    var home: Vector3 = body.get_meta("wildlife_home", body.global_position)
    var from_home := body.global_position - home
    from_home.y = 0.0
    var to_player := body.global_position - player.global_position
    to_player.y = 0.0
    var player_distance := to_player.length()
    var speed: float = float(body.get_meta("wildlife_speed", 0.58))
    if player_distance < CELL * 5.0 and to_player.length_squared() > 0.001:
        direction = to_player.normalized()
        speed *= 2.35
        timer = maxf(timer, 0.35)
    else:
        var roam_radius := CELL * 6.0
        if timer <= 0.0 or from_home.length() > roam_radius:
            if from_home.length() > roam_radius:
                direction = -from_home.normalized()
            else:
                direction = random_horizontal_direction()
            timer = randf_range(1.0, 3.0)
    var moved := move_wildlife(body, direction * speed * delta)
    if moved <= 0.001:
        for attempt in range(4):
            direction = random_horizontal_direction()
            moved = move_wildlife(body, direction * speed * delta)
            if moved > 0.001:
                break
        timer = randf_range(0.55, 1.45)
    if moved > 0.001:
        body.rotation.y = atan2(-direction.x, -direction.z)
    update_wildlife_animation(body, moved, speed)
    var ground_y := height_at_world(body.global_position.x, body.global_position.z)
    body.global_position.y = ground_y
    body.set_meta("wildlife_direction", direction)
    body.set_meta("wildlife_timer", timer)
    body.set_meta("wildlife_last_move", moved)

func update_wildlife_animation(body: StaticBody3D, moved: float, speed: float) -> void:
    if not bool(body.get_meta("wildlife_animated", false)):
        return
    var path := String(body.get_meta("wildlife_animation_player_path", ""))
    if path == "":
        return
    var anim_player := body.get_node_or_null(NodePath(path)) as AnimationPlayer
    if anim_player == null:
        return
    var animation_name := String(body.get_meta("wildlife_animation_name", ""))
    if animation_name != "" and not anim_player.is_playing():
        anim_player.play(animation_name)
    anim_player.speed_scale = 0.35 if moved <= 0.001 else clampf(speed * 1.25, 0.75, 1.85)

func move_wildlife(body: StaticBody3D, displacement: Vector3) -> float:
    displacement.y = 0.0
    if body == null or displacement.length_squared() < 0.000001:
        return 0.0
    var previous := body.global_position
    var previous_ground := height_at_world(previous.x, previous.z)
    var candidate := previous + displacement
    var next_ground := height_at_world(candidate.x, candidate.z)
    if next_ground < WATER_LEVEL + 0.45:
        return 0.0
    if absf(next_ground - previous_ground) > CELL * 0.72:
        return 0.0
    if wildlife_blocked_at(candidate):
        return 0.0
    body.global_position.x = candidate.x
    body.global_position.z = candidate.z
    return Vector2(candidate.x - previous.x, candidate.z - previous.z).length()

func wildlife_blocked_at(position: Vector3) -> bool:
    var cell := Vector3i(roundi(position.x / CELL), roundi(position.y / CELL), roundi(position.z / CELL))
    for dx in range(-1, 2):
        for dz in range(-1, 2):
            for dy in range(-1, 2):
                var key := cell + Vector3i(dx, dy, dz)
                if not blocks.has(key):
                    continue
                var block := blocks[key] as Node3D
                if block == null or not is_instance_valid(block):
                    continue
                var block_type := String(block.get_meta("block_type", ""))
                if block_type == "cobblestonePath" or block_type == "torch":
                    continue
                if Vector2(block.global_position.x - position.x, block.global_position.z - position.z).length() < CELL * 0.78:
                    return true
    return false

func update_hostiles(delta: float) -> void:
    if hostile_system == null or player == null:
        return
    var cell := Vector2i(world_to_cell(player.position.x), world_to_cell(player.position.z))
    var day_factor := clock_day_factor()
    hostile_system.update_hostiles(delta, day_factor, biome_at_cell(cell.x, cell.y), sanctuary_established)

func update_npcs(delta: float) -> void:
    if npc_system == null:
        return
    var day_factor := clock_day_factor()
    npc_system.update_npcs(delta, day_factor)

func update_beacon_charge(delta: float) -> void:
    var beacon := first_sanctuary_beacon()
    if sanctuary_established:
        beacon_charge = BEACON_CHARGE_REQUIRED
        beacon_raid_stage = BEACON_RAID_THRESHOLDS.size()
        beacon_status_message = "Sanctuary established"
        return
    if beacon == null:
        if beacon_charge > 0.0 or beacon_raid_stage > 0:
            beacon_charge = 0.0
            beacon_raid_stage = 0
        beacon_status_message = ""
        return
    var night_factor := smoothstep(0.32, 0.86, clock_night_factor())
    var threats := beacon_threat_count(beacon)
    if threats > 0:
        beacon_charge = maxf(0.0, beacon_charge - delta * (2.2 + float(threats) * 1.15))
        beacon_status_message = "Beacon contested: %d hostile%s" % [threats, "" if threats == 1 else "s"]
    else:
        beacon_charge = minf(BEACON_CHARGE_REQUIRED, beacon_charge + delta * (0.55 + night_factor * 1.75))
    var spawned := trigger_beacon_raids(beacon, delta)
    if beacon_charge >= BEACON_CHARGE_REQUIRED:
        establish_sanctuary()
        return
    var pct := floori((beacon_charge / BEACON_CHARGE_REQUIRED) * 100.0)
    if spawned > 0:
        beacon_status_message = "Rift assault" if beacon_raid_stage >= BEACON_RAID_THRESHOLDS.size() else "Rift surge %d" % beacon_raid_stage
    elif threats <= 0:
        beacon_status_message = "Beacon charging %d%%" % pct

func first_sanctuary_beacon() -> StaticBody3D:
    for block in blocks.values():
        var body := block as StaticBody3D
        if body != null and String(body.get_meta("block_type", "")) == "sanctuaryBeacon":
            return body
    return null

func beacon_threat_count(beacon: Node3D) -> int:
    if beacon == null or hostile_system == null:
        return 0
    var total := 0
    for enemy in hostile_system.enemies:
        var body := enemy.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            continue
        var variant := String(enemy.get("variant", "shadow"))
        var radius := CELL * (30.0 if variant == "rift" else 18.0)
        if body.global_position.distance_to(beacon.global_position) <= radius:
            total += 1
    return total

func trigger_beacon_raids(beacon: StaticBody3D, delta: float) -> int:
    if hostile_system == null or beacon == null or delta <= 0.0:
        return 0
    var spawned := 0
    while beacon_raid_stage < BEACON_RAID_THRESHOLDS.size() and beacon_charge >= float(BEACON_RAID_THRESHOLDS[beacon_raid_stage]):
        beacon_raid_stage += 1
        spawned += hostile_system.spawn_beacon_raid(beacon, beacon_raid_stage)
    return spawned

func raid_stage_for_charge(charge: float) -> int:
    var stage := 0
    for threshold in BEACON_RAID_THRESHOLDS:
        if charge >= float(threshold):
            stage += 1
    return stage

func establish_sanctuary() -> void:
    if sanctuary_established:
        return
    sanctuary_established = true
    beacon_charge = BEACON_CHARGE_REQUIRED
    beacon_raid_stage = BEACON_RAID_THRESHOLDS.size()
    if hostile_system:
        hostile_system.clear()
    beacon_status_message = "Sanctuary established"
    award_progression("sanctuary established", 100)
    var beacon := first_sanctuary_beacon()
    play_feedback("level", beacon.global_position if beacon != null else Vector3.INF, Color(0.54, 0.74, 0.92), 24)
    if hud:
        hud.show_victory(victory_stats())

func victory_stats() -> Array:
    var objective_snapshot: Dictionary = objective_system.snapshot() if objective_system else { "completed": [], "total": 0 }
    var progression_state: Dictionary = progression_system.state() if progression_system else {}
    var contract_state: Dictionary = contract_system.state() if contract_system else {}
    var state: Dictionary = objective_state()
    var hostile_state: Dictionary = state.get("hostiles", {})
    var defeated_variants: Dictionary = hostile_state.get("defeatedVariants", {})
    var totals: Dictionary = state.get("totals", {})
    var world_edits: int = height_edits.size() + removed_props.size() + blocks.size()
    var time_text := clock_time_text()
    return [
        { "label": "Seed", "value": seed_text },
        { "label": "Objectives", "value": "%d/%d" % [int(objective_snapshot.get("completed", []).size()), int(objective_snapshot.get("total", 0))] },
        { "label": "Contracts", "value": "%d/%d" % [int(contract_state.get("completed", 0)), int(contract_state.get("total", 0))] },
        { "label": "Level", "value": int(progression_state.get("level", 1)) },
        { "label": "Total XP", "value": int(progression_state.get("totalXp", 0)) },
        { "label": "Pack Slots", "value": "%d/%d" % [inventory_system.size if inventory_system else 0, inventory_system.max_size if inventory_system else 0] },
        { "label": "Biomes Discovered", "value": int(state.get("discoveredBiomes", 0)) },
        { "label": "Towns Found", "value": int(state.get("discoveredTowns", 0)) },
        { "label": "Shrines Opened", "value": int(state.get("discoveredShrines", 0)) },
        { "label": "Rift Surges", "value": "%d/%d" % [beacon_raid_stage, BEACON_RAID_THRESHOLDS.size()] },
        { "label": "Hostiles Defeated", "value": int(hostile_state.get("defeated", 0)) },
        { "label": "Rift Colossi Defeated", "value": int(defeated_variants.get("rift", 0)) },
        { "label": "Rift Cores", "value": int(totals.get("riftCore", 0)) },
        { "label": "Collapses", "value": death_count },
        { "label": "Placed Blocks", "value": blocks.size() },
        { "label": "World Edits", "value": world_edits },
        { "label": "Final Time", "value": time_text }
    ]

func update_break_reset(delta: float) -> void:
    if break_target_id == "":
        return
    break_idle_time += delta
    if break_idle_time >= BREAK_RESET_SECONDS:
        reset_break_progress()

func reset_break_progress() -> void:
    break_target_id = ""
    break_progress = 0.0
    break_idle_time = 0.0
    if break_overlay:
        break_overlay.visible = false

func orient_directional_light(light: DirectionalLight3D, sky_direction: Vector3) -> void:
    var up := Vector3.UP
    if abs(sky_direction.dot(up)) > 0.94:
        up = Vector3.FORWARD
    light.look_at(light.global_position - sky_direction, up)

func _input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and should_accept_mouse_look():
        player.handle_mouse_motion(event.relative)

func should_accept_mouse_look() -> bool:
    var captured := Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
    if OS.get_environment("VOXEL_PLAYTEST") != "":
        captured = true
    return (
        player != null
        and captured
        and not (hud and (
            hud.is_inventory_open()
            or hud.is_utility_open()
            or hud.is_teleport_open()
            or hud.is_objectives_open()
            or hud.is_contracts_open()
            or hud.is_settings_open()
            or hud.is_playtest_open()
            or hud.is_game_menu_open()
            or hud.is_dialogue_open()
        ))
    )
