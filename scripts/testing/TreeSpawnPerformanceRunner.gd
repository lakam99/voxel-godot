extends SceneTree

## Measures the production TreeSpawnService only.  It intentionally does not
## create terrain, NPCs, or a synthetic world: the report separates pure
## recipe cost from visual publication so a streaming budget can act on the
## actual source of a future hitch.

const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const CertifiedRequestFixture := preload("res://scripts/testing/CertifiedTreeRequestFixture.gd")

const SAMPLE_COUNT := 12

var report_path := ""

func _initialize() -> void:
	call_deferred("run_benchmark")

func run_benchmark() -> void:
	report_path = OS.get_environment("VOXEL_TREE_SPAWN_PERFORMANCE_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/tree-spawn-performance.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var service = TreeSpawnServiceScript.new()
	# Production prewarms immutable shared mesh/material resources during visual
	# registry setup. Benchmark the publication slice after that one-time setup,
	# while recipe construction remains measured separately below.
	service.prewarm_visuals()
	var recipes: Array[int] = []
	var publications: Array[int] = []
	var bole_publications: Array[int] = []
	var distal_publications: Array[int] = []
	var foliage_publications: Array[int] = []
	var family_samples := {}
	for index in range(SAMPLE_COUNT):
		var request := request_for(index)
		var recipe_started := Time.get_ticks_usec()
		var recipe: Dictionary = service.build_recipe(request)
		recipes.append(Time.get_ticks_usec() - recipe_started)
		var publication_started := Time.get_ticks_usec()
		# Queue publication receives the already-built render recipe. Measure that
		# exact main-thread operation before the stage probes allocate their own
		# short-lived visuals, so this remains comparable to prior direct reports.
		var visual: Node3D = service.instantiate_recipe(recipe, String(request.biome), String(request.treeId))
		publications.append(Time.get_ticks_usec() - publication_started)
		if visual != null:
			visual.free()
		var branches := typed_branches(recipe)
		var visual_factory = service.get_visual_factory()
		var bole_started := Time.get_ticks_usec()
		var bole_visual: MeshInstance3D = visual_factory.instantiate_runtime_bole(recipe, branches, String(request.biome))
		bole_publications.append(Time.get_ticks_usec() - bole_started)
		if bole_visual != null:
			bole_visual.free()
		var distal_started := Time.get_ticks_usec()
		var distal_visual: MultiMeshInstance3D = visual_factory.instantiate_runtime_distal_branches(recipe, branches, String(request.biome), String(request.treeId))
		distal_publications.append(Time.get_ticks_usec() - distal_started)
		if distal_visual != null:
			distal_visual.free()
		var foliage_started := Time.get_ticks_usec()
		var foliage_visual: Node3D = visual_factory.instantiate_foliage(recipe, String(request.biome), String(request.treeId)) as Node3D
		foliage_publications.append(Time.get_ticks_usec() - foliage_started)
		if foliage_visual != null:
			foliage_visual.free()
		var family := String(request.get("speciesGrammar", "unknown"))
		if not family_samples.has(family):
			family_samples[family] = {
				"recipeUsec": [], "publicationUsec": [],
				"branchCount": [], "foliageCount": [],
				"sourceBranchCount": [], "sourceFoliageCount": [], "recipePassCount": []
			}
		(family_samples[family].recipeUsec as Array).append(recipes.back())
		(family_samples[family].publicationUsec as Array).append(publications.back())
		(family_samples[family].branchCount as Array).append(int(recipe.get("branchCount", 0)))
		(family_samples[family].foliageCount as Array).append(int(recipe.get("foliageClusterCount", 0)))
		(family_samples[family].sourceBranchCount as Array).append(int(recipe.get("sourceBranchCount", 0)))
		(family_samples[family].sourceFoliageCount as Array).append(int(recipe.get("sourceFoliageClusterCount", 0)))
		(family_samples[family].recipePassCount as Array).append(int(recipe.get("runtimeRecipePassCount", 1)))
	var summary := {
		"runnerId": "tree_spawn_performance",
		"evidenceLevel": "microbenchmark",
		"scope": "Single-threaded production TreeSpawnService recipe and visual-publication measurements. This is diagnostic evidence, not a normal-runtime traversal benchmark.",
		"sampleCount": SAMPLE_COUNT,
		"recipe": timing_stats(recipes),
		"publication": timing_stats(publications),
		"publicationStages": {
			"bole": timing_stats(bole_publications),
			"distal": timing_stats(distal_publications),
			"foliage": timing_stats(foliage_publications)
		},
		"families": summarize_families(family_samples),
		"cache": service.cache_metrics()
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(summary, "  "))
		file.close()
	print(JSON.stringify(summary))
	quit(0)

func request_for(index: int) -> Dictionary:
	var family_index := index % 3
	var architecture := "broadleaf"
	var grammar := "bushy_oak"
	var biome := "forest"
	if family_index == 1:
		architecture = "conifer"
		grammar = "norway_spruce"
		biome = "taiga"
	elif family_index == 2:
		architecture = "savanna"
		grammar = "umbrella_thorn"
		biome = "savanna"
	return CertifiedRequestFixture.prepare_or_fail({
		"treeId": "performance-tree-%02d" % index,
		"worldSeed": "tree-performance-world",
		"biome": biome,
		"architecture": architecture,
		"speciesGrammar": grammar,
		"growthStage": 0.84,
		"canopyDensity": 0.84,
		"presentation": "runtime"
	})

func typed_branches(recipe: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in recipe.get("branches", []):
		if value is Dictionary:
			result.append(value as Dictionary)
	return result

func summarize_families(samples: Dictionary) -> Dictionary:
	var summary := {}
	for family_value in samples.keys():
		var family := String(family_value)
		var row: Dictionary = samples[family]
		summary[family] = {
			"recipe": timing_stats(row.recipeUsec as Array),
			"publication": timing_stats(row.publicationUsec as Array),
		"branchCounts": row.branchCount,
		"foliageCounts": row.foliageCount,
		"sourceBranchCounts": row.sourceBranchCount,
		"sourceFoliageCounts": row.sourceFoliageCount,
		"recipePassCounts": row.recipePassCount
		}
	return summary

func timing_stats(raw: Array) -> Dictionary:
	var samples: Array = raw.duplicate()
	samples.sort()
	var total := 0
	for sample in samples:
		total += sample
	return {
		"averageUsec": float(total) / float(maxi(1, samples.size())),
		"p50Usec": percentile(samples, 0.50),
		"p95Usec": percentile(samples, 0.95),
		"p99Usec": percentile(samples, 0.99),
		"maxUsec": samples.back() if not samples.is_empty() else 0
	}

func percentile(samples: Array, fraction: float) -> int:
	if samples.is_empty():
		return 0
	var index := clampi(int(ceil(float(samples.size()) * fraction)) - 1, 0, samples.size() - 1)
	return samples[index]
