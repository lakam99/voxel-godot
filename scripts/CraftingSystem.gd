extends RefCounted
class_name CraftingSystem

signal changed
signal crafted(recipe_id, output, amount)

var recipes := []
var catalog := {}
var inventory
var station_provider := Callable()
var last_message := ""

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
    var has_space := true
    var upgrade_locked := false
    if upgrade.is_empty():
        has_space = inventory != null and inventory.free_for(output) >= amount
    elif upgrade.has("inventorySize"):
        upgrade_locked = inventory == null or inventory.size >= int(upgrade["inventorySize"])
    var bench_locked := bool(recipe.get("requiresWorkbench", false)) and not has_bench
    var anvil_locked := bool(recipe.get("requiresAnvil", false)) and not has_anvil
    var disabled: bool = not enough or not has_space or bench_locked or anvil_locked or upgrade_locked
    var status := format_costs(costs)
    if upgrade_locked:
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
