extends "res://scripts/MainCore.gd"

const FIRST_STORY_QUEST_ID := "story.gloam_hart.storm"

func reset_runtime_world_state() -> void:
    world_elapsed = 0.0
    autosave_elapsed = 0.0
    time_of_day = 0.32
    next_fishing_ready_at = 0.0
    height_edits.clear()
    if world_generation_system and world_generation_system.has_method("reset"):
        world_generation_system.reset()
    if subsurface_system and subsurface_system.has_method("reset"):
        subsurface_system.reset()
    removed_props.clear()
    clear_chunk_asset_cache()
    clear_dropped_pickups()
    wildlife_nodes.clear()
    if hostile_system:
        hostile_system.clear()
    if npc_system:
        npc_system.clear()
    if utility_system:
        utility_system.close()
    clear_all_blocks()
    if structure_system and structure_system.has_method("reset"):
        structure_system.reset()
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
    if story_debug_tools and story_debug_tools.has_method("setup"):
        story_debug_tools.setup(self, story_director)
    discovered_biomes.clear()
    discovered_town_keys.clear()
    discovered_shrine_keys.clear()
    discovered_mine_keys.clear()
    discovered_ruin_keys.clear()
    discovered_camp_keys.clear()
    last_story_region_id = ""
    death_count = 0
    respawn_point = null
    beacon_charge = 0.0
    beacon_raid_stage = 0
    sanctuary_established = false
    beacon_status_message = ""
    cached_shelter_comfort = 0.0
    cached_shelter_label = "Exposed"
    shelter_sample_elapsed = 0.0
    if inventory_system:
        inventory_system.restore({
            "slots": [],
            "size": ItemCatalogScript.INVENTORY_SIZE,
            "selectedSlot": 0
        })
    if crafting_system and crafting_system.has_method("reset_unlocks"):
        crafting_system.reset_unlocks()
    if equipment_system:
        equipment_system.reset()
    if progression_system:
        progression_system.reset()
    if survival_system:
        survival_system.reset()
        last_survival_health = survival_system.health
    sleep_transition_active = false
    sleep_transition_elapsed = 0.0
    sleep_transition_applied = false
    sleep_transition_rest_quality = 0.0
    sleep_transition_message = ""
    if objective_system:
        objective_system.restore({ "completed": [], "total": objective_system.all_objectives().size() })
    if contract_system:
        contract_system.reset()
    _sync_inventory_totals()
    reset_break_progress()
    if held_item:
        held_item.refresh_active()
    reload_chunks()

func create_save_snapshot() -> Dictionary:
    var player_state := {}
    if player:
        player_state = {
            "position": vector3_to_array(player.global_position),
            "rotationY": player.rotation.y,
            "pitch": float(player.get("pitch"))
        }
    return {
        "seed": seed_text,
        "timeOfDay": time_of_day,
        "weather": weather_system.snapshot() if weather_system else {},
        "tutorial": tutorial_system.snapshot() if tutorial_system else {},
        "player": player_state,
        "inventory": {
            "slots": inventory_system.snapshot() if inventory_system else [],
            "size": inventory_system.size if inventory_system else ItemCatalogScript.INVENTORY_SIZE,
            "selectedSlot": inventory_system.selected_slot if inventory_system else 0
        },
        "crafting": crafting_system.snapshot() if crafting_system and crafting_system.has_method("snapshot") else {},
        "terrain": snapshot_height_edits(),
        "subsurface": snapshot_subsurface(),
        "removedProps": removed_props.keys(),
        "survival": survival_system.snapshot() if survival_system else {},
        "progression": progression_system.snapshot() if progression_system else {},
        "equipment": equipment_system.snapshot() if equipment_system else {},
        "objectives": objective_system.snapshot() if objective_system else {},
        "contracts": contract_system.snapshot() if contract_system else {},
        "caves": structure_system.snapshot_caves() if structure_system and structure_system.has_method("snapshot_caves") else [],
        "story": story_director.snapshot() if story_director else {},
        "npcJobFacts": npc_system.snapshot_job_facts() if npc_system and npc_system.has_method("snapshot_job_facts") else [],
        "exploration": snapshot_exploration(),
        "deathCount": death_count,
        "respawnPoint": vector3_to_array(respawn_point) if respawn_point is Vector3 else [],
        "beaconCharge": beacon_charge,
        "beaconRaidStage": beacon_raid_stage,
        "sanctuaryEstablished": sanctuary_established,
        "blocks": snapshot_player_blocks()
    }

func apply_save_snapshot(snapshot: Dictionary) -> bool:
    if String(snapshot.get("seed", seed_text)) != seed_text:
        return false
    time_of_day = clampf(float(snapshot.get("timeOfDay", time_of_day)), 0.0, 1.0)
    if inventory_system and snapshot.has("inventory"):
        inventory_system.restore(snapshot["inventory"])
    if crafting_system and crafting_system.has_method("restore"):
        crafting_system.restore(snapshot.get("crafting", {}))
    if progression_system and snapshot.has("progression"):
        progression_system.restore(snapshot["progression"])
    if equipment_system and snapshot.has("equipment"):
        equipment_system.restore(snapshot["equipment"])
    if objective_system and snapshot.has("objectives"):
        objective_system.restore(snapshot["objectives"])
    if contract_system and snapshot.has("contracts"):
        contract_system.restore(snapshot["contracts"])
    if story_director:
        story_director.restore(snapshot.get("story", {}))
    restore_exploration(snapshot.get("exploration", {}))
    if survival_system and snapshot.has("survival"):
        survival_system.restore(snapshot["survival"])
    restore_height_edits(snapshot.get("terrain", []))
    restore_subsurface(snapshot.get("subsurface", {}))
    restore_removed_props(snapshot.get("removedProps", []))
    if structure_system and structure_system.has_method("restore_caves"):
        structure_system.restore_caves(snapshot.get("caves", []))
    if npc_system and npc_system.has_method("restore_job_facts"):
        npc_system.restore_job_facts(snapshot.get("npcJobFacts", []))
    restore_player_state(snapshot.get("player", {}))
    if worldmark_encounter_controller and worldmark_encounter_controller.has_method("recover_after_load"):
        worldmark_encounter_controller.recover_after_load()
    if region_aftermath_system and region_aftermath_system.has_method("reconstruct_after_load"):
        region_aftermath_system.reconstruct_after_load()
    restore_player_blocks(snapshot.get("blocks", []))
    if tutorial_system:
        tutorial_system.restore(snapshot.get("tutorial", {}))
        if not snapshot.has("crafting") and bool(tutorial_system.get("started")) and tutorial_system.has_method("sync_crafting_unlocks_from_tutorial"):
            tutorial_system.sync_crafting_unlocks_from_tutorial()
        elif not snapshot.has("crafting") and crafting_system and crafting_system.has_method("unlock_all_groups"):
            crafting_system.unlock_all_groups()
    ensure_story_handoff_for_completed_tutorial_save()
    death_count = max(0, int(snapshot.get("deathCount", snapshot.get("runStats", {}).get("deathCount", 0))))
    respawn_point = optional_vector3(snapshot.get("respawnPoint", []))
    clear_dropped_pickups()
    beacon_charge = clampf(float(snapshot.get("beaconCharge", beacon_charge)), 0.0, BEACON_CHARGE_REQUIRED)
    beacon_raid_stage = clampi(int(snapshot.get("beaconRaidStage", raid_stage_for_charge(beacon_charge))), 0, BEACON_RAID_THRESHOLDS.size())
    sanctuary_established = bool(snapshot.get("sanctuaryEstablished", sanctuary_established))
    if sanctuary_established:
        beacon_charge = BEACON_CHARGE_REQUIRED
        beacon_raid_stage = BEACON_RAID_THRESHOLDS.size()
    if hud:
        if sanctuary_established:
            hud.show_victory(victory_stats())
        else:
            hud.hide_victory()
    _sync_inventory_totals()
    if held_item:
        held_item.refresh_active()
    reset_break_progress()
    reload_chunks()
    refresh_intro_knock_audio()
    return true

func ensure_story_handoff_for_completed_tutorial_save() -> void:
    if story_director == null or tutorial_system == null:
        return
    if not completed_tutorial_needs_story_handoff():
        return
    var snapshot: Dictionary = story_director.snapshot()
    var quests: Dictionary = snapshot.get("quests", {})
    if quests.has(FIRST_STORY_QUEST_ID):
        return
    var cell := Vector2i(280, 0)
    var town_value = tutorial_system.get("town")
    if town_value is Dictionary and not town_value.is_empty():
        cell = Vector2i(int(town_value.get("centerX", cell.x)), int(town_value.get("centerZ", cell.y)))
    var event_position := Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)
    if player:
        event_position = player.global_position
    emit_story_event("tutorial_final_rescue_complete", "tutorial:final_rescue", story_region_id_for_cell(cell), "tutorial:final_rescue_complete", event_position, {
        "rescuedNpcId": "niko",
        "guardNpcId": "sera",
        "tutorialStep": "finalNightComplete",
        "source": "completed_tutorial_save_load"
    })

func completed_tutorial_needs_story_handoff() -> bool:
    if tutorial_system == null:
        return false
    if bool(tutorial_system.get("final_night_complete")):
        return true
    var completed_steps_value = tutorial_system.get("completed_steps")
    if completed_steps_value is Dictionary:
        return bool(completed_steps_value.get("finalNightComplete", false))
    return false

func snapshot_exploration() -> Dictionary:
    return {
        "biomes": discovered_biomes.keys(),
        "towns": discovered_town_keys.keys(),
        "shrines": discovered_shrine_keys.keys(),
        "mines": discovered_mine_keys.keys(),
        "ruins": discovered_ruin_keys.keys(),
        "camps": discovered_camp_keys.keys()
    }

func restore_exploration(snapshot_value) -> void:
    discovered_biomes.clear()
    discovered_town_keys.clear()
    discovered_shrine_keys.clear()
    discovered_mine_keys.clear()
    discovered_ruin_keys.clear()
    discovered_camp_keys.clear()
    var state: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
    for biome_id in state.get("biomes", []):
        var biome := String(biome_id)
        if biome != "":
            discovered_biomes[biome] = true
    for town_key in state.get("towns", []):
        var town_key_string := String(town_key)
        if town_key_string != "":
            discovered_town_keys[town_key_string] = true
    for shrine_key in state.get("shrines", state.get("discoveredShrines", [])):
        var shrine_key_string := String(shrine_key)
        if shrine_key_string != "":
            discovered_shrine_keys[shrine_key_string] = true
    for mine_key in state.get("mines", state.get("discoveredMines", [])):
        var mine_key_string := String(mine_key)
        if mine_key_string != "":
            discovered_mine_keys[mine_key_string] = true
    for ruin_key in state.get("ruins", state.get("discoveredRuins", [])):
        var ruin_key_string := String(ruin_key)
        if ruin_key_string != "":
            discovered_ruin_keys[ruin_key_string] = true
    for camp_key in state.get("camps", state.get("discoveredCamps", [])):
        var camp_key_string := String(camp_key)
        if camp_key_string != "":
            discovered_camp_keys[camp_key_string] = true

func snapshot_height_edits() -> Array:
    var result := []
    for key in height_edits.keys():
        if not (key is Vector2i):
            continue
        result.append({
            "x": key.x,
            "z": key.y,
            "height": float(height_edits[key])
        })
    return result

func restore_height_edits(entries) -> void:
    height_edits.clear()
    clear_chunk_asset_cache()
    if not (entries is Array):
        return
    for entry in entries:
        if not (entry is Dictionary):
            continue
        var key := Vector2i(int(entry.get("x", 0)), int(entry.get("z", 0)))
        var old_height := terrain_height_cell(key.x, key.y)
        var new_height := float(entry.get("height", MIN_HEIGHT))
        height_edits[key] = new_height
        if npc_system and npc_system.has_method("notify_navigation_terrain_edited"):
            npc_system.notify_navigation_terrain_edited(key, old_height, new_height)

func snapshot_subsurface() -> Dictionary:
    if subsurface_system and subsurface_system.has_method("snapshot"):
        return subsurface_system.snapshot()
    return {}

func restore_subsurface(snapshot_value) -> void:
    if subsurface_system and subsurface_system.has_method("restore"):
        subsurface_system.restore(snapshot_value)

func restore_removed_props(entries) -> void:
    removed_props.clear()
    if not (entries is Array):
        return
    for prop_id in entries:
        var prop_key := String(prop_id)
        removed_props[prop_key] = true
        if npc_system and npc_system.has_method("notify_navigation_prop_removed"):
            npc_system.notify_navigation_prop_removed(prop_key, null)

func restore_player_state(state) -> void:
    if player == null or not (state is Dictionary):
        return
    player.global_position = array_to_vector3(state.get("position", []), player.global_position)
    player.rotation.y = float(state.get("rotationY", player.rotation.y))
    player.set("pitch", float(state.get("pitch", player.get("pitch"))))
    if player.get("camera"):
        var camera_node := player.get("camera") as Camera3D
        if camera_node:
            camera_node.rotation.x = float(player.get("pitch"))

func snapshot_player_blocks() -> Array:
    var result := []
    for block in blocks.values():
        var body := block as StaticBody3D
        if body == null or not bool(body.get_meta("player_placed", false)):
            continue
        var cell: Vector3i = body.get_meta("cell")
        var block_type := String(body.get_meta("block_type"))
        var entry := {
            "type": block_type,
            "cell": [cell.x, cell.y, cell.z],
            "worldY": body.position.y,
            "facing": body.rotation.y,
            "open": bool(body.get_meta("open", false)),
            "locked": bool(body.get_meta("locked", false)),
            "jammed": bool(body.get_meta("jammed", false)),
            "destroyed": bool(body.get_meta("destroyed", false)),
            "doorPortalId": String(body.get_meta("door_portal_id", "")),
            "doorGroupId": String(body.get_meta("door_group_id", ""))
        }
        if body.has_meta("storage_slots"):
            entry["storageSlots"] = serialize_slots(body.get_meta("storage_slots"))
        if body.has_meta("furnace_state"):
            entry["furnaceState"] = serialize_furnace_state(body.get_meta("furnace_state"))
        result.append(entry)
    return result

func restore_player_blocks(entries) -> void:
    clear_player_blocks()
    if not (entries is Array):
        return
    for entry in entries:
        if not (entry is Dictionary):
            continue
        var block_type := String(entry.get("type", ""))
        if not ItemCatalogScript.is_placeable(block_type):
            continue
        var cell := array_to_vector3i(entry.get("cell", []), Vector3i.ZERO)
        if blocks.has(cell):
            continue
        var block := create_block(cell, block_type, {
            "player_placed": true,
            "world_y": float(entry.get("worldY", cell.y * CELL)),
            "facing": float(entry.get("facing", 0.0)),
            "locked": bool(entry.get("locked", false)),
            "jammed": bool(entry.get("jammed", false)),
            "destroyed": bool(entry.get("destroyed", false)),
            "doorPortalId": String(entry.get("doorPortalId", "")),
            "doorGroupId": String(entry.get("doorGroupId", ""))
        })
        if block == null:
            continue
        if entry.has("storageSlots"):
            block.set_meta("storage_slots", restore_slots(entry["storageSlots"], UtilityBlockSystemScript.CHEST_SIZE))
        if entry.has("furnaceState"):
            block.set_meta("furnace_state", restore_furnace_state(entry["furnaceState"]))
            if utility_system:
                utility_system.ensure_furnace(block)
        if block_type == "door" and bool(entry.get("open", false)):
            request_door_state(block, true, null, "save", { "authorized": true })

func clear_player_blocks() -> void:
    for key in blocks.keys():
        var body := blocks[key] as Node
        if body != null and bool(body.get_meta("player_placed", false)):
            if npc_system and npc_system.has_method("notify_navigation_block_removed") and body.has_meta("cell"):
                npc_system.notify_navigation_block_removed(body.get_meta("cell"), String(body.get_meta("block_type", "")), body)
            body.queue_free()
            blocks.erase(key)

func clear_all_blocks() -> void:
    for key in blocks.keys():
        var body := blocks[key] as Node
        if body != null:
            if npc_system and npc_system.has_method("notify_navigation_block_removed") and body.has_meta("cell"):
                npc_system.notify_navigation_block_removed(body.get_meta("cell"), String(body.get_meta("block_type", "")), body)
            body.queue_free()
        blocks.erase(key)

func serialize_slots(slots_value) -> Array:
    var result := []
    if not (slots_value is Array):
        return result
    for slot in slots_value:
        if slot is Dictionary:
            result.append({
                "item": String(slot.get("item", "")),
                "count": int(slot.get("count", 0))
            })
    return result

func restore_slots(slots_value, size: int) -> Array:
    var result := []
    var source: Array = slots_value if slots_value is Array else []
    for i in range(size):
        var slot := { "item": "", "count": 0 }
        if i < source.size() and source[i] is Dictionary:
            var item_id := String(source[i].get("item", ""))
            var count_value := int(source[i].get("count", 0))
            if ItemCatalogScript.ITEMS.has(item_id) and count_value > 0:
                slot["item"] = item_id
                slot["count"] = clampi(count_value, 1, ItemCatalogScript.stack_max(item_id))
        result.append(slot)
    return result

func serialize_furnace_state(state_value) -> Dictionary:
    if not (state_value is Dictionary):
        return {}
    return {
        "input": serialize_single_slot(state_value.get("input", {})),
        "fuel": serialize_single_slot(state_value.get("fuel", {})),
        "output": serialize_single_slot(state_value.get("output", {})),
        "processing": bool(state_value.get("processing", false)),
        "progress": float(state_value.get("progress", 0.0)),
        "duration": float(state_value.get("duration", 4.5)),
        "outputItem": String(state_value.get("outputItem", ""))
    }

func restore_furnace_state(state_value) -> Dictionary:
    if not (state_value is Dictionary):
        state_value = {}
    return {
        "input": restore_single_slot(state_value.get("input", {})),
        "fuel": restore_single_slot(state_value.get("fuel", {})),
        "output": restore_single_slot(state_value.get("output", {})),
        "processing": bool(state_value.get("processing", false)),
        "progress": maxf(0.0, float(state_value.get("progress", 0.0))),
        "duration": maxf(0.1, float(state_value.get("duration", 4.5))),
        "outputItem": String(state_value.get("outputItem", ""))
    }

func serialize_single_slot(slot_value) -> Dictionary:
    if not (slot_value is Dictionary):
        return { "item": "", "count": 0 }
    return {
        "item": String(slot_value.get("item", "")),
        "count": int(slot_value.get("count", 0))
    }

func restore_single_slot(slot_value) -> Dictionary:
    if not (slot_value is Dictionary):
        return { "item": "", "count": 0 }
    var item_id := String(slot_value.get("item", ""))
    var count_value := int(slot_value.get("count", 0))
    if not ItemCatalogScript.ITEMS.has(item_id) or count_value <= 0:
        return { "item": "", "count": 0 }
    return { "item": item_id, "count": clampi(count_value, 1, ItemCatalogScript.stack_max(item_id)) }

func reload_chunks() -> void:
    for chunk in chunks.values():
        var node := chunk as Node
        if node:
            node.queue_free()
    chunks.clear()
    last_center_chunk = Vector2i(999999, 999999)
    if player:
        update_chunks(true)

func vector3_to_array(value: Vector3) -> Array:
    return [value.x, value.y, value.z]

func array_to_vector3(value, fallback: Vector3) -> Vector3:
    if not (value is Array) or value.size() < 3:
        return fallback
    return Vector3(float(value[0]), float(value[1]), float(value[2]))

func optional_vector3(value):
    if value is Array and value.size() >= 3:
        return Vector3(float(value[0]), float(value[1]), float(value[2]))
    if value is Dictionary:
        var x := float(value.get("x", NAN))
        var y := float(value.get("y", NAN))
        var z := float(value.get("z", NAN))
        if is_finite(x) and is_finite(y) and is_finite(z):
            return Vector3(x, y, z)
    return null

func array_to_vector3i(value, fallback: Vector3i) -> Vector3i:
    if not (value is Array) or value.size() < 3:
        return fallback
    return Vector3i(int(value[0]), int(value[1]), int(value[2]))

func setup_noise() -> void:
    height_noise = make_noise(17, 0.0058, 4)
    ridge_noise = make_noise(43, 0.014, 3)
    flat_noise = make_noise(71, 0.0024, 3)
    moisture_noise = make_noise(107, 0.006, 3)
    temp_noise = make_noise(131, 0.005, 3)

func make_noise(salt: int, frequency: float, octaves: int) -> FastNoiseLite:
    var noise := FastNoiseLite.new()
    noise.seed = int((seed_hash + salt * 7919) & 0x7fffffff)
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    noise.frequency = frequency
    noise.fractal_octaves = octaves
    noise.fractal_gain = 0.5
    noise.fractal_lacunarity = 2.0
    return noise
