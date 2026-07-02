extends "res://scripts/MainWorldEntities.gd"

func heading_degrees() -> float:
    if player == null:
        return 0.0
    var forward := -player.global_transform.basis.z
    forward.y = 0.0
    if forward.length_squared() < 0.001:
        return 0.0
    forward = forward.normalized()
    return fposmod(rad_to_deg(atan2(forward.x, -forward.z)), 360.0)

func navigation_heading_text() -> String:
    var degrees := heading_degrees()
    return "%s %03d" % [cardinal_for_degrees(degrees), roundi(degrees)]

func navigation_map_state() -> Dictionary:
    var radius := 92.0
    if equipment_system:
        radius += float(equipment_system.map_range_bonus())
    var points := []
    if player == null:
        return { "radius": radius, "heading": 0.0, "points": points, "pointCount": 0, "terrainSamples": [], "sampleCount": 0, "waypointsText": "No tracked structures nearby", "markerSummary": "No mapped markers nearby" }
    var player_cell := Vector2i(world_to_cell(player.global_position.x), world_to_cell(player.global_position.z))
    var map_visible := has_map()
    var heading := deg_to_rad(heading_degrees())
    var cache_cell := Vector2i(int(floor(float(player_cell.x) / 2.0)) * 2, int(floor(float(player_cell.y) / 2.0)) * 2)
    var hostile_count: int = hostile_system.enemies.size() if hostile_system else 0
    var cache_key := "%d,%d:%d:%s:%d:%d" % [cache_cell.x, cache_cell.y, roundi(radius), str(map_visible), blocks.size(), hostile_count]
    if cache_key == navigation_map_state_cache_key and navigation_map_state_cache_elapsed < navigation_map_state_cache_interval and not navigation_map_state_cache.is_empty():
        var cached_state: Dictionary = navigation_map_state_cache.duplicate(true)
        cached_state["heading"] = heading
        return cached_state
    var town := town_region_at_cell(player_cell.x, player_cell.y)
    if not town.is_empty():
        add_map_point(points, "town", "Town", Vector2(float(town.get("centerX", 0)) * CELL - player.global_position.x, float(town.get("centerZ", 0)) * CELL - player.global_position.z), 4.8, radius)
    var seen_landmarks := {}
    for block in blocks.values():
        var body := block as Node3D
        if body == null or not body.has_meta("block_type"):
            continue
        var block_type := String(body.get_meta("block_type"))
        var marker := navigation_marker_for(body, block_type)
        if marker.is_empty():
            continue
        var marker_key := String(marker.get("key", ""))
        if marker_key != "" and seen_landmarks.has(marker_key):
            continue
        if marker_key != "":
            seen_landmarks[marker_key] = true
        add_map_point(points, String(marker.get("kind", "structure")), String(marker.get("label", ItemCatalogScript.label(block_type))), Vector2(body.global_position.x - player.global_position.x, body.global_position.z - player.global_position.z), float(marker.get("size", 3.3)), radius)
        if points.size() >= 28:
            break
    if hostile_system:
        for enemy in hostile_system.enemies:
            var body := enemy.get("body") as Node3D
            if body and is_instance_valid(body):
                add_map_point(points, "hostile", "Hostile", Vector2(body.global_position.x - player.global_position.x, body.global_position.z - player.global_position.z), 3.8, radius)
    var state := {
        "radius": radius,
        "heading": heading,
        "points": points,
        "pointCount": points.size(),
        "terrainSamples": map_terrain_samples(player_cell, radius) if map_visible else [],
        "sampleCount": MAP_SAMPLE_GRID if map_visible else 0,
        "waypointsText": navigation_waypoints_text(points),
        "markerSummary": map_marker_summary(points)
    }
    navigation_map_state_cache_key = cache_key
    navigation_map_state_cache_elapsed = 0.0
    navigation_map_state_cache = state.duplicate(true)
    return state

func add_map_point(points: Array, kind: String, label: String, offset: Vector2, size: float, radius: float) -> void:
    if offset.length() > radius:
        return
    points.append({
        "kind": kind,
        "label": label,
        "offset": offset,
        "size": size,
        "distance": offset.length(),
        "bearing": cardinal_for_offset(offset)
    })

func navigation_marker_for(body: Node, block_type: String) -> Dictionary:
    var tier := String(body.get_meta("generatedTier", ""))
    if tier == "shrine":
        return { "kind": "landmark", "label": "Shrine", "size": 4.0, "key": "shrine:%s" % String(body.get_meta("cacheKey", "")) }
    if tier == "mine":
        return { "kind": "landmark", "label": "Mine", "size": 4.0, "key": "mine:%s" % String(body.get_meta("cacheKey", "")) }
    if tier == "ruin":
        return { "kind": "landmark", "label": "Ruin", "size": 4.0, "key": "ruin:%s" % String(body.get_meta("cacheKey", "")) }
    if tier == "camp":
        return { "kind": "landmark", "label": "Camp", "size": 3.8, "key": "camp:%s" % String(body.get_meta("cacheKey", "")) }
    var specs := {
        "sanctuaryBeacon": { "kind": "beacon", "label": "Beacon", "size": 5.0 },
        "bed": { "kind": "bed", "label": "Bed", "size": 4.0 },
        "wardLantern": { "kind": "ward", "label": "Ward", "size": 4.0 },
        "riftAnchor": { "kind": "anchor", "label": "Anchor", "size": 5.0 },
        "workbench": { "kind": "structure", "label": "Workbench", "size": 3.2 },
        "anvil": { "kind": "structure", "label": "Anvil", "size": 3.2 },
        "campfire": { "kind": "structure", "label": "Campfire", "size": 3.2 },
        "furnace": { "kind": "structure", "label": "Furnace", "size": 3.2 },
        "traderStall": { "kind": "trader", "label": "Trader", "size": 3.4 }
    }
    return specs.get(block_type, {})

func cardinal_for_degrees(degrees: float) -> String:
    var labels := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    var index := posmod(int(floor((degrees + 22.5) / 45.0)), labels.size())
    return labels[index]

func cardinal_for_offset(offset: Vector2) -> String:
    if offset.length_squared() <= 0.001:
        return "Here"
    var degrees := fposmod(rad_to_deg(atan2(offset.x, -offset.y)), 360.0)
    return cardinal_for_degrees(degrees)

func navigation_waypoints_text(points: Array) -> String:
    var waypoints := []
    for point_value in points:
        if not (point_value is Dictionary):
            continue
        var point: Dictionary = point_value
        if String(point.get("kind", "")) == "hostile":
            continue
        waypoints.append(point)
    waypoints.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return float(a.get("distance", 999999.0)) < float(b.get("distance", 999999.0))
    )
    if waypoints.is_empty():
        return "No tracked structures nearby"
    var parts := []
    for i in range(min(3, waypoints.size())):
        var point: Dictionary = waypoints[i]
        parts.append("%s %dm %s" % [
            String(point.get("bearing", "")),
            max(1, roundi(float(point.get("distance", 0.0)))),
            String(point.get("label", "Marker"))
        ])
    return " | ".join(parts)

func map_marker_summary(points: Array) -> String:
    var labels := []
    for point_value in points:
        if not (point_value is Dictionary):
            continue
        var label := String(point_value.get("label", ""))
        if label == "" or labels.has(label):
            continue
        labels.append(label)
        if labels.size() >= 4:
            break
    if labels.is_empty():
        return "No mapped markers nearby"
    var extra: int = max(0, points.size() - labels.size())
    return "%s%s" % [" | ".join(labels), " +%d" % extra if extra > 0 else ""]

func map_terrain_samples(center_cell: Vector2i, radius: float) -> Array:
    var map_visible := has_map()
    if not map_visible:
        return []
    var center_key := Vector2i(int(floor(float(center_cell.x) / 2.0)) * 2, int(floor(float(center_cell.y) / 2.0)) * 2)
    var cache_key := "%d,%d:%d" % [center_key.x, center_key.y, roundi(radius)]
    if cache_key == map_sample_cache_key:
        return map_sample_cache
    var samples := []
    var radius_cells := maxf(8.0, radius / CELL)
    var grid := MAP_SAMPLE_GRID
    for row in range(grid):
        for col in range(grid):
            var nx := (float(col) + 0.5) / float(grid) - 0.5
            var nz := (float(row) + 0.5) / float(grid) - 0.5
            var cell_x := center_key.x + roundi(nx * radius_cells * 2.0)
            var cell_z := center_key.y + roundi(nz * radius_cells * 2.0)
            var offset := Vector2(float(cell_x - center_cell.x) * CELL, float(cell_z - center_cell.y) * CELL)
            if offset.length() > radius:
                continue
            var height := surface_y_at_cell(Vector3i(cell_x, 0, cell_z))
            var biome := surface_biome_at_cell(Vector3i(cell_x, 0, cell_z))
            samples.append({
                "offset": offset,
                "color": map_color_for_sample(biome, height)
            })
    map_sample_cache_key = cache_key
    map_sample_cache = samples
    return samples

func map_color_for_sample(biome: String, height: float) -> Color:
    if height <= WATER_LEVEL + 0.15:
        return Color(0.18, 0.50, 0.60, 0.82)
    var color: Color = BIOME_COLORS.get(biome, BIOME_COLORS["plains"])
    var shade := clampf(0.68 + (height - WATER_LEVEL) / 120.0, 0.58, 1.12)
    return Color(
        clampf(color.r * shade, 0.0, 1.0),
        clampf(color.g * shade, 0.0, 1.0),
        clampf(color.b * shade, 0.0, 1.0),
        0.82
    )

func _on_ui_slot_clicked(index: int) -> void:
    if index < inventory_system.hotbar_size:
        inventory_system.select(index)
        return
    if index >= 0 and index < inventory_system.slots.size():
        var slot: Dictionary = inventory_system.slots[index]
        var item_id := String(slot.get("item", ""))
        if item_id != "":
            update_hud("Drag %s to move it" % ItemCatalogScript.label(item_id))

func _on_ui_slot_moved(from_index: int, to_index: int) -> void:
    if inventory_system == null:
        return
    var source: Dictionary = inventory_system.slots[from_index] if from_index >= 0 and from_index < inventory_system.slots.size() else {}
    var item_id := String(source.get("item", ""))
    if inventory_system.move_slot(from_index, to_index):
        mark_world_dirty("inventory_moved")
        update_hud("Moved %s" % (ItemCatalogScript.label(item_id) if item_id != "" else "item"))

func _on_craft_requested(recipe_id: String) -> void:
    crafting_system.craft(recipe_id)
    update_hud(crafting_system.last_message)

func _on_utility_action_requested(action: String, payload) -> void:
    if utility_system == null:
        return
    utility_system.handle_action(action, payload)
    if hud:
        hud.render_utility(utility_system.active_state())
    update_hud(utility_system.last_message)
    if not utility_system.is_open() and not hud.is_inventory_open():
        Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _on_dialogue_closed(context) -> void:
    if tutorial_system and tutorial_system.has_method("acknowledge_dialogue"):
        tutorial_system.acknowledge_dialogue(context)
        update_objectives_and_contracts()
    capture_mouse_if_no_modal()

func _on_resume_requested() -> void:
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    update_hud("Resumed")

func _on_new_game_requested() -> void:
    start_new_game(true)
    if inventory_system:
        inventory_system.clear()
        _sync_inventory_totals()
    if held_item:
        held_item.refresh_active()

func _on_recipe_crafted(recipe_id: String, output: String, amount: int) -> void:
    mark_world_dirty("recipe_crafted")
    award_craft_xp(recipe_id)
    play_feedback("craft", Vector3.INF, feedback_color_for_material(output), 8)
    match output:
        "workbench":
            objective_system.complete("craft_workbench")
        "woodBlock":
            objective_system.complete("craft_wood_block")
        "woodenPickaxe":
            objective_system.complete("woodenPickaxe")
        "stonePickaxe":
            objective_system.complete("stonePickaxe")
        "copperPickaxe":
            objective_system.complete("craftCopperPickaxe")
            objective_system.complete("copperGear")
        "ironPickaxe":
            objective_system.complete("craftIronPickaxe")
            objective_system.complete("iron")
        "compass":
            objective_system.complete("craft_compass")
    if output.begins_with("copper") and output != "copperIngot":
        objective_system.complete("copperGear")
    if output.begins_with("iron") and output != "ironIngot":
        objective_system.complete("iron")
    maybe_emit_story_countermeasure_prepared(output, "crafting")
    update_objectives_and_contracts()

func _on_objective_completed(objective: Dictionary) -> void:
    mark_world_dirty("objective_completed")
    if hud:
        hud.show_objective_complete(String(objective.get("label", "")))

func _on_utility_changed() -> void:
    mark_world_dirty("utility_changed")
    if hud == null or utility_system == null:
        return
    hud.render_utility(utility_system.active_state())
    if utility_system.last_message != "":
        update_hud(utility_system.last_message)

func _on_utility_processed(block_type: String, output_item: String) -> void:
    mark_world_dirty("utility_processed")
    var amount := 4
    if output_item in ["copperIngot", "ironIngot"]:
        amount = 10
    elif output_item in ["cookedMeat", "cookedFish"]:
        amount = 6
    award_progression("%s made %s" % [ItemCatalogScript.label(block_type), ItemCatalogScript.label(output_item)], amount)
    if output_item == "copperIngot":
        objective_system.complete("smeltCopper")
    elif output_item == "ironIngot":
        objective_system.complete("smeltIron")
        objective_system.complete("iron")
    play_feedback("craft", Vector3.INF, feedback_color_for_material(output_item), 6)
    maybe_emit_story_countermeasure_prepared(output_item, "utility_processed:%s" % block_type)
    update_objectives_and_contracts()

func _on_utility_traded(trade: Dictionary) -> void:
    mark_world_dirty("utility_traded")
    var output_item := String(trade.get("output", ""))
    award_progression("trade: %s" % String(trade.get("label", "barter")), int(trade.get("xp", 6)))
    update_objectives_and_contracts()
    play_feedback("pickup", Vector3.INF, feedback_color_for_material(output_item), 8)
    maybe_emit_story_countermeasure_prepared(output_item, "utility_trade")

func _on_survival_changed() -> void:
    mark_world_dirty("survival_changed")
    if survival_system and survival_system.health < last_survival_health - 0.05:
        play_feedback("damage", Vector3.INF, Color(0.95, 0.22, 0.16), 7)
    if survival_system:
        last_survival_health = survival_system.health
    if hud and survival_system:
        hud.set_survival(survival_system.snapshot())

func _on_progression_changed(state: Dictionary, leveled: bool) -> void:
    mark_world_dirty("progression_changed")
    apply_progression_bonuses(state)
    if hud:
        hud.set_progression(state)
        if leveled:
            hud.set_target_message("Level up: %d" % int(state.get("level", 1)))
    if leveled:
        play_feedback("level", Vector3.INF, Color(1.0, 0.82, 0.36), 18)

func apply_progression_bonuses(state: Dictionary) -> void:
    if survival_system == null:
        return
    var progression_bonuses: Dictionary = state.get("bonuses", {})
    var equipment_bonuses: Dictionary = equipment_system.bonuses() if equipment_system else {}
    survival_system.set_bonuses({
        "health": float(progression_bonuses.get("health", 0.0)) + float(equipment_bonuses.get("health", 0.0)),
        "stamina": float(progression_bonuses.get("stamina", 0.0)) + float(equipment_bonuses.get("stamina", 0.0)),
        "hunger": float(progression_bonuses.get("hunger", 0.0)) + float(equipment_bonuses.get("hunger", 0.0))
    })
    survival_system.armor = float(equipment_system.state().get("armor", 0)) if equipment_system else 0.0

func award_progression(reason: String, amount: int) -> bool:
    if progression_system == null:
        return false
    return progression_system.award(reason, amount)

func award_craft_xp(recipe_id: String) -> void:
    if crafting_system == null:
        return
    var recipe: Dictionary = crafting_system.recipe_for(recipe_id)
    if recipe.is_empty():
        return
    var output := String(recipe.get("output", ""))
    var amount := 8 if bool(recipe.get("requiresWorkbench", false)) else 4
    if output in ["trailPack", "hunterBow", "trailCharm", "surveyLens"]:
        amount = 14
    elif output == "expeditionPack":
        amount = 24
    elif output.begins_with("copper") or output.begins_with("iron"):
        amount = 18
    elif output in ["wardLantern", "wardArmor", "wardAmulet", "nightBlade"]:
        amount = 18
    elif output == "sanctuaryBeacon":
        amount = 35
    elif output == "riftAnchor":
        amount = 45
    award_progression("crafted %s" % String(recipe.get("label", recipe_id)), amount)

func award_break_xp(material_id: String) -> void:
    var xp_by_material := {
        "grass": 1,
        "dirt": 1,
        "sand": 1,
        "mud": 1,
        "snow": 1,
        "tree": 7,
        "rock": 7,
        "wildlife": 8,
        "berryBush": 2,
        "aloePatch": 2,
        "mushroomCluster": 3,
        "frostHerbPatch": 3,
        "copperOre": 9,
        "ironOre": 11,
        "copperVein": 9,
        "ironVein": 11,
        "stone": 5,
        "woodBlock": 2,
        "dirtBlock": 1,
        "stoneBlock": 4,
        "cobblestonePath": 2,
        "workbench": 3,
        "door": 2,
        "bed": 2,
        "glass": 2,
        "chest": 3,
        "traderStall": 3,
        "furnace": 5,
        "campfire": 3,
        "torch": 1,
        "spikeTrap": 5,
        "wardLantern": 8,
        "sanctuaryBeacon": 12,
        "riftAnchor": 15
    }
    var label := ItemCatalogScript.material_label(material_id)
    award_progression("%s broken" % label, int(xp_by_material.get(material_id, 2)))

func award_hostile_xp(variant: String) -> void:
    var xp_by_variant := {
        "shadow": 14,
        "frost": 16,
        "skitter": 12,
        "mire": 22,
        "seer": 18,
        "rift": 50
    }
    award_progression("defeated %s" % variant, int(xp_by_variant.get(variant, 14)))

func award_place_xp(block_type: String) -> void:
    if block_type in ["woodBlock", "stoneBlock", "dirtBlock", "glass", "cobblestonePath", "torch"]:
        award_progression("placed %s" % ItemCatalogScript.label(block_type), 1)
    elif ItemCatalogScript.is_placeable(block_type):
        award_progression("placed %s" % ItemCatalogScript.label(block_type), 2)

func _on_teleport_requested(value: String) -> void:
    if teleport_to(value):
        if hud:
            hud.set_teleport_open(false)
        Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _on_setting_changed(setting: String, value) -> void:
    apply_runtime_setting(setting, value)

func _on_playtest_requested(case_id: String) -> void:
    if run_playtest_case(case_id):
        if hud:
            hud.set_playtest_open(false)
        Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _on_playtest_cleanup_requested() -> void:
    cleanup_playtest_case_assets()
    var counts := playtest_case_counts()
    var message := "Playtest cleanup: %d props, %d blocks, %d hostiles" % [
        int(counts.get("props", 0)),
        int(counts.get("blocks", 0)),
        int(counts.get("hostiles", 0))
    ]
    if hud:
        hud.set_playtest_status(message)
    update_hud(message)

func apply_runtime_settings() -> void:
    for setting_variant in runtime_settings.keys():
        apply_runtime_setting(String(setting_variant), runtime_settings[setting_variant], false)
    if hud:
        hud.set_settings_state(runtime_settings)
        if story_accessibility_settings and hud.has_method("set_story_accessibility_state"):
            hud.set_story_accessibility_state(story_accessibility_settings.state())
