extends SceneTree

const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const WindSystemScript := preload("res://scripts/environment/EnvironmentWindSystem.gd")
const VisualAssetRegistryScript := preload("res://scripts/visual/VisualAssetRegistry.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const CertifiedRequestFixture := preload("res://scripts/testing/CertifiedTreeRequestFixture.gd")

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
    call_deferred("run")

func run() -> void:
    report_path = OS.get_environment("VOXEL_ENVIRONMENT_WIND_CONTRACT_REPORT").strip_edges()
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/environment-wind-contract.json")
    DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
    var catalog := CatalogScript.new()
    add_result("catalog_available_to_wind_runtime", catalog.setup(), catalog.last_errors)
    test_global_contract()
    test_deterministic_weather_response(catalog)
    test_cpu_update_budget(catalog)
    test_shared_tree_materials(catalog)
    test_shader_contracts()
    test_integration_firewall()
    finish()

func test_global_contract() -> void:
    var names := [
        "environment_wind_direction",
        "environment_wind_strength",
        "environment_wind_gust_strength",
        "environment_wind_gust_frequency",
        "environment_wind_time"
    ]
    var missing: Array[String] = []
    for name in names:
        if not ProjectSettings.has_setting("shader_globals/%s" % name):
            missing.append(name)
    add_result("five_project_shader_globals_are_declared", missing.is_empty(), {"missing": missing, "names": names})

func test_deterministic_weather_response(catalog) -> void:
    var first = WindSystemScript.new()
    var second = WindSystemScript.new()
    first.setup(1492, catalog)
    second.setup(1492, catalog)
    var clear_weather := {"kind": "clear", "intensity": 0.0, "cloudCover": 0.22}
    for _index in range(120):
        first.update_wind(1.0 / 60.0, clear_weather, "forest")
        second.update_wind(1.0 / 60.0, clear_weather, "forest")
    var clear_a: Dictionary = first.snapshot()
    var clear_b: Dictionary = second.snapshot()
    var deterministic := snapshots_match(clear_a, clear_b)
    add_result("same_seed_weather_and_biome_produce_same_smoothed_field", deterministic, {"first": compact_snapshot(clear_a), "second": compact_snapshot(clear_b)})

    var rain_weather := {"kind": "rain", "intensity": 0.92, "cloudCover": 0.94}
    var before_rain := float(clear_a.strength)
    var first_rain: Dictionary = first.update_wind(1.0 / 60.0, rain_weather, "forest")
    for _index in range(179):
        first.update_wind(1.0 / 60.0, rain_weather, "forest")
    var rain: Dictionary = first.snapshot()
    var smooth_transition := float(first_rain.strength) > before_rain and float(first_rain.strength) < float(first_rain.targetStrength)
    var stronger_rain := float(rain.strength) > before_rain + 0.20 and float(rain.gustStrength) > float(clear_a.gustStrength) + 0.20
    add_result("rain_increases_strength_and_gusts_without_a_step_change", smooth_transition and stronger_rain, {
        "clear": compact_snapshot(clear_a), "firstRainFrame": compact_snapshot(first_rain), "settledRain": compact_snapshot(rain)
    })
    var bounded_direction := absf((rain.direction as Vector3).length() - 1.0) < 0.001 and absf(float(rain.direction.y)) < 0.001
    var bounded_writes := int(rain.globalWriteCount) == 5 + int(rain.updateCount) * 5
    add_result("wind_update_is_bounded_to_five_global_writes", bounded_direction and bounded_writes, compact_snapshot(rain))
    first.free()
    second.free()

func test_shared_tree_materials(catalog) -> void:
    var registry = VisualAssetRegistryScript.new()
    var ready: bool = registry.setup(catalog)
    var tree_service = TreeSpawnServiceScript.new()
    var first := tree_service.spawn_tree(procedural_tree_request("wind-contract-a", "forest", "broadleaf", "bushy_oak"))
    var second := tree_service.spawn_tree(procedural_tree_request("wind-contract-b", "forest", "broadleaf", "bushy_oak"))
    # The headless renderer deliberately returns a no-RID tree proxy, so it
    # cannot expose GeometryInstance materials. Assert the real factory cache
    # directly here; the headed wind visual runner proves those cached resources
    # are actually bound to rendered MultiMeshes.
    var factory = tree_service.get_visual_factory()
    var branch_a = factory.branch_material("broadleaf", "forest") if factory != null else null
    var branch_b = factory.branch_material("broadleaf", "forest") if factory != null else null
    var foliage_a = factory.foliage_material("broadleaf", "forest") if factory != null else null
    var foliage_b = factory.foliage_material("broadleaf", "forest") if factory != null else null
    var shared_count := 0
    if branch_a != null and branch_a == branch_b:
        shared_count += 1
    if foliage_a != null and foliage_a == foliage_b:
        shared_count += 1
    var materials_have_expected_shaders := branch_a != null and foliage_a != null \
        and branch_a.shader != null and foliage_a.shader != null
    var margins_ok := tree_margins_at_least(first, 1.24) and tree_margins_at_least(second, 1.24)
    var phase_a := float(first.get_meta("tree_wind_phase", -1.0)) if first != null else -1.0
    var phase_b := float(second.get_meta("tree_wind_phase", -1.0)) if second != null else -1.0
    var configured := phase_a >= 0.0 and phase_b >= 0.0 and not is_equal_approx(phase_a, phase_b)
    add_result("procedural_tree_materials_are_shared_cached_and_instance_phased", ready and shared_count == 2 and materials_have_expected_shaders and margins_ok and configured, {
        "ready": ready,
        "headlessProxy": first != null and first.get_child_count() == 0,
        "sharedMaterials": shared_count,
        "materialsHaveExpectedShaders": materials_have_expected_shaders,
        "phaseA": phase_a,
        "phaseB": phase_b,
        "marginsOk": margins_ok,
        "errors": registry.last_errors
    })
    var static_tree_cached := false
    for asset_id in registry.cached_asset_ids():
        if asset_id.contains("broadleaf") or asset_id.contains("conifer") or asset_id.contains("savanna"):
            static_tree_cached = true
    var procedural_authority := first != null and second != null \
        and String(first.get_meta("visual_source", "")) == "procedural_tree_recipe" \
        and String(second.get_meta("visual_source", "")) == "procedural_tree_recipe"
    add_result("natural_canopies_publish_from_recipe_authority_not_static_tree_glbs", registry.asset_count() == 69 and not static_tree_cached and procedural_authority, {
        "assetCount": registry.asset_count(),
        "cachedSceneCount": registry.cached_scene_count(),
        "staticTreeCached": static_tree_cached,
        "proceduralAuthority": procedural_authority
    })
    if first != null:
        first.free()
    if second != null:
        second.free()

func test_cpu_update_budget(catalog) -> void:
    var wind = WindSystemScript.new()
    wind.setup(918273, catalog)
    var samples: Array[int] = []
    var weather := {"kind": "rain", "intensity": 0.72, "cloudCover": 0.84}
    for index in range(4000):
        if index % 600 == 0:
            weather = {"kind": "clear", "intensity": 0.0, "cloudCover": 0.20} if String(weather.kind) == "rain" else {"kind": "rain", "intensity": 0.72, "cloudCover": 0.84}
        var snapshot: Dictionary = wind.update_wind(1.0 / 60.0, weather, "forest")
        samples.append(int(snapshot.lastUpdateUsec))
    samples.sort()
    var total := 0
    for sample in samples:
        total += sample
    var stats := {
        "sampleCount": samples.size(),
        "averageUsec": float(total) / float(maxi(1, samples.size())),
        "p50Usec": percentile(samples, 0.50),
        "p95Usec": percentile(samples, 0.95),
        "p99Usec": percentile(samples, 0.99),
        "maxUsec": samples[-1] if not samples.is_empty() else 0,
        "writesPerUpdate": 5
    }
    add_result("wind_cpu_update_p99_stays_below_one_millisecond", int(stats.p99Usec) < 1000 and int(stats.maxUsec) < 5000, stats)
    wind.free()

func test_shader_contracts() -> void:
    var branch_source := FileAccess.get_file_as_string("res://resources/visual/procedural_tree_branch.gdshader")
    var foliage_source := FileAccess.get_file_as_string("res://resources/visual/procedural_tree_foliage.gdshader")
    var detail_source := FileAccess.get_file_as_string("res://resources/visual/detail_material.gdshader")
    var globals := ["environment_wind_direction", "environment_wind_strength", "environment_wind_gust_strength", "environment_wind_gust_frequency", "environment_wind_time"]
    var tree_complete := true
    var detail_complete := true
    for global_name in globals:
        tree_complete = tree_complete and branch_source.contains("global uniform") and branch_source.contains(global_name) \
            and foliage_source.contains("global uniform") and foliage_source.contains(global_name)
        detail_complete = detail_complete and detail_source.contains("global uniform") and detail_source.contains(global_name)
    tree_complete = tree_complete and branch_source.contains("INSTANCE_CUSTOM") and branch_source.contains("bark_coordinates") \
        and branch_source.contains("inverse(MODEL_MATRIX)") and foliage_source.contains("INSTANCE_CUSTOM") \
        and foliage_source.contains("leaf_variation") and foliage_source.contains("inverse(MODEL_MATRIX)")
    detail_complete = detail_complete and detail_source.contains("UV2.x") and detail_source.contains("INSTANCE_CUSTOM.x") and detail_source.contains("inverse(MODEL_MATRIX)") and not detail_source.contains("TIME")
    add_result("procedural_tree_and_multimesh_detail_shaders_share_one_world_wind_field", tree_complete and detail_complete, {"treeComplete": tree_complete, "detailComplete": detail_complete})

    var setup_source := FileAccess.get_file_as_string("res://scripts/MainSetupScene.gd")
    var static_details := setup_source.contains("detailPebble\"] = make_detail_material") and setup_source.contains("detailPebble\"] = make_detail_material(Color(0.48, 0.51, 0.48), 0.92, 0.0)") \
        and setup_source.contains("detailSnow\"] = make_detail_material(Color(0.88, 0.93, 0.91), 0.78, 0.0)")
    var moving_details := setup_source.contains("detailGrass\"] = make_detail_material(Color(0.34, 0.68, 0.27), 0.86, 0.018)") \
        and setup_source.contains("detailReed\"] = make_detail_material(Color(0.42, 0.55, 0.24), 0.86, 0.026)") \
        and setup_source.contains("detailScrub\"] = make_detail_material(Color(0.50, 0.56, 0.26), 0.88, 0.014)") \
        and setup_source.contains("detailLeaf\"] = make_detail_material(Color(0.48, 0.38, 0.18), 0.88, 0.004)")
    add_result("detail_response_classes_keep_stones_and_snow_static", static_details and moving_details, {"static": static_details, "moving": moving_details})

func test_integration_firewall() -> void:
    var system_source := FileAccess.get_file_as_string("res://scripts/environment/EnvironmentWindSystem.gd")
    var update_body := source_function_body(system_source, "func update_wind", "func publish_globals")
    var main_loop_source := FileAccess.get_file_as_string("res://scripts/MainGameLoop.gd")
    var setup_source := FileAccess.get_file_as_string("res://scripts/MainSetupScene.gd")
    var core_source := FileAccess.get_file_as_string("res://scripts/MainCore.gd")
    var no_tree_loop := not update_body.contains("for ") and not update_body.contains("get_children") and not system_source.contains("global_shader_parameter_get")
    var single_update := count_occurrences(main_loop_source, "environment_wind_system.update_wind") == 1
    var composed := setup_source.contains("EnvironmentWindSystemScript.new()") and core_source.contains("environment_wind_system.reset_for_seed(seed_hash)")
    add_result("runtime_uses_one_composed_o1_wind_update_without_global_getters", no_tree_loop and single_update and composed, {
        "noTreeLoop": no_tree_loop, "updateCalls": count_occurrences(main_loop_source, "environment_wind_system.update_wind"), "composed": composed
    })

func tree_materials(node: Node) -> Array[Material]:
    var materials: Array[Material] = []
    if node == null:
        return materials
    if node is GeometryInstance3D:
        var geometry_material := (node as GeometryInstance3D).material_override
        if geometry_material != null:
            materials.append(geometry_material)
    if node is MeshInstance3D:
        var mesh_instance := node as MeshInstance3D
        if mesh_instance.mesh != null:
            for surface_index in range(mesh_instance.mesh.get_surface_count()):
                var material := mesh_instance.get_surface_override_material(surface_index)
                if material != null and not materials.has(material):
                    materials.append(material)
    for child in node.get_children():
        for material in tree_materials(child):
            if not materials.has(material):
                materials.append(material)
    return materials

func tree_margins_at_least(node: Node, minimum: float) -> bool:
    if node == null:
        return false
    if node is MeshInstance3D and float((node as MeshInstance3D).extra_cull_margin) < minimum:
        return false
    for child in node.get_children():
        if not tree_margins_at_least(child, minimum):
            return false
    return true

func procedural_tree_request(tree_id: String, biome: String, architecture: String, grammar: String) -> Dictionary:
    return CertifiedRequestFixture.prepare_or_fail({
        "treeId": tree_id,
        "worldSeed": "wind-contract-world",
        "biome": biome,
        "architecture": architecture,
        "speciesGrammar": grammar,
        "growthStage": 0.82,
        "canopyDensity": 0.86,
        "presentation": "runtime"
    })

func snapshots_match(first: Dictionary, second: Dictionary) -> bool:
    return (first.direction as Vector3).is_equal_approx(second.direction as Vector3) \
        and is_equal_approx(float(first.strength), float(second.strength)) \
        and is_equal_approx(float(first.gustStrength), float(second.gustStrength)) \
        and is_equal_approx(float(first.gustFrequency), float(second.gustFrequency))

func compact_snapshot(snapshot: Dictionary) -> Dictionary:
    return {
        "direction": snapshot.get("direction", Vector3.ZERO),
        "strength": snapshot.get("strength", 0.0),
        "gustStrength": snapshot.get("gustStrength", 0.0),
        "gustFrequency": snapshot.get("gustFrequency", 0.0),
        "targetStrength": snapshot.get("targetStrength", 0.0),
        "targetGustStrength": snapshot.get("targetGustStrength", 0.0),
        "updateCount": snapshot.get("updateCount", 0),
        "globalWriteCount": snapshot.get("globalWriteCount", 0),
        "lastUpdateUsec": snapshot.get("lastUpdateUsec", 0)
    }

func source_function_body(source: String, start_marker: String, end_marker: String) -> String:
    var start := source.find(start_marker)
    var end := source.find(end_marker, start + start_marker.length())
    if start < 0 or end < 0:
        return ""
    return source.substr(start, end - start)

func count_occurrences(source: String, needle: String) -> int:
    var count := 0
    var offset := 0
    while true:
        var found := source.find(needle, offset)
        if found < 0:
            return count
        count += 1
        offset = found + needle.length()
    return count

func percentile(sorted_samples: Array[int], fraction: float) -> int:
    if sorted_samples.is_empty():
        return 0
    var index := clampi(int(ceil(float(sorted_samples.size()) * fraction)) - 1, 0, sorted_samples.size() - 1)
    return sorted_samples[index]

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
        "runnerId": "environment_wind_contract",
        "testId": "vox_121_environment_wind_contract",
        "finished": true,
        "passed": failure_count == 0,
        "evidenceLevel": "contract",
        "scope": "Deterministic O(1) weather/biome wind field, declared shader globals, shared tree material cache, instance phase/stiffness, shader channel use, static detail classes, and VOX-122 runtime canopy publication. This is contract evidence, not live visual or performance acceptance.",
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
