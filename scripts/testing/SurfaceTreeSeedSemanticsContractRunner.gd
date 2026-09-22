extends SceneTree

## Executes the live tree-request source to freeze its intentionally split seed
## semantics. Family selection uses the raw world seed while ecology uses the
## trimmed/default seed key. Native migration must preserve both operations.

const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const TreeRuntimeRequestBuilderScript := preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_SURFACE_TREE_SEED_SEMANTICS_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/surface-tree-seed-semantics-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var catalog = CatalogScript.new()
	var ready: bool = catalog.setup()
	var profile = catalog.profile_for_biome("plains") as BiomeEnvironmentProfile
	if not ready or profile == null:
		add_result("surface_tree_seed_semantics_catalog_ready", false, {"catalogErrors": catalog.last_errors})
		finish()
		return
	var builder = TreeRuntimeRequestBuilderScript.new()
	verify_whitespace_seed_boundary(builder, profile)
	verify_empty_seed_boundary(builder, profile)
	finish()

func verify_whitespace_seed_boundary(builder, profile: BiomeEnvironmentProfile) -> void:
	var fixture := find_distinct_family_fixture(seed_semantic_profile(profile), "  native-tree-seed-%d  ", false)
	var ok := not fixture.is_empty()
	if ok:
		var raw_seed := String(fixture.rawSeed)
		var normalized_seed := raw_seed.strip_edges()
		var prop_id := String(fixture.propId)
		var cell: Vector2i = fixture.cell
		var raw_production_family := TreeRuntimeRequestBuilderScript.select_tree_family(profile, "plains", prop_id, raw_seed)
		var normalized_production_family := TreeRuntimeRequestBuilderScript.select_tree_family(profile, "plains", prop_id, normalized_seed)
		var raw_ecology: Dictionary = builder.sample_ecology(profile, "plains", prop_id, cell, raw_seed)
		var normalized_ecology: Dictionary = builder.sample_ecology(profile, "plains", prop_id, cell, normalized_seed)
		var request: Dictionary = builder.build(profile, "plains", prop_id, 4.2, cell, raw_seed)
		ok = int(fixture.rawHash) != int(fixture.normalizedHash) \
			and String(fixture.rawFamily) != String(fixture.normalizedFamily) \
			and String(request.get("family", "")) == raw_production_family \
			and ecology_matches(raw_ecology, normalized_ecology) \
			and String(request.get("ageBand", "")) == String(raw_ecology.get("ageBand", "")) \
			and is_equal_approx(float(request.get("ageYears", -1.0)), float(raw_ecology.get("ageYears", -2.0)))
		fixture["rawProductionFamily"] = raw_production_family
		fixture["normalizedProductionFamily"] = normalized_production_family
		fixture["request"] = request
	add_result("surface_tree_family_keeps_raw_whitespace_seed_while_ecology_normalizes_it", ok, fixture)

func verify_empty_seed_boundary(builder, profile: BiomeEnvironmentProfile) -> void:
	var fixture := find_distinct_family_fixture(profile, "", true)
	var ok := not fixture.is_empty()
	if ok:
		var prop_id := String(fixture.propId)
		var cell: Vector2i = fixture.cell
		var empty_ecology: Dictionary = builder.sample_ecology(profile, "plains", prop_id, cell, "")
		var default_ecology: Dictionary = builder.sample_ecology(profile, "plains", prop_id, cell, "default")
		var request: Dictionary = builder.build(profile, "plains", prop_id, 4.2, cell, "")
		ok = String(request.get("family", "")) == String(fixture.rawFamily) \
			and ecology_matches(empty_ecology, default_ecology) \
			and String(request.get("ageBand", "")) == String(empty_ecology.get("ageBand", "")) \
			and is_equal_approx(float(request.get("ageYears", -1.0)), float(empty_ecology.get("ageYears", -2.0)))
		fixture["request"] = request
	add_result("surface_tree_family_keeps_empty_seed_while_ecology_defaults_it", ok, fixture)

func seed_semantic_profile(profile: BiomeEnvironmentProfile) -> BiomeEnvironmentProfile:
	var result := profile.duplicate(true) as BiomeEnvironmentProfile
	result.tree_families = PackedStringArray([
		"ecological_broadleaf_tree_0", "ecological_savanna_tree_1", "ecological_broadleaf_tree_2",
		"ecological_savanna_tree_3", "ecological_broadleaf_tree_4", "ecological_savanna_tree_5",
		"ecological_broadleaf_tree_6"
	])
	return result

func find_distinct_family_fixture(profile: BiomeEnvironmentProfile, seed_format: String, empty_seed: bool) -> Dictionary:
	for index in range(512):
		var raw_seed := "" if empty_seed else seed_format % index
		var normalized_seed := "default" if empty_seed else raw_seed.strip_edges()
		var cell := Vector2i(index * 17 - 301, index * -13 + 97)
		var prop_id := "%s:%d,%d:%d" % [raw_seed, cell.x, cell.y, index]
		var raw_family := TreeRuntimeRequestBuilderScript.select_tree_family(profile, "plains", prop_id, raw_seed)
		var normalized_family := TreeRuntimeRequestBuilderScript.select_tree_family(profile, "plains", prop_id, normalized_seed)
		if raw_family != normalized_family:
			return {
				"rawSeed": raw_seed,
				"normalizedEcologySeed": normalized_seed,
				"propId": prop_id,
				"cell": cell,
				"rawFamily": raw_family,
				"normalizedFamily": normalized_family,
				"rawHash": TreeRuntimeRequestBuilderScript.stable_hash("tree-family:%s:%s:%s" % [raw_seed, "plains", prop_id]),
				"normalizedHash": TreeRuntimeRequestBuilderScript.stable_hash("tree-family:%s:%s:%s" % [normalized_seed, "plains", prop_id]),
			}
	return {}

func ecology_matches(first: Dictionary, second: Dictionary) -> bool:
	for key in ["maturity", "effectiveMaturity", "ageRangeMin", "ageRangeMax", "ageYears", "growthStage", "geneticUnit", "heightGrowth", "girthGrowth", "crownGrowth"]:
		if not is_equal_approx(float(first.get(key, NAN)), float(second.get(key, NAN))):
			return false
	return String(first.get("ageBand", "")) == String(second.get("ageBand", "")) \
		and int(first.get("geneticSeed", 0)) == int(second.get("geneticSeed", 0))

func add_result(name: String, passed: bool, details: Dictionary) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func finish() -> void:
	var failure_count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failure_count += 1
	var report := {
		"schemaVersion": 1,
		"runnerId": "surface_tree_seed_semantics_contract",
		"finished": true,
		"passed": failure_count == 0,
		"evidenceLevel": "contract",
		"scope": "Direct Godot execution of TreeRuntimeRequestBuilder seed semantics. It proves the source's raw-family and normalized-ecology split only; it does not prove native parity, feature publication, or gameplay.",
		"resultCount": results.size(),
		"failureCount": failure_count,
		"results": results,
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	quit(0 if failure_count == 0 else 1)
