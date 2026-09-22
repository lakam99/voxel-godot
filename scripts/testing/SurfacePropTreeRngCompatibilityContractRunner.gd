extends SceneTree

## Verifies the exact legacy RNG consumption retained by the native
## surface-prop baseline. This directly executes tree_visual_spec rather than
## inferring its draw count from source text. It is a source-contract check,
## not visual or gameplay acceptance evidence.

const MainPlaytestToolsScript := preload("res://scripts/MainPlaytestTools.gd")

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
	verify_tree_visual_spec_consumption(tools, "forest", 5, 36)
	verify_tree_visual_spec_consumption(tools, "taiga", 3, 22)
	verify_tree_visual_spec_consumption(tools, "snow", 3, 22)
	tools.free()
	finish()

func verify_tree_visual_spec_consumption(tools, biome: String, expected_clumps: int, expected_draws: int) -> void:
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
		complete_clumps and observed.state == oracle.state, {
			"biome": biome,
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
