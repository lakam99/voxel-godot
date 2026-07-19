extends SceneTree

const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const RegistryScript := preload("res://scripts/visual/VisualAssetRegistry.gd")
const TreeRuntimeRequestBuilderScript := preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const ProceduralTreeVisualFactoryScript := preload("res://scripts/visual/ProceduralTreeVisualFactory.gd")
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
    add_result("runtime_catalog_and_registry_publish_procedural_tree_authority", catalog_ready and registry_ready and registry.asset_count() == 69 and registry.cached_scene_count() < registry.asset_count(), {
        "catalogReady": catalog_ready,
        "registryReady": registry_ready,
        "assetCount": registry.asset_count(),
        "catalogErrors": catalog.last_errors,
        "registryErrors": registry.last_errors
    })
    test_biome_specs(registry)
    test_registry_independent_runtime_requests(catalog, registry)
    test_biome_parameters_drive_shared_recipe(registry)
    test_age_ecology_selection(registry)
    test_family_age_ecology_coverage(registry)
    test_monumental_upper_age_dimensions(registry)
    test_age_ecology_seed_and_biome_variation(registry)
    test_shared_scale_safe_bark(registry)
    test_runtime_bole_surface_contract(registry)
    test_physical_tree_contract(registry)
    test_monumental_tree_continue_spawn_safety(registry)
    test_structure_exclusion_and_rng_parity(registry)
    test_removed_tree_save_contract()
    test_legacy_save_without_procedural_fields(registry)
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

func test_registry_independent_runtime_requests(catalog, registry) -> void:
    var builder = TreeRuntimeRequestBuilderScript.new()
    var rows: Array[Dictionary] = []
    var valid := true
    for biome in ["forest", "taiga", "savanna", "plains", "beach"]:
        var profile := catalog.profile_for_biome(biome) as BiomeEnvironmentProfile
        for index in range(12):
            var prop_id := "runtime-request-contract:%s:%d,36" % [biome, index]
            var cell := Vector2i(index * 37 - 190, 36)
            var direct: Dictionary = builder.build(profile, biome, prop_id, 4.2, cell, "runtime-request-contract")
            var via_registry: Dictionary = registry.tree_runtime_spec(biome, prop_id, 4.2, cell, "runtime-request-contract")
            var family := String(direct.get("family", ""))
            var expected_architecture := TreeRuntimeRequestBuilderScript.architecture_for_tree_family(family)
            var row_ok := TreeRuntimeRequestBuilderScript.is_procedural_request(direct) \
                and runtime_specs_match(direct, via_registry) \
                and String(direct.get("architecture", "")) == expected_architecture \
                and String((direct.get("biomeParameters", {}) as Dictionary).get("architecture", "")) == expected_architecture
            valid = valid and row_ok
            rows.append({
                "biome": biome,
                "propId": prop_id,
                "family": family,
                "architecture": direct.get("architecture", ""),
                "matchesRegistryAdapter": runtime_specs_match(direct, via_registry),
                "ok": row_ok,
            })
    add_result("runtime_tree_requests_are_registry_independent_and_mixed_biomes_resolve_family_before_grammar", valid, rows)

func test_biome_parameters_drive_shared_recipe(registry) -> void:
    var service = TreeSpawnServiceScript.new()
    var forest_spec: Dictionary = registry.tree_runtime_spec("forest", "biome-request-contract:forest:28,-16", 4.2, Vector2i(28, -16), "biome-request-contract")
    var taiga_spec: Dictionary = registry.tree_runtime_spec("taiga", "biome-request-contract:taiga:28,-16", 4.2, Vector2i(28, -16), "biome-request-contract")
    var forest_request := forest_spec.duplicate(true)
    forest_request["treeId"] = "biome-request-contract:forest:28,-16"
    forest_request["worldSeed"] = "biome-request-contract"
    forest_request["biome"] = "forest"
    forest_request["presentation"] = "runtime"
    var taiga_request := taiga_spec.duplicate(true)
    taiga_request["treeId"] = "biome-request-contract:taiga:28,-16"
    taiga_request["worldSeed"] = "biome-request-contract"
    taiga_request["biome"] = "taiga"
    taiga_request["presentation"] = "runtime"
    var forest_recipe: Dictionary = service.build_recipe(forest_request)
    var taiga_recipe: Dictionary = service.build_recipe(taiga_request)
    var forest_parameters: Dictionary = forest_recipe.get("biomeParameters", {})
    var taiga_parameters: Dictionary = taiga_recipe.get("biomeParameters", {})
    var forest_policy: Dictionary = forest_recipe.get("renderPolicy", {})
    var taiga_policy: Dictionary = taiga_recipe.get("renderPolicy", {})
    var forest_mid_recipe := forest_recipe.duplicate(true)
    forest_mid_recipe["renderLod"] = {"tier": "mid"}
    var forest_visual: Node3D = service.instantiate_recipe(forest_recipe, "forest", String(forest_request.treeId)) as Node3D
    var forest_policy_on_visual := forest_visual != null \
        and is_equal_approx(float(forest_visual.get_meta("tree_visibility_range", 0.0)), float(forest_policy.get("visibilityRange", -1.0))) \
        and is_equal_approx(float(forest_visual.get_meta("tree_shadow_range", 0.0)), float(forest_policy.get("shadowRange", -1.0))) \
        and is_equal_approx(float(forest_visual.get_meta("tree_wind_response", 0.0)), float(forest_policy.get("windResponse", -1.0)))
    var parameterized := int(forest_parameters.get("version", 0)) == 1 \
        and String(forest_parameters.get("biome", "")) == "forest" \
        and String(forest_parameters.get("architecture", "")) == String(forest_recipe.get("architecture", "")) \
        and is_equal_approx(float(forest_parameters.get("canopyDensity", -1.0)), float(forest_recipe.get("canopyDensity", -2.0))) \
        and float(forest_policy.get("visibilityRange", 0.0)) > float(forest_policy.get("shadowRange", 0.0))
    var biome_changes_recipe := String(forest_recipe.get("architecture", "")) == "broadleaf" \
        and String(taiga_recipe.get("architecture", "")) == "conifer" \
        and String(forest_recipe.get("signature", "")) != String(taiga_recipe.get("signature", "")) \
        and not is_equal_approx(float(forest_parameters.get("windResponse", 0.0)), float(taiga_parameters.get("windResponse", 0.0)))
    add_result("biome_snapshot_is_first_class_shared_recipe_input", parameterized and biome_changes_recipe and forest_policy_on_visual, {
        "forestRecipe": {
            "signature": forest_recipe.get("signature", ""),
            "architecture": forest_recipe.get("architecture", ""),
            "parameters": forest_parameters,
            "renderPolicy": forest_policy,
        },
        "taigaRecipe": {
            "signature": taiga_recipe.get("signature", ""),
            "architecture": taiga_recipe.get("architecture", ""),
            "parameters": taiga_parameters,
            "renderPolicy": taiga_policy,
        },
        "recipeUsesBiomeParameters": parameterized,
        "biomeChangesRecipe": biome_changes_recipe,
        "visualReceivesPolicy": forest_policy_on_visual,
    })
    add_result("near_only_shadow_policy_keeps_close_tree_shade_without_mid_distance_shadow_fill", \
        String(forest_policy.get("shadowPolicy", "")) == "near_only" \
        and ProceduralTreeVisualFactoryScript.recipe_casts_shadows(forest_recipe) \
        and not ProceduralTreeVisualFactoryScript.recipe_casts_shadows(forest_mid_recipe), {
        "nearTierCastsShadows": ProceduralTreeVisualFactoryScript.recipe_casts_shadows(forest_recipe),
        "midTierCastsShadows": ProceduralTreeVisualFactoryScript.recipe_casts_shadows(forest_mid_recipe),
        "policy": forest_policy.get("shadowPolicy", "")
    })
    if forest_visual != null:
        forest_visual.free()

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
    var recipe_authority := String(first.get("assetId", "")) == "" \
        and String(first.get("speciesGrammar", "")) != "" \
        and String(first.get("architecture", "")) == "broadleaf"
    var mature_by_default := total > 0 and float(established_or_older) / float(total) >= 0.72
    add_result("local_maturity_is_continuous_and_age_selects_matching_stable_recipes", runtime_specs_match(first, second) and continuity and recipe_authority and bands.size() >= 3 and mature_by_default, {
        "bandCounts": bands,
        "establishedOrOlderRatio": float(established_or_older) / float(maxi(1, total)),
        "first": first,
        "adjacentEcology": adjacent,
        "continuity": continuity,
        "recipeAuthority": recipe_authority,
        "samples": samples,
    })

func test_family_age_ecology_coverage(registry) -> void:
    # Every production family must make mature and old natural specimens
    # attainable from the same deterministic ecology sampler that builds runtime
    # recipes. This is distribution coverage only; the headed interaction matrix
    # separately proves that a naturally placed specimen can be harvested and
    # persisted through Continue.
    var rows: Array[Dictionary] = []
    var valid := true
    for biome in ["forest", "taiga", "savanna"]:
        var bands := {}
        var total := 0
        for z in range(-1200, 1201, 97):
            for x in range(-1200, 1201, 97):
                var cell := Vector2i(x, z)
                var prop_id := "family-age-ecology:%s:%d,%d:%d" % [biome, x, z, total]
                var spec: Dictionary = registry.tree_runtime_spec(biome, prop_id, 4.0, cell, "family-age-ecology")
                var band := String(spec.get("ageBand", ""))
                bands[band] = int(bands.get(band, 0)) + 1
                total += 1
        var mature_count := int(bands.get("mature", 0))
        var old_count := int(bands.get("old", 0))
        var row_ok := mature_count > 0 and old_count > 0
        valid = valid and row_ok
        rows.append({
            "biome": biome,
            "sampleCount": total,
            "bandCounts": bands,
            "matureCount": mature_count,
            "oldCount": old_count,
            "ok": row_ok,
        })
    add_result("all_production_tree_families_expose_mature_and_old_ecology", valid, rows)

func test_monumental_upper_age_dimensions(registry) -> void:
    var largest_by_band := {}
    for z in range(-1200, 1201, 137):
        for x in range(-1200, 1201, 137):
            var prop_id := "monument-contract:tree:%d,%d" % [x, z]
            var spec: Dictionary = registry.tree_runtime_spec("forest", prop_id, 4.0, Vector2i(x, z), "ecology-contract")
            var band := String(spec.get("ageBand", ""))
            if band not in ["mature", "old", "ancient"]:
                continue
            if not largest_by_band.has(band) or float(spec.get("trunkRadius", 0.0)) > float((largest_by_band[band] as Dictionary).get("trunkRadius", 0.0)):
                largest_by_band[band] = spec
    var mature: Dictionary = largest_by_band.get("mature", {})
    var old: Dictionary = largest_by_band.get("old", {})
    var ancient: Dictionary = largest_by_band.get("ancient", {})
    var monumental := not mature.is_empty() and not old.is_empty() and not ancient.is_empty() \
        and float(mature.get("visualHeight", 0.0)) >= 45.0 and float(mature.get("trunkRadius", 0.0)) >= 2.3 \
        and float(old.get("visualHeight", 0.0)) >= 58.0 and float(old.get("trunkRadius", 0.0)) >= 3.5 \
        and float(ancient.get("visualHeight", 0.0)) >= 70.0 and float(ancient.get("trunkRadius", 0.0)) * 2.0 >= 11.0
    add_result("wooded_biome_upper_age_range_contains_screen_filling_landmark_trunks", monumental, {
        "largestByBand": largest_by_band,
        "ancientTrunkDiameter": float(ancient.get("trunkRadius", 0.0)) * 2.0,
    })

func test_shared_scale_safe_bark(registry) -> void:
    var shader_source := FileAccess.get_file_as_string("res://resources/visual/procedural_tree_branch.gdshader")
    var factory_source := FileAccess.get_file_as_string("res://scripts/visual/ProceduralTreeVisualFactory.gd")
    var spec: Dictionary = registry.tree_runtime_spec("forest", "bark-contract:tree:12,18:0", 4.0, Vector2i(12, 18), "bark-contract")
    var source_contract := shader_source.contains("physical_length") \
        and shader_source.contains("bark_coordinates") \
        and factory_source.contains("set_instance_custom_data")
    add_result("procedural_branch_shader_scales_bark_to_physical_segment_length", source_contract \
        and String(spec.get("assetId", "")) == "" \
        and float(spec.get("barkScale", 0.0)) == 1.0, {
        "spec": spec,
        "sourceContract": source_contract,
    })

func test_runtime_bole_surface_contract(registry) -> void:
    # The production tree uses the same recipe service as the PoCs.  Only the
    # base bole is emitted as one connected surface at runtime, since that is
    # the part players inspect closely; higher-order wood remains bounded
    # MultiMesh work.  This is deliberately a topology contract, not a visual
    # acceptance claim.
    var prop_id := "continuous-bole-contract:tree:112,-44:2"
    var spec: Dictionary = registry.tree_runtime_spec("forest", prop_id, 4.2, Vector2i(112, -44), "continuous-bole-contract")
    var visual: Node3D = registry.instantiate_procedural_tree_visual("forest", prop_id, spec, "continuous-bole-contract") as Node3D
    var headless := DisplayServer.get_name().to_lower() == "headless"
    var wood_root: Node = visual.find_child("ProceduralTreeWood", true, false) if visual != null else null
    var bole: Node = visual.find_child("ProceduralTreeContinuousStructuralWood", true, false) if visual != null else null
    var distal: Node = visual.find_child("ProceduralTreeDistalBranches", true, false) if visual != null else null
    var bole_ok := bole is MeshInstance3D \
        and String(bole.get_meta("tree_wood_topology", "")) == "single_generated_wood_graph_without_segment_caps" \
        and not bool(bole.get_meta("tree_wood_uses_cylinder_instances", true))
    var distal_ok := distal is MultiMeshInstance3D \
        and String(distal.get_meta("tree_wood_role", "")) == "instanced_distal_branches"
    var topology_ok := wood_root != null \
        and String(wood_root.get_meta("tree_wood_topology", "")) == "continuous_structural_wood_with_instanced_supported_twigs"
    # The Godot dummy headless renderer intentionally cannot allocate mesh or
    # MultiMesh RIDs. It retains the published logical tree/wood topology for
    # queue and identity contracts; headed canopy release evidence owns the
    # actual continuous-surface/instance visual assertion.
    var headless_proxy_ok := headless and visual != null \
        and int(visual.get_meta("tree_branch_count", 0)) > 0 \
        and topology_ok and bole == null and distal == null
    var headed_geometry_ok := not headless and bole_ok and distal_ok and topology_ok
    add_result("runtime_bole_is_one_continuous_surface_with_bounded_instanced_distal_branches", String(spec.get("assetId", "")) == "" \
        and (headless_proxy_ok or headed_geometry_ok), {
        "renderer": DisplayServer.get_name(),
        "headlessProxy": headless_proxy_ok,
        "runtimeSpecFamily": spec.get("family", ""),
        "structuralWoodRole": bole.get_meta("tree_wood_role", "") if bole != null else "",
        "boleTopology": bole.get_meta("tree_wood_topology", "") if bole != null else "",
        "distalRole": distal.get_meta("tree_wood_role", "") if distal != null else "",
        "rootTopology": wood_root.get_meta("tree_wood_topology", "") if wood_root != null else "",
    })
    if visual != null:
        visual.free()

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
    var collision_height := float(tree.get_meta("tree_collision_height", 0.0)) if tree != null else 0.0
    var collisions := collision_shape_count(tree)
    var aligned := shape != null \
        and absf(shape.radius - trunk_radius) <= 0.001 \
        and absf(shape.height - collision_height) <= 0.001 \
        and absf(collider.position.y - collision_height * 0.5) <= 0.001 \
        and collision_height < visual_height
    add_result("procedural_recipe_drives_one_bounded_non_canopy_collision_trunk", tree != null and aligned and collisions == 1 and String(tree.get_meta("visual_asset_id", "")).begins_with("procedural:"), {
        "assetId": tree.get_meta("visual_asset_id", "") if tree != null else "",
        "family": tree.get_meta("tree_family", "") if tree != null else "",
        "visualHeight": visual_height,
        "collisionHeight": collision_height,
        "trunkRadius": trunk_radius,
        "shapeHeight": shape.height if shape != null else 0.0,
        "shapeRadius": shape.radius if shape != null else 0.0,
        "collisionShapeCount": collisions
    })
    parent.queue_free()
    main.free()

func test_monumental_tree_continue_spawn_safety(registry) -> void:
    var main = MainScript.new()
    main.set("visual_asset_registry", registry)
    main.set("npc_system", null)
    main.set("structure_system", null)
    var parent := Node3D.new()
    root.add_child(parent)
    var active_player := CharacterBody3D.new()
    root.add_child(active_player)
    active_player.global_position = Vector3.ZERO
    main.set("player", active_player)
    var enclosed_rng := RandomNumberGenerator.new()
    enclosed_rng.seed = 28741
    var enclosed = main.call("make_tree", parent, "continue-safety", Vector3.ZERO, "forest", enclosed_rng, Vector2i(44, 44))
    var relocated_position := active_player.global_position
    var enclosed_radius := float(enclosed.get_meta("tree_trunk_radius", 0.0)) if enclosed != null else 0.0
    active_player.global_position = Vector3(100.0, 0.0, 100.0)
    var clear_rng := RandomNumberGenerator.new()
    clear_rng.seed = 28741
    var clear = main.call("make_tree", parent, "continue-safety", Vector3.ZERO, "forest", clear_rng, Vector2i(44, 44))
    var enclosed_next := enclosed_rng.randf()
    var clear_next := clear_rng.randf()
    var relocation_distance := Vector2(relocated_position.x, relocated_position.z).length()
    add_result("monumental_tree_publication_preserves_tree_and_relocates_continue_player", enclosed != null and clear != null and relocation_distance >= enclosed_radius + 0.80 and is_equal_approx(enclosed_next, clear_next), {
        "publishedAtPlayer": enclosed != null,
        "publishedAfterClearance": clear != null,
        "relocatedPlayerPosition": [relocated_position.x, relocated_position.y, relocated_position.z],
        "relocationDistance": relocation_distance,
        "requiredClearance": enclosed_radius + 0.80,
        "rngParityPreserved": is_equal_approx(enclosed_next, clear_next),
    })
    active_player.queue_free()
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
    var road_overhang = main.call("make_tree", parent, "exclusion-tree", Vector3.ZERO, "forest", road_overhang_rng, Vector2i(0, 11))
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

func test_legacy_save_without_procedural_fields(registry) -> void:
    # Procedural topology is immutable seed-derived data, so a save must never
    # require a serialized branch graph to restore the same tree. Model an old
    # save that contains only its stable world seed and mutable removed-prop
    # delta, then rebuild the request twice through the production runtime
    # adapter. This is a focused additive-load contract; the headed canopy
    # release runner separately proves real Save/Continue behavior.
    var world_seed := "legacy-procedural-tree-save"
    var prop_id := "%s:forest:64,-32:7" % world_seed
    var legacy_snapshot := {
        "seed": world_seed,
        "removedProps": ["%s:removed" % prop_id]
    }
    var main = MainScript.new()
    main.set("seed_text", world_seed)
    main.set("npc_system", null)
    main.call("restore_removed_props", legacy_snapshot.get("removedProps", []))
    var first_request: Dictionary = registry.tree_runtime_spec("forest", prop_id, 4.2, Vector2i(64, -32), world_seed)
    var second_request: Dictionary = registry.tree_runtime_spec("forest", prop_id, 4.2, Vector2i(64, -32), world_seed)
    # TreeRuntimeRequestBuilder owns the ecological dimensions. Its production
    # caller owns the stable request identity before TreeSpawnService receives
    # it, so complete that same boundary contract in this direct recipe test.
    first_request["treeId"] = prop_id
    first_request["biome"] = "forest"
    first_request["worldSeed"] = world_seed
    second_request["treeId"] = prop_id
    second_request["biome"] = "forest"
    second_request["worldSeed"] = world_seed
    var service = TreeSpawnServiceScript.new()
    var first_recipe: Dictionary = service.build_recipe(first_request)
    var second_recipe: Dictionary = service.build_recipe(second_request)
    var current_snapshot: Dictionary = main.call("create_save_snapshot")
    var no_serialized_topology := not current_snapshot.has("proceduralTrees") \
        and not current_snapshot.has("treeRecipes") \
        and not current_snapshot.has("treeBranchGraphs")
    var restored_removed: Dictionary = main.get("removed_props")
    var deterministic_rebuild := not first_recipe.is_empty() and not second_recipe.is_empty() \
        and String(first_recipe.get("signature", "")) == String(second_recipe.get("signature", ""))
    add_result("legacy_saves_without_procedural_tree_fields_restore_additively", \
        no_serialized_topology and restored_removed.has("%s:removed" % prop_id) and deterministic_rebuild, {
            "legacyKeys": legacy_snapshot.keys(),
            "currentSnapshotHasSerializedTopology": not no_serialized_topology,
            "removedDeltaRestored": restored_removed.has("%s:removed" % prop_id),
            "recipeSignature": first_recipe.get("signature", ""),
            "deterministicRebuild": deterministic_rebuild
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
        and is_equal_approx(float(first.get("collisionHeight", 0.0)), float(second.get("collisionHeight", 0.0))) \
        and String(first.get("speciesGrammar", "")) == String(second.get("speciesGrammar", "")) \
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
        "scope": "Continuous deterministic local maturity, age-band phenotype selection, monumental upper-age sizing, open-biome height authority, shared scale-safe bark, manifest-scaled dimensions, trunk/collision alignment, deterministic tree-preserving Continue overlap relocation, structure exclusion, RNG parity, removed-tree save restoration, chunk respawn gating, and tutorial authority separation. This is contract evidence, not live visual, harvesting, Continue, or NPC acceptance.",
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
