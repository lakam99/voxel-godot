extends SceneTree

## VOX-134 Candidate-A renderer comparison.  This is deliberately a focused
## prototype, not a gameplay acceptance test: it measures the same immutable
## mathematical recipes when represented by the current hybrid tree renderer
## versus a chunk/material/LOD-owned shared-primitive renderer.

const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const VisualFactoryScript := preload("res://scripts/visual/ProceduralTreeVisualFactory.gd")
const TreeChunkBatchRendererScript := preload("res://scripts/visual/TreeChunkBatchRenderer.gd")

var report_path := ""
var results: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("run_comparison")

func run_comparison() -> void:
	report_path = OS.get_environment("VOXEL_TREE_CHUNK_BATCH_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/tree-chunk-batch-prototype.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var fixture := Node3D.new()
	fixture.name = "TreeChunkBatchPrototypeFixture"
	get_root().add_child(fixture)
	var service = TreeSpawnServiceScript.new()
	var visual_factory = VisualFactoryScript.new()
	visual_factory.prewarm_runtime_resources()
	var recipes := build_fixture_recipes(service)
	var hybrid := inspect_hybrid_candidate(visual_factory, recipes)
	var chunk_batch = TreeChunkBatchRendererScript.new()
	fixture.add_child(chunk_batch)
	var batch_started := Time.get_ticks_usec()
	var added := 0
	for entry_value in recipes:
		var entry: Dictionary = entry_value as Dictionary
		if chunk_batch.add_tree(
			String(entry.get("treeId", "")),
			entry.get("recipe", {}) as Dictionary,
			String(entry.get("biome", "")),
			"prototype-chunk-12-7",
			entry.get("worldOrigin", Vector3.ZERO) as Vector3
		):
			added += 1
	var initial_add_usec := Time.get_ticks_usec() - batch_started
	var batched_metrics: Dictionary = chunk_batch.metrics()
	var recipe_counts := total_recipe_counts(recipes)
	var no_physics_nodes := chunk_batch.find_children("*", "PhysicsBody3D", true, false).is_empty() \
		and chunk_batch.find_children("*", "CollisionShape3D", true, false).is_empty()
	add_result("shared_chunk_batches_preserve_all_recipe_instance_counts", added == recipes.size() \
		and int(batched_metrics.get("branchInstances", -1)) == int(recipe_counts.get("branches", -2)) \
		and int(batched_metrics.get("foliageInstances", -1)) == int(recipe_counts.get("foliage", -2)), {
		"added": added,
		"recipeCounts": recipe_counts,
		"metrics": batched_metrics
	})
	add_result("chunk_batched_candidate_reduces_render_submission_roles_without_adding_collision", no_physics_nodes \
		and int(batched_metrics.get("estimatedDrawCalls", 9999)) < int(hybrid.get("estimatedDrawCalls", 0)), {
		"candidateA": batched_metrics,
		"candidateB": hybrid,
		"collisionNodesPresent": not no_physics_nodes
	})
	var batch_creates_before_remove := int(batched_metrics.get("batchCreateCount", 0))
	var remove_started := Time.get_ticks_usec()
	var removed := chunk_batch.remove_tree("prototype-broadleaf-03")
	var remove_usec := Time.get_ticks_usec() - remove_started
	var after_remove: Dictionary = chunk_batch.metrics()
	add_result("tree_unpublication_releases_slots_by_swap_without_rebuilding_chunk_batch", removed \
		and int(after_remove.get("treeCount", -1)) == recipes.size() - 1 \
		and int(after_remove.get("batchCreateCount", -1)) == batch_creates_before_remove \
		and int(after_remove.get("removalSwapCount", 0)) > 0, {
		"removeUsec": remove_usec,
		"before": batched_metrics,
		"after": after_remove
	})
	var passed := true
	for result in results:
		passed = passed and bool(result.get("passed", false))
	var report := {
		"runnerId": "tree_chunk_batch_renderer_prototype",
		"evidenceLevel": "renderer_prototype_microbenchmark",
		"scope": "Candidate-A shared branch/foliage MultiMeshes against the existing per-tree hybrid visual roles, using identical canonical recipes. It does not prove production chunk culling, streaming integration, final GPU frame time, or normal-gameplay visual acceptance.",
		"passed": passed,
		"fixture": {
			"treeCount": recipes.size(),
			"chunkKey": "prototype-chunk-12-7",
			"initialAddUsec": initial_add_usec,
			"removalUsec": remove_usec
		},
		"candidateA": batched_metrics,
		"candidateB": hybrid,
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify(report))
	fixture.queue_free()
	quit(0 if passed else 1)

func build_fixture_recipes(service) -> Array[Dictionary]:
	var families := [
		{"architecture": "broadleaf", "grammar": "bushy_oak", "biome": "forest", "count": 6},
		{"architecture": "conifer", "grammar": "norway_spruce", "biome": "taiga", "count": 4},
		{"architecture": "savanna", "grammar": "umbrella_thorn", "biome": "savanna", "count": 2}
	]
	var entries: Array[Dictionary] = []
	var ordinal := 0
	for family_value in families:
		var family: Dictionary = family_value as Dictionary
		for family_index in range(int(family.get("count", 0))):
			ordinal += 1
			var tree_id := "prototype-%s-%02d" % [String(family.get("architecture", "tree")), family_index + 1]
			var request := {
				"treeId": tree_id,
				"worldSeed": "vox134-chunk-batch-prototype",
				"geneticSeed": 18011 + ordinal * 7919,
				"biome": String(family.get("biome", "forest")),
				"architecture": String(family.get("architecture", "broadleaf")),
				"speciesGrammar": String(family.get("grammar", "bushy_oak")),
				"growthStage": 0.82,
				"visualHeight": 21.0,
				"trunkRadius": 0.94,
				"canopyRadius": 8.7,
				"canopyDensity": 0.84,
				"renderLodTier": "near",
				"presentation": "runtime"
			}
			entries.append({
				"treeId": tree_id,
				"biome": String(family.get("biome", "forest")),
				"worldOrigin": Vector3(float((ordinal % 4) * 18), 0.0, float((ordinal / 4) * 18)),
				"recipe": service.build_recipe(request)
			})
	return entries

func inspect_hybrid_candidate(visual_factory, recipes: Array[Dictionary]) -> Dictionary:
	var roles := 0
	var shadow_roles := 0
	var structural_meshes := 0
	var multimesh_nodes := 0
	var instantiate_started := Time.get_ticks_usec()
	for entry in recipes:
		var visual: Node3D = visual_factory.instantiate_recipe(entry.get("recipe", {}) as Dictionary, String(entry.get("biome", "forest")), String(entry.get("treeId", "")))
		if visual == null:
			continue
		for node in visual.find_children("*", "GeometryInstance3D", true, false):
			roles += 1
			if (node as GeometryInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				shadow_roles += 1
			if node is MultiMeshInstance3D:
				multimesh_nodes += 1
			elif node is MeshInstance3D:
				structural_meshes += 1
		visual.free()
	var instantiate_usec := Time.get_ticks_usec() - instantiate_started
	return {
		"renderer": "candidate_b_per_tree_hybrid",
		"treeCount": recipes.size(),
		"estimatedDrawCalls": roles,
		"estimatedShadowDrawCalls": shadow_roles,
		"continuousStructuralMeshInstances": structural_meshes,
		"instancedRoleNodes": multimesh_nodes,
		"initialInstantiateUsec": instantiate_usec,
		"note": "Role count is measured from actual nodes instantiated by the existing hybrid factory; it is a submission proxy, not a renderer draw-call readback."
	}

func total_recipe_counts(recipes: Array[Dictionary]) -> Dictionary:
	var branches := 0
	var foliage := 0
	for entry in recipes:
		var recipe: Dictionary = entry.get("recipe", {}) as Dictionary
		for branch_value in recipe.get("branches", []) as Array:
			if branch_value is Dictionary and int((branch_value as Dictionary).get("order", 1)) != 0:
				branches += 1
		foliage += int(recipe.get("foliageClusterCount", 0))
	return {"branches": branches, "foliage": foliage}

func add_result(name: String, passed: bool, details: Dictionary) -> void:
	results.append({"name": name, "passed": passed, "details": details})
