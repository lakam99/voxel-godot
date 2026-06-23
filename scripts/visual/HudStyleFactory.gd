extends RefCounted
class_name HudStyleFactory

const GAME_THEME := preload("res://resources/ui/game_theme.tres")

const INK := Color(0.93, 0.92, 0.84)
const MUTED := Color(0.68, 0.73, 0.66)
const GOLD := Color(0.96, 0.76, 0.36)
const GREEN := Color(0.42, 0.76, 0.52)
const BLUE := Color(0.38, 0.66, 0.78)
const RED := Color(0.78, 0.32, 0.28)
const PANEL := Color(0.11, 0.14, 0.13, 0.74)
const PANEL_DARK := Color(0.07, 0.09, 0.085, 0.88)
const PANEL_LIGHT := Color(0.23, 0.28, 0.25, 0.88)
const BORDER := Color(0.62, 0.55, 0.39, 0.88)
const BORDER_SOFT := Color(0.38, 0.44, 0.39, 0.78)

static func apply(hud) -> void:
    var theme := GAME_THEME.duplicate(true) as Theme
    configure_theme(theme)
    hud.ui_theme = theme
    if hud.hud_root:
        hud.hud_root.theme = theme
    apply_type_variations(hud)

static func configure_theme(theme: Theme) -> void:
    theme.default_font_size = 15
    theme.set_font_size("font_size", "Label", 15)
    theme.set_color("font_color", "Label", INK)
    theme.set_color("font_shadow_color", "Label", Color(0.0, 0.0, 0.0, 0.72))
    theme.set_constant("shadow_offset_x", "Label", 1)
    theme.set_constant("shadow_offset_y", "Label", 1)

    theme.set_stylebox("panel", "PanelContainer", panel_box(PANEL, BORDER_SOFT, 1, 4, Vector4(12, 12, 10, 10)))
    theme.set_stylebox("normal", "Button", button_box(PANEL_LIGHT, BORDER_SOFT, 1))
    theme.set_stylebox("hover", "Button", button_box(Color(0.29, 0.34, 0.29, 0.94), BORDER, 1))
    theme.set_stylebox("pressed", "Button", button_box(Color(0.15, 0.18, 0.16, 0.96), GOLD, 2))
    theme.set_stylebox("focus", "Button", focus_box())
    theme.set_stylebox("disabled", "Button", button_box(Color(0.12, 0.13, 0.12, 0.66), Color(0.28, 0.30, 0.28, 0.55), 1))
    theme.set_color("font_color", "Button", INK)
    theme.set_color("font_hover_color", "Button", Color(1.0, 0.95, 0.74))
    theme.set_color("font_pressed_color", "Button", GOLD)
    theme.set_color("font_disabled_color", "Button", Color(0.52, 0.56, 0.52, 0.78))
    theme.set_font_size("font_size", "Button", 15)
    theme.set_constant("h_separation", "Button", 7)
    theme.set_constant("icon_max_width", "Button", 42)

    theme.set_stylebox("background", "ProgressBar", panel_box(Color(0.10, 0.12, 0.11, 0.78), Color(0.30, 0.35, 0.31, 0.75), 1, 4, Vector4(0, 0, 0, 0)))
    theme.set_stylebox("fill", "ProgressBar", panel_box(Color(0.78, 0.83, 0.72, 0.95), Color(0.90, 0.82, 0.48, 0.9), 0, 4, Vector4(0, 0, 0, 0)))

    theme.set_stylebox("normal", "LineEdit", panel_box(Color(0.08, 0.10, 0.09, 0.92), BORDER_SOFT, 1, 3, Vector4(8, 8, 5, 5)))
    theme.set_stylebox("focus", "LineEdit", panel_box(Color(0.10, 0.12, 0.10, 0.96), GOLD, 2, 3, Vector4(8, 8, 5, 5)))
    theme.set_color("font_color", "LineEdit", INK)
    theme.set_color("font_placeholder_color", "LineEdit", Color(0.64, 0.68, 0.62, 0.72))
    theme.set_font_size("font_size", "LineEdit", 15)

    theme.set_stylebox("grabber_area", "HSlider", panel_box(Color(0.16, 0.18, 0.16, 0.82), BORDER_SOFT, 1, 3, Vector4(0, 0, 0, 0)))
    theme.set_stylebox("grabber_area_highlight", "HSlider", panel_box(Color(0.28, 0.30, 0.23, 0.92), GOLD, 1, 3, Vector4(0, 0, 0, 0)))
    theme.set_icon("grabber", "HSlider", null)
    theme.set_icon("grabber_highlight", "HSlider", null)

    theme.set_constant("separation", "VBoxContainer", 8)
    theme.set_constant("separation", "HBoxContainer", 8)
    theme.set_constant("h_separation", "GridContainer", 8)
    theme.set_constant("v_separation", "GridContainer", 8)

    theme.set_stylebox("panel", "TooltipPanel", panel_box(PANEL_DARK, GOLD, 1, 3, Vector4(8, 8, 5, 5)))
    theme.set_color("font_color", "TooltipLabel", INK)
    theme.set_font_size("font_size", "TooltipLabel", 13)

    add_button_variation(theme, "HotbarSlot", slot_box(false, true), slot_box(false, false), slot_box(false, true), INK)
    add_button_variation(theme, "HotbarSlotSelected", slot_box(true, true), slot_box(true, false), slot_box(true, true), GOLD)
    add_button_variation(theme, "InventorySlot", slot_box(false, false), slot_box(false, false), slot_box(false, true), INK)
    add_button_variation(theme, "InventorySlotSelected", slot_box(true, false), slot_box(true, false), slot_box(true, true), GOLD)
    add_panel_variation(theme, "DialoguePanel", panel_box(Color(0.09, 0.11, 0.10, 0.94), GOLD, 2, 4, Vector4(14, 14, 10, 10)))
    add_panel_variation(theme, "UtilityPanel", panel_box(Color(0.10, 0.13, 0.12, 0.90), BORDER, 1, 4, Vector4(12, 12, 10, 10)))
    add_label_variation(theme, "ToastLabel", 24, Color(1.0, 0.94, 0.70))
    add_label_variation(theme, "VitalLabel", 14, INK)
    add_label_variation(theme, "MutedLabel", 13, MUTED)
    add_label_variation(theme, "DebugLabel", 12, Color(0.77, 0.92, 0.77, 0.88))

static func apply_type_variations(hud) -> void:
    if hud.status_label:
        hud.status_label.theme_type_variation = &"MutedLabel"
    if hud.version_label:
        hud.version_label.theme_type_variation = &"DebugLabel"
    if hud.performance_label:
        hud.performance_label.theme_type_variation = &"DebugLabel"
    for label in [hud.health_label, hud.stamina_label, hud.hunger_label, hud.armor_label, hud.danger_label]:
        if label:
            label.theme_type_variation = &"VitalLabel"
    if hud.objective_toast:
        hud.objective_toast.theme_type_variation = &"ToastLabel"
    if hud.dialogue_panel:
        hud.dialogue_panel.theme_type_variation = &"DialoguePanel"
    if hud.utility_panel:
        hud.utility_panel.theme_type_variation = &"UtilityPanel"
    if hud.inventory_panel:
        hud.inventory_panel.theme_type_variation = &"UtilityPanel"
    if hud.game_menu_panel:
        hud.game_menu_panel.theme_type_variation = &"DialoguePanel"
    if hud.settings_panel:
        hud.settings_panel.theme_type_variation = &"DialoguePanel"
    if hud.playtest_panel:
        hud.playtest_panel.theme_type_variation = &"DialoguePanel"

static func add_button_variation(theme: Theme, variation: String, normal: StyleBox, pressed: StyleBox, hover: StyleBox, font_color: Color) -> void:
    theme.set_type_variation(variation, "Button")
    theme.set_stylebox("normal", variation, normal)
    theme.set_stylebox("hover", variation, hover)
    theme.set_stylebox("pressed", variation, pressed)
    theme.set_stylebox("focus", variation, focus_box())
    theme.set_stylebox("disabled", variation, normal)
    theme.set_color("font_color", variation, font_color)
    theme.set_color("font_hover_color", variation, Color(1.0, 0.95, 0.74))
    theme.set_color("font_pressed_color", variation, GOLD)
    theme.set_constant("icon_max_width", variation, 42)
    theme.set_constant("h_separation", variation, 7)

static func add_panel_variation(theme: Theme, variation: String, style: StyleBox) -> void:
    theme.set_type_variation(variation, "PanelContainer")
    theme.set_stylebox("panel", variation, style)

static func add_label_variation(theme: Theme, variation: String, size: int, color: Color) -> void:
    theme.set_type_variation(variation, "Label")
    theme.set_font_size("font_size", variation, size)
    theme.set_color("font_color", variation, color)
    theme.set_color("font_shadow_color", variation, Color(0.0, 0.0, 0.0, 0.74))
    theme.set_constant("shadow_offset_x", variation, 1)
    theme.set_constant("shadow_offset_y", variation, 1)

static func panel_box(bg: Color, border: Color, border_width: int, radius: int, margins: Vector4) -> StyleBoxFlat:
    var box := StyleBoxFlat.new()
    box.bg_color = bg
    box.border_color = border
    box.set_border_width_all(border_width)
    box.set_corner_radius_all(radius)
    box.set_content_margin(SIDE_LEFT, margins.x)
    box.set_content_margin(SIDE_RIGHT, margins.y)
    box.set_content_margin(SIDE_TOP, margins.z)
    box.set_content_margin(SIDE_BOTTOM, margins.w)
    box.shadow_color = Color(0.0, 0.0, 0.0, 0.32)
    box.shadow_size = 4
    box.shadow_offset = Vector2(1, 2)
    return box

static func button_box(bg: Color, border: Color, border_width: int) -> StyleBoxFlat:
    return panel_box(bg, border, border_width, 3, Vector4(8, 8, 5, 5))

static func slot_box(selected: bool, compact: bool) -> StyleBoxFlat:
    var bg := Color(0.10, 0.12, 0.11, 0.88) if compact else Color(0.09, 0.11, 0.10, 0.90)
    var border := GOLD if selected else Color(0.28, 0.34, 0.31, 0.90)
    var width := 3 if selected else 1
    var margins := Vector4(6, 6, 5, 5) if compact else Vector4(8, 8, 6, 6)
    var box := panel_box(bg, border, width, 3, margins)
    if selected:
        box.bg_color = Color(0.20, 0.18, 0.10, 0.94)
        box.shadow_color = Color(1.0, 0.72, 0.22, 0.24)
        box.shadow_size = 7
    return box

static func focus_box() -> StyleBoxFlat:
    var box := StyleBoxFlat.new()
    box.bg_color = Color(0.0, 0.0, 0.0, 0.0)
    box.border_color = Color(1.0, 0.88, 0.46, 0.75)
    box.set_border_width_all(1)
    box.set_corner_radius_all(3)
    return box
