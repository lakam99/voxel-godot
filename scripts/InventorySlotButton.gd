extends Button
class_name InventorySlotButton

signal slot_dropped(from_index: int, to_index: int)

var slot_index := -1
var item_id := ""
var item_count := 0
var compact_slot := false

func configure(index: int, item: String, count: int, compact: bool) -> void:
    slot_index = index
    item_id = item
    item_count = count
    compact_slot = compact
    tooltip_text = "Drag to move" if item_id != "" and item_count > 0 else "Drop item here"

func _get_drag_data(_at_position: Vector2) -> Variant:
    if slot_index < 0 or item_id == "" or item_count <= 0:
        return null
    var preview := Button.new()
    preview.disabled = true
    preview.custom_minimum_size = custom_minimum_size
    preview.icon = icon
    preview.text = text
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
    slot_dropped.emit(int(data.get("from", -1)), slot_index)
