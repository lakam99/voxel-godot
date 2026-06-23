extends RefCounted
class_name ObjectiveSystem

signal changed
signal completed(objective)

const POST_INTRO_TUTORIAL_OBJECTIVES := {
    "tutorial_mira": true,
    "tutorial_rowan": true,
    "tutorial_niko": true,
    "tutorial_sera": true,
    "tutorial_gather_logs": true,
    "tutorial_make_workbench": true,
    "tutorial_make_blocks": true,
    "tutorial_food": true,
    "tutorial_weapon": true,
    "tutorial_final_night": true,
    "tutorial_ready": true
}

var last_state := {}

var objectives := [
    { "id": "tutorial_open_door", "label": "Answer the Knock", "detail": "Open the door for Mira", "completed": false },
    { "id": "tutorial_repair_chest", "label": "Open Repair Chest", "detail": "Take wood and stone from the town chest", "completed": false },
    { "id": "tutorial_build_repairs", "label": "Build Fence and Lamps", "detail": "Craft enough wood blocks and torches for the broken perimeter", "completed": false },
    { "id": "tutorial_repair_perimeter", "label": "Repair the Perimeter", "detail": "Place the missing fence blocks and lamps around town", "completed": false },
    { "id": "tutorial_sleep_after_repair", "label": "Sleep Through the Storm", "detail": "Use your bed after the perimeter is repaired", "completed": false },
    { "id": "tutorial_mira", "label": "Speak to Mira", "detail": "Wake in the village shelter", "completed": false },
    { "id": "tutorial_rowan", "label": "Meet Rowan", "detail": "Find the carpenter near the workbench", "completed": false },
    { "id": "tutorial_niko", "label": "Meet Niko", "detail": "Ask the forager about food", "completed": false },
    { "id": "tutorial_sera", "label": "Meet Sera", "detail": "Ask the watch about the village lights", "completed": false },
    { "id": "tutorial_gather_logs", "label": "Craft an Axe and Gather Wood", "detail": "Craft an axe, then bring Rowan 4 logs", "completed": false },
    { "id": "tutorial_make_workbench", "label": "Craft a Pickaxe", "detail": "Use a workbench to make a pickaxe", "completed": false },
    { "id": "tutorial_make_blocks", "label": "Gather Stone", "detail": "Use a pickaxe and bring Rowan 4 stones", "completed": false },
    { "id": "tutorial_food", "label": "Pack Food", "detail": "Bring Niko 2 berries for a field ration", "completed": false },
    { "id": "tutorial_weapon", "label": "Arm Yourself", "detail": "Craft a sword or bow before leaving the lights", "completed": false },
    { "id": "tutorial_final_night", "label": "Rescue the Forager", "detail": "Follow Sera and clear the monsters around Niko", "completed": false },
    { "id": "tutorial_ready", "label": "Ready for the Wilds", "detail": "Prepare food, tools, and a weapon", "completed": false },
    { "id": "logs", "label": "Gather Logs", "detail": "Collect logs from trees", "completed": false },
    { "id": "craft_workbench", "label": "Craft a Workbench", "detail": "Make your first station", "completed": false },
    { "id": "place_workbench", "label": "Place the Workbench", "detail": "Unlock station crafting nearby", "completed": false },
    { "id": "workbench", "label": "Place a Workbench", "detail": "Open crafting near it", "completed": false },
    { "id": "craft_wood_block", "label": "Craft Wood Blocks", "detail": "Turn logs into building blocks", "completed": false },
    { "id": "woodenPickaxe", "label": "Craft a Wooden Pickaxe", "detail": "Use the workbench to make your first mining tool", "completed": false },
    { "id": "stonePickaxe", "label": "Craft a Stone Pickaxe", "detail": "Stone picks can break copper veins", "completed": false },
    { "id": "mineCopper", "label": "Mine Copper Ore", "detail": "Use a stone pickaxe on copper veins", "completed": false },
    { "id": "smeltCopper", "label": "Smelt Copper", "detail": "Use a furnace with copper ore and logs", "completed": false },
    { "id": "anvil", "label": "Place an Anvil", "detail": "Unlock metalworking for copper and iron gear", "completed": false },
    { "id": "craftCopperPickaxe", "label": "Forge a Copper Pickaxe", "detail": "Copper picks can break iron veins", "completed": false },
    { "id": "mineIron", "label": "Mine Iron Ore", "detail": "Use a copper pickaxe on iron veins", "completed": false },
    { "id": "smeltIron", "label": "Smelt Iron", "detail": "Use a furnace with iron ore and logs", "completed": false },
    { "id": "craftIronPickaxe", "label": "Forge an Iron Pickaxe", "detail": "Craft a durable pick for late-game materials", "completed": false },
    { "id": "campfire", "label": "Make a Safe Fire", "detail": "Place a campfire or torch", "completed": false },
    { "id": "spikeTrap", "label": "Set a Trap", "detail": "Craft and place a Spike Trap for defense", "completed": false },
    { "id": "hunt", "label": "Hunt for Meat", "detail": "Hunt wildlife or hostiles for raw meat", "completed": false },
    { "id": "fish", "label": "Catch a Fish", "detail": "Craft a rod and fish near water", "completed": false },
    { "id": "tool", "label": "Make a Tool or Weapon", "detail": "Craft any tool, sword, or bow", "completed": false },
    { "id": "ranged", "label": "Make a Ranged Weapon", "detail": "Craft arrows and a bow for safer hunts", "completed": false },
    { "id": "bed", "label": "Set a Bed", "detail": "Craft or find a bed for safe nights", "completed": false },
    { "id": "shelter", "label": "Build a Shelter", "detail": "Sleep or stand inside a roofed, lit shelter", "completed": false },
    { "id": "armor", "label": "Equip Armor", "detail": "Craft or equip armor", "completed": false },
    { "id": "accessory", "label": "Equip a Charm", "detail": "Craft or equip an accessory", "completed": false },
    { "id": "level", "label": "Grow Stronger", "detail": "Reach level 3", "completed": false },
    { "id": "torch", "label": "Bring Light", "detail": "Craft or place a torch", "completed": false },
    { "id": "glass", "label": "Smelt Glass", "detail": "Use a furnace with sand and logs", "completed": false },
    { "id": "iron", "label": "Forge Iron", "detail": "Mine ore, smelt ingots, and craft iron gear", "completed": false },
    { "id": "mine", "label": "Find a Mine", "detail": "Locate a mine site or bring back raw ore", "completed": false },
    { "id": "copperGear", "label": "Forge Copper Gear", "detail": "Use the anvil to craft any copper gear", "completed": false },
    { "id": "craft_compass", "label": "Craft a Compass", "detail": "Unlock heading UI", "completed": false },
    { "id": "compass", "label": "Craft a Compass", "detail": "Track shelter, wards, and the beacon", "completed": false },
    { "id": "pack", "label": "Upgrade Your Pack", "detail": "Craft a Trail Pack for longer expeditions", "completed": false },
    { "id": "biomeSurvey", "label": "Survey the Wilds", "detail": "Discover 4 biomes", "completed": false },
    { "id": "town", "label": "Find a Town", "detail": "Unlock contracts", "completed": false },
    { "id": "landmarkScout", "label": "Scout a Landmark", "detail": "Find an old ruin, mine, or hostile camp", "completed": false },
    { "id": "enemyCamp", "label": "Clear a Camp", "detail": "Find a hostile camp and defeat its guards", "completed": false },
    { "id": "shrine", "label": "Find a Rift Shrine", "detail": "Open a shrine cache for ward supplies", "completed": false },
    { "id": "cookedFood", "label": "Cook Food", "detail": "Use a campfire or furnace to cook food", "completed": false },
    { "id": "nightShard", "label": "Survive the Night", "detail": "Defeat hostiles for 2 Night Shards", "completed": false },
    { "id": "wardTonic", "label": "Brew a Ward Tonic", "detail": "Craft or trade for a Ward Tonic", "completed": false },
    { "id": "ward", "label": "Build a Ward", "detail": "Craft or place a Ward Lantern", "completed": false },
    { "id": "beacon", "label": "Raise the Beacon", "detail": "Place the Sanctuary Beacon", "completed": false },
    { "id": "riftRaid", "label": "Repel the Rift", "detail": "Survive every beacon charge surge", "completed": false },
    { "id": "riftColossus", "label": "Break the Colossus", "detail": "Defeat the Rift Colossus and claim its core", "completed": false },
    { "id": "riftAnchor", "label": "Bind the Rift", "detail": "Place a Rift Anchor", "completed": false },
    { "id": "sanctuary", "label": "Defend the Beacon", "detail": "Keep hostiles away until it fully charges", "completed": false }
]

func snapshot() -> Dictionary:
    var completed_ids := []
    for objective in objectives:
        if bool(objective.get("completed", false)):
            completed_ids.append(String(objective.get("id", "")))
    return {
        "completed": completed_ids,
        "total": objectives.size()
    }

func restore(snapshot_value = {}) -> void:
    var state: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
    var completed_ids := {}
    for objective_id in state.get("completed", []):
        completed_ids[String(objective_id)] = true
    for objective in objectives:
        objective["completed"] = completed_ids.has(String(objective.get("id", "")))
    changed.emit()

func complete(objective_id: String) -> bool:
    for objective in objectives:
        if String(objective.get("id", "")) != objective_id:
            continue
        if bool(objective.get("completed", false)):
            return false
        objective["completed"] = true
        completed.emit(objective.duplicate())
        changed.emit()
        return true
    return false

func update(state: Dictionary) -> bool:
    last_state = state.duplicate(true)
    var any_completed := false
    for objective in objectives:
        if bool(objective.get("completed", false)):
            continue
        var objective_id := String(objective.get("id", ""))
        if not is_available(objective_id, state):
            continue
        if not is_complete(objective_id, state):
            continue
        objective["completed"] = true
        completed.emit(objective.duplicate())
        any_completed = true
    if any_completed:
        changed.emit()
    return any_completed

func is_complete(objective_id: String, state: Dictionary) -> bool:
    if not is_available(objective_id, state):
        return false
    var totals: Dictionary = state.get("totals", {})
    var counts: Dictionary = state.get("structureCounts", {})
    var equipment: Dictionary = state.get("equipment", {})
    var hostiles: Dictionary = state.get("hostiles", {})
    var tier_counts: Dictionary = state.get("generatedTierCounts", {})
    var defeated_variants: Dictionary = hostiles.get("defeatedVariants", {})
    var tutorial_talks: Dictionary = state.get("tutorialNpcTalks", {})
    var tutorial_steps: Dictionary = state.get("tutorialSteps", {})
    match objective_id:
        "tutorial_open_door":
            return bool(tutorial_steps.get("introDoorOpened", false)) or bool(state.get("introDoorOpened", false)) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_repair_chest":
            return bool(tutorial_steps.get("introRepairChest", false)) or bool(state.get("introRepairChestOpened", false)) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_build_repairs":
            return bool(tutorial_steps.get("introFenceBuilt", false)) or (
                int(state.get("introFencePlaced", 0)) >= int(state.get("introFenceRequired", 8))
                and int(state.get("introLampsPlaced", 0)) >= int(state.get("introLampsRequired", 4))
            ) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_repair_perimeter":
            return bool(tutorial_steps.get("introPerimeterRepaired", false)) or bool(state.get("introRepairComplete", false)) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_sleep_after_repair":
            return bool(tutorial_steps.get("introFirstSleep", false)) or bool(state.get("introBedUsed", false)) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_mira":
            return bool(tutorial_steps.get("miraMorningBriefing", false)) or bool(state.get("postIntroMiraBriefed", false)) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_rowan":
            return bool(tutorial_talks.get("rowan", false)) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_niko":
            return bool(tutorial_talks.get("niko", false)) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_sera":
            return bool(tutorial_talks.get("sera", false)) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_gather_logs":
            return bool(tutorial_steps.get("rowanLogs", false)) or (has_axe(totals) and int(totals.get("logs", 0)) >= 4) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_make_workbench":
            return bool(tutorial_steps.get("rowanPickaxe", false)) or has_pickaxe(totals) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_make_blocks":
            return bool(tutorial_steps.get("rowanStones", false)) or bool(tutorial_steps.get("rowanBlocks", false)) or (has_pickaxe(totals) and int(totals.get("stones", 0)) >= 4) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_food":
            return bool(tutorial_steps.get("nikoBerries", false)) or int(totals.get("fieldRation", 0)) > 0 or int(totals.get("cookedBerries", 0)) > 0 or bool(state.get("sanctuaryEstablished", false))
        "tutorial_weapon":
            return bool(tutorial_steps.get("seraWeapon", false)) or has_weapon(totals) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_final_night":
            return bool(tutorial_steps.get("finalNightComplete", false)) or bool(state.get("finalNightComplete", false)) or bool(state.get("sanctuaryEstablished", false))
        "tutorial_ready":
            return bool(tutorial_steps.get("readyForWilds", false)) or bool(state.get("tutorialReadyForWilds", false)) or bool(state.get("sanctuaryEstablished", false))
        "logs":
            return int(totals.get("logs", 0)) >= 4 or int(counts.get("workbench", 0)) > 0
        "craft_workbench":
            return int(totals.get("workbench", 0)) > 0 or int(counts.get("workbench", 0)) > 0
        "place_workbench":
            return int(counts.get("workbench", 0)) > 0
        "workbench":
            return int(counts.get("workbench", 0)) > 0
        "craft_wood_block":
            return int(totals.get("woodBlock", 0)) >= 4
        "woodenPickaxe":
            return int(totals.get("woodenPickaxe", 0)) > 0 or int(totals.get("stonePickaxe", 0)) > 0 or int(totals.get("copperPickaxe", 0)) > 0 or int(totals.get("ironPickaxe", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "stonePickaxe":
            return int(totals.get("stonePickaxe", 0)) > 0 or int(totals.get("copperPickaxe", 0)) > 0 or int(totals.get("ironPickaxe", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "mineCopper":
            return int(totals.get("copperOre", 0)) > 0 or int(totals.get("copperIngot", 0)) > 0 or int(totals.get("copperPickaxe", 0)) > 0 or int(totals.get("ironPickaxe", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "smeltCopper":
            return int(totals.get("copperIngot", 0)) > 0 or int(totals.get("copperPickaxe", 0)) > 0 or int(totals.get("ironPickaxe", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "craftCopperPickaxe":
            return int(totals.get("copperPickaxe", 0)) > 0 or int(totals.get("ironPickaxe", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "mineIron":
            return int(totals.get("ironOre", 0)) > 0 or int(totals.get("ironIngot", 0)) > 0 or int(totals.get("ironPickaxe", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "smeltIron":
            return int(totals.get("ironIngot", 0)) > 0 or int(totals.get("ironPickaxe", 0)) > 0 or int(totals.get("ironArmor", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "craftIronPickaxe":
            return int(totals.get("ironPickaxe", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "campfire":
            return int(counts.get("campfire", 0)) > 0 or int(counts.get("torch", 0)) > 0 or int(counts.get("wardLantern", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "spikeTrap":
            return int(counts.get("spikeTrap", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "hunt":
            return int(totals.get("rawMeat", 0)) > 0 or int(totals.get("cookedMeat", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "fish":
            return int(totals.get("rawFish", 0)) > 0 or int(totals.get("cookedFish", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "tool":
            return bool(state.get("hasTool", false))
        "ranged":
            return int(totals.get("hunterBow", 0)) > 0 or int(totals.get("ironCrossbow", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "bed":
            return int(totals.get("bed", 0)) > 0 or int(counts.get("bed", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "shelter":
            return float(state.get("shelterComfort", 0.0)) >= 0.62 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "armor":
            return String(equipment.get("body", "")) != "" or int(totals.get("wardArmor", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "accessory":
            return String(equipment.get("accessory", "")) != "" or int(totals.get("trailCharm", 0)) > 0 or int(totals.get("wardAmulet", 0)) > 0 or int(totals.get("surveyLens", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "level":
            return int(state.get("level", 1)) >= 3 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "torch":
            return int(totals.get("torch", 0)) > 0 or int(counts.get("torch", 0)) > 0 or int(counts.get("wardLantern", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "glass":
            return int(totals.get("glass", 0)) >= 2 or int(counts.get("glass", 0)) > 0 or int(counts.get("wardLantern", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "iron":
            return int(totals.get("ironIngot", 0)) > 0 or int(totals.get("ironPickaxe", 0)) > 0 or int(totals.get("ironSword", 0)) > 0 or int(totals.get("ironArmor", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "mine":
            return int(tier_counts.get("mine", 0)) > 0 or int(totals.get("copperOre", 0)) > 0 or int(totals.get("ironOre", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "anvil":
            return int(counts.get("anvil", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "copperGear":
            return int(totals.get("copperAxe", 0)) > 0 or int(totals.get("copperPickaxe", 0)) > 0 or int(totals.get("copperShovel", 0)) > 0 or int(totals.get("copperSword", 0)) > 0 or int(totals.get("copperArmor", 0)) > 0 or String(equipment.get("body", "")) == "copperArmor" or int(counts.get("sanctuaryBeacon", 0)) > 0
        "craft_compass":
            return int(totals.get("compass", 0)) > 0
        "compass":
            return int(totals.get("compass", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "pack":
            return int(state.get("inventorySize", 0)) >= 32 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "biomeSurvey":
            return int(state.get("discoveredBiomes", 0)) >= 4 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "town":
            return int(state.get("discoveredTowns", 0)) > 0
        "landmarkScout":
            return int(state.get("discoveredRuins", 0)) > 0 or int(state.get("discoveredMines", 0)) > 0 or int(state.get("discoveredCamps", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0 or bool(state.get("sanctuaryEstablished", false))
        "enemyCamp":
            return (int(state.get("discoveredCamps", 0)) > 0 and int(hostiles.get("defeated", 0)) >= 2) or int(counts.get("sanctuaryBeacon", 0)) > 0 or bool(state.get("sanctuaryEstablished", false))
        "shrine":
            return int(state.get("discoveredShrines", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0 or bool(state.get("sanctuaryEstablished", false))
        "cookedFood":
            return int(totals.get("cookedBerries", 0)) > 0 or int(totals.get("cookedMeat", 0)) > 0 or int(totals.get("cookedFish", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "nightShard":
            return int(totals.get("nightShard", 0)) >= 2 or int(totals.get("wardLantern", 0)) > 0 or int(counts.get("wardLantern", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "wardTonic":
            return int(totals.get("wardTonic", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "ward":
            return int(totals.get("wardLantern", 0)) > 0 or int(counts.get("wardLantern", 0)) > 0 or int(counts.get("sanctuaryBeacon", 0)) > 0
        "beacon":
            return int(counts.get("sanctuaryBeacon", 0)) > 0
        "riftRaid":
            return int(state.get("beaconRaidStage", 0)) >= 3 or bool(state.get("sanctuaryEstablished", false))
        "riftColossus":
            return int(defeated_variants.get("rift", 0)) > 0 or int(totals.get("riftCore", 0)) > 0 or bool(state.get("sanctuaryEstablished", false))
        "riftAnchor":
            return int(counts.get("riftAnchor", 0)) > 0 or bool(state.get("sanctuaryEstablished", false))
        "sanctuary":
            return bool(state.get("sanctuaryEstablished", false))
    return false

func is_available(objective_id: String, state: Dictionary = {}) -> bool:
    var check_state := state if not state.is_empty() else last_state
    if POST_INTRO_TUTORIAL_OBJECTIVES.has(objective_id):
        return post_intro_objective_available(objective_id, check_state)
    return true

func post_intro_objective_available(objective_id: String, state: Dictionary) -> bool:
    if not intro_followup_unlocked(state):
        return false
    if bool(state.get("sanctuaryEstablished", false)):
        return true
    var tutorial_steps: Dictionary = state.get("tutorialSteps", {})
    if objective_id == "tutorial_mira":
        return true
    if not (bool(tutorial_steps.get("miraMorningBriefing", false)) or bool(state.get("postIntroMiraBriefed", false))):
        return false
    match objective_id:
        "tutorial_niko", "tutorial_food":
            return true
        "tutorial_rowan", "tutorial_gather_logs", "tutorial_make_workbench", "tutorial_make_blocks":
            return bool(tutorial_steps.get("nikoBerries", false))
        "tutorial_sera", "tutorial_weapon":
            return bool(tutorial_steps.get("rowanBlocks", false))
        "tutorial_final_night":
            return bool(tutorial_steps.get("seraWeapon", false))
        "tutorial_ready":
            return bool(tutorial_steps.get("finalNightComplete", false)) or bool(state.get("finalNightComplete", false))
    return true

func intro_followup_unlocked(state: Dictionary) -> bool:
    if state.is_empty():
        return true
    if bool(state.get("sanctuaryEstablished", false)):
        return true
    if not bool(state.get("tutorialStarted", false)):
        return true
    var tutorial_steps: Dictionary = state.get("tutorialSteps", {})
    return bool(tutorial_steps.get("introFirstSleep", false)) or bool(state.get("introBedUsed", false))

func has_weapon(totals: Dictionary) -> bool:
    for item_id in ["woodenSword", "stoneSword", "copperSword", "ironSword", "nightBlade", "hunterBow", "ironCrossbow"]:
        if int(totals.get(item_id, 0)) > 0:
            return true
    return false

func has_axe(totals: Dictionary) -> bool:
    for item_id in ["woodenAxe", "stoneAxe", "copperAxe", "ironAxe"]:
        if int(totals.get(item_id, 0)) > 0:
            return true
    return false

func has_pickaxe(totals: Dictionary) -> bool:
    for item_id in ["woodenPickaxe", "stonePickaxe", "copperPickaxe", "ironPickaxe"]:
        if int(totals.get(item_id, 0)) > 0:
            return true
    return false

func active_objective() -> Dictionary:
    for objective in objectives:
        if not bool(objective.get("completed", false)) and is_available(String(objective.get("id", "")), last_state):
            var copy: Dictionary = objective.duplicate()
            copy["available"] = true
            return copy
    return {}

func all_objectives() -> Array:
    var result := []
    for objective in objectives:
        var copy: Dictionary = objective.duplicate()
        copy["available"] = is_available(String(objective.get("id", "")), last_state)
        result.append(copy)
    return result

func completed_count() -> int:
    var total := 0
    for objective in objectives:
        if bool(objective.get("completed", false)):
            total += 1
    return total
