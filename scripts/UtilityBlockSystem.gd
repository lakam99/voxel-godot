extends RefCounted
class_name UtilityBlockSystem

const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")

signal changed
signal processed(block_type, output_item)
signal traded(trade)

const CHEST_SIZE := 12
const EMPTY_SLOT := { "item": "", "count": 0 }
const HEAT_STATION_RECIPES := {
    "furnace": {
        "sand": { "output": "glass", "label": "Glass", "duration": 4.5 },
        "berries": { "output": "cookedBerries", "label": "Cooked Berries", "duration": 3.2 },
        "rawMeat": { "output": "cookedMeat", "label": "Cooked Meat", "duration": 4.2 },
        "rawFish": { "output": "cookedFish", "label": "Cooked Fish", "duration": 3.9 },
        "copperOre": { "output": "copperIngot", "label": "Copper Ingot", "duration": 5.4 },
        "ironOre": { "output": "ironIngot", "label": "Iron Ingot", "duration": 6.8 }
    },
    "campfire": {
        "berries": { "output": "cookedBerries", "label": "Cooked Berries", "duration": 2.6 },
        "rawMeat": { "output": "cookedMeat", "label": "Cooked Meat", "duration": 3.8 },
        "rawFish": { "output": "cookedFish", "label": "Cooked Fish", "duration": 3.4 }
    }
}
const MARKET_TRADES := [
    { "id": "trailTorches", "label": "Trail Torches", "output": "torch", "amount": 4, "costs": { "logs": 2 } },
    { "id": "cookedRations", "label": "Cooked Rations", "output": "cookedBerries", "amount": 2, "costs": { "berries": 4, "logs": 1 } },
    { "id": "masonBundle", "label": "Mason Bundle", "output": "stoneBlock", "amount": 4, "costs": { "stones": 5 } },
    { "id": "glassBundle", "label": "Glass Bundle", "output": "glass", "amount": 2, "costs": { "sand": 2, "stones": 1 } },
    { "id": "hunterStew", "label": "Hunter Stew", "output": "hunterStew", "amount": 1, "costs": { "cookedMeat": 1, "berries": 2 } },
    { "id": "dockMeal", "label": "Dock Meal", "output": "cookedFish", "amount": 2, "costs": { "rawFish": 2, "logs": 1 } },
    { "id": "wardTonic", "label": "Ward Tonic", "output": "wardTonic", "amount": 1, "costs": { "aloe": 1, "frostHerb": 1, "glass": 1, "nightShard": 1 } },
    { "id": "wardLantern", "label": "Ward Lantern", "output": "wardLantern", "amount": 1, "costs": { "torch": 1, "glass": 2, "nightShard": 2 } },
    { "id": "relicIron", "label": "Relic Iron", "output": "ironIngot", "amount": 2, "costs": { "relicFragment": 2, "stones": 3 }, "xp": 12 },
    { "id": "relicWardCache", "label": "Relic Ward Cache", "output": "wardTonic", "amount": 2, "costs": { "relicFragment": 2, "nightShard": 1 }, "xp": 14 },
    { "id": "surveyLens", "label": "Survey Lens", "output": "surveyLens", "amount": 1, "costs": { "relicFragment": 4, "compass": 1, "glass": 2 }, "xp": 20 }
]

var inventory
var active_block: Node = null
var heat_blocks: Array = []
var last_message := ""

func setup(inventory_system) -> void:
    inventory = inventory_system

func is_heat_station(block_type: String) -> bool:
    return block_type == "furnace" or block_type == "campfire"

func is_utility_block(block_type: String) -> bool:
    return block_type == "chest" or is_heat_station(block_type) or block_type == "traderStall"

func open_block(block: Node) -> bool:
    if block == null or not block.has_meta("block_type"):
        return false
    var block_type := String(block.get_meta("block_type"))
    if not is_utility_block(block_type):
        return false
    active_block = block
    if block_type == "chest":
        ensure_chest(block)
    elif is_heat_station(block_type):
        ensure_furnace(block)
    last_message = "%s opened" % ItemCatalogScript.label(block_type)
    changed.emit()
    return true

func close() -> void:
    active_block = null
    changed.emit()

func is_open() -> bool:
    return active_block != null and is_instance_valid(active_block)

func active_type() -> String:
    if active_block == null or not is_instance_valid(active_block) or not active_block.has_meta("block_type"):
        return ""
    return String(active_block.get_meta("block_type"))

func active_state() -> Dictionary:
    if active_block == null or not is_instance_valid(active_block):
        active_block = null
        return {}
    var block_type := active_type()
    if block_type == "chest":
        var chest_slots: Array = ensure_chest(active_block)
        var filled := 0
        for slot in chest_slots:
            if String(slot.get("item", "")) != "":
                filled += 1
        return {
            "type": block_type,
            "slots": duplicate_slots(chest_slots),
            "status": "%d/%d" % [filled, chest_slots.size()],
            "message": last_message
        }
    if is_heat_station(block_type):
        var furnace_state: Dictionary = ensure_furnace(active_block)
        var check: Dictionary = can_process(furnace_state, block_type)
        return {
            "type": block_type,
            "input": furnace_state["input"].duplicate(),
            "fuel": furnace_state["fuel"].duplicate(),
            "output": furnace_state["output"].duplicate(),
            "processing": bool(furnace_state.get("processing", false)),
            "progress": float(furnace_state.get("progress", 0.0)),
            "duration": float(furnace_state.get("duration", 1.0)),
            "canProcess": bool(check.get("ok", false)),
            "status": String(check.get("reason", "")),
            "message": last_message
        }
    if block_type == "traderStall":
        return {
            "type": block_type,
            "status": "Barter supplies",
            "trades": trade_states(),
            "message": last_message
        }
    return {}

func transfer_chest_slot(index: int) -> bool:
    if active_block == null or active_type() != "chest":
        return false
    var slots: Array = ensure_chest(active_block)
    if index < 0 or index >= slots.size():
        return false
    var slot: Dictionary = slots[index]
    if String(slot.get("item", "")) != "":
        withdraw_to_inventory(slot)
    else:
        transfer_with_active(slot)
    set_chest_slots(active_block, slots)
    return true

func transfer_furnace_slot(slot_name: String) -> bool:
    if active_block == null or not is_heat_station(active_type()):
        return false
    var block_type := active_type()
    var state: Dictionary = ensure_furnace(active_block)
    if slot_name == "input":
        transfer_with_active(state["input"], { "accepts": recipes_for(block_type).keys(), "label": input_label(block_type) })
    elif slot_name == "fuel":
        transfer_with_active(state["fuel"], { "accepts": ["logs"], "label": "%s fuel takes logs" % ItemCatalogScript.label(block_type) })
    elif slot_name == "output":
        withdraw_to_active(state["output"])
    else:
        return false
    set_furnace_state(active_block, state)
    return true

func start_processing() -> bool:
    if active_block == null or not is_heat_station(active_type()):
        return false
    var block_type := active_type()
    var state: Dictionary = ensure_furnace(active_block)
    var check: Dictionary = can_process(state, block_type)
    if not bool(check.get("ok", false)):
        last_message = "%s: %s" % [ItemCatalogScript.label(block_type), String(check.get("reason", ""))]
        changed.emit()
        return false
    var recipe: Dictionary = check.get("recipe", {})
    state["input"]["count"] = int(state["input"].get("count", 0)) - 1
    normalize_slot(state["input"])
    state["fuel"]["count"] = int(state["fuel"].get("count", 0)) - 1
    normalize_slot(state["fuel"])
    state["processing"] = true
    state["progress"] = 0.0
    state["duration"] = float(recipe.get("duration", 4.5))
    state["outputItem"] = String(recipe.get("output", "glass"))
    set_furnace_state(active_block, state)
    last_message = "%s %s: %s" % [
        ItemCatalogScript.label(block_type),
        "cooking" if block_type == "campfire" else "lit",
        String(recipe.get("label", ItemCatalogScript.label(String(recipe.get("output", "")))))
    ]
    if inventory:
        inventory.notify()
    changed.emit()
    return true

func handle_action(action: String, payload = null) -> bool:
    if action == "chest_slot":
        return transfer_chest_slot(int(payload))
    if action == "furnace_slot":
        return transfer_furnace_slot(String(payload))
    if action == "start_processing":
        return start_processing()
    if action == "trade":
        return trade(String(payload))
    if action == "close":
        close()
        return true
    return false

func update(delta: float) -> void:
    var any_changed := false
    var tracked: Array = []
    for candidate in heat_blocks:
        if candidate == null or not is_instance_valid(candidate):
            continue
        var block := candidate as Node
        if block == null or block.get_parent() == null:
            continue
        tracked.append(block)
        var state: Dictionary = ensure_furnace(block)
        if not bool(state.get("processing", false)):
            continue
        state["progress"] = min(float(state.get("duration", 1.0)), float(state.get("progress", 0.0)) + delta)
        if float(state.get("progress", 0.0)) >= float(state.get("duration", 1.0)) and add_furnace_output(state):
            state["processing"] = false
            state["progress"] = 0.0
            last_message = "%s finished" % ItemCatalogScript.label(String(state.get("outputItem", "")))
            processed.emit(String(block.get_meta("block_type")), String(state.get("outputItem", "")))
        set_furnace_state(block, state)
        any_changed = true
    heat_blocks = tracked
    if any_changed:
        changed.emit()

func make_slots(size: int) -> Array:
    var result: Array = []
    for i in range(size):
        result.append(EMPTY_SLOT.duplicate())
    return result

func ensure_chest(block: Node) -> Array:
    if not block.has_meta("storage_slots"):
        block.set_meta("storage_slots", make_slots(CHEST_SIZE))
    return block.get_meta("storage_slots")

func set_chest_slots(block: Node, slots: Array) -> void:
    block.set_meta("storage_slots", slots)

func ensure_furnace(block: Node) -> Dictionary:
    if not block.has_meta("furnace_state"):
        block.set_meta("furnace_state", {
            "input": EMPTY_SLOT.duplicate(),
            "fuel": EMPTY_SLOT.duplicate(),
            "output": EMPTY_SLOT.duplicate(),
            "processing": false,
            "progress": 0.0,
            "duration": 4.5,
            "outputItem": ""
        })
    if not heat_blocks.has(block):
        heat_blocks.append(block)
    return block.get_meta("furnace_state")

func set_furnace_state(block: Node, state: Dictionary) -> void:
    block.set_meta("furnace_state", state)

func recipes_for(block_type: String) -> Dictionary:
    return HEAT_STATION_RECIPES.get(block_type, {})

func input_label(block_type: String) -> String:
    if block_type == "campfire":
        return "Campfire input takes berries, raw meat, or raw fish"
    return "Furnace input takes sand, berries, raw meat, raw fish, copper ore, or iron ore"

func trade_by_id(id: String) -> Dictionary:
    for trade in MARKET_TRADES:
        if String(trade.get("id", "")) == id:
            return trade
    return {}

func format_costs(costs: Dictionary) -> String:
    var parts := []
    for item_id_variant in costs.keys():
        var item_id := String(item_id_variant)
        parts.append("%s %d" % [ItemCatalogScript.label(item_id), int(costs[item_id_variant])])
    return " + ".join(parts)

func trade_state(trade: Dictionary) -> Dictionary:
    var costs: Dictionary = trade.get("costs", {})
    var output := String(trade.get("output", ""))
    var amount := int(trade.get("amount", 1))
    var enough: bool = inventory != null and bool(inventory.has_costs(costs))
    var has_space: bool = inventory != null and int(inventory.free_for(output)) >= amount
    var status := format_costs(costs)
    if not enough:
        status = "missing items"
    elif not has_space:
        status = "inventory full"
    return {
        "id": String(trade.get("id", "")),
        "label": String(trade.get("label", output)),
        "output": output,
        "amount": amount,
        "costs": costs,
        "costText": format_costs(costs),
        "status": status,
        "disabled": not enough or not has_space,
        "enough": enough,
        "hasSpace": has_space,
        "xp": int(trade.get("xp", 6))
    }

func trade_states() -> Array:
    var result := []
    for trade in MARKET_TRADES:
        result.append(trade_state(trade))
    return result

func trade(id: String) -> bool:
    if active_block == null or active_type() != "traderStall":
        return false
    var trade_data := trade_by_id(id)
    if trade_data.is_empty():
        last_message = "Trade missing"
        changed.emit()
        return false
    var state := trade_state(trade_data)
    if bool(state.get("disabled", true)):
        last_message = "Cannot trade for %s: %s" % [String(state.get("label", "")), String(state.get("status", ""))]
        changed.emit()
        return false
    if inventory == null or not inventory.consume_costs(trade_data.get("costs", {})):
        last_message = "Trade failed"
        changed.emit()
        return false
    var received: int = inventory.add_item(String(trade_data.get("output", "")), int(trade_data.get("amount", 1)))
    last_message = "Traded: %s x%d" % [String(trade_data.get("label", "")), received]
    traded.emit(trade_data)
    changed.emit()
    return received > 0

func can_process(state: Dictionary, block_type: String) -> Dictionary:
    if bool(state.get("processing", false)):
        return { "ok": false, "reason": "Cooking" if block_type == "campfire" else "Smelting" }
    var input_slot: Dictionary = state.get("input", EMPTY_SLOT.duplicate())
    var fuel_slot: Dictionary = state.get("fuel", EMPTY_SLOT.duplicate())
    var output_slot: Dictionary = state.get("output", EMPTY_SLOT.duplicate())
    var recipe: Dictionary = recipes_for(block_type).get(String(input_slot.get("item", "")), {})
    if recipe.is_empty() or int(input_slot.get("count", 0)) < 1:
        return { "ok": false, "reason": "Needs cookable food" if block_type == "campfire" else "Needs smeltable input" }
    if String(fuel_slot.get("item", "")) != "logs" or int(fuel_slot.get("count", 0)) < 1:
        return { "ok": false, "reason": "Needs logs" }
    var output_item := String(recipe.get("output", ""))
    if String(output_slot.get("item", "")) != "" and String(output_slot.get("item", "")) != output_item:
        return { "ok": false, "reason": "Output blocked" }
    if String(output_slot.get("item", "")) == output_item and int(output_slot.get("count", 0)) >= ItemCatalogScript.stack_max(output_item):
        return { "ok": false, "reason": "Output full" }
    return { "ok": true, "reason": "Ready: %s" % String(recipe.get("label", output_item)), "recipe": recipe }

func transfer_with_active(slot: Dictionary, options: Dictionary = {}) -> int:
    if inventory == null:
        return 0
    var active: Dictionary = inventory.active_stack()
    var active_item := String(active.get("item", ""))
    var slot_item := String(slot.get("item", ""))
    var accepts: Array = options.get("accepts", [])
    var has_accepts := accepts.size() > 0
    if active_item != "" and has_accepts and not accepts.has(active_item):
        last_message = String(options.get("label", "%s cannot store here" % ItemCatalogScript.label(active_item)))
        changed.emit()
        return 0
    var moved := 0
    if active_item != "" and slot_item == active_item:
        moved = move_between_slots(active, slot, ItemCatalogScript.stack_max(slot_item))
        after_transfer("Stored item" if moved > 0 else "Stack full")
        return moved
    if active_item == "" and slot_item != "":
        moved = move_between_slots(slot, active, ItemCatalogScript.stack_max(slot_item))
        after_transfer("Took item" if moved > 0 else "Cannot take item")
        return moved
    if active_item != "" and slot_item == "":
        moved = move_between_slots(active, slot, ItemCatalogScript.stack_max(active_item))
        after_transfer("Stored item" if moved > 0 else "Cannot store item")
        return moved
    if active_item != "" and slot_item != "":
        var held := active.duplicate()
        active["item"] = slot_item
        active["count"] = int(slot.get("count", 0))
        slot["item"] = held.get("item", "")
        slot["count"] = int(held.get("count", 0))
        after_transfer("Swapped item")
        return int(active.get("count", 0))
    last_message = "Empty slot"
    changed.emit()
    return 0

func withdraw_to_active(slot: Dictionary) -> int:
    if inventory == null:
        return 0
    if String(slot.get("item", "")) == "":
        last_message = "Output empty"
        changed.emit()
        return 0
    var active: Dictionary = inventory.active_stack()
    var active_item := String(active.get("item", ""))
    var slot_item := String(slot.get("item", ""))
    if active_item != "" and active_item != slot_item:
        last_message = "Active slot must match output"
        changed.emit()
        return 0
    var moved := move_between_slots(slot, active, ItemCatalogScript.stack_max(slot_item))
    after_transfer("Took output" if moved > 0 else "Active stack full")
    return moved

func withdraw_to_inventory(slot: Dictionary) -> int:
    if inventory == null:
        return 0
    var item_id := String(slot.get("item", ""))
    var count := int(slot.get("count", 0))
    if item_id == "" or count <= 0:
        last_message = "Empty slot"
        changed.emit()
        return 0
    var selected_slot := int(inventory.selected_slot)
    var moved: int = inventory.add_item_away_from_empty_slot(item_id, count, selected_slot) if inventory.has_method("add_item_away_from_empty_slot") else inventory.add_item(item_id, count)
    if moved <= 0:
        last_message = "Inventory full"
        changed.emit()
        return 0
    slot["count"] = count - moved
    normalize_slot(slot)
    after_transfer("Took item" if moved == count else "Took %d, inventory full" % moved)
    return moved

func move_between_slots(from_slot: Dictionary, to_slot: Dictionary, to_max: int) -> int:
    var item_id := String(from_slot.get("item", ""))
    if item_id == "" or int(from_slot.get("count", 0)) <= 0:
        return 0
    var to_item := String(to_slot.get("item", ""))
    if to_item != "" and to_item != item_id:
        return 0
    var free := to_max - int(to_slot.get("count", 0)) if to_item != "" else to_max
    if free <= 0:
        return 0
    var moved: int = min(int(from_slot.get("count", 0)), free)
    if to_item == "":
        to_slot["item"] = item_id
    to_slot["count"] = int(to_slot.get("count", 0)) + moved
    from_slot["count"] = int(from_slot.get("count", 0)) - moved
    normalize_slot(from_slot)
    normalize_slot(to_slot)
    return moved

func normalize_slot(slot: Dictionary) -> void:
    if int(slot.get("count", 0)) <= 0 or String(slot.get("item", "")) == "":
        slot["item"] = ""
        slot["count"] = 0

func after_transfer(message: String) -> void:
    last_message = message
    if inventory:
        inventory.notify()
    changed.emit()

func add_furnace_output(state: Dictionary) -> bool:
    var output := String(state.get("outputItem", "glass"))
    var output_slot: Dictionary = state.get("output", EMPTY_SLOT.duplicate())
    if output == "":
        return false
    if String(output_slot.get("item", "")) != "" and String(output_slot.get("item", "")) != output:
        return false
    if String(output_slot.get("item", "")) == output and int(output_slot.get("count", 0)) >= ItemCatalogScript.stack_max(output):
        return false
    if String(output_slot.get("item", "")) == "":
        output_slot["item"] = output
    output_slot["count"] = int(output_slot.get("count", 0)) + 1
    state["output"] = output_slot
    return true

func duplicate_slots(slots: Array) -> Array:
    var result: Array = []
    for slot in slots:
        if slot is Dictionary:
            result.append(slot.duplicate())
        else:
            result.append(EMPTY_SLOT.duplicate())
    return result
