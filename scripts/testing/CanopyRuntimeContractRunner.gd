extends SceneTree

const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const RegistryScript := preload("res://scripts/visual/VisualAssetRegistry.gd")
const StructureSystemScript := preload("res://scripts/StructureSystem.gd")
const MainScript := preload("res://scripts/Main.gd")

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
    call_deferred("run")

func run() -> void:
    report_path = OS.get_environment("VOXEL_CANOPY_RUNTIME_CONTRACT_REPORT").strip_edges()
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/canopy-runtime-contract.json")
    DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
    var catalog := CatalogScript.new()
    var catalog_ready: bool = catalog.setup()
    var registry := RegistryScript.new()
    var registry_ready: bool = registry.setup(catalog)
    add_result("runtime_catalog_and_registry_publish_mature_canopies", catalog_ready and registry_ready and registry.asset_count() == 39, {
        "catalogReady": catalog_ready,
        "registryReady": registry_ready,
        "assetCount": registry.asset_count(),
        "catalogErrors": catalog.last_errors,
        "registryErrors": registry.last_errors
    })
    test_biome_specs(registry)
    test_old_growth_selection(registry)
    test_physical_tree_contract(registry)
    test_structure_exclusion_and_rng_parity(registry)
    test_removed_tree_save_contract()
    test_integration_firewall()
    finish()

func test_biome_specs(registry) -> void:
    var cases := {
        "forest": ["mature_broadleaf_tree", 11.0, 9.0],
        "taiga": ["mature_conifer_tree", 12.0, 6.0],
        "swamp": ["mature_broadleaf_tree", 9.0, 8.0],
        "savanna": ["mature_savanna_tree", 8.5, 9.5]
    }
    var rows: Array[Dictionary] = []
    var valid := true
    for biome in cases.keys():
        var first: Dictionary = registry.tree_runtime_spec(biome, "canopy-contract:%s" % biome, 4.2)
        var second: Dictionary = registry.tree_runtime_spec(biome, "canopy-contract:%s" % biome, 4.2)
        var expected: Array = cases[biome]
        var row_ok := String(first.family) == String(expected[0]) \
            and float(first.visualHeight) >= float(expected[1]) \
            and float(first.canopyRadius) * 2.0 >= float(expected[2]) \
            and runtime_specs_match(first, second)
        valid = valid and row_ok
        rows.append({"biome": biome, "ok": row_ok, "spec": first})
    var plains: Dictionary = registry.tree_runtime_spec("plains", "canopy-contract:plains", 4.2)
    var plains_open := String(plains.family) in ["broadleaf_tree", "savanna_tree"] and float(plains.visualHeight) < 8.0
    rows.append({"biome": "plains", "ok": plains_open, "spec": plains})
    add_result("wooded_biomes_are_mature_while_plains_remain_open", valid and plains_open, rows)

func test_old_growth_selection(registry) -> void:
    var old_growth_id := ""
    var standard_id := ""
    for index in range(256):
        var prop_id := "old-growth-probe:%d" % index
        var asset_id: String = registry.select_tree_asset_id("forest", prop_id)
        var family := String(registry.asset_record(asset_id).get("family", ""))
        if family == "old_growth_broadleaf_tree" and old_growth_id == "":
            old_growth_id = prop_id
        elif family == "mature_broadleaf_tree" and standard_id == "":
            standard_id = prop_id
        if old_growth_id != "" and standard_id != "":
            break
    var first: Dictionary = registry.tree_runtime_spec("forest", old_growth_id, 4.0) if old_growth_id != "" else {}
    var second: Dictionary = registry.tree_runtime_spec("forest", old_growth_id, 4.0) if old_growth_id != "" else {}
    add_result("old_growth_selection_is_rare_stable_and_seed_keyed", old_growth_id != "" and standard_id != "" and bool(first.get("oldGrowth", false)) and runtime_specs_match(first, second), {
        "oldGrowthPropId": old_growth_id,
        "standardPropId": standard_id,
        "oldGrowthSpec": first
    })

func test_physical_tree_contract(registry) -> void:
    var main = MainScript.new()
    main.set("visual_asset_registry", registry)
    main.set("npc_system", null)
    main.set("structure_system", null)
    var parent := Node3D.new()
    root.add_child(parent)
    var rng := RandomNumberGenerator.new()
    rng.seed = 78123
    var tree = main.call("make_tree", parent, "physical-tree", Vector3.ZERO, "forest", rng)
    var collider := first_collision_shape(tree)
    var shape := collider.shape as CylinderShape3D if collider != null else null
    var trunk_radius := float(tree.get_meta("tree_trunk_radius", 0.0)) if tree != null else 0.0
    var visual_height := float(tree.get_meta("tree_visual_height", 0.0)) if tree != null else 0.0
    var collisions := collision_shape_count(tree)
    var aligned := shape != null \
        and absf(shape.radius - trunk_radius) <= 0.001 \
        and absf(shape.height - visual_height) <= 0.001 \
        and absf(collider.position.y - visual_height * 0.5) <= 0.001
    add_result("manifest_trunk_metrics_drive_one_coherent_static_cylinder", tree != null and aligned and collisions == 1 and String(tree.get_meta("visual_asset_id", "")).begins_with("mature_"), {
        "assetId": tree.get_meta("visual_asset_id", "") if tree != null else "",
        "family": tree.get_meta("tree_family", "") if tree != null else "",
        "visualHeight": visual_height,
        "trunkRadius": trunk_radius,
        "shapeHeight": shape.height if shape != null else 0.0,
        "shapeRadius": shape.radius if shape != null else 0.0,
        "collisionShapeCount": collisions
    })
    parent.queue_free()
    main.free()

func test_structure_exclusion_and_rng_parity(registry) -> void:
    var structures = StructureSystemScript.new()
    structures.reserve_natural_prop_exclusion(10, 10, 4, 4, "canopy-contract-corridor")
    structures.record_structure_terrain_footprint(30, 30, 0.0, 4, 4, 3, "canopy-contract-building", "stone", 0)
    var main = MainScript.new()
    main.set("visual_asset_registry", registry)
    main.set("npc_system", null)
    main.set("structure_system", structures)
    var parent := Node3D.new()
    root.add_child(parent)
    var road_overhang_rng := RandomNumberGenerator.new()
    road_overhang_rng.seed = 49281
    var building_blocked_rng := RandomNumberGenerator.new()
    building_blocked_rng.seed = 49281
    var road_overhang = main.call("make_tree", parent, "exclusion-tree", Vector3.ZERO, "forest", road_overhang_rng, Vector2i(5, 11))
    var building_blocked = main.call("make_tree", parent, "exclusion-tree", Vector3.ZERO, "forest", building_blocked_rng, Vector2i(24, 31))
    var next_road_overhang := road_overhang_rng.randf()
    var next_building_blocked := building_blocked_rng.randf()
    var road_query: bool = structures.blocks_natural_prop_with_separate_margins_at_cell(5, 11, 1, 7)
    var building_query: bool = structures.blocks_natural_prop_with_separate_margins_at_cell(24, 31, 1, 7)
    add_result("tree_exclusion_allows_road_overhang_but_protects_building_crowns_without_rng_reordering", road_overhang != null and building_blocked == null and not road_query and building_query and is_equal_approx(next_road_overhang, next_building_blocked), {
        "roadOverhangAllowed": road_overhang != null,
        "buildingCrownBlocked": building_blocked == null,
        "nextRoadOverhang": next_road_overhang,
        "nextBuildingBlocked": next_building_blocked,
        "roadQuery": road_query,
        "buildingQuery": building_query
    })
    parent.queue_free()
    main.free()

func test_removed_tree_save_contract() -> void:
    var main = MainScript.new()
    main.set("seed_text", "canopy-save-contract")
    main.set("npc_system", null)
    var prop_id := "canopy-save-contract:tree:17,23:4"
    var removed: Dictionary = main.get("removed_props")
    removed[prop_id] = true
    var snapshot: Dictionary = main.call("create_save_snapshot")
    removed.clear()
    main.call("restore_removed_props", snapshot.get("removedProps", []))
    var restored: Dictionary = main.get("removed_props")
    var spawn_source := FileAccess.get_file_as_string("res://scripts/MainPlaytestTools.gd")
    var removal_gate_index := spawn_source.find("if removed_props.has(prop_id):")
    var removal_gate := removal_gate_index >= 0 \
        and spawn_source.substr(removal_gate_index, 96).contains("return")
    add_result("removed_tree_ids_round_trip_and_gate_chunk_respawn", restored.has(prop_id) and removal_gate, {
        "propId": prop_id,
        "snapshotRemovedProps": snapshot.get("removedProps", []),
        "restored": restored.has(prop_id),
        "chunkSpawnRemovalGate": removal_gate
    })
    main.free()

func test_integration_firewall() -> void:
    var tree_source := FileAccess.get_file_as_string("res://scripts/MainPlaytestTools.gd")
    var structure_source := FileAccess.get_file_as_string("res://scripts/StructureSystem.gd")
    var tutorial_source := FileAccess.get_file_as_string("res://scripts/TutorialSystem.gd")
    var generic_notification := tree_source.contains("notify_navigation_prop_created") and tree_source.contains("notify_navigation_prop_removed") == false
    var structure_contract := structure_source.contains("blocks_natural_prop_with_separate_margins_at_cell")
    var tutorial_is_unaware := not tutorial_source.contains("tree_runtime_spec") and not tutorial_source.contains("mature_broadleaf_tree")
    add_result("canopy_uses_generic_prop_notification_and_stays_out_of_tutorial_authority", generic_notification and structure_contract and tutorial_is_unaware, {
        "genericNotification": generic_notification,
        "structureContract": structure_contract,
        "tutorialUnaware": tutorial_is_unaware
    })

func runtime_specs_match(first: Dictionary, second: Dictionary) -> bool:
    return String(first.get("assetId", "")) == String(second.get("assetId", "")) \
        and is_equal_approx(float(first.get("scale", 0.0)), float(second.get("scale", 0.0))) \
        and is_equal_approx(float(first.get("visualHeight", 0.0)), float(second.get("visualHeight", 0.0))) \
        and is_equal_approx(float(first.get("trunkRadius", 0.0)), float(second.get("trunkRadius", 0.0))) \
        and is_equal_approx(float(first.get("canopyRadius", 0.0)), float(second.get("canopyRadius", 0.0)))

func first_collision_shape(node: Node) -> CollisionShape3D:
    if node == null:
        return null
    if node is CollisionShape3D:
        return node as CollisionShape3D
    for child in node.get_children():
        var found := first_collision_shape(child)
        if found != null:
            return found
    return null

func collision_shape_count(node: Node) -> int:
    if node == null:
        return 0
    var count := 1 if node is CollisionShape3D else 0
    for child in node.get_children():
        count += collision_shape_count(child)
    return count

func add_result(name: String, passed: bool, details) -> void:
    results.append({"name": name, "passed": passed, "details": details})
    print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func finish() -> void:
    var failure_count := 0
    for result in results:
        if not bool(result.get("passed", false)):
            failure_count += 1
    var report := {
        "schemaVersion": 1,
        "runnerId": "canopy_runtime_contract",
        "testId": "vox_122_canopy_runtime_contract",
        "finished": true,
        "passed": failure_count == 0,
        "evidenceLevel": "contract",
        "scope": "Mature biome family publication, deterministic archetype/old-growth selection, manifest-scaled tree dimensions, trunk/collision alignment, separate natural-corridor and building-footprint margins, RNG parity, additive removed-tree save restoration, chunk respawn gating, and tutorial authority separation. This is contract evidence, not live visual, harvesting, Continue, or NPC acceptance.",
        "resultCount": results.size(),
        "failureCount": failure_count,
        "results": results
    }
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(report, "  "))
        file.close()
    print(JSON.stringify({"runnerId": report.runnerId, "passed": report.passed, "resultCount": report.resultCount, "failureCount": report.failureCount}, "  "))
    quit(0 if failure_count == 0 else 1)
