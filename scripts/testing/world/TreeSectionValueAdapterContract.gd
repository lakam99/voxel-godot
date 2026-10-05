extends SceneTree

const Adapter := preload("res://scripts/world/TreeSectionValueAdapter.gd")
const QueueScript := preload("res://scripts/environment/TreePublicationQueue.gd")
const TreeServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const RemovedProps := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const EcologyAdapter := preload("res://scripts/world/EcologySectionValueAdapter.gd")

class TestAuthority extends Node:
	var seed_text := "tree-section-adapter-contract"
	var seed_hash := 19
	var removed_props := {}
	var removed_props_revision := 0
	var tree_publication_queue: Object
	var world_static_section_coordinator: Object
	func detail_mesh(_chunk: Vector2i) -> Mesh: return BoxMesh.new()
	func detail_material(_chunk: Vector2i) -> Material: return StandardMaterial3D.new()
	func _ecology_chunk_source_revision(_chunk: Vector2i) -> String: return "fixture"

class TestSectionCoordinator extends RefCounted:
	var installed_receipts: Dictionary = {}
	func installed_section_receipt_is_current(section_key: Vector3i,
			receipt: Dictionary) -> bool:
		return installed_receipts.get(section_key, {}) == receipt

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
	var normalized_request: Dictionary = service.normalize_request(request)
	var signature := String(service.runtime_recipe_signature(recipe, normalized_request))
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
	recipe["signature"] = service.runtime_recipe_signature(recipe, normalized_request)
	signature = String(recipe.signature)
	var lod: Dictionary = recipe.get("renderLod", {})
	lod["tier"] = String(request.get("renderLodTier", "near"))
	recipe["renderLod"] = lod
	recipe["runtimeImpostor"] = false
	var visual := Node3D.new()
	visual.name = "GeneratedTreeVisual"
	visual.transform = Transform3D(Basis.IDENTITY, Vector3(0.5, 0.0, 0.0))
	visual.set_meta("tree_recipe_signature", signature)
	visual.set_meta("tree_id", String(request.treeId))
	var wood := Node3D.new()
	wood.name = "ProceduralTreeWood"
	wood.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	visual.add_child(wood)
	var bole := MeshInstance3D.new()
	bole.name = "ProceduralTreeContinuousStructuralWood"
	bole.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 2.0))
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
	var branch_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	branch_image.fill(Color("8a633e"))
	branch_material.albedo_texture = ImageTexture.create_from_image(branch_image)
	var branches := _multi_instance(branch_mesh, branch_material,
		[Transform3D(Basis.IDENTITY, Vector3(24.0,2.0,0.0))],
		[Color(0.5,0.7,0.37,0.81)], "ProceduralTreeDistalBranches",
		"instanced_distal_branches")
	branches.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 3.0))
	wood.add_child(branches)
	var foliage_mesh := BoxMesh.new()
	foliage_mesh.resource_name = "tree-contract-foliage"
	var foliage_material := _material(Color("3d672c"))
	var foliage := _multi_instance(foliage_mesh, foliage_material,
		[Transform3D(Basis.IDENTITY, Vector3(48.0,3.0,0.0))],
		[Color(0.2,0.8,0.35,0.0)], "RuntimeFoliage", "")
	foliage.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 5.0))
	foliage.set_meta("tree_foliage_batching", "single_shared_cluster_mesh")
	var foliage_root := Node3D.new()
	foliage_root.name = "ProceduralTreeFoliage"
	foliage_root.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 4.0, 0.0))
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
	body.transform = Transform3D(Basis(Vector3.UP, 0.37), Vector3(100.0, 4.0, -30.0))
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
	var wood: Node3D = built.visual.get_node("ProceduralTreeWood")
	var foliage_root: Node3D = built.visual.get_node("ProceduralTreeFoliage")
	var section_members: Array = [
		queue.capture_section_value_member(wood.get_node("ProceduralTreeContinuousStructuralWood"), "bole", built.visual).member,
		queue.capture_section_value_member(wood.get_node("ProceduralTreeDistalBranches"), "branches", built.visual).member,
		queue.capture_section_value_member(foliage_root.get_node("RuntimeFoliage"), "foliage", built.visual).member]
	var expected_local_origins := [Vector3(0.5, 1.0, 2.0), Vector3(24.5, 3.0, 3.0), Vector3(48.5, 7.0, 5.0)]
	var captured_local_origins: Array[Vector3] = []
	for member_index: int in range(section_members.size()):
		var member: Dictionary = section_members[member_index]
		captured_local_origins.append((member.localTransform as Transform3D).origin
			+ ((member.transforms as Array)[0] as Transform3D).origin)
	check("nonidentity_body_and_child_hierarchy_are_captured_once",
		captured_local_origins.size() == expected_local_origins.size() \
		and section_members[0].transforms[0].is_equal_approx(Transform3D.IDENTITY) \
		and captured_local_origins[0].is_equal_approx(expected_local_origins[0]) \
		and captured_local_origins[1].is_equal_approx(expected_local_origins[1]) \
		and captured_local_origins[2].is_equal_approx(expected_local_origins[2]))
	queue.remember_published_lod(body, request, section_members, recipe)
	await process_frame
	var world_id := "seed:%s:%d" % [authority.seed_text, authority.seed_hash]
	# The adapter must consume the queue's sealed producer artifact. The legacy
	# visual tree can be absent while capture still binds the acknowledged data.
	body.remove_child(built.visual)
	built.visual.queue_free()
	var captured := _make_capture(queue, authority, body, recipe, world_id)
	var queue_capture := Adapter.capture_from_queue_record(queue, authority,
		world_id, body, RemovedProps.capture(authority))
	authority.removed_props["unrelated-prop-from-another-chunk"] = true
	authority.removed_props_revision += 1
	var unrelated_removal_capture := _make_capture(queue, authority, body, recipe, world_id)
	var partition: Dictionary = captured.get("partition", {})
	var ecology := EcologyAdapter.new()
	ecology.configure(world_id)
	ecology.bind_main_authority(authority)
	var tree_candidate := {"propId":prop_id, "sourceId":"%s:tree:%s" % [authority.seed_text, prop_id],
		"contentRevision":"tree-census-fixture-r1"}
	var publication := {"record":Adapter._published_record(queue, body), "body":body}
	var census_revision := ecology._tree_census_source_revision(tree_candidate, publication)
	var contribution_revision := ecology._tree_section_source_revision(tree_candidate, captured)
	check("tree_census_and_contribution_share_resource_aware_revision",
		census_revision == contribution_revision and not census_revision.is_empty())
	var initial_resource_revision := census_revision
	var shared_branch_mesh := section_members[1].mesh as BoxMesh
	shared_branch_mesh.size += Vector3(0.25, 0.0, 0.0)
	var changed_resource_capture := _make_capture(queue, authority, body, recipe, world_id)
	var changed_census_revision := ecology._tree_census_source_revision(tree_candidate, publication)
	var changed_contribution_revision := ecology._tree_section_source_revision(
		tree_candidate, changed_resource_capture)
	check("retained_mesh_mutation_revises_census_and_contribution_together",
		changed_resource_capture.get("status") == "ready" \
		and changed_census_revision == changed_contribution_revision \
		and changed_census_revision != initial_resource_revision)
	var shared_branch_material := section_members[1].material as StandardMaterial3D
	shared_branch_material.albedo_color = Color("855126")
	var changed_material_capture := _make_capture(queue, authority, body, recipe, world_id)
	var changed_material_census_revision := ecology._tree_census_source_revision(
		tree_candidate, publication)
	var changed_material_contribution_revision := ecology._tree_section_source_revision(
		tree_candidate, changed_material_capture)
	check("retained_material_mutation_revises_census_and_contribution_together",
		changed_material_capture.get("status") == "ready" \
		and changed_material_census_revision == changed_material_contribution_revision \
		and changed_material_census_revision != changed_census_revision)
	var branch_texture := shared_branch_material.albedo_texture as ImageTexture
	var changed_texture_image := branch_texture.get_image()
	changed_texture_image.set_pixel(0, 0, Color("cfb54a"))
	branch_texture.update(changed_texture_image)
	var changed_texture_capture := _make_capture(queue, authority, body, recipe, world_id)
	var changed_texture_census_revision := ecology._tree_census_source_revision(
		tree_candidate, publication)
	var changed_texture_contribution_revision := ecology._tree_section_source_revision(
		tree_candidate, changed_texture_capture)
	check("retained_material_texture_mutation_revises_census_and_contribution_together",
		changed_texture_capture.get("status") == "ready" \
		and changed_texture_census_revision == changed_texture_contribution_revision \
		and changed_texture_census_revision != changed_material_census_revision)
	var expected_instances := 3 # one bole, one branch, one foliage cluster
	check("exact_queue_acknowledged_recipe_membership_partitions_every_draw_instance",
		captured.get("status") == "ready" \
		and int(partition.get("inputInstanceCount", -1)) == expected_instances \
		and int(partition.get("outputInstanceCount", -1)) == expected_instances \
		and captured.get("memberRows", []).size() == 3)
	check("committed_queue_recipe_and_geometry_values_survive_legacy_visual_removal",
		queue_capture.get("status") == "ready" \
		and queue_capture.get("sourceRevision", "") == captured.get("sourceRevision", "") \
		and queue_capture.get("inputs", []).size() == captured.get("inputs", []).size())
	check("unrelated_durable_removal_does_not_revise_tree_geometry",
		unrelated_removal_capture.get("status") == "ready" \
		and unrelated_removal_capture.get("sourceRevision", "") == captured.get("sourceRevision", ""))
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
	var renderer_tier_by_role := {}
	for row_value: Variant in captured.get("memberRows", []):
		if row_value is Dictionary:
			renderer_tier_by_role[String(row_value.get("role", ""))] = String(
				row_value.get("rendererTier", ""))
	check("recipe_lod_stays_separate_from_native_renderer_categories",
		captured.get("status") == "ready" \
		and captured.get("renderLodTier") == "near" \
		and renderer_tier_by_role == {"bole":"structural", "branches":"structural",
			"foliage":"detail"} \
		and captured.get("compatibilityByKey", {}).values().all(func(value: Dictionary) -> bool:
			return String(value.get("renderTier", "")) in ["silhouette", "structural", "detail", "horizon"]))
	var section_boundaries: Array = captured.get("sectionKeys", [])
	var expected_world_origins: Array[Vector3] = []
	for origin: Vector3 in expected_local_origins:
		expected_world_origins.append(body.global_transform * origin)
	check("tree_instances_are_owned_by_the_partition_of_their_transformed_mesh_bounds",
		captured.get("status") == "ready" \
		and section_boundaries.has(Grid.key_for_world_position(expected_world_origins[0])) \
		and section_boundaries.has(Grid.key_for_world_position(expected_world_origins[1])) \
		and section_boundaries.has(Grid.key_for_world_position(expected_world_origins[2])) \
		and section_boundaries.size() >= 3)
	check("capture_retains_gameplay_body_collision_and_stable_source_identity",
		body.get_node_or_null("TrunkCollision") == collider \
		and collider.shape == cylinder and captured.get("sourceId", "") == "%s:tree:%s" % [authority.seed_text, prop_id] \
		and captured.get("censusStatus", "") == "pending")
	var prepared_members: Array = queue.published_lod_records[0].sectionValueMembers
	body.set_meta("tree_visual_state", "section_candidate_pending")
	var prepared_result := queue.seal_prepared_section_value_record({
		"request":request.duplicate(true), "recipe":recipe,
		"sectionValueMembers":prepared_members, "sectionValueCapturePending":""}, body)
	var prepared_record: Dictionary = prepared_result.get("record", {})
	var prepared_retained := queue.retain_prepared_section_value_record(prepared_record)
	var prepared_publication := {"record":prepared_record, "body":body, "prepared":true}
	var prepared_capture := Adapter.capture_from_prepared_record(queue, authority,
		world_id, body, prepared_record, RemovedProps.capture(authority))
	var prepared_census_revision := ecology._tree_census_source_revision(
		tree_candidate, prepared_publication)
	var prepared_sections := ecology._tree_census_section_keys(prepared_publication)
	prepared_sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	check("prepared_tree_values_are_censusable_before_per_tree_commit",
		prepared_result.get("status") == "ready" \
		and prepared_retained.get("status") == "retained" \
		and prepared_capture.get("status") == "ready" \
		and not prepared_census_revision.is_empty() \
		and prepared_census_revision == ecology._tree_section_source_revision(
			tree_candidate, prepared_capture))
	var old_tree_visual := body.get_node_or_null("GeneratedTreeVisual") as Node3D
	if old_tree_visual == null:
		old_tree_visual = Node3D.new()
		old_tree_visual.name = "GeneratedTreeVisual"
		body.add_child(old_tree_visual)
	body.set_meta("tree_visual_state", "published")
	body.set_meta("visual_source", "procedural_tree_recipe")
	var prepared_capture_during_replacement := Adapter.capture_from_prepared_record(queue,
		authority, world_id, body, prepared_record, RemovedProps.capture(authority))
	check("new_candidate_is_censusable_while_the_old_tree_visual_remains_current",
		prepared_capture_during_replacement.get("status") == "ready" \
		and body.get_node_or_null("GeneratedTreeVisual") == old_tree_visual \
		and String(body.get_meta("tree_visual_state", "")) == "published")
	body.set_meta("tree_visual_state", "section_candidate_pending")
	var superseded_generation := int(prepared_record.get("producerGeneration", 0)) + 1
	body.set_meta("tree_section_recipe_input_expected_generation", superseded_generation)
	var stale_preparation := queue.seal_prepared_section_value_record({
		"enqueueSequence":superseded_generation - 1,
		"bodyGlobalTransform":body.global_transform,
		"request":request.duplicate(true), "recipe":recipe,
		"sectionValueMembers":prepared_members, "sectionValueCapturePending":"",
		"sectionOwnedCompile":true}, body)
	var rejected_old_artifact := queue.retain_prepared_section_value_record(prepared_record)
	check("superseded_tree_generation_cannot_seal_or_replace_retained_candidate",
		stale_preparation.get("status") == "pending" \
		and stale_preparation.get("reason") == "prepared_tree_producer_generation_stale" \
		and rejected_old_artifact.get("status") == "pending" \
		and queue.prepared_section_value_record_for_body(body).get("artifactGeneration", 0) \
			== prepared_record.get("artifactGeneration", -1))
	body.remove_meta("tree_section_recipe_input_expected_generation")
	var accepted_visual_body := StaticBody3D.new()
	accepted_visual_body.set_meta("tree_visual_state", "published")
	accepted_visual_body.set_meta("visual_source", "procedural_tree_recipe")
	var accepted_visual := Node3D.new()
	accepted_visual.name = "GeneratedTreeVisual"
	accepted_visual_body.add_child(accepted_visual)
	queue._set_tree_preparation_state(accepted_visual_body, "section_compile_failed")
	check("replacement_failure_preserves_last_accepted_per_tree_visual_state",
		String(accepted_visual_body.get_meta("tree_visual_state", "")) == "published" \
		and accepted_visual_body.get_node_or_null("GeneratedTreeVisual") == accepted_visual)
	accepted_visual_body.free()
	var prepared_receipts := {}
	for section_key: Vector3i in prepared_sections:
		var receipt := {"status":"installed",
			"sectionKey":section_key, "generation":1,
			"contentManifestDigest":"tree-contract:%s" % section_key}
		receipt.make_read_only()
		prepared_receipts[section_key] = receipt
	var fake_coordinator := TestSectionCoordinator.new()
	fake_coordinator.installed_receipts = prepared_receipts
	authority.tree_publication_queue = queue
	authority.world_static_section_coordinator = fake_coordinator
	ecology._latest_tree_candidate_by_source[String(tree_candidate.sourceId)] = tree_candidate
	for section_key: Vector3i in prepared_sections:
		ecology._latest_by_section[section_key] = {
			String(tree_candidate.sourceId):prepared_census_revision}
		ecology._latest_coverage_by_section[section_key] = \
			"tree-contract-coverage:%s" % section_key
	var section_owner_ack: Dictionary = {}
	for section_key: Vector3i in prepared_sections:
		section_owner_ack = ecology.acknowledge_section_install(section_key,
			String(ecology._latest_coverage_by_section[section_key]),
			prepared_receipts[section_key])
	var section_owned_publication := {"record":queue.published_lod_records[0],
		"body":body, "prepared":false}
	var section_owned_capture := Adapter.capture_from_queue_record(queue, authority,
		world_id, body, RemovedProps.capture(authority))
	check("tree_visual_retires_only_after_all_section_receipts_and_reuses_owned_values",
		section_owner_ack.get("status") == "acknowledged" \
		and section_owner_ack.get("acknowledgedTreeCount", 0) == 1 \
		and String(body.get_meta("tree_visual_state", "")) == "section_owned" \
		and bool(queue.published_lod_records[0].get("sectionOwned", false)) \
		and section_owned_capture.get("status") == "ready" \
		and ecology._tree_census_source_revision(tree_candidate,
			section_owned_publication) == ecology._tree_section_source_revision(
				tree_candidate, section_owned_capture))
	var stale_recipe := recipe.duplicate(true)
	stale_recipe["signature"] = "tree-v10-deadbeef"
	var stale := _make_capture(queue, authority, body, stale_recipe, world_id)
	check("recipe_signature_mismatch_stays_pending_with_revision_diagnostics",
		stale.get("status") == "pending" \
		and stale.get("reason") == "tree_recipe_revision_not_current" \
		and not String(stale.get("queueRequestKey", "")).is_empty() \
		and not String(stale.get("expectedRecipeSignature", "")).is_empty() \
		and stale.get("capturedRecipeSignature") == "tree-v10-deadbeef" \
		and stale.get("bodyRecipeSignature") == String(recipe.get("signature", "")) \
		and stale.get("queueTier") == stale.get("recipeTier") \
		and stale.get("queueTier") == stale.get("bodyTier"))
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
	var stale_record: Dictionary = queue.published_lod_records[0].duplicate()
	stale_record.erase("sectionValueMembers")
	queue.published_lod_records[0] = stale_record
	var proxy_capture := _make_capture(queue, authority, body, recipe, world_id)
	check("missing_queue_geometry_values_do_not_become_visual_success",
		proxy_capture.get("status") == "pending")
	var report := {"schema":"tree-section-value-adapter-contract/v1",
		"checks":checks, "passed":not checks.values().has(false),
		"captureStatus":captured.get("status", "missing"),
		"captureReason":captured.get("reason", ""),
		"sourceId":captured.get("sourceId", ""),
		"collisionPresent":body.get_node_or_null("TrunkCollision") == collider,
		"liveMultiTransform":section_members[1].get("transforms", [])[0],
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
