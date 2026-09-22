extends SceneTree

## Verifies the exact legacy RNG consumption retained by the native
## surface-prop baseline. This directly executes tree_visual_spec rather than
## inferring its draw count from source text. It is a source-contract check,
## not visual or gameplay acceptance evidence.

const MainPlaytestToolsScript := preload("res://scripts/MainPlaytestTools.gd")
const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const EXPECTED_DRAWS := {
	"default": 36, "ocean": 36, "beach": 36, "plains": 36,
	"forest": 36, "taiga": 22, "snow": 22, "tundra": 22,
	"alpine": 36, "savanna": 36, "desert": 36, "swamp": 36,
	"town": 36,
}

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_SURFACE_PROP_TREE_RNG_CONTRACT_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/surface-prop-tree-rng-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var tools = MainPlaytestToolsScript.new()
	var catalog = CatalogScript.new()
	var catalog_ready: bool = catalog.setup()
	var ids: Array[String] = catalog.biome_ids() if catalog_ready else []
	add_result("resolved_catalog_matches_frozen_tree_replay_matrix",
		catalog_ready and ids.size() == EXPECTED_DRAWS.size() and ids.all(func(id: String) -> bool: return EXPECTED_DRAWS.has(id)),
		{ "catalogReady": catalog_ready, "biomeIds": ids, "expectedIds": EXPECTED_DRAWS.keys() })
	for biome in ids:
		var expected_draws: int = int(EXPECTED_DRAWS.get(biome, -1))
		verify_tree_visual_spec_consumption(tools, biome, 3 if expected_draws == 22 else 5, expected_draws,
			String(catalog.profile_for_biome(biome).tree_architecture))
	var alpine_profile = catalog.profile_for_biome("alpine") if catalog_ready else null
	add_result("alpine_conifer_architecture_uses_legacy_36_draw_replay",
		alpine_profile != null and String(alpine_profile.tree_architecture) == "conifer" and int(EXPECTED_DRAWS["alpine"]) == 36,
		{ "architecture": String(alpine_profile.tree_architecture) if alpine_profile != null else "", "draws": int(EXPECTED_DRAWS["alpine"]) })
	tools.free()
	finish()

func verify_tree_visual_spec_consumption(tools, biome: String, expected_clumps: int, expected_draws: int, architecture: String) -> void:
	var observed := RandomNumberGenerator.new()
	var oracle := RandomNumberGenerator.new()
	observed.seed = 918273
	oracle.seed = 918273
	var spec: Dictionary = tools.tree_visual_spec(biome, observed)
	var clumps: Array = spec.get("clumps", []) as Array
	# One rotation, one fallback height, six values for the center clump because
	# its spread is the literal 0.0, then seven values per remaining clump.
	for _draw in range(expected_draws):
		oracle.randf()
	var complete_clumps := clumps.size() == expected_clumps
	for clump_value in clumps:
		if not clump_value is Dictionary:
			complete_clumps = false
			continue
		var clump: Dictionary = clump_value
		complete_clumps = complete_clumps \
			and clump.has("radius") and clump.has("position") and clump.has("scale")
	add_result("%s_tree_visual_spec_consumes_%d_shared_pcg_draws" % [biome, expected_draws],
		expected_draws >= 0 and complete_clumps and observed.state == oracle.state, {
			"biome": biome,
			"architecture": architecture,
			"expectedClumps": expected_clumps,
			"actualClumps": clumps.size(),
			"expectedDraws": expected_draws,
			"observedState": observed.state,
			"oracleState": oracle.state,
		})

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
		"runnerId": "surface_prop_tree_rng_compatibility_contract",
		"finished": true,
		"passed": failure_count == 0,
		"evidenceLevel": "contract",
		"scope": "Direct Godot execution of the legacy tree visual RNG consumer. It proves retained shared-PCG draw counts only; it does not prove native feature geometry, publication, or gameplay.",
		"resultCount": results.size(),
		"failureCount": failure_count,
		"results": results,
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	quit(0 if failure_count == 0 else 1)
