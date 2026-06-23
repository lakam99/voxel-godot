extends CanvasLayer
class_name GameHud

const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")
const ItemIconFactoryScript := preload("res://scripts/ItemIconFactory.gd")
const MiniMapDisplayScript := preload("res://scripts/MiniMapDisplay.gd")
const InventorySlotButtonScript := preload("res://scripts/InventorySlotButton.gd")
const GameHudLayoutBuilderScript := preload("res://scripts/GameHudLayoutBuilder.gd")
const GameHudRendererScript := preload("res://scripts/GameHudRenderer.gd")
const GameHudOverlayControllerScript := preload("res://scripts/GameHudOverlayController.gd")
const HudStyleFactoryScript := preload("res://scripts/visual/HudStyleFactory.gd")
const GAME_BUILD_LABEL := "build 2026.06.22.8"

signal slot_clicked(index)
signal slot_moved(from_index, to_index)
signal craft_requested(recipe_id)
signal utility_action_requested(action, payload)
signal teleport_requested(value)
signal equipment_slot_clicked(slot)
signal setting_changed(setting, value)
signal playtest_requested(case_id)
signal playtest_cleanup_requested
signal resume_requested
signal new_game_requested
signal dialogue_closed(context)

var inventory
var crafting
var objectives
var equipment
var contracts

var hud_root: Control
var ui_theme: Theme
var debug_readout_visible := false
var last_status_state := {}
var status_label: Label
var version_label: Label
var target_label: Label
var active_label: Label
var level_label: Label
var xp_bar: ProgressBar
var xp_recent_label: Label
var health_label: Label
var stamina_label: Label
var hunger_label: Label
var armor_label: Label
var danger_label: Label
var hotbar: HBoxContainer
var inventory_panel: PanelContainer
var inventory_grid: GridContainer
var crafting_list: VBoxContainer
var crafting_status: Label
var armor_slot_button: Button
var accessory_slot_button: Button
var equipment_readout: Label
var utility_panel: PanelContainer
var utility_title: Label
var utility_status: Label
var utility_grid: GridContainer
var utility_progress: Label
var utility_actions: HBoxContainer
var teleport_panel: PanelContainer
var teleport_input: LineEdit
var teleport_status: Label
var settings_panel: PanelContainer
var settings_grid: GridContainer
var playtest_panel: PanelContainer
var playtest_list: VBoxContainer
var playtest_route_label: Label
var playtest_status: Label
var game_menu_panel: PanelContainer
var performance_label: Label
var compass_label: Label
var compass_waypoint_label: Label
var map_panel: PanelContainer
var mini_map
var map_info_label: Label
var objective_toast: Label
var objective_panel: PanelContainer
var objective_list: VBoxContainer
var contract_panel: PanelContainer
var contract_status: Label
var contract_list: VBoxContainer
var contract_recent: Label
var victory_panel: PanelContainer
var victory_stats_list: GridContainer
var dialogue_panel: PanelContainer
var dialogue_speaker_label: Label
var dialogue_role_label: Label
var dialogue_body_label: Label
var dialogue_reply_label: Label
var dialogue_context := {}
var objective_toast_time := 0.0
var sleep_fade_overlay: ColorRect
var sleep_fade_tween: Tween
var icon_cache := {}
var icon_factory
var hotbar_slot_buttons: Array[Button] = []
var setting_controls := {}
var settings_state := {}
var playtest_cases := []
var map_enabled := false
var map_collapsed := false
var current_map_state := {}

func setup(inventory_system, crafting_system, objective_system = null, equipment_system = null, contract_system = null) -> void:
    inventory = inventory_system
    crafting = crafting_system
    objectives = objective_system
    equipment = equipment_system
    contracts = contract_system
    icon_factory = ItemIconFactoryScript.new()
    build_ui()
    inventory.changed.connect(render)
    crafting.changed.connect(render)
    if objectives:
        objectives.changed.connect(render_objectives)
    if equipment:
        equipment.changed.connect(render)
    if contracts:
        contracts.changed.connect(render_contracts)
    render()

func build_ui() -> void:
    GameHudLayoutBuilderScript.build_ui(self)
    HudStyleFactoryScript.apply(self)

func play_sleep_fade(fade_out := 0.55, hold := 0.45, fade_in := 0.70) -> void:
    GameHudOverlayControllerScript.play_sleep_fade(self, fade_out, hold, fade_in)

func is_sleep_fading() -> bool:
    return sleep_fade_overlay != null and sleep_fade_overlay.visible

func set_status(seed_text: String, biome: String, chunk_count: int, coords: Vector2, time_text: String) -> void:
    GameHudRendererScript.set_status(self, seed_text, biome, chunk_count, coords, time_text)

func set_performance(state: Dictionary) -> void:
    GameHudRendererScript.set_performance(self, state)

func set_performance_open(open: bool) -> void:
    debug_readout_visible = open
    if performance_label:
        performance_label.visible = open
    if version_label:
        version_label.visible = open
    GameHudRendererScript.refresh_status_label(self)

func toggle_performance() -> bool:
    set_performance_open(not performance_label.visible)
    return performance_label.visible

func is_performance_open() -> bool:
    return performance_label != null and performance_label.visible

func set_settings_state(state: Dictionary) -> void:
    settings_state = state.duplicate(true)
    for setting in setting_controls.keys():
        if not settings_state.has(setting):
            continue
        var entry: Dictionary = setting_controls[setting]
        var control = entry.get("control", null)
        if control is HSlider:
            control.set_value_no_signal(float(settings_state.get(setting)))
            update_slider_label(setting, float(settings_state.get(setting)))
        elif control is CheckBox:
            control.set_pressed_no_signal(bool(settings_state.get(setting)))

func set_settings_open(open: bool) -> void:
    if settings_panel == null:
        return
    settings_panel.visible = open
    if open:
        hide_dialogue()
        if game_menu_panel:
            game_menu_panel.visible = false
        set_inventory_open(false)
        set_teleport_open(false)
        set_playtest_open(false)
        hide_utility_panel()
        if contract_panel:
            contract_panel.visible = false
            if contracts:
                contracts.toggle_menu(false)

func toggle_settings() -> bool:
    set_settings_open(not settings_panel.visible)
    return settings_panel.visible

func is_settings_open() -> bool:
    return settings_panel != null and settings_panel.visible

func set_game_menu_open(open: bool) -> void:
    if game_menu_panel == null:
        return
    game_menu_panel.visible = open
    if open:
        hide_dialogue()
        set_inventory_open(false)
        set_teleport_open(false)
        set_settings_open(false)
        set_playtest_open(false)
        hide_utility_panel()
        if objective_panel:
            objective_panel.visible = false
        if contract_panel:
            contract_panel.visible = false
            if contracts:
                contracts.toggle_menu(false)

func toggle_game_menu() -> bool:
    set_game_menu_open(not game_menu_panel.visible)
    return game_menu_panel.visible

func is_game_menu_open() -> bool:
    return game_menu_panel != null and game_menu_panel.visible

func set_playtest_open(open: bool) -> void:
    if playtest_panel == null:
        return
    playtest_panel.visible = open
    if open:
        hide_dialogue()
        if game_menu_panel:
            game_menu_panel.visible = false
        set_inventory_open(false)
        set_teleport_open(false)
        set_settings_open(false)
        hide_utility_panel()
        if contract_panel:
            contract_panel.visible = false
            if contracts:
                contracts.toggle_menu(false)

func toggle_playtest() -> bool:
    set_playtest_open(not playtest_panel.visible)
    return playtest_panel.visible

func is_playtest_open() -> bool:
    return playtest_panel != null and playtest_panel.visible

func set_playtest_cases(cases: Array) -> void:
    playtest_cases = cases.duplicate(true)
    render_playtest_cases()
    if playtest_cases.size() > 0:
        set_playtest_route(String((playtest_cases[0] as Dictionary).get("id", "")))

func render_playtest_cases() -> void:
    if playtest_list == null:
        return
    clear_container(playtest_list)
    for case_value in playtest_cases:
        if not (case_value is Dictionary):
            continue
        var case: Dictionary = case_value
        var button := Button.new()
        button.text = "%s | %s" % [String(case.get("label", "Case")), String(case.get("detail", ""))]
        button.custom_minimum_size = Vector2(480, 38)
        button.pressed.connect(_on_playtest_case_pressed.bind(String(case.get("id", ""))))
        playtest_list.add_child(button)

func set_playtest_route(case_id: String) -> void:
    if playtest_route_label == null:
        return
    for case_value in playtest_cases:
        if not (case_value is Dictionary):
            continue
        var case: Dictionary = case_value
        if String(case.get("id", "")) != case_id:
            continue
        playtest_route_label.text = "%s: %s\nChecks: %s" % [
            String(case.get("label", case_id.capitalize())),
            String(case.get("detail", "")),
            String(case.get("validates", "case setup"))
        ]
        return
    playtest_route_label.text = "Select a case"

func set_playtest_status(message: String) -> void:
    if playtest_status:
        playtest_status.text = message

func set_target_message(message: String) -> void:
    target_label.text = message

func set_survival(state: Dictionary) -> void:
    GameHudRendererScript.set_survival(self, state)

func set_progression(state: Dictionary) -> void:
    GameHudRendererScript.set_progression(self, state)

func set_equipment(state: Dictionary) -> void:
    GameHudRendererScript.render_equipment(self)

func set_navigation(compass_visible: bool, map_visible: bool, heading_text: String, map_state: Dictionary) -> void:
    GameHudRendererScript.set_navigation(self, compass_visible, map_visible, heading_text, map_state)

func apply_map_panel_state() -> void:
    GameHudRendererScript.apply_map_panel_state(self)

func set_map_collapsed(collapsed: bool) -> bool:
    map_collapsed = collapsed
    apply_map_panel_state()
    return map_collapsed

func toggle_map() -> bool:
    return set_map_collapsed(not map_collapsed)

func is_map_collapsed() -> bool:
    return map_collapsed

func set_contracts(state: Dictionary) -> void:
    GameHudRendererScript.render_contracts(self)

func set_inventory_open(open: bool) -> void:
    inventory_panel.visible = open
    if hotbar:
        hotbar.visible = not open
    if active_label:
        active_label.visible = not open
    if open:
        hide_dialogue()
    if open and game_menu_panel:
        game_menu_panel.visible = false
    if open and objective_panel:
        objective_panel.visible = false
    if open and contract_panel:
        contract_panel.visible = false
        if contracts:
            contracts.toggle_menu(false)
    if open and teleport_panel:
        teleport_panel.visible = false
    if open and settings_panel:
        settings_panel.visible = false
    if open and playtest_panel:
        playtest_panel.visible = false
    if open:
        hide_utility_panel()
    render()

func toggle_inventory() -> bool:
    set_inventory_open(not inventory_panel.visible)
    return inventory_panel.visible

func is_inventory_open() -> bool:
    return inventory_panel.visible

func is_utility_open() -> bool:
    return utility_panel != null and utility_panel.visible

func set_teleport_open(open: bool) -> void:
    if teleport_panel == null:
        return
    teleport_panel.visible = open
    if open:
        hide_dialogue()
        if game_menu_panel:
            game_menu_panel.visible = false
        set_inventory_open(false)
        hide_utility_panel()
        if contract_panel:
            contract_panel.visible = false
            if contracts:
                contracts.toggle_menu(false)
        if settings_panel:
            settings_panel.visible = false
        if playtest_panel:
            playtest_panel.visible = false
        teleport_status.text = "Enter coordinates"
        teleport_input.grab_focus()
        teleport_input.select_all()

func toggle_teleport() -> bool:
    set_teleport_open(not teleport_panel.visible)
    return teleport_panel.visible

func is_teleport_open() -> bool:
    return teleport_panel != null and teleport_panel.visible

func set_teleport_status(message: String) -> void:
    if teleport_status:
        teleport_status.text = message

func toggle_objectives() -> bool:
    if inventory_panel.visible or settings_panel.visible or playtest_panel.visible or is_game_menu_open():
        objective_panel.visible = false
        return false
    if is_dialogue_open():
        hide_dialogue()
    if contract_panel:
        contract_panel.visible = false
    objective_panel.visible = not objective_panel.visible
    render_objectives()
    return objective_panel.visible

func toggle_contracts() -> bool:
    if contracts == null or contract_panel == null:
        return false
    if inventory_panel.visible or teleport_panel.visible or settings_panel.visible or playtest_panel.visible or is_game_menu_open():
        contract_panel.visible = false
        return false
    if is_dialogue_open():
        hide_dialogue()
    var state: Dictionary = contracts.state()
    if not bool(state.get("townUnlocked", false)):
        contract_panel.visible = false
        set_target_message("Find a town to unlock contracts")
        return false
    if objective_panel:
        objective_panel.visible = false
    var open: bool = contracts.toggle_menu()
    render_contracts()
    return open

func is_contracts_open() -> bool:
    return contract_panel != null and contract_panel.visible

func show_victory(stats: Array) -> void:
    GameHudOverlayControllerScript.show_victory(self, stats)

func hide_victory() -> void:
    if victory_panel:
        victory_panel.visible = false

func is_victory_open() -> bool:
    return victory_panel != null and victory_panel.visible

func show_dialogue(speaker: String, role: String, body: String, context := {}) -> void:
    GameHudOverlayControllerScript.show_dialogue(self, speaker, role, body, context)

func hide_dialogue(emit_signal := true) -> void:
    GameHudOverlayControllerScript.hide_dialogue(self, emit_signal)

func is_dialogue_open() -> bool:
    return dialogue_panel != null and dialogue_panel.visible

func _on_dialogue_close_pressed() -> void:
    hide_dialogue(true)

func show_objective_complete(label: String) -> void:
    GameHudOverlayControllerScript.show_objective_complete(self, label)

func _process(delta: float) -> void:
    GameHudOverlayControllerScript.process(self, delta)

func render() -> void:
    GameHudRendererScript.render(self)

func render_utility(state: Dictionary) -> void:
    GameHudRendererScript.render_utility(self, state)

func hide_utility_panel() -> void:
    GameHudRendererScript.hide_utility_panel(self)

func render_objectives() -> void:
    GameHudRendererScript.render_objectives(self)

func render_contracts() -> void:
    GameHudRendererScript.render_contracts(self)

func render_active() -> void:
    GameHudRendererScript.render_active(self)

func render_hotbar() -> void:
    GameHudRendererScript.render_hotbar(self)

func render_inventory_grid() -> void:
    GameHudRendererScript.render_inventory_grid(self)

func render_crafting_list() -> void:
    GameHudRendererScript.render_crafting_list(self)

func render_equipment() -> void:
    GameHudRendererScript.render_equipment(self)

func make_slot_button(slot: Dictionary, index: int, compact: bool) -> Button:
    return GameHudRendererScript.make_slot_button(self, slot, index, compact)

func make_equipment_button(slot: String, label: String, key: String) -> Button:
    return GameHudRendererScript.make_equipment_button(self, slot, label, key)

func update_equipment_button(button: Button, slot: String, label: String, key: String) -> void:
    GameHudRendererScript.update_equipment_button(self, button, slot, label, key)

func make_vital_label(text: String) -> Label:
    return GameHudRendererScript.make_vital_label(text)

func make_utility_slot_button(slot: Dictionary, label: String, action: String, payload) -> Button:
    return GameHudRendererScript.make_utility_slot_button(self, slot, label, action, payload)

func icon_for(item_id: String) -> Texture2D:
    return GameHudRendererScript.icon_for(self, item_id)

func style_item_button_icon(button: Button) -> void:
    GameHudRendererScript.style_item_button_icon(button)

func update_slider_label(setting: String, value: float) -> void:
    GameHudRendererScript.update_slider_label(self, setting, value)

func icon_color(item_id: String) -> Color:
    return GameHudRendererScript.icon_color(item_id)

func clear_container(container: Node) -> void:
    GameHudRendererScript.clear_container(container)

func _on_slot_pressed(index: int, compact := false) -> void:
    if inventory_panel and inventory_panel.visible and not compact:
        return
    slot_clicked.emit(index)

func _on_slot_dropped(from_index: int, to_index: int) -> void:
    slot_moved.emit(from_index, to_index)

func _on_craft_pressed(recipe_id: String) -> void:
    craft_requested.emit(recipe_id)

func _on_utility_action_pressed(action: String, payload) -> void:
    utility_action_requested.emit(action, payload)

func _on_equipment_slot_pressed(slot: String) -> void:
    equipment_slot_clicked.emit(slot)

func _on_setting_slider_changed(value: float, setting: String) -> void:
    if setting == "renderDistance" or setting == "fov":
        value = round(value)
    settings_state[setting] = value
    update_slider_label(setting, value)
    setting_changed.emit(setting, value)

func _on_setting_toggled(enabled: bool, setting: String) -> void:
    settings_state[setting] = enabled
    setting_changed.emit(setting, enabled)

func _on_playtest_case_pressed(case_id: String) -> void:
    set_playtest_route(case_id)
    playtest_requested.emit(case_id)

func _on_playtest_cleanup_pressed() -> void:
    playtest_cleanup_requested.emit()

func _on_resume_pressed() -> void:
    set_game_menu_open(false)
    resume_requested.emit()

func _on_new_game_pressed() -> void:
    new_game_requested.emit()

func _on_menu_settings_pressed() -> void:
    set_game_menu_open(false)
    set_settings_open(true)

func _on_teleport_go_pressed() -> void:
    teleport_requested.emit(teleport_input.text if teleport_input else "")

func _on_teleport_submitted(value: String) -> void:
    teleport_requested.emit(value)

func hash_string(text: String) -> int:
    var h := 2166136261
    for i in range(text.length()):
        h = int((h ^ text.unicode_at(i)) * 16777619) & 0xffffffff
    return h
