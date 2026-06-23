extends RefCounted
class_name GameHudRenderer

const InventorySlotButtonScript := preload("res://scripts/InventorySlotButton.gd")
const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")

static func set_status(hud, seed_text: String, biome: String, chunk_count: int, coords: Vector2, time_text: String) -> void:
    hud.last_status_state = {
        "seed": seed_text,
        "biome": biome,
        "chunkCount": chunk_count,
        "coords": coords,
        "time": time_text
    }
    refresh_status_label(hud)

static func refresh_status_label(hud) -> void:
    if hud.status_label == null or not (hud.last_status_state is Dictionary) or hud.last_status_state.is_empty():
        return
    var biome := String(hud.last_status_state.get("biome", "")).capitalize()
    var time_text := String(hud.last_status_state.get("time", ""))
    if bool(hud.debug_readout_visible):
        var coords := hud.last_status_state.get("coords", Vector2.ZERO) as Vector2
        hud.status_label.text = "Voxel Biome World Godot\nseed %s | %s | %d chunks\n%s | %.0f, %.0f" % [
            String(hud.last_status_state.get("seed", "")),
            biome,
            int(hud.last_status_state.get("chunkCount", 0)),
            time_text,
            coords.x,
            coords.y
        ]
        return
    hud.status_label.text = "Voxel Biome World\n%s | %s" % [biome, time_text]

static func set_performance(hud, state: Dictionary) -> void:
    if hud.performance_label == null or not hud.performance_label.visible:
        return
    var hud_refresh: Dictionary = state.get("hudRefresh", {})
    var chunk_cache: Dictionary = state.get("chunkCache", {})
    hud.performance_label.text = "FPS %d | frame %.2fms | chunks %d | props %d | blocks %d\nhostiles %d | pickups %d | bodies %d | draw est %d\nchunk %.2f | sky %.2f | hostile %.2f | survival %.2f | hud %.2f\nutility %.2f | pickups %.2f | beacon %.2f | break %.2f | save %.2f\nHUD refresh %d/%d skip %d | chunk cache h/m/i %d/%d/%d" % [
        roundi(float(state.get("fps", 0.0))),
        float(state.get("frameMs", 0.0)),
        int(state.get("chunks", 0)),
        int(state.get("props", 0)),
        int(state.get("blocks", 0)),
        int(state.get("hostiles", 0)),
        int(state.get("pickups", 0)),
        int(state.get("physicsBodies", 0)),
        int(state.get("drawEstimate", 0)),
        float(state.get("chunkMs", 0.0)),
        float(state.get("skyMs", 0.0)),
        float(state.get("hostilesMs", 0.0)),
        float(state.get("survivalMs", 0.0)),
        float(state.get("hudMs", 0.0)),
        float(state.get("utilityMs", 0.0)),
        float(state.get("pickupsMs", 0.0)),
        float(state.get("beaconMs", 0.0)),
        float(state.get("breakMs", 0.0)),
        float(state.get("autosaveMs", 0.0)),
        int(hud_refresh.get("throttled", 0)),
        int(hud_refresh.get("manual", 0)),
        int(hud_refresh.get("skipped", 0)),
        int(chunk_cache.get("hits", 0)),
        int(chunk_cache.get("misses", 0)),
        int(chunk_cache.get("invalidations", 0))
    ]

static func set_survival(hud, state: Dictionary) -> void:
    if hud.health_label == null:
        return
    hud.health_label.text = "HP %d/%d" % [roundi(float(state.get("health", 100.0))), roundi(float(state.get("maxHealth", 100.0)))]
    hud.stamina_label.text = "STA %d/%d" % [roundi(float(state.get("stamina", 100.0))), roundi(float(state.get("maxStamina", 100.0)))]
    hud.hunger_label.text = "HUN %d/%d" % [roundi(float(state.get("hunger", 100.0))), roundi(float(state.get("maxHunger", 100.0)))]
    hud.armor_label.text = "ARM %d" % roundi(float(state.get("armor", 0.0)))
    hud.danger_label.text = String(state.get("danger", "Safe"))

static func set_progression(hud, state: Dictionary) -> void:
    if hud.level_label == null:
        return
    var current_level := int(state.get("level", 1))
    var current_xp := int(state.get("xp", 0))
    var needed := int(state.get("needed", 80))
    hud.level_label.text = "Lvl %d | XP %d/%d" % [current_level, current_xp, needed]
    if hud.xp_bar:
        hud.xp_bar.max_value = maxf(1.0, float(needed))
        hud.xp_bar.value = clampf(float(current_xp), 0.0, float(needed))
    if hud.xp_recent_label:
        hud.xp_recent_label.text = String(state.get("recent", "No XP earned yet"))

static func set_navigation(hud, compass_visible: bool, map_visible: bool, heading_text: String, map_state: Dictionary) -> void:
    hud.map_enabled = map_visible
    hud.current_map_state = map_state.duplicate(true)
    if hud.compass_label:
        hud.compass_label.visible = compass_visible
        hud.compass_label.text = heading_text
    if hud.compass_waypoint_label:
        hud.compass_waypoint_label.visible = compass_visible
        hud.compass_waypoint_label.text = String(map_state.get("waypointsText", "No tracked structures nearby"))
    if hud.mini_map:
        hud.mini_map.set_map_state(map_state)
    apply_map_panel_state(hud)

static func apply_map_panel_state(hud) -> void:
    if hud.map_panel:
        hud.map_panel.visible = hud.map_enabled
    if hud.mini_map:
        hud.mini_map.visible = hud.map_enabled and not hud.map_collapsed
    if hud.map_info_label:
        hud.map_info_label.visible = hud.map_enabled
        hud.map_info_label.text = "Map hidden" if hud.map_collapsed else String(hud.current_map_state.get("markerSummary", "%d nearby" % int(hud.current_map_state.get("pointCount", 0))))

static func render(hud) -> void:
    if hud.inventory == null:
        return
    var inventory_open: bool = hud.inventory_panel != null and hud.inventory_panel.visible
    if inventory_open:
        if hud.hotbar:
            hud.hotbar.visible = false
        if hud.active_label:
            hud.active_label.visible = false
    if hud.hotbar == null or hud.hotbar.visible:
        render_hotbar(hud)
    render_active(hud)
    render_equipment(hud)
    render_objectives(hud)
    render_contracts(hud)
    if hud.inventory_panel and hud.inventory_panel.visible:
        render_inventory_grid(hud)
        render_crafting_list(hud)

static func render_utility(hud, state: Dictionary) -> void:
    if hud.utility_panel == null:
        return
    if state.is_empty():
        hide_utility_panel(hud)
        return
    hud.utility_panel.visible = true
    clear_container(hud.utility_grid)
    clear_container(hud.utility_actions)
    var block_type := String(state.get("type", ""))
    hud.utility_title.text = ItemCatalogScript.label(block_type)
    hud.utility_status.text = String(state.get("status", ""))
    hud.utility_progress.text = ""
    if block_type == "chest":
        hud.utility_grid.columns = 4
        var slots: Array = state.get("slots", [])
        for i in range(slots.size()):
            var slot: Dictionary = slots[i] if slots[i] is Dictionary else { "item": "", "count": 0 }
            hud.utility_grid.add_child(make_utility_slot_button(hud, slot, "", "chest_slot", i))
        return
    if block_type == "furnace" or block_type == "campfire":
        render_heat_station(hud, state, block_type)
        return
    if block_type == "traderStall":
        render_trader_stall(hud, state)

static func render_heat_station(hud, state: Dictionary, block_type: String) -> void:
    hud.utility_grid.columns = 3
    hud.utility_grid.add_child(make_utility_slot_button(hud, state.get("input", {}), "In", "furnace_slot", "input"))
    hud.utility_grid.add_child(make_utility_slot_button(hud, state.get("fuel", {}), "Fuel", "furnace_slot", "fuel"))
    hud.utility_grid.add_child(make_utility_slot_button(hud, state.get("output", {}), "Out", "furnace_slot", "output"))
    var processing: bool = bool(state.get("processing", false))
    var progress: float = float(state.get("progress", 0.0))
    var duration: float = maxf(0.01, float(state.get("duration", 1.0)))
    hud.utility_progress.text = "Progress %.0f%%" % ((progress / duration) * 100.0) if processing else ""
    var start_button := Button.new()
    start_button.text = "Cook" if block_type == "campfire" else "Smelt"
    start_button.disabled = not bool(state.get("canProcess", false))
    start_button.pressed.connect(Callable(hud, "_on_utility_action_pressed").bind("start_processing", null))
    hud.utility_actions.add_child(start_button)

static func render_trader_stall(hud, state: Dictionary) -> void:
    hud.utility_grid.columns = 1
    var trades: Array = state.get("trades", [])
    for row_value in trades:
        if not (row_value is Dictionary):
            continue
        var trade: Dictionary = row_value
        var button := Button.new()
        button.custom_minimum_size = Vector2(304, 58)
        button.alignment = HORIZONTAL_ALIGNMENT_LEFT
        button.clip_text = true
        style_item_button_icon(button)
        button.icon = icon_for(hud, String(trade.get("output", "")))
        button.text = "%s x%d\n%s" % [String(trade.get("label", "")), int(trade.get("amount", 1)), String(trade.get("status", ""))]
        button.disabled = bool(trade.get("disabled", true))
        button.pressed.connect(Callable(hud, "_on_utility_action_pressed").bind("trade", String(trade.get("id", ""))))
        hud.utility_grid.add_child(button)

static func hide_utility_panel(hud) -> void:
    if hud.utility_panel:
        hud.utility_panel.visible = false

static func render_objectives(hud) -> void:
    if hud.objectives == null or hud.objective_list == null:
        return
    clear_container(hud.objective_list)
    for objective in hud.objectives.all_objectives():
        var label := Label.new()
        var done := bool(objective.get("completed", false))
        var available := bool(objective.get("available", true))
        label.text = "%s %s" % ["DONE" if done else ("TODO" if available else "LOCKED"), String(objective.get("label", ""))]
        label.modulate = Color(0.74, 0.92, 0.78) if done else (Color(0.92, 0.92, 0.88) if available else Color(0.68, 0.72, 0.70, 0.74))
        hud.objective_list.add_child(label)

static func render_contracts(hud) -> void:
    if hud.contracts == null or hud.contract_panel == null or hud.contract_list == null:
        return
    clear_container(hud.contract_list)
    var state: Dictionary = hud.contracts.state()
    var unlocked := bool(state.get("townUnlocked", false))
    hud.contract_panel.visible = unlocked and bool(state.get("menuOpen", false)) and not hud.inventory_panel.visible and not hud.teleport_panel.visible
    hud.contract_status.text = "%d/%d" % [int(state.get("completed", 0)), int(state.get("total", 0))] if unlocked else "Locked"
    hud.contract_recent.text = String(state.get("recent", "Find a town to unlock contracts"))
    if not unlocked:
        return
    for row_value in state.get("contracts", []):
        if not (row_value is Dictionary):
            continue
        var row: Dictionary = row_value
        var done := bool(row.get("completed", false))
        var active := bool(row.get("active", false))
        var label := Label.new()
        label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        label.text = "%s %s\n%s\n%s" % ["DONE" if done else (">" if active else "TODO"), String(row.get("label", "")), String(row.get("detail", "")), String(row.get("reward", ""))]
        label.modulate = Color(0.74, 0.92, 0.78) if done else (Color(1.0, 0.92, 0.62) if active else Color(0.88, 0.90, 0.86))
        hud.contract_list.add_child(label)

static func render_active(hud) -> void:
    var stack: Dictionary = hud.inventory.active_stack()
    var item_id := String(stack.get("item", ""))
    hud.active_label.text = "Active: empty" if item_id == "" else "Active: %s x%d" % [ItemCatalogScript.label(item_id), int(stack.get("count", 0))]

static func render_hotbar(hud) -> void:
    ensure_hotbar_slots(hud)
    for i in range(hud.inventory.hotbar_size):
        var slot: Dictionary = hud.inventory.slots[i] if i < hud.inventory.slots.size() else { "item": "", "count": 0 }
        update_slot_button(hud, hud.hotbar_slot_buttons[i], slot, i, true)

static func ensure_hotbar_slots(hud) -> void:
    if hud.hotbar == null or hud.inventory == null:
        return
    while hud.hotbar_slot_buttons.size() < hud.inventory.hotbar_size:
        var index: int = int(hud.hotbar_slot_buttons.size())
        var button := make_slot_button(hud, { "item": "", "count": 0 }, index, true)
        hud.hotbar_slot_buttons.append(button)
        hud.hotbar.add_child(button)
    while hud.hotbar_slot_buttons.size() > hud.inventory.hotbar_size:
        var button := hud.hotbar_slot_buttons.pop_back() as Button
        if button:
            hud.hotbar.remove_child(button)
            button.queue_free()

static func render_inventory_grid(hud) -> void:
    clear_container(hud.inventory_grid)
    for i in range(hud.inventory.slots.size()):
        hud.inventory_grid.add_child(make_slot_button(hud, hud.inventory.slots[i], i, false))

static func render_crafting_list(hud) -> void:
    clear_container(hud.crafting_list)
    var state: Dictionary = hud.crafting.recipe_states()
    hud.crafting_status.text = "Workbench + Anvil ready" if bool(state.get("hasBench", false)) and bool(state.get("hasAnvil", false)) else ("Workbench ready" if bool(state.get("hasBench", false)) else ("Anvil ready" if bool(state.get("hasAnvil", false)) else "No station"))
    for recipe_state in state.get("recipes", []):
        var recipe: Dictionary = recipe_state.get("recipe", {})
        var output := String(recipe.get("output", ""))
        var button := Button.new()
        button.custom_minimum_size = Vector2(348, 56)
        button.alignment = HORIZONTAL_ALIGNMENT_LEFT
        style_item_button_icon(button)
        button.text = "%s x%d\n%s" % [recipe.get("label", output), int(recipe.get("amount", 1)), recipe_state.get("status", "")]
        button.icon = icon_for(hud, output)
        button.disabled = bool(recipe_state.get("disabled", true))
        button.pressed.connect(Callable(hud, "_on_craft_pressed").bind(String(recipe.get("id", ""))))
        hud.crafting_list.add_child(button)

static func render_equipment(hud) -> void:
    if hud.equipment == null or hud.armor_slot_button == null or hud.accessory_slot_button == null:
        return
    update_equipment_button(hud, hud.armor_slot_button, "body", "Armor", "A")
    update_equipment_button(hud, hud.accessory_slot_button, "accessory", "Charm", "C")
    var labels := []
    for item_id in [String(hud.equipment.equipped_item("body")), String(hud.equipment.equipped_item("accessory"))]:
        if item_id != "":
            labels.append(ItemCatalogScript.label(item_id))
    var state: Dictionary = hud.equipment.state()
    var bonus: Dictionary = state.get("bonuses", {})
    hud.equipment_readout.text = "Equipment: %s | Armor %d | +STA %d +HUN %d" % [", ".join(labels) if labels.size() > 0 else "none", int(state.get("armor", 0)), roundi(float(bonus.get("stamina", 0.0))), roundi(float(bonus.get("hunger", 0.0)))]

static func make_slot_button(hud, slot: Dictionary, index: int, compact: bool) -> Button:
    var button := InventorySlotButtonScript.new()
    button.toggle_mode = false
    button.disabled = false
    button.pressed.connect(Callable(hud, "_on_slot_pressed").bind(index, compact))
    button.slot_dropped.connect(Callable(hud, "_on_slot_dropped"))
    update_slot_button(hud, button, slot, index, compact)
    return button

static func update_slot_button(hud, button: Button, slot: Dictionary, index: int, compact: bool) -> void:
    var item_id := String(slot.get("item", ""))
    var count := int(slot.get("count", 0))
    button.custom_minimum_size = Vector2(82, 58) if compact else Vector2(116, 72)
    button.clip_text = true
    style_item_button_icon(button)
    button.configure(index, item_id, count, compact)
    button.icon = null
    button.remove_theme_color_override("font_color")
    var selected: bool = index == int(hud.inventory.selected_slot)
    if compact:
        button.theme_type_variation = &"HotbarSlotSelected" if selected else &"HotbarSlot"
    else:
        button.theme_type_variation = &"InventorySlotSelected" if selected else &"InventorySlot"
    if item_id == "":
        button.text = "%d\nEmpty" % (index + 1) if compact else "Empty"
    else:
        button.icon = icon_for(hud, item_id)
        button.text = "%d\nx%d" % [index + 1, count] if compact else "%s\nx%d" % [ItemCatalogScript.label(item_id), count]

static func make_equipment_button(hud, slot: String, label: String, key: String) -> Button:
    var button := Button.new()
    button.custom_minimum_size = Vector2(150, 58)
    button.clip_text = true
    style_item_button_icon(button)
    button.text = "%s\n%s" % [key, label]
    button.pressed.connect(Callable(hud, "_on_equipment_slot_pressed").bind(slot))
    return button

static func update_equipment_button(hud, button: Button, slot: String, label: String, key: String) -> void:
    var item_id := String(hud.equipment.equipped_item(slot))
    if item_id == "":
        button.text = "%s\n%s" % [key, label]
        button.icon = null
        return
    button.text = "%s\n%s" % [key, ItemCatalogScript.label(item_id)]
    button.icon = icon_for(hud, item_id)

static func make_vital_label(text: String) -> Label:
    var label := Label.new()
    label.text = text
    label.add_theme_font_size_override("font_size", 14)
    return label

static func make_utility_slot_button(hud, slot: Dictionary, label: String, action: String, payload) -> Button:
    var item_id := String(slot.get("item", ""))
    var count := int(slot.get("count", 0))
    var button := Button.new()
    button.custom_minimum_size = Vector2(74, 58)
    button.clip_text = true
    style_item_button_icon(button)
    if item_id == "":
        button.text = "%s\nEmpty" % label if label != "" else "Empty"
    else:
        button.icon = icon_for(hud, item_id)
        button.text = "%s\nx%d" % [label if label != "" else ItemCatalogScript.label(item_id), count]
    button.pressed.connect(Callable(hud, "_on_utility_action_pressed").bind(action, payload))
    return button

static func icon_for(hud, item_id: String) -> Texture2D:
    if hud.icon_factory:
        return hud.icon_factory.icon_for(item_id)
    if hud.icon_cache.has(item_id):
        return hud.icon_cache[item_id]
    var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
    var base := icon_color(item_id)
    image.fill(base)
    var border := base.darkened(0.45)
    for x in range(32):
        image.set_pixel(x, 0, border)
        image.set_pixel(x, 31, border)
    for y in range(32):
        image.set_pixel(0, y, border)
        image.set_pixel(31, y, border)
    var accent := base.lightened(0.24)
    var hash_value: int = int(hud.hash_string(item_id))
    for i in range(34):
        var px := 3 + posmod(hash_value + i * 11, 26)
        var py := 3 + posmod(hash_value / 7 + i * 17, 26)
        image.set_pixel(px, py, accent)
        if px + 1 < 31:
            image.set_pixel(px + 1, py, accent)
    var texture := ImageTexture.create_from_image(image)
    hud.icon_cache[item_id] = texture
    return texture

static func style_item_button_icon(button: Button) -> void:
    button.add_theme_constant_override("icon_max_width", 42)
    button.add_theme_constant_override("h_separation", 7)

static func update_slider_label(hud, setting: String, value: float) -> void:
    if not hud.setting_controls.has(setting):
        return
    var entry: Dictionary = hud.setting_controls[setting]
    var label := entry.get("label", null) as Label
    if label == null:
        return
    var label_text := String(entry.get("labelText", setting))
    if setting == "renderDistance" or setting == "fov":
        label.text = "%s %d" % [label_text, roundi(value)]
    elif setting == "weatherParticles" or setting == "lookSmoothing":
        label.text = "%s %d%%" % [label_text, roundi(value * 100.0)]
    else:
        label.text = "%s %.2f" % [label_text, value]

static func icon_color(item_id: String) -> Color:
    if item_id.find("wood") >= 0 or item_id in ["logs", "door", "workbench", "chest", "campfire", "torch", "traderStall"]:
        return Color(0.62, 0.39, 0.19)
    if item_id.find("stone") >= 0 or item_id in ["stones", "cobblestonePath", "furnace", "anvil"]:
        return Color(0.52, 0.56, 0.53)
    if item_id in ["dirt", "dirtBlock", "mud"]:
        return Color(0.38, 0.25, 0.15)
    if item_id in ["sand", "glass"]:
        return Color(0.68, 0.84, 0.90)
    if item_id in ["grass", "berries", "aloe", "mirecap", "frostHerb"]:
        return Color(0.32, 0.62, 0.30)
    if item_id.find("iron") >= 0:
        return Color(0.72, 0.74, 0.70)
    if item_id.find("copper") >= 0:
        return Color(0.76, 0.44, 0.25)
    return Color(0.46, 0.50, 0.58)

static func clear_container(container: Node) -> void:
    if container == null:
        return
    for child in container.get_children():
        container.remove_child(child)
        child.queue_free()
