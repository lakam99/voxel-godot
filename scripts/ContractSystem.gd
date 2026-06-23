extends RefCounted
class_name ContractSystem

signal changed
signal rewarded(contract)

var catalog := {}
var contracts := []
var completed := {}
var town_unlocked := false
var menu_open := false
var recent := "Find a town to unlock contracts"

func _init(catalog_value := {}) -> void:
    catalog = catalog_value
    contracts = create_contracts()

func create_contracts() -> Array:
    return [
        { "id": "trailScout", "label": "Trail Scout", "detail": "Find a town and chart 5 biomes", "reward": { "xp": 30, "items": { "cookedBerries": 2 } } },
        { "id": "masonOrder", "label": "Mason Order", "detail": "Carry 18 stones for town builders", "reward": { "xp": 24, "items": { "stoneBlock": 4 } } },
        { "id": "ironSupply", "label": "Iron Supply", "detail": "Smelt 3 iron ingots for the smith", "reward": { "xp": 42, "items": { "copperIngot": 2, "torch": 3 } } },
        { "id": "prospector", "label": "Prospector", "detail": "Find a mine or carry 8 raw ore", "reward": { "xp": 38, "items": { "copperIngot": 2, "arrows": 8 } } },
        { "id": "copperSample", "label": "Copper Sample", "detail": "Bring 4 copper ore or a smelted copper ingot", "reward": { "xp": 32, "items": { "logs": 4, "copperIngot": 1 } } },
        { "id": "smelterRun", "label": "Smelter Run", "detail": "Smelt 2 copper ingots for the foundry", "reward": { "xp": 34, "items": { "ironOre": 2, "logs": 4 } } },
        { "id": "ironSample", "label": "Iron Sample", "detail": "Bring 2 iron ore or a smelted iron ingot", "reward": { "xp": 44, "items": { "copperIngot": 2, "torch": 3 } } },
        { "id": "ruinSurveyor", "label": "Ruin Surveyor", "detail": "Find an old ruin for the archivist", "reward": { "xp": 34, "items": { "torch": 3, "arrows": 8 } } },
        { "id": "campClear", "label": "Camp Clear", "detail": "Scout a hostile camp or defeat 3 hostiles", "reward": { "xp": 38, "items": { "arrows": 10, "fieldRation": 1 } } },
        { "id": "smithSetup", "label": "Smith Setup", "detail": "Place an anvil for town metalwork", "reward": { "xp": 32, "items": { "ironOre": 2, "torch": 2 } } },
        { "id": "copperCommission", "label": "Copper Commission", "detail": "Forge any copper tool, weapon, or armor", "reward": { "xp": 30, "items": { "ironOre": 2, "cookedBerries": 2 } } },
        { "id": "wildPantry", "label": "Wild Pantry", "detail": "Bring aloe, mirecaps, and frost herbs", "reward": { "xp": 34, "items": { "fieldRation": 2, "aloeSalve": 1 } } },
        { "id": "quartermaster", "label": "Quartermaster", "detail": "Upgrade to an Expedition Pack", "reward": { "xp": 40, "items": { "fieldRation": 2, "torch": 4 } } },
        { "id": "nightWatch", "label": "Night Watch", "detail": "Defeat 5 night hostiles", "reward": { "xp": 36, "items": { "nightShard": 2 } } },
        { "id": "trapLine", "label": "Trap Line", "detail": "Place a Spike Trap", "reward": { "xp": 30, "items": { "arrows": 8, "stones": 4 } } },
        { "id": "huntersSupper", "label": "Hunter Supper", "detail": "Cook meat at a campfire or furnace", "reward": { "xp": 26, "items": { "fieldRation": 1, "torch": 2 } } },
        { "id": "fisherOrder", "label": "Fisher Order", "detail": "Catch 2 fish or cook a fish meal", "reward": { "xp": 28, "items": { "cookedFish": 2, "torch": 2 } } },
        { "id": "tannersOrder", "label": "Tanner Order", "detail": "Bring 4 hides or equip a Hide Vest", "reward": { "xp": 28, "items": { "cookedMeat": 2, "arrows": 8 } } },
        { "id": "charmwright", "label": "Charmwright", "detail": "Craft or equip an accessory", "reward": { "xp": 30, "items": { "frostHerb": 2, "aloe": 2 } } },
        { "id": "builderGuild", "label": "Builder Guild", "detail": "Place 16 permanent blocks", "reward": { "xp": 28, "items": { "glass": 2, "torch": 4 } } },
        { "id": "wardSupply", "label": "Ward Supply", "detail": "Craft or place a Ward Lantern", "reward": { "xp": 45, "items": { "nightShard": 2, "cookedBerries": 3 } } },
        { "id": "apothecaryOrder", "label": "Apothecary Order", "detail": "Prepare a Ward Tonic", "reward": { "xp": 36, "items": { "wardTonic": 1, "aloeSalve": 1 } } },
        { "id": "riftTrophy", "label": "Rift Trophy", "detail": "Recover a Rift Core", "reward": { "xp": 75, "items": { "wardTonic": 1, "nightShard": 3 } } },
        { "id": "anchorwright", "label": "Anchorwright", "detail": "Place a Rift Anchor", "reward": { "xp": 90, "items": { "wardTonic": 2, "ironIngot": 2 } } }
    ]

func reset() -> void:
    completed.clear()
    town_unlocked = false
    menu_open = false
    recent = "Find a town to unlock contracts"
    changed.emit()

func snapshot() -> Dictionary:
    return {
        "completed": completed.keys(),
        "townUnlocked": town_unlocked,
        "menuOpen": menu_open
    }

func restore(snapshot_value = {}) -> void:
    var saved: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
    completed.clear()
    var saved_completed: Array = saved.get("completed", [])
    for contract_id in saved_completed:
        var id := String(contract_id)
        if id != "":
            completed[id] = true
    town_unlocked = bool(saved.get("townUnlocked", false)) or completed.size() > 0
    menu_open = town_unlocked and bool(saved.get("menuOpen", false))
    recent = "Contracts restored" if town_unlocked else "Find a town to unlock contracts"
    changed.emit()

func state() -> Dictionary:
    return {
        "completed": completed.size(),
        "total": contracts.size(),
        "townUnlocked": town_unlocked,
        "menuOpen": menu_open,
        "active": String(active_contract().get("id", "")),
        "recent": recent,
        "contracts": contract_rows()
    }

func active_contract() -> Dictionary:
    if not town_unlocked:
        return {}
    for contract in contracts:
        if not completed.has(String(contract.get("id", ""))):
            return contract
    return {}

func toggle_menu(force_value = null) -> bool:
    if not town_unlocked:
        menu_open = false
        recent = "Find a town to unlock contracts"
        changed.emit()
        return false
    if force_value is bool:
        menu_open = bool(force_value)
    else:
        menu_open = not menu_open
    changed.emit()
    return menu_open

func update(objective_state: Dictionary) -> bool:
    var any_changed := false
    if int(objective_state.get("discoveredTowns", 0)) > 0 and not town_unlocked:
        town_unlocked = true
        recent = "Town contracts unlocked"
        any_changed = true
    if town_unlocked:
        for contract in contracts:
            var id := String(contract.get("id", ""))
            if completed.has(id):
                continue
            if not is_contract_complete(id, objective_state):
                continue
            completed[id] = true
            recent = "Contract complete: %s" % String(contract.get("label", id))
            rewarded.emit(contract.duplicate(true))
            any_changed = true
            break
    if any_changed:
        changed.emit()
    return any_changed

func is_contract_complete(id: String, state: Dictionary) -> bool:
    var totals: Dictionary = state.get("totals", {})
    var counts: Dictionary = state.get("structureCounts", {})
    var equipment: Dictionary = state.get("equipment", {})
    var hostiles: Dictionary = state.get("hostiles", {})
    var defeated_variants: Dictionary = hostiles.get("defeatedVariants", {})
    var discovered_towns := int(state.get("discoveredTowns", 0))
    if discovered_towns <= 0:
        return false
    match id:
        "trailScout":
            return int(state.get("discoveredBiomes", 0)) >= 5
        "masonOrder":
            return int(totals.get("stones", 0)) >= 18
        "ironSupply":
            return int(totals.get("ironIngot", 0)) >= 3 or int(totals.get("ironPickaxe", 0)) > 0 or int(totals.get("ironArmor", 0)) > 0
        "prospector":
            return int(state.get("discoveredMines", 0)) > 0 or int(totals.get("copperOre", 0)) + int(totals.get("ironOre", 0)) >= 8
        "copperSample":
            return int(totals.get("copperOre", 0)) >= 4 or int(totals.get("copperIngot", 0)) > 0 or int(totals.get("copperPickaxe", 0)) > 0 or int(totals.get("ironPickaxe", 0)) > 0
        "smelterRun":
            return int(totals.get("copperIngot", 0)) >= 2 or int(totals.get("copperPickaxe", 0)) > 0 or int(totals.get("ironPickaxe", 0)) > 0
        "ironSample":
            return int(totals.get("ironOre", 0)) >= 2 or int(totals.get("ironIngot", 0)) > 0 or int(totals.get("ironPickaxe", 0)) > 0 or int(totals.get("ironArmor", 0)) > 0
        "ruinSurveyor":
            return int(state.get("discoveredRuins", 0)) > 0
        "campClear":
            return int(state.get("discoveredCamps", 0)) > 0 or int(hostiles.get("defeated", 0)) >= 3
        "smithSetup":
            return int(counts.get("anvil", 0)) > 0
        "copperCommission":
            return (
                int(totals.get("copperAxe", 0)) > 0
                or int(totals.get("copperPickaxe", 0)) > 0
                or int(totals.get("copperShovel", 0)) > 0
                or int(totals.get("copperSword", 0)) > 0
                or int(totals.get("copperArmor", 0)) > 0
                or String(equipment.get("body", "")) == "copperArmor"
            )
        "wildPantry":
            return int(totals.get("aloe", 0)) >= 1 and int(totals.get("mirecap", 0)) >= 1 and int(totals.get("frostHerb", 0)) >= 1
        "quartermaster":
            return int(state.get("inventorySize", 0)) >= 40
        "nightWatch":
            return int(hostiles.get("defeated", 0)) >= 5
        "trapLine":
            return int(counts.get("spikeTrap", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "huntersSupper":
            return int(totals.get("cookedMeat", 0)) > 0
        "fisherOrder":
            return int(totals.get("rawFish", 0)) >= 2 or int(totals.get("cookedFish", 0)) > 0
        "tannersOrder":
            return int(totals.get("hide", 0)) >= 4 or int(totals.get("hideVest", 0)) > 0 or String(equipment.get("body", "")) == "hideVest"
        "charmwright":
            return String(equipment.get("accessory", "")) != "" or int(totals.get("trailCharm", 0)) > 0 or int(totals.get("wardAmulet", 0)) > 0 or int(totals.get("surveyLens", 0)) > 0
        "builderGuild":
            return int(state.get("placedBlocks", 0)) >= 16
        "wardSupply":
            return int(totals.get("wardLantern", 0)) > 0 or int(counts.get("wardLantern", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "apothecaryOrder":
            return int(totals.get("wardTonic", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "riftTrophy":
            return int(defeated_variants.get("rift", 0)) > 0 or int(totals.get("riftCore", 0)) > 0 or bool(state.get("sanctuaryEstablished", false))
        "anchorwright":
            return int(counts.get("riftAnchor", 0)) > 0 or bool(state.get("sanctuaryEstablished", false))
    return false

func contract_rows() -> Array:
    var rows := []
    var active_id := String(active_contract().get("id", ""))
    for contract in contracts:
        var id := String(contract.get("id", ""))
        rows.append({
            "id": id,
            "label": String(contract.get("label", id)),
            "detail": String(contract.get("detail", "")),
            "reward": reward_text(contract),
            "completed": completed.has(id),
            "active": id == active_id
        })
    return rows

func reward_text(contract: Dictionary) -> String:
    var reward: Dictionary = contract.get("reward", {})
    var parts := []
    var xp := int(reward.get("xp", 0))
    if xp > 0:
        parts.append("%d XP" % xp)
    var items: Dictionary = reward.get("items", {})
    for item_id_variant in items.keys():
        var item_id := String(item_id_variant)
        parts.append("%s %d" % [String(catalog.get(item_id, {}).get("label", item_id)), int(items[item_id_variant])])
    return " + ".join(parts)
