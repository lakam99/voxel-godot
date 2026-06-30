extends RefCounted
class_name StructureLoot

const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")
const CHEST_SIZE := 12

func make_loot_slots(rng: RandomNumberGenerator, tier: String) -> Array:
    var slots := empty_storage_slots()
    var table := loot_table_for(tier)
    var rolls := 3 + rng.randi_range(0, 1)
    if tier == "shrine":
        rolls = 5 + rng.randi_range(0, 2)
    elif tier == "town":
        rolls = 4 + rng.randi_range(0, 2)
    elif tier == "ruin":
        rolls = 2 + rng.randi_range(0, 2)
    elif tier == "camp":
        rolls = 4 + rng.randi_range(0, 2)
    for i in range(rolls):
        var entry := weighted_loot(table, rng)
        var item_id := String(entry.get("item", "stones"))
        var amount := rng.randi_range(int(entry.get("min", 1)), int(entry.get("max", 1)))
        add_loot(slots, item_id, amount)
    if tier == "mine":
        add_loot(slots, "copperOre", 3)
    elif tier == "ruin":
        add_loot(slots, "relicFragment", 1)
    elif tier == "shrine":
        add_loot(slots, "nightShard", 2)
    elif tier == "camp":
        add_loot(slots, "arrows", 8)
        add_loot(slots, "fieldRation", 1)
    return slots

func make_cave_final_loot_slots(rng: RandomNumberGenerator) -> Array:
    var slots := make_loot_slots(rng, "cave")
    add_loot(slots, "craftingBookStone", 1)
    if rng.randf() < 0.18:
        add_loot(slots, rare_crafting_book_for_roll(rng), 1)
    return slots

func empty_storage_slots() -> Array:
    var slots := []
    for i in range(CHEST_SIZE):
        slots.append({ "item": "", "count": 0 })
    return slots

func loot_table_for(tier: String) -> Array:
    if tier == "shrine":
        return [
            { "item": "nightShard", "min": 2, "max": 5, "weight": 5 },
            { "item": "glass", "min": 2, "max": 5, "weight": 4 },
            { "item": "torch", "min": 2, "max": 4, "weight": 3 },
            { "item": "arrows", "min": 8, "max": 18, "weight": 3 },
            { "item": "stoneBlock", "min": 2, "max": 5, "weight": 3 },
            { "item": "cookedBerries", "min": 1, "max": 3, "weight": 2 },
            { "item": "wardTonic", "min": 1, "max": 1, "weight": 2 },
            { "item": "ironIngot", "min": 1, "max": 3, "weight": 2 },
            { "item": "copperIngot", "min": 1, "max": 3, "weight": 2 },
            { "item": "relicFragment", "min": 1, "max": 3, "weight": 2 },
            { "item": "wardLantern", "min": 1, "max": 1, "weight": 1 },
            { "item": "nightBlade", "min": 1, "max": 1, "weight": 1 }
        ]
    if tier == "town":
        return [
            { "item": "logs", "min": 2, "max": 6, "weight": 4 },
            { "item": "stones", "min": 2, "max": 7, "weight": 4 },
            { "item": "berries", "min": 1, "max": 4, "weight": 3 },
            { "item": "hide", "min": 1, "max": 4, "weight": 3 },
            { "item": "cookedMeat", "min": 1, "max": 2, "weight": 2 },
            { "item": "hunterStew", "min": 1, "max": 1, "weight": 2 },
            { "item": "torch", "min": 1, "max": 2, "weight": 2 },
            { "item": "arrows", "min": 6, "max": 16, "weight": 2 },
            { "item": "glass", "min": 1, "max": 3, "weight": 2 },
            { "item": "copperIngot", "min": 1, "max": 2, "weight": 2 },
            { "item": "ironOre", "min": 1, "max": 3, "weight": 1 },
            { "item": "nightShard", "min": 1, "max": 2, "weight": 1 },
            { "item": "hideVest", "min": 1, "max": 1, "weight": 1 },
            { "item": "stoneSword", "min": 1, "max": 1, "weight": 1 }
        ]
    if tier == "mine":
        return [
            { "item": "copperOre", "min": 3, "max": 8, "weight": 5 },
            { "item": "ironOre", "min": 1, "max": 5, "weight": 4 },
            { "item": "stones", "min": 4, "max": 10, "weight": 4 },
            { "item": "torch", "min": 2, "max": 5, "weight": 3 },
            { "item": "copperIngot", "min": 1, "max": 2, "weight": 2 },
            { "item": "arrows", "min": 6, "max": 14, "weight": 2 },
            { "item": "stonePickaxe", "min": 1, "max": 1, "weight": 1 },
            { "item": "copperPickaxe", "min": 1, "max": 1, "weight": 1 }
        ]
    if tier == "cave":
        return [
            { "item": "stones", "min": 5, "max": 12, "weight": 5 },
            { "item": "torch", "min": 2, "max": 5, "weight": 4 },
            { "item": "copperOre", "min": 2, "max": 6, "weight": 4 },
            { "item": "ironOre", "min": 1, "max": 4, "weight": 3 },
            { "item": "fieldRation", "min": 1, "max": 2, "weight": 3 },
            { "item": "cookedBerries", "min": 1, "max": 3, "weight": 2 },
            { "item": "relicFragment", "min": 1, "max": 2, "weight": 2 },
            { "item": "stonePickaxe", "min": 1, "max": 1, "weight": 1 },
            { "item": "craftingBookSurvival", "min": 1, "max": 1, "weight": 1 }
        ]
    if tier == "ruin":
        return [
            { "item": "stones", "min": 3, "max": 10, "weight": 5 },
            { "item": "relicFragment", "min": 1, "max": 3, "weight": 4 },
            { "item": "sand", "min": 3, "max": 8, "weight": 3 },
            { "item": "torch", "min": 1, "max": 2, "weight": 2 },
            { "item": "nightShard", "min": 1, "max": 2, "weight": 2 },
            { "item": "arrows", "min": 5, "max": 14, "weight": 2 },
            { "item": "hide", "min": 1, "max": 3, "weight": 2 },
            { "item": "copperOre", "min": 1, "max": 4, "weight": 2 },
            { "item": "ironOre", "min": 1, "max": 2, "weight": 1 },
            { "item": "stonePickaxe", "min": 1, "max": 1, "weight": 1 },
            { "item": "hunterBow", "min": 1, "max": 1, "weight": 1 },
            { "item": "hunterStew", "min": 1, "max": 1, "weight": 1 },
            { "item": "stoneSword", "min": 1, "max": 1, "weight": 1 }
        ]
    if tier == "camp":
        return [
            { "item": "arrows", "min": 6, "max": 18, "weight": 5 },
            { "item": "torch", "min": 2, "max": 5, "weight": 4 },
            { "item": "fieldRation", "min": 1, "max": 2, "weight": 4 },
            { "item": "cookedMeat", "min": 1, "max": 3, "weight": 3 },
            { "item": "hide", "min": 1, "max": 4, "weight": 3 },
            { "item": "stones", "min": 3, "max": 8, "weight": 3 },
            { "item": "logs", "min": 2, "max": 6, "weight": 3 },
            { "item": "nightShard", "min": 1, "max": 2, "weight": 2 },
            { "item": "spikeTrap", "min": 1, "max": 2, "weight": 2 },
            { "item": "hunterBow", "min": 1, "max": 1, "weight": 1 },
            { "item": "stoneSword", "min": 1, "max": 1, "weight": 1 }
        ]
    return [
        { "item": "logs", "min": 2, "max": 6, "weight": 5 },
        { "item": "stones", "min": 2, "max": 6, "weight": 4 },
        { "item": "berries", "min": 1, "max": 5, "weight": 3 },
        { "item": "arrows", "min": 4, "max": 10, "weight": 2 },
        { "item": "torch", "min": 1, "max": 2, "weight": 2 },
        { "item": "woodenAxe", "min": 1, "max": 1, "weight": 1 },
        { "item": "hunterBow", "min": 1, "max": 1, "weight": 1 },
        { "item": "woodenSword", "min": 1, "max": 1, "weight": 1 }
    ]

func weighted_loot(table: Array, rng: RandomNumberGenerator) -> Dictionary:
    var total := 0.0
    for entry in table:
        total += float(entry.get("weight", 1))
    var roll := rng.randf() * total
    for entry in table:
        roll -= float(entry.get("weight", 1))
        if roll <= 0.0:
            return entry
    return table.back() if not table.is_empty() else { "item": "stones", "min": 1, "max": 1, "weight": 1 }

func rare_crafting_book_for_roll(rng: RandomNumberGenerator) -> String:
    var books := ["rareBookBow", "rareBookCompass", "rareBookMap", "rareBookSurveyLens"]
    return books[rng.randi_range(0, books.size() - 1)]

func add_loot(slots: Array, item_id: String, amount: int) -> void:
    if not ItemCatalogScript.ITEMS.has(item_id) or amount <= 0:
        return
    var remaining := amount
    var stack_max := ItemCatalogScript.stack_max(item_id)
    for slot in slots:
        if String(slot.get("item", "")) != item_id:
            continue
        if int(slot.get("count", 0)) >= stack_max:
            continue
        var moved: int = min(remaining, stack_max - int(slot.get("count", 0)))
        slot["count"] = int(slot.get("count", 0)) + moved
        remaining -= moved
        if remaining <= 0:
            return
    for slot in slots:
        if String(slot.get("item", "")) != "":
            continue
        slot["item"] = item_id
        slot["count"] = min(remaining, stack_max)
        remaining -= int(slot.get("count", 0))
        if remaining <= 0:
            return
