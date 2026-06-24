extends Button
class_name InventorySlotButton

signal slot_dropped(from_index: int, to_index: int)

var slot_index := -1
var item_id := ""
var item_count := 0
var compact_slot := false
var shortcut_label: Label
var count_label: Label
var icon_rect: TextureRect
var durability_strip: ProgressBar
var slot_icon_texture: Texture2D

func configure(index: int, item: String, count: int, compact: bool) -> void:
    slot_index = index
    item_id = item
    item_count = count
    compact_slot = compact
    tooltip_text = "Drag to move" if item_id != "" and item_count > 0 else "Drop item here"
    if not compact_slot:
        clear_compact_presentation()

func set_compact_presentation(shortcut: int, texture: Texture2D, count: int, durability := -1.0) -> void:
    ensure_compact_children()
    slot_icon_texture = texture
    text = ""
    icon = null
    shortcut_label.text = str(shortcut)
    shortcut_label.visible = true
    icon_rect.texture = texture
    icon_rect.visible = texture != null
    count_label.text = str(count) if texture != null and count > 1 else ""
    count_label.visible = count_label.text != ""
    durability_strip.visible = durability >= 0.0
    if durability_strip.visible:
        durability_strip.value = clampf(durability, 0.0, 1.0)

func clear_compact_presentation() -> void:
    slot_icon_texture = null
    for child in [shortcut_label, count_label, icon_rect, durability_strip]:
        if child != null:
            child.visible = false

func ensure_compact_children() -> void:
    if shortcut_label != null:
        return
    shortcut_label = Label.new()
    shortcut_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    shortcut_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
    shortcut_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
    shortcut_label.add_theme_font_size_override("font_size", 12)
    shortcut_label.anchor_left = 0.0
    shortcut_label.anchor_right = 1.0
    shortcut_label.anchor_top = 0.0
    shortcut_label.anchor_bottom = 0.0
    shortcut_label.offset_left = 6
    shortcut_label.offset_right = -6
    shortcut_label.offset_top = 3
    shortcut_label.offset_bottom = 20
    add_child(shortcut_label)

    icon_rect = TextureRect.new()
    icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    icon_rect.anchor_left = 0.5
    icon_rect.anchor_right = 0.5
    icon_rect.anchor_top = 0.5
    icon_rect.anchor_bottom = 0.5
    icon_rect.offset_left = -18
    icon_rect.offset_right = 18
    icon_rect.offset_top = -18
    icon_rect.offset_bottom = 18
    add_child(icon_rect)

    count_label = Label.new()
    count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
    count_label.add_theme_font_size_override("font_size", 13)
    count_label.anchor_left = 0.0
    count_label.anchor_right = 1.0
    count_label.anchor_top = 1.0
    count_label.anchor_bottom = 1.0
    count_label.offset_left = 6
    count_label.offset_right = -6
    count_label.offset_top = -24
    count_label.offset_bottom = -6
    add_child(count_label)

    durability_strip = ProgressBar.new()
    durability_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
    durability_strip.min_value = 0.0
    durability_strip.max_value = 1.0
    durability_strip.show_percentage = false
    durability_strip.anchor_left = 0.0
    durability_strip.anchor_right = 1.0
    durability_strip.anchor_top = 1.0
    durability_strip.anchor_bottom = 1.0
    durability_strip.offset_left = 6
    durability_strip.offset_right = -6
    durability_strip.offset_top = -6
    durability_strip.offset_bottom = -3
    add_child(durability_strip)

func _get_drag_data(_at_position: Vector2) -> Variant:
    if slot_index < 0 or item_id == "" or item_count <= 0:
        return null
    var preview := Button.new()
    preview.disabled = true
    preview.custom_minimum_size = custom_minimum_size
    preview.theme = theme
    preview.theme_type_variation = theme_type_variation
    preview.icon = slot_icon_texture if compact_slot else icon
    preview.text = str(item_count) if compact_slot and item_count > 1 else text
    preview.clip_text = true
    preview.modulate = Color(1.0, 1.0, 1.0, 0.82)
    preview.add_theme_constant_override("icon_max_width", 42)
    preview.add_theme_constant_override("h_separation", 7)
    set_drag_preview(preview)
    return {
        "kind": "inventory_slot",
        "from": slot_index,
        "item": item_id
    }

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
    if slot_index < 0 or not (data is Dictionary):
        return false
    if String(data.get("kind", "")) != "inventory_slot":
        return false
    var from_index := int(data.get("from", -1))
    return from_index >= 0 and from_index != slot_index

func _drop_data(_at_position: Vector2, data: Variant) -> void:
    if not _can_drop_data(_at_position, data):
        return
    call_deferred("_emit_slot_dropped", int(data.get("from", -1)), slot_index)

func _emit_slot_dropped(from_index: int, to_index: int) -> void:
    slot_dropped.emit(from_index, to_index)
