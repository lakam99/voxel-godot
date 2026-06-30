extends SceneTree

const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")
const InventorySystemScript := preload("res://scripts/InventorySystem.gd")
const CraftingSystemScript := preload("res://scripts/CraftingSystem.gd")

var results: Array[Dictionary] = []
var inventory
var crafting

func _init() -> void:
    call_deferred("run")

func run() -> void:
    test_default_recipes_locked_until_group_unlocked()
    test_tutorial_repair_group_only_unlocks_repair_recipes()
    test_rowan_and_rescue_unlocks_gate_wood_tools_and_sword()
    test_book_and_rare_groups_gate_post_tutorial_recipes()
    test_crafting_books_unlock_groups_when_read()
    test_crafting_unlock_snapshot_round_trip()
    save_report()
    quit(0 if all_passed() else 1)

func setup_system(groups: Array) -> void:
    inventory = InventorySystemScript.new(
        ItemCatalogScript.ITEMS,
        ItemCatalogScript.INVENTORY_SIZE,
        ItemCatalogScript.MAX_INVENTORY_SIZE,
        ItemCatalogScript.HOTBAR_SIZE
    )
    crafting = CraftingSystemScript.new(
        ItemCatalogScript.crafting_recipes(),
        ItemCatalogScript.ITEMS,
        inventory,
        Callable(self, "has_station")
    )
    crafting.reset_unlocks(groups)

func has_station(_station_id: String) -> bool:
    return true

func stock(items: Dictionary) -> void:
    for item_id_variant in items.keys():
        inventory.add_item(String(item_id_variant), int(items[item_id_variant]))

func test_default_recipes_locked_until_group_unlocked() -> void:
    setup_system([])
    stock({ "logs": 8, "stones": 8 })
    var logs_before: int = int(inventory.count("logs"))
    var wood_state: Dictionary = crafting.state_for(crafting.recipe_for("woodBlock"))
    var crafted: bool = bool(crafting.craft("woodBlock"))
    add_result(
        "crafting_gate_default_locks_recipe",
        bool(wood_state.get("unlockLocked", false)) and not crafted and inventory.count("logs") == logs_before,
        "state=%s crafted=%s logs=%d->%d" % [JSON.stringify(wood_state), str(crafted), logs_before, inventory.count("logs")]
    )

func test_tutorial_repair_group_only_unlocks_repair_recipes() -> void:
    setup_system(["tutorial_repair"])
    stock({ "logs": 16, "stones": 8 })
    var wood_state: Dictionary = crafting.state_for(crafting.recipe_for("woodBlock"))
    var torch_state: Dictionary = crafting.state_for(crafting.recipe_for("torch"))
    var axe_state: Dictionary = crafting.state_for(crafting.recipe_for("woodenAxe"))
    var sword_state: Dictionary = crafting.state_for(crafting.recipe_for("woodenSword"))
    var crafted_wood: bool = bool(crafting.craft("woodBlock"))
    var crafted_torch: bool = bool(crafting.craft("torch"))
    var crafted_axe: bool = bool(crafting.craft("woodenAxe"))
    add_result(
        "crafting_gate_tutorial_repair_only",
        not bool(wood_state.get("unlockLocked", true))
            and not bool(torch_state.get("unlockLocked", true))
            and bool(axe_state.get("unlockLocked", false))
            and bool(sword_state.get("unlockLocked", false))
            and crafted_wood
            and crafted_torch
            and not crafted_axe,
        "wood=%s torch=%s axe=%s sword=%s crafted=%s/%s/%s" % [
            JSON.stringify(wood_state),
            JSON.stringify(torch_state),
            JSON.stringify(axe_state),
            JSON.stringify(sword_state),
            str(crafted_wood),
            str(crafted_torch),
            str(crafted_axe)
        ]
    )

func test_rowan_and_rescue_unlocks_gate_wood_tools_and_sword() -> void:
    setup_system(["tutorial_repair", "rowan_basic_tools"])
    stock({ "logs": 16, "stones": 8 })
    var crafted_axe: bool = bool(crafting.craft("woodenAxe"))
    var crafted_pickaxe: bool = bool(crafting.craft("woodenPickaxe"))
    var sword_before: Dictionary = crafting.state_for(crafting.recipe_for("woodenSword"))
    var sword_locked_craft: bool = bool(crafting.craft("woodenSword"))
    crafting.unlock_group("rescue_weapon")
    var sword_after: Dictionary = crafting.state_for(crafting.recipe_for("woodenSword"))
    var sword_unlocked_craft: bool = bool(crafting.craft("woodenSword"))
    add_result(
        "crafting_gate_rowan_then_rescue",
        crafted_axe
            and crafted_pickaxe
            and bool(sword_before.get("unlockLocked", false))
            and not sword_locked_craft
            and not bool(sword_after.get("unlockLocked", true))
            and sword_unlocked_craft,
        "axe=%s pickaxe=%s sword_before=%s locked_craft=%s sword_after=%s unlocked_craft=%s" % [
            str(crafted_axe),
            str(crafted_pickaxe),
            JSON.stringify(sword_before),
            str(sword_locked_craft),
            JSON.stringify(sword_after),
            str(sword_unlocked_craft)
        ]
    )

func test_book_and_rare_groups_gate_post_tutorial_recipes() -> void:
    setup_system(["tutorial_repair", "rowan_basic_tools", "rescue_weapon"])
    stock({ "logs": 24, "stones": 24, "grass": 8, "glass": 8 })
    var stone_before: Dictionary = crafting.state_for(crafting.recipe_for("stonePickaxe"))
    var bow_before: Dictionary = crafting.state_for(crafting.recipe_for("hunterBow"))
    var compass_before: Dictionary = crafting.state_for(crafting.recipe_for("compass"))
    var stone_locked_craft: bool = bool(crafting.craft("stonePickaxe"))
    crafting.unlock_group("book_stone_tools")
    var stone_unlocked_craft: bool = bool(crafting.craft("stonePickaxe"))
    var bow_locked_craft: bool = bool(crafting.craft("hunterBow"))
    crafting.unlock_group("rare_bow")
    var bow_unlocked_craft: bool = bool(crafting.craft("hunterBow"))
    var compass_locked_craft: bool = bool(crafting.craft("compass"))
    crafting.unlock_group("rare_compass")
    var compass_unlocked_craft: bool = bool(crafting.craft("compass"))
    add_result(
        "crafting_gate_books_and_rare_books",
        bool(stone_before.get("unlockLocked", false))
            and bool(bow_before.get("unlockLocked", false))
            and bool(compass_before.get("unlockLocked", false))
            and not stone_locked_craft
            and stone_unlocked_craft
            and not bow_locked_craft
            and bow_unlocked_craft
            and not compass_locked_craft
            and compass_unlocked_craft,
        "stone=%s bow=%s compass=%s crafts=%s/%s/%s/%s/%s/%s" % [
            JSON.stringify(stone_before),
            JSON.stringify(bow_before),
            JSON.stringify(compass_before),
            str(stone_locked_craft),
            str(stone_unlocked_craft),
            str(bow_locked_craft),
            str(bow_unlocked_craft),
            str(compass_locked_craft),
            str(compass_unlocked_craft)
        ]
    )

func test_crafting_books_unlock_groups_when_read() -> void:
    setup_system(["tutorial_repair", "rowan_basic_tools", "rescue_weapon"])
    inventory.restore({
        "slots": [
            { "item": "craftingBookStone", "count": 1 },
            { "item": "logs", "count": 24 },
            { "item": "stones", "count": 24 },
            { "item": "grass", "count": 8 },
            { "item": "rareBookBow", "count": 1 }
        ],
        "size": ItemCatalogScript.INVENTORY_SIZE,
        "selectedSlot": 0
    })
    var stone_before: Dictionary = crafting.state_for(crafting.recipe_for("stonePickaxe"))
    var stone_locked_craft: bool = bool(crafting.craft("stonePickaxe"))
    var read_stone_book: bool = bool(crafting.use_active_unlock_item())
    var stone_book_count := int(inventory.count("craftingBookStone"))
    var stone_after: Dictionary = crafting.state_for(crafting.recipe_for("stonePickaxe"))
    var stone_unlocked_craft: bool = bool(crafting.craft("stonePickaxe"))
    inventory.select(4)
    var bow_before: Dictionary = crafting.state_for(crafting.recipe_for("hunterBow"))
    var read_bow_book: bool = bool(crafting.use_active_unlock_item())
    var bow_book_count := int(inventory.count("rareBookBow"))
    var bow_after: Dictionary = crafting.state_for(crafting.recipe_for("hunterBow"))
    var bow_unlocked_craft: bool = bool(crafting.craft("hunterBow"))
    add_result(
        "crafting_books_unlock_groups_when_read",
        bool(stone_before.get("unlockLocked", false))
            and not stone_locked_craft
            and read_stone_book
            and stone_book_count == 0
            and bool(crafting.has_unlock_group("book_stone_tools"))
            and not bool(stone_after.get("unlockLocked", true))
            and stone_unlocked_craft
            and bool(bow_before.get("unlockLocked", false))
            and read_bow_book
            and bow_book_count == 0
            and bool(crafting.has_unlock_group("rare_bow"))
            and not bool(bow_after.get("unlockLocked", true))
            and bow_unlocked_craft,
        "stone before=%s read=%s count=%d after=%s craft=%s; bow before=%s read=%s count=%d after=%s craft=%s" % [
            JSON.stringify(stone_before),
            str(read_stone_book),
            stone_book_count,
            JSON.stringify(stone_after),
            str(stone_unlocked_craft),
            JSON.stringify(bow_before),
            str(read_bow_book),
            bow_book_count,
            JSON.stringify(bow_after),
            str(bow_unlocked_craft)
        ]
    )

func test_crafting_unlock_snapshot_round_trip() -> void:
    setup_system(["tutorial_repair", "rowan_basic_tools"])
    crafting.unlock_group("rescue_weapon")
    var snapshot: Dictionary = crafting.snapshot()
    setup_system([])
    crafting.restore(snapshot)
    add_result(
        "crafting_gate_snapshot_round_trip",
        bool(crafting.has_unlock_group("tutorial_repair"))
            and bool(crafting.has_unlock_group("rowan_basic_tools"))
            and bool(crafting.has_unlock_group("rescue_weapon"))
            and not bool(crafting.has_unlock_group("book_stone_tools")),
        JSON.stringify(snapshot)
    )

func add_result(name: String, passed: bool, details := "") -> void:
    results.append({
        "name": name,
        "passed": passed,
        "details": details
    })

func all_passed() -> bool:
    for result in results:
        if not bool(result.get("passed", false)):
            return false
    return true

func save_report() -> void:
    var report: Dictionary = {
        "finished": true,
        "passed": all_passed(),
        "evidenceLevel": "contract",
        "scope": "Crafting recipe unlock authority only; not live gameplay acceptance.",
        "resultCount": results.size(),
        "failureCount": failure_count(),
        "results": results
    }
    var report_path: String = OS.get_environment("VOXEL_CRAFTING_GATE_REPORT")
    if report_path == "":
        report_path = "user://crafting-gate-report.json"
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(report, "  "))
        file.close()
    print(JSON.stringify(report, "  "))

func failure_count() -> int:
    var count := 0
    for result in results:
        if not bool(result.get("passed", false)):
            count += 1
    return count
