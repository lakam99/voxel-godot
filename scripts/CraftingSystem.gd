extends RefCounted
class_name CraftingSystem

signal changed
signal crafted(recipe_id, output, amount)

var recipes := []
var catalog := {}
var inventory
var station_provider := Callable()
var last_message := ""
var unlocked_groups := {}

const UNLOCK_GROUP_LABELS := {
    "tutorial_repair": "tutorial repair crafting",
    "rowan_basic_tools": "Rowan's basic tools",
    "rescue_weapon": "rescue weapon training",
    "book_stone_tools": "stone crafting book",
    "book_settlement_basics": "settlement crafting book",
    "book_survival_crafting": "survival crafting book",
    "book_hunting": "hunting crafting book",
    "book_metalworking": "metalworking crafting book",
    "book_wardcraft": "wardcraft book",
    "book_packs": "pack crafting book",
    "book_defense": "defense crafting book",
    "rare_bow": "rare bow book",
    "rare_compass": "rare compass book",
    "rare_map": "rare map book",
    "rare_survey_lens": "rare survey lens book"
}

func _init(recipe_list := [], catalog_value := {}, inventory_system = null, station_provider_value := Callable()) -> void:
    recipes = recipe_list
    catalog = catalog_value
    inventory = inventory_system
    station_provider = station_provider_value

func recipe_for(recipe_id: String) -> Dictionary:
    for recipe in recipes:
        if String(recipe.get("id", "")) == recipe_id:
            return recipe
    return {}

func recipe_states() -> Dictionary:
    var has_bench := has_station("workbench")
    var has_anvil := has_station("anvil")
    var states := []
    for recipe in recipes:
        states.append(state_for_with_stations(recipe, has_bench, has_anvil))
    return {
        "hasBench": has_bench,
        "hasAnvil": has_anvil,
        "recipes": states
    }

func state_for(recipe: Dictionary) -> Dictionary:
    return state_for_with_stations(recipe, has_station("workbench"), has_station("anvil"))

func state_for_with_stations(recipe: Dictionary, has_bench: bool, has_anvil: bool) -> Dictionary:
    var costs: Dictionary = recipe.get("costs", {})
    var enough: bool = inventory != null and inventory.has_costs(costs)
    var output := String(recipe.get("output", ""))
    var amount := int(recipe.get("amount", 1))
    var upgrade: Dictionary = recipe.get("upgrade", {})
    var unlock_group := recipe_unlock_group(recipe)
    var unlock_locked := not is_recipe_unlocked(recipe)
    var has_space := true
    var upgrade_locked := false
    if upgrade.is_empty():
        has_space = inventory != null and inventory.free_for(output) >= amount
    elif upgrade.has("inventorySize"):
        upgrade_locked = inventory == null or inventory.size >= int(upgrade["inventorySize"])
    var bench_locked := bool(recipe.get("requiresWorkbench", false)) and not has_bench
    var anvil_locked := bool(recipe.get("requiresAnvil", false)) and not has_anvil
    var disabled: bool = unlock_locked or not enough or not has_space or bench_locked or anvil_locked or upgrade_locked
    var status := format_costs(costs)
    if unlock_locked:
        status = "locked: %s" % unlock_label(unlock_group)
    elif upgrade_locked:
        status = "already upgraded"
    elif anvil_locked:
        status = "needs anvil"
    elif bench_locked:
        status = "needs bench"
    elif not enough:
        status = "missing items"
    elif not has_space:
        status = "inventory full"
    return {
        "recipe": recipe,
        "enough": enough,
        "hasSpace": has_space,
        "unlockGroup": unlock_group,
        "unlockLocked": unlock_locked,
        "benchLocked": bench_locked,
        "anvilLocked": anvil_locked,
        "upgradeLocked": upgrade_locked,
        "disabled": disabled,
        "status": status
    }

func craft(recipe_id: String) -> bool:
    var recipe: Dictionary = recipe_for(recipe_id)
    if recipe.is_empty():
        last_message = "Crafting recipe missing"
        changed.emit()
        return false
    var state: Dictionary = state_for(recipe)
    if bool(state.get("disabled", true)):
        last_message = "Cannot craft %s: %s" % [recipe.get("label", recipe_id), state.get("status", "blocked")]
        changed.emit()
        return false
    if inventory == null or not inventory.consume_costs(recipe.get("costs", {})):
        last_message = "Cannot craft %s: missing items" % recipe.get("label", recipe_id)
        changed.emit()
        return false

    var upgrade: Dictionary = recipe.get("upgrade", {})
    if not upgrade.is_empty() and upgrade.has("inventorySize"):
        inventory.set_size(int(upgrade["inventorySize"]))
        last_message = "Upgraded: %s" % recipe.get("label", recipe_id)
        crafted.emit(recipe_id, recipe.get("output", ""), 1)
        changed.emit()
        return true

    var output := String(recipe.get("output", ""))
    var amount := int(recipe.get("amount", 1))
    var added: int = inventory.add_item(output, amount)
    last_message = "Crafted: %s x%d" % [recipe.get("label", recipe_id), added]
    crafted.emit(recipe_id, output, added)
    changed.emit()
    return added > 0

func recipe_unlock_group(recipe: Dictionary) -> String:
    return String(recipe.get("unlockGroup", recipe.get("unlock", "")))

func is_recipe_unlocked(recipe: Dictionary) -> bool:
    var group_id := recipe_unlock_group(recipe)
    return group_id == "" or bool(unlocked_groups.get(group_id, false))

func unlock_group(group_id: String) -> bool:
    group_id = group_id.strip_edges()
    if group_id == "":
        return false
    if bool(unlocked_groups.get(group_id, false)):
        return false
    unlocked_groups[group_id] = true
    last_message = "Unlocked: %s" % unlock_label(group_id)
    changed.emit()
    return true

func unlock_groups(group_ids: Array) -> bool:
    var changed_any := false
    for group_id_value in group_ids:
        changed_any = unlock_group(String(group_id_value)) or changed_any
    return changed_any

func unlock_all_groups() -> bool:
    return unlock_groups(UNLOCK_GROUP_LABELS.keys())

func reset_unlocks(initial_groups := []) -> void:
    unlocked_groups.clear()
    for group_id_value in initial_groups:
        var group_id := String(group_id_value).strip_edges()
        if group_id != "":
            unlocked_groups[group_id] = true
    changed.emit()

func has_unlock_group(group_id: String) -> bool:
    group_id = group_id.strip_edges()
    return group_id == "" or bool(unlocked_groups.get(group_id, false))

func snapshot() -> Dictionary:
    var groups := unlocked_groups.keys()
    groups.sort()
    return { "unlockedGroups": groups }

func restore(snapshot_value = {}) -> void:
    unlocked_groups.clear()
    var state: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
    var groups_value = state.get("unlockedGroups", [])
    if groups_value is Dictionary:
        for group_id_variant in groups_value.keys():
            if bool(groups_value[group_id_variant]):
                var group_id := String(group_id_variant).strip_edges()
                if group_id != "":
                    unlocked_groups[group_id] = true
    elif groups_value is Array:
        for group_id_value in groups_value:
            var group_id := String(group_id_value).strip_edges()
            if group_id != "":
                unlocked_groups[group_id] = true
    changed.emit()

func unlock_label(group_id: String) -> String:
    return String(UNLOCK_GROUP_LABELS.get(group_id, group_id))

func has_station(station_id: String) -> bool:
    if station_provider.is_valid():
        return bool(station_provider.call(station_id))
    return false

func format_costs(costs: Dictionary) -> String:
    var parts := []
    for item_id_variant in costs.keys():
        var item_id := String(item_id_variant)
        var label := item_id
        if catalog.has(item_id):
            label = String(catalog[item_id].get("label", item_id))
        parts.append("%s %d" % [label, int(costs[item_id_variant])])
    return " + ".join(parts)
