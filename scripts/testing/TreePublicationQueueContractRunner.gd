extends SceneTree

const TreePublicationQueueScript := preload("res://scripts/environment/TreePublicationQueue.gd")
const TreeRecipeCacheScript := preload("res://scripts/environment/TreeRecipeCache.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const CertifiedRequestFixture := preload("res://scripts/testing/CertifiedTreeRequestFixture.gd")
const BiomeEnvironmentCatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const ActiveBiomeEnvironmentSnapshotScript := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
const EcologySectionContract := preload("res://scripts/testing/world/EcologySectionValueAdapterContract.gd")
const TreeRecipeSectionCompilerScript := preload("res://scripts/world/TreeRecipeSectionCompiler.gd")
const EcologyProducerDomainScript := preload("res://scripts/world/EcologyProducerDomain.gd")
const RemovedPropsScript := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")

class BandAuthority extends Node:
	var current := true
	var expected_view: Dictionary = {}
	var expected_token := ""

	func ecology_source_publication_local_is_current(view: Dictionary,
			token: String) -> Dictionary:
		if not current:
			return {"status":"pending", "reason":"fixture_band_publication_stale"}
		if not is_same(view, expected_view) or token != expected_token:
			return {"status":"failed", "reason":"fixture_band_publication_identity_mismatch"}
		return {"status":"ready"}

	func ecology_source_publication_record_is_current(view: Dictionary,
			token: String, _record: Dictionary) -> Dictionary:
		return ecology_source_publication_local_is_current(view, token)

var results: Array[Dictionary] = []

class RealTreeRuntimeOwner extends "res://scripts/Main.gd":
	func _ready() -> void: pass
	func _process(_delta: float) -> void: pass
	func _physics_process(_delta: float) -> void: pass

func _initialize() -> void:
	call_deferred("run_contract")

func run_contract() -> void:
	await _real_building_tree_identity_contract()
	var fixture := Node3D.new()
	get_root().add_child(fixture)
	var queue = TreePublicationQueueScript.new()
	fixture.add_child(queue)
	# Main-world startup prewarms these immutable mesh/material resources while
	# the loading UI is active.  The queue contract measures the subsequent
	# gameplay publication slices, not one-time shader/resource creation.
	queue.publication_service.prewarm_visuals()
	var band_authority := BandAuthority.new()
	fixture.add_child(band_authority)
	var band_queue = TreePublicationQueueScript.new()
	band_authority.add_child(band_queue)
	# Synthetic terminal-state regression: retain the compiler's owned payload
	# while exposing its original rejection, rather than polling failed work forever.
	var failed_compiler := TreeRecipeSectionCompilerScript.new()
	failed_compiler._job = {"status":"pending", "mode":"immutable_source",
		"catalogLeaseReleased":true, "records":[]}
	var discarded: Dictionary = failed_compiler._discard("fixture_retained_source_failure")
	band_queue.ecology_source_compile_jobs["synthetic-failed"] = {
		"status":"queued", "compiler":failed_compiler, "consumers":{},
		"publicationLeaseToken":""}
	band_queue.ecology_source_compile_order.append("synthetic-failed")
	band_queue.advance_ecology_source_compilers()
	var failed_job: Dictionary = band_queue.ecology_source_compile_jobs["synthetic-failed"]
	add_result("synthetic_retained_failed_compiler_is_terminal_with_original_reason",
		discarded.get("status") == "failed" and failed_job.get("status") == "failed"
		and failed_job.get("reason") == "fixture_retained_source_failure"
		and failed_job.get("compiler") == failed_compiler
		and failed_compiler.advance().get("reason") == "fixture_retained_source_failure"
		and not failed_compiler._job.is_empty(), {"discard":discarded,
			"status":failed_job.get("status"), "reason":failed_job.get("reason")})
	band_queue.ecology_source_compile_jobs.erase("synthetic-failed")
	band_queue.ecology_source_compile_order.erase("synthetic-failed")
	failed_compiler.cancel()
	var band_snapshot := _freeze_contract_value({"schema":"ecology-source-domain-family-bundle/v1",
		"status":"ready", "worldId":"queue-band-world",
		"sourceChunkKey":Vector2i(4, -2), "sourceRevision":"band-source-r1"}) as Dictionary
	var band_view := _freeze_contract_value({"schema":"ecology-source-publication-view/v1",
		"publicationId":"queue-band-publication", "contentDigest":"a".repeat(64),
		"payload":band_snapshot,
		"familyResultsById":{"trees":{"status":"ready",
			"familyRevision":"tree-family-r1", "sourceManifestDigest":"b".repeat(64),
			"sourceRows":[]}}}) as Dictionary
	var band_token := "queue-band-publication-lease"
	band_authority.expected_view = band_view
	band_authority.expected_token = band_token
	var band_authority_receipt := _freeze_contract_value({
		"schema":"ecology-tree-source-family-band-authority/v1",
		"worldId":"queue-band-world", "sourceChunkKey":Vector2i(4, -2),
		"sectionKey":Vector3i(4, 0, -2), "sourceRevision":"band-source-r1",
		"sourcePublicationId":"queue-band-publication",
		"sourcePublicationContentDigest":"a".repeat(64),
		"sourceFamilyRevision":"tree-family-r1",
		"sourceFamilyManifestDigest":"b".repeat(64),
		"producerSourceIds":[], "authorityDigest":"c".repeat(64),
		"publicationLeaseToken":band_token}) as Dictionary
	var first_band_consumer := "queue-band-consumer-a"
	var second_band_consumer := "queue-band-consumer-b"
	var band_first := band_queue.request_ecology_tree_source_band_compile(band_authority,
		band_snapshot, Vector3i(4, 0, -2), band_authority_receipt, band_view,
		first_band_consumer)
	var band_second := band_queue.request_ecology_tree_source_band_compile(band_authority,
		band_snapshot, Vector3i(4, 0, -2), band_authority_receipt, band_view,
		second_band_consumer)
	var band_job_key := String(band_first.get("jobKey", ""))
	var band_first_poll := band_queue.poll_ecology_tree_source_band_compile(
		band_job_key, first_band_consumer)
	var empty_band_artifact: Dictionary = band_first_poll.get("artifact", {})
	var canonical_empty_manifest_digest := _canonical_digest(
		empty_band_artifact.get("sourceCompletionManifest", []))
	var canonical_empty_owner_payload_digest := _canonical_digest(
		empty_band_artifact.get("ownerBatchContributors", []))
	band_queue.cancel_ecology_tree_source_band_compile(band_job_key, first_band_consumer)
	var band_second_poll := band_queue.poll_ecology_tree_source_band_compile(
		band_job_key, second_band_consumer)
	band_authority.current = false
	var stale_band_poll := band_queue.poll_ecology_tree_source_band_compile(
		band_job_key, second_band_consumer)
	band_queue.cancel_ecology_tree_source_band_compile(band_job_key, second_band_consumer)
	band_authority.current = true
	var retry_band := band_queue.request_ecology_tree_source_band_compile(band_authority,
		band_snapshot, Vector3i(4, 0, -2), band_authority_receipt, band_view,
		"queue-band-consumer-retry")
	var retry_band_poll := band_queue.poll_ecology_tree_source_band_compile(
		String(retry_band.get("jobKey", "")), "queue-band-consumer-retry")
	add_result("tree_band_compile_seals_explicit_empty_and_shares_retryable_subscribers",
		String(band_first.get("jobKey", "")) == String(band_second.get("jobKey", "")) \
		and String(band_first_poll.get("status", "")) == "ready" \
		and String(band_first_poll.get("artifact", {}).get("disposition", "")) == "complete_empty" \
		and String(empty_band_artifact.get("sourceCompletionDigest", "")) \
			== canonical_empty_manifest_digest \
		and String(empty_band_artifact.get("ownerBatchPayloadDigest", "")) \
			== canonical_empty_owner_payload_digest \
		and String(band_second_poll.get("status", "")) == "ready" \
		and String(stale_band_poll.get("status", "")) == "pending" \
		and String(retry_band.get("jobKey", "")) == band_job_key \
		and String(retry_band_poll.get("status", "")) == "ready", {
		"firstStatus":band_first.get("status", ""),
		"secondStatus":band_second.get("status", ""),
		"emptyDisposition":band_first_poll.get("artifact", {}).get("disposition", ""),
		"sourceCompletionDigestMatchesEmptyManifest":String(empty_band_artifact.get(
			"sourceCompletionDigest", "")) == canonical_empty_manifest_digest,
		"ownerPayloadDigestMatchesEmptyManifest":String(empty_band_artifact.get(
			"ownerBatchPayloadDigest", "")) == canonical_empty_owner_payload_digest,
		"staleReason":stale_band_poll.get("reason", ""),
		"retryStatus":retry_band_poll.get("status", "")})
	var nonempty_band_result: Dictionary = await _catalog_scoped_nonempty_band_progresses()
	add_result("catalog_scoped_scheduler_advances_nonempty_band_without_legacy_work",
		bool(nonempty_band_result.get("passed", false)), nonempty_band_result)
	# A worker service is single-use. Its full canonical grammar must not remain
	# attached to a publication task after it returns the reduced render recipe.
	var worker_only_service = TreeSpawnServiceScript.new()
	var canonical_service = TreeSpawnServiceScript.new()
	var worker_recipe: Dictionary = worker_only_service.build_recipe_for_worker(request_for("queue-worker-recipe", "broadleaf", "bushy_oak", "forest"))
	var canonical_recipe: Dictionary = canonical_service.build_recipe(request_for("queue-worker-recipe", "broadleaf", "bushy_oak", "forest"))
	var worker_cache_metrics: Dictionary = worker_only_service.cache_metrics()
	add_result("single_use_worker_returns_same_reduced_recipe_without_private_canonical_cache", not worker_recipe.is_empty() \
		and String(worker_recipe.get("signature", "")) == String(canonical_recipe.get("signature", "")) \
		and int(worker_recipe.get("branchCount", -1)) == int(canonical_recipe.get("branchCount", -2)) \
		and int(worker_recipe.get("foliageClusterCount", -1)) == int(canonical_recipe.get("foliageClusterCount", -2)) \
		and int(worker_cache_metrics.get("recipeCacheEntries", -1)) == 0, {
		"workerCache": worker_cache_metrics,
		"branchCount": worker_recipe.get("branchCount", -1),
		"foliageCount": worker_recipe.get("foliageClusterCount", -1)
	})
	var recipe_input_queue = TreePublicationQueueScript.new()
	fixture.add_child(recipe_input_queue)
	recipe_input_queue.publication_service.prewarm_visuals()
	var recipe_input_body := tree_body("queue-worker-recipe")
	fixture.add_child(recipe_input_body)
	var recipe_input_request := request_for("queue-worker-recipe", "broadleaf", "bushy_oak", "forest")
	recipe_input_request["renderLodTier"] = "near"
	recipe_input_request["treeWorldPosition"] = recipe_input_body.global_position
	recipe_input_queue.set_section_owned_publication_enabled(true)
	recipe_input_queue.recipe_cache.store(
		recipe_input_queue.publication_service.recipe_cache_key(recipe_input_request), worker_recipe)
	var recipe_input_queued: bool = recipe_input_queue.enqueue(recipe_input_body, recipe_input_request)
	var recipe_input_retained := {"status":"retained" if recipe_input_queued else "failed"}
	var recipe_input_current := recipe_input_queue.tree_section_recipe_input_record_for_body(recipe_input_body)
	var recipe_input_record: Dictionary = recipe_input_current
	recipe_input_queue.set_section_owned_publication_enabled(false)
	add_result("completed_recipe_is_sealed_for_section_compilation_before_visual_publication", \
		recipe_input_queued and recipe_input_retained.get("status") == "retained" \
		and recipe_input_record.is_read_only() \
		and recipe_input_record.get("request", {}).is_read_only() \
		and recipe_input_record.get("recipeSnapshot", {}).is_read_only() \
		and recipe_input_record.get("recipeSignature", "") == worker_recipe.get("signature", "") \
		and recipe_input_record.get("contentRevision", "").length() == 64 \
		and recipe_input_current.get("contentRevision", "") == recipe_input_record.get("contentRevision", "") \
		and recipe_input_body.get_node_or_null("GeneratedTreeVisual") == null, {
		"queuePath":recipe_input_queued,
		"retainStatus":recipe_input_retained.get("status", ""),
		"artifactGeneration":recipe_input_record.get("artifactGeneration", 0),
		"contentRevision":recipe_input_record.get("contentRevision", ""),
		"visualAlreadyBuilt":recipe_input_body.get_node_or_null("GeneratedTreeVisual") != null
	})
	recipe_input_body.position.x += 1.0
	add_result("section_recipe_input_rejects_moved_owner_before_compile", \
		recipe_input_queue.tree_section_recipe_input_record_for_body(recipe_input_body).is_empty() \
		and recipe_input_queue.retain_tree_section_recipe_input_record(recipe_input_record).get("reason", "") == "tree_section_recipe_input_owner_stale", {
		"lookupAfterMove":recipe_input_queue.tree_section_recipe_input_record_for_body(recipe_input_body).size(),
		"retainAfterMove":recipe_input_queue.retain_tree_section_recipe_input_record(recipe_input_record).get("reason", "")
	})
	var stale_task_queue = TreePublicationQueueScript.new()
	fixture.add_child(stale_task_queue)
	var superseded_tree := tree_body("queue-superseded-generation")
	fixture.add_child(superseded_tree)
	superseded_tree.set_meta("tree_section_recipe_input_expected_generation", 2)
	stale_task_queue.enqueue_pending_task({"body":weakref(superseded_tree),
		"enqueueSequence":1, "publicationPosition":superseded_tree.global_position,
		"request":request_for("queue-superseded-generation", "broadleaf", "bushy_oak", "forest")})
	stale_task_queue.start_pending_workers()
	add_result("superseded_generation_is_dropped_before_worker_admission",
		stale_task_queue.pending_tasks.is_empty() and stale_task_queue.active.is_empty() \
		and stale_task_queue.cancelled_count == 1, {
		"pending":stale_task_queue.pending_tasks.size(),
		"active":stale_task_queue.active.size(),
		"cancelled":stale_task_queue.cancelled_count
	})
	var broadleaf := tree_body("queue-broadleaf")
	var conifer := tree_body("queue-conifer")
	fixture.add_child(broadleaf)
	fixture.add_child(conifer)
	var admission_started := Time.get_ticks_usec()
	var broadleaf_request: Dictionary = request_for(
		"queue-broadleaf", "broadleaf", "bushy_oak", "forest")
	var conifer_request: Dictionary = request_for(
		"queue-conifer", "conifer", "norway_spruce", "taiga")
	var admission_usec := Time.get_ticks_usec() - admission_started
	broadleaf_request = _freeze_contract_value(broadleaf_request) as Dictionary
	conifer_request = _freeze_contract_value(conifer_request) as Dictionary
	var admitted_requests_are_immutable := not broadleaf_request.is_empty() \
		and not conifer_request.is_empty() and broadleaf_request.is_read_only() \
		and conifer_request.is_read_only()
	add_result("certified_fixture_requests_are_pre_admitted_and_immutable",
		admitted_requests_are_immutable, {
		"fixtureAdmissionUsec": admission_usec,
		"broadleafRequestReadOnly": broadleaf_request.is_read_only(),
		"coniferRequestReadOnly": conifer_request.is_read_only()
	})
	var enqueue_started := Time.get_ticks_usec()
	var broadleaf_queued: bool = queue.enqueue(broadleaf, broadleaf_request)
	var broadleaf_enqueue_usec := Time.get_ticks_usec() - enqueue_started
	var conifer_enqueue_started := Time.get_ticks_usec()
	var conifer_queued: bool = queue.enqueue(conifer, conifer_request)
	var conifer_enqueue_usec := Time.get_ticks_usec() - conifer_enqueue_started
	var enqueue_usec := Time.get_ticks_usec() - enqueue_started
	add_result("enqueue_returns_without_sync_recipe_generation", broadleaf_queued and conifer_queued and enqueue_usec < 5000, {
		"enqueueUsec": enqueue_usec,
		"broadleafEnqueueUsec": broadleaf_enqueue_usec,
		"coniferEnqueueUsec": conifer_enqueue_usec,
		"fixtureAdmissionUsec": admission_usec
	})
	for _frame in range(480):
		if String(broadleaf.get_meta("tree_visual_state", "")) == "published" and String(conifer.get_meta("tree_visual_state", "")) == "published":
			break
		# `--fixed-fps` intentionally advances test frames as fast as possible;
		# without a small real-time yield, a worker-safe recipe thread can be
		# starved while this contract reaches its frame cap. This is test timing
		# only, not a production publication delay.
		OS.delay_msec(4)
		await process_frame
	var metrics: Dictionary = queue.metrics()
	var both_published := String(broadleaf.get_meta("tree_visual_state", "")) == "published" \
		and String(conifer.get_meta("tree_visual_state", "")) == "published"
	add_result("worker_built_recipes_publish_to_live_tree_bodies", both_published and int(metrics.get("published", 0)) == 2, {
		"metrics": metrics,
		"broadleafBranches": broadleaf.get_meta("tree_branch_count", 0),
		"coniferBranches": conifer.get_meta("tree_branch_count", 0),
		"broadleafWaitUsec": broadleaf.get_meta("tree_visual_queue_wait_usec", -1),
		"coniferWaitUsec": conifer.get_meta("tree_visual_queue_wait_usec", -1)
	})
	add_result("published_trees_keep_recipe_identity", String(broadleaf.get_meta("visual_asset_id", "")).begins_with("procedural:") \
		and String(conifer.get_meta("visual_asset_id", "")).begins_with("procedural:"), {
		"broadleafAsset": broadleaf.get_meta("visual_asset_id", ""),
		"coniferAsset": conifer.get_meta("visual_asset_id", "")
	})
	# A distant detail recipe can already be assembling when a player reaches a
	# new local tree. Its detached partial visual must yield safely: the new
	# local tree publishes first, while the original recipe remains retained for
	# later atomic completion rather than being cancelled or rebuilt.
	var priority_queue = TreePublicationQueueScript.new()
	fixture.add_child(priority_queue)
	priority_queue.publication_service.prewarm_visuals()
	var priority_viewer := Node3D.new()
	fixture.add_child(priority_viewer)
	var distant_assembly := tree_body("queue-distant-assembly")
	distant_assembly.position = Vector3(420.0, 0.0, 0.0)
	fixture.add_child(distant_assembly)
	var distant_request := request_for("queue-distant-assembly", "broadleaf", "bushy_oak", "forest")
	distant_request["treeWorldPosition"] = distant_assembly.global_position
	# No viewer is installed yet, so the request deliberately starts at the full
	# near tier and reaches an expensive detached assembly stage.
	distant_request["publicationPriority"] = 0.0
	var distant_queued: bool = priority_queue.enqueue(distant_assembly, distant_request)
	var distant_assembling := await wait_for_state(distant_assembly, "assembling")
	priority_queue.set_viewer(priority_viewer)
	var local_priority := tree_body("queue-local-priority")
	fixture.add_child(local_priority)
	var local_request := request_for("queue-local-priority", "broadleaf", "bushy_oak", "forest")
	local_request["treeWorldPosition"] = local_priority.global_position
	local_request["publicationPriority"] = 0.0
	# Seed the bounded queue cache with the exact request. The contract is about
	# renderer scheduling once a nearby recipe is already worker-complete, not
	# about racing an arbitrary worker duration against a short test fixture.
	local_request["renderLodTier"] = "near"
	var local_recipe: Dictionary = priority_queue.publication_service.build_recipe(local_request)
	priority_queue.recipe_cache.store(priority_queue.publication_service.recipe_cache_key(local_request), local_recipe)
	var local_queued: bool = priority_queue.enqueue(local_priority, local_request)
	var local_published := await wait_for_published(local_priority)
	var preemption_metrics: Dictionary = priority_queue.metrics()
	var distant_state_at_local_publish := String(distant_assembly.get_meta("tree_visual_state", ""))
	add_result("detached_far_assembly_yields_to_newly_ready_local_tree_without_drop", distant_queued and distant_assembling \
		and local_queued and local_published and distant_state_at_local_publish != "published" \
		and int(preemption_metrics.get("priorityScheduling", {}).get("preemptedDetachedTasks", 0)) >= 1 \
		and int(preemption_metrics.get("cancelled", 0)) == 0 and int(preemption_metrics.get("failed", 0)) == 0, {
		"distantStateAtLocalPublish": distant_state_at_local_publish,
		"localState": local_priority.get_meta("tree_visual_state", ""),
		"metrics": preemption_metrics
	})
	await wait_for_published(distant_assembly)
	var cached_restream := tree_body("queue-broadleaf-restream")
	fixture.add_child(cached_restream)
	var cached_request := request_for("queue-broadleaf", "broadleaf", "bushy_oak", "forest")
	var cache_enqueue_started := Time.get_ticks_usec()
	var cached_queued: bool = queue.enqueue(cached_restream, cached_request)
	var cache_enqueue_usec := Time.get_ticks_usec() - cache_enqueue_started
	var cache_published := await wait_for_published(cached_restream)
	metrics = queue.metrics()
	var cache_metrics: Dictionary = metrics.get("recipeCache", {})
	add_result("restream_reuses_bounded_main_thread_recipe_cache", cached_queued and cache_published \
		and int(cache_metrics.get("hits", 0)) >= 1 and int(metrics.get("recipeCacheReused", 0)) >= 1 \
		and cache_enqueue_usec < 5000, {
		"enqueueUsec": cache_enqueue_usec,
		"cache": cache_metrics,
		"state": cached_restream.get_meta("tree_visual_state", "")
	})
	var viewer := Node3D.new()
	viewer.name = "QueueContractViewer"
	fixture.add_child(viewer)
	queue.set_viewer(viewer)
	var lod_tree := tree_body("queue-distance-lod")
	lod_tree.position = Vector3(520.0, 0.0, 0.0)
	fixture.add_child(lod_tree)
	var lod_request := request_for("queue-distance-lod", "broadleaf", "bushy_oak", "forest")
	lod_request["treeWorldPosition"] = lod_tree.global_position
	lod_request["publicationPriority"] = lod_tree.global_position.distance_squared_to(viewer.global_position)
	var far_queued: bool = queue.enqueue(lod_tree, lod_request)
	var far_published := await wait_for_published(lod_tree)
	var initial_tier := String(lod_tree.get_meta("tree_render_lod_tier", ""))
	var impostor_present := lod_tree.get_node_or_null("GeneratedTreeVisual/ProceduralTreeImpostor") != null
	viewer.position = lod_tree.position
	var near_rebuilt := await wait_for_lod(lod_tree, "near")
	metrics = queue.metrics()
	add_result("distance_lod_rebuilds_from_far_impostor_to_near_recipe_with_hysteresis", far_queued and far_published \
		and initial_tier == "impostor" and impostor_present and near_rebuilt \
		and int(metrics.get("lod", {}).get("rebuilds", 0)) >= 1, {
		"initialTier": initial_tier,
		"finalTier": lod_tree.get_meta("tree_render_lod_tier", ""),
		"impostorPresent": impostor_present,
		"lod": metrics.get("lod", {})
	})
	# Moving away from a full near recipe must not invoke the grammar again just
	# to obtain the smaller mid representation. The cache lends its immutable
	# higher-detail graph to a worker, which performs the same graph-preserving
	# reduction used by ordinary LOD publication. This keeps source ownership
	# bounded by TreeRecipeCache and keeps the gameplay frame out of the copy.
	viewer.position = lod_tree.position + Vector3(-120.0, 0.0, 0.0)
	var mid_rebuilt_from_near := await wait_for_lod(lod_tree, "mid")
	metrics = queue.metrics()
	var lod_derivation: Dictionary = metrics.get("lodRecipeDerivation", {})
	var lod_cache: Dictionary = metrics.get("recipeCache", {})
	add_result("lod_downshift_derives_from_cached_higher_detail_recipe_on_worker", mid_rebuilt_from_near \
		and int(lod_derivation.get("requested", 0)) >= 1 \
		and int(lod_derivation.get("completed", 0)) >= 1 \
		and int(lod_cache.get("lodDerivationHits", 0)) >= 1, {
		"renderLod": lod_tree.get_meta("tree_render_lod_tier", ""),
		"lodDerivation": lod_derivation,
		"cache": lod_cache
	})
	# A player can move across a LOD boundary after a chunk records an intent but
	# before the worker begins. The queue must retier first, rather than spending
	# worker/renderer time on an obsolete near graph and replacing it later.
	var prepublication_queue = TreePublicationQueueScript.new()
	fixture.add_child(prepublication_queue)
	prepublication_queue.publication_service.prewarm_visuals()
	var prepublication_viewer := Node3D.new()
	fixture.add_child(prepublication_viewer)
	var prepublication_tree := tree_body("queue-prepublication-retier")
	prepublication_tree.position = Vector3(520.0, 0.0, 0.0)
	fixture.add_child(prepublication_tree)
	var prepublication_request := request_for("queue-prepublication-retier", "broadleaf", "bushy_oak", "forest")
	prepublication_request["treeWorldPosition"] = prepublication_tree.global_position
	prepublication_request["publicationPriority"] = 0.0
	var near_intent_queued: bool = prepublication_queue.enqueue(prepublication_tree, prepublication_request)
	prepublication_queue.set_viewer(prepublication_viewer)
	var retiered_before_publication := await wait_for_published(prepublication_tree)
	var prepublication_metrics: Dictionary = prepublication_queue.metrics()
	add_result("queued_near_tree_retiers_before_worker_and_skips_obsolete_detail_recipe", near_intent_queued and retiered_before_publication \
		and String(prepublication_tree.get_meta("tree_render_lod_tier", "")) == "impostor" \
		and int(prepublication_tree.get_meta("tree_branch_count", -1)) == 0 \
		and int(prepublication_metrics.get("published", 0)) == 1, {
		"tier": prepublication_tree.get_meta("tree_render_lod_tier", ""),
		"branches": prepublication_tree.get_meta("tree_branch_count", -1),
		"metrics": prepublication_metrics
	})
	# If a worker has already completed, cancelling its graph/partial MultiMesh
	# during a camera move is more expensive than finishing the bounded atomic
	# publish. The published-LOD reconciler must then replace it safely.
	var reconciliation_queue = TreePublicationQueueScript.new()
	fixture.add_child(reconciliation_queue)
	reconciliation_queue.publication_service.prewarm_visuals()
	var reconciliation_viewer := Node3D.new()
	fixture.add_child(reconciliation_viewer)
	var reconciliation_tree := tree_body("queue-post-worker-reconciliation")
	reconciliation_tree.position = Vector3(18.0, 0.0, 0.0)
	fixture.add_child(reconciliation_tree)
	var reconciliation_request := request_for("queue-post-worker-reconciliation", "broadleaf", "bushy_oak", "forest")
	reconciliation_request["treeWorldPosition"] = reconciliation_tree.global_position
	reconciliation_request["publicationPriority"] = reconciliation_tree.global_position.distance_squared_to(reconciliation_viewer.global_position)
	reconciliation_queue.set_viewer(reconciliation_viewer)
	var reconciliation_queued: bool = reconciliation_queue.enqueue(reconciliation_tree, reconciliation_request)
	var reached_assembly := await wait_for_state(reconciliation_tree, "assembling")
	reconciliation_viewer.position = Vector3(-520.0, 0.0, 0.0)
	var reconciled_to_impostor := await wait_for_lod(reconciliation_tree, "impostor")
	var reconciliation_metrics: Dictionary = reconciliation_queue.metrics()
	add_result("completed_recipe_finishes_atomically_then_reconciles_lod_without_cancellation", reconciliation_queued and reached_assembly \
		and reconciled_to_impostor and int(reconciliation_metrics.get("published", 0)) >= 2 \
		and int(reconciliation_metrics.get("cancelled", 0)) == 0 and int(reconciliation_metrics.get("failed", 0)) == 0, {
		"tier": reconciliation_tree.get_meta("tree_render_lod_tier", ""),
		"metrics": reconciliation_metrics
	})
	# Streamed chunks can enqueue a large horizon backlog before a worker becomes
	# available. The local request added last must launch without sorting or
	# shifting that backlog, while the oldest distant task remains eligible as
	# the second fairness candidate.
	var pending_stress_queue = TreePublicationQueueScript.new()
	fixture.add_child(pending_stress_queue)
	var pending_stress_viewer := Node3D.new()
	fixture.add_child(pending_stress_viewer)
	pending_stress_queue.set_viewer(pending_stress_viewer)
	for index in range(160):
		var distant_pending := tree_body("queue-pending-stress-%d" % index)
		distant_pending.position = Vector3(360.0 + float(index) * 20.0, 0.0, 0.0)
		fixture.add_child(distant_pending)
		var distant_pending_request := request_for("queue-pending-stress-%d" % index, "broadleaf", "bushy_oak", "forest")
		distant_pending_request["treeWorldPosition"] = distant_pending.global_position
		distant_pending_request["publicationPriority"] = distant_pending.global_position.distance_squared_to(pending_stress_viewer.global_position)
		pending_stress_queue.enqueue(distant_pending, distant_pending_request)
	var immediate_pending := tree_body("queue-pending-immediate")
	immediate_pending.position = Vector3(4.0, 0.0, 0.0)
	fixture.add_child(immediate_pending)
	var immediate_pending_request := request_for("queue-pending-immediate", "broadleaf", "bushy_oak", "forest")
	immediate_pending_request["treeWorldPosition"] = immediate_pending.global_position
	immediate_pending_request["publicationPriority"] = immediate_pending.global_position.distance_squared_to(pending_stress_viewer.global_position)
	var immediate_pending_queued: bool = pending_stress_queue.enqueue(immediate_pending, immediate_pending_request)
	pending_stress_queue.start_pending_workers()
	var pending_stress_metrics: Dictionary = pending_stress_queue.metrics()
	var worker_priority: Dictionary = pending_stress_metrics.get("workerPriorityScheduling", {})
	add_result("dense_pending_backlog_launches_nearest_recipe_with_bounded_worker_selection", immediate_pending_queued \
		and String(immediate_pending.get_meta("tree_visual_state", "")) == "building" \
		and int(pending_stress_metrics.get("pending", 0)) >= 159 \
		and int(worker_priority.get("maxSelectionCandidates", 0)) <= 2 \
		and String(worker_priority.get("queueModel", "")) == "indexed_local_priority_fifo_fairness", {
		"immediateState": immediate_pending.get_meta("tree_visual_state", ""),
		"metrics": pending_stress_metrics
	})
	# A viewer may be unavailable during startup or a short player rebind. With
	# no meaningful distance coordinate, completed publication must use stable
	# FIFO rather than globally scanning the backlog.
	var viewless_queue = TreePublicationQueueScript.new()
	fixture.add_child(viewless_queue)
	for index in range(48):
		var viewless_body := tree_body("queue-viewless-%d" % index)
		viewless_body.position = Vector3(float(index) * 8.0, 0.0, 0.0)
		fixture.add_child(viewless_body)
		viewless_queue.enqueue_completed_task({
			"body": weakref(viewless_body),
			"publicationPosition": viewless_body.global_position,
			"enqueuedUsec": Time.get_ticks_usec(),
			"enqueueSequence": index + 1,
			"request": {},
			"recipe": {}
		})
	var viewless_selected_index := viewless_queue.highest_priority_completed_index()
	var viewless_metrics: Dictionary = viewless_queue.metrics()
	var viewless_priority: Dictionary = viewless_metrics.get("priorityScheduling", {})
	add_result("viewerless_completed_backlog_uses_bounded_fifo_without_global_priority_scan", viewless_selected_index == 0 \
		and int(viewless_priority.get("viewlessFifoSelections", 0)) >= 1 \
		and int(viewless_priority.get("fullFallbackSelections", 0)) == 0 \
		and int(viewless_priority.get("maxSelectionCandidates", 0)) <= 1, {
		"selectedIndex": viewless_selected_index,
		"priority": viewless_priority
	})
	# The pinned startup failure left a 20m tree behind hundreds of recipes for
	# 171 seconds. Test actual bounded completed selection with an older distant
	# task, then prove the oldest can still win after substantially more waiting.
	var age_queue = TreePublicationQueueScript.new()
	fixture.add_child(age_queue)
	var age_viewer := Node3D.new()
	fixture.add_child(age_viewer)
	age_queue.set_viewer(age_viewer)
	var age_far := tree_body("queue-age-far")
	age_far.position = Vector3(120.0, 0.0, 0.0)
	fixture.add_child(age_far)
	var age_near := tree_body("queue-age-near")
	age_near.position = Vector3(20.0, 0.0, 0.0)
	fixture.add_child(age_near)
	var age_now := Time.get_ticks_usec()
	age_queue.enqueue_completed_task({"body": weakref(age_far),
		"publicationPosition": age_far.global_position,
		"enqueuedUsec": age_now - 172000000,
		"enqueueSequence": 1, "request": {}, "recipe": {}})
	age_queue.enqueue_completed_task({"body": weakref(age_near),
		"publicationPosition": age_near.global_position,
		"enqueuedUsec": age_now - 171000000,
		"enqueueSequence": 2, "request": {}, "recipe": {}})
	var aged_near_index := age_queue.highest_priority_completed_index()
	var aged_near_score := age_queue.effective_priority_at(age_queue.completed[1], age_now, Vector3.ZERO)
	var aged_far_score := age_queue.effective_priority_at(age_queue.completed[0], age_now, Vector3.ZERO)
	add_result("aged_near_tree_outranks_slightly_older_far_recipe_without_zero_score_collapse", \
		aged_near_index == 1 and aged_near_score > 0.0 and aged_near_score < aged_far_score, {
		"selectedIndex": aged_near_index, "nearScore": aged_near_score,
		"farScore": aged_far_score})
	age_queue.completed[0]["enqueuedUsec"] = age_now - 1200000000
	var very_old_far_index := age_queue.highest_priority_completed_index()
	var very_old_far_score := age_queue.effective_priority_at(age_queue.completed[0], age_now, Vector3.ZERO)
	var age_priority: Dictionary = age_queue.metrics().get("priorityScheduling", {})
	add_result("very_old_far_tree_eventually_wins_with_two_candidate_bounded_selection", \
		very_old_far_index == 0 and very_old_far_score < aged_near_score \
		and int(age_priority.get("maxSelectionCandidates", 0)) <= 2 \
		and int(age_priority.get("fullFallbackSelections", 0)) == 0, {
		"selectedIndex": very_old_far_index, "nearScore": aged_near_score,
		"farScore": very_old_far_score, "priority": age_priority})
	var tie_older := {"publicationPosition": Vector3(20.0, 0.0, 0.0),
		"enqueuedUsec": age_now - 171000000, "enqueueSequence": 4}
	var tie_newer := tie_older.duplicate()
	tie_newer["enqueueSequence"] = 5
	add_result("equal_age_and_distance_preserve_enqueue_sequence_tie_break", \
		age_queue.task_precedes_at(tie_older, tie_newer, age_now, Vector3.ZERO) \
		and not age_queue.task_precedes_at(tie_newer, tie_older, age_now, Vector3.ZERO), {})
	# Direction is a presentation signal only, but a confidently sprinting
	# player must see the tree in their actual arrival corridor before equally
	# near side/behind work. The task data itself remains immutable and no RNG
	# participates in this ordering decision.
	var directional_queue = TreePublicationQueueScript.new()
	fixture.add_child(directional_queue)
	var directional_viewer := Node3D.new()
	fixture.add_child(directional_viewer)
	directional_queue.set_viewer(directional_viewer)
	directional_queue.set_viewer_motion_snapshot(Vector3.ZERO, Vector3(15.5, 0.0, 0.0), Vector3.RIGHT)
	var directional_bodies: Array[StaticBody3D] = []
	for direction_case in [
		{"id": "lateral", "position": Vector3(0.0, 0.0, 18.0)},
		{"id": "behind", "position": Vector3(-18.0, 0.0, 0.0)},
		{"id": "forward", "position": Vector3(18.0, 0.0, 0.0)}
	]:
		var directional_body := tree_body("queue-directional-%s" % String(direction_case.get("id", "tree")))
		directional_body.position = direction_case.get("position", Vector3.ZERO)
		fixture.add_child(directional_body)
		directional_bodies.append(directional_body)
		directional_queue.enqueue_completed_task({
			"body": weakref(directional_body),
			"publicationPosition": directional_body.global_position,
			"enqueuedUsec": Time.get_ticks_usec(),
			"enqueueSequence": directional_bodies.size(),
			"request": {},
			"recipe": {}
		})
	var directional_selected := directional_queue.take_next_completed_task()
	var directional_metrics: Dictionary = directional_queue.metrics()
	add_result("confident_motion_prioritizes_forward_tree_over_equal_distance_lateral_and_behind_work", \
		String((directional_selected.get("body") as WeakRef).get_ref().name) == "queue-directional-forward" \
		and int(directional_metrics.get("priorityScheduling", {}).get("directionalPublicationSelections", 0)) == 1, {
		"selected": (directional_selected.get("body") as WeakRef).get_ref().name if directional_selected.has("body") else "",
		"priority": directional_metrics.get("priorityScheduling", {})
	})
	var stationary_queue = TreePublicationQueueScript.new()
	fixture.add_child(stationary_queue)
	stationary_queue.set_viewer(directional_viewer)
	stationary_queue.set_viewer_motion_snapshot(Vector3.ZERO, Vector3.ZERO, Vector3.RIGHT)
	var stationary_near := tree_body("queue-stationary-near")
	stationary_near.position = Vector3(0.0, 0.0, 8.0)
	fixture.add_child(stationary_near)
	var stationary_forward := tree_body("queue-stationary-forward")
	stationary_forward.position = Vector3(18.0, 0.0, 0.0)
	fixture.add_child(stationary_forward)
	for stationary_entry in [
		{"body": stationary_near, "sequence": 1},
		{"body": stationary_forward, "sequence": 2}
	]:
		var stationary_body := stationary_entry.get("body") as StaticBody3D
		stationary_queue.enqueue_completed_task({
			"body": weakref(stationary_body),
			"publicationPosition": stationary_body.global_position,
			"enqueuedUsec": Time.get_ticks_usec(),
			"enqueueSequence": int(stationary_entry.get("sequence", 0)),
			"request": {},
			"recipe": {}
		})
	var stationary_selected := stationary_queue.take_next_completed_task()
	add_result("stationary_motion_falls_back_to_distance_priority", \
		String((stationary_selected.get("body") as WeakRef).get_ref().name) == "queue-stationary-near", {
		"selected": (stationary_selected.get("body") as WeakRef).get_ref().name if stationary_selected.has("body") else "",
		"priority": stationary_queue.metrics().get("priorityScheduling", {})
	})
	# A body with real trunk collision receives a shared proxy synchronously at
	# enqueue when it is already inside the collision-visibility horizon. The
	# final queue commit must replace that proxy without changing identity.
	var visibility_queue = TreePublicationQueueScript.new()
	fixture.add_child(visibility_queue)
	visibility_queue.publication_service.prewarm_visuals()
	visibility_queue.set_viewer(directional_viewer)
	visibility_queue.set_viewer_motion_snapshot(Vector3.ZERO, Vector3(15.5, 0.0, 0.0), Vector3.RIGHT)
	var collision_tree := tree_body("queue-collision-visible")
	collision_tree.position = Vector3(12.0, 0.0, 0.0)
	var collision_shape := CollisionShape3D.new()
	var collision_geometry := CylinderShape3D.new()
	collision_geometry.radius = 0.88
	collision_geometry.height = 8.0
	collision_shape.shape = collision_geometry
	collision_tree.add_child(collision_shape)
	fixture.add_child(collision_tree)
	var collision_request := request_for("queue-collision-visible", "broadleaf", "bushy_oak", "forest")
	collision_request["treeWorldPosition"] = collision_tree.global_position
	var collision_queued := visibility_queue.enqueue(collision_tree, collision_request)
	var proxy_attached := collision_tree.get_node_or_null("TreeVisibilityProxy") != null \
		and bool(collision_tree.get_meta("tree_visibility_proxy", false)) \
		and int(collision_tree.get_meta("tree_relevant_collision_to_first_visual_lag_usec", -1)) >= 0
	var collision_published := await wait_for_published(collision_tree)
	var collision_metrics: Dictionary = visibility_queue.metrics()
	add_result("collision_relevant_tree_is_visibly_represented_before_final_recipe_and_replaced_atomically", \
		collision_queued and proxy_attached and collision_published \
		and collision_tree.get_node_or_null("TreeVisibilityProxy") == null \
		and collision_tree.get_node_or_null("GeneratedTreeVisual") != null \
		and String(collision_tree.get_meta("prop_id", "")) == "queue-collision-visible" \
		and int(collision_metrics.get("collisionVisibility", {}).get("proxyAttachments", 0)) >= 1 \
		and int(collision_metrics.get("collisionVisibility", {}).get("collisionBeforeVisualInvariantBreaches", -1)) == 0, {
		"proxyAttached": proxy_attached,
		"firstVisualSource": collision_tree.get_meta("tree_first_visual_source", ""),
		"visibility": collision_metrics.get("collisionVisibility", {})
	})
	# Collision can be published before the player enters its local horizon. Once
	# the player actually approaches that already-queued body, the bounded local
	# guard must attach the same shared proxy before the recipe is ready; this is
	# the production failure mode behind an otherwise invisible tree collision.
	var approaching_queue = TreePublicationQueueScript.new()
	fixture.add_child(approaching_queue)
	approaching_queue.publication_service.prewarm_visuals()
	approaching_queue.set_viewer(directional_viewer)
	approaching_queue.set_viewer_motion_snapshot(Vector3.ZERO, Vector3.ZERO, Vector3.RIGHT)
	var approaching_tree := tree_body("queue-collision-approach")
	approaching_tree.position = Vector3(44.0, 0.0, 0.0)
	var approaching_shape := CollisionShape3D.new()
	var approaching_geometry := CylinderShape3D.new()
	approaching_geometry.radius = 0.88
	approaching_geometry.height = 8.0
	approaching_shape.shape = approaching_geometry
	approaching_tree.add_child(approaching_shape)
	fixture.add_child(approaching_tree)
	var approaching_request := request_for("queue-collision-approach", "broadleaf", "bushy_oak", "forest")
	approaching_request["treeWorldPosition"] = approaching_tree.global_position
	var approaching_queued := approaching_queue.enqueue(approaching_tree, approaching_request)
	var proxy_absent_while_far := approaching_tree.get_node_or_null("TreeVisibilityProxy") == null
	approaching_queue.set_viewer_motion_snapshot(Vector3(24.0, 0.0, 0.0), Vector3(15.5, 0.0, 0.0), Vector3.RIGHT)
	approaching_queue.refresh_collision_visibility_proxies()
	var proxy_attached_on_approach := approaching_tree.get_node_or_null("TreeVisibilityProxy") != null \
		and String(approaching_tree.get_meta("tree_first_visual_source", "")) == "shared_visibility_proxy" \
		and int(approaching_tree.get_meta("tree_relevant_collision_to_first_visual_lag_usec", -1)) >= 0
	add_result("queued_tree_gains_shared_visibility_proxy_when_player_enters_collision_horizon", \
		approaching_queued and proxy_absent_while_far and proxy_attached_on_approach \
		and int(approaching_queue.metrics().get("collisionVisibility", {}).get("collisionBeforeVisualInvariantBreaches", -1)) == 0, {
		"queued": approaching_queued,
		"proxyAbsentWhileFar": proxy_absent_while_far,
		"proxyAttachedOnApproach": proxy_attached_on_approach,
		"visibility": approaching_queue.metrics().get("collisionVisibility", {})
	})
	var cache_capacity = TreeRecipeCacheScript.new()
	cache_capacity.configure(2, 8192)
	for index in range(3):
		cache_capacity.store("capacity-%d" % index, {"branches": [], "foliage": [], "signature": "capacity-%d" % index})
	var bounded_cache_metrics: Dictionary = cache_capacity.metrics()
	add_result("recipe_cache_has_explicit_entry_and_memory_bounds", int(bounded_cache_metrics.get("entries", 0)) <= 2 \
		and int(bounded_cache_metrics.get("estimatedBytes", 0)) <= int(bounded_cache_metrics.get("byteCapacity", 0)) \
		and int(bounded_cache_metrics.get("evictions", 0)) >= 1, {
		"cache": bounded_cache_metrics
	})
	var lod_index_cache = TreeRecipeCacheScript.new()
	lod_index_cache.configure(96, 12 * 1024 * 1024)
	var lod_identity := "queue-contract-lod-index"
	lod_index_cache.store("lod-index-near", {"branches": [], "foliage": [], "signature": "near"}, lod_identity, "near")
	lod_index_cache.store("lod-index-mid", {"branches": [], "foliage": [], "signature": "mid"}, lod_identity, "mid")
	var indexed_source := lod_index_cache.fetch_compatible_lod_source(lod_identity, "far")
	var indexed_metrics: Dictionary = lod_index_cache.metrics()
	add_result("lod_source_cache_uses_identity_tier_index_and_prefers_closest_higher_detail_source", String(indexed_source.get("signature", "")) == "mid" \
		and int(indexed_metrics.get("lodDerivationHits", 0)) == 1 \
		and int(indexed_metrics.get("lodDerivationIndexLookups", 0)) == 1, {
		"source": indexed_source.get("signature", ""),
		"cache": indexed_metrics
	})
	var passed := true
	for result in results:
		passed = passed and bool(result.get("passed", false))
	print(JSON.stringify({
		"runnerId": "tree_publication_queue_contract",
		"evidenceLevel": "contract",
		"scope": "Asynchronous mathematical recipe construction and bounded publication. This does not prove normal-runtime chunk traversal performance.",
		"passed": passed,
		"results": results
	}))
	fixture.queue_free()
	quit(0 if passed else 1)

func tree_body(id: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = id
	body.set_meta("prop_id", id)
	return body

func request_for(id: String, architecture: String, grammar: String, biome: String) -> Dictionary:
	return CertifiedRequestFixture.prepare_or_fail({
		"treeId": id,
		"worldSeed": "queue-contract-world",
		"biome": biome,
		"architecture": architecture,
		"speciesGrammar": grammar,
		"growthStage": 0.80,
		"canopyDensity": 0.82,
		"presentation": "runtime"
	})

func _freeze_contract_value(value: Variant) -> Variant:
	if value is Dictionary:
		var frozen: Dictionary = {}
		for key: Variant in value.keys():
			frozen[key] = _freeze_contract_value(value[key])
		frozen.make_read_only()
		return frozen
	if value is Array:
		var frozen: Array = []
		for item: Variant in value:
			frozen.append(_freeze_contract_value(item))
		frozen.make_read_only()
		return frozen
	return value

func wait_for_published(body: StaticBody3D, max_frames := 720) -> bool:
	for _frame in range(max_frames):
		if String(body.get_meta("tree_visual_state", "")) == "published":
			return true
		OS.delay_msec(4)
		await process_frame
	return String(body.get_meta("tree_visual_state", "")) == "published"

func wait_for_lod(body: StaticBody3D, tier: String, max_frames := 720) -> bool:
	for _frame in range(max_frames):
		if String(body.get_meta("tree_visual_state", "")) == "published" and String(body.get_meta("tree_render_lod_tier", "")) == tier:
			return true
		OS.delay_msec(4)
		await process_frame
	return String(body.get_meta("tree_visual_state", "")) == "published" and String(body.get_meta("tree_render_lod_tier", "")) == tier

func wait_for_state(body: StaticBody3D, target_state: String, max_frames := 720) -> bool:
	for _frame in range(max_frames):
		if String(body.get_meta("tree_visual_state", "")) == target_state:
			return true
		OS.delay_msec(4)
		await process_frame
	return String(body.get_meta("tree_visual_state", "")) == target_state

func add_result(name: String, passed: bool, details: Dictionary) -> void:
	results.append({"name": name, "passed": passed, "details": details})


func _catalog_scoped_nonempty_band_progresses() -> Dictionary:
	var main = EcologySectionContract.ProductionAuthority.new()
	main.seed_text = "queue-band-nonempty-world"
	main.seed_hash = 73
	var catalog = BiomeEnvironmentCatalogScript.new()
	if not catalog.setup():
		main.free()
		return {"passed":false, "reason":"fixture_biome_catalog_setup_failed"}
	var captured_profiles: Dictionary = ActiveBiomeEnvironmentSnapshotScript.capture(catalog)
	if not bool(captured_profiles.get("ok", false)):
		main.free()
		return {"passed":false, "reason":"fixture_biome_snapshot_capture_failed"}
	# This nonempty source must use the same complete profile snapshot for its
	# recipe request and the synthetic authority's certified spatial policy.
	# Other adapter contracts intentionally keep minimized profiles; mixing that
	# policy with a full-catalog forest request would test a fabricated mismatch.
	main._profile_snapshot = {"ok":true,
		"schemaVersion":int(captured_profiles.get("schemaVersion", -1)),
		"fallbackId":String(captured_profiles.get("fallbackId", "")),
		"contentIdentity":String(captured_profiles.get("contentIdentity", "")),
		"profiles":(captured_profiles.get("profiles", []) as Array).duplicate(true)}
	main._tree_request_envelope = EcologyProducerDomainScript.derive_tree_request_envelope(
		main._profile_snapshot)
	main._tree_support_envelope = EcologyProducerDomainScript.derive_tree_grammar_support_envelope(
		main._profile_snapshot)
	if String(main._tree_support_envelope.get("status", "")) != "ready":
		var unavailable_envelope: Dictionary = main._tree_support_envelope.duplicate(true)
		main.free()
		return {"passed":false, "reason":"fixture_full_tree_support_envelope_unavailable",
			"treeSupportEnvelope":unavailable_envelope}
	# The fixture's bounded rock artifact is synthetic, so reseal its profile
	# identity alongside the full catalog used by the tree request.
	var synthetic_rock_digest := EcologyProducerDomainScript.digest_value([
		"synthetic-rock-catalog-v1", main._profile_snapshot.contentIdentity])
	main._rock_envelope["profileCatalogRevision"] = main._profile_snapshot.contentIdentity
	main._rock_envelope["eligibleAssetSetDigest"] = synthetic_rock_digest
	main._rock_envelope["digest"] = synthetic_rock_digest
	main._rock_envelope["assetSetDigest"] = synthetic_rock_digest
	get_root().add_child(main)
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	var source_chunk := Vector2i.ZERO
	var source_origin := Vector3(2.0, 0.0, 2.0)
	var policy_inputs: Dictionary = main.ecology_source_support_policy_inputs(
		world_id, source_chunk, main.seed_text, {})
	var support_policy: Dictionary = policy_inputs.get("supportPolicy", {})
	var runtime_spec := request_for("queue-band-nonempty-tree", "broadleaf",
		"bushy_oak", "forest")
	runtime_spec["worldSeed"] = main.seed_text
	runtime_spec["treeWorldPosition"] = source_origin
	runtime_spec["renderLodTier"] = "near"
	var normalized: Dictionary = TreeSpawnServiceScript.new().normalize_request(runtime_spec)
	var request_certificate: Dictionary = normalized.get("treeAdmissionCertificate", {})
	var certificate_snapshot: Dictionary = request_certificate.get(
		"profileCatalogSnapshot", {})
	var request_catalog_matches_authority := String(certificate_snapshot.get(
		"contentIdentity", "")) == String(main._profile_snapshot.get("contentIdentity", "")) \
		and String(normalized.get("treeProducerCatalogRevision", "")) == String(
			main._profile_snapshot.get("contentIdentity", ""))
	var recipe: Dictionary = TreeSpawnServiceScript.new().build_recipe(normalized)
	var tree_transform := Transform3D(Basis.IDENTITY, source_origin)
	var support_envelope: Dictionary = TreeRecipeSectionCompilerScript.certify_recipe_support_envelope(
		recipe, tree_transform)
	var support_value: Dictionary = support_envelope.get("value", {})
	var source_bounds: Variant = support_value.get("worldBounds", null)
	var support_proof: Dictionary = EcologyProducerDomainScript.validate_source_bounds(
		"trees", source_origin, source_bounds if source_bounds is AABB else AABB(),
		support_policy)
	if source_bounds is AABB:
		support_proof["worldBounds"] = source_bounds
		support_proof["sourceOrigin"] = source_origin
	var source_id := "%s:tree:queue-band-nonempty-tree" % main.seed_text
	var source_row := {"schema":"ecology.static_source_value.v1",
		"sourceId":source_id, "propId":"queue-band-nonempty-tree",
		"producerFamily":"trees", "kind":"trees_foliage", "recipeVersion":2,
		"biome":"forest", "sourceOrigin":source_origin, "transform":tree_transform,
		"runtimeSpec":normalized,
		"legacySpec":{"height":float(recipe.get("height", 8.0)),
			"trunk_radius":float(recipe.get("trunkRadius", 0.4)),
			"canopy_radius":float(recipe.get("canopyRadius", 3.0))},
		"supportProof":support_proof}
	main.set_fixture_rows(source_chunk, [source_row])
	var capture: Dictionary = main.capture_ecology_source_domain(world_id,
		source_chunk, main.seed_text, policy_inputs.get("sourceInputs", {}),
		RemovedPropsScript.capture(main))
	var snapshot: Dictionary = capture.get("snapshot", {})
	var publication_view: Dictionary = capture.get("sourcePublicationView", {})
	var tree_family: Dictionary = publication_view.get("familyResultsById", {}).get(
		"trees", {})
	var tree_rows: Array = tree_family.get("sourceRows", [])
	var family_row: Dictionary = tree_rows[0] if not tree_rows.is_empty() else {}
	var support_families: Dictionary = support_policy.get("families", {})
	var tree_support_policy: Dictionary = support_families.get("trees", {})
	var captured_support_proof: Dictionary = family_row.get("supportProof", {})
	var section_key := Vector3i.ZERO
	var publication_token := String(capture.get("sourcePublicationLeaseToken", ""))
	var authority := {"schema":"ecology-tree-source-family-band-authority/v1",
		"worldId":world_id, "sourceChunkKey":source_chunk, "sectionKey":section_key,
		"sourceRevision":String(snapshot.get("sourceRevision", "")),
		"sourcePublicationId":String(publication_view.get("publicationId", "")),
		"sourcePublicationContentDigest":String(publication_view.get("contentDigest", "")),
		"sourceFamilyRevision":String(tree_family.get("familyRevision", "")),
		"sourceFamilyManifestDigest":String(tree_family.get("sourceManifestDigest", "")),
		"producerSourceIds":[source_id],
		"producerSourceIdsDigest":EcologyProducerDomainScript._digest([source_id]),
		"producerDisposition":"complete_nonempty",
		"publicationLeaseToken":publication_token}
	var authority_identity: Dictionary = authority.duplicate(true)
	authority_identity.erase("publicationLeaseToken")
	authority["authorityDigest"] = _canonical_digest(authority_identity)
	authority = _freeze_contract_value(authority) as Dictionary
	var band_queue = TreePublicationQueueScript.new()
	main.add_child(band_queue)
	main.tree_publication_queue = band_queue
	band_queue.publication_service.prewarm_visuals()
	band_queue.set_process(true)
	var consumer := "queue-band-nonempty-consumer"
	var request_result: Dictionary = band_queue.request_ecology_tree_source_band_compile(
		main, snapshot, section_key, authority, publication_view, consumer)
	var job_key := String(request_result.get("jobKey", ""))
	var initial_job: Dictionary = band_queue.ecology_tree_band_compile_jobs.get(
		job_key, {})
	var initial_job_status := String(initial_job.get("status", ""))
	var source_job_rows: Array = band_queue.ecology_source_compile_jobs.values()
	var first_source_job: Dictionary = source_job_rows[0] if not source_job_rows.is_empty() else {}
	var source_record_jobs_bounded: bool = \
		band_queue.ecology_source_compile_jobs.size() == 1 \
		and String(first_source_job.get("artifactKind", "")) == "tree_source_record_geometry" \
		and String(first_source_job.get("sourceId", "")) == source_id \
		and band_queue.active.is_empty() and band_queue.pending_tasks.is_empty() \
		and band_queue.active_tree_section_compile_record.is_empty()
	var terminal: Dictionary = {}
	for _frame in range(2400):
		await process_frame
		terminal = band_queue.poll_ecology_tree_source_band_compile(job_key, consumer)
		if String(terminal.get("status", "")) != "pending":
			break
	var artifact: Dictionary = terminal.get("artifact", {})
	var completion_manifest: Variant = artifact.get("sourceCompletionManifest", null)
	var owner_payload: Variant = artifact.get("ownerBatchContributors", null)
	var completion_digest_matches_admitted_payload := completion_manifest is Array \
		and String(artifact.get("sourceCompletionDigest", "")) \
		== _canonical_digest(completion_manifest)
	var owner_payload_digest_matches_admitted_payload := owner_payload is Array \
		and String(artifact.get("ownerBatchPayloadDigest", "")) \
		== _canonical_digest(owner_payload)
	var terminal_band_job: Dictionary = band_queue.ecology_tree_band_compile_jobs.get(
		job_key, {})
	var terminal_job_count: int = band_queue.ecology_tree_band_compile_jobs.size()
	var terminal_source_job_keys: Array[String] = []
	for source_job_key_value: Variant in terminal_band_job.get("recordJobKeys", {}).values():
		terminal_source_job_keys.append(String(source_job_key_value))
	terminal_source_job_keys.sort()
	terminal_band_job["status"] = "failed"
	terminal_band_job["reason"] = "fixture_terminal_band_failure"
	band_queue.ecology_tree_band_compile_jobs[job_key] = terminal_band_job
	var failed_repeat: Dictionary = band_queue.request_ecology_tree_source_band_compile(
		main, snapshot, section_key, authority, publication_view,
		"queue-band-nonempty-terminal-retry")
	var retained_terminal_job: Dictionary = band_queue.ecology_tree_band_compile_jobs.get(
		job_key, {})
	var retained_source_job_keys: Array[String] = []
	for source_job_key_value: Variant in retained_terminal_job.get(
		"recordJobKeys", {}).values():
		retained_source_job_keys.append(String(source_job_key_value))
	retained_source_job_keys.sort()
	var terminal_failure_stays_for_same_identity: bool = \
		String(failed_repeat.get("status", "")) == "failed" \
		and String(failed_repeat.get("reason", "")) == "fixture_terminal_band_failure" \
		and String(retained_terminal_job.get("reason", "")) == "fixture_terminal_band_failure" \
		and terminal_source_job_keys == retained_source_job_keys \
		and band_queue.ecology_tree_band_compile_jobs.size() == terminal_job_count
	var owner_batch_contributors: Array = artifact.get("ownerBatchContributors", [])
	var contributor_source_ids: Array[String] = []
	var contributor_part_ids: Array[String] = []
	var contributor_identity_set: Dictionary = {}
	var contributor_sources_match := not owner_batch_contributors.is_empty()
	for contributor_value: Variant in owner_batch_contributors:
		if not contributor_value is Array or contributor_value.size() != 2 \
				or not contributor_value[1] is Array \
				or contributor_value[1].size() < 2:
			contributor_sources_match = false
			continue
		var contributor_payload: Array = contributor_value[1]
		var contributor_source_id := String(contributor_payload[0])
		var contributor_part_id := String(contributor_payload[1])
		contributor_source_ids.append(contributor_source_id)
		contributor_part_ids.append(contributor_part_id)
		var contributor_identity := TreeRecipeSectionCompilerScript._source_part_identity_key(
			contributor_source_id, contributor_part_id)
		if contributor_source_id != source_id or contributor_part_id.is_empty() \
				or contributor_identity.is_empty() \
				or contributor_identity_set.has(contributor_identity):
			contributor_sources_match = false
		contributor_identity_set[contributor_identity] = true
	var ready_nonempty: bool = String(terminal.get("status", "")) == "ready" \
			and String(artifact.get("disposition", "")) == "complete_nonempty" \
			and artifact.get("sectionKey", null) == section_key \
			and artifact.get("expectedSourceIds", []) == [source_id] \
			and not artifact.get("batches", []).is_empty() \
			and contributor_sources_match \
			and String(artifact.get("authorityDigest", "")) \
				== String(authority.get("authorityDigest", ""))
	var result := {"captureStatus":capture.get("status", ""),
		"capturedTreeSourceCount":tree_rows.size(),
		"sourceRowIdentity":"%s/%s" % [family_row.get("producerFamily", ""),
			family_row.get("sourceId", "")],
		"requestCatalogMatchesAuthority":request_catalog_matches_authority,
		"supportProofStatus":captured_support_proof.get("status", ""),
		"supportProofReason":captured_support_proof.get("reason", ""),
		"supportPolicyStatus":support_policy.get("status", ""),
		"supportPolicyRevision":support_policy.get("revision", ""),
		"supportPolicyDigest":support_policy.get("digest", ""),
		"treeSupportPolicyStatus":tree_support_policy.get("status", ""),
		"treeSupportPolicyReason":tree_support_policy.get("reason", ""),
		"treeSupportMaxHorizontalMeters":tree_support_policy.get(
			"maxHorizontalSupportMeters", null),
		"treeSupportMaxVerticalMeters":tree_support_policy.get(
			"maxVerticalSupportMeters", null),
		"supportProofPolicyRevision":captured_support_proof.get(
			"influencePolicyRevision", ""),
		"supportProofPolicyDigest":captured_support_proof.get(
			"influencePolicyDigest", ""),
		"supportProofBounds":captured_support_proof.get("worldBounds", null),
		"certifiedRecipeBounds":source_bounds,
		"requestVisualHeight":normalized.get("visualHeight", null),
		"requestTrunkRadius":normalized.get("trunkRadius", null),
		"requestCanopyRadius":normalized.get("canopyRadius", null),
		"supportEnvelopeStatus":support_envelope.get("status", ""),
		"requestStatus":request_result.get("status", ""),
		"initialJobStatus":initial_job_status,
		"sourceRecordJobsBounded":source_record_jobs_bounded,
		"sourceRecordCompileStarts":band_queue.ecology_tree_source_record_compile_start_count,
		"sourceRecordCacheReuseCount":band_queue.ecology_tree_source_record_cache_reuse_count,
		"sourceRecordProjectionCount":band_queue.ecology_tree_source_band_projection_count,
		"terminalStatus":terminal.get("status", ""),
		"terminalReason":terminal.get("reason", ""),
		"artifactDisposition":artifact.get("disposition", ""),
		"artifactSourceIds":artifact.get("expectedSourceIds", []),
		"artifactBatchCount":artifact.get("batches", []).size(),
		"artifactOwnerContributorCount":artifact.get(
			"ownerBatchContributors", []).size(),
		"ownerContributorSourceIds":contributor_source_ids,
		"ownerContributorPartIds":contributor_part_ids,
		"ownerContributorsMatchExactSource":contributor_sources_match,
		"sourceCompletionDigestMatchesQueueAdmittedPayload": \
			completion_digest_matches_admitted_payload,
		"ownerBatchPayloadDigestMatchesQueueAdmittedPayload": \
			owner_payload_digest_matches_admitted_payload,
		"same_identity_reuses_terminal_band_failure":terminal_failure_stays_for_same_identity,
		"readyNonemptyArtifact":ready_nonempty}
	result["passed"] = capture.get("status", "") == "ready" \
		and request_catalog_matches_authority \
		and family_row.get("sourceId", "") == source_id \
		and String(support_policy.get("status", "")) == "ready" \
		and String(tree_support_policy.get("status", "")) == "bounded" \
		and String(captured_support_proof.get("status", "")) == "ready" \
		and String(request_result.get("status", "")) == "pending" \
		and String(request_result.get("reason", "")) == "tree_source_record_projection_waiting" \
		and initial_job_status in ["queued", "active"] \
		and source_record_jobs_bounded \
		and band_queue.ecology_tree_source_record_compile_start_count == 1 \
		and band_queue.ecology_tree_source_band_projection_count == 1 \
		and ready_nonempty \
		and completion_digest_matches_admitted_payload \
		and owner_payload_digest_matches_admitted_payload \
		and terminal_failure_stays_for_same_identity
	if String(terminal.get("status", "")) == "pending":
		band_queue.cancel_ecology_tree_source_band_compile(job_key, consumer)
	main.queue_free()
	return result


func _real_building_tree_identity_contract() -> void:
	var owner := RealTreeRuntimeOwner.new()
	owner.seed_text = "actual-building-tree-world"
	owner.seed_hash = owner.seed_text.hash()
	get_root().add_child(owner)
	owner.setup_biome_environment_catalog()
	var coordinator = load("res://scripts/world/WorldStaticSectionCoordinator.gd").new()
	coordinator.configure("seed:%s:%d" % [owner.seed_text, owner.seed_hash])
	owner.world_static_section_coordinator = coordinator
	var parent := Node3D.new()
	owner.add_child(parent)
	var records: Array = load("res://scripts/buildings/CitadelUrbanPocComposer.gd").build_tree_placement_records(
		[Vector3(8, 0, 6)], 72819)
	if records.is_empty():
		add_result("real_building_tree_identity", false, {"reason":"composer_empty"})
		owner.free()
		return
	var row: Dictionary = records[0]
	var original_request: Dictionary = row.treeRequest.duplicate(true)
	var durable_id := "site-tree:4:site:%d:%s" % [String(row.id).length(), row.id]
	var viewer := Node3D.new()
	owner.add_child(viewer)
	viewer.position = Vector3(1000, 0, 1000)
	owner.ensure_tree_publication_queue().set_viewer(viewer)
	var published: Dictionary = owner.make_tree_from_runtime_request(parent, durable_id,
		row.position, "town", row.treeRequest, row.rotationY)
	var body: StaticBody3D = published.get("body")
	var queue: Variant = owner.tree_publication_queue
	var captured: Dictionary = {}
	var proof: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 30000
	while is_instance_valid(body) and Time.get_ticks_msec() < deadline:
		await process_frame
		proof = queue.tree_publication_proof(body)
		if proof.get("installed", false) or proof.get("status") == "failed": break
	add_result("real_building_tree_native_impostor_proves_prepared_without_recipe_id_rewrite",
		proof.get("installed", false) and proof.get("sourcePrepared", false)
		and proof.get("representation") == "native_impostor"
		and row.treeRequest == original_request,
		{"proof":proof, "queue":queue.metrics()})
	var far_compile: Dictionary = queue.advance_tree_section_compiler()
	var far_capture: Dictionary = queue.capture_section_source(body, owner.seed_text)
	for frame in 300:
		if far_capture.get("status") == "ready": break
		await process_frame
		far_capture = queue.capture_section_source(body, owner.seed_text)
	add_result("real_building_tree_native_impostor_has_capturable_section_source",
		far_capture.get("status") == "ready",
		{"captureStatus":far_capture.get("status"), "captureReason":far_capture.get("reason"),
			"compilerAdmission":far_compile, "compiler":queue.startup_tree_section_compile_diagnostics(),
			"recipeInputTier":queue.tree_section_recipe_input_record_for_body(body).get("renderLodTier"),
			"installedProof":proof})
	var far_members: Array = far_capture.get("sourceManifest", {}).get("geometryOwnership", [])
	var far_projection_ready := not far_members.is_empty()
	var projected_instances := 0
	for section_key: Vector3i in far_capture.get("sourceManifest", {}).get("ownedSectionKeys", []):
		var projected: Dictionary = load("res://scripts/world/TreeSectionValueAdapter.gd").capture_compiled_contributor(
			far_capture, "citadel:site:member:tree:" + String(row.id), "census-far-r1", section_key)
		far_projection_ready = far_projection_ready and projected.get("status") == "ready"
		for input_row: Dictionary in projected.get("inputs", []): projected_instances += int(input_row.get("instanceCount", 0))
	var far_backend: Variant = body.get_meta("static_chunk_render_publisher", null)
	var far_snapshot: Dictionary = far_backend.installed_snapshot(body) if is_instance_valid(far_backend) else {}
	var actual_matches := 0
	var exact_meshes := true
	var bounds_policy := true
	var shader_lanes := true
	var draw_policy := true
	for batch: Dictionary in far_capture.get("compiledRecord", {}).get("compiled", {}).get("batches", []):
		var compatibility: Dictionary = batch.compatibilityKey
		bounds_policy = bounds_policy and String(batch.meshKey).contains("tree-impostor-planar-support/v1")
		draw_policy = draw_policy and not bool(compatibility.castShadows) \
			and is_equal_approx(float(compatibility.fadeMargin), minf(20.0, float(compatibility.visibilityRangeEnd) * 0.12))
		for member: Dictionary in batch.contributors.values():
			for lane in range(12, 16): shader_lanes = shader_lanes and member.instanceAttributes[lane] == 1.0
			for lane in range(16, 20): shader_lanes = shader_lanes and member.instanceAttributes[lane] == 0.0
			var world_transform: Transform3D = Transform3D(Basis.IDENTITY, batch.sectionOrigin) * load("res://scripts/world/StaticInstanceAttributeBuffer.gd").decode_transform(member.instanceAttributes, 0)
			var matched := false
			for index in far_snapshot.get("instanceTransforms", []).size():
				var installed_transform: Transform3D = far_snapshot.batchGlobalTransform * far_snapshot.instanceTransforms[index]
				if world_transform.is_equal_approx(installed_transform):
					matched = true
					var actual_mesh: Mesh = instance_from_id(far_snapshot.meshResourceIds[index]) as Mesh
					exact_meshes = exact_meshes and load("res://scripts/world/StaticRenderMeshFingerprint.gd").inspect(actual_mesh).get("contentDigest") == compatibility.meshContentDigest
					if index > 0: exact_meshes = exact_meshes and actual_mesh.get_aabb().size.z == 0.0
					break
			if matched: actual_matches += 1
	var original_transform: Transform3D = body.global_transform
	body.position.x += 0.25
	var stale_capture: Dictionary = queue.capture_section_source(body, owner.seed_text)
	body.global_transform = original_transform
	add_result("real_far_impostor_section_preserves_three_native_instances_and_planar_mesh",
		far_members.size() == 3 and actual_matches == 3 and exact_meshes and bounds_policy
		and far_projection_ready and projected_instances == 3 and shader_lanes and draw_policy,
		{"memberCount":far_members.size(), "matchedNativeTransforms":actual_matches, "exactMeshVertices":exact_meshes, "boundsPolicySealed":bounds_policy,
			"ownedSections":far_capture.get("sourceManifest", {}).get("ownedSectionKeys", []),
			"exactContributorProjectionReady":far_projection_ready, "projectedInstances":projected_instances,
			"legacyShaderLaneParity":shader_lanes, "shadowAndFadePolicyParity":draw_policy,
			"remainingRendererParity":"legacy extraCullMargin1m and native page-origin cull compensation are not explicit section compatibility fields"})
	add_result("real_far_impostor_retains_native_slot_until_ack_and_rejects_stale_body",
		far_snapshot.get("status") == "ready" and stale_capture.get("status") != "ready"
		and queue.capture_section_source(body, owner.seed_text).get("status") == "ready",
		{"slotStatus":far_snapshot.get("status"), "staleReason":stale_capture.get("reason")})
	if is_instance_valid(body): viewer.global_position = body.global_position + Vector3(3, 0, 0)
	deadline = Time.get_ticks_msec() + 30000
	while is_instance_valid(body) and Time.get_ticks_msec() < deadline:
		await process_frame
		proof = queue.tree_publication_proof(body, false)
		captured = queue.capture_section_source(body, owner.seed_text)
		if captured.get("status") == "ready" or proof.get("status") == "failed": break
	var contribution: Dictionary = {}
	var input: Dictionary = captured.get("input", {})
	var source_manifest: Dictionary = captured.get("sourceManifest", {})
	var sections: Array = source_manifest.get("ownedSectionKeys", [])
	if captured.get("status") == "ready" and not sections.is_empty():
		contribution = load("res://scripts/world/TreeSectionValueAdapter.gd").capture_compiled_contributor(
			captured, "citadel:site:member:tree:" + String(row.id), "census-tree-r1", sections[0])
	add_result("real_building_tree_keeps_durable_world_and_recipe_identity_separate",
		published.get("status") == "published" and proof.get("sourcePrepared", false)
		and captured.get("status") == "ready"
		and captured.get("producerSourceId") == owner.seed_text + ":tree:" + durable_id
		and input.get("propId") == durable_id and input.get("worldSeed") == owner.seed_text
		and input.get("request", {}).get("treeId") == original_request.treeId
		and input.get("request", {}).get("worldSeed") == original_request.worldSeed
		and row.treeRequest == original_request and contribution.get("status") == "ready",
		{"proof":proof, "captureStatus":captured.get("status"), "captureReason":captured.get("reason"),
			"sourceManifestKeys":source_manifest.keys(),
			"contributionStatus":contribution.get("status"), "contributionReason":contribution.get("reason"),
			"contributorInputCount":contribution.get("inputs", []).size(),
			"producerSourceId":captured.get("producerSourceId"),
			"compiler":queue.startup_tree_section_compile_diagnostics() if is_instance_valid(queue) else {}})
	if is_instance_valid(body): queue.cancel_body_publication(body)
	owner.free()


func _canonical_digest(value: Variant) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(value)) != OK:
		return ""
	return context.finish().hex_encode()
