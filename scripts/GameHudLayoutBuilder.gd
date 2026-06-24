extends RefCounted
class_name GameHudLayoutBuilder

const GameHudPanelBuilderScript := preload("res://scripts/GameHudPanelBuilder.gd")
const MiniMapDisplayScript := preload("res://scripts/MiniMapDisplay.gd")
const GAME_BUILD_LABEL := "build 2026.06.22.8"

static func set_mouse_filter_recursive(node: Node, filter: int) -> void:
    if node == null:
        return
    if node is Control:
        (node as Control).mouse_filter = filter
    for child in node.get_children():
        set_mouse_filter_recursive(child, filter)

static func set_passive_hud_mouse_filters(hud) -> void:
    for control in [
        hud.location_panel,
        hud.version_label,
        hud.performance_label,
        hud.compass_label,
        hud.compass_waypoint_label,
        hud.map_panel,
        hud.vitals_panel,
        hud.reticle_root,
        hud.target_label,
        hud.objective_toast,
        hud.notification_label,
        hud.level_label,
        hud.xp_bar,
        hud.xp_recent_label,
        hud.active_label,
        hud.selected_item_label,
        hud.hotbar
    ]:
        set_mouse_filter_recursive(control, Control.MOUSE_FILTER_IGNORE)

static func build_ui(hud) -> void:
    var root := Control.new()
    root.name = "HudRoot"
    root.set_anchors_preset(Control.PRESET_FULL_RECT)
    root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    hud.add_child(root)
    hud.hud_root = root

    hud.location_panel = PanelContainer.new()
    hud.location_panel.position = Vector2(16, 14)
    hud.location_panel.custom_minimum_size = Vector2(236, 62)
    root.add_child(hud.location_panel)
    var location_margin := MarginContainer.new()
    location_margin.add_theme_constant_override("margin_left", 10)
    location_margin.add_theme_constant_override("margin_right", 10)
    location_margin.add_theme_constant_override("margin_top", 7)
    location_margin.add_theme_constant_override("margin_bottom", 7)
    hud.location_panel.add_child(location_margin)
    hud.status_label = Label.new()
    hud.status_label.add_theme_font_size_override("font_size", 16)
    location_margin.add_child(hud.status_label)

    hud.version_label = Label.new()
    hud.version_label.text = GAME_BUILD_LABEL
    hud.version_label.visible = false
    hud.version_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    hud.version_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    hud.version_label.anchor_left = 1.0
    hud.version_label.anchor_right = 1.0
    hud.version_label.offset_left = -220
    hud.version_label.offset_right = -18
    hud.version_label.offset_top = 6
    hud.version_label.offset_bottom = 28
    hud.version_label.add_theme_font_size_override("font_size", 11)
    hud.version_label.modulate = Color(0.88, 0.94, 0.92, 0.68)
    root.add_child(hud.version_label)

    hud.performance_label = Label.new()
    hud.performance_label.visible = false
    hud.performance_label.position = Vector2(18, 84)
    hud.performance_label.add_theme_font_size_override("font_size", 13)
    hud.performance_label.modulate = Color(0.84, 0.96, 0.86, 0.88)
    root.add_child(hud.performance_label)

    build_vitals_panel(hud, root)
    build_reticle(hud, root)

    hud.compass_label = Label.new()
    hud.compass_label.text = "N"
    hud.compass_label.visible = false
    hud.compass_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hud.compass_label.anchor_left = 0.5
    hud.compass_label.anchor_right = 0.5
    hud.compass_label.offset_left = -100
    hud.compass_label.offset_right = 100
    hud.compass_label.offset_top = 16
    hud.compass_label.offset_bottom = 44
    hud.compass_label.add_theme_font_size_override("font_size", 18)
    root.add_child(hud.compass_label)

    hud.compass_waypoint_label = Label.new()
    hud.compass_waypoint_label.visible = false
    hud.compass_waypoint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hud.compass_waypoint_label.anchor_left = 0.5
    hud.compass_waypoint_label.anchor_right = 0.5
    hud.compass_waypoint_label.offset_left = -260
    hud.compass_waypoint_label.offset_right = 260
    hud.compass_waypoint_label.offset_top = 42
    hud.compass_waypoint_label.offset_bottom = 66
    hud.compass_waypoint_label.add_theme_font_size_override("font_size", 12)
    root.add_child(hud.compass_waypoint_label)

    hud.map_panel = PanelContainer.new()
    hud.map_panel.visible = false
    hud.map_panel.anchor_left = 1.0
    hud.map_panel.anchor_right = 1.0
    hud.map_panel.offset_left = -172
    hud.map_panel.offset_right = -24
    hud.map_panel.offset_top = 22
    hud.map_panel.offset_bottom = 170
    root.add_child(hud.map_panel)
    var map_box := VBoxContainer.new()
    hud.map_panel.add_child(map_box)
    hud.mini_map = MiniMapDisplayScript.new()
    hud.mini_map.custom_minimum_size = Vector2(132, 116)
    map_box.add_child(hud.mini_map)
    hud.map_info_label = Label.new()
    hud.map_info_label.text = "Nearby"
    hud.map_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    map_box.add_child(hud.map_info_label)

    hud.objective_panel = PanelContainer.new()
    hud.objective_panel.visible = false
    hud.objective_panel.anchor_left = 1.0
    hud.objective_panel.anchor_right = 1.0
    hud.objective_panel.offset_left = -344
    hud.objective_panel.offset_right = -22
    hud.objective_panel.offset_top = 190
    hud.objective_panel.offset_bottom = 430
    root.add_child(hud.objective_panel)
    var objective_box := VBoxContainer.new()
    objective_box.add_theme_constant_override("separation", 8)
    hud.objective_panel.add_child(objective_box)
    var objective_title := Label.new()
    objective_title.text = "Objectives"
    objective_title.add_theme_font_size_override("font_size", 20)
    objective_box.add_child(objective_title)
    hud.objective_scroll = ScrollContainer.new()
    hud.objective_scroll.clip_contents = true
    hud.objective_scroll.custom_minimum_size = Vector2(296, 182)
    hud.objective_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    objective_box.add_child(hud.objective_scroll)
    hud.objective_list = VBoxContainer.new()
    hud.objective_list.custom_minimum_size = Vector2(282, 0)
    hud.objective_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hud.objective_list.add_theme_constant_override("separation", 5)
    hud.objective_scroll.add_child(hud.objective_list)

    hud.contract_panel = PanelContainer.new()
    hud.contract_panel.visible = false
    hud.contract_panel.anchor_left = 1.0
    hud.contract_panel.anchor_right = 1.0
    hud.contract_panel.offset_left = -390
    hud.contract_panel.offset_right = -22
    hud.contract_panel.offset_top = 188
    hud.contract_panel.offset_bottom = 560
    root.add_child(hud.contract_panel)
    var contract_box := VBoxContainer.new()
    contract_box.add_theme_constant_override("separation", 6)
    hud.contract_panel.add_child(contract_box)
    var contract_header := HBoxContainer.new()
    contract_box.add_child(contract_header)
    var contract_title := Label.new()
    contract_title.text = "Contracts"
    contract_title.add_theme_font_size_override("font_size", 20)
    contract_header.add_child(contract_title)
    hud.contract_status = Label.new()
    hud.contract_status.text = "Locked"
    hud.contract_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    hud.contract_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    contract_header.add_child(hud.contract_status)
    hud.contract_scroll = ScrollContainer.new()
    hud.contract_scroll.clip_contents = true
    hud.contract_scroll.custom_minimum_size = Vector2(340, 282)
    hud.contract_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    contract_box.add_child(hud.contract_scroll)
    hud.contract_list = VBoxContainer.new()
    hud.contract_list.custom_minimum_size = Vector2(320, 0)
    hud.contract_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hud.contract_list.add_theme_constant_override("separation", 5)
    hud.contract_scroll.add_child(hud.contract_list)
    hud.contract_recent = Label.new()
    hud.contract_recent.text = "Find a town to unlock contracts"
    hud.contract_recent.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    hud.contract_recent.custom_minimum_size = Vector2(340, 36)
    hud.contract_recent.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    contract_box.add_child(hud.contract_recent)

    hud.story_panel = PanelContainer.new()
    hud.story_panel.visible = false
    hud.story_panel.focus_mode = Control.FOCUS_ALL
    hud.story_panel.anchor_left = 1.0
    hud.story_panel.anchor_right = 1.0
    hud.story_panel.offset_left = -430
    hud.story_panel.offset_right = -22
    hud.story_panel.offset_top = 188
    hud.story_panel.offset_bottom = 560
    root.add_child(hud.story_panel)
    var story_box := VBoxContainer.new()
    story_box.add_theme_constant_override("separation", 6)
    hud.story_panel.add_child(story_box)
    var story_title := Label.new()
    story_title.text = "Story"
    story_title.add_theme_font_size_override("font_size", 20)
    story_box.add_child(story_title)
    hud.story_status_label = Label.new()
    hud.story_status_label.text = "No active investigation"
    hud.story_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    story_box.add_child(hud.story_status_label)
    var story_scroll := ScrollContainer.new()
    story_scroll.custom_minimum_size = Vector2(380, 288)
    story_box.add_child(story_scroll)
    hud.story_list = VBoxContainer.new()
    hud.story_list.add_theme_constant_override("separation", 5)
    story_scroll.add_child(hud.story_list)

    build_victory_panel(hud, root)
    build_dialogue_panel(hud, root)
    build_progress_and_inventory(hud, root)
    build_utility_panel(hud, root)
    build_teleport_panel(hud, root)
    GameHudPanelBuilderScript.build_game_menu_panel(hud, root)
    GameHudPanelBuilderScript.build_settings_panel(hud, root)
    GameHudPanelBuilderScript.build_playtest_panel(hud, root)
    GameHudPanelBuilderScript.build_sleep_fade_overlay(hud, root)
    set_passive_hud_mouse_filters(hud)

static func build_victory_panel(hud, root: Control) -> void:
    hud.victory_panel = PanelContainer.new()
    hud.victory_panel.visible = false
    hud.victory_panel.anchor_left = 0.5
    hud.victory_panel.anchor_right = 0.5
    hud.victory_panel.anchor_top = 0.5
    hud.victory_panel.anchor_bottom = 0.5
    hud.victory_panel.offset_left = -285
    hud.victory_panel.offset_right = 285
    hud.victory_panel.offset_top = -238
    hud.victory_panel.offset_bottom = 238
    root.add_child(hud.victory_panel)
    var victory_box := VBoxContainer.new()
    victory_box.add_theme_constant_override("separation", 10)
    hud.victory_panel.add_child(victory_box)
    var victory_title := Label.new()
    victory_title.text = "Sanctuary Established"
    victory_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    victory_title.add_theme_font_size_override("font_size", 28)
    victory_box.add_child(victory_title)
    var victory_subtitle := Label.new()
    victory_subtitle.text = "Night hostiles repelled"
    victory_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    victory_subtitle.add_theme_font_size_override("font_size", 16)
    victory_box.add_child(victory_subtitle)
    hud.victory_stats_list = GridContainer.new()
    hud.victory_stats_list.columns = 2
    hud.victory_stats_list.add_theme_constant_override("h_separation", 24)
    hud.victory_stats_list.add_theme_constant_override("v_separation", 5)
    victory_box.add_child(hud.victory_stats_list)

static func build_vitals_panel(hud, root: Control) -> void:
    hud.vitals_panel = PanelContainer.new()
    hud.vitals_panel.position = Vector2(16, 92)
    hud.vitals_panel.custom_minimum_size = Vector2(226, 142)
    root.add_child(hud.vitals_panel)
    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 10)
    margin.add_theme_constant_override("margin_right", 10)
    margin.add_theme_constant_override("margin_top", 8)
    margin.add_theme_constant_override("margin_bottom", 8)
    hud.vitals_panel.add_child(margin)
    var vitals := VBoxContainer.new()
    vitals.add_theme_constant_override("separation", 6)
    margin.add_child(vitals)

    var health := add_vital_row(hud, vitals, "HP", Color(0.82, 0.24, 0.22), "HealthBar")
    hud.health_label = health["label"]
    hud.health_bar = health["bar"]
    var stamina := add_vital_row(hud, vitals, "ST", Color(0.96, 0.76, 0.30), "StaminaBar")
    hud.stamina_label = stamina["label"]
    hud.stamina_bar = stamina["bar"]
    var hunger := add_vital_row(hud, vitals, "HN", Color(0.38, 0.72, 0.44), "HungerBar")
    hud.hunger_label = hunger["label"]
    hud.hunger_bar = hunger["bar"]

    var status_row := HBoxContainer.new()
    status_row.add_theme_constant_override("separation", 7)
    vitals.add_child(status_row)
    var shield := Label.new()
    shield.text = "SHD"
    shield.custom_minimum_size = Vector2(34, 20)
    shield.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    shield.add_theme_font_size_override("font_size", 14)
    status_row.add_child(shield)
    hud.armor_label = hud.make_vital_label("0")
    hud.armor_label.custom_minimum_size = Vector2(46, 20)
    status_row.add_child(hud.armor_label)
    hud.danger_label = hud.make_vital_label("SAFE")
    hud.danger_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hud.danger_label.custom_minimum_size = Vector2(78, 22)
    status_row.add_child(hud.danger_label)

static func add_vital_row(hud, parent: VBoxContainer, icon_text: String, color: Color, bar_variation: String) -> Dictionary:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 7)
    parent.add_child(row)
    var icon := Label.new()
    icon.text = icon_text
    icon.custom_minimum_size = Vector2(34, 22)
    icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    icon.add_theme_font_size_override("font_size", 14)
    icon.modulate = color.lightened(0.12)
    row.add_child(icon)
    var bar := ProgressBar.new()
    bar.min_value = 0.0
    bar.max_value = 100.0
    bar.value = 100.0
    bar.show_percentage = false
    bar.custom_minimum_size = Vector2(104, 12)
    bar.theme_type_variation = StringName(bar_variation)
    row.add_child(bar)
    var label: Label = hud.make_vital_label("100")
    label.custom_minimum_size = Vector2(42, 22)
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    row.add_child(label)
    return { "label": label, "bar": bar }

static func build_reticle(hud, root: Control) -> void:
    hud.reticle_root = Control.new()
    hud.reticle_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    hud.reticle_root.anchor_left = 0.5
    hud.reticle_root.anchor_right = 0.5
    hud.reticle_root.anchor_top = 0.5
    hud.reticle_root.anchor_bottom = 0.5
    hud.reticle_root.offset_left = -12
    hud.reticle_root.offset_right = 12
    hud.reticle_root.offset_top = -12
    hud.reticle_root.offset_bottom = 12
    root.add_child(hud.reticle_root)
    var horizontal := ColorRect.new()
    horizontal.color = Color(0.96, 0.92, 0.74, 0.42)
    horizontal.position = Vector2(5, 11)
    horizontal.size = Vector2(14, 2)
    hud.reticle_root.add_child(horizontal)
    var vertical := ColorRect.new()
    vertical.color = Color(0.96, 0.92, 0.74, 0.42)
    vertical.position = Vector2(11, 5)
    vertical.size = Vector2(2, 14)
    hud.reticle_root.add_child(vertical)

static func build_dialogue_panel(hud, root: Control) -> void:
    hud.target_label = Label.new()
    hud.target_label.visible = false
    hud.target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hud.target_label.anchor_left = 0.5
    hud.target_label.anchor_right = 0.5
    hud.target_label.anchor_top = 0.5
    hud.target_label.anchor_bottom = 0.5
    hud.target_label.offset_left = -260
    hud.target_label.offset_right = 260
    hud.target_label.offset_top = 72
    hud.target_label.offset_bottom = 104
    hud.target_label.add_theme_font_size_override("font_size", 18)
    root.add_child(hud.target_label)

    hud.objective_toast = Label.new()
    hud.objective_toast.visible = false
    hud.objective_toast.modulate.a = 0.0
    hud.objective_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hud.objective_toast.anchor_left = 0.5
    hud.objective_toast.anchor_right = 0.5
    hud.objective_toast.anchor_top = 0.32
    hud.objective_toast.anchor_bottom = 0.32
    hud.objective_toast.offset_left = -310
    hud.objective_toast.offset_right = 310
    hud.objective_toast.offset_top = -24
    hud.objective_toast.offset_bottom = 28
    hud.objective_toast.add_theme_font_size_override("font_size", 24)
    root.add_child(hud.objective_toast)

    hud.notification_label = Label.new()
    hud.notification_label.visible = false
    hud.notification_label.modulate.a = 0.0
    hud.notification_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hud.notification_label.anchor_left = 0.5
    hud.notification_label.anchor_right = 0.5
    hud.notification_label.anchor_top = 1.0
    hud.notification_label.anchor_bottom = 1.0
    hud.notification_label.offset_left = -300
    hud.notification_label.offset_right = 300
    hud.notification_label.offset_top = -164
    hud.notification_label.offset_bottom = -136
    hud.notification_label.add_theme_font_size_override("font_size", 18)
    root.add_child(hud.notification_label)

    hud.dialogue_panel = PanelContainer.new()
    hud.dialogue_panel.visible = false
    hud.dialogue_panel.focus_mode = Control.FOCUS_ALL
    hud.dialogue_panel.anchor_left = 0.5
    hud.dialogue_panel.anchor_right = 0.5
    hud.dialogue_panel.anchor_top = 1.0
    hud.dialogue_panel.anchor_bottom = 1.0
    hud.dialogue_panel.offset_left = -340
    hud.dialogue_panel.offset_right = 340
    hud.dialogue_panel.offset_top = -330
    hud.dialogue_panel.offset_bottom = -104
    hud.dialogue_panel.mouse_filter = Control.MOUSE_FILTER_STOP
    root.add_child(hud.dialogue_panel)
    var dialogue_margin := MarginContainer.new()
    dialogue_margin.add_theme_constant_override("margin_left", 16)
    dialogue_margin.add_theme_constant_override("margin_right", 16)
    dialogue_margin.add_theme_constant_override("margin_top", 12)
    dialogue_margin.add_theme_constant_override("margin_bottom", 12)
    hud.dialogue_panel.add_child(dialogue_margin)
    var dialogue_box := VBoxContainer.new()
    dialogue_box.add_theme_constant_override("separation", 8)
    dialogue_margin.add_child(dialogue_box)
    var dialogue_header := HBoxContainer.new()
    dialogue_header.add_theme_constant_override("separation", 10)
    dialogue_box.add_child(dialogue_header)
    hud.dialogue_speaker_label = Label.new()
    hud.dialogue_speaker_label.text = "Villager"
    hud.dialogue_speaker_label.add_theme_font_size_override("font_size", 20)
    dialogue_header.add_child(hud.dialogue_speaker_label)
    hud.dialogue_role_label = Label.new()
    hud.dialogue_role_label.text = "NPC"
    hud.dialogue_role_label.modulate = Color(0.82, 0.88, 0.82)
    hud.dialogue_role_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    dialogue_header.add_child(hud.dialogue_role_label)
    var dialogue_scroll := ScrollContainer.new()
    dialogue_scroll.custom_minimum_size = Vector2(624, 92)
    dialogue_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    dialogue_box.add_child(dialogue_scroll)
    hud.dialogue_body_label = Label.new()
    hud.dialogue_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    hud.dialogue_body_label.custom_minimum_size = Vector2(600, 0)
    hud.dialogue_body_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hud.dialogue_body_label.add_theme_font_size_override("font_size", 17)
    dialogue_scroll.add_child(hud.dialogue_body_label)
    hud.dialogue_reply_label = Label.new()
    hud.dialogue_reply_label.text = "Reply options coming soon"
    hud.dialogue_reply_label.modulate = Color(0.70, 0.76, 0.72, 0.72)
    dialogue_box.add_child(hud.dialogue_reply_label)
    var dialogue_actions := HBoxContainer.new()
    dialogue_actions.alignment = BoxContainer.ALIGNMENT_END
    dialogue_box.add_child(dialogue_actions)
    var dialogue_close := Button.new()
    dialogue_close.text = "Close"
    dialogue_close.pressed.connect(Callable(hud, "_on_dialogue_close_pressed"))
    dialogue_actions.add_child(dialogue_close)

static func build_progress_and_inventory(hud, root: Control) -> void:
    hud.level_label = Label.new()
    hud.level_label.text = "Lvl 1 | XP 0/80"
    hud.level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
    hud.level_label.anchor_left = 0.0
    hud.level_label.anchor_right = 0.0
    hud.level_label.anchor_top = 1.0
    hud.level_label.anchor_bottom = 1.0
    hud.level_label.offset_left = 18
    hud.level_label.offset_right = 210
    hud.level_label.offset_top = -98
    hud.level_label.offset_bottom = -76
    hud.level_label.add_theme_font_size_override("font_size", 15)
    root.add_child(hud.level_label)

    hud.xp_bar = ProgressBar.new()
    hud.xp_bar.min_value = 0.0
    hud.xp_bar.max_value = 80.0
    hud.xp_bar.value = 0.0
    hud.xp_bar.show_percentage = false
    hud.xp_bar.anchor_left = 0.0
    hud.xp_bar.anchor_right = 0.0
    hud.xp_bar.anchor_top = 1.0
    hud.xp_bar.anchor_bottom = 1.0
    hud.xp_bar.offset_left = 18
    hud.xp_bar.offset_right = 210
    hud.xp_bar.offset_top = -74
    hud.xp_bar.offset_bottom = -62
    root.add_child(hud.xp_bar)

    hud.xp_recent_label = Label.new()
    hud.xp_recent_label.text = "No XP earned yet"
    hud.xp_recent_label.visible = false
    hud.xp_recent_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hud.xp_recent_label.anchor_left = 0.5
    hud.xp_recent_label.anchor_right = 0.5
    hud.xp_recent_label.anchor_top = 1.0
    hud.xp_recent_label.anchor_bottom = 1.0
    hud.xp_recent_label.offset_left = -260
    hud.xp_recent_label.offset_right = 260
    hud.xp_recent_label.offset_top = -116
    hud.xp_recent_label.offset_bottom = -96
    root.add_child(hud.xp_recent_label)

    hud.active_label = Label.new()
    hud.active_label.visible = false
    root.add_child(hud.active_label)

    hud.selected_item_label = Label.new()
    hud.selected_item_label.visible = false
    hud.selected_item_label.modulate.a = 0.0
    hud.selected_item_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hud.selected_item_label.anchor_left = 0.5
    hud.selected_item_label.anchor_right = 0.5
    hud.selected_item_label.anchor_top = 1.0
    hud.selected_item_label.anchor_bottom = 1.0
    hud.selected_item_label.offset_left = -240
    hud.selected_item_label.offset_right = 240
    hud.selected_item_label.offset_top = -112
    hud.selected_item_label.offset_bottom = -88
    hud.selected_item_label.add_theme_font_size_override("font_size", 17)
    root.add_child(hud.selected_item_label)

    hud.hotbar = HBoxContainer.new()
    hud.hotbar.anchor_left = 0.5
    hud.hotbar.anchor_right = 0.5
    hud.hotbar.anchor_top = 1.0
    hud.hotbar.anchor_bottom = 1.0
    hud.hotbar.offset_left = -372
    hud.hotbar.offset_right = 372
    hud.hotbar.offset_top = -78
    hud.hotbar.offset_bottom = -16
    hud.hotbar.alignment = BoxContainer.ALIGNMENT_CENTER
    root.add_child(hud.hotbar)

    hud.inventory_panel = PanelContainer.new()
    hud.inventory_panel.visible = false
    hud.inventory_panel.anchor_left = 0.5
    hud.inventory_panel.anchor_right = 0.5
    hud.inventory_panel.anchor_top = 0.5
    hud.inventory_panel.anchor_bottom = 0.5
    hud.inventory_panel.offset_left = -470
    hud.inventory_panel.offset_right = 470
    hud.inventory_panel.offset_top = -292
    hud.inventory_panel.offset_bottom = 292
    root.add_child(hud.inventory_panel)
    var inventory_layout := HBoxContainer.new()
    inventory_layout.add_theme_constant_override("separation", 16)
    hud.inventory_panel.add_child(inventory_layout)
    var left_column := VBoxContainer.new()
    left_column.custom_minimum_size = Vector2(500, 540)
    inventory_layout.add_child(left_column)
    var inventory_title := Label.new()
    inventory_title.text = "Inventory"
    inventory_title.add_theme_font_size_override("font_size", 22)
    left_column.add_child(inventory_title)
    var equipment_row := HBoxContainer.new()
    equipment_row.add_theme_constant_override("separation", 8)
    left_column.add_child(equipment_row)
    hud.armor_slot_button = hud.make_equipment_button("body", "Armor", "A")
    hud.accessory_slot_button = hud.make_equipment_button("accessory", "Charm", "C")
    equipment_row.add_child(hud.armor_slot_button)
    equipment_row.add_child(hud.accessory_slot_button)
    hud.equipment_readout = Label.new()
    hud.equipment_readout.text = "Equipment: none"
    hud.equipment_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    left_column.add_child(hud.equipment_readout)
    hud.inventory_grid = GridContainer.new()
    hud.inventory_grid.columns = 4
    hud.inventory_grid.add_theme_constant_override("h_separation", 8)
    hud.inventory_grid.add_theme_constant_override("v_separation", 8)
    left_column.add_child(hud.inventory_grid)

    var right_column := VBoxContainer.new()
    right_column.custom_minimum_size = Vector2(380, 540)
    inventory_layout.add_child(right_column)
    var crafting_title := Label.new()
    crafting_title.text = "Crafting"
    crafting_title.add_theme_font_size_override("font_size", 22)
    right_column.add_child(crafting_title)
    hud.crafting_status = Label.new()
    right_column.add_child(hud.crafting_status)
    var scroll := ScrollContainer.new()
    scroll.custom_minimum_size = Vector2(360, 490)
    right_column.add_child(scroll)
    hud.crafting_list = VBoxContainer.new()
    hud.crafting_list.add_theme_constant_override("separation", 6)
    scroll.add_child(hud.crafting_list)

static func build_utility_panel(hud, root: Control) -> void:
    hud.utility_panel = PanelContainer.new()
    hud.utility_panel.visible = false
    hud.utility_panel.anchor_left = 1.0
    hud.utility_panel.anchor_right = 1.0
    hud.utility_panel.anchor_top = 0.5
    hud.utility_panel.anchor_bottom = 0.5
    hud.utility_panel.offset_left = -360
    hud.utility_panel.offset_right = -24
    hud.utility_panel.offset_top = -164
    hud.utility_panel.offset_bottom = 164
    root.add_child(hud.utility_panel)
    var utility_box := VBoxContainer.new()
    utility_box.add_theme_constant_override("separation", 8)
    hud.utility_panel.add_child(utility_box)
    hud.utility_title = Label.new()
    hud.utility_title.text = "Utility"
    hud.utility_title.add_theme_font_size_override("font_size", 22)
    utility_box.add_child(hud.utility_title)
    hud.utility_status = Label.new()
    hud.utility_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    utility_box.add_child(hud.utility_status)
    hud.utility_progress = Label.new()
    hud.utility_progress.text = ""
    utility_box.add_child(hud.utility_progress)
    hud.utility_grid = GridContainer.new()
    hud.utility_grid.columns = 4
    hud.utility_grid.add_theme_constant_override("h_separation", 6)
    hud.utility_grid.add_theme_constant_override("v_separation", 6)
    utility_box.add_child(hud.utility_grid)
    hud.utility_actions = HBoxContainer.new()
    hud.utility_actions.add_theme_constant_override("separation", 8)
    utility_box.add_child(hud.utility_actions)
    var close_button := Button.new()
    close_button.text = "Close"
    close_button.pressed.connect(Callable(hud, "_on_utility_action_pressed").bind("close", null))
    utility_box.add_child(close_button)

static func build_teleport_panel(hud, root: Control) -> void:
    hud.teleport_panel = PanelContainer.new()
    hud.teleport_panel.visible = false
    hud.teleport_panel.anchor_left = 0.5
    hud.teleport_panel.anchor_right = 0.5
    hud.teleport_panel.anchor_top = 0.5
    hud.teleport_panel.anchor_bottom = 0.5
    hud.teleport_panel.offset_left = -210
    hud.teleport_panel.offset_right = 210
    hud.teleport_panel.offset_top = -86
    hud.teleport_panel.offset_bottom = 86
    root.add_child(hud.teleport_panel)
    var teleport_box := VBoxContainer.new()
    teleport_box.add_theme_constant_override("separation", 8)
    hud.teleport_panel.add_child(teleport_box)
    var teleport_title := Label.new()
    teleport_title.text = "Teleport"
    teleport_title.add_theme_font_size_override("font_size", 22)
    teleport_box.add_child(teleport_title)
    hud.teleport_input = LineEdit.new()
    hud.teleport_input.placeholder_text = "x z or x y z"
    hud.teleport_input.text_submitted.connect(Callable(hud, "_on_teleport_submitted"))
    teleport_box.add_child(hud.teleport_input)
    hud.teleport_status = Label.new()
    hud.teleport_status.text = "Enter coordinates"
    hud.teleport_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    teleport_box.add_child(hud.teleport_status)
    var teleport_actions := HBoxContainer.new()
    teleport_actions.add_theme_constant_override("separation", 8)
    teleport_box.add_child(teleport_actions)
    var teleport_button := Button.new()
    teleport_button.text = "Go"
    teleport_button.pressed.connect(Callable(hud, "_on_teleport_go_pressed"))
    teleport_actions.add_child(teleport_button)
    var teleport_close := Button.new()
    teleport_close.text = "Close"
    teleport_close.pressed.connect(Callable(hud, "set_teleport_open").bind(false))
    teleport_actions.add_child(teleport_close)
