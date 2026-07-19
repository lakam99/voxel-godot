extends SceneTree

const TreePublicationQueueScript := preload("res://scripts/environment/TreePublicationQueue.gd")
const TreeRecipeCacheScript := preload("res://scripts/environment/TreeRecipeCache.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")

var results: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("run_contract")

func run_contract() -> void:
	var fixture := Node3D.new()
	get_root().add_child(fixture)
	var queue = TreePublicationQueueScript.new()
	fixture.add_child(queue)
	# Main-world startup prewarms these immutable mesh/material resources while
	# the loading UI is active.  The queue contract measures the subsequent
	# gameplay publication slices, not one-time shader/resource creation.
	queue.publication_service.prewarm_visuals()
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
	var broadleaf := tree_body("queue-broadleaf")
	var conifer := tree_body("queue-conifer")
	fixture.add_child(broadleaf)
	fixture.add_child(conifer)
	var enqueue_started := Time.get_ticks_usec()
	var broadleaf_queued: bool = queue.enqueue(broadleaf, request_for("queue-broadleaf", "broadleaf", "bushy_oak", "forest"))
	var conifer_queued: bool = queue.enqueue(conifer, request_for("queue-conifer", "conifer", "norway_spruce", "taiga"))
	var enqueue_usec := Time.get_ticks_usec() - enqueue_started
	add_result("enqueue_returns_without_sync_recipe_generation", broadleaf_queued and conifer_queued and enqueue_usec < 5000, {"enqueueUsec": enqueue_usec})
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
	return {
		"treeId": id,
		"worldSeed": "queue-contract-world",
		"biome": biome,
		"architecture": architecture,
		"speciesGrammar": grammar,
		"growthStage": 0.80,
		"visualHeight": 20.0,
		"trunkRadius": 0.88,
		"canopyRadius": 8.0,
		"canopyDensity": 0.82,
		"presentation": "runtime"
	}

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
