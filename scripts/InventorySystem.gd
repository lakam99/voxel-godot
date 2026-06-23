extends RefCounted
class_name InventorySystem

signal changed

var catalog := {}
var base_size := 24
var size := 24
var max_size := 40
var hotbar_size := 8
var selected_slot := 0
var slots := []

func _init(catalog_value := {}, size_value := 24, max_size_value := 40, hotbar_size_value := 8) -> void:
    catalog = catalog_value
    base_size = size_value
    size = size_value
    max_size = max(max_size_value, size_value)
    hotbar_size = hotbar_size_value
    selected_slot = 0
    slots = []
    for i in range(size):
        slots.append({ "item": "", "count": 0 })

func active_stack() -> Dictionary:
    if selected_slot < 0 or selected_slot >= slots.size():
        return { "item": "", "count": 0 }
    return slots[selected_slot]

func filled_count() -> int:
    var total := 0
    for slot in slots:
        if String(slot.get("item", "")) != "" and int(slot.get("count", 0)) > 0:
            total += 1
    return total

func totals() -> Dictionary:
    var result := {}
    for slot in slots:
        var item := String(slot.get("item", ""))
        var count := int(slot.get("count", 0))
        if item == "" or count <= 0:
            continue
        result[item] = int(result.get(item, 0)) + count
    return result

func count(item_id: String) -> int:
    var total := 0
    for slot in slots:
        if String(slot.get("item", "")) == item_id:
            total += int(slot.get("count", 0))
    return total

func free_for(item_id: String) -> int:
    if not catalog.has(item_id):
        return 0
    var stack_max := int(catalog[item_id].get("stackMax", 1))
    var total := 0
    for slot in slots:
        var slot_item := String(slot.get("item", ""))
        if slot_item == "":
            total += stack_max
        elif slot_item == item_id:
            total += max(0, stack_max - int(slot.get("count", 0)))
    return total

func has_costs(costs: Dictionary) -> bool:
    for item_id in costs.keys():
        if count(String(item_id)) < int(costs[item_id]):
            return false
    return true

func consume_costs(costs: Dictionary) -> bool:
    if not has_costs(costs):
        return false
    for item_id_variant in costs.keys():
        var item_id := String(item_id_variant)
        var remaining := int(costs[item_id_variant])
        for slot in slots:
            if remaining <= 0:
                break
            if String(slot.get("item", "")) != item_id:
                continue
            var taken: int = min(int(slot.get("count", 0)), remaining)
            slot["count"] = int(slot.get("count", 0)) - taken
            remaining -= taken
            if int(slot.get("count", 0)) <= 0:
                slot["item"] = ""
                slot["count"] = 0
    notify()
    return true

func consume_active(amount := 1) -> bool:
    if selected_slot < 0 or selected_slot >= slots.size():
        return false
    var slot: Dictionary = slots[selected_slot]
    if String(slot.get("item", "")) == "" or int(slot.get("count", 0)) < amount:
        return false
    slot["count"] = int(slot.get("count", 0)) - amount
    if int(slot.get("count", 0)) <= 0:
        slot["item"] = ""
        slot["count"] = 0
    notify()
    return true

func add_item(item_id: String, amount := 1) -> int:
    return add_item_with_options(item_id, amount)

func add_item_away_from_empty_slot(item_id: String, amount := 1, avoided_index := -1) -> int:
    return add_item_with_options(item_id, amount, { "avoidEmptyIndex": avoided_index })

func add_item_with_options(item_id: String, amount := 1, options := {}) -> int:
    if not catalog.has(item_id) or amount <= 0:
        return 0
    var stack_max := int(catalog[item_id].get("stackMax", 1))
    var avoid_empty_index := int(options.get("avoidEmptyIndex", -1))
    var remaining := amount
    for slot in slots:
        if remaining <= 0:
            break
        if String(slot.get("item", "")) != item_id:
            continue
        if int(slot.get("count", 0)) >= stack_max:
            continue
        var add_count: int = min(remaining, stack_max - int(slot.get("count", 0)))
        slot["count"] = int(slot.get("count", 0)) + add_count
        remaining -= add_count
    for i in range(slots.size()):
        if remaining <= 0:
            break
        if i == avoid_empty_index:
            continue
        var slot: Dictionary = slots[i]
        if String(slot.get("item", "")) != "":
            continue
        var add_count: int = min(remaining, stack_max)
        slot["item"] = item_id
        slot["count"] = add_count
        remaining -= add_count
    if amount - remaining > 0:
        notify()
    return amount - remaining

func clear() -> void:
    slots = []
    for i in range(size):
        slots.append({ "item": "", "count": 0 })
    selected_slot = 0
    notify()

func set_size(next_size_value: int) -> bool:
    var next_size: int = clampi(next_size_value, base_size, max_size)
    if next_size == size:
        return false
    if next_size < size:
        for i in range(next_size, slots.size()):
            if String(slots[i].get("item", "")) != "" and int(slots[i].get("count", 0)) > 0:
                return false
        slots.resize(next_size)
    else:
        while slots.size() < next_size:
            slots.append({ "item": "", "count": 0 })
    size = next_size
    selected_slot = posmod(selected_slot, hotbar_size)
    notify()
    return true

func select(index: int) -> void:
    selected_slot = posmod(index, hotbar_size)
    notify()

func swap_with_active(index: int) -> void:
    if index < 0 or index >= slots.size():
        return
    var active: Dictionary = slots[selected_slot].duplicate()
    slots[selected_slot] = slots[index].duplicate()
    slots[index] = active
    notify()

func move_slot(from_index: int, to_index: int) -> bool:
    if from_index < 0 or from_index >= slots.size() or to_index < 0 or to_index >= slots.size():
        return false
    if from_index == to_index:
        return false
    var source: Dictionary = slots[from_index]
    var target: Dictionary = slots[to_index]
    var source_item := String(source.get("item", ""))
    var source_count := int(source.get("count", 0))
    if source_item == "" or source_count <= 0:
        return false
    var target_item := String(target.get("item", ""))
    var target_count := int(target.get("count", 0))
    if target_item == "":
        slots[to_index] = source.duplicate()
        slots[from_index] = { "item": "", "count": 0 }
        notify()
        return true
    if target_item == source_item and catalog.has(source_item):
        var stack_max := int(catalog[source_item].get("stackMax", 1))
        var free_space: int = max(0, stack_max - target_count)
        if free_space > 0:
            var moved: int = min(source_count, free_space)
            slots[to_index]["count"] = target_count + moved
            slots[from_index]["count"] = source_count - moved
            if int(slots[from_index].get("count", 0)) <= 0:
                slots[from_index] = { "item": "", "count": 0 }
            notify()
            return true
    slots[to_index] = source.duplicate()
    slots[from_index] = target.duplicate()
    notify()
    return true

func snapshot() -> Array:
    var result := []
    for slot in slots:
        result.append(slot.duplicate())
    return result

func restore(snapshot_value) -> void:
    var source_slots: Array = []
    if snapshot_value is Array:
        source_slots = snapshot_value
    elif snapshot_value is Dictionary:
        source_slots = snapshot_value.get("slots", [])
        size = clampi(int(snapshot_value.get("size", base_size)), base_size, max_size)
        selected_slot = posmod(int(snapshot_value.get("selectedSlot", 0)), hotbar_size)
    slots = []
    for i in range(size):
        var source := {}
        if i < source_slots.size() and source_slots[i] is Dictionary:
            source = source_slots[i]
        var item_id := String(source.get("item", ""))
        var count_value := int(source.get("count", 0))
        if item_id == "" or not catalog.has(item_id) or count_value <= 0:
            slots.append({ "item": "", "count": 0 })
        else:
            var stack_max := int(catalog[item_id].get("stackMax", 1))
            slots.append({ "item": item_id, "count": clampi(count_value, 1, stack_max) })
    notify()

func notify() -> void:
    changed.emit()
