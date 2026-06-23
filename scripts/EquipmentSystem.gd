extends RefCounted
class_name EquipmentSystem

signal changed

const EQUIPMENT_SLOTS := ["body", "accessory"]

var catalog := {}
var inventory
var slots := {
    "body": "",
    "accessory": ""
}
var last_message := ""

func _init(catalog_value := {}, inventory_system = null) -> void:
    catalog = catalog_value
    inventory = inventory_system

func snapshot() -> Dictionary:
    return {
        "body": slots.get("body", ""),
        "accessory": slots.get("accessory", "")
    }

func restore(snapshot_value = {}) -> void:
    var saved: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
    for slot in EQUIPMENT_SLOTS:
        var item_id := String(saved.get(slot, ""))
        slots[slot] = item_id if slot_for(item_id) == slot else ""
    last_message = "Equipment restored"
    changed.emit()

func reset() -> void:
    for slot in EQUIPMENT_SLOTS:
        slots[slot] = ""
    last_message = "Equipment cleared"
    changed.emit()

func slot_for(item_id: String) -> String:
    var spec: Dictionary = catalog.get(item_id, {})
    var equipment: Dictionary = spec.get("equipment", {})
    var slot := String(equipment.get("slot", ""))
    return slot if EQUIPMENT_SLOTS.has(slot) else ""

func is_equippable(item_id: String) -> bool:
    return slot_for(item_id) != ""

func equipped_item(slot := "body") -> String:
    return String(slots.get(slot, ""))

func equipped_spec(slot := "body") -> Dictionary:
    var item_id := equipped_item(slot)
    return catalog.get(item_id, {}) if item_id != "" else {}

func equipped_specs() -> Array:
    var result := []
    for slot in EQUIPMENT_SLOTS:
        var spec := equipped_spec(slot)
        if not spec.is_empty():
            result.append(spec)
    return result

func stacks() -> Array:
    var result := []
    for slot in EQUIPMENT_SLOTS:
        var item_id := equipped_item(slot)
        if item_id != "":
            result.append({ "item": item_id, "count": 1 })
    return result

func equip_active(slot_override := "") -> bool:
    if inventory == null:
        last_message = "No inventory"
        changed.emit()
        return false
    var active: Dictionary = inventory.active_stack()
    var item_id := String(active.get("item", ""))
    var item_slot := slot_for(item_id)
    var requested_slot := slot_override if EQUIPMENT_SLOTS.has(slot_override) else item_slot
    if item_id == "":
        return unequip_to_inventory(requested_slot if requested_slot != "" else "body")
    if item_slot == "" or requested_slot == "" or item_slot != requested_slot:
        last_message = "%s is not equipment" % String(catalog.get(item_id, {}).get("label", item_id))
        changed.emit()
        return false

    var previous := String(slots.get(item_slot, ""))
    slots[item_slot] = item_id
    active["item"] = previous
    active["count"] = 1 if previous != "" else 0
    inventory.notify()
    last_message = "Equipped: %s" % String(catalog.get(item_id, {}).get("label", item_id))
    changed.emit()
    return true

func unequip_to_inventory(slot := "body") -> bool:
    if inventory == null:
        return false
    var item_id := equipped_item(slot)
    if item_id == "":
        last_message = "No %s equipped" % ("armor" if slot == "body" else "accessory")
        changed.emit()
        return false
    if inventory.free_for(item_id) < 1:
        last_message = "Inventory full"
        changed.emit()
        return false
    slots[slot] = ""
    inventory.add_item(item_id, 1)
    last_message = "Unequipped: %s" % String(catalog.get(item_id, {}).get("label", item_id))
    changed.emit()
    return true

func toggle_slot(slot := "body") -> bool:
    if inventory == null:
        return false
    return equip_active(slot) if String(inventory.active_stack().get("item", "")) != "" else unequip_to_inventory(slot)

func protection(kind := "hostile") -> float:
    var total := 0.0
    for spec in equipped_specs():
        var equipment: Dictionary = spec.get("equipment", {})
        if kind == "hostile":
            total += float(equipment.get("combatProtection", 0.0))
        elif kind == "exposure":
            total += float(equipment.get("exposureProtection", 0.0))
        else:
            total += float(equipment.get("protection", 0.0))
    return clampf(total, 0.0, 0.82)

func damage_multiplier(kind := "hostile") -> float:
    return 1.0 - protection(kind)

func bonuses() -> Dictionary:
    var totals := { "health": 0.0, "stamina": 0.0, "hunger": 0.0 }
    for spec in equipped_specs():
        var equipment: Dictionary = spec.get("equipment", {})
        totals["health"] = float(totals["health"]) + float(equipment.get("healthBonus", 0.0))
        totals["stamina"] = float(totals["stamina"]) + float(equipment.get("staminaBonus", 0.0))
        totals["hunger"] = float(totals["hunger"]) + float(equipment.get("hungerBonus", 0.0))
    return totals

func map_range_bonus() -> int:
    var total := 0
    for spec in equipped_specs():
        var equipment: Dictionary = spec.get("equipment", {})
        total += int(equipment.get("mapRangeBonus", 0))
    return total

func state() -> Dictionary:
    return {
        "slots": snapshot(),
        "armor": roundi(protection("hostile") * 100.0),
        "exposure": roundi(protection("exposure") * 100.0),
        "bonuses": bonuses(),
        "mapRangeBonus": map_range_bonus(),
        "message": last_message
    }
