extends RefCounted
class_name GameHudPanelBuilder

static func build_game_menu_panel(hud, root: Control) -> void:
    hud.game_menu_panel = PanelContainer.new()
    hud.game_menu_panel.visible = false
    hud.game_menu_panel.anchor_left = 0.5
    hud.game_menu_panel.anchor_right = 0.5
    hud.game_menu_panel.anchor_top = 0.5
    hud.game_menu_panel.anchor_bottom = 0.5
    hud.game_menu_panel.offset_left = -190
    hud.game_menu_panel.offset_right = 190
    hud.game_menu_panel.offset_top = -175
    hud.game_menu_panel.offset_bottom = 175
    root.add_child(hud.game_menu_panel)

    var box := VBoxContainer.new()
    box.add_theme_constant_override("separation", 10)
    hud.game_menu_panel.add_child(box)
    var title := Label.new()
    title.text = "Game Menu"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 24)
    box.add_child(title)

    var resume := Button.new()
    resume.text = "Resume"
    resume.custom_minimum_size = Vector2(320, 42)
    resume.pressed.connect(Callable(hud, "_on_resume_pressed"))
    box.add_child(resume)
    var new_game := Button.new()
    new_game.text = "New Game"
    new_game.custom_minimum_size = Vector2(320, 42)
    new_game.pressed.connect(Callable(hud, "_on_new_game_pressed"))
    box.add_child(new_game)
    var settings := Button.new()
    settings.text = "Settings"
    settings.custom_minimum_size = Vector2(320, 42)
    settings.pressed.connect(Callable(hud, "_on_menu_settings_pressed"))
    box.add_child(settings)
    var quit := Button.new()
    quit.text = "Quit"
    quit.custom_minimum_size = Vector2(320, 42)
    quit.pressed.connect(Callable(hud, "_on_quit_pressed"))
    box.add_child(quit)
    var close := Button.new()
    close.text = "Close"
    close.custom_minimum_size = Vector2(320, 42)
    close.pressed.connect(Callable(hud, "_on_resume_pressed"))
    box.add_child(close)

static func build_settings_panel(hud, root: Control) -> void:
    hud.settings_panel = PanelContainer.new()
    hud.settings_panel.visible = false
    hud.settings_panel.anchor_left = 0.5
    hud.settings_panel.anchor_right = 0.5
    hud.settings_panel.anchor_top = 0.5
    hud.settings_panel.anchor_bottom = 0.5
    hud.settings_panel.offset_left = -285
    hud.settings_panel.offset_right = 285
    hud.settings_panel.offset_top = -318
    hud.settings_panel.offset_bottom = 318
    root.add_child(hud.settings_panel)

    var box := VBoxContainer.new()
    box.add_theme_constant_override("separation", 8)
    hud.settings_panel.add_child(box)
    var title := Label.new()
    title.text = "Settings"
    title.add_theme_font_size_override("font_size", 22)
    box.add_child(title)

    var settings_scroll := ScrollContainer.new()
    settings_scroll.custom_minimum_size = Vector2(542, 498)
    box.add_child(settings_scroll)

    hud.settings_grid = GridContainer.new()
    hud.settings_grid.columns = 2
    hud.settings_grid.add_theme_constant_override("h_separation", 12)
    hud.settings_grid.add_theme_constant_override("v_separation", 8)
    settings_scroll.add_child(hud.settings_grid)

    add_settings_slider(hud, "mouseSensitivity", "Mouse", 0.25, 2.50, 0.05, 1.00)
    add_settings_slider(hud, "fov", "FOV", 58.0, 104.0, 1.0, 72.0)
    add_settings_slider(hud, "renderDistance", "Render", 2.0, 4.0, 1.0, 3.0)
    add_settings_slider(hud, "weatherParticles", "Weather", 0.0, 1.0, 0.05, 1.0)
    add_settings_slider(hud, "hudScale", "HUD Scale", 0.8, 1.4, 0.2, 1.0)
    add_settings_slider(hud, "lookSmoothing", "Look Smoothing", 0.0, 0.82, 0.02, 0.0)
    add_settings_checkbox(hud, "invertY", "Invert Y", false)
    add_settings_checkbox(hud, "shadows", "Shadows", true)
    add_settings_checkbox(hud, "headBob", "Head Bob", true)
    add_settings_checkbox(hud, "handSway", "Hand Sway", true)
    add_settings_checkbox(hud, "fullscreen", "Fullscreen", false)
    add_settings_slider(hud, "storyTextSpeed", "Story Text", 0.5, 2.0, 0.05, 2.0)
    add_settings_slider(hud, "storyJournalFontScale", "Journal Font", 0.85, 1.35, 0.05, 1.0)
    add_settings_checkbox(hud, "storySubtitles", "Story Subtitles", true)
    add_settings_checkbox(hud, "storyColorIndependentClues", "Clue Labels", true)
    add_settings_checkbox(hud, "storyReplayDiscoveredText", "Replay Text", true)
    add_settings_checkbox(hud, "storyControllerNavigation", "Controller Nav", true)

    var close := Button.new()
    close.text = "Close"
    close.pressed.connect(Callable(hud, "set_settings_open").bind(false))
    box.add_child(close)

static func add_settings_slider(hud, setting: String, label_text: String, min_value: float, max_value: float, step: float, value: float) -> void:
    var label := Label.new()
    label.text = "%s %.2f" % [label_text, value]
    hud.settings_grid.add_child(label)
    var slider := HSlider.new()
    slider.custom_minimum_size = Vector2(310, 24)
    slider.min_value = min_value
    slider.max_value = max_value
    slider.step = step
    slider.value = value
    slider.value_changed.connect(Callable(hud, "_on_setting_slider_changed").bind(setting))
    hud.settings_grid.add_child(slider)
    hud.setting_controls[setting] = { "control": slider, "label": label, "labelText": label_text }
    hud.settings_state[setting] = value

static func add_settings_checkbox(hud, setting: String, label_text: String, value: bool) -> void:
    var spacer := Label.new()
    spacer.text = ""
    hud.settings_grid.add_child(spacer)
    var checkbox := CheckBox.new()
    checkbox.text = label_text
    checkbox.button_pressed = value
    checkbox.toggled.connect(Callable(hud, "_on_setting_toggled").bind(setting))
    hud.settings_grid.add_child(checkbox)
    hud.setting_controls[setting] = { "control": checkbox, "labelText": label_text }
    hud.settings_state[setting] = value

static func build_playtest_panel(hud, root: Control) -> void:
    hud.playtest_panel = PanelContainer.new()
    hud.playtest_panel.visible = false
    hud.playtest_panel.anchor_left = 0.5
    hud.playtest_panel.anchor_right = 0.5
    hud.playtest_panel.anchor_top = 0.5
    hud.playtest_panel.anchor_bottom = 0.5
    hud.playtest_panel.offset_left = -300
    hud.playtest_panel.offset_right = 300
    hud.playtest_panel.offset_top = -250
    hud.playtest_panel.offset_bottom = 250
    root.add_child(hud.playtest_panel)

    var box := VBoxContainer.new()
    box.add_theme_constant_override("separation", 7)
    hud.playtest_panel.add_child(box)
    var title := Label.new()
    title.text = "Playtest"
    title.add_theme_font_size_override("font_size", 22)
    box.add_child(title)
    var subtitle := Label.new()
    subtitle.text = "Jump to curated QA setups"
    subtitle.modulate = Color(0.82, 0.86, 0.80)
    box.add_child(subtitle)

    hud.playtest_route_label = Label.new()
    hud.playtest_route_label.text = "Select a case"
    hud.playtest_route_label.modulate = Color(0.88, 0.94, 0.86)
    hud.playtest_route_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    box.add_child(hud.playtest_route_label)
    hud.playtest_list = VBoxContainer.new()
    hud.playtest_list.add_theme_constant_override("separation", 5)
    box.add_child(hud.playtest_list)
    hud.playtest_status = Label.new()
    hud.playtest_status.text = "No case loaded"
    hud.playtest_status.modulate = Color(0.78, 0.86, 0.80)
    hud.playtest_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    box.add_child(hud.playtest_status)

    var actions := HBoxContainer.new()
    actions.add_theme_constant_override("separation", 8)
    box.add_child(actions)
    var cleanup := Button.new()
    cleanup.text = "Clean Up"
    cleanup.pressed.connect(Callable(hud, "_on_playtest_cleanup_pressed"))
    actions.add_child(cleanup)
    var close := Button.new()
    close.text = "Close"
    close.pressed.connect(Callable(hud, "set_playtest_open").bind(false))
    actions.add_child(close)

static func build_sleep_fade_overlay(hud, root: Control) -> void:
    hud.sleep_fade_overlay = ColorRect.new()
    hud.sleep_fade_overlay.name = "SleepFadeOverlay"
    hud.sleep_fade_overlay.visible = false
    hud.sleep_fade_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
    hud.sleep_fade_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
    hud.sleep_fade_overlay.color = Color(0.0, 0.0, 0.0, 0.0)
    root.add_child(hud.sleep_fade_overlay)

static func build_loading_overlay(hud, root: Control) -> void:
    hud.loading_overlay = Control.new()
    hud.loading_overlay.name = "LoadingOverlay"
    hud.loading_overlay.visible = false
    hud.loading_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
    hud.loading_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
    root.add_child(hud.loading_overlay)

    var dim := ColorRect.new()
    dim.color = Color(0.02, 0.025, 0.022, 0.84)
    dim.set_anchors_preset(Control.PRESET_FULL_RECT)
    dim.mouse_filter = Control.MOUSE_FILTER_STOP
    hud.loading_overlay.add_child(dim)

    var label := Label.new()
    label.text = "Loading"
    label.theme_type_variation = &"ToastLabel"
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    label.set_anchors_preset(Control.PRESET_FULL_RECT)
    label.add_theme_font_size_override("font_size", 24)
    hud.loading_overlay.add_child(label)
    hud.loading_label = label
