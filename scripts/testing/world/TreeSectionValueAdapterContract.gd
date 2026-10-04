extends SceneTree

const Adapter := preload("res://scripts/world/TreeSectionValueAdapter.gd")
const QueueScript := preload("res://scripts/environment/TreePublicationQueue.gd")
const TreeServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const RemovedProps := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")

class TestAuthority extends Node:
	var seed_text := "tree-section-adapter-contract"
	var seed_hash := 19
	var removed_props := {}
	var removed_props_revision := 0

var checks := {}

func _init() -> void:
	call_deferred("run")


func check(name: String, condition: bool) -> void:
	checks[name] = condition


func _multi_instance(mesh: Mesh, material: Material, transforms: Array[Transform3D],
		custom_values: Array[Color], name: String, role: String) -> MultiMeshInstance3D:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for index in range(transforms.size()):
		multi.set_instance_transform(index, transforms[index])
		multi.set_instance_custom_data(index, custom_values[index])
	var instance := MultiMeshInstance3D.new()
	instance.name = name
	instance.multimesh = multi
	instance.material_override = material
	instance.visibility_range_end = 440.0
	instance.visibility_range_end_margin = 28.0
	instance.set_meta("tree_wood_role", role) if role == "instanced_distal_branches" else instance.set_meta("tree_render_role", "foliage")
	return instance


func _recipe_and_visual(body: StaticBody3D, queue: TreePublicationQueue,
		request: Dictionary) -> Dictionary:
	var recipe := queue.publication_service.build_recipe(request)
	var service = queue.publication_service
	var signature := String(service.runtime_recipe_signature(recipe, request))
	recipe["signature"] = signature
	recipe["branches"] = [
		{"order":0,"start":Vector3.ZERO,"end":Vector3.UP},
		{"order":1,"start":Vector3.ZERO,"end":Vector3(0.0,1.0,0.0)}]
	recipe["branchCount"] = 2
	recipe["foliage"] = [{"position":Vector3(0.0,2.0,0.0)}]
	recipe["foliageClusterCount"] = 1
	# Runtime signature intentionally covers source topology and branch count;
	# the fixture uses a compact deterministic render graph for exact membership.
	recipe["topologySignature"] = "tree-section-contract-topology"
	recipe["signature"] = service.runtime_recipe_signature(recipe, request)
	signature = String(recipe.signature)
	var lod: Dictionary = recipe.get("renderLod", {})
	lod["tier"] = String(request.get("renderLodTier", "near"))
	recipe["renderLod"] = lod
	recipe["runtimeImpostor"] = false
	var visual := Node3D.new()
	visual.name = "GeneratedTreeVisual"
	visual.set_meta("tree_recipe_signature", signature)
	visual.set_meta("tree_id", String(request.treeId))
	var wood := Node3D.new()
	wood.name = "ProceduralTreeWood"
	visual.add_child(wood)
	var bole := MeshInstance3D.new()
	bole.name = "ProceduralTreeContinuousStructuralWood"
	bole.mesh = BoxMesh.new()
	bole.material_override = _material(Color("65411e"))
	bole.visibility_range_end = 440.0
	bole.visibility_range_end_margin = 28.0
	bole.set_meta("tree_render_role", "continuous_wood")
	bole.set_meta("tree_wood_segment_count", 1)
	bole.set_meta("tree_wood_role", "continuous_bole_and_scaffolds")
	wood.add_child(bole)
	var branch_mesh := BoxMesh.new()
	branch_mesh.resource_name = "tree-contract-branch"
	var branch_material := _material(Color("65411e"))
	var branches := _multi_instance(branch_mesh, branch_material,
		[Transform3D(Basis.IDENTITY, Vector3(24.0,2.0,0.0))],
		[Color(0.5,0.7,0.37,0.81)], "ProceduralTreeDistalBranches",
		"instanced_distal_branches")
	wood.add_child(branches)
	var foliage_mesh := BoxMesh.new()
	foliage_mesh.resource_name = "tree-contract-foliage"
	var foliage_material := _material(Color("3d672c"))
	var foliage := _multi_instance(foliage_mesh, foliage_material,
		[Transform3D(Basis.IDENTITY, Vector3(48.0,3.0,0.0))],
		[Color(0.2,0.8,0.35,0.0)], "RuntimeFoliage", "")
	foliage.set_meta("tree_foliage_batching", "single_shared_cluster_mesh")
	var foliage_root := Node3D.new()
	foliage_root.name = "ProceduralTreeFoliage"
	foliage_root.add_child(foliage)
	visual.add_child(foliage_root)
	body.add_child(visual)
	body.set_meta("tree_recipe_signature", signature)
	body.set_meta("tree_render_lod_tier", String(request.renderLodTier))
	body.set_meta("tree_visual_state", "published")
	body.set_meta("visual_source", "procedural_tree_recipe")
	return {"recipe":recipe, "visual":visual}


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.88
	return material


func _make_capture(queue: TreePublicationQueue, authority: TestAuthority,
		body: StaticBody3D, recipe: Dictionary, world_id: String) -> Dictionary:
	var removed := RemovedProps.capture(authority)
	return Adapter.capture_published_tree(queue, authority, world_id, body, recipe, removed)


func run() -> void:
	var authority := TestAuthority.new()
	root.add_child(authority)
	var queue := QueueScript.new()
	root.add_child(queue)
	var prop_id := "tree-section-adapter-contract:0,0:0"
	var body := StaticBody3D.new()
	body.name = "TreeBody"
	body.set_meta("prop_id", prop_id)
	body.add_to_group("generated_props")
	var collider := CollisionShape3D.new()
	collider.name = "TrunkCollision"
	var cylinder := CylinderShape3D.new()
	cylinder.height = 8.0
	cylinder.radius = 0.4
	collider.shape = cylinder
	body.add_child(collider)
	root.add_child(body)
	var request := {"treeId":prop_id, "worldSeed":authority.seed_text,
		"biome":"forest", "architecture":"broadleaf", "speciesGrammar":"bushy_oak",
		"renderLodTier":"near", "treeWorldPosition":body.global_position,
		"visualHeight":8.0, "trunkRadius":0.4, "canopyRadius":3.2,
		"canopyDensity":0.6, "geneticSeed":12345}
	var built := _recipe_and_visual(body, queue, request)
	var recipe: Dictionary = built.recipe
	queue.published_lod_records.append({"body":weakref(body),
		"bodyInstanceId":body.get_instance_id(), "request":request.duplicate(true),
		"tier":"near", "rebuildPending":false})
	await process_frame
	var world_id := "seed:%s:%d" % [authority.seed_text, authority.seed_hash]
	var captured := _make_capture(queue, authority, body, recipe, world_id)
	var partition: Dictionary = captured.get("partition", {})
	var expected_instances := 3 # one bole, one branch, one foliage cluster
	check("exact_queue_acknowledged_recipe_membership_partitions_every_draw_instance",
		captured.get("status") == "ready" \
		and int(partition.get("inputInstanceCount", -1)) == expected_instances \
		and int(partition.get("outputInstanceCount", -1)) == expected_instances \
		and captured.get("memberRows", []).size() == 3)
	check("branch_and_foliage_custom_data_survive_shared_20_float_abi",
		captured.get("status") == "ready" \
		and captured.get("inputs", []).all(func(input: Dictionary) -> bool:
			return input.buffer.size() == input.instanceCount * Attributes.FLOATS_PER_INSTANCE)
		and captured.get("compatibilityByKey", {}).size() == 3)
	check("actual_resource_bindings_match_canonical_batch_compatibility_keys",
		captured.get("status") == "ready" \
		and captured.get("meshBindings", {}).size() == 3 \
		and captured.get("materialBindings", {}).size() == 3 \
		and captured.get("compatibilityByKey", {}).values().all(func(value: Dictionary) -> bool:
			return not String(value.get("batchKey", "")).is_empty()))
	var section_boundaries: Array = captured.get("sectionKeys", [])
	check("tree_instances_are_owned_by_the_partition_of_their_transformed_mesh_bounds",
		captured.get("status") == "ready" \
		and section_boundaries.has(Grid.key_for_world_position(Vector3(0.0,0.0,0.0))) \
		and section_boundaries.has(Grid.key_for_world_position(Vector3(24.0,2.0,0.0))) \
		and section_boundaries.has(Grid.key_for_world_position(Vector3(48.0,3.0,0.0))) \
		and section_boundaries.size() >= 3)
	check("capture_retains_gameplay_body_collision_and_stable_source_identity",
		body.get_node_or_null("TrunkCollision") == collider \
		and collider.shape == cylinder and captured.get("sourceId", "") == "%s:tree:%s" % [authority.seed_text, prop_id] \
		and captured.get("censusStatus", "") == "pending")
	var stale_recipe := recipe.duplicate(true)
	stale_recipe["signature"] = "tree-v10-deadbeef"
	var stale := _make_capture(queue, authority, body, stale_recipe, world_id)
	check("recipe_signature_mismatch_stays_pending", stale.get("status") == "pending")
	var lod_record: Dictionary = queue.published_lod_records[0]
	lod_record["rebuildPending"] = true
	queue.published_lod_records[0] = lod_record
	var retiering := _make_capture(queue, authority, body, recipe, world_id)
	check("old_tree_capture_waits_while_atomic_lod_replacement_is_pending",
		retiering.get("status") == "pending" \
		and retiering.get("reason") == "tree_lod_replacement_pending")
	lod_record["rebuildPending"] = false
	queue.published_lod_records[0] = lod_record
	authority.removed_props[prop_id] = true
	authority.removed_props_revision += 1
	var removed := _make_capture(queue, authority, body, recipe, world_id)
	check("only_authoritative_removed_props_snapshot_proves_tree_tombstone",
		removed.get("status") == "empty" \
		and removed.get("reason") == "tree_authoritative_tombstone")
	authority.removed_props.erase(prop_id)
	authority.removed_props_revision += 1
	var headless_proxy := Node3D.new()
	headless_proxy.name = "GeneratedTreeVisual"
	headless_proxy.set_meta("tree_recipe_signature", recipe.signature)
	headless_proxy.set_meta("tree_id", prop_id)
	headless_proxy.set_meta("tree_headless_visual_proxy", true)
	body.remove_child(built.visual)
	built.visual.queue_free()
	body.add_child(headless_proxy)
	var proxy_capture := _make_capture(queue, authority, body, recipe, world_id)
	check("missing_production_geometry_does_not_become_visual_success",
		proxy_capture.get("status") == "pending")
	var report := {"schema":"tree-section-value-adapter-contract/v1",
		"checks":checks, "passed":not checks.values().has(false),
		"captureStatus":captured.get("status", "missing"),
		"captureReason":captured.get("reason", ""),
		"sourceId":captured.get("sourceId", ""),
		"collisionPresent":body.get_node_or_null("TrunkCollision") == collider,
		"liveMultiTransform":built.visual.get_node("ProceduralTreeWood/ProceduralTreeDistalBranches").multimesh.get_instance_transform(0),
		"partitionInstanceCount":partition.get("outputInstanceCount", 0),
		"sectionKeys":captured.get("sectionKeys", []),
		"sectionSizeMeters":Grid.SECTION_SIZE_METERS,
		"inputOrigins":captured.get("inputs", []).map(func(input: Dictionary) -> Variant:
			return Attributes.decode_transform(input.buffer, 0).origin),
		"partitionOutputKeys":partition.get("outputs", []).map(func(output: Dictionary) -> Variant:
			return output.get("sectionKey")),
		"batchCount":captured.get("compatibilityByKey", {}).size(),
		"evidence":"synthetic queue receipt and visual-resource fixture using canonical TreeSpawnService recipe identity; exact one-tree membership/partition/batch binding only; no real queue production, native renderer installation, complete ecology census, live gameplay, collision parity, save/replay, or performance acceptance"}
	var report_path := OS.get_environment("TREE_SECTION_VALUE_ADAPTER_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print("TREE SECTION VALUE ADAPTER ", JSON.stringify(report))
	queue.queue_free()
	authority.queue_free()
	quit(0 if report.passed else 1)
