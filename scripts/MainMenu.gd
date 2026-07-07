extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const SaveSystemScript := preload("res://scripts/SaveSystem.gd")
const HudStyleFactoryScript := preload("res://scripts/visual/HudStyleFactory.gd")
const GAME_THEME := preload("res://resources/ui/game_theme.tres")

var ui_layer: CanvasLayer
var continue_button: Button
var new_game_button: Button
var quit_button: Button
var status_label: Label
var loading_overlay: Control
var launching := false
var saved_seed := ""

func _ready() -> void:
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    build_menu()
    refresh_save_state()

func build_menu() -> void:
    ui_layer = CanvasLayer.new()
    ui_layer.name = "MainMenuLayer"
    add_child(ui_layer)

    var root := Control.new()
    root.name = "MainMenuRoot"
    root.set_anchors_preset(Control.PRESET_FULL_RECT)
    var theme := GAME_THEME.duplicate(true) as Theme
    HudStyleFactoryScript.configure_theme(theme)
    root.theme = theme
    ui_layer.add_child(root)

    var sky := ColorRect.new()
    sky.color = Color(0.55, 0.72, 0.76)
    sky.set_anchors_preset(Control.PRESET_FULL_RECT)
    root.add_child(sky)

    var distant_band := ColorRect.new()
    distant_band.color = Color(0.43, 0.56, 0.50)
    distant_band.anchor_left = 0.0
    distant_band.anchor_right = 1.0
    distant_band.anchor_top = 0.58
    distant_band.anchor_bottom = 1.0
    root.add_child(distant_band)

    var ground_band := ColorRect.new()
    ground_band.color = Color(0.26, 0.34, 0.30)
    ground_band.anchor_left = 0.0
    ground_band.anchor_right = 1.0
    ground_band.anchor_top = 0.72
    ground_band.anchor_bottom = 1.0
    root.add_child(ground_band)

    var shadow_band := ColorRect.new()
    shadow_band.color = Color(0.09, 0.12, 0.11, 0.54)
    shadow_band.anchor_left = 0.0
    shadow_band.anchor_right = 1.0
    shadow_band.anchor_top = 0.84
    shadow_band.anchor_bottom = 1.0
    root.add_child(shadow_band)

    var panel := PanelContainer.new()
    panel.theme_type_variation = &"DialoguePanel"
    panel.anchor_left = 0.08
    panel.anchor_right = 0.38
    panel.anchor_top = 0.18
    panel.anchor_bottom = 0.72
    panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    root.add_child(panel)

    var box := VBoxContainer.new()
    box.add_theme_constant_override("separation", 12)
    panel.add_child(box)

    var title := Label.new()
    title.text = "Voxel Biome World"
    title.theme_type_variation = &"ToastLabel"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
    box.add_child(title)

    status_label = Label.new()
    status_label.theme_type_variation = &"MutedLabel"
    status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    box.add_child(status_label)

    var spacer := Control.new()
    spacer.custom_minimum_size = Vector2(1, 10)
    box.add_child(spacer)

    new_game_button = Button.new()
    new_game_button.text = "New Game"
    new_game_button.custom_minimum_size = Vector2(320, 46)
    new_game_button.pressed.connect(Callable(self, "_on_new_game_pressed"))
    box.add_child(new_game_button)

    continue_button = Button.new()
    continue_button.text = "Continue"
    continue_button.custom_minimum_size = Vector2(320, 46)
    continue_button.pressed.connect(Callable(self, "_on_continue_pressed"))
    box.add_child(continue_button)

    quit_button = Button.new()
    quit_button.text = "Quit"
    quit_button.custom_minimum_size = Vector2(320, 46)
    quit_button.pressed.connect(Callable(self, "_on_quit_pressed"))
    box.add_child(quit_button)

    loading_overlay = Control.new()
    loading_overlay.visible = false
    loading_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
    root.add_child(loading_overlay)

    var loading_dim := ColorRect.new()
    loading_dim.color = Color(0.04, 0.05, 0.045, 0.72)
    loading_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
    loading_overlay.add_child(loading_dim)

    var loading_label := Label.new()
    loading_label.text = "Loading"
    loading_label.theme_type_variation = &"ToastLabel"
    loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    loading_label.set_anchors_preset(Control.PRESET_FULL_RECT)
    loading_overlay.add_child(loading_label)

func refresh_save_state() -> void:
    saved_seed = active_saved_seed()
    var has_save := saved_seed != ""
    continue_button.disabled = not has_save
    if has_save:
        status_label.text = "Saved world: %s" % saved_seed
    else:
        status_label.text = "No saved world"

func active_saved_seed() -> String:
    var save_system = SaveSystemScript.new(gameplay_save_path())
    var active_seed := save_system.active_seed("")
    if active_seed == "":
        return ""
    var snapshot: Dictionary = save_system.load(active_seed)
    if snapshot.is_empty():
        return ""
    return active_seed

func gameplay_save_path() -> String:
    var save_path_override := OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges()
    if save_path_override != "":
        return save_path_override
    if OS.get_environment("VOXEL_PLAYTEST") != "":
        return "user://voxel_biome_world_playtest_saves.json"
    return "user://voxel_biome_world_saves.json"

func _on_new_game_pressed() -> void:
    launch_game("new_game")

func _on_continue_pressed() -> void:
    if saved_seed == "":
        refresh_save_state()
        return
    launch_game("continue")

func _on_quit_pressed() -> void:
    get_tree().quit(0)

func launch_game(mode: String) -> void:
    if launching:
        return
    launching = true
    new_game_button.disabled = true
    continue_button.disabled = true
    quit_button.disabled = true
    status_label.text = "Loading"
    loading_overlay.visible = true
    call_deferred("_deferred_launch_game", mode)

func _deferred_launch_game(mode: String) -> void:
    await get_tree().process_frame
    var main := MAIN_SCENE.instantiate()
    if main == null:
        status_label.text = "Load failed"
        loading_overlay.visible = false
        launching = false
        refresh_save_state()
        return
    main.set("startup_mode", mode)
    add_child(main)
    if ui_layer != null:
        ui_layer.queue_free()
        ui_layer = null
