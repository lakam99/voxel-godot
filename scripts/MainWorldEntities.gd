extends "res://scripts/MainCharacterState.gd"

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and not event.echo:
        if event.keycode == KEY_I:
            if utility_system and utility_system.is_open():
                utility_system.close()
            if hud and hud.is_teleport_open():
                hud.set_teleport_open(false)
            if hud and hud.is_contracts_open() and contract_system:
                contract_system.toggle_menu(false)
            var open: bool = hud.toggle_inventory()
            Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED)
            update_hud("Inventory opened" if open else "Inventory closed")
            return
        if event.keycode == KEY_ESCAPE:
            if hud and hud.is_dialogue_open():
                hud.hide_dialogue(true)
                capture_mouse_if_no_modal()
                update_hud("")
            elif hud and hud.is_game_menu_open():
                hud.set_game_menu_open(false)
                Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Game menu closed")
            elif hud and hud.is_teleport_open():
                hud.set_teleport_open(false)
                Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Teleport closed")
            elif hud and hud.is_settings_open():
                hud.set_settings_open(false)
                Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Settings closed")
            elif hud and hud.is_playtest_open():
                hud.set_playtest_open(false)
                Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Playtest closed")
            elif hud and hud.is_contracts_open() and contract_system:
                contract_system.toggle_menu(false)
                update_hud("Contracts closed")
            elif utility_system and utility_system.is_open():
                utility_system.close()
                Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Utility closed")
            elif hud and hud.is_inventory_open():
                hud.set_inventory_open(false)
                Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Inventory closed")
            else:
                var menu_open: bool = hud.toggle_game_menu() if hud else false
                Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if menu_open else Input.MOUSE_MODE_CAPTURED)
                update_hud("Game menu opened" if menu_open else "Game menu closed")
            return
        if event.keycode >= KEY_1 and event.keycode <= KEY_8:
            inventory_system.select(int(event.keycode - KEY_1))
            var active: Dictionary = inventory_system.active_stack()
            var item_id := String(active.get("item", ""))
            update_hud("Selected %s" % (ItemCatalogScript.label(item_id) if item_id != "" else "empty"))
            return
        if event.keycode == KEY_O:
            var objectives_open: bool = hud.toggle_objectives()
            update_hud("Objectives opened" if objectives_open else "Objectives closed")
            return
        if event.keycode == KEY_J:
            var contracts_open: bool = hud.toggle_contracts()
            update_hud("Contracts opened" if contracts_open else "Contracts closed")
            return
        if event.keycode == KEY_M:
            if has_map():
                var collapsed: bool = hud.toggle_map()
                update_hud("Map hidden" if collapsed else "Map shown")
            else:
                update_hud("Craft a compass to unlock the map")
            return
        if event.keycode == KEY_F2:
            var settings_open: bool = hud.toggle_settings() if hud else false
            Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if settings_open else Input.MOUSE_MODE_CAPTURED)
            update_hud("Settings opened" if settings_open else "Settings closed")
            return
        if event.keycode == KEY_F3:
            performance_visible = hud.toggle_performance() if hud else false
            if performance_visible:
                update_performance_overlay(999.0)
            update_hud("Performance HUD shown" if performance_visible else "Performance HUD hidden")
            return
        if event.keycode == KEY_F4:
            var playtest_open: bool = hud.toggle_playtest() if hud else false
            Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if playtest_open else Input.MOUSE_MODE_CAPTURED)
            update_hud("Playtest cases opened" if playtest_open else "Playtest cases closed")
            return
        if event.keycode == KEY_F5:
            save_world(true)
            return
        if event.keycode == KEY_F9:
            try_load_world(true)
            return
        if event.keycode == KEY_T:
            if utility_system and utility_system.is_open():
                utility_system.close()
            if hud and hud.is_inventory_open():
                hud.set_inventory_open(false)
            var open_teleport: bool = hud.toggle_teleport()
            Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if open_teleport else Input.MOUSE_MODE_CAPTURED)
            update_hud("Teleport opened" if open_teleport else "Teleport closed")
            return

    if hud and (
        hud.is_inventory_open()
        or hud.is_utility_open()
        or hud.is_teleport_open()
        or hud.is_contracts_open()
        or hud.is_settings_open()
        or hud.is_playtest_open()
        or hud.is_game_menu_open()
    ):
        return

    if event is InputEventMouseButton and event.pressed:
        if event.button_index == MOUSE_BUTTON_WHEEL_UP:
            select_hotbar_delta(-1)
            return
        if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            select_hotbar_delta(1)
            return
        if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
            Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
            return
        if event.button_index == MOUSE_BUTTON_LEFT:
            destroy_target()
        elif event.button_index == MOUSE_BUTTON_RIGHT:
            use_or_place()

func select_hotbar_delta(delta: int) -> int:
    if inventory_system == null:
        return -1
    var next_slot := posmod(inventory_system.selected_slot + delta, inventory_system.hotbar_size)
    inventory_system.select(next_slot)
    var active: Dictionary = inventory_system.active_stack()
    var item_id := String(active.get("item", ""))
    update_hud("Selected %s" % (ItemCatalogScript.label(item_id) if item_id != "" else "empty"))
    return next_slot

func update_hud_frame(delta: float) -> void:
    if not player or not hud:
        return
    hud_refresh_elapsed += delta
    if hud_refresh_interval > 0.0 and hud_refresh_elapsed < hud_refresh_interval:
        hud_skipped_refresh_count += 1
        return
    hud_refresh_elapsed = 0.0
    update_hud("", true)

func update_hud(message: String = "", throttled: bool = false) -> void:
    if not player or not hud:
        return
    hud_refresh_count += 1
    if throttled:
        hud_throttled_refresh_count += 1
    else:
        hud_manual_refresh_count += 1
    if message != "":
        hud_message_refresh_count += 1
        last_hud_refresh_message = message
        if not throttled:
            hud_refresh_elapsed = 0.0
    var cell := Vector2i(world_to_cell(player.position.x), world_to_cell(player.position.z))
    var biome := biome_at_cell(cell.x, cell.y)
    update_exploration_state(cell, biome)
    update_objectives_and_contracts()
    var time_text := clock_time_text()
    hud.set_status(
        seed_text,
        biome.capitalize(),
        chunks.size(),
        Vector2(player.position.x, player.position.z),
        time_text
    )
    if survival_system:
        hud.set_survival(survival_system.snapshot())
    if progression_system:
        hud.set_progression(progression_system.state())
    if equipment_system:
        hud.set_equipment(equipment_system.state())
    if contract_system:
        hud.set_contracts(contract_system.state())
    hud.set_navigation(
        has_compass(),
        has_map(),
        navigation_heading_text(),
        navigation_map_state()
    )
    if message != "":
        hud.set_target_message(message)
    elif beacon_status_message != "":
        hud.set_target_message(beacon_status_message)

func hud_refresh_stats() -> Dictionary:
    return {
        "refreshes": hud_refresh_count,
        "throttled": hud_throttled_refresh_count,
        "manual": hud_manual_refresh_count,
        "messages": hud_message_refresh_count,
        "skipped": hud_skipped_refresh_count,
        "interval": hud_refresh_interval,
        "elapsed": hud_refresh_elapsed,
        "lastMessage": last_hud_refresh_message
    }

func update_exploration_state(cell: Vector2i, biome: String) -> void:
    if biome != "" and not discovered_biomes.has(biome):
        discovered_biomes[biome] = true
        award_discovery_xp({ "type": "biome", "message": "Biome discovered: %s" % biome.capitalize() })
    var town := town_region_at_cell(cell.x, cell.y)
    if not town.is_empty():
        var key := "%d,%d" % [int(town.get("centerX", 0)), int(town.get("centerZ", 0))]
        if not discovered_town_keys.has(key):
            discovered_town_keys[key] = true
            award_discovery_xp({ "type": "town", "message": "Town discovered" })
    if player:
        discover_landmarks_near(player.global_position)

func discover_landmarks_near(position: Vector3, radius: float = CELL * 8.0) -> int:
    var discovered_count := 0
    var candidates := {}
    for block in blocks.values():
        var body := block as Node3D
        if body == null or not body.has_meta("generatedTier"):
            continue
        var tier := String(body.get_meta("generatedTier", ""))
        if not (tier in ["mine", "ruin", "camp"]):
            continue
        var distance := body.global_position.distance_to(position)
        if distance > radius:
            continue
        var key := String(body.get_meta("cacheKey", ""))
        if key == "":
            var cell_value: Vector3i = body.get_meta("cell", Vector3i.ZERO)
            key = "%s:%d,%d,%d" % [tier, cell_value.x, cell_value.y, cell_value.z]
        var current: Dictionary = candidates.get(key, {})
        if not current.is_empty() and float(current.get("distance", INF)) <= distance:
            continue
        candidates[key] = {
            "tier": tier,
            "key": key,
            "position": body.global_position,
            "distance": distance
        }
    for key_variant in candidates.keys():
        var candidate: Dictionary = candidates[key_variant]
        if discover_landmark(String(candidate.get("tier", "")), String(candidate.get("key", "")), candidate.get("position", position)):
            discovered_count += 1
    return discovered_count

func discover_landmark(tier: String, key: String, position: Vector3) -> bool:
    if key == "":
        return false
    if tier == "mine":
        if discovered_mine_keys.has(key):
            return false
        discovered_mine_keys[key] = true
    elif tier == "ruin":
        if discovered_ruin_keys.has(key):
            return false
        discovered_ruin_keys[key] = true
    elif tier == "camp":
        if discovered_camp_keys.has(key):
            return false
        discovered_camp_keys[key] = true
    else:
        return false
    var label := landmark_label_for_tier(tier)
    award_discovery_xp({
        "type": tier,
        "message": "%s discovered" % label
    })
    var spawned := trigger_landmark_ambush(position, tier, label)
    if spawned > 0:
        beacon_status_message = "%s disturbed" % label
    return true

func landmark_label_for_tier(tier: String) -> String:
    if tier == "mine":
        return "Mine"
    if tier == "ruin":
        return "Ruin"
    if tier == "camp":
        return "Camp"
    return tier.capitalize()

func discover_shrine_cache(block: Node) -> bool:
    if block == null or not block.has_meta("generatedTier") or String(block.get_meta("generatedTier", "")) != "shrine":
        return false
    var key := String(block.get_meta("cacheKey", ""))
    if key == "" or discovered_shrine_keys.has(key):
        return false
    discovered_shrine_keys[key] = true
    award_discovery_xp({ "type": "shrine", "message": "Rift shrine discovered" })
    var spawned := 0
    if hostile_system and block is Node3D and not sanctuary_established:
        spawned = int(hostile_system.spawn_shrine_guardians((block as Node3D).global_position, 3))
    var message := "Rift shrine opened: %d guardians awakened" % spawned if spawned > 0 else "Rift shrine opened"
    if hud:
        hud.set_target_message(message)
    update_objectives_and_contracts()
    return true

func award_discovery_xp(event: Dictionary) -> void:
    var xp_by_type := {
        "biome": 8,
        "town": 20,
        "shrine": 35,
        "mine": 24,
        "ruin": 18,
        "camp": 22
    }
    award_progression(String(event.get("message", "Discovery")), int(xp_by_type.get(String(event.get("type", "")), 6)))

func trigger_landmark_ambush(position: Vector3, tier: String, label: String) -> int:
    if sanctuary_established or hostile_system == null:
        return 0
    return int(hostile_system.spawn_landmark_ambush(position, tier))

func update_objectives_and_contracts() -> void:
    var state := objective_state()
    if tutorial_system and tutorial_system.update_progress(state):
        state = objective_state()
    if objective_system:
        objective_system.update(state)
    if contract_system:
        contract_system.update(state)

func objective_state() -> Dictionary:
    var totals: Dictionary = inventory_system.totals() if inventory_system else {}
    var counts: Dictionary = structure_counts()
    var tier_counts: Dictionary = generated_tier_counts()
    var equipment_state: Dictionary = equipment_system.snapshot() if equipment_system else {}
    var hostile_state: Dictionary = hostile_system.stats() if hostile_system else {}
    var npc_state: Dictionary = npc_system.stats() if npc_system else {}
    var tutorial_state: Dictionary = tutorial_system.state() if tutorial_system else {}
    return {
        "totals": totals,
        "structureCounts": counts,
        "generatedTierCounts": tier_counts,
        "equipment": equipment_state,
        "hostiles": hostile_state,
        "npcs": npc_state,
        "tutorialStarted": bool(tutorial_state.get("started", false)),
        "tutorialNpcTalks": tutorial_state.get("interacted", {}),
        "tutorialSteps": tutorial_state.get("completedSteps", {}),
        "tutorialReadyForWilds": bool(tutorial_state.get("readyForWilds", false)),
        "introDoorOpened": bool(tutorial_state.get("introDoorOpened", false)),
        "introRepairChestOpened": bool(tutorial_state.get("introRepairChestOpened", false)),
        "introRepairComplete": bool(tutorial_state.get("introRepairComplete", false)),
        "introBedUsed": bool(tutorial_state.get("introBedUsed", false)),
        "introFencePlaced": int(tutorial_state.get("introFencePlaced", 0)),
        "introFenceRequired": int(tutorial_state.get("introFenceRequired", 8)),
        "introLampsPlaced": int(tutorial_state.get("introLampsPlaced", 0)),
        "introLampsRequired": int(tutorial_state.get("introLampsRequired", 4)),
        "postIntroMiraBriefed": bool(tutorial_state.get("postIntroMiraBriefed", false)),
        "tutorialStage": String(tutorial_state.get("tutorialStage", "")),
        "finalNightActive": bool(tutorial_state.get("finalNightActive", false)),
        "finalNightComplete": bool(tutorial_state.get("finalNightComplete", false)),
        "finalNightDefeats": int(tutorial_state.get("finalNightDefeats", 0)),
        "finalNightRequired": int(tutorial_state.get("finalNightRequired", 6)),
        "rescueEscortStarted": bool(tutorial_state.get("rescueEscortStarted", false)),
        "rescueReturning": bool(tutorial_state.get("rescueReturning", false)),
        "rescueRemaining": int(tutorial_state.get("rescueRemaining", 0)),
        "rescueRequired": int(tutorial_state.get("rescueRequired", 6)),
        "inventorySize": inventory_system.size if inventory_system else 0,
        "level": progression_system.level if progression_system else 1,
        "discoveredBiomes": discovered_biomes.size(),
        "discoveredTowns": discovered_town_keys.size(),
        "discoveredShrines": discovered_shrine_keys.size(),
        "discoveredMines": discovered_mine_keys.size(),
        "discoveredRuins": discovered_ruin_keys.size(),
        "discoveredCamps": discovered_camp_keys.size(),
        "placedBlocks": placed_block_count(),
        "hasTool": has_any_tool(totals),
        "shelterComfort": cached_shelter_comfort,
        "shelterLabel": cached_shelter_label,
        "sanctuaryEstablished": sanctuary_established,
        "beaconRaidStage": beacon_raid_stage,
        "beaconCharge": beacon_charge
    }

func structure_counts() -> Dictionary:
    var counts := {}
    for block in blocks.values():
        var body := block as Node
        if body == null or not body.has_meta("block_type"):
            continue
        var block_type := String(body.get_meta("block_type"))
        counts[block_type] = int(counts.get(block_type, 0)) + 1
    return counts

func generated_tier_counts() -> Dictionary:
    var counts := {}
    for block in blocks.values():
        var body := block as Node
        if body == null or not body.has_meta("generatedTier"):
            continue
        var tier := String(body.get_meta("generatedTier"))
        if tier == "":
            continue
        counts[tier] = int(counts.get(tier, 0)) + 1
    return counts

func placed_block_count() -> int:
    var total := 0
    for block in blocks.values():
        var body := block as Node
        if body != null and bool(body.get_meta("player_placed", false)):
            total += 1
    return total

func has_any_tool(totals: Dictionary) -> bool:
    for item_id_variant in totals.keys():
        var item_id := String(item_id_variant)
        if (item_id.ends_with("Axe") or item_id.ends_with("Pickaxe") or item_id.ends_with("Shovel") or item_id.ends_with("Sword") or item_id == "hunterBow" or item_id == "ironCrossbow") and int(totals[item_id_variant]) > 0:
            return true
    return false

func has_compass() -> bool:
    if inventory_system == null:
        return false
    return inventory_system.count("compass") > 0 or has_map() or has_navigation_beacon()

func has_map() -> bool:
    if inventory_system == null:
        return false
    if inventory_system.count("surveyLens") > 0:
        return true
    if equipment_system != null and String(equipment_system.equipped_item("accessory")) == "surveyLens":
        return true
    return inventory_system.count("compass") > 0 or has_navigation_beacon()

func has_navigation_beacon() -> bool:
    for block in blocks.values():
        var body := block as Node
        if body != null and String(body.get_meta("block_type", "")) == "sanctuaryBeacon":
            return true
    return false
