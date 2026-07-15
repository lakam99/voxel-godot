extends SceneTree

const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const ProfileScript := preload("res://scripts/environment/BiomeEnvironmentProfile.gd")
const VisualAssetRegistryScript := preload("res://scripts/visual/VisualAssetRegistry.gd")
const WeatherSystemScript := preload("res://scripts/WeatherSystem.gd")

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_BIOME_ENVIRONMENT_CONTRACT_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/biome-environment-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var catalog := CatalogScript.new()
	add_result("catalog_loads_complete_profile_set", catalog.setup() and catalog.profile_count() == 13, {
		"ids": catalog.biome_ids(), "errors": catalog.last_errors
	})
	test_profile_parity(catalog)
	test_detail_parity(catalog)
	test_fallback_and_validation(catalog)
	test_shared_consumer_injection(catalog)
	test_rng_and_source_firewall(catalog)
	finish()

func test_profile_parity(catalog) -> void:
	var expected := {
		"default": [0.02, 0.08, 0.0, 0.0, 0.36, 0.36],
		"ocean": [0.02, 0.08, 0.0, 0.0, 0.72, 0.62],
		"beach": [0.02, 0.08, 0.08, 0.0, 0.56, 0.46],
		"plains": [0.22, 0.16, 0.14, 0.10, 0.36, 0.36],
		"forest": [0.58, 0.12, 0.20, 0.07, 0.68, 0.62],
		"taiga": [0.48, 0.12, 0.13, 0.06, 0.68, 0.62],
		"snow": [0.02, 0.55, 0.12, 0.035, 0.58, 0.58],
		"tundra": [0.02, 0.55, 0.10, 0.045, 0.58, 0.58],
		"alpine": [0.02, 0.55, 0.08, 0.028, 0.58, 0.58],
		"savanna": [0.10, 0.36, 0.12, 0.09, 0.16, 0.28],
		"desert": [0.02, 0.36, 0.10, 0.0, 0.16, 0.28],
		"swamp": [0.26, 0.08, 0.18, 0.035, 0.68, 0.62],
		"town": [0.02, 0.08, 0.0, 0.0, 0.48, 0.44]
	}
	var mismatches: Array[Dictionary] = []
	for biome in expected.keys():
		var profile = catalog.profile_for_biome(String(biome))
		var actual := [profile.tree_chance, profile.rock_base_chance, profile.forage_chance, profile.wildlife_chance, profile.weather_precip, profile.weather_clouds]
		for index in range(actual.size()):
			if not is_equal_approx(float(actual[index]), float(expected[biome][index])):
				mismatches.append({"biome": biome, "index": index, "expected": expected[biome][index], "actual": actual[index]})
	add_result("placement_weather_values_match_pre_catalog_behavior", mismatches.is_empty(), mismatches)

	var asset_expected := {
		"default": [PackedStringArray(["broadleaf_tree"]), 1.0, 1.0],
		"forest": [PackedStringArray(["broadleaf_tree"]), 1.04, 0.94],
		"taiga": [PackedStringArray(["conifer_tree"]), 1.08, 1.0],
		"plains": [PackedStringArray(["broadleaf_tree", "savanna_tree"]), 0.98, 0.95],
		"savanna": [PackedStringArray(["savanna_tree"]), 1.0, 1.04]
	}
	var asset_mismatches: Array[Dictionary] = []
	for biome in asset_expected.keys():
		var profile = catalog.profile_for_biome(String(biome))
		var row: Array = asset_expected[biome]
		if profile.tree_families != row[0] or not is_equal_approx(profile.tree_scale, float(row[1])) or not is_equal_approx(profile.rock_scale, float(row[2])):
			asset_mismatches.append({"biome": biome, "families": profile.tree_families, "treeScale": profile.tree_scale, "rockScale": profile.rock_scale})
	add_result("asset_family_and_scale_values_match_visual_profiles", asset_mismatches.is_empty(), asset_mismatches)

	var forage_expected := {
		"forest": ["berryBush", "berries", 2, 4, 0.56],
		"desert": ["aloePatch", "aloe", 1, 3, 0.48],
		"swamp": ["mushroomCluster", "mirecap", 1, 3, 0.50],
		"taiga": ["frostHerbPatch", "frostHerb", 1, 2, 0.48]
	}
	var forage_mismatches: Array[Dictionary] = []
	for biome in forage_expected.keys():
		var spec: Dictionary = catalog.profile_for_biome(String(biome)).forage_spec()
		var row: Array = forage_expected[biome]
		if String(spec.material) != row[0] or String(spec.drop) != row[1] or int(spec.drop_min) != row[2] or int(spec.drop_max) != row[3] or not is_equal_approx(float(spec.radius), float(row[4])):
			forage_mismatches.append({"biome": biome, "spec": spec})
	add_result("forage_specs_match_pre_catalog_behavior", forage_mismatches.is_empty(), forage_mismatches)

func test_detail_parity(catalog) -> void:
	var cases := [
		["ocean", 11.2, 11.1, 0.30, "reed", 0.36, 0.75, 1.28],
		["ocean", 12.0, 11.1, 0.30, "", 0.0, 0.0, 0.0],
		["beach", 12.0, 11.1, 0.20, "pebble", 0.05, 0.65, 1.35],
		["beach", 12.0, 11.1, 0.60, "reed", 0.34, 0.70, 1.15],
		["beach", 12.0, 11.1, 0.90, "", 0.0, 0.0, 0.0],
		["snow", 30.0, 11.1, 0.20, "snowClump", 0.05, 0.65, 1.35],
		["snow", 30.0, 11.1, 0.80, "pebble", 0.05, 0.55, 1.10],
		["savanna", 24.0, 11.1, 0.20, "scrub", 0.17, 0.65, 1.22],
		["swamp", 15.0, 11.1, 0.70, "grass", 0.19, 0.65, 1.15],
		["forest", 22.0, 11.1, 0.20, "leafLitter", 0.015, 0.70, 1.40],
		["forest", 22.0, 11.1, 0.50, "grass", 0.19, 0.65, 1.20],
		["forest", 22.0, 11.1, 0.90, "flower", 0.15, 0.82, 1.18],
		["plains", 22.0, 11.1, 0.90, "pebble", 0.05, 0.50, 0.95]
	]
	var mismatches: Array[Dictionary] = []
	for row in cases:
		var choice: Dictionary = catalog.detail_choice(row[0], row[1], row[2], row[3])
		if String(choice.get("type", "")) != row[4]:
			mismatches.append({"case": row, "choice": choice})
			continue
		if row[4] != "" and (not is_equal_approx(float(choice.yOffset), float(row[5])) or not is_equal_approx(float(choice.scaleMin), float(row[6])) or not is_equal_approx(float(choice.scaleMax), float(row[7]))):
			mismatches.append({"case": row, "choice": choice})
	add_result("detail_distribution_and_transform_ranges_match_pre_catalog_behavior", mismatches.is_empty(), mismatches)

func test_fallback_and_validation(catalog) -> void:
	var fallback = catalog.profile_for_biome("future_unknown_biome")
	add_result("unknown_biome_uses_explicit_default_profile", fallback == catalog.profile_for_biome("default") and fallback.biome_id == "default", fallback.biome_id)
	var duplicate_catalog := CatalogScript.new()
	var duplicate_ok: bool = duplicate_catalog.setup([
		"res://resources/visual/biomes/default.tres",
		"res://resources/visual/biomes/default.tres"
	])
	add_result("duplicate_biome_is_bounded_structured_error", not duplicate_ok and has_error_code(duplicate_catalog.last_errors, "duplicate_biome_id") and duplicate_catalog.profile_for_biome("unknown") != null, duplicate_catalog.last_errors)
	var missing_catalog := CatalogScript.new()
	var missing_ok: bool = missing_catalog.setup([
		"res://resources/visual/biomes/default.tres",
		"res://resources/visual/biomes/does-not-exist.tres"
	])
	add_result("missing_profile_keeps_explicit_fallback_available", not missing_ok and has_error_code(missing_catalog.last_errors, "missing_or_invalid_profile") and missing_catalog.profile_for_biome("unknown").biome_id == "default", missing_catalog.last_errors)
	var invalid_profile = ProfileScript.new()
	invalid_profile.biome_id = "invalid"
	invalid_profile.detail_thresholds = PackedFloat32Array([0.70, 0.60, 1.0])
	var invalid_result: Dictionary = catalog.validate_profile(invalid_profile, "memory://invalid")
	add_result("invalid_profile_schema_is_structured", not bool(invalid_result.get("ok", true)) and String(invalid_result.get("code", "")) == "invalid_detail_threshold", invalid_result)

func test_shared_consumer_injection(catalog) -> void:
	var registry = VisualAssetRegistryScript.new()
	var registry_ok: bool = registry.setup(catalog)
	var weather = WeatherSystemScript.new()
	weather.setup(null, 1492, catalog)
	add_result("visual_registry_and_weather_share_one_catalog_instance", registry_ok and registry.environment_catalog == catalog and weather.environment_catalog == catalog and registry.profile_for_biome("forest") == catalog.profile_for_biome("forest"), {
		"registryReady": registry_ok,
		"assetErrors": registry.last_errors,
		"profileCount": registry.profile_count()
	})
	weather.free()

func test_rng_and_source_firewall(catalog) -> void:
	var control := RandomNumberGenerator.new()
	var observed := RandomNumberGenerator.new()
	control.seed = 918273
	observed.seed = 918273
	var expected_first := control.randf()
	var expected_second := control.randf()
	var actual_first := observed.randf()
	catalog.profile_for_biome("forest")
	catalog.detail_choice("forest", 20.0, 11.1, 0.50)
	var actual_second := observed.randf()
	add_result("catalog_reads_consume_no_placement_rng", actual_first == expected_first and actual_second == expected_second, {
		"expected": [expected_first, expected_second], "actual": [actual_first, actual_second]
	})
	var main_source := FileAccess.get_file_as_string("res://scripts/Main.gd")
	var detail_source := FileAccess.get_file_as_string("res://scripts/MainPlaytestTools.gd")
	var weather_source := FileAccess.get_file_as_string("res://scripts/WeatherSystem.gd")
	var registry_source := FileAccess.get_file_as_string("res://scripts/visual/VisualAssetRegistry.gd")
	var core_source := FileAccess.get_file_as_string("res://scripts/MainCore.gd")
	var retired := not main_source.contains("func tree_chance(biome: String) -> float:\n\tmatch biome") \
		and not main_source.contains("func forage_chance(biome: String) -> float:\n\tmatch biome") \
		and not detail_source.contains("if biome == \"ocean\"") \
		and not weather_source.contains("func profile_for_biome(biome: String) -> Dictionary") \
		and not registry_source.contains("const PROFILE_PATHS") \
		and core_source.contains("visual_asset_registry.setup(biome_environment_catalog)")
	add_result("duplicate_hardcoded_biome_tables_are_retired", retired, {"retired": retired})

func has_error_code(errors: Array, code: String) -> bool:
	for error_variant in errors:
		if error_variant is Dictionary and String(error_variant.get("code", "")) == code:
			return true
	return false

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
		"runnerId": "biome_environment_catalog_contract",
		"testId": "vox_119_biome_environment_catalog_contract",
		"finished": true,
		"passed": failure_count == 0,
		"evidenceLevel": "contract",
		"scope": "Resource schema, exact pre-catalog values, detail selection, bounded fallback, shared consumer injection, no-RNG reads, and static duplicate-table retirement. This is contract evidence, not live visual acceptance.",
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
