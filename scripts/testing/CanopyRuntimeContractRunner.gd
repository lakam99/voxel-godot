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
    add_result("runtime_catalog_and_registry_publish_age_driven_canopies", catalog_ready and registry_ready and registry.asset_count() == 69, {
        "catalogReady": catalog_ready,
        "registryReady": registry_ready,
        "assetCount": registry.asset_count(),
        "catalogErrors": catalog.last_errors,
        "registryErrors": registry.last_errors
    })
    test_biome_specs(registry)
    test_age_ecology_selection(registry)
    test_age_ecology_seed_and_biome_variation(registry)
    test_shared_scale_safe_bark(registry)
    test_physical_tree_contract(registry)
    test_structure_exclusion_and_rng_parity(registry)
    test_removed_tree_save_contract()
    test_integration_firewall()
    finish()

func test_biome_specs(registry) -> void:
    var cases := {
        "forest": ["ecological_broadleaf_tree", 17.0, 7.0],
        "taiga": ["ecological_conifer_tree", 17.0, 4.0],
        "swamp": ["ecological_broadleaf_tree", 16.0, 7.0],
        "savanna": ["ecological_savanna_tree", 11.0, 8.0]
    }
    var rows: Array[Dictionary] = []
    var valid := true
    for biome in cases.keys():
        var first: Dictionary = registry.tree_runtime_spec(biome, "canopy-contract:%s:40,40" % biome, 4.2, Vector2i(40, 40), "canopy-contract")
        var second: Dictionary = registry.tree_runtime_spec(biome, "canopy-contract:%s:40,40" % biome, 4.2, Vector2i(40, 40), "canopy-contract")
        var expected: Array = cases[biome]
        var row_ok := String(first.family) == String(expected[0]) \
            and float(first.visualHeight) >= float(expected[1]) \
            and float(first.canopyRadius) * 2.0 >= float(expected[2]) \
            and runtime_specs_match(first, second)
        valid = valid and row_ok
        rows.append({"biome": biome, "ok": row_ok, "spec": first})
    var plains: Dictionary = registry.tree_runtime_spec("plains", "canopy-contract:plains:40,40", 4.2, Vector2i(40, 40), "canopy-contract")
    var plains_open := String(plains.family) in ["ecological_broadleaf_tree", "ecological_savanna_tree"] \
        and float(plains.visualHeight) >= 6.5 and float(plains.visualHeight) <= 19.0
    rows.append({"biome": "plains", "ok": plains_open, "spec": plains})
    add_result("biomes_select_ecological_architectures_and_profile_scaled_dimensions", valid and plains_open, rows)

func test_age_ecology_selection(registry) -> void:
    var bands := {}
    var samples: Array[Dictionary] = []
    var established_or_older := 0
    var total := 0
    for z in range(-1200, 1201, 137):
        for x in range(-1200, 1201, 137):
            var cell := Vector2i(x, z)
            var prop_id := "ecology-contract:tree:%d,%d:%d" % [x, z, total]
            var spec: Dictionary = registry.tree_runtime_spec("forest", prop_id, 4.0, cell, "ecology-contract")
            var band := String(spec.get("ageBand", ""))
            bands[band] = int(bands.get(band, 0)) + 1
            if band in ["established", "mature", "old", "ancient"]:
                established_or_older += 1
            if samples.size() < 12:
                samples.append(spec)
            total += 1
    var first: Dictionary = registry.tree_runtime_spec("forest", "ecology-contract:tree:8,8:1", 4.0, Vector2i(8, 8), "ecology-contract")
    var second: Dictionary = registry.tree_runtime_spec("forest", "ecology-contract:tree:8,8:1", 4.0, Vector2i(8, 8), "ecology-contract")
    var adjacent: Dictionary = registry.tree_ecology_spec("forest", "ecology-contract:tree:9,8:2", Vector2i(9, 8), "ecology-contract")
    var continuity := absf(float(first.get("localMaturity", 0.0)) - float(adjacent.get("maturity", 1.0))) < 0.08
    var selected_record: Dictionary = registry.asset_record(String(first.get("assetId", "")))
    var phenotype_matches := String(selected_record.get("treePhenotype", {}).get("ageBand", "")) == String(first.get("ageBand", ""))
    var mature_by_default := total > 0 and float(established_or_older) / float(total) >= 0.72
    add_result("local_maturity_is_continuous_and_age_selects_matching_stable_phenotypes", runtime_specs_match(first, second) and continuity and phenotype_matches and bands.size() >= 3 and mature_by_default, {
        "bandCounts": bands,
        "establishedOrOlderRatio": float(established_or_older) / float(maxi(1, total)),
        "first": first,
        "adjacentEcology": adjacent,
        "continuity": continuity,
        "phenotypeMatches": phenotype_matches,
        "samples": samples,
    })

func test_shared_scale_safe_bark(registry) -> void:
    var shader_source := FileAccess.get_file_as_string("res://resources/visual/tree_wind_material.gdshader")
    var registry_source := FileAccess.get_file_as_string("res://scripts/visual/VisualAssetRegistry.gd")
    var spec: Dictionary = registry.tree_runtime_spec("forest", "bark-contract:tree:12,18:0", 4.0, Vector2i(12, 18), "bark-contract")
    var asset: Dictionary = registry.asset_record(String(spec.get("assetId", "")))
    var bark: Dictionary = asset.get("barkData", {})
    var source_contract := shader_source.contains("UV * bark_scale") \
        and registry_source.contains("tree_wind_material_cache") \
        and registry_source.contains("set_instance_shader_parameter(\"bark_scale\"")
    add_result("shared_shader_uses_branch_uv_and_instance_scale_for_non_smearing_bark", source_contract \
        and String(bark.get("attribute", "")) == "TEXCOORD_0" \
        and is_equal_approx(float(spec.get("barkScale", 0.0)), float(spec.get("scale", -1.0))), {
        "spec": spec,
        "bark": bark,
        "sharedMaterialCount": registry.tree_wind_material_count(),
        "sourceContract": source_contract,
    })

func test_age_ecology_seed_and_biome_variation(registry) -> void:
    var cell := Vector2i(311, -227)
    var first: Dictionary = registry.tree_ecology_spec("forest", "ecology-a:tree:311,-227:1", cell, "ecology-a")
    var same: Dictionary = registry.tree_ecology_spec("forest", "ecology-a:tree:311,-227:1", cell, "ecology-a")
    var sibling: Dictionary = registry.tree_ecology_spec("forest", "ecology-a:tree:311,-227:2", cell, "ecology-a")
    var adjacent: Dictionary = registry.tree_ecology_spec("forest", "ecology-a:tree:312,-227:3", Vector2i(312, -227), "ecology-a")
    var different_seed: Dictionary = registry.tree_ecology_spec("forest", "ecology-b:tree:311,-227:1", cell, "ecology-b")
    var taiga: Dictionary = registry.tree_ecology_spec("taiga", "ecology-a:tree:311,-227:1", cell, "ecology-a")
    var exact_same := is_equal_approx(float(first.get("maturity", -1.0)), float(same.get("maturity", -2.0))) \
        and is_equal_approx(float(first.get("ageYears", -1.0)), float(same.get("ageYears", -2.0))) \
        and int(first.get("geneticSeed", 0)) == int(same.get("geneticSeed", -1)) \
        and String(first.get("ageBand", "")) == String(same.get("ageBand", "missing"))
    var coherent_siblings := is_equal_approx(float(first.get("ageRangeMin", -1.0)), float(sibling.get("ageRangeMin", -2.0))) \
        and is_equal_approx(float(first.get("ageRangeMax", -1.0)), float(sibling.get("ageRangeMax", -2.0))) \
        and not is_equal_approx(float(first.get("ageYears", 0.0)), float(sibling.get("ageYears", 0.0)))
    var boundary_continuous := absf(float(first.get("maturity", 0.0)) - float(adjacent.get("maturity", 1.0))) < 0.08 \
        and absf(float(first.get("ageRangeMin", 0.0)) - float(adjacent.get("ageRangeMin", 1000.0))) < 4.0
    var seed_varies := not is_equal_approx(float(first.get("maturity", 0.0)), float(different_seed.get("maturity", 0.0))) \
        and int(first.get("geneticSeed", 0)) != int(different_seed.get("geneticSeed", 0))
    var biome_varies := String(first.get("architecture", "")) == "broadleaf" \
        and String(taiga.get("architecture", "")) == "conifer" \
        and float(first.get("ageRangeMax", 0.0)) != float(taiga.get("ageRangeMax", 0.0))
    add_result("tree_age_facts_are_seeded_coherent_chunk_continuous_and_biome_specific", exact_same and coherent_siblings and boundary_continuous and seed_varies and biome_varies, {
        "first": first,
        "sibling": sibling,
        "adjacent": adjacent,
        "differentSeed": different_seed,
        "taiga": taiga,
        "exactSame": exact_same,
        "coherentSiblings": coherent_siblings,
        "boundaryContinuous": boundary_continuous,
        "seedVaries": seed_varies,
        "biomeVaries": biome_varies,
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
    add_result("manifest_trunk_metrics_drive_one_coherent_static_cylinder", tree != null and aligned and collisions == 1 and String(tree.get_meta("visual_asset_id", "")).begins_with("ecological_"), {
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
    var tutorial_is_unaware := not tutorial_source.contains("tree_runtime_spec") \
        and not tutorial_source.contains("mature_broadleaf_tree") \
        and not tutorial_source.contains("ecological_broadleaf_tree")
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
        and is_equal_approx(float(first.get("canopyRadius", 0.0)), float(second.get("canopyRadius", 0.0))) \
        and String(first.get("ageBand", "")) == String(second.get("ageBand", "")) \
        and is_equal_approx(float(first.get("ageYears", 0.0)), float(second.get("ageYears", -1.0)))

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
        "testId": "vox_127_130_131_tree_ecology_runtime_contract",
        "finished": true,
        "passed": failure_count == 0,
        "evidenceLevel": "contract",
        "scope": "Continuous deterministic local maturity, age-band phenotype selection, mature-by-default tuning, shared scale-safe bark, manifest-scaled dimensions, trunk/collision alignment, structure exclusion, RNG parity, removed-tree save restoration, chunk respawn gating, and tutorial authority separation. This is contract evidence, not live visual, harvesting, Continue, or NPC acceptance.",
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
