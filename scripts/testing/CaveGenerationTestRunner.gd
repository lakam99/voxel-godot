extends SceneTree

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")

var results: Array[Dictionary] = []
var main: Node3D
var structure_system
var seed := ""

func _init() -> void:
    call_deferred("run")

func run() -> void:
    seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
    if seed == "":
        seed = "atlas-1492"
    OS.set_environment("VOXEL_TEST_SEED", seed)
    main = MAIN_SCENE.instantiate()
    root.add_child(main)
    await wait_frames(90)
    structure_system = main.get("structure_system") if main != null else null
    test_scene_ready()
    test_cave_plan_determinism()
    test_cave_candidate_types()
    test_cave_update_around_generation()
    test_cave_build_blocks_and_book_loot()
    save_report()
    quit(0 if all_passed() else 1)

func test_scene_ready() -> void:
    add_result("cave_scene_ready", main != null and structure_system != null, "main + structure_system present")

func test_cave_plan_determinism() -> void:
    if structure_system == null:
        add_result("cave_plan_determinism", false, "structure system missing")
        return
    var plan_a: Dictionary = structure_system.call("cave_plan_for_region", 2, -1, "cliff", false)
    var plan_b: Dictionary = structure_system.call("cave_plan_for_region", 2, -1, "cliff", false)
    var stable := JSON.stringify(sanitize(plan_a)) == JSON.stringify(sanitize(plan_b))
    add_result(
        "cave_plan_determinism",
        not plan_a.is_empty() and stable,
        "planA=%s planB=%s" % [JSON.stringify(sanitize(plan_a)), JSON.stringify(sanitize(plan_b))]
    )

func test_cave_candidate_types() -> void:
    if structure_system == null:
        add_result("cave_candidate_types", false, "structure system missing")
        return
    var cliff: Dictionary = structure_system.call("find_cave_plan_sample", "cliff", 10, false)
    var underground: Dictionary = structure_system.call("find_cave_plan_sample", "underground", 10, false)
    var cliff_ok := not cliff.is_empty() and String(cliff.get("kind", "")) == "cliff" and float(cliff.get("entranceVariation", 0.0)) >= 1.0
    var underground_ok := not underground.is_empty() and String(underground.get("kind", "")) == "underground"
    add_result(
        "cave_candidate_types",
        cliff_ok and underground_ok,
        "cliff=%s underground=%s" % [JSON.stringify(sanitize_plan_summary(cliff)), JSON.stringify(sanitize_plan_summary(underground))]
    )

func test_cave_update_around_generation() -> void:
    if structure_system == null:
        add_result("cave_update_around_generation", false, "structure system missing")
        return
    cleanup_generated_blocks()
    var snapshot = main.call("snapshot_height_edits") if main.has_method("snapshot_height_edits") else []
    structure_system.call("reset")
    var natural_plan: Dictionary = structure_system.call("find_cave_plan_sample", "", 12, true)
    if natural_plan.is_empty():
        add_result("cave_update_around_generation", true, "seed has no natural cave spawn in focused search radius")
        restore_height_edits(snapshot)
        return
    structure_system.call("update_around", natural_plan.get("entranceCell", Vector2i.ZERO))
    var records: Dictionary = structure_system.call("cave_records_snapshot")
    var found := records.has(String(natural_plan.get("id", "")))
    add_result(
        "cave_update_around_generation",
        found,
        "natural=%s records=%s" % [String(natural_plan.get("id", "")), JSON.stringify(sanitize(records))]
    )
    cleanup_generated_blocks()
    restore_height_edits(snapshot)

func test_cave_build_blocks_and_book_loot() -> void:
    if structure_system == null:
        add_result("cave_build_blocks_and_book_loot", false, "structure system missing")
        return
    cleanup_generated_blocks()
    var snapshot = main.call("snapshot_height_edits") if main.has_method("snapshot_height_edits") else []
    structure_system.call("reset")
    var plan: Dictionary = structure_system.call("find_cave_plan_sample", "cliff", 10, false)
    if plan.is_empty():
        add_result("cave_build_blocks_and_book_loot", false, "no cliff cave plan")
        restore_height_edits(snapshot)
        return
    var contiguous := bool(structure_system.call("cave_plan_is_contiguous", plan))
    var rng := RandomNumberGenerator.new()
    rng.seed = 51093
    structure_system.call("build_cave", plan, rng)
    var summary := cave_block_summary(plan)
    var passed := contiguous \
        and int(summary.get("pathBlocks", 0)) >= int(plan.get("pathLength", 0)) * 3 \
        and int(summary.get("wallBlocks", 0)) >= 16 \
        and int(summary.get("torches", 0)) >= 4 \
        and int(summary.get("finalChests", 0)) == 1 \
        and bool(summary.get("finalChestHasCraftingBook", false)) \
        and int(summary.get("heightEditCells", 0)) >= int(plan.get("pathLength", 0)) * 3
    add_result(
        "cave_build_blocks_and_book_loot",
        passed,
        "contiguous=%s summary=%s plan=%s" % [str(contiguous), JSON.stringify(summary), JSON.stringify(sanitize_plan_summary(plan))]
    )
    cleanup_generated_blocks()
    restore_height_edits(snapshot)

func cave_block_summary(plan: Dictionary) -> Dictionary:
    var blocks_value = main.get("blocks") if main != null else {}
    var blocks: Dictionary = blocks_value if blocks_value is Dictionary else {}
    var path_blocks := 0
    var wall_blocks := 0
    var torches := 0
    var final_chests := 0
    var final_chest_has_book := false
    for block_value in blocks.values():
        var block := block_value as Node
        if block == null or String(block.get_meta("generatedTier", "")) != "cave":
            continue
        var block_type := String(block.get_meta("block_type", ""))
        var role := String(block.get_meta("caveRole", ""))
        if block_type == "cobblestonePath":
            path_blocks += 1
        if role == "wall" or role == "entrance_arch" or role == "ore_vein":
            wall_blocks += 1
        if block_type == "torch":
            torches += 1
        if block_type == "chest" and role == "final_chest":
            final_chests += 1
            final_chest_has_book = final_chest_has_book or chest_has_crafting_book(block)
    var edits_value = main.get("height_edits") if main != null else {}
    var edits: Dictionary = edits_value if edits_value is Dictionary else {}
    return {
        "pathBlocks": path_blocks,
        "wallBlocks": wall_blocks,
        "torches": torches,
        "finalChests": final_chests,
        "finalChestHasCraftingBook": final_chest_has_book,
        "heightEditCells": edits.size(),
        "finalChestCell": vec2i(plan.get("finalChestCell", Vector2i.ZERO))
    }

func chest_has_crafting_book(chest: Node) -> bool:
    if chest == null or not chest.has_meta("storage_slots"):
        return false
    var slots: Array = chest.get_meta("storage_slots")
    for slot in slots:
        if not (slot is Dictionary):
            continue
        var item_id := String(slot.get("item", ""))
        if (item_id.begins_with("craftingBook") or item_id.begins_with("rareBook")) and int(slot.get("count", 0)) > 0:
            return true
    return false

func cleanup_generated_blocks() -> void:
    if main == null:
        return
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return
    var blocks: Dictionary = blocks_value
    for key in blocks.keys().duplicate():
        var block := blocks[key] as Node
        if block != null and bool(block.get_meta("generated", false)):
            block.queue_free()
            blocks.erase(key)

func restore_height_edits(snapshot) -> void:
    if main != null and main.has_method("restore_height_edits"):
        main.call("restore_height_edits", snapshot)

func add_result(name: String, passed: bool, details := "") -> void:
    results.append({
        "name": name,
        "passed": passed,
        "details": details
    })
    print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])

func all_passed() -> bool:
    for result in results:
        if not bool(result.get("passed", false)):
            return false
    return true

func save_report() -> void:
    var report := {
        "schemaVersion": 1,
        "testId": "cave_generation_integration",
        "seed": seed,
        "finished": true,
        "passed": all_passed(),
        "evidenceLevel": "integration",
        "scope": "Procedural cave generator, structure block metadata, terrain shaping, and cave chest loot; not player visual acceptance.",
        "resultCount": results.size(),
        "failureCount": failure_count(),
        "results": results
    }
    var report_path := OS.get_environment("VOXEL_CAVE_GENERATION_REPORT")
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/caves/cave-generation-report.json")
    DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
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

func wait_frames(count: int) -> void:
    for i in range(count):
        await process_frame

func sanitize_plan_summary(plan: Dictionary) -> Dictionary:
    if plan.is_empty():
        return {}
    return {
        "id": String(plan.get("id", "")),
        "kind": String(plan.get("kind", "")),
        "region": vec2i(plan.get("region", Vector2i.ZERO)),
        "entranceCell": vec2i(plan.get("entranceCell", Vector2i.ZERO)),
        "finalChamberCell": vec2i(plan.get("finalChamberCell", Vector2i.ZERO)),
        "finalChestCell": vec2i(plan.get("finalChestCell", Vector2i.ZERO)),
        "pathLength": int(plan.get("pathLength", 0)),
        "chamberRadius": int(plan.get("chamberRadius", 0)),
        "entranceVariation": snappedf(float(plan.get("entranceVariation", 0.0)), 0.001)
    }

func sanitize(value):
    if value is Vector2i:
        return vec2i(value)
    if value is Vector3i:
        return { "x": value.x, "y": value.y, "z": value.z }
    if value is Vector3:
        return { "x": snappedf(value.x, 0.001), "y": snappedf(value.y, 0.001), "z": snappedf(value.z, 0.001) }
    if value is Array:
        var result := []
        for item in value:
            result.append(sanitize(item))
        return result
    if value is Dictionary:
        var result := {}
        for key in value.keys():
            result[String(key)] = sanitize(value[key])
        return result
    return value

func vec2i(value: Vector2i) -> Dictionary:
    return { "x": value.x, "z": value.y }
