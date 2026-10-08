extends SceneTree

const Compiler := preload("res://scripts/world/TreeRecipeSectionCompiler.gd")
const QueueScript := preload("res://scripts/environment/TreePublicationQueue.gd")
const RemovedProps := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Adapter := preload("res://scripts/world/TreeSectionValueAdapter.gd")
const EcologyAdapter := preload("res://scripts/world/EcologySectionValueAdapter.gd")
const RuntimeRequestBuilder := preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")
const CertifiedRequestFixture := preload("res://scripts/testing/CertifiedTreeRequestFixture.gd")
const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const ActiveSnapshotScript := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
const VisualFactory := preload("res://scripts/visual/ProceduralTreeVisualFactory.gd")
const ForestProfile := preload("res://resources/visual/biomes/forest.tres")
const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const ProducerDomain := preload("res://scripts/world/EcologyProducerDomain.gd")

class Authority extends Node:
	const DomainScript := preload("res://scripts/world/EcologyProducerDomain.gd")
	const CatalogStore := preload("res://scripts/world/EcologyProducerCatalogContext.gd")
	const BiomeCatalog := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
	const BiomeSnapshot := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
	var seed_text := "tree-recipe-section-compiler-contract"
	var seed_hash := 505
	var removed_props := {}
	var removed_props_revision := 0
	var tree_publication_queue: Node
	var ecology_world_epoch := 1
	var _catalog_store := CatalogStore.new()
	var _catalog_artifact_id := ""
	var _catalog_world_id := ""
	var _publication_sequence := 0
	func detail_mesh(_detail_type: String) -> Mesh: return BoxMesh.new()
	func detail_material(_detail_type: String) -> Material: return StandardMaterial3D.new()
	func _ecology_chunk_source_revision(_key: Vector2i) -> String: return "ecology-test-r1"

	func acquire_ecology_catalog_artifact_lease(artifact_id: String, owner_kind: String,
			owner_key: String, world_id: String, world_epoch: int) -> Dictionary:
		return _catalog_store.acquire_lease(artifact_id, owner_kind, owner_key,
			world_id, world_epoch)

	func resolve_ecology_catalog_artifact(token: String, world_id: String,
			world_epoch: int) -> Dictionary:
		var resolved := _catalog_store.resolve_leased_artifact(token, world_id, world_epoch)
		if resolved.get("status") == "ready":
			resolved["catalogArtifactId"] = String(resolved.get("artifactId", ""))
		return resolved

	func release_ecology_catalog_artifact_lease(token: String) -> Dictionary:
		return _catalog_store.release_lease(token)

	# This fixture remains a resident tree-owner test. These real publication-store
	# facades satisfy the shared adapter contract without adding a source generator.
	func admit_ecology_source_publication(snapshot: Dictionary, catalog_token: String,
			owner_kind: String, owner_key: String) -> Dictionary:
		var resolved := resolve_ecology_catalog_artifact(catalog_token, _catalog_world_id, ecology_world_epoch)
		if resolved.get("status") != "ready": return resolved
		_publication_sequence += 1
		var hold := acquire_ecology_catalog_artifact_lease(_catalog_artifact_id,
			"source_publication", str(_publication_sequence), _catalog_world_id, ecology_world_epoch)
		if hold.get("status") != "ready": return hold
		var result := _catalog_store.publish_source_bundle(snapshot, String(hold.leaseToken),
			owner_kind, owner_key, {"mainInstanceId":get_instance_id(), "worldId":_catalog_world_id,
			"worldEpoch":ecology_world_epoch, "catalogArtifactId":_catalog_artifact_id,
			"catalogContentDigest":String(resolved.artifact.get("catalogContentDigest", ""))})
		if result.get("status") != "ready" or not bool(result.get("catalogLeaseAdopted", false)):
			release_ecology_catalog_artifact_lease(String(hold.leaseToken))
		return result

	func acquire_ecology_source_publication(id: String, kind: String, key: String) -> Dictionary:
		var acquired := _catalog_store.acquire_source_publication_lease(id, kind, key, _catalog_world_id, ecology_world_epoch)
		if acquired.get("status") != "ready": return acquired
		var resolved := resolve_ecology_source_publication(String(acquired.leaseToken), _catalog_world_id, ecology_world_epoch)
		if resolved.get("status") != "ready":
			release_ecology_source_publication(String(acquired.leaseToken))
			return resolved
		acquired["view"] = resolved.view
		return acquired

	func resolve_ecology_source_publication(token: String, world: String, epoch: int) -> Dictionary:
		if world != _catalog_world_id or epoch != ecology_world_epoch:
			return {"status":"failed", "reason":"synthetic_tree_publication_owner_stale"}
		var resolved := _catalog_store.resolve_source_publication(token, world, epoch)
		if resolved.get("status") == "ready" and (String(resolved.view.get("catalogArtifactId", "")) != _catalog_artifact_id \
				or int(resolved.view.ownerReceipt.get("mainInstanceId", 0)) != get_instance_id()):
			return {"status":"failed", "reason":"synthetic_tree_publication_owner_stale"}
		return resolved

	func ecology_source_publication_is_current(token: String, world: String, epoch: int,
			receipt: Dictionary, revision: String, removal: String) -> Dictionary:
		var resolved := resolve_ecology_source_publication(token, world, epoch)
		if resolved.get("status") != "ready": return resolved
		return _catalog_store.source_publication_is_current(token, world, epoch, receipt, revision, removal)

	func ecology_source_publication_local_is_current(view: Dictionary, token: String) -> Dictionary:
		var resolved := resolve_ecology_source_publication(token, String(view.get("worldId", "")), int(view.get("worldEpoch", -1)))
		if resolved.get("status") != "ready" or not is_same(resolved.get("view", {}), view):
			return {"status":"failed", "reason":"synthetic_tree_publication_alias_stale"}
		return {"status":"pending", "reason":"resident_tree_fixture_has_no_source_generation_authority"}

	func ecology_source_publication_record_is_current(view: Dictionary, token: String, _record: Dictionary) -> Dictionary:
		return ecology_source_publication_local_is_current(view, token)

	func release_ecology_source_publication(token: String) -> Dictionary:
		return _catalog_store.release_source_publication_lease(token)

	func seed_catalog_artifact(world_id: String) -> Dictionary:
		var catalog := BiomeCatalog.new()
		if not catalog.setup():
			return {"status":"failed", "reason":"profile_catalog_unavailable"}
		var captured := BiomeSnapshot.capture(catalog)
		if not bool(captured.get("ok", false)):
			return {"status":"failed", "reason":"profile_snapshot_unavailable"}
		var profiles := {"schemaVersion":int(captured.get("schemaVersion", -1)),
			"fallbackId":String(captured.get("fallbackId", "")),
			"contentIdentity":String(captured.get("contentIdentity", "")),
			"profiles":(captured.get("profiles", []) as Array).duplicate(true)}
		var tree_request := DomainScript.derive_tree_request_envelope(profiles)
		var tree_support := DomainScript.derive_tree_grammar_support_envelope(profiles)
		var rock_digest := DomainScript.digest_value(["tree-compiler-rock-catalog-v2",
			profiles.contentIdentity])
		var rock_envelope := {"status":"ready", "profileCatalogRevision":profiles.contentIdentity,
			"eligibleAssetSetDigest":rock_digest, "digest":rock_digest,
			"assetSetDigest":rock_digest, "registryRevision":"tree-compiler-rock-registry-v2",
			"assetRows":[{"assetId":"tree-compiler-bounded-rock",
				"maxHorizontalSupportMeters":2.0, "maxVerticalSupportMeters":2.0}],
			"maxHorizontalSupportMeters":2.0, "maxVerticalSupportMeters":2.0}
		var catalog_inputs := {"biomeProfileSnapshotStatus":"ready",
			"biomeProfileSnapshot":profiles,
			"treeProducerEnvelopeStatus":String(tree_request.get("status", "failed")),
			"treeProducerEnvelope":tree_request,
			"treeGrammarEnvelopeStatus":String(tree_support.get("status", "failed")),
			"treeGrammarEnvelope":tree_support,
			"treeGrammarEnvelopeDigest":String(tree_support.get("digest", "")),
			"rockSupportEnvelopeStatus":"ready", "rockSupportEnvelope":rock_envelope,
			"staticRecipeEnvelopeStatus":"ready",
			"producerCatalogRevision":DomainScript.digest_value([
				"tree-compiler-catalog-v2", profiles.contentIdentity])}
		var interned := _catalog_store.intern_fresh(world_id, seed_text,
			ecology_world_epoch, {"owner":get_instance_id()}, catalog_inputs)
		if String(interned.get("status", "")) == "ready":
			_catalog_artifact_id = String(interned.get("artifactId", ""))
			_catalog_world_id = world_id
		return interned

	func begin_ecology_source_catalog_context_scope() -> Dictionary:
		return _catalog_store.begin_artifact_scope(_catalog_artifact_id,
			_catalog_world_id, ecology_world_epoch)

	func end_ecology_source_catalog_context_scope(scope: Dictionary) -> Dictionary:
		return _catalog_store.end_scope(scope)

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
	request = CertifiedRequestFixture.prepare_or_fail(request)
	if request.is_empty():
		return {"authority":authority, "queue":queue, "body":body,
			"request":request, "recipe":{}, "record":{},
			"worldId":"seed:%s:%d" % [authority.seed_text, authority.seed_hash],
			"removed":RemovedProps.capture_for_ids(authority, [prop_id])}
	var recipe: Dictionary = queue.publication_service.build_recipe(request)
	var sealed := queue.build_tree_section_recipe_input_record(
		{"request":request, "enqueueSequence":1}, body, recipe)
	return {"authority":authority, "queue":queue, "body":body,
		"request":request, "recipe":recipe, "record":sealed.get("record", {}),
		"worldId":"seed:%s:%d" % [authority.seed_text, authority.seed_hash],
		"removed":RemovedProps.capture_for_ids(authority, [prop_id])}


func _run_compiler(fixture: Dictionary, unit_budget: int) -> Dictionary:
	var compiler := Compiler.new()
	var native_dispatcher: RefCounted = fixture.queue._tree_geometry_dispatcher()
	if native_dispatcher == null:
		return {"result":{"status":"pending",
			"reason":"native_tree_geometry_dispatcher_unavailable"}, "steps":0}
	compiler.set_native_tree_geometry_dispatcher(native_dispatcher)
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
		await process_frame
	return {"result":result, "steps":steps, "begin":begun}


func _freeze_tree_value(value: Variant) -> Variant:
	if value is Dictionary:
		var frozen: Dictionary = {}
		for key: Variant in value:
			frozen[key] = _freeze_tree_value(value[key])
		frozen.make_read_only()
		return frozen
	if value is Array:
		var frozen: Array = []
		for item: Variant in value:
			frozen.append(_freeze_tree_value(item))
		frozen.make_read_only()
		return frozen
	return value


func _band_completion_proof_checks() -> Dictionary:
	var compiler := Compiler.new()
	var target := Vector3i(1, 0, 0)
	var owner := Vector3i(0, 0, 0)
	var support_member := {"memberId":"tree:cross-section-support",
		"ownedSectionKey":owner, "supportSectionKeys":[owner, target],
		"conservativeWorldBounds":AABB(Vector3(0, 0, 0), Vector3(16, 8, 16)),
		"meshContentDigest":"mesh-proof", "certifiedEnvelopeDigest":"envelope-proof"}
	var source := {"sourceId":"tree-source:projection", "sourceRevision":"source-r1",
		"sourceRecordDigest":"record-proof", "recipeArtifactRevision":"recipe-r1",
		"recipeSignature":"recipe-signature", "geometryOwnership":[support_member]}
	var empty_owner_result: Dictionary = compiler._build_band_completion_proof(
		target, ["tree-source:projection"], [source], [], {})
	var no_source_result: Dictionary = compiler._build_band_completion_proof(
		target, [], [], [], {})
	var missing_completion_result: Dictionary = compiler._build_band_completion_proof(
		target, ["tree-source:projection"], [], [], {})
	var duplicate_member_source: Dictionary = source.duplicate(true)
	duplicate_member_source["geometryOwnership"] = [support_member, support_member.duplicate(true)]
	var duplicate_geometry_result: Dictionary = compiler._build_band_completion_proof(
		target, ["tree-source:projection"], [duplicate_member_source], [], {})
	var owned_member: Dictionary = support_member.duplicate(true)
	owned_member["ownedSectionKey"] = target
	owned_member["supportSectionKeys"] = [target]
	owned_member["conservativeWorldBounds"] = AABB(Vector3(16, 0, 0), Vector3(16, 8, 16))
	var owned_source: Dictionary = source.duplicate(true)
	owned_source["geometryOwnership"] = [owned_member]
	var identity := Compiler._source_part_identity_key("tree-source:projection",
		"tree:cross-section-support")
	var mesh_key := "tree.runtime.mesh-proof"
	var material_key := "tree.material.material-proof"
	var compatibility := {"batchKey":"tree-batch:opaque",
		"compatibilityKey":"tree-batch:opaque", "renderLayer":"opaque",
		"meshResourceKey":mesh_key, "materialKey":material_key,
		"meshKey":"tree.runtime.mesh-proof|pipeline=test|layer=opaque",
		"pipelineRevision":"tree-pipeline-test", "translucentSortPolicy":"none",
		"meshContentDigest":"mesh-proof", "materialContentDigest":"material-proof"}
	var packed_attributes: Array = []
	for attribute_index: int in range(Attributes.FLOATS_PER_INSTANCE):
		packed_attributes.append(0.0)
	var batch := {"sectionKey":target, "batchKey":"tree-batch:opaque",
		"compatibilityKey":compatibility, "renderLayer":"opaque",
		"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"instanceCount":1, "instanceAttributes":packed_attributes,
		"meshKey":mesh_key, "materialKey":material_key,
		"meshContentDigest":"mesh-proof", "materialContentDigest":"material-proof",
		"contributors":{identity:{"sourceId":"tree-source:projection",
			"sourcePartId":"tree:cross-section-support", "sourceRevision":"source-r1",
			"instanceAttributeOffsets":[0], "instanceAttributes":packed_attributes.duplicate()}}}
	var owned_batch_result: Dictionary = compiler._build_band_completion_proof(
		target, ["tree-source:projection"], [owned_source], [batch],
		{mesh_key:"mesh-proof", material_key:"material-proof"})
	var tampered_batch: Dictionary = batch.duplicate(true)
	tampered_batch["instanceAttributes"][0] = 1.0
	var tampered_attributes_result: Dictionary = compiler._build_band_completion_proof(
		target, ["tree-source:projection"], [owned_source], [tampered_batch],
		{mesh_key:"mesh-proof", material_key:"material-proof"})
	return {"supportOnlyReady":empty_owner_result.get("status") == "ready",
		"supportOnlyDisposition":String(empty_owner_result.get("disposition", "")),
		"supportOnlyManifestHasCompleteZeroOwner":empty_owner_result.get(
			"sourceCompletionManifest", []).size() == 1 \
			and empty_owner_result.sourceCompletionManifest[0].get("completionState", "") == "complete" \
			and empty_owner_result.sourceCompletionManifest[0].get("ownerMemberIds", []).is_empty() \
			and empty_owner_result.sourceCompletionManifest[0].get("supportMemberIds", []) \
			== ["tree:cross-section-support"],
		"explicitEmptySourceProjectionReady":no_source_result.get("status") == "ready" \
			and String(no_source_result.get("disposition", "")) == "complete_empty",
		"missingSourceCompletionRejected":missing_completion_result.get("status") != "ready",
		"duplicateGeometryOwnershipRejected":duplicate_geometry_result.get("status") != "ready",
		"currentOwnerBatchAccepted":owned_batch_result.get("status") == "ready" \
			and String(owned_batch_result.get("disposition", "")) == "complete_nonempty",
		"aggregateBatchAttributeTamperRejected":tampered_attributes_result.get("status") != "ready"}


func _native_foliage_parity_case(fixture: Dictionary, family: Dictionary) -> Dictionary:
	var request: Dictionary = fixture.request.duplicate(true)
	request["presentation"] = "review"
	request["biome"] = String(family.biome)
	request["architecture"] = String(family.architecture)
	request["speciesGrammar"] = String(family.grammar)
	request["renderLodTier"] = String(family.lod)
	var normalized: Dictionary = fixture.queue.publication_service.normalize_request(request)
	var mutable_recipe: Dictionary = fixture.queue.publication_service.build_recipe(request)
	if normalized.is_empty() or mutable_recipe.is_empty() \
			or bool(mutable_recipe.get("runtimeImpostor", false)):
		return {"status":"failed", "reason":"canonical_tree_recipe_unavailable",
			"family":family}
	var recipe: Dictionary = _freeze_tree_value(mutable_recipe)
	var factory := VisualFactory.new()
	var reference: Dictionary = factory.begin_runtime_foliage_build(recipe,
		recipe.get("foliage", []), String(family.biome), String(request.treeId))
	if bool(reference.get("headlessVisualProxy", false)):
		return {"status":"failed", "reason":"headed_foliage_reference_unavailable",
			"family":family}
	var reference_multi: MultiMesh = reference.multiMesh
	var reference_foliage: Array = reference.foliage
	reference_multi.instance_count = 0
	reference_multi.use_colors = true
	reference_multi.instance_count = reference_foliage.size()
	var reference_steps := 0
	while not factory.advance_runtime_foliage_build(reference, 64):
		reference_steps += 1
		if reference_steps > 64:
			return {"status":"failed", "reason":"factory_foliage_reference_stalled",
				"family":family}
	# The candidate ABI explicitly carries white instance color when the recipe
	# factory's source MultiMesh has colors disabled.
	for index in range(reference_multi.instance_count):
		reference_multi.set_instance_color(index, Color.WHITE)
	var expected: PackedFloat32Array = reference_multi.buffer
	var dispatcher: RefCounted = ClassDB.instantiate("NativeTreeGeometryDispatcher") as RefCounted
	if dispatcher == null:
		return {"status":"failed", "reason":"native_tree_geometry_dispatcher_instantiation_failed",
			"family":family}
	var source_key := "%s:%s:%s" % [family.architecture, family.lod, request.treeId]
	var identity := {"worldId":fixture.worldId, "worldEpoch":"parity-contract-v1",
		"sourceId":source_key, "sourceRevision":"source-r1",
		"recipeSignature":String(recipe.get("signature", "")), "artifactGeneration":1,
		"sourceRecordDigest":"source-digest", "sourceProvenanceDigest":"provenance-digest",
		"requestDigest":"request-digest"}
	var admission: Dictionary = dispatcher.call("submit_foliage_compile", recipe,
		String(family.biome), String(request.treeId), identity)
	if admission.get("status") != "pending":
		dispatcher.call("drain_tree_geometry_compiles")
		return {"status":"failed", "reason":String(admission.get("reason", "native_foliage_admission_failed")),
			"family":family}
	var ticket := int(admission.get("ticket", 0))
	var polled: Dictionary = {}
	for _attempt in range(3000):
		polled = dispatcher.call("poll_tree_geometry_compile", ticket)
		if String(polled.get("status", "")) not in ["queued", "running"]:
			break
		await process_frame
	var completed: Dictionary = dispatcher.call("take_tree_geometry_compile_result", ticket) \
		if polled.get("status") == "ready" else polled
	var actual: Variant = completed.get("instanceValues", null)
	var max_error := 0.0
	var max_error_index := -1
	var parity: bool = actual is PackedFloat32Array and actual.size() == expected.size()
	# Compare through the same MultiMesh API the production installer uses. The
	# buffer getter is an engine upload representation and can quantize custom
	# data, while get_instance_custom_data reports the renderer-facing value.
	if parity:
		var native_multi := MultiMesh.new()
		native_multi.transform_format = MultiMesh.TRANSFORM_3D
		native_multi.use_colors = true
		native_multi.use_custom_data = true
		native_multi.mesh = reference_multi.mesh
		native_multi.instance_count = reference_multi.instance_count
		native_multi.set_buffer(actual)
		for instance_index in range(reference_multi.instance_count):
			var expected_lanes := Attributes.encode(
				reference_multi.get_instance_transform(instance_index),
				reference_multi.get_instance_custom_data(instance_index),
				reference_multi.get_instance_color(instance_index))
			var actual_lanes := Attributes.encode(
				native_multi.get_instance_transform(instance_index),
				native_multi.get_instance_custom_data(instance_index),
				native_multi.get_instance_color(instance_index))
			for lane in range(Attributes.FLOATS_PER_INSTANCE):
				var lane_error := absf(float(expected_lanes[lane]) - float(actual_lanes[lane]))
				if lane_error > max_error:
					max_error = lane_error
					max_error_index = instance_index * Attributes.FLOATS_PER_INSTANCE + lane
				if max_error > 0.00002:
					parity = false
					break
			if not parity: break
	dispatcher.call("release_tree_geometry_compile", ticket)
	var release_metrics: Dictionary = dispatcher.call("tree_geometry_compile_metrics")
	dispatcher.call("drain_tree_geometry_compiles")
	return {"status":"ready" if parity else "failed", "family":family,
		"recipeSignature":String(recipe.signature), "instanceCount":expected.size() / Attributes.FLOATS_PER_INSTANCE,
		"packedFloatCount":expected.size(), "maxAbsolutePackedFloatError":max_error,
		"maxErrorIndex":max_error_index,
		"expectedAtMaxError":float(expected[max_error_index]) if max_error_index >= 0 else null,
		"actualAtMaxError":float(actual[max_error_index]) if max_error_index >= 0 \
			and actual is PackedFloat32Array else null,
		"jobCountAfterRelease":int(release_metrics.get("jobCount", -1)),
		"retainedOutputFloatsAfterRelease":int(release_metrics.get("retainedOutputFloats", -1)),
		"statusReason":String(completed.get("reason", ""))}


func _native_branch_parity_case(fixture: Dictionary, family: Dictionary) -> Dictionary:
	var request: Dictionary = fixture.request.duplicate(true)
	request["presentation"] = "review"
	request["biome"] = String(family.biome)
	request["architecture"] = String(family.architecture)
	request["speciesGrammar"] = String(family.grammar)
	request["renderLodTier"] = String(family.lod)
	var recipe_value: Dictionary = fixture.queue.publication_service.build_recipe(request)
	if recipe_value.is_empty() or bool(recipe_value.get("runtimeImpostor", false)):
		return {"status":"failed", "reason":"canonical_branch_recipe_unavailable", "family":family}
	var recipe: Dictionary = _freeze_tree_value(recipe_value)
	var branch_values: Variant = recipe.get("branches", null)
	if not branch_values is Array:
		return {"status":"failed", "reason":"canonical_branch_values_missing", "family":family}
	var typed_branches: Array[Dictionary] = []
	for branch_value: Variant in branch_values:
		if not branch_value is Dictionary:
			return {"status":"failed", "reason":"canonical_branch_value_invalid", "family":family}
		typed_branches.append(branch_value)
	var factory := VisualFactory.new()
	var reference: Dictionary = factory.begin_runtime_distal_build(recipe,
		typed_branches, String(family.biome), String(request.treeId))
	if reference.is_empty() or bool(reference.get("headlessVisualProxy", false)):
		return {"status":"failed", "reason":"headed_branch_reference_unavailable", "family":family}
	var reference_steps := 0
	while not factory.advance_runtime_distal_build(reference, 64):
		reference_steps += 1
		if reference_steps > 64:
			return {"status":"failed", "reason":"factory_branch_reference_stalled", "family":family}
	var reference_multi: MultiMesh = reference.multiMesh
	var distal_count := reference_multi.instance_count
	var expected := PackedFloat32Array()
	expected.resize(distal_count * Attributes.FLOATS_PER_INSTANCE)
	for index in range(distal_count):
		var lanes: PackedFloat32Array = Attributes.encode(reference_multi.get_instance_transform(index),
			reference_multi.get_instance_custom_data(index), Color.WHITE)
		for lane in range(Attributes.FLOATS_PER_INSTANCE):
			expected[index * Attributes.FLOATS_PER_INSTANCE + lane] = lanes[lane]
	var dispatcher: RefCounted = ClassDB.instantiate("NativeTreeGeometryDispatcher") as RefCounted
	if dispatcher == null:
		return {"status":"failed", "reason":"native_tree_geometry_dispatcher_instantiation_failed", "family":family}
	var identity := {"worldId":fixture.worldId, "worldEpoch":"record-parity-v1",
		"sourceId":"%s:%s:%s" % [family.architecture, family.lod, request.treeId],
		"sourceRevision":"source-r1", "recipeSignature":String(recipe.signature),
		"artifactGeneration":1, "sourceRecordDigest":"record-digest",
		"sourceProvenanceDigest":"provenance-digest", "requestDigest":"request-digest"}
	var admission: Dictionary = dispatcher.call("submit_tree_record_compile", recipe,
		String(family.biome), String(request.treeId), identity)
	if admission.get("status") != "pending":
		dispatcher.call("drain_tree_geometry_compiles")
		return {"status":"failed", "reason":String(admission.get("reason", "tree_record_admission_failed")), "family":family}
	var ticket := int(admission.get("ticket", 0))
	var polled: Dictionary = {}
	for _attempt in range(3000):
		polled = dispatcher.call("poll_tree_geometry_compile", ticket)
		if String(polled.get("status", "")) not in ["queued", "running"]: break
		await process_frame
	var completed: Dictionary = dispatcher.call("take_tree_geometry_compile_result", ticket) \
		if polled.get("status") == "ready" else polled
	var actual: Variant = completed.get("branchInstanceValues", null)
	var max_error := 0.0
	var parity: bool = completed.get("status") == "ready" and actual is PackedFloat32Array \
		and actual.size() == expected.size() \
		and int(completed.get("branchInstanceCount", -1)) == distal_count \
		and completed.get("identity", {}) == identity
	if parity:
		var native_multi := MultiMesh.new()
		native_multi.transform_format = MultiMesh.TRANSFORM_3D
		native_multi.use_colors = true
		native_multi.use_custom_data = true
		native_multi.mesh = reference_multi.mesh
		native_multi.instance_count = distal_count
		native_multi.set_buffer(actual)
		for index in range(distal_count):
			var expected_lanes: PackedFloat32Array = Attributes.encode(
				reference_multi.get_instance_transform(index),
				reference_multi.get_instance_custom_data(index), Color.WHITE)
			var actual_lanes: PackedFloat32Array = Attributes.encode(
				native_multi.get_instance_transform(index),
				native_multi.get_instance_custom_data(index),
				native_multi.get_instance_color(index))
			for lane in range(Attributes.FLOATS_PER_INSTANCE):
				max_error = maxf(max_error, absf(expected_lanes[lane] - actual_lanes[lane]))
			if max_error > 0.00002:
				parity = false
				break
	# Replaced source and recipe epochs are independent invalidation cases.
	var replaced_source_identity: Dictionary = identity.duplicate(true)
	replaced_source_identity["sourceRevision"] = "source-r2"
	var source_epoch_rejected := not Compiler.native_tree_record_identity_is_current(
		completed.get("identity", {}), replaced_source_identity)
	var replaced_recipe_identity: Dictionary = identity.duplicate(true)
	replaced_recipe_identity["recipeSignature"] = String(recipe.signature) + ":replacement"
	var recipe_epoch_rejected := not Compiler.native_tree_record_identity_is_current(
		completed.get("identity", {}), replaced_recipe_identity)
	var stale_rejected := source_epoch_rejected and recipe_epoch_rejected
	dispatcher.call("release_tree_geometry_compile", ticket)
	dispatcher.call("drain_tree_geometry_compiles")
	return {"status":"ready" if parity and stale_rejected else "failed", "family":family,
		"recipeSignature":String(recipe.signature), "instanceCount":distal_count,
		"maxAbsolutePackedFloatError":max_error, "sourceEpochEchoed":String(
			completed.get("identity", {}).get("sourceRevision", "")),
		"replacementEpochRejected":stale_rejected,
		"replacedSourceEpochRejected":source_epoch_rejected,
		"replacedRecipeEpochRejected":recipe_epoch_rejected}


func _native_dispatcher_lifecycle_checks(fixture: Dictionary) -> Dictionary:
	var dispatcher: RefCounted = ClassDB.instantiate("NativeTreeGeometryDispatcher") as RefCounted
	if dispatcher == null:
		return {"cancelled":false, "capacityBounded":false,
			"reason":"native_tree_geometry_dispatcher_instantiation_failed"}
	var source_recipe: Dictionary = fixture.record.recipeSnapshot
	var anchor_values: Array = source_recipe.get("foliage", [])
	if anchor_values.is_empty():
		dispatcher.call("drain_tree_geometry_compiles")
		return {"cancelled":false, "capacityBounded":false,
			"reason":"canonical_foliage_anchor_missing"}
	var expanded: Array = []
	for _index in range(4096): expanded.append(anchor_values[0].duplicate(true))
	var running_cancel: Dictionary = source_recipe.duplicate(true)
	running_cancel["foliage"] = expanded
	running_cancel["signature"] = "tree-native-running-cancel-contract"
	var running_cancel_recipe: Dictionary = _freeze_tree_value(running_cancel)
	var cancellation_identity := {"worldId":fixture.worldId, "worldEpoch":"cancel-contract",
		"sourceId":"cancelled-tree", "sourceRevision":"r1",
		"recipeSignature":String(running_cancel_recipe.signature), "artifactGeneration":1,
		"sourceRecordDigest":"source", "sourceProvenanceDigest":"provenance",
		"requestDigest":"request"}
	var submitted: Dictionary = dispatcher.call("submit_tree_record_compile", running_cancel_recipe,
		"forest", "cancelled-tree", cancellation_identity)
	var cancelled := false
	var observed_running := false
	var cancellation_release: Dictionary = {}
	if submitted.get("status") == "pending":
		var ticket := int(submitted.ticket)
		for _attempt in range(10000):
			var polled: Dictionary = dispatcher.call("poll_tree_geometry_compile", ticket)
			if String(polled.get("status", "")) == "running":
				observed_running = true
				break
			if String(polled.get("status", "")) != "queued": break
		var cancel_result: Dictionary = {}
		var post_cancel: Dictionary = {}
		if observed_running:
			cancel_result = dispatcher.call("cancel_tree_geometry_compile", ticket)
			for _attempt in range(3000):
				post_cancel = dispatcher.call("poll_tree_geometry_compile", ticket)
				if String(post_cancel.get("status", "")) not in ["queued", "running"]:
					break
				await process_frame
			cancellation_release = dispatcher.call("release_tree_geometry_compile", ticket)
			for _attempt in range(3000):
				var metrics: Dictionary = dispatcher.call("tree_geometry_compile_metrics")
				if int(metrics.get("jobCount", -1)) == 0: break
				await process_frame
			var after_running_cancel: Dictionary = dispatcher.call("tree_geometry_compile_metrics")
			cancelled = cancel_result.get("status") == "ready" \
				and post_cancel.get("status") == "cancelled" \
				and int(after_running_cancel.get("jobCount", -1)) == 0 \
				and int(after_running_cancel.get("retainedOutputFloats", -1)) == 0 \
				and cancellation_release.get("status") in ["ready", "pending"]
		else:
			dispatcher.call("cancel_tree_geometry_compile", ticket)
			cancellation_release = dispatcher.call("release_tree_geometry_compile", ticket)
			for _attempt in range(3000):
				var metrics: Dictionary = dispatcher.call("tree_geometry_compile_metrics")
				if int(metrics.get("jobCount", -1)) == 0: break
				await process_frame
	var tickets: Array[int] = []
	var capacity_bounded := true
	var limited: Dictionary = source_recipe.duplicate(true)
	limited["foliage"] = [anchor_values[0].duplicate(true)]
	limited["signature"] = "tree-native-capacity-contract"
	var limited_recipe: Dictionary = _freeze_tree_value(limited)
	for index in range(129):
		var identity := cancellation_identity.duplicate(true)
		identity["sourceId"] = "capacity-tree-%d" % index
		identity["recipeSignature"] = String(limited_recipe.signature)
		var admitted: Dictionary = dispatcher.call("submit_foliage_compile", limited_recipe,
			"forest", "capacity-tree-%d" % index, identity)
		if index < 128 and admitted.get("status") == "pending":
			tickets.append(int(admitted.ticket))
		elif index == 128:
			capacity_bounded = admitted.get("status") == "backpressure" \
				and String(admitted.get("reason", "")) == "tree_geometry_dispatcher_capacity"
		else:
			capacity_bounded = false
			break
	var cleanup: Dictionary = dispatcher.call("drain_tree_geometry_compiles")
	var after_capacity_cleanup: Dictionary = dispatcher.call("tree_geometry_compile_metrics")
	return {"cancelled":cancelled, "runningObserved":observed_running,
		"cancellationRelease":cancellation_release,
		"capacityBounded":capacity_bounded, "admittedBeforeBackpressure":tickets.size(),
		"cleanup":cleanup,
		"jobCountAfterCapacityCleanup":int(after_capacity_cleanup.get("jobCount", -1)),
		"retainedOutputFloatsAfterCapacityCleanup":int(
			after_capacity_cleanup.get("retainedOutputFloats", -1))}


func _world_aabb_from_corners(local_bounds: AABB, world_transform: Transform3D) -> AABB:
	var world_bounds := AABB()
	var has_point := false
	for x: float in [local_bounds.position.x, local_bounds.end.x]:
		for y: float in [local_bounds.position.y, local_bounds.end.y]:
			for z: float in [local_bounds.position.z, local_bounds.end.z]:
				var world_point: Vector3 = world_transform * Vector3(x, y, z)
				if not has_point:
					world_bounds = AABB(world_point, Vector3.ZERO)
					has_point = true
				else:
					world_bounds = world_bounds.expand(world_point)
	return world_bounds


func _aabb_corners(bounds: AABB) -> Array[Vector3]:
	var corners: Array[Vector3] = []
	for x: float in [bounds.position.x, bounds.end.x]:
		for y: float in [bounds.position.y, bounds.end.y]:
			for z: float in [bounds.position.z, bounds.end.z]:
				corners.append(Vector3(x, y, z))
	return corners


func _aabb_from_points(points: Array[Vector3]) -> AABB:
	if points.is_empty():
		return AABB()
	var bounds := AABB(points[0], Vector3.ZERO)
	for point: Vector3 in points.slice(1):
		bounds = bounds.expand(point)
	return bounds


func _aabb_matches(left: AABB, right: AABB, epsilon := 0.0001) -> bool:
	return left.position.distance_to(right.position) <= epsilon \
		and left.size.distance_to(right.size) <= epsilon


func _runtime_instance_transforms(request: Dictionary, recipe: Dictionary,
		prop_id: String) -> Dictionary:
	var factory := VisualFactory.new()
	var role_transforms: Dictionary = {"bole":[Transform3D.IDENTITY],
		"branches":[], "foliage":[]}
	var branches: Array = recipe.get("branches", [])
	for branch_value: Variant in branches:
		if not branch_value is Dictionary or int(branch_value.get("order", 1)) == 0:
			continue
		role_transforms.branches.append(factory.branch_transform(
			branch_value.get("start", Vector3.ZERO), branch_value.get("end", Vector3.UP),
			maxf(0.025, float(branch_value.get("radiusStart", 0.1)))))
	for foliage_value: Variant in recipe.get("foliage", []):
		if not foliage_value is Dictionary:
			continue
		var rotation: Vector3 = foliage_value.get("rotation", Vector3.ZERO)
		var scale: Vector3 = foliage_value.get("scale", Vector3.ONE)
		role_transforms.foliage.append(Transform3D(
			Basis.from_euler(rotation).scaled(scale),
			foliage_value.get("position", Vector3.ZERO)))
	return role_transforms


func _ownership_for_compiled_instance(role: String, world_transform: Transform3D,
		ownership_rows: Array, role_transforms: Dictionary,
		tree_world_position: Vector3) -> Dictionary:
	var transforms: Array = role_transforms.get(role, [])
	for row_value: Variant in ownership_rows:
		if not row_value is Dictionary or String(row_value.get("role", "")) != role:
			continue
		var index := int(row_value.get("instanceIndex", -1))
		if index < 0 or index >= transforms.size() or not transforms[index] is Transform3D:
			continue
		var local_transform: Transform3D = transforms[index]
		var expected_world_transform: Transform3D = Transform3D(Basis.IDENTITY,
			tree_world_position) * local_transform
		if expected_world_transform.origin.distance_to(world_transform.origin) <= 0.001 \
				and expected_world_transform.basis.is_equal_approx(world_transform.basis):
			return row_value
	return {}


func _sorted_section_keys(keys: Array) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for key_value: Variant in keys:
		if key_value is Vector3i:
			result.append(key_value)
	result.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	return result


func _native_section_pack_differential(fixture: Dictionary) -> Dictionary:
	var dispatcher: RefCounted = ClassDB.instantiate("NativeTreeGeometryDispatcher") as RefCounted
	if dispatcher == null:
		return {"status":"failed", "reason":"native_tree_geometry_dispatcher_instantiation_failed"}
	var body := Transform3D(Basis.from_euler(Vector3(0.07, 0.31, -0.11)).scaled(
		Vector3(1.2, 0.85, 0.9)), Vector3(-32.0, 0.0, 32.0))
	var mesh_bounds := AABB(Vector3(-0.6, -0.2, -0.6), Vector3(1.2, 2.0, 1.2))
	var desired_centers: Array[Vector3] = [
		Vector3(-16.0, 0.0, 0.0), Vector3(-31.7, 0.2, 16.2),
		Vector3(16.0, 15.8, -16.0), Vector3(1000000.0, 0.0, -1000000.0)]
	var transforms: Array[Transform3D] = []
	var values := PackedFloat32Array()
	for index in range(desired_centers.size()):
		var local_origin := body.affine_inverse() * desired_centers[index]
		var local := Transform3D(Basis.from_euler(Vector3(0.13 * index, -0.09 * index,
			0.04 * index)).scaled(Vector3(0.7 + 0.1 * index, 1.1, 0.8)), local_origin)
		transforms.append(local)
		values.append_array(Attributes.encode(local,
			Color(0.1 * index, 0.4, 0.6, 0.8), Color(0.8, 0.9, 1.0, 1.0)))
	var input_array: Array = []
	for value: float in values:
		input_array.append(value)
	var identity := {"worldId":fixture.worldId, "worldEpoch":"pack-differential-v1",
		"sourceId":"tree-pack-differential", "sourceRevision":"source-r1",
		"recipeSignature":"recipe-r1", "artifactGeneration":1,
		"sourceRecordDigest":"record-digest", "sourceProvenanceDigest":"provenance-digest",
		"requestDigest":"request-digest"}
	var packet := {"role":"foliage", "sourcePartId":"foliage",
		"batchKey":"tree-pack-differential-batch",
		"meshContentDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"supportEnvelopePolicyRevision":"tree-factory-support-envelope/v2",
		"meshLocalBounds":mesh_bounds, "sourceGlobalTransform":body,
		"certifiedWorldBounds":AABB(Vector3(-1100000.0, -100.0, -1100000.0),
			Vector3(2200000.0, 200.0, 2200000.0)),
		"windEnvelopeDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"windHorizontalMeters":0.9, "windVerticalMeters":0.3,
		"sectionSize":Grid.SECTION_SIZE_METERS, "instanceValues":values}
	var narrowed_size_packet := packet.duplicate(true)
	narrowed_size_packet["sectionSize"] = 1.0e-46
	var narrowed_size_admission: Dictionary = dispatcher.call(
		"submit_tree_section_pack", narrowed_size_packet, identity)
	var narrowed_section_size_rejected: bool = narrowed_size_admission.get("status") == "failed" \
		and String(narrowed_size_admission.get("reason", "")) \
			== "tree_section_pack_section_size_not_representable"
	var admission: Dictionary = dispatcher.call("submit_tree_section_pack", packet, identity)
	var standard_section_size_accepted: bool = admission.get("status") == "pending" \
		and float(packet.get("sectionSize", 0.0)) == Grid.SECTION_SIZE_METERS
	if admission.get("status") != "pending":
		dispatcher.call("drain_tree_geometry_compiles")
		return {"status":"failed", "reason":String(admission.get("reason", "pack_admission_failed")),
			"narrowedSectionSizeRejected":narrowed_section_size_rejected,
			"standardSectionSizeAccepted":standard_section_size_accepted}
	var ticket := int(admission.get("ticket", 0))
	var polled: Dictionary = {}
	for _attempt in range(10000):
		polled = dispatcher.call("poll_tree_geometry_compile", ticket)
		if String(polled.get("status", "")) not in ["queued", "running"]:
			break
		await process_frame
	if polled.get("status") != "ready":
		dispatcher.call("release_tree_geometry_compile", ticket)
		dispatcher.call("drain_tree_geometry_compiles")
		return {"status":"failed", "reason":String(polled.get("reason", "pack_worker_not_ready"))}
	var take_started := Time.get_ticks_usec()
	var completed: Dictionary = dispatcher.call("take_tree_geometry_compile_result", ticket)
	var materialization_usec := maxi(0, Time.get_ticks_usec() - take_started)
	var seen := {}
	var max_attribute_error := 0.0
	var supports_exact := true
	var owners_exact := true
	var support_mismatch: Dictionary = {}
	var attribute_mismatch: Dictionary = {}
	var large_coordinate_witness: Dictionary = {}
	for section_value: Variant in completed.get("sections", []):
		if not section_value is Dictionary:
			supports_exact = false
			continue
		var section: Dictionary = section_value
		var owner_section: Vector3i = section.sectionKey
		var section_attributes: Array = section.instanceAttributes
		for member_value: Variant in section.members:
			var member: Dictionary = member_value
			var index := int(member.get("instanceIndex", -1))
			var offset := int(member.get("attributeOffset", -1))
			if index < 0 or index >= transforms.size() or offset < 0 \
					or offset * Attributes.FLOATS_PER_INSTANCE + Attributes.FLOATS_PER_INSTANCE \
						> section_attributes.size() or seen.has(index):
				supports_exact = false
				continue
			seen[index] = true
			var local := Attributes.decode_transform(input_array,
				index * Attributes.FLOATS_PER_INSTANCE)
			var world_transform := body * local
			var world_bounds: AABB = world_transform * mesh_bounds
			var expansion := Vector3(0.9, 0.3, 0.9)
			world_bounds = AABB(world_bounds.position - expansion,
				world_bounds.size + expansion * 2.0)
			var expected_owner := Grid.key_for_world_position(world_bounds.get_center())
			var expected_support := Grid.keys_intersecting_bounds(world_bounds)
			owners_exact = owners_exact and expected_owner == owner_section \
				and member.get("ownedSectionKey") == expected_owner
			var member_supports: Array = member.get("supportSectionKeys", [])
			var member_bounds: AABB = member.get("worldBounds", AABB())
			var support_match := member_supports == expected_support \
				and expected_support.has(expected_owner) \
				and member_bounds.is_equal_approx(world_bounds)
			if not support_match and support_mismatch.is_empty():
				support_mismatch = {"instanceIndex":index, "expectedSupport":expected_support,
					"actualSupport":member_supports, "expectedBounds":world_bounds,
					"actualBounds":member_bounds}
			supports_exact = supports_exact and support_match
			var expected_attributes := Attributes.encode(
				Transform3D(Basis.IDENTITY, -Grid.origin_for_key(expected_owner)) * world_transform,
				Color(0.1 * index, 0.4, 0.6, 0.8), Color(0.8, 0.9, 1.0, 1.0))
			var actual_offset := offset * Attributes.FLOATS_PER_INSTANCE
			if index == 3:
				large_coordinate_witness = {"instanceIndex":index,
					"expectedOwner":expected_owner, "actualOwner":member.get("ownedSectionKey"),
					"expectedSupport":expected_support, "actualSupport":member_supports,
					"expectedWorldBounds":world_bounds, "actualWorldBounds":member_bounds,
					"expectedSectionLocalOrigin":Vector3(expected_attributes[3],
						expected_attributes[7], expected_attributes[11]),
					"actualSectionLocalOrigin":Vector3(section_attributes[actual_offset + 3],
						section_attributes[actual_offset + 7], section_attributes[actual_offset + 11])}
			for lane in range(Attributes.FLOATS_PER_INSTANCE):
				var error := absf(float(section_attributes[actual_offset + lane]) \
					- float(expected_attributes[lane]))
				if error > max_attribute_error:
					max_attribute_error = error
					attribute_mismatch = {"instanceIndex":index, "lane":lane,
						"expected":float(expected_attributes[lane]),
						"actual":float(section_attributes[actual_offset + lane])}
	var stale_identity := identity.duplicate(true)
	stale_identity["sourceRevision"] = "source-r2"
	var stale_rejected := not Compiler.native_tree_record_identity_is_current(
		completed.get("identity", {}), stale_identity)
	dispatcher.call("release_tree_geometry_compile", ticket)
	var rejected_packet := packet.duplicate(true)
	rejected_packet["certifiedWorldBounds"] = AABB(Vector3(-1.0, -1.0, -1.0),
		Vector3(2.0, 2.0, 2.0))
	var rejected_admission: Dictionary = dispatcher.call("submit_tree_section_pack",
		rejected_packet, identity)
	var certified_envelope_rejected := false
	if rejected_admission.get("status") == "pending":
		var rejected_ticket := int(rejected_admission.ticket)
		var rejected_result: Dictionary = {}
		for _attempt in range(10000):
			rejected_result = dispatcher.call("poll_tree_geometry_compile", rejected_ticket)
			if String(rejected_result.get("status", "")) not in ["queued", "running"]:
				break
			await process_frame
		certified_envelope_rejected = rejected_result.get("status") == "failed" \
			and String(rejected_result.get("reason", "")) \
				== "tree_compiled_instance_exceeds_certified_envelope"
		dispatcher.call("release_tree_geometry_compile", rejected_ticket)
	var support_budget_packet := packet.duplicate(true)
	support_budget_packet["meshLocalBounds"] = AABB(Vector3(-256.0, -256.0, -256.0),
		Vector3(512.0, 512.0, 512.0))
	support_budget_packet["certifiedWorldBounds"] = AABB(Vector3(-1100000.0, -1100000.0, -1100000.0),
		Vector3(2200000.0, 2200000.0, 2200000.0))
	var support_budget_admission: Dictionary = dispatcher.call("submit_tree_section_pack",
		support_budget_packet, identity)
	var support_budget_rejected := false
	if support_budget_admission.get("status") == "pending":
		var support_budget_ticket := int(support_budget_admission.ticket)
		var support_budget_result: Dictionary = {}
		for _attempt in range(10000):
			support_budget_result = dispatcher.call("poll_tree_geometry_compile",
				support_budget_ticket)
			if String(support_budget_result.get("status", "")) not in ["queued", "running"]:
				break
			await process_frame
		support_budget_rejected = support_budget_result.get("status") == "failed" \
			and String(support_budget_result.get("reason", "")) \
				== "tree_instance_support_section_budget_exceeded"
		dispatcher.call("release_tree_geometry_compile", support_budget_ticket)
	var metrics: Dictionary = dispatcher.call("tree_geometry_compile_metrics")
	dispatcher.call("drain_tree_geometry_compiles")
	return {"status":"ready" if completed.get("status") == "ready" \
			and seen.size() == transforms.size() and owners_exact and supports_exact \
			and max_attribute_error <= 0.0001 and stale_rejected \
			and certified_envelope_rejected and support_budget_rejected \
			and narrowed_section_size_rejected and standard_section_size_accepted \
			and int(metrics.get("jobCount", -1)) == 0 else "failed",
		"instanceCount":transforms.size(), "observedInstanceCount":seen.size(),
		"narrowedSectionSizeRejected":narrowed_section_size_rejected,
		"standardSectionSizeAccepted":standard_section_size_accepted,
		"ownersExact":owners_exact, "supportRangesExact":supports_exact,
		"maxAttributeError":max_attribute_error, "staleIdentityRejected":stale_rejected,
		"certifiedEnvelopeRejected":certified_envelope_rejected,
		"supportKeyBudgetRejected":support_budget_rejected,
		"supportMismatch":support_mismatch, "attributeMismatch":attribute_mismatch,
		"largeCoordinateWitness":large_coordinate_witness,
		"resultMaterializationUsec":materialization_usec,
		"resultSectionCount":completed.get("sections", []).size()}


func _native_section_pack_lifecycle(fixture: Dictionary) -> Dictionary:
	var dispatcher: RefCounted = ClassDB.instantiate("NativeTreeGeometryDispatcher") as RefCounted
	if dispatcher == null:
		return {"cancelled":false, "capacityBounded":false,
			"reason":"native_tree_geometry_dispatcher_instantiation_failed"}
	var one := PackedFloat32Array([
		1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
		0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0,
		0.0, 0.0, 0.0, 0.0])
	var values := PackedFloat32Array()
	for _index in range(1024):
		values.append_array(one)
	var packet := {"role":"branches", "sourcePartId":"branches",
		"batchKey":"tree-pack-lifecycle-batch",
		"meshContentDigest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
		"supportEnvelopePolicyRevision":"tree-factory-support-envelope/v2",
		"meshLocalBounds":AABB(Vector3(-0.1, -0.1, -0.1), Vector3(0.2, 0.2, 0.2)),
		"sourceGlobalTransform":Transform3D.IDENTITY,
		"certifiedWorldBounds":AABB(Vector3(-10.0, -10.0, -10.0), Vector3(20.0, 20.0, 20.0)),
		"windEnvelopeDigest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
		"windHorizontalMeters":0.2, "windVerticalMeters":0.0,
		"sectionSize":Grid.SECTION_SIZE_METERS, "instanceValues":values}
	var admitted_tickets: Array[int] = []
	var capacity_bounded := true
	for index in range(129):
		var identity := {"worldId":fixture.worldId, "worldEpoch":"pack-capacity-v1",
			"sourceId":"tree-pack-capacity-%d" % index, "sourceRevision":"source-r1",
			"recipeSignature":"pack-capacity-recipe", "artifactGeneration":index + 1,
			"sourceRecordDigest":"pack-capacity-record-%d" % index,
			"sourceProvenanceDigest":"pack-capacity-provenance",
			"requestDigest":"pack-capacity-request"}
		var admission: Dictionary = dispatcher.call("submit_tree_section_pack", packet, identity)
		if index < 128 and admission.get("status") == "pending":
			admitted_tickets.append(int(admission.ticket))
		elif index == 128:
			capacity_bounded = admission.get("status") == "backpressure" \
				and String(admission.get("reason", "")) == "tree_geometry_dispatcher_capacity"
		else:
			capacity_bounded = false
			if admission.get("status") == "pending":
				admitted_tickets.append(int(admission.ticket))
	var cancelled := true
	for ticket in admitted_tickets:
		var cancel_result: Dictionary = dispatcher.call("cancel_tree_geometry_compile", ticket)
		var release_result: Dictionary = dispatcher.call("release_tree_geometry_compile", ticket)
		cancelled = cancelled and cancel_result.get("status") == "ready" \
			and release_result.get("status") in ["ready", "pending"]
	var final_metrics: Dictionary = {}
	for _attempt in range(10000):
		final_metrics = dispatcher.call("tree_geometry_compile_metrics")
		if int(final_metrics.get("jobCount", -1)) == 0:
			break
		await process_frame
	cancelled = cancelled and int(final_metrics.get("jobCount", -1)) == 0 \
		and int(final_metrics.get("retainedOutputFloats", -1)) == 0
	dispatcher.call("drain_tree_geometry_compiles")
	return {"cancelled":cancelled, "capacityBounded":capacity_bounded,
		"admittedBeforeBackpressure":admitted_tickets.size(),
		"jobCountAfterCleanup":final_metrics.get("jobCount", -1),
		"retainedOutputFloatsAfterCleanup":final_metrics.get("retainedOutputFloats", -1)}


func _run_max_profile_cross_owner_falsifier() -> Dictionary:
	var fixture := _new_fixture("tree-max-profile-cross-owner", 40.5)
	var profile := ForestProfile as BiomeEnvironmentProfile
	var request_builder := RuntimeRequestBuilder.new()
	var catalog := CatalogScript.new()
	if not catalog.setup():
		return {"status":"failed", "reason":"profile_catalog_unavailable"}
	var catalog_snapshot := ActiveSnapshotScript.capture(catalog)
	var request: Dictionary = {}
	var requested_id := ""
	var maximum_radius := float(profile.crown_radius_max) if profile != null else 0.0
	for index in range(4096):
		var prop_id := "tree-max-profile-cross-owner-%d" % index
		var candidate: Dictionary = request_builder.build(profile, "forest", prop_id,
			float(profile.tree_height_max), Vector2i(1, 0), fixture.authority.seed_text,
			catalog_snapshot)
		if String(candidate.get("architecture", "")) == "broadleaf" \
				and float(candidate.get("canopyRadius", 0.0)) >= maximum_radius - 0.001:
			request = candidate.duplicate(true)
			requested_id = prop_id
			break
	if request.is_empty():
		fixture.queue.queue_free()
		fixture.body.queue_free()
		fixture.authority.queue_free()
		return {"status":"pending", "reason":"max_profile_request_not_found",
			"maximumCanopyRadius":maximum_radius}
	request["treeId"] = requested_id
	request["worldSeed"] = fixture.authority.seed_text
	request["biome"] = "forest"
	request["presentation"] = "runtime"
	request["renderLodTier"] = "near"
	request["treeWorldPosition"] = Vector3(40.5, 0.0, 10.0)
	fixture.body.set_meta("prop_id", requested_id)
	fixture.body.set_meta("static_ecology_source_id",
		"%s:tree:%s" % [fixture.authority.seed_text, requested_id])
	fixture.body.global_position = request.treeWorldPosition
	var recipe: Dictionary = fixture.queue.publication_service.build_recipe(request)
	var sealed: Dictionary = fixture.queue.build_tree_section_recipe_input_record(
		{"request":request, "enqueueSequence":1}, fixture.body, recipe)
	var compile_fixture := fixture.duplicate()
	compile_fixture.record = sealed.get("record", {})
	compile_fixture.worldId = "seed:%s:%d" % [fixture.authority.seed_text,
		fixture.authority.seed_hash]
	compile_fixture.removed = RemovedProps.capture_for_ids(fixture.authority, [requested_id])
	var compiled := await _run_compiler(compile_fixture, 24)
	var result: Dictionary = compiled.get("result", {})
	var source: Dictionary = result.get("sources", [])[0] \
		if result.get("status") == "ready" and not result.get("sources", []).is_empty() else {}
	var geometry_ownership: Array = source.get("geometryOwnership", [])
	var target_section := Vector3i(0, 2, 0)
	var compiled_support_reaches_target := geometry_ownership.any(
		func(row: Dictionary) -> bool:
			return row.get("supportSectionKeys", []).has(target_section))
	var compiled_center_owner_reaches_target := geometry_ownership.any(
		func(row: Dictionary) -> bool:
			return row.get("ownedSectionKey") == target_section)
	var center_owned_cross_support_witnesses: Array[Dictionary] = []
	for row_value: Variant in geometry_ownership:
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		if row.get("supportSectionKeys", []).has(target_section) \
				and row.get("ownedSectionKey") != target_section:
			center_owned_cross_support_witnesses.append({
				"role":String(row.get("role", "")),
				"instanceIndex":int(row.get("instanceIndex", -1)),
				"centerOwnerSectionKey":row.get("ownedSectionKey"),
				"supportSectionKeys":row.get("supportSectionKeys", [])})
	var actual_mesh_bounds_reach_target := false
	var actual_mesh_bounds_escape_declared := false
	var max_mesh_support_distance := 0.0
	var actual_mesh_bounds_union := AABB()
	var actual_mesh_bounds_union_set := false
	var actual_target_aabb_witnesses: Array[Dictionary] = []
	var actual_center_owned_cross_support_witnesses: Array[Dictionary] = []
	var runtime_instance_transforms := _runtime_instance_transforms(request, recipe,
		requested_id)
	var declared_candidate_bounds := _world_aabb_from_corners(
		AABB(Vector3(-maximum_radius, 0.0, -maximum_radius),
		Vector3(maximum_radius * 2.0, float(request.get("visualHeight", 0.0)),
			maximum_radius * 2.0)), Transform3D(Basis.IDENTITY,
			request.treeWorldPosition))
	for batch_value: Variant in result.get("batches", []):
		if not batch_value is Dictionary:
			continue
		var batch: Dictionary = batch_value
		var mesh: Mesh = result.get("resourceBindings", {}).get(
			String(batch.get("meshKey", "")), null) as Mesh
		if not is_instance_valid(mesh):
			continue
		var buffer: Array = batch.get("instanceAttributes", [])
		var origin: Vector3 = batch.get("sectionOrigin", Vector3.ZERO)
		for offset in range(0, buffer.size(), Attributes.FLOATS_PER_INSTANCE):
			var local_transform := Attributes.decode_transform(buffer, offset)
			var world_transform := Transform3D(local_transform.basis,
				local_transform.origin + origin)
			var world_mesh_bounds := _world_aabb_from_corners(mesh.get_aabb(), world_transform)
			var center_owner_section := Grid.key_for_world_position(world_mesh_bounds.get_center())
			actual_mesh_bounds_union = world_mesh_bounds if not actual_mesh_bounds_union_set \
				else actual_mesh_bounds_union.merge(world_mesh_bounds)
			actual_mesh_bounds_union_set = true
			var actual_support_keys := Grid.keys_intersecting_bounds(world_mesh_bounds)
			if actual_support_keys.has(target_section):
				actual_mesh_bounds_reach_target = true
			for support_section: Vector3i in actual_support_keys:
				if support_section == target_section and support_section != center_owner_section:
					if actual_center_owned_cross_support_witnesses.size() < 8:
						var matched_ownership := _ownership_for_compiled_instance(
							String(batch.get("role", "")), world_transform,
							geometry_ownership, runtime_instance_transforms,
							request.treeWorldPosition)
						var local_corners := _aabb_corners(mesh.get_aabb())
						var world_corners: Array[Vector3] = []
						for local_corner: Vector3 in local_corners:
							world_corners.append(world_transform * local_corner)
						var corner_oracle_bounds := _aabb_from_points(world_corners)
						var corner_oracle_support := Grid.keys_intersecting_bounds(
							corner_oracle_bounds)
						actual_center_owned_cross_support_witnesses.append({
							"role":String(batch.get("role", "")),
							"instanceIndex":int(matched_ownership.get("instanceIndex", -1)),
							"batchCenterOwnerSectionKey":batch.get("sectionKey", Vector3i.ZERO),
							"meshCenterOwnerSectionKey":center_owner_section,
							"supportSectionKey":support_section,
							"matchedOwnershipRow":matched_ownership,
							"ownershipRowMatchesIndependentAabb":
								matched_ownership.get("ownedSectionKey") == center_owner_section \
								and _sorted_section_keys(matched_ownership.get(
									"supportSectionKeys", [])) == _sorted_section_keys(actual_support_keys),
							"localCornerCount":local_corners.size(),
							"worldCornerCount":world_corners.size(),
							"cornerOracleBounds":corner_oracle_bounds,
							"cornerOracleMatchesClaimedBounds":local_corners.size() == 8 \
								and world_corners.size() == 8 \
								and _aabb_matches(corner_oracle_bounds, world_mesh_bounds),
							"cornerOracleSupportMatches":_sorted_section_keys(
								corner_oracle_support) == _sorted_section_keys(actual_support_keys),
							"sourceRevision":String(source.get("sourceRevision", "")),
							"meshLocalAabb":mesh.get_aabb(), "meshLocalCorners":local_corners,
							"worldCorners":world_corners, "worldAabb":world_mesh_bounds})
			if actual_support_keys.has(target_section):
				if actual_target_aabb_witnesses.size() < 8:
					actual_target_aabb_witnesses.append({"role":String(batch.get("role", "")),
						"sectionKey":batch.get("sectionKey", Vector3i.ZERO),
						"worldAabb":world_mesh_bounds,
						"meshAabb":mesh.get_aabb(), "worldTransform":world_transform,
						"independentSupportKeys":actual_support_keys})
			var epsilon := 0.0001
			actual_mesh_bounds_escape_declared = actual_mesh_bounds_escape_declared \
				or world_mesh_bounds.position.x < declared_candidate_bounds.position.x - epsilon \
				or world_mesh_bounds.position.y < declared_candidate_bounds.position.y - epsilon \
				or world_mesh_bounds.position.z < declared_candidate_bounds.position.z - epsilon \
				or world_mesh_bounds.end.x > declared_candidate_bounds.end.x + epsilon \
				or world_mesh_bounds.end.y > declared_candidate_bounds.end.y + epsilon \
				or world_mesh_bounds.end.z > declared_candidate_bounds.end.z + epsilon
			if not actual_support_keys.has(target_section):
				continue
			max_mesh_support_distance = maxf(max_mesh_support_distance,
				maxf(absf(world_mesh_bounds.position.x - 40.5),
					absf(world_mesh_bounds.end.x - 40.5)))
	var target_bounds := AABB(Grid.origin_for_key(target_section),
		Vector3.ONE * Grid.SECTION_SIZE_METERS)
	var five_meter_closure := AABB(
		target_bounds.position - Vector3(5.0, 0.0, 5.0),
		target_bounds.size + Vector3(10.0, 0.0, 10.0))
	var five_meter_owner_keys := Partitioner._stream_chunks_intersecting_bounds(five_meter_closure)
	var five_meter_admits_tree_owner := five_meter_owner_keys.has(Vector2i(1, 0))
	var target_owned_batch_count := 0
	for batch_value: Variant in result.get("batches", []):
		if batch_value is Dictionary and batch_value.get("sectionKey") == target_section \
				and batch_value.get("contributors", {}).has(String(source.get("sourceId", ""))):
			target_owned_batch_count += 1
	fixture.queue.queue_free()
	fixture.body.queue_free()
	fixture.authority.queue_free()
	return {"status":result.get("status", "missing"),
		"reason":result.get("reason", ""), "requestedId":requested_id,
		"ownerChunk":Grid.chunk_key_for_world_position(Vector3(40.5, 0.0, 10.0)),
		"treeWorldPosition":Vector3(40.5, 0.0, 10.0),
		"maximumCanopyRadius":maximum_radius,
		"requestCanopyRadius":float(request.get("canopyRadius", 0.0)),
		"actualSourceSectionKeys":source.get("sectionKeys", []),
		"actualCenterOwnedSectionKeys":source.get("ownedSectionKeys", []),
		"actualCompiledSupportReachesSelectedSupport":compiled_support_reaches_target,
		"actualCompiledCenterOwnerReachesSelectedSupport":compiled_center_owner_reaches_target,
		"centerOwnedCrossSupportWitnesses":center_owned_cross_support_witnesses,
		"actualCenterOwnedCrossSupportWitnesses":actual_center_owned_cross_support_witnesses,
		"actualCenterOwnerMatchesCompilerBatch":actual_center_owned_cross_support_witnesses.any(
			func(row: Dictionary) -> bool:
				return int(row.get("instanceIndex", -1)) >= 0 \
					and bool(row.get("ownershipRowMatchesIndependentAabb", false)) \
					and row.get("batchCenterOwnerSectionKey") == row.get(
						"meshCenterOwnerSectionKey")),
		"actualMeshAabbReachesSelectedSupport":actual_mesh_bounds_reach_target,
		"selectedActualSupportSection":target_section,
		"actualMeshAabbEscapesDeclaredCanopyBounds":actual_mesh_bounds_escape_declared,
		"actualCompiledMeshAabbUnion":actual_mesh_bounds_union if actual_mesh_bounds_union_set else AABB(),
		"actualTargetAabbWitnesses":actual_target_aabb_witnesses,
		"declaredCandidateWorldBounds":declared_candidate_bounds,
		"targetOwnedBatchCount":target_owned_batch_count,
		"maxObservedMeshSupportDistanceFromRootX":max_mesh_support_distance,
		"fiveMeterOwnerKeys":five_meter_owner_keys,
		"fiveMeterClosureAdmitsOwnerChunk1":five_meter_admits_tree_owner,
		"steps":compiled.get("steps", 0)}


func run() -> void:
	var section_origin_x := Grid.SECTION_SIZE_METERS * 2.0
	var fixture := _new_fixture("tree-compiler:boundary", section_origin_x - 1.0)
	var compiled := await _run_compiler(fixture, 1)
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
	var second := await _run_compiler(fixture, 24)
	var second_result: Dictionary = second.result
	var same_output := false
	if second_result.get("status") == "ready":
		same_output = result.batches == second_result.batches \
			and result.sources == second_result.sources
	var native_parity_cases: Array[Dictionary] = []
	var native_branch_parity_cases: Array[Dictionary] = []
	for family: Dictionary in [
		{"biome":"forest", "architecture":"broadleaf", "grammar":"bushy_oak", "lod":"near"},
		{"biome":"taiga", "architecture":"conifer", "grammar":"norway_spruce", "lod":"mid"},
		{"biome":"savanna", "architecture":"savanna", "grammar":"umbrella_thorn", "lod":"far"}]:
		native_parity_cases.append(await _native_foliage_parity_case(fixture, family))
		native_branch_parity_cases.append(await _native_branch_parity_case(fixture, family))
	var native_lifecycle := await _native_dispatcher_lifecycle_checks(fixture)
	var section_pack_differential := await _native_section_pack_differential(fixture)
	var section_pack_lifecycle := await _native_section_pack_lifecycle(fixture)
	_check("native_tree_section_pack_rejects_section_size_that_narrows_to_zero",
		bool(section_pack_differential.get("narrowedSectionSizeRejected", false)))
	_check("native_tree_section_pack_accepts_standard_section_size",
		bool(section_pack_differential.get("standardSectionSizeAccepted", false)))
	var empty_role_compiler := Compiler.new()
	var empty_role_record := {"recipeSnapshot":{"branches":[], "foliage":[]}}
	var empty_branches: Dictionary = empty_role_compiler._begin_role(empty_role_record, "branches")
	var empty_foliage: Dictionary = empty_role_compiler._begin_role(empty_role_record, "foliage")
	var complete_empty_roles: bool = empty_branches.get("status") == "ready" \
		and bool(empty_branches.get("emptyRole", false)) \
		and empty_foliage.get("status") == "ready" \
		and bool(empty_foliage.get("emptyRole", false))
	_check("empty_tree_roles_remain_explicit_complete_empty_without_native_packet",
		complete_empty_roles)
	_check("native_tree_section_pack_matches_transform_bounds_owner_and_support_reference",
		section_pack_differential.get("status") == "ready" \
		and bool(section_pack_differential.get("ownersExact", false)) \
		and bool(section_pack_differential.get("supportRangesExact", false)) \
		and bool(section_pack_differential.get("staleIdentityRejected", false)) \
		and bool(section_pack_differential.get("certifiedEnvelopeRejected", false)) \
		and int(section_pack_differential.get("observedInstanceCount", 0)) == 4)
	_check("native_tree_section_pack_cancel_and_capacity_are_bounded",
		bool(section_pack_lifecycle.get("cancelled", false)) \
		and bool(section_pack_lifecycle.get("capacityBounded", false)) \
		and int(section_pack_lifecycle.get("admittedBeforeBackpressure", 0)) == 128 \
		and int(section_pack_lifecycle.get("jobCountAfterCleanup", -1)) == 0 \
		and int(section_pack_lifecycle.get("retainedOutputFloatsAfterCleanup", -1)) == 0)
	var native_parity_passed := native_parity_cases.size() == 3 \
		and native_parity_cases.all(func(row: Dictionary) -> bool:
			return row.get("status", "") == "ready" \
				and int(row.get("packedFloatCount", 0)) == int(row.get("instanceCount", 0)) \
					* Attributes.FLOATS_PER_INSTANCE \
				and int(row.get("jobCountAfterRelease", -1)) == 0 \
				and int(row.get("retainedOutputFloatsAfterRelease", -1)) == 0)
	_check("native_foliage_packed_values_match_factory_all_families_lods",
		native_parity_passed)
	_check("native_whole_record_branch_values_match_factory_and_echo_epochs",
		native_branch_parity_cases.size() == 3 and native_branch_parity_cases.all(
			func(row: Dictionary) -> bool:
			return row.get("status", "") == "ready" \
				and bool(row.get("replacementEpochRejected", false)) \
				and bool(row.get("replacedSourceEpochRejected", false)) \
				and bool(row.get("replacedRecipeEpochRejected", false)) \
				and float(row.get("maxAbsolutePackedFloatError", INF)) <= 0.00002))
	_check("native_tree_worker_cancel_and_queue_capacity_are_bounded",
		bool(native_lifecycle.get("runningObserved", false)) \
		and bool(native_lifecycle.get("cancelled", false)) \
		and bool(native_lifecycle.get("capacityBounded", false)) \
		and int(native_lifecycle.get("admittedBeforeBackpressure", 0)) == 128 \
		and int(native_lifecycle.get("jobCountAfterCapacityCleanup", -1)) == 0 \
		and int(native_lifecycle.get("retainedOutputFloatsAfterCapacityCleanup", -1)) == 0)
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
	var band_proof_checks := _band_completion_proof_checks()
	_check("section_band_completion_distinguishes_support_only_empty_missing_and_owned_output",
		bool(band_proof_checks.get("supportOnlyReady", false)) \
		and String(band_proof_checks.get("supportOnlyDisposition", "")) == "complete_empty" \
		and bool(band_proof_checks.get("supportOnlyManifestHasCompleteZeroOwner", false)) \
		and bool(band_proof_checks.get("explicitEmptySourceProjectionReady", false)) \
		and bool(band_proof_checks.get("missingSourceCompletionRejected", false)) \
		and bool(band_proof_checks.get("duplicateGeometryOwnershipRejected", false)) \
		and bool(band_proof_checks.get("currentOwnerBatchAccepted", false)) \
		and bool(band_proof_checks.get("aggregateBatchAttributeTamperRejected", false)))
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
	var queue_fixture := _new_fixture("tree-queue-integration", 8.0)
	var queue: TreePublicationQueue = queue_fixture.queue
	queue_fixture.authority.tree_publication_queue = queue
	var queue_body: StaticBody3D = queue_fixture.body
	queue_body.set_meta("static_ecology_source_id", String(queue_fixture.record.sourceId))
	queue_body.add_to_group("generated_tree_trunks")
	queue.set_section_owned_publication_enabled(true)
	var prop_ids: Array[String] = [String(queue_fixture.record.propId)]
	var unknown_prop_ids: Array[String] = ["tree-queue-integration:unknown"]
	var unknown_exact: Dictionary = queue.startup_tree_candidate_diagnostics(unknown_prop_ids)
	var unknown_diagnostic_rows: Dictionary = unknown_exact.get("byPropId", {}).get(
		unknown_prop_ids[0], {})
	var unknown_stage_rows_empty := true
	var unknown_indexed_candidate_count := 0
	for stage_name: String in ["section_recipe_input", "section_compiled", "section_prepared"]:
		var stage_rows: Array = unknown_diagnostic_rows.get(stage_name, [])
		unknown_stage_rows_empty = unknown_stage_rows_empty and stage_rows.is_empty()
		unknown_indexed_candidate_count += stage_rows.size()
	var unknown_revision_join: Dictionary = unknown_diagnostic_rows.get("revisionJoin", {})
	_check("exact_tree_queue_query_does_not_treat_missing_candidate_as_empty_success",
		bool(unknown_exact.get("indexBacked", false)) \
		and int(unknown_exact.get("queryCount", 0)) == 1 \
		and unknown_diagnostic_rows.has("revisionJoin") \
		and unknown_diagnostic_rows.size() == 4 \
		and unknown_stage_rows_empty and unknown_indexed_candidate_count == 0 \
		and int(unknown_exact.get("knownCandidateCount", -1)) == 0 \
		and String(unknown_revision_join.get("status", "")) == "unresolved")
	var retained: Dictionary = queue.retain_tree_section_recipe_input_record(queue_fixture.record)
	var retained_exact: Dictionary = queue.startup_tree_candidate_diagnostics(prop_ids)
	var initial_progress: Dictionary = queue.startup_tree_section_compile_diagnostics()
	var first_advance: Dictionary = queue.advance_tree_section_compiler(1)
	var first_progress: Dictionary = queue.startup_tree_section_compile_diagnostics()
	var compiler_progress: Dictionary = first_progress.get("compiler", {})
	var last_advance: Dictionary = first_progress.get("lastAdvance", {})
	_check("startup_tree_compiler_diagnostic_reports_actual_active_job_progress",
		initial_progress.get("startedCount", -1) == 0 \
		and first_advance.get("status") == "pending" \
		and compiler_progress.get("status") == "pending" \
		and String(first_progress.get("activeCandidateId", "")) \
			== String(queue_fixture.record.get("propId", "")) \
		and String(first_progress.get("activeSourceId", "")) \
			== String(queue_fixture.record.get("sourceId", "")) \
		and int(compiler_progress.get("workUnits", -1)) \
			== int(first_advance.get("workUnits", -2)) \
		and String(compiler_progress.get("role", "")) == "bole" \
		and int(compiler_progress.get("roleCount", 0)) == 3 \
		and int(compiler_progress.get("startedElapsedUsec", -1)) >= 0 \
		and int(compiler_progress.get("sinceLastAdvanceStartedUsec", -1)) >= 0 \
		and last_advance.get("status") == first_advance.get("status") \
		and String(last_advance.get("reason", "")) \
			== String(first_advance.get("reason", "")) \
		and int(first_progress.get("startedCount", 0)) == 1 \
		and int(first_progress.get("completedCount", -1)) == 0 \
		and int(first_progress.get("staleCount", -1)) == 0)
	var queue_output: Dictionary = first_advance
	var queue_steps := 0
	while queue_output.get("status") == "pending" \
			and String(queue_output.get("reason", "")) == "tree_section_compile_in_progress" \
			and queue_steps < 1000:
		queue_output = queue.advance_tree_section_compiler(24)
		queue_steps += 1
	var installed_queue_record := queue.compiled_tree_section_record_for_body(queue_body)
	var compiled_exact: Dictionary = queue.startup_tree_candidate_diagnostics(prop_ids)
	var compiled_exact_rows: Dictionary = compiled_exact.get("byPropId", {}).get(prop_ids[0], {})
	var compiled_exact_sources: Array = compiled_exact_rows.get("section_compiled", [])
	var exact_section_keys: Array = compiled_exact_sources[0].get("sectionKeys", []) \
		if not compiled_exact_sources.is_empty() else []
	_check("exact_tree_queue_index_joins_recipe_input_to_compiled_section_manifest",
		bool(retained_exact.get("indexBacked", false)) \
		and retained_exact.get("byPropId", {}).get(prop_ids[0], {}).get(
			"section_recipe_input", []).size() == 1 \
		and compiled_exact.get("byPropId", {}).get(prop_ids[0], {}).get(
			"section_recipe_input", []).size() == 1 \
		and compiled_exact_sources.size() == 1 \
		and not exact_section_keys.is_empty() \
		and exact_section_keys.all(func(section: Variant) -> bool: return section is Vector3i))
	queue_body.set_meta("tree_visual_state", "section_owned")
	queue_body.set_meta("visual_source", "chunk_owned_static_section")
	queue_body.set_meta("tree_section_recipe_input_expected_generation", 2)
	queue._startup_tree_diagnostic_ack_by_id[prop_ids[0]] = {
		"sourceId":String(queue_fixture.record.sourceId), "propId":prop_ids[0],
		"body":weakref(queue_body), "bodyInstanceId":queue_body.get_instance_id(),
		"artifactGeneration":1, "producerGeneration":1,
		"recipeSignature":String(queue_fixture.record.recipeSignature),
		"recipeArtifactRevision":String(queue_fixture.record.contentRevision),
		"sourceRevision":"old-source-revision",
		"sectionKeys":exact_section_keys}
	var stale_ack_join: Dictionary = queue.startup_tree_candidate_diagnostics(prop_ids)
	var stale_ack_stages: Dictionary = stale_ack_join.get("byPropId", {}).get(prop_ids[0], {})
	_check("newer_expected_recipe_generation_cannot_join_old_section_ack",
		stale_ack_stages.get("revisionJoin", {}).get("status", "") != "matched" \
		and not bool(stale_ack_stages.get("section_acknowledged", {}).get(
			"ownerIdentityCurrent", true)))
	queue._startup_tree_diagnostic_ack_by_id.erase(prop_ids[0])
	queue_body.set_meta("tree_section_recipe_input_expected_generation", 1)
	var ecology := EcologyAdapter.new()
	var queue_world_id := "seed:%s:%d" % [queue_fixture.authority.seed_text,
		queue_fixture.authority.seed_hash]
	var ecology_configure := ecology.configure(queue_world_id)
	var ecology_catalog: Dictionary = queue_fixture.authority.seed_catalog_artifact(queue_world_id)
	var ecology_bind := ecology.bind_main_authority(queue_fixture.authority)
	var catalog_lease: Dictionary = queue_fixture.authority.acquire_ecology_catalog_artifact_lease(
		String(ecology_catalog.get("artifactId", "")), "tree_compiler_contract",
		"compiled-tree-adapter", queue_world_id, queue_fixture.authority.ecology_world_epoch)
	var resolved_catalog: Dictionary = queue_fixture.authority.resolve_ecology_catalog_artifact(
		String(catalog_lease.get("leaseToken", "")), queue_world_id,
		queue_fixture.authority.ecology_world_epoch)
	var catalog_artifact: Dictionary = resolved_catalog.get("artifact", {})
	var compact_source_inputs := {"schema":"ecology-source-domain-inputs/v2",
		"worldId":queue_world_id, "worldSeed":queue_fixture.authority.seed_text,
		"worldEpoch":queue_fixture.authority.ecology_world_epoch,
		"sourceChunkKey":Vector2i.ZERO,
		"catalogArtifactId":String(ecology_catalog.get("artifactId", "")),
		"catalogContentDigest":String(ecology_catalog.get("catalogContentDigest", "")),
		"influencePolicyRevision":String(catalog_artifact.get("supportPolicy", {}).get(
			"revision", "")),
		"influencePolicyDigest":String(catalog_artifact.get("supportPolicy", {}).get(
			"digest", ""))}
	var v2_policy := ProducerDomain.support_policy(compact_source_inputs, catalog_artifact)
	var v2_scope: Dictionary = queue_fixture.authority.begin_ecology_source_catalog_context_scope()
	var v2_scope_end: Dictionary = queue_fixture.authority.end_ecology_source_catalog_context_scope(v2_scope) \
		if v2_scope.get("status") == "ready" else {"status":"not_started"}
	var released_catalog: Dictionary = queue_fixture.authority.release_ecology_catalog_artifact_lease(
		String(catalog_lease.get("leaseToken", "")))
	var tree_candidate := {"sourceId":String(queue_fixture.record.sourceId),
		"propId":String(queue_fixture.record.propId), "contentRevision":"producer-ledger-r1"}
	var publication: Dictionary = ecology._current_tree_publications(
		queue_fixture.authority).get(String(queue_fixture.record.propId), {})
	var ecology_capture := ecology._capture_compiled_tree_candidate(tree_candidate, publication)
	var tree_spatial_review := ProducerDomain.active_tree_spatial_source_contract()
	_check("production_queue_scheduler_seals_canonical_recipe_for_ecology",
		retained.get("status") == "retained" and queue_output.get("status") == "ready" \
		and not installed_queue_record.is_empty()
		and int(installed_queue_record.get("bodyInstanceId", 0)) == queue_body.get_instance_id()
		and queue_steps > 1)
	_check("ecology_adapter_consumes_exact_compiled_queue_sections",
		ecology_capture.get("status") == "ready" \
		and ecology_capture.get("partition", {}).get("outputs", []).size() > 0 \
		and ecology_capture.get("partition", {}).get("outputs", []).all(
			func(value: Dictionary) -> bool:
				return Vector3i(value.get("sectionKey", Vector3i(999, 999, 999))) \
					in ecology_capture.get("sectionKeys", [])))
	_check("ecology_adapter_uses_v2_catalog_lease_resolver",
		ecology_catalog.get("status") == "ready" and ecology_bind.get("status") == "ready" \
		and catalog_lease.get("status") == "ready" \
		and resolved_catalog.get("status") == "ready" \
		and resolved_catalog.get("catalogArtifactId") == ecology_catalog.get("artifactId") \
		and v2_policy.get("status") == "ready" \
		and v2_scope.get("status") == "ready" and v2_scope_end.get("status") == "ready" \
		and released_catalog.get("released", false))
	_check("tree_support_policy_uses_reviewed_runtime_spatial_envelope",
		v2_policy.get("families", {}).get("trees", {}).get("status") == "bounded" \
		and float(v2_policy.get("families", {}).get("trees", {}).get(
			"maxHorizontalSupportMeters", 0.0)) > 0.0 \
		and float(v2_policy.get("families", {}).get("trees", {}).get(
			"maxVerticalSupportMeters", 0.0)) > 0.0)
	var replacement_body := StaticBody3D.new()
	replacement_body.set_meta("prop_id", String(queue_fixture.record.propId))
	replacement_body.set_meta("static_ecology_source_id", String(queue_fixture.record.sourceId))
	replacement_body.global_transform = queue_body.global_transform
	replacement_body.add_to_group("generated_tree_trunks")
	queue_fixture.authority.add_child(replacement_body)
	queue_body.set_meta("tree_section_recipe_input_expected_generation", 1)
	var prepared_request: Dictionary = queue_fixture.request.duplicate(true)
	prepared_request.make_read_only()
	var prepared_record := {"schema":"prepared-tree-section-artifact/v1",
		"artifactGeneration":int(installed_queue_record.get("artifactGeneration", 1)),
		"producerGeneration":1,
		"sourceId":String(queue_fixture.record.sourceId),
		"propId":String(queue_fixture.record.propId),
		"body":weakref(queue_body), "bodyInstanceId":queue_body.get_instance_id(),
		"bodyGlobalTransform":queue_body.global_transform,
		"request":prepared_request,
		"recipeSignature":String(queue_fixture.record.recipeSignature),
		"sectionValueMembers":[]}
	prepared_record.make_read_only()
	var retained_prepared := queue.retain_prepared_section_value_record(prepared_record)
	var before_prepared_unload: Dictionary = queue.startup_tree_candidate_diagnostics(prop_ids)
	var prepared_before_unload: Array = before_prepared_unload.get("byPropId", {}).get(
		prop_ids[0], {}).get("section_prepared", [])
	_check("exact_tree_index_includes_current_prepared_artifact",
		retained_prepared.get("status") == "retained" \
		and prepared_before_unload.size() == 1 \
		and prepared_before_unload[0].get("ownerIdentityCurrent", false) \
		and prepared_before_unload[0].get("state", "") == "current")
	var ambiguous_publication: Dictionary = ecology._current_tree_publications(
		queue_fixture.authority).get(String(queue_fixture.record.propId), {})
	var replacement_capture := ecology._capture_compiled_tree_candidate(tree_candidate,
		ambiguous_publication)
	_check("duplicate_live_replacement_owner_keeps_tree_candidate_pending",
		replacement_capture.get("status") == "pending" \
		and String(replacement_capture.get("reason", "")) == \
		"ecology_compiled_tree_live_owner_roster_ambiguous")
	replacement_body.remove_from_group("generated_tree_trunks")
	var replacement_request: Dictionary = queue_fixture.request.duplicate(true)
	var replacement_recipe: Dictionary = queue.publication_service.build_recipe(replacement_request)
	var replacement_record: Dictionary = queue.build_tree_section_recipe_input_record(
		{"request":replacement_request, "enqueueSequence":2}, replacement_body, replacement_recipe).get("record", {})
	queue.cancel_body_publication(queue_body)
	var unloaded_exact: Dictionary = queue.startup_tree_candidate_diagnostics(prop_ids)
	var unloaded_stages: Dictionary = unloaded_exact.get("byPropId", {}).get(prop_ids[0], {})
	var stale_prepared_rows: Array = unloaded_stages.get("section_prepared", [])
	_check("unload_cancellation_discards_old_output_and_allows_replay_admission",
		queue.compiled_tree_section_record_for_body(queue_body).is_empty() \
		and unloaded_stages.get("section_recipe_input", []).is_empty() \
		and unloaded_stages.get("section_compiled", []).is_empty() \
		and stale_prepared_rows.size() == 1 \
		and stale_prepared_rows[0].get("state", "") == "stale_owner" \
		and not stale_prepared_rows[0].get("ownerIdentityCurrent", true) \
		and replacement_record.is_read_only() \
		and queue.retain_tree_section_recipe_input_record(replacement_record).get("status") == "retained")
	var replacement_exact: Dictionary = queue.startup_tree_candidate_diagnostics(prop_ids)
	_check("exact_tree_index_tracks_replacement_owner_after_unload",
		replacement_exact.get("byPropId", {}).get(prop_ids[0], {}).get(
			"section_recipe_input", []).size() == 1 \
		and replacement_exact.get("byPropId", {}).get(prop_ids[0], {}).get(
			"section_compiled", []).is_empty() \
		and replacement_exact.get("byPropId", {}).get(prop_ids[0], {}).get(
			"section_prepared", [])[0].get("state", "") == "stale_owner")
	var tree_closure_falsifier := await _run_max_profile_cross_owner_falsifier()
	_check("max_profile_compiled_tree_from_owner_1_crosses_high_x0_support_outside_5m_closure",
		tree_closure_falsifier.get("status", "") == "ready" \
		and tree_closure_falsifier.get("ownerChunk") == Vector2i(1, 0) \
		and float(tree_closure_falsifier.get("requestCanopyRadius", 0.0)) >= 33.999 \
		and tree_closure_falsifier.get("selectedActualSupportSection") == Vector3i(0, 2, 0) \
		and tree_closure_falsifier.get("actualCompiledSupportReachesSelectedSupport", false) \
		and tree_closure_falsifier.get("actualMeshAabbReachesSelectedSupport", false) \
		and tree_closure_falsifier.get("actualMeshAabbEscapesDeclaredCanopyBounds", false) \
		and not tree_closure_falsifier.get("fiveMeterClosureAdmitsOwnerChunk1", true))
	_check("actual_tree_mesh_aabb_crosses_center_owner_section",
		tree_closure_falsifier.get("actualCenterOwnedCrossSupportWitnesses", []).any(
			func(row: Dictionary) -> bool:
				return row.get("meshCenterOwnerSectionKey") != row.get("supportSectionKey")))
	_check("compiler_batch_owner_matches_independent_tree_mesh_center",
		tree_closure_falsifier.get("actualCenterOwnerMatchesCompilerBatch", false))
	_check("tree_compiler_support_rows_match_exact_role_instance_mesh_aabbs",
		tree_closure_falsifier.get("actualCenterOwnedCrossSupportWitnesses", []).any(
			func(row: Dictionary) -> bool:
				return int(row.get("instanceIndex", -1)) >= 0 \
					and bool(row.get("ownershipRowMatchesIndependentAabb", false)) \
					and row.get("supportSectionKey") == Vector3i(0, 2, 0)))
	_check("tree_mesh_corner_oracle_has_eight_points_and_matches_bounds_and_support",
		tree_closure_falsifier.get("actualCenterOwnedCrossSupportWitnesses", []).any(
			func(row: Dictionary) -> bool:
				return int(row.get("instanceIndex", -1)) >= 0 \
					and int(row.get("localCornerCount", 0)) == 8 \
					and int(row.get("worldCornerCount", 0)) == 8 \
					and bool(row.get("cornerOracleMatchesClaimedBounds", false)) \
					and bool(row.get("cornerOracleSupportMatches", false)) \
					and row.get("supportSectionKey") == Vector3i(0, 2, 0)))
	var report := {"schema":"tree-recipe-section-compiler-contract/v1",
		"checks":checks, "passed":not checks.values().has(false),
		"status":result.get("status", "missing"), "reason":result.get("reason", ""),
		"beginReason":compiled.get("begin", {}).get("reason", ""),
		"sectionKeys":section_keys, "sectionSizeMeters":Grid.SECTION_SIZE_METERS,
		"sampleOwnership":ownership.slice(0, 4),
		"batchCount":batches.size(), "roles":roles.keys(),
		"nativeFoliageParityCases":native_parity_cases,
		"nativeBranchParityCases":native_branch_parity_cases,
		"nativeDispatcherLifecycle":native_lifecycle,
		"nativeSectionPackDifferential":section_pack_differential,
		"nativeSectionPackLifecycle":section_pack_lifecycle,
		"nativeTreePackAcceptance":{"acceptedInstances":int(result.get(
			"nativeTreePackAcceptedInstances", 0)), "acceptanceUsec":int(result.get(
			"nativeTreePackAcceptanceUsec", 0)),
			"timingScope":"aggregate GDScript member proof/materialization; excludes dispatcher take"},
		"workUnits":result.get("workUnits", 0), "singleUnitSteps":compiled.steps,
		"largeUnitSteps":second.steps, "queueIntegrationSteps":queue_steps,
		"treeClosureFalsifier":tree_closure_falsifier,
		"unknownCandidateQueryEvidence":unknown_exact,
		"unknownIndexedCandidateCount":unknown_indexed_candidate_count,
		"unknownStageRowsEmpty":unknown_stage_rows_empty,
		"unknownRevisionJoinStatus":String(unknown_revision_join.get("status", "")),
		"queueIntegrationEvidence":{"retained":retained, "queueOutputStatus":queue_output.get("status", ""),
		"queueOutputReason":queue_output.get("reason", ""),
			"queueRecordPresent":not installed_queue_record.is_empty(),
			"ecologyConfigure":ecology_configure, "ecologyCatalog":ecology_catalog,
			"ecologyBind":ecology_bind,
			"catalogLease":catalog_lease, "resolvedCatalog":resolved_catalog,
			"treeSpatialSourceReview":tree_spatial_review,
			"v2Policy":v2_policy, "v2Scope":v2_scope,
			"v2ScopeEnd":v2_scope_end, "releasedCatalog":released_catalog,
			"publicationKeys":publication.keys(),
			"publicationHasBody":publication.get("body", null) is StaticBody3D,
			"publicationHasCompiledRecord":publication.get("compiledRecord", null) is Dictionary,
			"ecologyCaptureStatus":ecology_capture.get("status", ""),
			"ecologyCaptureReason":ecology_capture.get("reason", ""),
			"duplicateCaptureStatus":replacement_capture.get("status", ""),
			"duplicateCaptureReason":replacement_capture.get("reason", "")},
		"evidenceLevel":"headed canonical recipe compiler and TreePublicationQueue-to-EcologySectionValueAdapter value integration; native foliage and branch parity against the visual factory for broadleaf/conifer/savanna and near/mid/far LOD; native section packing differentially checked against independent Transform3D/AABB/Grid/Attributes reference at negative, exact-plane, rotated/nonuniform and large coordinates with wind expansion; pack cancellation, backpressure, stale identity, v2 catalog leases, immutable output, ownership ABI and budget slicing. Native take/Variant materialization and the aggregate GDScript per-member proof/materialization loop are timed separately, with accepted instance count. The compiler remains upstream of NativeSectionCompileDispatcher and native candidate installation; gameplay lifecycle, save/replay and performance acceptance remain unproven."}
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
	queue.queue_free()
	queue_body.queue_free()
	replacement_body.queue_free()
	queue_fixture.authority.queue_free()
	quit(0 if report.passed else 1)
