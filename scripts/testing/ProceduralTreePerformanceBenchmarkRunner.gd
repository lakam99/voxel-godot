extends SceneTree

## VOX-135 diagnostic benchmark.  It measures the production recipe service
## and the staged production publication queue separately; neither half is a
## substitute for a headed traversal observation.

const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const TreePublicationQueueScript := preload("res://scripts/environment/TreePublicationQueue.gd")
# Every cold sample must have a distinct stable tree identity. Repeating one
# request only measures TreeSpawnService's canonical-recipe cache, which is
# useful separately but cannot represent a newly streamed tree.
const SAMPLE_COUNT := 5

var report_path := ""

func _initialize() -> void:
	call_deferred("run_benchmark")

func run_benchmark() -> void:
	report_path = OS.get_environment("VOXEL_PROCEDURAL_TREE_PERFORMANCE_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/procedural-tree-performance.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var service = TreeSpawnServiceScript.new()
	service.prewarm_visuals()
	var recipe_rows: Array[Dictionary] = []
	for request in benchmark_requests():
		var samples: Array[int] = []
		var branch_counts: Array[int] = []
		var foliage_counts: Array[int] = []
		var build_stage_samples: Array[Dictionary] = []
		for sample_index in range(SAMPLE_COUNT):
			var cold_request: Dictionary = (request as Dictionary).duplicate(true)
			cold_request["treeId"] = "%s-cold-%d" % [String(request.get("treeId", "benchmark-tree")), sample_index]
			var started := Time.get_ticks_usec()
			var recipe: Dictionary = service.build_recipe(cold_request)
			samples.append(Time.get_ticks_usec() - started)
			branch_counts.append(int(recipe.get("branchCount", 0)))
			foliage_counts.append(int(recipe.get("foliageClusterCount", 0)))
			var recipe_stats: Dictionary = recipe.get("stats", {}) if recipe.get("stats", {}) is Dictionary else {}
			var timing: Dictionary = recipe_stats.get("timingUsec", {}) if recipe_stats.get("timingUsec", {}) is Dictionary else {}
			if not timing.is_empty():
				build_stage_samples.append({
					"recipe": timing,
					"colonization": recipe_stats.get("colonizationTimingUsec", {})
				})
		recipe_rows.append({
			"family": String(request.get("speciesGrammar", "")),
			"tier": String(request.get("renderLodTier", "near")),
		"timing": timing_stats(samples),
		"branchCounts": branch_counts,
		"foliageCounts": foliage_counts,
		"buildStageSamplesUsec": build_stage_samples
		})
	var cache_request := request_for("cache-repeat", "broadleaf", "bushy_oak", "forest", "near")
	service.build_recipe(cache_request)
	var cache_samples: Array[int] = []
	for _index in range(6):
		var started := Time.get_ticks_usec()
		service.build_recipe(cache_request)
		cache_samples.append(Time.get_ticks_usec() - started)
	var lod_downshift := benchmark_lod_downshift(service)
	var queue_result := await benchmark_staged_queue()
	var summary := {
		"runnerId": "procedural_tree_performance_benchmark",
		"evidenceLevel": "microbenchmark",
		"scope": "Production mathematical recipe generation, bounded recipe reuse, and staged visual publication. Does not prove headed traversal frame pacing.",
		"sampleCountPerFamilyTier": SAMPLE_COUNT,
		"recipeByFamilyTier": recipe_rows,
		"sameRequestCache": {
			"timing": timing_stats(cache_samples),
			"metrics": service.cache_metrics()
		},
		"lodDownshiftReuse": lod_downshift,
		"stagedPublication": queue_result
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(summary, "  "))
		file.close()
	print(JSON.stringify(summary))
	quit(0)

func benchmark_lod_downshift(service) -> Dictionary:
	# This measures the exact pure-data operation invoked by the queue worker on
	# a near -> mid transition. It is intentionally reported separately from the
	# headed queue benchmark: no renderer work belongs in this number.
	var source_request := request_for("lod-source", "broadleaf", "bushy_oak", "forest", "near")
	source_request["geneticSeed"] = 77291
	var source_recipe: Dictionary = service.build_recipe(source_request)
	var mid_request: Dictionary = source_request.duplicate(true)
	mid_request["renderLodTier"] = "mid"
	var derived_samples: Array[int] = []
	var derived_signatures := {}
	var derived_branch_counts: Array[int] = []
	var derived_foliage_counts: Array[int] = []
	var derived_flags := true
	for _sample_index in range(SAMPLE_COUNT):
		var started := Time.get_ticks_usec()
		var derived: Dictionary = service.derive_recipe_for_lod(source_recipe, mid_request)
		derived_samples.append(Time.get_ticks_usec() - started)
		derived_signatures[String(derived.get("signature", ""))] = true
		derived_branch_counts.append(int(derived.get("branchCount", 0)))
		derived_foliage_counts.append(int(derived.get("foliageClusterCount", 0)))
		derived_flags = derived_flags and bool(derived.get("runtimeLodDerived", false)) \
			and String(derived.get("runtimeLodSourceTier", "")) == "near"
	var cold_mid_samples: Array[int] = []
	for _sample_index in range(SAMPLE_COUNT):
		var cold_service = TreeSpawnServiceScript.new()
		var started := Time.get_ticks_usec()
		cold_service.build_recipe(mid_request)
		cold_mid_samples.append(Time.get_ticks_usec() - started)
	return {
		"sourceTier": "near",
		"targetTier": "mid",
		"sourceBranchCount": int(source_recipe.get("branchCount", 0)),
		"sourceFoliageCount": int(source_recipe.get("foliageClusterCount", 0)),
		"derived": {
			"timing": timing_stats(derived_samples),
			"branchCounts": derived_branch_counts,
			"foliageCounts": derived_foliage_counts,
			"deterministic": derived_signatures.size() == 1,
			"usedCachedHigherDetailSource": derived_flags
		},
		"coldMidGrammarBuild": timing_stats(cold_mid_samples)
	}

func benchmark_staged_queue() -> Dictionary:
	var fixture := Node3D.new()
	get_root().add_child(fixture)
	var viewer := Node3D.new()
	fixture.add_child(viewer)
	var queue = TreePublicationQueueScript.new()
	fixture.add_child(queue)
	queue.set_viewer(viewer)
	queue.publication_service.prewarm_visuals()
	var bodies: Array[StaticBody3D] = []
	var requests := benchmark_requests()
	var publication_distances := [20.0, 120.0, 300.0, 540.0]
	for index in range(requests.size()):
		var body := StaticBody3D.new()
		body.name = "BenchmarkTree%d" % index
		body.position = Vector3(float(publication_distances[index]), 0.0, 0.0)
		fixture.add_child(body)
		var request: Dictionary = (requests[index] as Dictionary).duplicate(true)
		request["treeWorldPosition"] = body.global_position
		request["publicationPriority"] = body.global_position.distance_squared_to(viewer.global_position)
		queue.enqueue(body, request)
		bodies.append(body)
	for _frame in range(1800):
		var published := true
		for body in bodies:
			if String(body.get_meta("tree_visual_state", "")) != "published":
				published = false
				break
		if published:
			break
		OS.delay_msec(3)
		await process_frame
	var tiers := {}
	for body in bodies:
		var tier := String(body.get_meta("tree_render_lod_tier", "missing"))
		tiers[tier] = int(tiers.get(tier, 0)) + 1
	var result := {"metrics": queue.metrics(), "publishedTiers": tiers}
	fixture.queue_free()
	return result

func benchmark_requests() -> Array[Dictionary]:
	return [
		# These are the active production grammars. The old rounded broadleaf
		# recipe remains available for historical PoC comparison, but it must not
		# define runtime performance acceptance after grammar selection moved to
		# the allometric oak.
		request_for("benchmark-broadleaf", "broadleaf", "bushy_oak", "forest", "near"),
		request_for("benchmark-conifer", "conifer", "norway_spruce", "taiga", "mid"),
		request_for("benchmark-savanna", "savanna", "umbrella_thorn", "savanna", "far"),
		request_for("benchmark-broadleaf-impostor", "broadleaf", "bushy_oak", "forest", "impostor")
	]

func request_for(id: String, architecture: String, grammar: String, biome: String, tier: String) -> Dictionary:
	return {
		"treeId": id,
		"worldSeed": "procedural-tree-performance",
		"biome": biome,
		"architecture": architecture,
		"speciesGrammar": grammar,
		"growthStage": 0.84,
		"visualHeight": 22.0,
		"trunkRadius": 1.0,
		"canopyRadius": 9.0,
		"canopyDensity": 0.84,
		"renderLodTier": tier,
		"presentation": "runtime"
	}

func timing_stats(raw: Array) -> Dictionary:
	var samples: Array = raw.duplicate()
	samples.sort()
	var total := 0
	for sample in samples:
		total += int(sample)
	return {
		"averageUsec": float(total) / float(maxi(1, samples.size())),
		"p50Usec": percentile(samples, 0.50),
		"p95Usec": percentile(samples, 0.95),
		"p99Usec": percentile(samples, 0.99),
		"maxUsec": int(samples.back()) if not samples.is_empty() else 0
	}

func percentile(samples: Array, fraction: float) -> int:
	if samples.is_empty():
		return 0
	return int(samples[clampi(ceili(float(samples.size()) * fraction) - 1, 0, samples.size() - 1)])
