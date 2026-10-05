extends SceneTree

const Compiler := preload("res://scripts/world/TreeRecipeSectionCompiler.gd")
const QueueScript := preload("res://scripts/environment/TreePublicationQueue.gd")
const RemovedProps := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Adapter := preload("res://scripts/world/TreeSectionValueAdapter.gd")

class Authority extends Node:
	var seed_text := "tree-recipe-section-compiler-contract"
	var seed_hash := 505
	var removed_props := {}
	var removed_props_revision := 0

var checks := {}


func _init() -> void:
	call_deferred("run")


func _check(name: String, condition: bool) -> void:
	checks[name] = condition


func _new_fixture(prop_id: String, x_position: float) -> Dictionary:
	var authority := Authority.new()
	root.add_child(authority)
	var queue := QueueScript.new()
	authority.add_child(queue)
	var body := StaticBody3D.new()
	body.set_meta("prop_id", prop_id)
	authority.add_child(body)
	body.global_position = Vector3(x_position, 0.0, 0.0)
	var request := {"treeId":prop_id, "worldSeed":authority.seed_text,
		"biome":"forest", "architecture":"broadleaf", "speciesGrammar":"bushy_oak",
		"renderLodTier":"near", "treeWorldPosition":body.global_position,
		"visualHeight":8.0, "trunkRadius":0.4, "canopyRadius":4.0,
		"canopyDensity":0.6, "geneticSeed":12345}
	var recipe: Dictionary = queue.publication_service.build_recipe(request)
	var sealed := queue.build_tree_section_recipe_input_record(
		{"request":request, "enqueueSequence":1}, body, recipe)
	return {"authority":authority, "queue":queue, "body":body,
		"request":request, "recipe":recipe, "record":sealed.get("record", {}),
		"worldId":"seed:%s:%d" % [authority.seed_text, authority.seed_hash],
		"removed":RemovedProps.capture_for_ids(authority, [prop_id])}


func _run_compiler(fixture: Dictionary, unit_budget: int) -> Dictionary:
	var compiler := Compiler.new()
	var begun: Dictionary = compiler.begin(fixture.authority, fixture.worldId,
		[fixture.record], fixture.removed)
	if begun.get("status") != "pending":
		return {"result":begun, "steps":0}
	var steps := 0
	var result: Dictionary = begun
	while steps < 20000:
		result = compiler.advance(unit_budget)
		steps += 1
		if result.get("status") != "pending" or String(result.get("reason", "")) != "tree_section_compile_in_progress":
			break
	return {"result":result, "steps":steps, "begin":begun}


func run() -> void:
	var section_origin_x := Grid.SECTION_SIZE_METERS * 2.0
	var fixture := _new_fixture("tree-compiler:boundary", section_origin_x - 1.0)
	var compiled := _run_compiler(fixture, 1)
	var result: Dictionary = compiled.result
	var batches: Array = result.get("batches", [])
	var section_keys: Array[Vector3i] = []
	var roles := {}
	var valid_buffers := true
	var deep_read_only := result.is_read_only()
	for batch_value: Variant in batches:
		if not batch_value is Dictionary:
			valid_buffers = false
			continue
		var batch: Dictionary = batch_value
		roles[String(batch.role)] = true
		if not section_keys.has(batch.sectionKey): section_keys.append(batch.sectionKey)
		var attributes: Array = batch.instanceAttributes
		valid_buffers = valid_buffers and attributes.is_read_only() \
			and attributes.size() == int(batch.instanceCount) * Attributes.FLOATS_PER_INSTANCE \
			and String(batch.renderLayer) == "opaque" \
			and batch.contributors.is_read_only() \
			and batch.contributors.values().all(func(c: Dictionary) -> bool:
				return not String(c.get("sourceRevision", "")).is_empty() \
					and c.instanceAttributes.is_read_only())
		deep_read_only = deep_read_only and batch.is_read_only() \
			and batch.compatibilityKey.is_read_only() \
			and batch.streamChunkDependencies.is_read_only()
	section_keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var second := _run_compiler(fixture, 24)
	var second_result: Dictionary = second.result
	var same_output := false
	if second_result.get("status") == "ready":
		same_output = result.batches == second_result.batches \
			and result.sources == second_result.sources
	_check("compiler_uses_sealed_recipe_artifact_without_visual_nodes",
		fixture.record is Dictionary and fixture.record.is_read_only() \
		and result.get("status") == "ready" \
		and fixture.body.get_child_count() == 0)
	_check("recipe_geometry_crosses_exact_section_boundary",
		result.get("status") == "ready" \
		and is_equal_approx(float(fixture.record.bodyGlobalTransform.origin.x), section_origin_x - 1.0) \
		and section_keys.size() > 1 \
		and result.sources.size() == 1)
	var ownership: Array = result.sources[0].get("geometryOwnership", []) \
		if result.get("status") == "ready" and result.sources.size() > 0 else []
	_check("each_instance_records_center_owner_and_aabb_support_sections",
		result.get("status") == "ready" and not ownership.is_empty() \
		and ownership.all(func(entry: Dictionary) -> bool:
			return entry.has("ownedSectionKey") \
				and entry.get("supportSectionKeys", []).size() > 0))
	_check("all_runtime_roles_preserve_mesh_material_layer_and_instance_abi",
		result.get("status") == "ready" and roles.has("bole") \
		and roles.has("branches") and roles.has("foliage") and valid_buffers)
	_check("nested_candidate_values_are_read_only",
		result.get("status") == "ready" and deep_read_only \
		and result.sources.is_read_only())
	_check("deterministic_output_is_independent_of_slice_budget",
		result.get("status") == "ready" and second_result.get("status") == "ready" \
		and same_output and int(result.workUnits) >= 3 and compiled.steps > 3)
	var translucent := StandardMaterial3D.new()
	translucent.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_check("unsupported_translucent_layer_fails_closed",
		Adapter._supported_opaque_layer(translucent, "foliage").is_empty())
	var stale_compiler := Compiler.new()
	stale_compiler.begin(fixture.authority, fixture.worldId, [fixture.record], fixture.removed)
	fixture.body.position.x += 2.0
	var stale_result := stale_compiler.advance(1)
	_check("owner_transform_change_rejects_in_flight_recipe", stale_result.get("status") == "pending" \
		and stale_result.get("reason", "").contains("stale"))
	fixture.body.position.x -= 2.0
	var tombstone_compiler := Compiler.new()
	tombstone_compiler.begin(fixture.authority, fixture.worldId, [fixture.record], fixture.removed)
	fixture.authority.removed_props[fixture.body.get_meta("prop_id")] = true
	fixture.authority.removed_props_revision += 1
	var tombstone_result := tombstone_compiler.advance(1)
	_check("new_tombstone_invalidates_in_flight_recipe", tombstone_result.get("status") == "pending" \
		and tombstone_result.get("reason", "").contains("stale"))
	var report := {"schema":"tree-recipe-section-compiler-contract/v1",
		"checks":checks, "passed":not checks.values().has(false),
		"status":result.get("status", "missing"), "reason":result.get("reason", ""),
		"beginReason":compiled.get("begin", {}).get("reason", ""),
		"sectionKeys":section_keys, "sectionSizeMeters":Grid.SECTION_SIZE_METERS,
		"sampleOwnership":ownership.slice(0, 4),
		"batchCount":batches.size(), "roles":roles.keys(),
		"workUnits":result.get("workUnits", 0), "singleUnitSteps":compiled.steps,
		"largeUnitSteps":second.steps,
		"evidenceLevel":"headed canonical recipe artifact and node-free factory value compiler contract; exact source geometry ownership, immutable output, per-instance ABI and budget slicing only; no real ecology census, candidate assembler/native installation, gameplay lifecycle, save/replay or performance acceptance"}
	var path := OS.get_environment("TREE_RECIPE_SECTION_COMPILER_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print("TREE RECIPE SECTION COMPILER ", JSON.stringify(report))
	fixture.queue.queue_free()
	fixture.body.queue_free()
	fixture.authority.queue_free()
	quit(0 if report.passed else 1)
