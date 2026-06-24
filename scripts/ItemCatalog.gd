extends RefCounted
class_name ItemCatalog

const HOTBAR_SIZE := 8
const INVENTORY_SIZE := 24
const MAX_INVENTORY_SIZE := 40
const CRAFTING_RANGE := 7.5

const ITEMS := {
    "workbench": { "label": "Workbench", "texture": "workbench", "stackMax": 8, "tags": ["crafting", "placeable"] },
    "anvil": { "label": "Anvil", "texture": "anvil", "stackMax": 4, "tags": ["crafting", "metalworking", "placeable"] },
    "woodBlock": { "label": "Wood Block", "texture": "wood-block", "stackMax": 64, "tags": ["wood", "block", "placeable"] },
    "stoneBlock": { "label": "Stone Block", "texture": "stone-block", "stackMax": 64, "tags": ["stone", "block", "placeable"] },
    "dirtBlock": { "label": "Dirt Block", "texture": "dirt-block", "stackMax": 64, "tags": ["soil", "block", "placeable"] },
    "cobblestonePath": { "label": "Cobblestone Path", "texture": "cobblestone-path", "stackMax": 64, "tags": ["stone", "path", "placeable"] },
    "door": { "label": "Door", "texture": "door", "stackMax": 16, "tags": ["wood", "structure", "placeable"] },
    "bed": { "label": "Bed", "texture": "bed", "stackMax": 4, "tags": ["wood", "rest", "placeable", "crafting"] },
    "glass": { "label": "Glass", "texture": "glass", "stackMax": 64, "tags": ["glass", "block", "placeable"] },
    "chest": { "label": "Chest", "texture": "chest", "stackMax": 16, "tags": ["storage", "wood", "placeable", "crafting"] },
    "traderStall": { "label": "Trader Stall", "texture": "trader-stall", "stackMax": 1, "tags": ["market", "wood"] },
    "furnace": { "label": "Furnace", "texture": "furnace", "stackMax": 8, "tags": ["smelting", "stone", "placeable", "crafting"] },
    "campfire": { "label": "Campfire", "texture": "campfire", "stackMax": 16, "tags": ["light", "warmth", "wood", "placeable", "crafting"] },
    "torch": { "label": "Torch", "texture": "torch", "stackMax": 32, "tags": ["light", "wood", "placeable", "crafting"] },
    "spikeTrap": { "label": "Spike Trap", "texture": "spike-trap", "stackMax": 16, "tags": ["defense", "wood", "stone", "placeable", "crafting"] },
    "wardLantern": { "label": "Ward Lantern", "texture": "ward-lantern", "stackMax": 8, "tags": ["light", "ward", "placeable", "crafting"] },
    "sanctuaryBeacon": { "label": "Sanctuary Beacon", "texture": "sanctuary-beacon", "stackMax": 1, "tags": ["light", "ward", "endgame", "placeable", "crafting"] },
    "riftAnchor": { "label": "Rift Anchor", "texture": "rift-anchor", "stackMax": 1, "tags": ["light", "ward", "endgame", "placeable", "crafting"] },
    "woodenAxe": { "label": "Wooden Axe", "texture": "wooden-axe", "stackMax": 1, "tags": ["tool", "axe", "wood", "crafting"] },
    "woodenPickaxe": { "label": "Wooden Pickaxe", "texture": "wooden-pickaxe", "stackMax": 1, "tags": ["tool", "pickaxe", "wood", "crafting"] },
    "woodenShovel": { "label": "Wooden Shovel", "texture": "wooden-shovel", "stackMax": 1, "tags": ["tool", "shovel", "wood", "crafting"] },
    "woodenSword": { "label": "Wooden Sword", "texture": "wooden-sword", "stackMax": 1, "tags": ["weapon", "wood", "combat", "crafting"] },
    "fishingRod": { "label": "Fishing Rod", "texture": "fishing-rod", "stackMax": 1, "tags": ["tool", "water", "food", "crafting"] },
    "arrows": { "label": "Arrows", "texture": "arrows", "stackMax": 64, "tags": ["ammo", "combat", "crafting"] },
    "hunterBow": { "label": "Hunter Bow", "texture": "hunter-bow", "stackMax": 1, "tags": ["weapon", "ranged", "wood", "combat", "crafting"], "ranged": { "ammo": "arrows", "damage": 14, "range": 34 } },
    "stoneAxe": { "label": "Stone Axe", "texture": "stone-axe", "stackMax": 1, "tags": ["tool", "axe", "stone", "crafting"] },
    "stonePickaxe": { "label": "Stone Pickaxe", "texture": "stone-pickaxe", "stackMax": 1, "tags": ["tool", "pickaxe", "stone", "crafting"] },
    "stoneShovel": { "label": "Stone Shovel", "texture": "stone-shovel", "stackMax": 1, "tags": ["tool", "shovel", "stone", "crafting"] },
    "stoneSword": { "label": "Stone Sword", "texture": "stone-sword", "stackMax": 1, "tags": ["weapon", "stone", "combat", "crafting"] },
    "copperAxe": { "label": "Copper Axe", "texture": "copper-axe", "stackMax": 1, "tags": ["tool", "axe", "copper", "crafting"] },
    "copperPickaxe": { "label": "Copper Pickaxe", "texture": "copper-pickaxe", "stackMax": 1, "tags": ["tool", "pickaxe", "copper", "crafting"] },
    "copperShovel": { "label": "Copper Shovel", "texture": "copper-shovel", "stackMax": 1, "tags": ["tool", "shovel", "copper", "crafting"] },
    "copperSword": { "label": "Copper Sword", "texture": "copper-sword", "stackMax": 1, "tags": ["weapon", "copper", "combat", "crafting"] },
    "ironAxe": { "label": "Iron Axe", "texture": "iron-axe", "stackMax": 1, "tags": ["tool", "axe", "iron", "crafting"] },
    "ironPickaxe": { "label": "Iron Pickaxe", "texture": "iron-pickaxe", "stackMax": 1, "tags": ["tool", "pickaxe", "iron", "crafting"] },
    "ironShovel": { "label": "Iron Shovel", "texture": "iron-shovel", "stackMax": 1, "tags": ["tool", "shovel", "iron", "crafting"] },
    "ironSword": { "label": "Iron Sword", "texture": "iron-sword", "stackMax": 1, "tags": ["weapon", "iron", "combat", "crafting"] },
    "ironCrossbow": { "label": "Iron Crossbow", "texture": "iron-crossbow", "stackMax": 1, "tags": ["weapon", "ranged", "iron", "combat", "crafting"], "ranged": { "ammo": "arrows", "damage": 24, "range": 44 } },
    "nightBlade": { "label": "Night Blade", "texture": "night-blade", "stackMax": 1, "tags": ["weapon", "combat", "night", "crafting"] },
    "hideVest": { "label": "Hide Vest", "texture": "hide-vest", "stackMax": 1, "tags": ["armor", "hunting", "cold", "crafting"], "equipment": { "slot": "body", "combatProtection": 0.18, "exposureProtection": 0.22 } },
    "stoneArmor": { "label": "Stone Guard", "texture": "stone-armor", "stackMax": 1, "tags": ["armor", "stone", "combat", "crafting"], "equipment": { "slot": "body", "combatProtection": 0.28, "exposureProtection": 0.12 } },
    "copperArmor": { "label": "Copper Guard", "texture": "copper-armor", "stackMax": 1, "tags": ["armor", "copper", "combat", "crafting"], "equipment": { "slot": "body", "combatProtection": 0.33, "exposureProtection": 0.14 } },
    "ironArmor": { "label": "Iron Guard", "texture": "iron-armor", "stackMax": 1, "tags": ["armor", "iron", "combat", "crafting"], "equipment": { "slot": "body", "combatProtection": 0.38, "exposureProtection": 0.16 } },
    "wardArmor": { "label": "Ward Armor", "texture": "ward-armor", "stackMax": 1, "tags": ["armor", "ward", "combat", "crafting"], "equipment": { "slot": "body", "combatProtection": 0.46, "exposureProtection": 0.34 } },
    "trailCharm": { "label": "Trail Charm", "texture": "trail-charm", "stackMax": 1, "tags": ["accessory", "exploration", "crafting"], "equipment": { "slot": "accessory", "staminaBonus": 15, "hungerBonus": 10 } },
    "wardAmulet": { "label": "Ward Amulet", "texture": "ward-amulet", "stackMax": 1, "tags": ["accessory", "ward", "combat", "crafting"], "equipment": { "slot": "accessory", "combatProtection": 0.12, "exposureProtection": 0.20, "staminaBonus": 10 } },
    "compass": { "label": "Compass", "texture": "compass", "stackMax": 1, "tags": ["navigation", "crafting"] },
    "surveyLens": { "label": "Survey Lens", "texture": "survey-lens", "stackMax": 1, "tags": ["accessory", "navigation", "exploration", "crafting"], "equipment": { "slot": "accessory", "mapRangeBonus": 64, "staminaBonus": 5 } },
    "trailPack": { "label": "Trail Pack", "texture": "trail-pack", "stackMax": 1, "tags": ["upgrade", "storage", "crafting"] },
    "expeditionPack": { "label": "Expedition Pack", "texture": "expedition-pack", "stackMax": 1, "tags": ["upgrade", "storage", "crafting"] },
    "logs": { "label": "Logs", "texture": "logs", "stackMax": 32, "tags": ["wood", "fuel", "crafting"] },
    "stones": { "label": "Stone", "texture": "stones", "stackMax": 48, "tags": ["stone", "crafting"] },
    "dirt": { "label": "Dirt", "texture": "dirt", "stackMax": 64, "tags": ["soil", "block"] },
    "sand": { "label": "Sand", "texture": "sand", "stackMax": 64, "tags": ["sand", "block"] },
    "grass": { "label": "Grass", "texture": "grass", "stackMax": 64, "tags": ["soil", "block"] },
    "mud": { "label": "Mud", "texture": "mud", "stackMax": 64, "tags": ["soil", "block"] },
    "snow": { "label": "Snow", "texture": "snow", "stackMax": 64, "tags": ["snow", "block"] },
    "berries": { "label": "Berries", "texture": "berries", "stackMax": 16, "tags": ["food", "forage"], "food": 24 },
    "cookedBerries": { "label": "Cooked Berries", "texture": "cooked-berries", "stackMax": 16, "tags": ["food", "cooked"], "food": 42 },
    "rawMeat": { "label": "Raw Meat", "texture": "raw-meat", "stackMax": 12, "tags": ["food", "hunting", "cooking"], "food": 16, "health": -4 },
    "cookedMeat": { "label": "Cooked Meat", "texture": "cooked-meat", "stackMax": 12, "tags": ["food", "cooked"], "food": 58, "health": 8, "stamina": 8 },
    "rawFish": { "label": "Raw Fish", "texture": "raw-fish", "stackMax": 12, "tags": ["food", "fishing", "cooking"], "food": 18, "health": -2 },
    "cookedFish": { "label": "Cooked Fish", "texture": "cooked-fish", "stackMax": 12, "tags": ["food", "cooked", "fishing"], "food": 52, "health": 10, "stamina": 10 },
    "hide": { "label": "Hide", "texture": "hide", "stackMax": 24, "tags": ["hunting", "crafting"] },
    "aloe": { "label": "Aloe", "texture": "aloe", "stackMax": 24, "tags": ["food", "forage", "healing"], "food": 6, "health": 14 },
    "mirecap": { "label": "Mirecap", "texture": "mirecap", "stackMax": 24, "tags": ["food", "forage"], "food": 16, "health": 4 },
    "frostHerb": { "label": "Frost Herb", "texture": "frost-herb", "stackMax": 24, "tags": ["food", "forage", "cold"], "food": 4, "stamina": 24, "warmth": 90 },
    "fieldRation": { "label": "Field Ration", "texture": "field-ration", "stackMax": 12, "tags": ["food", "crafted"], "food": 58, "health": 10, "stamina": 12 },
    "hunterStew": { "label": "Hunter Stew", "texture": "hunter-stew", "stackMax": 8, "tags": ["food", "hunting", "crafted"], "food": 86, "health": 18, "stamina": 18, "warmth": 70 },
    "aloeSalve": { "label": "Aloe Salve", "texture": "aloe-salve", "stackMax": 8, "tags": ["healing", "crafted"], "health": 36, "stamina": 8 },
    "wardTonic": { "label": "Ward Tonic", "texture": "ward-tonic", "stackMax": 8, "tags": ["ward", "healing", "crafted"], "food": 0, "health": 10, "stamina": 12, "warmth": 45, "ward": 120 },
    "copperOre": { "label": "Copper Ore", "texture": "copper-ore", "stackMax": 32, "tags": ["ore", "copper", "smelting"] },
    "ironOre": { "label": "Iron Ore", "texture": "iron-ore", "stackMax": 32, "tags": ["ore", "iron", "smelting"] },
    "copperVein": { "label": "Copper Vein", "texture": "copper-ore", "stackMax": 1, "tags": ["generated", "ore", "copper"] },
    "ironVein": { "label": "Iron Vein", "texture": "iron-ore", "stackMax": 1, "tags": ["generated", "ore", "iron"] },
    "copperIngot": { "label": "Copper Ingot", "texture": "copper-ingot", "stackMax": 24, "tags": ["metal", "copper", "crafting"] },
    "ironIngot": { "label": "Iron Ingot", "texture": "iron-ingot", "stackMax": 24, "tags": ["metal", "iron", "crafting"] },
    "nightShard": { "label": "Night Shard", "texture": "night-shard", "stackMax": 32, "tags": ["combat", "crafting"] },
    "relicFragment": { "label": "Relic Fragment", "texture": "relic-fragment", "stackMax": 24, "tags": ["relic", "exploration", "crafting"] },
    "riftCore": { "label": "Rift Core", "texture": "rift-core", "stackMax": 8, "tags": ["combat", "endgame", "trophy", "crafting"] }
}

const PLACEABLES := {
    "workbench": true,
    "anvil": true,
    "woodBlock": true,
    "stoneBlock": true,
    "dirtBlock": true,
    "cobblestonePath": true,
    "door": true,
    "bed": true,
    "glass": true,
    "chest": true,
    "furnace": true,
    "campfire": true,
    "torch": true,
    "spikeTrap": true,
    "wardLantern": true,
    "sanctuaryBeacon": true,
    "riftAnchor": true
}

const RECIPES := [
    { "id": "workbench", "label": "Workbench", "output": "workbench", "amount": 1, "costs": { "logs": 4 }, "requiresWorkbench": false },
    { "id": "anvil", "label": "Anvil", "output": "anvil", "amount": 1, "costs": { "stones": 8, "copperIngot": 2 }, "requiresWorkbench": true },
    { "id": "woodenAxe", "label": "Wooden Axe", "output": "woodenAxe", "amount": 1, "costs": { "logs": 2 }, "requiresWorkbench": true },
    { "id": "woodenPickaxe", "label": "Wooden Pickaxe", "output": "woodenPickaxe", "amount": 1, "costs": { "logs": 3 }, "requiresWorkbench": true },
    { "id": "woodenShovel", "label": "Wooden Shovel", "output": "woodenShovel", "amount": 1, "costs": { "logs": 1 }, "requiresWorkbench": true },
    { "id": "woodenSword", "label": "Wooden Sword", "output": "woodenSword", "amount": 1, "costs": { "logs": 2 }, "requiresWorkbench": true },
    { "id": "fishingRod", "label": "Fishing Rod", "output": "fishingRod", "amount": 1, "costs": { "logs": 2, "grass": 2 }, "requiresWorkbench": true },
    { "id": "arrows", "label": "Arrows", "output": "arrows", "amount": 8, "costs": { "logs": 1, "stones": 1 }, "requiresWorkbench": true },
    { "id": "hunterBow", "label": "Hunter Bow", "output": "hunterBow", "amount": 1, "costs": { "logs": 3, "grass": 2 }, "requiresWorkbench": true },
    { "id": "hideVest", "label": "Hide Vest", "output": "hideVest", "amount": 1, "costs": { "hide": 4, "grass": 2 }, "requiresWorkbench": true },
    { "id": "stoneAxe", "label": "Stone Axe", "output": "stoneAxe", "amount": 1, "costs": { "logs": 1, "stones": 3 }, "requiresWorkbench": true },
    { "id": "stonePickaxe", "label": "Stone Pickaxe", "output": "stonePickaxe", "amount": 1, "costs": { "logs": 2, "stones": 3 }, "requiresWorkbench": true },
    { "id": "stoneShovel", "label": "Stone Shovel", "output": "stoneShovel", "amount": 1, "costs": { "logs": 1, "stones": 1 }, "requiresWorkbench": true },
    { "id": "stoneSword", "label": "Stone Sword", "output": "stoneSword", "amount": 1, "costs": { "logs": 1, "stones": 2 }, "requiresWorkbench": true },
    { "id": "stoneArmor", "label": "Stone Guard", "output": "stoneArmor", "amount": 1, "costs": { "logs": 2, "stones": 8 }, "requiresWorkbench": true },
    { "id": "copperAxe", "label": "Copper Axe", "output": "copperAxe", "amount": 1, "costs": { "logs": 1, "copperIngot": 3 }, "requiresAnvil": true },
    { "id": "copperPickaxe", "label": "Copper Pickaxe", "output": "copperPickaxe", "amount": 1, "costs": { "logs": 2, "copperIngot": 3 }, "requiresAnvil": true },
    { "id": "copperShovel", "label": "Copper Shovel", "output": "copperShovel", "amount": 1, "costs": { "logs": 1, "copperIngot": 1 }, "requiresAnvil": true },
    { "id": "copperSword", "label": "Copper Sword", "output": "copperSword", "amount": 1, "costs": { "logs": 1, "copperIngot": 2 }, "requiresAnvil": true },
    { "id": "copperArmor", "label": "Copper Guard", "output": "copperArmor", "amount": 1, "costs": { "stoneArmor": 1, "copperIngot": 4 }, "requiresAnvil": true },
    { "id": "ironAxe", "label": "Iron Axe", "output": "ironAxe", "amount": 1, "costs": { "logs": 1, "ironIngot": 3 }, "requiresAnvil": true },
    { "id": "ironPickaxe", "label": "Iron Pickaxe", "output": "ironPickaxe", "amount": 1, "costs": { "logs": 2, "ironIngot": 3, "copperIngot": 1 }, "requiresAnvil": true },
    { "id": "ironShovel", "label": "Iron Shovel", "output": "ironShovel", "amount": 1, "costs": { "logs": 1, "ironIngot": 1 }, "requiresAnvil": true },
    { "id": "ironSword", "label": "Iron Sword", "output": "ironSword", "amount": 1, "costs": { "logs": 1, "ironIngot": 2 }, "requiresAnvil": true },
    { "id": "ironCrossbow", "label": "Iron Crossbow", "output": "ironCrossbow", "amount": 1, "costs": { "logs": 2, "ironIngot": 2, "copperIngot": 1 }, "requiresAnvil": true },
    { "id": "ironArmor", "label": "Iron Guard", "output": "ironArmor", "amount": 1, "costs": { "stoneArmor": 1, "ironIngot": 6 }, "requiresAnvil": true },
    { "id": "woodBlock", "label": "Wood Block", "output": "woodBlock", "amount": 4, "costs": { "logs": 2 }, "requiresWorkbench": true },
    { "id": "stoneBlock", "label": "Stone Block", "output": "stoneBlock", "amount": 3, "costs": { "stones": 3 }, "requiresWorkbench": true },
    { "id": "dirtBlock", "label": "Dirt Block", "output": "dirtBlock", "amount": 2, "costs": { "dirt": 2 }, "requiresWorkbench": true },
    { "id": "cobblestonePath", "label": "Cobblestone Path", "output": "cobblestonePath", "amount": 4, "costs": { "stones": 2 }, "requiresWorkbench": true },
    { "id": "door", "label": "Door", "output": "door", "amount": 1, "costs": { "logs": 2 }, "requiresWorkbench": true },
    { "id": "bed", "label": "Bed", "output": "bed", "amount": 1, "costs": { "logs": 3, "berries": 2 }, "requiresWorkbench": true },
    { "id": "fieldRation", "label": "Field Ration", "output": "fieldRation", "amount": 1, "costs": { "berries": 2, "mirecap": 1, "frostHerb": 1 }, "requiresWorkbench": false },
    { "id": "hunterStew", "label": "Hunter Stew", "output": "hunterStew", "amount": 1, "costs": { "cookedMeat": 1, "berries": 2, "frostHerb": 1 }, "requiresWorkbench": false },
    { "id": "aloeSalve", "label": "Aloe Salve", "output": "aloeSalve", "amount": 1, "costs": { "aloe": 2, "grass": 1 }, "requiresWorkbench": false },
    { "id": "wardTonic", "label": "Ward Tonic", "output": "wardTonic", "amount": 1, "costs": { "aloe": 1, "frostHerb": 1, "nightShard": 1, "glass": 1 }, "requiresAnvil": true },
    { "id": "glass", "label": "Glass", "output": "glass", "amount": 2, "costs": { "sand": 3 }, "requiresWorkbench": true },
    { "id": "compass", "label": "Compass", "output": "compass", "amount": 1, "costs": { "logs": 1, "stones": 2, "glass": 1 }, "requiresWorkbench": true },
    { "id": "surveyLens", "label": "Survey Lens", "output": "surveyLens", "amount": 1, "costs": { "compass": 1, "relicFragment": 3, "glass": 2, "copperIngot": 1 }, "requiresAnvil": true },
    { "id": "trailCharm", "label": "Trail Charm", "output": "trailCharm", "amount": 1, "costs": { "hide": 2, "grass": 3, "copperIngot": 1 }, "requiresWorkbench": true },
    { "id": "wardArmor", "label": "Ward Armor", "output": "wardArmor", "amount": 1, "costs": { "stoneArmor": 1, "nightShard": 4, "glass": 2 }, "requiresAnvil": true },
    { "id": "wardAmulet", "label": "Ward Amulet", "output": "wardAmulet", "amount": 1, "costs": { "trailCharm": 1, "nightShard": 3, "glass": 2, "ironIngot": 1 }, "requiresAnvil": true },
    { "id": "nightBlade", "label": "Night Blade", "output": "nightBlade", "amount": 1, "costs": { "stoneSword": 1, "nightShard": 4, "glass": 2 }, "requiresAnvil": true },
    { "id": "trailPack", "label": "Trail Pack", "output": "trailPack", "amount": 1, "costs": { "logs": 3, "berries": 2, "grass": 4 }, "requiresWorkbench": true, "upgrade": { "inventorySize": 32 } },
    { "id": "expeditionPack", "label": "Expedition Pack", "output": "expeditionPack", "amount": 1, "costs": { "logs": 4, "aloe": 2, "mirecap": 2, "frostHerb": 1, "nightShard": 1 }, "requiresWorkbench": true, "upgrade": { "inventorySize": 40 } },
    { "id": "chest", "label": "Chest", "output": "chest", "amount": 1, "costs": { "logs": 4 }, "requiresWorkbench": true },
    { "id": "furnace", "label": "Furnace", "output": "furnace", "amount": 1, "costs": { "stones": 6 }, "requiresWorkbench": true },
    { "id": "campfire", "label": "Campfire", "output": "campfire", "amount": 1, "costs": { "logs": 2, "stones": 2 }, "requiresWorkbench": false },
    { "id": "torch", "label": "Torch", "output": "torch", "amount": 4, "costs": { "logs": 1, "stones": 1 }, "requiresWorkbench": true },
    { "id": "spikeTrap", "label": "Spike Trap", "output": "spikeTrap", "amount": 2, "costs": { "logs": 2, "stones": 2 }, "requiresWorkbench": true },
    { "id": "wardLantern", "label": "Ward Lantern", "output": "wardLantern", "amount": 1, "costs": { "torch": 1, "glass": 2, "stones": 2, "nightShard": 2 }, "requiresAnvil": true },
    { "id": "sanctuaryBeacon", "label": "Sanctuary Beacon", "output": "sanctuaryBeacon", "amount": 1, "costs": { "wardLantern": 1, "stoneBlock": 4, "glass": 4, "nightShard": 6 }, "requiresAnvil": true },
    { "id": "riftAnchor", "label": "Rift Anchor", "output": "riftAnchor", "amount": 1, "costs": { "riftCore": 1, "wardLantern": 1, "stoneBlock": 4, "glass": 4, "ironIngot": 2 }, "requiresAnvil": true }
]

const MATERIALS := {
    "grass": { "label": "Grass", "hardness": 3, "drop": "grass" },
    "dirt": { "label": "Dirt", "hardness": 4, "drop": "dirt" },
    "sand": { "label": "Sand", "hardness": 3, "drop": "sand" },
    "mud": { "label": "Mud", "hardness": 4, "drop": "mud" },
    "snow": { "label": "Snow", "hardness": 3, "drop": "snow" },
    "stone": { "label": "Stone", "hardness": 10, "drop": "stones", "requiredTool": "pickaxe", "requiredTier": 2 },
    "copperOre": { "label": "Copper Ore", "hardness": 7, "drop": "copperOre", "requiredTool": "pickaxe", "requiredTier": 3 },
    "ironOre": { "label": "Iron Ore", "hardness": 10, "drop": "ironOre", "requiredTool": "pickaxe", "requiredTier": 4 },
    "copperVein": { "label": "Copper Vein", "hardness": 8, "drop": "copperOre", "requiredTool": "pickaxe", "requiredTier": 3 },
    "ironVein": { "label": "Iron Vein", "hardness": 12, "drop": "ironOre", "requiredTool": "pickaxe", "requiredTier": 4 },
    "tree": { "label": "Tree", "hardness": 10, "drop": "logs", "requiredTool": "axe", "requiredTier": 2 },
    "rock": { "label": "Rock", "hardness": 12, "drop": "stones", "requiredTool": "pickaxe", "requiredTier": 2 },
    "wildlife": { "label": "Wildlife", "hardness": 12, "drop": "rawMeat", "requiredTool": "sword", "requiredTier": 2 },
    "berryBush": { "label": "Berry Bush", "hardness": 2, "drop": "berries" },
    "aloePatch": { "label": "Aloe Patch", "hardness": 3, "drop": "aloe" },
    "mushroomCluster": { "label": "Mirecap Cluster", "hardness": 2, "drop": "mirecap" },
    "frostHerbPatch": { "label": "Frost Herb Patch", "hardness": 3, "drop": "frostHerb" },
    "workbench": { "label": "Workbench", "hardness": 7, "drop": "workbench", "requiredTool": "axe", "requiredTier": 2 },
    "anvil": { "label": "Anvil", "hardness": 8, "drop": "anvil", "requiredTool": "pickaxe", "requiredTier": 2 },
    "woodBlock": { "label": "Wood Block", "hardness": 7, "drop": "woodBlock", "requiredTool": "axe", "requiredTier": 2 },
    "stoneBlock": { "label": "Stone Block", "hardness": 12, "drop": "stoneBlock", "requiredTool": "pickaxe", "requiredTier": 2 },
    "dirtBlock": { "label": "Dirt Block", "hardness": 4, "drop": "dirtBlock" },
    "cobblestonePath": { "label": "Cobblestone Path", "hardness": 8, "drop": "cobblestonePath", "requiredTool": "pickaxe", "requiredTier": 2 },
    "door": { "label": "Door", "hardness": 6, "drop": "door", "requiredTool": "axe", "requiredTier": 2 },
    "bed": { "label": "Bed", "hardness": 6, "drop": "bed", "requiredTool": "axe", "requiredTier": 2 },
    "glass": { "label": "Glass", "hardness": 2, "drop": "glass" },
    "chest": { "label": "Chest", "hardness": 6, "drop": "chest", "requiredTool": "axe", "requiredTier": 2 },
    "traderStall": { "label": "Trader Stall", "hardness": 7, "drop": "logs", "requiredTool": "axe", "requiredTier": 2 },
    "furnace": { "label": "Furnace", "hardness": 7, "drop": "furnace", "requiredTool": "pickaxe", "requiredTier": 2 },
    "campfire": { "label": "Campfire", "hardness": 5, "drop": "campfire", "requiredTool": "axe", "requiredTier": 2 },
    "torch": { "label": "Torch", "hardness": 1, "drop": "torch" },
    "spikeTrap": { "label": "Spike Trap", "hardness": 4, "drop": "spikeTrap" },
    "wardLantern": { "label": "Ward Lantern", "hardness": 4, "drop": "wardLantern", "requiredTool": "pickaxe", "requiredTier": 2 },
    "sanctuaryBeacon": { "label": "Sanctuary Beacon", "hardness": 10, "drop": "sanctuaryBeacon", "requiredTool": "pickaxe", "requiredTier": 3 },
    "riftAnchor": { "label": "Rift Anchor", "hardness": 12, "drop": "riftAnchor", "requiredTool": "pickaxe", "requiredTier": 4 }
}

static func item_spec(item_id: String) -> Dictionary:
    return ITEMS.get(item_id, {})

static func label(item_id: String) -> String:
    return item_spec(item_id).get("label", item_id)

static func stack_max(item_id: String) -> int:
    return int(item_spec(item_id).get("stackMax", 1))

static func texture_key(item_id: String) -> String:
    return item_spec(item_id).get("texture", item_id)

static func is_placeable(item_id: String) -> bool:
    return PLACEABLES.has(item_id)

static func material_spec(material_id: String) -> Dictionary:
    return MATERIALS.get(material_id, { "label": label(material_id), "hardness": 1, "drop": material_id })

static func material_label(material_id: String) -> String:
    return material_spec(material_id).get("label", label(material_id))

static func material_drop(material_id: String) -> String:
    return material_spec(material_id).get("drop", material_id)

static func material_hardness(material_id: String) -> int:
    return int(material_spec(material_id).get("hardness", 1))

static func material_required_tool(material_id: String) -> String:
    return String(material_spec(material_id).get("requiredTool", ""))

static func material_required_tier(material_id: String) -> int:
    return int(material_spec(material_id).get("requiredTier", 0))

static func recipe_by_id(recipe_id: String) -> Dictionary:
    for recipe in RECIPES:
        if recipe.get("id", "") == recipe_id:
            return recipe
    return {}
