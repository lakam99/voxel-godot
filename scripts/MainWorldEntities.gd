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
            set_game_mouse_mode(Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED)
            update_hud("Inventory opened" if open else "Inventory closed")
            return
        if event.keycode == KEY_ESCAPE:
            if hud and hud.is_dialogue_open():
                hud.hide_dialogue(true)
                capture_mouse_if_no_modal()
                update_hud("")
            elif hud and hud.is_game_menu_open():
                hud.set_game_menu_open(false)
                set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Game menu closed")
            elif hud and hud.is_teleport_open():
                hud.set_teleport_open(false)
                set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Teleport closed")
            elif hud and hud.is_settings_open():
                hud.set_settings_open(false)
                set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Settings closed")
            elif hud and hud.is_playtest_open():
                hud.set_playtest_open(false)
                set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Playtest closed")
            elif hud and hud.is_objectives_open():
                hud.set_objectives_open(false)
                set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Objectives closed")
            elif hud and hud.is_contracts_open() and contract_system:
                hud.set_contracts_open(false)
                set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Contracts closed")
            elif hud and hud.is_story_journal_open():
                hud.set_story_journal_open(false)
                update_hud("Story closed")
            elif utility_system and utility_system.is_open():
                utility_system.close()
                set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Utility closed")
            elif hud and hud.is_inventory_open():
                hud.set_inventory_open(false)
                set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)
                update_hud("Inventory closed")
            else:
                var menu_open: bool = hud.toggle_game_menu() if hud else false
                set_game_mouse_mode(Input.MOUSE_MODE_VISIBLE if menu_open else Input.MOUSE_MODE_CAPTURED)
                update_hud("Game menu opened" if menu_open else "Game menu closed")
            return
        if event.keycode >= KEY_1 and event.keycode <= KEY_8:
            inventory_system.select(int(event.keycode - KEY_1))
            return
        if event.keycode == KEY_R:
            if try_story_release_input():
                return
        if event.keycode == KEY_O:
            var objectives_open: bool = hud.toggle_objectives()
            set_game_mouse_mode(Input.MOUSE_MODE_VISIBLE if objectives_open else Input.MOUSE_MODE_CAPTURED)
            update_hud("Objectives opened" if objectives_open else "Objectives closed")
            return
        if event.keycode == KEY_J:
            var contracts_open: bool = hud.toggle_contracts()
            set_game_mouse_mode(Input.MOUSE_MODE_VISIBLE if contracts_open else Input.MOUSE_MODE_CAPTURED)
            update_hud("Contracts opened" if contracts_open else "Contracts closed")
            return
        if event.keycode == KEY_L:
            var story_open: bool = hud.toggle_story_journal()
            update_hud("Story opened" if story_open else "Story closed")
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
            set_game_mouse_mode(Input.MOUSE_MODE_VISIBLE if settings_open else Input.MOUSE_MODE_CAPTURED)
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
            set_game_mouse_mode(Input.MOUSE_MODE_VISIBLE if playtest_open else Input.MOUSE_MODE_CAPTURED)
            update_hud("Playtest cases opened" if playtest_open else "Playtest cases closed")
            return
        if event.keycode == KEY_F5:
            save_world(true)
            return
        if event.keycode == KEY_F6:
            var story_dump := debug_story_dump()
            print("STORY_DEBUG_DUMP %s" % JSON.stringify(story_dump, "  "))
            update_hud("Story debug dumped to console")
            return
        if event.keycode == KEY_F9:
            await try_load_world_staged(true)
            return
        if event.keycode == KEY_T:
            if utility_system and utility_system.is_open():
                utility_system.close()
            if hud and hud.is_inventory_open():
                hud.set_inventory_open(false)
            var open_teleport: bool = hud.toggle_teleport()
            set_game_mouse_mode(Input.MOUSE_MODE_VISIBLE if open_teleport else Input.MOUSE_MODE_CAPTURED)
            update_hud("Teleport opened" if open_teleport else "Teleport closed")
            return

    if hud and (
        hud.is_inventory_open()
        or hud.is_utility_open()
        or hud.is_teleport_open()
        or hud.is_objectives_open()
        or hud.is_contracts_open()
        or hud.is_story_journal_open()
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
            set_game_mouse_mode(Input.MOUSE_MODE_CAPTURED)
            if not (event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT):
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
    return next_slot

func update_hud_frame(delta: float) -> void:
    if not player or not hud:
        return
    hud_refresh_elapsed += delta
    navigation_map_state_cache_elapsed += delta
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
    if startup_loading_active:
        startup_loading_step.emit("HUD refresh: cell")
    var world_state_start := Time.get_ticks_usec()
    var biome_start := Time.get_ticks_usec()
    var cell := Vector2i(world_to_cell(player.position.x), world_to_cell(player.position.z))
    var biome := surface_biome_at_cell(Vector3i(cell.x, 0, cell.y))
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud_biome_lookup", profiled_ms(biome_start))
    if startup_loading_active:
        startup_loading_step.emit("HUD refresh: exploration")
    var exploration_start := Time.get_ticks_usec()
    update_exploration_state(cell, biome)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud_exploration_state", profiled_ms(exploration_start))
    if startup_loading_active:
        startup_loading_step.emit("HUD refresh: objectives")
    var objectives_start := Time.get_ticks_usec()
    update_objectives_and_contracts()
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud_objectives_contracts", profiled_ms(objectives_start))
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud_world_state", profiled_ms(world_state_start))
    if startup_loading_active:
        startup_loading_step.emit("HUD refresh: status")
    var status_start := Time.get_ticks_usec()
    var time_text := "Day %d %s" % [max(1, int(floor(world_elapsed / DAY_LENGTH)) + 1), clock_time_text()]
    var weather_state: Dictionary = weather_system.snapshot() if weather_system else { "kind": "clear", "intensity": 0.0 }
    hud.set_status(
        seed_text,
        biome.capitalize(),
        chunks.size(),
        Vector2(player.position.x, player.position.z),
        time_text,
        weather_state
    )
    if survival_system:
        hud.set_survival(survival_system.snapshot())
    if progression_system:
        hud.set_progression(progression_system.state())
    if equipment_system:
        hud.set_equipment(equipment_system.state())
    # Contract rows are only visible in the contracts panel. Avoid allocating
    # and rebuilding the complete 24-row list during ordinary HUD refreshes;
    # the panel's open/close paths render the same authoritative state on
    # demand, while an already-open panel remains live.
    if contract_system and hud.is_contracts_open():
        hud.set_contracts(contract_system.state())
    if story_journal_model and hud.has_method("set_story_journal_state"):
        hud.set_story_journal_state(story_journal_model.state())
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud_status_panels", profiled_ms(status_start))
    if startup_loading_active:
        startup_loading_step.emit("HUD refresh: navigation state")
    var nav_state_start := Time.get_ticks_usec()
    var map_state := navigation_map_state()
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud_navigation_state", profiled_ms(nav_state_start))
    if startup_loading_active:
        startup_loading_step.emit("HUD refresh: navigation apply")
    var nav_apply_start := Time.get_ticks_usec()
    hud.set_navigation(
        has_compass(),
        has_map(),
        navigation_heading_text(),
        map_state
    )
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud_navigation_apply", profiled_ms(nav_apply_start))
    var interaction_start := Time.get_ticks_usec()
    if hud.has_method("set_interaction_prompt"):
        hud.set_interaction_prompt(focused_interaction_prompt())
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud_interaction_prompt", profiled_ms(interaction_start))
    if message != "":
        hud.show_notification(message) if hud.has_method("show_notification") else hud.set_target_message(message)
    if startup_loading_active:
        startup_loading_step.emit("HUD refresh: done")

func show_action_message(message: String, passive := false) -> void:
    if message == "" or hud == null:
        return
    if passive:
        hud.show_notification(message, 1.25, -1)
        return
    hud_message_refresh_count += 1
    last_hud_refresh_message = message
    hud_refresh_elapsed = 0.0
    hud.set_target_message(message)

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

func focused_interaction_prompt() -> String:
    if player == null:
        return ""
    var release_prompt := story_release_input_prompt()
    if release_prompt != "":
        return release_prompt
    var hit: Dictionary = focused_interaction_hit()
    if hit.is_empty():
        return ""
    var collider := hit.get("collider") as Node
    if collider == null:
        return ""
    var story_prompt := focused_story_prompt(collider)
    if story_prompt != "":
        return story_prompt
    if collider.has_meta("kind"):
        var kind := String(collider.get_meta("kind"))
        if kind == "npc":
            return "[RMB] Talk to %s" % String(collider.get_meta("npc_name", "Resident"))
    var block := interaction_block_from_collider(collider)
    if block == null:
        return ""
    if String(block.get_meta("kind", "")) != "block" and not (String(block.get_meta("block_type", "")) == "door" and block.has_meta("door_portal_id")):
        return ""
    var block_type := String(block.get_meta("block_type", ""))
    return focused_block_prompt(block, block_type)

func focused_story_prompt(collider: Node) -> String:
    var current := collider
    while current != null:
        if current.has_meta("kind") and String(current.get_meta("kind")) == "story_interactable":
            var prompt := String(current.get_meta("storyPrompt", "Inspect"))
            return "[RMB] %s" % prompt
        current = current.get_parent()
    return ""

func focused_block_prompt(block: Node, block_type: String) -> String:
    if block_type == "door":
        return "[RMB] Close door" if bool(block.get_meta("open", false)) else "[RMB] Open door"
    if block_type == "bed":
        return "[RMB] Sleep"
    if block_type == "chest":
        return "[RMB] Open Chest"
    if block_type == "furnace":
        return "[RMB] Use Furnace"
    if block_type == "campfire":
        return "[RMB] Use Campfire"
    if block_type == "workbench":
        return "[RMB] Craft at Workbench"
    if block_type == "anvil":
        return "[RMB] Use Anvil"
    if block_type == "traderStall":
        return "[RMB] Trade"
    return ""

func update_exploration_state(cell: Vector2i, biome: String) -> void:
    var observer_position := player.global_position if player else Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)
    update_story_region_entry(cell, observer_position, biome)
    if biome != "" and not discovered_biomes.has(biome):
        discovered_biomes[biome] = true
        emit_story_event("biome_discovered", "biome:%s" % biome, story_region_id_for_cell(cell), "discover:biome:%s" % biome, observer_position, {
            "biome": biome,
            "cell": [cell.x, cell.y]
        })
        award_discovery_xp({ "type": "biome", "message": "Biome discovered: %s" % biome.capitalize() })
    var town := town_region_at_cell(cell.x, cell.y)
    if not town.is_empty():
        var key := "%d,%d" % [int(town.get("centerX", 0)), int(town.get("centerZ", 0))]
        if not discovered_town_keys.has(key):
            discovered_town_keys[key] = true
            var town_cell := Vector2i(int(town.get("centerX", cell.x)), int(town.get("centerZ", cell.y)))
            var town_position := player.global_position if player else Vector3(float(town_cell.x) * CELL, float(town.get("level", 0.0)), float(town_cell.y) * CELL)
            emit_story_event("town_discovered", "town:%s" % key, story_region_id_for_cell(town_cell), "discover:town:%s" % key, town_position, {
                "townKey": key,
                "centerCell": [town_cell.x, town_cell.y]
            })
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
    var cell := Vector2i(world_to_cell(position.x), world_to_cell(position.z))
    emit_story_event("%s_discovered" % tier, "%s:%s" % [tier, key], story_region_id_for_cell(cell), "discover:%s:%s" % [tier, key], position, {
        "landmarkType": tier,
        "key": key,
        "cell": [cell.x, cell.y]
    })
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
    var shrine_position := (block as Node3D).global_position if block is Node3D else Vector3.INF
    var shrine_cell := Vector2i(world_to_cell(shrine_position.x), world_to_cell(shrine_position.z)) if is_finite(shrine_position.x) and is_finite(shrine_position.z) else Vector2i.ZERO
    emit_story_event("shrine_discovered", "shrine:%s" % key, story_region_id_for_cell(shrine_cell), "discover:shrine:%s" % key, shrine_position, {
        "landmarkType": "shrine",
        "key": key,
        "cell": [shrine_cell.x, shrine_cell.y]
    })
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
    var objective_state_start := Time.get_ticks_usec()
    var state := objective_state()
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud_objective_state_snapshot", profiled_ms(objective_state_start))
    var tutorial_progress_start := Time.get_ticks_usec()
    if tutorial_system and tutorial_system.update_progress(state):
        state = objective_state()
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud_tutorial_progress", profiled_ms(tutorial_progress_start))
    var objective_update_start := Time.get_ticks_usec()
    if objective_system:
        objective_system.update(state)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud_objective_update", profiled_ms(objective_update_start))
    var contract_update_start := Time.get_ticks_usec()
    if contract_system:
        contract_system.update(state)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.observe_duration("hud_contract_update", profiled_ms(contract_update_start))

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

func block_stats() -> Dictionary:
    if not block_stats_cache_dirty and block_stats_cache_size == blocks.size() and not block_stats_cache.is_empty():
        return block_stats_cache
    var structure_counts_by_type := {}
    var generated_counts_by_tier := {}
    var player_placed_total := 0
    var navigation_beacon_present := false
    for block in blocks.values():
        var body := block as Node
        if body == null or not body.has_meta("block_type"):
            continue
        var block_type := String(body.get_meta("block_type"))
        structure_counts_by_type[block_type] = int(structure_counts_by_type.get(block_type, 0)) + 1
        if bool(body.get_meta("player_placed", false)):
            player_placed_total += 1
        if block_type == "sanctuaryBeacon":
            navigation_beacon_present = true
        var tier := String(body.get_meta("generatedTier", ""))
        if tier != "":
            generated_counts_by_tier[tier] = int(generated_counts_by_tier.get(tier, 0)) + 1
    block_stats_cache = {
        "structureCounts": structure_counts_by_type,
        "generatedTierCounts": generated_counts_by_tier,
        "placedBlocks": player_placed_total,
        "hasNavigationBeacon": navigation_beacon_present
    }
    block_stats_cache_size = blocks.size()
    block_stats_cache_dirty = false
    return block_stats_cache

func structure_counts() -> Dictionary:
    var stats := block_stats()
    var counts: Dictionary = stats.get("structureCounts", {}) if stats.get("structureCounts", {}) is Dictionary else {}
    return counts.duplicate()

func generated_tier_counts() -> Dictionary:
    var stats := block_stats()
    var counts: Dictionary = stats.get("generatedTierCounts", {}) if stats.get("generatedTierCounts", {}) is Dictionary else {}
    return counts.duplicate()

func placed_block_count() -> int:
    return int(block_stats().get("placedBlocks", 0))

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
    if inventory_system.count("map") > 0:
        return true
    if inventory_system.count("surveyLens") > 0:
        return true
    if equipment_system != null and String(equipment_system.equipped_item("accessory")) == "surveyLens":
        return true
    return inventory_system.count("compass") > 0 or has_navigation_beacon()

func has_navigation_beacon() -> bool:
    return bool(block_stats().get("hasNavigationBeacon", false))
