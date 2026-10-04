extends Node
class_name TreePublicationQueue

## Converts pure mathematical recipes into tree visuals without spending a
## chunk/terrain frame on graph growth.  Tree placement, collision, drops,
## save IDs, and world RNG remain owned by the caller; this queue owns only
## deterministic recipe work and a bounded main-thread visual publication.

signal tree_visual_published(body: StaticBody3D, recipe: Dictionary)
signal tree_section_values_prepared(body: StaticBody3D)

const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const TreeRecipeCacheScript := preload("res://scripts/environment/TreeRecipeCache.gd")
const VisualFactoryScript := preload("res://scripts/visual/ProceduralTreeVisualFactory.gd")
const HorizonEcologyTreeBatchScript := preload("res://scripts/world/HorizonEcologyTreeBatch.gd")
const StaticRenderSectionGridScript := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const TREE_SECTION_RECIPE_INPUT_SCHEMA := "tree-section-recipe-input/v1"
const TREE_SECTION_RECIPE_COMPILER_REVISION := "tree-recipe-section-compiler/v1"
const MAX_ACTIVE_WORKERS := 2
# Each visual is assembled across small main-thread stages. This avoids
# treating a dense tree as one indivisible frame of work while keeping a body
# pending until its full visual can be committed atomically.
## Publication work always yields after one renderer-backed tree stage.  The
## individual stages are profiled and bounded, but pairing two "cheap" stages
## still produced an avoidable multi-millisecond aggregate in a real traversal.
const MAX_PUBLICATION_WORK_UNITS_PER_FRAME := 1
# A queue frame yields as soon as its measured main-thread budget is consumed.
## The time budget remains a guard for invalid/cancelled task cleanup; the one
## stage limit is the stronger hitch-prevention invariant for live rendering.
const MAX_PUBLICATION_WORK_USEC_PER_FRAME := 720
# A stage may vary between a cheap cursor advance and a renderer-backed commit.
# Reserve the measured high-water cost of the next stage before beginning it;
# otherwise four individually bounded slices can still become one multi-ms
# gameplay frame. The first observation of each stage deliberately runs alone.
const PUBLICATION_STAGE_SAFETY_MARGIN_USEC := 96
# Each MultiMesh write still crosses the renderer boundary.  Keep leaf batches
# deliberately smaller than branch batches: foliage is denser and was the only
# staged phase able to exceed the one-millisecond gameplay budget on a headed
# run.
# Distal branches carry a full transform plus variation data. Keep their
# renderer upload below the live max-stage gate; this is a publication cadence
# limit only and does not simplify, cull, or otherwise alter the finished tree.
const MAX_DISTAL_INSTANCES_PER_SLICE := 24
# A foliage transform writes both a renderer transform and custom wind data.
# Keep this smaller than branch batches so dense near crowns cannot turn one
# publication slice into a visible stream-in hitch. It changes only when the
# already-computed canopy appears, never the final recipe or leaf density.
const MAX_FOLIAGE_INSTANCES_PER_SLICE := 16
const PUBLICATION_TIMING_SAMPLE_LIMIT := 240
# Render accounting is derived from the canonical recipe, not by reading a
# mesh back from the renderer during publication.  These fixed primitive
# budgets mirror ProceduralTreeVisualFactory's runtime geometry: a 4-sided
# continuous bole tube, the 8-sided/5-ring shared twig cylinder, and the
# 56-card dense runtime foliage cluster. They are deliberately estimates; draw
# calls and instance counts remain exact publication facts.
const ESTIMATED_RUNTIME_BOLE_TRIANGLES_PER_SEGMENT := 14
const ESTIMATED_SHARED_BRANCH_TRIANGLES := 96
const ESTIMATED_RUNTIME_FOLIAGE_CLUSTER_TRIANGLES := 112
const ESTIMATED_IMPOSTOR_TRIANGLES := 100
# Visual publication is intentionally viewer-facing: a fully assembled nearby
# canopy is more useful than a distant one whose body already owns collision.
# Age reduces effective distance without collapsing every long-waiting task
# to zero. The oldest non-local request still competes with one local request.
const PUBLICATION_PRIORITY_AGE_SCALE_SECONDS := 20.0
const MAX_LOD_REEVALUATIONS_PER_FRAME := 6
# Completed recipes can arrive in a burst after a chunk stream-in or recipe
# cache hit.  Priority selection must stay local to the player rather than
# re-scanning every completed graph before each renderer slice.
const COMPLETED_PRIORITY_CELL_SIZE := 24.0
const COMPLETED_PRIORITY_LOCAL_CELL_RADIUS := 2
const COMPLETED_UNPLACED_CELL := Vector2i(999999999, 999999999)
# Directional readiness changes only the order in which the already eligible
# queue receives work.  It never changes chunk retention, prop placement, or
# a tree's immutable recipe.  The values deliberately describe a short sprint
# horizon rather than a second streaming radius.
const VIEWER_MOTION_MIN_SPEED := 0.75
const VIEWER_MOTION_LOOKAHEAD_SECONDS := 1.35
const VIEWER_MOTION_MAX_LOOKAHEAD_DISTANCE := 28.0
const VIEWER_MOTION_CAMERA_WEIGHT := 0.32
const FORWARD_CORRIDOR_MIN_HALF_WIDTH := 4.0
const FORWARD_CORRIDOR_MAX_HALF_WIDTH := 14.0
const FORWARD_CORRIDOR_LATERAL_WEIGHT := 1.45
const BACKWARD_PRIORITY_PENALTY := 0.42
const MAX_DIRECTIONAL_PRIORITY_CELLS := 3
# Trees retain their authoritative trunk collision.  This distance is only a
# visual-readiness horizon: at sprint speed it gives the bounded queue more
# than a second to replace the shared silhouette with the full recipe.
const COLLISION_VISIBILITY_PROXY_DISTANCE := 28.0
const MAX_COLLISION_VISIBILITY_PROXIES_PER_FRAME := 2

# Pending recipes use an indexed priority queue rather than sorting and
# shifting the entire stream-in backlog whenever a worker becomes free.  The
# graph work is still deterministic; only worker launch order follows the
# current viewer so a local tree does not wait behind a distant horizon.
var pending_tasks := {}
var pending_order: Array[int] = []
var pending_order_head := 0
var pending_spatial_buckets := {}
var active: Array[Dictionary] = []
var completed: Array[Dictionary] = []
# Completed entries are tombstoned when consumed, so buckets can retain stable
# indices without shifting large recipe dictionaries.  The moving head is used
# only for the oldest-task fairness fallback.
var completed_head := 0
var completed_count := 0
var completed_spatial_buckets := {}
var staged_publication_task: Dictionary = {}
var publication_service = TreeSpawnServiceScript.new()
var recipe_cache = TreeRecipeCacheScript.new()
var viewer: WeakRef
var viewer_motion_snapshot := {}
var external_viewer_motion_snapshot := {}
var external_viewer_motion_expires_usec := 0
var published_lod_records: Array[Dictionary] = []
## Prepared members are handed to the section owner before per-tree attachment.
## The records are immutable values; the parallel acknowledgement map is owned
## by this queue and tracks section receipts without mutating captured inputs.
var prepared_section_value_records: Array[Dictionary] = []
var prepared_section_acknowledgements := {}
var prepared_section_generation := 0
## Recipe inputs are sealed as soon as deterministic worker output arrives,
## before the legacy per-tree visual stages. The section compiler may consume
## these values without waiting for GeneratedTreeVisual construction.
var section_recipe_input_records: Array[Dictionary] = []
var section_recipe_input_generation := 0
var section_owned_publication_enabled := false
var lod_recheck_cursor := 0
## Render accounting is updated only at publish/retier/removal boundaries.  It
## deliberately never walks the live forest during a gameplay frame merely to
## produce telemetry.
var published_render_stats := {}
var published_render_totals := {
	"visibleTrees": 0,
	"branchInstances": 0,
	"foliageInstances": 0,
	"estimatedDrawCalls": 0,
	"estimatedTriangles": 0,
	"estimatedShadowTriangles": 0,
	"lodDistribution": {"near": 0, "mid": 0, "far": 0, "impostor": 0}
}
var queued_count := 0
var published_count := 0
var dropped_count := 0
var cancelled_count := 0
var failed_count := 0
var recipe_cache_reused_count := 0
var lod_recipe_derivation_requested_count := 0
var lod_recipe_derivation_completed_count := 0
var lod_rebuild_count := 0
var priority_scheduled_count := 0
var preempted_publication_count := 0
var priority_selection_count := 0
var priority_selection_candidate_total := 0
var priority_selection_max_candidates := 0
var priority_selection_full_fallback_count := 0
var priority_selection_viewless_fifo_count := 0
var priority_selection_samples_usec: Array[int] = []
var priority_selection_sample_cursor := 0
var local_selection_candidate_count := 0
var local_selection_score := INF
var worker_priority_selection_count := 0
var worker_priority_selection_candidate_total := 0
var worker_priority_selection_max_candidates := 0
var worker_priority_selection_full_fallback_count := 0
var worker_priority_selection_samples_usec: Array[int] = []
var worker_priority_selection_sample_cursor := 0
var worker_local_selection_candidate_count := 0
var worker_local_selection_score := INF
var enqueue_sequence := 0
var directional_worker_selection_count := 0
var directional_publication_selection_count := 0
var directional_preemption_count := 0
var viewer_heading_confident_frame_count := 0
var viewer_heading_fallback_frame_count := 0
var collision_visibility_proxy_attach_count := 0
var collision_visibility_proxy_release_count := 0
var collision_visibility_proxy_active_count := 0
var collision_visibility_proxy_peak_count := 0
var collision_visibility_proxy_lifetime_total_usec := 0
var collision_visibility_proxy_lifetime_max_usec := 0
var collision_to_first_visible_total_lag_usec := 0
var collision_to_first_visible_max_lag_usec := 0
var collision_to_first_visible_count := 0
var collision_before_visual_invariant_breach_count := 0
var publication_work_samples_usec: Array[int] = []
var publication_frame_samples_usec: Array[int] = []
var publication_scheduler_samples_usec: Array[int] = []
var publication_validation_samples_usec: Array[int] = []
var publication_bookkeeping_samples_usec: Array[int] = []
## Keep the measurement mechanism honest. In a real traversal the aggregate
## queue frame exceeded the sum of its previously reported renderer/scheduler
## stages, so report the accounting cost and remaining gap separately before
## changing any publication policy.
var publication_reporting_samples_usec: Array[int] = []
var publication_unattributed_samples_usec: Array[int] = []
var publication_loop_tail_samples_usec: Array[int] = []
var publication_work_sample_cursor := 0
var publication_frame_sample_cursor := 0
var publication_scheduler_sample_cursor := 0
var publication_validation_sample_cursor := 0
var publication_bookkeeping_sample_cursor := 0
var publication_reporting_sample_cursor := 0
var publication_unattributed_sample_cursor := 0
var publication_loop_tail_sample_cursor := 0
var publication_stage_counts := {"root": 0, "bole": 0, "distal": 0, "foliage": 0, "commit": 0}
var publication_stage_samples_usec := {"root": [], "bole": [], "distal": [], "foliage": [], "commit": []}
var publication_stage_sample_cursors := {"root": 0, "bole": 0, "distal": 0, "foliage": 0, "commit": 0}
var publication_stage_estimates_usec := {"root": MAX_PUBLICATION_WORK_USEC_PER_FRAME, "bole": MAX_PUBLICATION_WORK_USEC_PER_FRAME, "distal": MAX_PUBLICATION_WORK_USEC_PER_FRAME, "foliage": MAX_PUBLICATION_WORK_USEC_PER_FRAME, "commit": MAX_PUBLICATION_WORK_USEC_PER_FRAME}
var worst_publication_frame := {
	"elapsedUsec": 0,
	"stage": "",
	"schedulerUsec": 0,
	"validationUsec": 0,
	"stageUsec": 0,
	"reportingUsec": 0,
	"unattributedUsec": 0,
	"loopTailUsec": 0,
	"completedBefore": 0,
	"pending": 0
}

func enqueue(body: StaticBody3D, request: Dictionary) -> bool:
	if body == null or not is_instance_valid(body) or body.is_queued_for_deletion() or request.is_empty():
		return false
	if bool(body.get_meta("tree_publication_cancelled", false)): return false
	var prepared_request := request.duplicate(true)
	prepared_request["renderLodTier"] = selected_lod_tier(prepared_request)
	var recipe_key := publication_service.recipe_cache_key(prepared_request)
	var recipe_identity_key := publication_service.recipe_identity_key(prepared_request)
	enqueue_sequence += 1
	var priority := maxf(0.0, float(prepared_request.get("publicationPriority", INF)))
	if is_finite(priority):
		priority_scheduled_count += 1
	var task := {
		"body": weakref(body),
		# Tree props are static for the life of this queued visual. Cache the
		# immutable world position so priority selection never dereferences scene
		# nodes in its hot loop.
		"publicationPosition": body.global_position if _is_live_node(body) else prepared_request.get("treeWorldPosition", null),
		"request": prepared_request,
		"recipeCacheKey": recipe_key,
		"recipeIdentityKey": recipe_identity_key,
		"enqueuedUsec": Time.get_ticks_usec(),
		"publicationPriority": priority,
		"enqueueSequence": enqueue_sequence,
		"sectionValueMembers": []
	}
	body.set_meta("tree_section_recipe_input_expected_generation", enqueue_sequence)
	# The trunk collision is already owned by the gameplay prop before this
	# presentation queue is called.  Record that boundary once, then make a
	# nearby blocker visible immediately with shared geometry while its full
	# mathematical recipe remains worker/queue owned.
	var horizon_only := body.get_parent() != null \
		and bool(body.get_parent().get_meta("horizon_visual_only", false))
	if not horizon_only:
		if not body.has_meta("tree_collision_ready_usec"):
			body.set_meta("tree_collision_ready_usec", Time.get_ticks_usec())
		ensure_collision_visible_representation(body, prepared_request, "enqueue")
	ensure_horizon_visible_representation(body, prepared_request)
	queued_count += 1
	var cached_recipe: Dictionary = recipe_cache.fetch(recipe_key)
	if not cached_recipe.is_empty():
		task["recipe"] = cached_recipe
		enqueue_completed_task(task)
		recipe_cache_reused_count += 1
		body.set_meta("tree_visual_state", "recipe_cached")
		return true
	var lod_source_recipe: Dictionary = recipe_cache.fetch_compatible_lod_source(
		recipe_identity_key,
		String(prepared_request.get("renderLodTier", "near"))
	)
	if not lod_source_recipe.is_empty():
		task["lodSourceRecipe"] = lod_source_recipe
		lod_recipe_derivation_requested_count += 1
		body.set_meta("tree_visual_state", "recipe_lod_derivation_queued")
	enqueue_pending_task(task)
	if not task.has("lodSourceRecipe"):
		body.set_meta("tree_visual_state", "queued")
	return true

## Cancel this exact scene instance without harvesting it or waiting for recipe
## workers on the gameplay thread. All queued/LOD/proxy consumers resolve the
## same instance flag; a fresh same-ID tree remains independently publishable.
func cancel_body_publication(body: StaticBody3D) -> Dictionary:
	if not is_instance_valid(body): return {"status":"failed", "reason":"invalid_tree"}
	body.set_meta("tree_publication_cancelled", true)
	_remove_tree_section_recipe_input_record_for_body(body)
	release_horizon_visible_representation(body)
	return {"status":"cancelled", "bodyInstanceId":body.get_instance_id()}

func _publication_body(record: Dictionary) -> StaticBody3D:
	var reference: WeakRef = record.get("body") as WeakRef
	var body: StaticBody3D = reference.get_ref() as StaticBody3D if reference != null else null
	if is_instance_valid(body) and not body.is_queued_for_deletion() and not bool(body.get_meta("tree_publication_cancelled", false)): return body
	return null

## Detached bodies still own retryable preparation. Only scene queries and
## distance-based presentation require live membership; never treat detachment
## as cancellation of the recipe or its partially assembled visual.
func _is_live_node(node: Node3D) -> bool:
	return is_instance_valid(node) and node.is_inside_tree() and not node.is_queued_for_deletion()

func _live_viewer() -> Node3D:
	var node: Node3D = viewer.get_ref() as Node3D if viewer != null else null
	return node if _is_live_node(node) else null

func set_viewer(node: Node3D) -> void:
	viewer = weakref(node) if node != null and is_instance_valid(node) else null
	if viewer == null:
		viewer_motion_snapshot.clear()

## An owning game loop or focused contract can supply one already-sampled
## motion snapshot for the current frame.  It is presentation-only: no raw
## input or frame timing can influence the generated tree itself.
func set_viewer_motion_snapshot(position: Vector3, planar_velocity: Vector3, camera_forward: Vector3) -> void:
	external_viewer_motion_snapshot = make_viewer_motion_snapshot(position, planar_velocity, camera_forward)
	external_viewer_motion_expires_usec = Time.get_ticks_usec() + 100000
	viewer_motion_snapshot = external_viewer_motion_snapshot.duplicate(true)

func make_viewer_motion_snapshot(position: Vector3, planar_velocity: Vector3, camera_forward: Vector3) -> Dictionary:
	var planar_velocity_flat := Vector3(planar_velocity.x, 0.0, planar_velocity.z)
	var planar_camera_forward := Vector3(camera_forward.x, 0.0, camera_forward.z)
	var speed := planar_velocity_flat.length()
	if planar_camera_forward.length_squared() > 0.0001:
		planar_camera_forward = planar_camera_forward.normalized()
	var velocity_heading := planar_velocity_flat.normalized() if speed >= VIEWER_MOTION_MIN_SPEED else Vector3.ZERO
	var blended_heading := velocity_heading
	if velocity_heading.length_squared() > 0.0001 and planar_camera_forward.length_squared() > 0.0001:
		blended_heading = (velocity_heading * (1.0 - VIEWER_MOTION_CAMERA_WEIGHT) + planar_camera_forward * VIEWER_MOTION_CAMERA_WEIGHT).normalized()
	elif planar_camera_forward.length_squared() > 0.0001 and speed >= VIEWER_MOTION_MIN_SPEED:
		blended_heading = planar_camera_forward
	var confident := speed >= VIEWER_MOTION_MIN_SPEED and blended_heading.length_squared() > 0.0001
	var lookahead_distance := minf(VIEWER_MOTION_MAX_LOOKAHEAD_DISTANCE, speed * VIEWER_MOTION_LOOKAHEAD_SECONDS) if confident else 0.0
	return {
		"position": position,
		"planarVelocity": planar_velocity_flat,
		"cameraForward": planar_camera_forward,
		"heading": blended_heading,
		"speed": speed,
		"confident": confident,
		"lookaheadDistance": lookahead_distance,
		"predictedPosition": position + blended_heading * lookahead_distance
	}

func refresh_viewer_motion_snapshot() -> void:
	if viewer != null and _live_viewer() == null:
		viewer_motion_snapshot.clear()
		external_viewer_motion_snapshot.clear()
		return
	if not external_viewer_motion_snapshot.is_empty() and Time.get_ticks_usec() <= external_viewer_motion_expires_usec:
		viewer_motion_snapshot = external_viewer_motion_snapshot.duplicate(true)
	else:
		var viewer_node: Node3D = _live_viewer()
		if viewer_node == null or not is_instance_valid(viewer_node):
			viewer_motion_snapshot.clear()
		else:
			var velocity_value = viewer_node.get("velocity")
			var planar_velocity := velocity_value as Vector3 if velocity_value is Vector3 else Vector3.ZERO
			var camera_forward := -viewer_node.global_transform.basis.z
			var camera_value = viewer_node.get("camera")
			if camera_value is Camera3D and _is_live_node(camera_value as Camera3D):
				camera_forward = -(camera_value as Camera3D).global_transform.basis.z
			viewer_motion_snapshot = make_viewer_motion_snapshot(viewer_node.global_position, planar_velocity, camera_forward)
	if bool(viewer_motion_snapshot.get("confident", false)):
		viewer_heading_confident_frame_count += 1
	else:
		viewer_heading_fallback_frame_count += 1

func viewer_motion_for_position(viewer_position: Vector3) -> Dictionary:
	if viewer_motion_snapshot.is_empty() or not bool(viewer_motion_snapshot.get("confident", false)):
		return {}
	var snapshot_position = viewer_motion_snapshot.get("position", Vector3.INF)
	if snapshot_position is not Vector3 or (snapshot_position as Vector3).distance_squared_to(viewer_position) > 0.25:
		return {}
	return viewer_motion_snapshot

func current_viewer_position() -> Vector3:
	if viewer != null and _live_viewer() == null:
		return Vector3.INF
	var snapshot_position = viewer_motion_snapshot.get("position", null)
	if snapshot_position is Vector3:
		return snapshot_position as Vector3
	var viewer_node: Node3D = _live_viewer()
	return viewer_node.global_position if viewer_node != null and is_instance_valid(viewer_node) else Vector3.INF

func body_is_collision_visible(body: StaticBody3D) -> bool:
	if not _is_live_node(body):
		return false
	if body.get_node_or_null("GeneratedTreeVisual") != null \
			or body.get_node_or_null("TreeVisibilityProxy") != null:
		return true
	for key in [HorizonEcologyTreeBatchScript.PUBLISHER_META, "static_chunk_render_publisher"]:
		if not body.has_meta(key):
			continue
		var publisher := body.get_meta(key) as Object
		if is_instance_valid(publisher) and publisher.has_method("installed_snapshot") \
				and String((publisher.call("installed_snapshot", body) as Dictionary).get("status", "")) == "ready":
			return true
	return false

## The horizon silhouette is installed on the same generated candidate through
## a chunk-owned MultiMesh slot. It does not change collision, recipe, or LOD
## authority and is never a near-detail receipt.
func ensure_horizon_visible_representation(body: StaticBody3D, request: Dictionary) -> bool:
	if not _is_live_node(body) or body.get_node_or_null("GeneratedTreeVisual") != null \
			or body.get_node_or_null("TreeVisibilityProxy") != null:
		return false
	var visual_factory: ProceduralTreeVisualFactory = publication_service.get_visual_factory()
	if visual_factory.is_headless_renderer():
		return false
	var parent := body.get_parent() as Node3D
	if parent == null or not _is_live_node(parent):
		return false
	var batch := parent.get_node_or_null("HorizonEcologyTreeBatch") as Node3D
	if batch == null:
		batch = HorizonEcologyTreeBatchScript.new()
		batch.name = "HorizonEcologyTreeBatch"
		parent.add_child(batch)
		batch.call("configure", parent, visual_factory)
	if not batch.has_method("add_tree"):
		return false
	return bool(batch.call("add_tree", body, request))


func publish_chunk_owned_impostor(body: StaticBody3D, request: Dictionary,
		recipe: Dictionary) -> bool:
	if not _is_live_node(body):
		return false
	var parent := body.get_parent() as Node3D
	if parent == null or not _is_live_node(parent):
		return false
	var visual_factory: ProceduralTreeVisualFactory = publication_service.get_visual_factory()
	if visual_factory.is_headless_renderer():
		return false
	if not ClassDB.class_exists("ChunkStaticRenderBackend"):
		return false
	var backend := parent.get_node_or_null("ChunkStaticRenderBackend") as Node3D
	if backend == null:
		backend = ClassDB.instantiate("ChunkStaticRenderBackend") as Node3D
		if backend == null:
			return false
		backend.name = "ChunkStaticRenderBackend"
		parent.add_child(backend)
	var architecture := String(request.get("architecture", "broadleaf"))
	var biome := String(request.get("biome", "forest"))
	var result: Dictionary = backend.call("publish_tree_impostor", body, request, recipe,
		visual_factory.runtime_shared_branch_mesh(), visual_factory.runtime_shared_impostor_crown_mesh(),
		visual_factory.branch_material(architecture, biome), visual_factory.foliage_material(architecture, biome))
	if String(result.get("status", "")) != "ready":
		return false
	# Retire the temporary GDScript horizon placeholder only after the native
	# chunk page has a validated slot for this exact gameplay body.
	release_horizon_visible_representation(body)
	return true

func release_horizon_visible_representation(body: StaticBody3D) -> void:
	if not is_instance_valid(body) or not body.has_meta(HorizonEcologyTreeBatchScript.PUBLISHER_META):
		return
	var batch := body.get_meta(HorizonEcologyTreeBatchScript.PUBLISHER_META) as Node3D
	if is_instance_valid(batch) and batch.has_method("release_tree"):
		batch.call("release_tree", body)

func release_chunk_static_visual(body: StaticBody3D) -> void:
	if not is_instance_valid(body) or not body.has_meta("static_chunk_render_publisher"):
		return
	var publisher := body.get_meta("static_chunk_render_publisher") as Object
	if is_instance_valid(publisher) and publisher.has_method("release_tree"):
		publisher.call("release_tree", body)

func body_is_collision_visibility_relevant(body: StaticBody3D) -> bool:
	if not _is_live_node(body) or bool(body.get_meta("tree_publication_cancelled", false)):
		return false
	if body.get_parent() != null \
			and bool(body.get_parent().get_meta("horizon_visual_only", false)):
		return false
	var viewer_position := current_viewer_position()
	if viewer_position == Vector3.INF:
		return false
	var horizontal_delta := Vector2(body.global_position.x - viewer_position.x, body.global_position.z - viewer_position.z)
	return horizontal_delta.length_squared() <= COLLISION_VISIBILITY_PROXY_DISTANCE * COLLISION_VISIBILITY_PROXY_DISTANCE

func record_first_collision_visible(body: StaticBody3D, source: String) -> void:
	if not _is_live_node(body) or body.has_meta("tree_first_visual_ready_usec"):
		return
	if not body.has_meta("tree_collision_visibility_relevant_usec"):
		return
	var now_usec := Time.get_ticks_usec()
	var collision_relevant_usec := int(body.get_meta("tree_collision_visibility_relevant_usec", now_usec))
	var lag_usec := maxi(0, now_usec - collision_relevant_usec)
	body.set_meta("tree_first_visual_ready_usec", now_usec)
	body.set_meta("tree_relevant_collision_to_first_visual_lag_usec", lag_usec)
	body.set_meta("tree_first_visual_source", source)
	collision_to_first_visible_count += 1
	collision_to_first_visible_total_lag_usec += lag_usec
	collision_to_first_visible_max_lag_usec = maxi(collision_to_first_visible_max_lag_usec, lag_usec)

func ensure_collision_visible_representation(body: StaticBody3D, request: Dictionary, reason: String) -> bool:
	if body == null or not is_instance_valid(body):
		return false
	if not body_is_collision_visibility_relevant(body):
		return false
	if not body.has_meta("tree_collision_visibility_relevant_usec"):
		body.set_meta("tree_collision_visibility_relevant_usec", Time.get_ticks_usec())
	if body_is_collision_visible(body):
		record_first_collision_visible(body, "already_published_or_proxied")
		return false
	var visual_factory = publication_service.get_visual_factory()
	var proxy: Node3D = visual_factory.instantiate_collision_visibility_proxy(request, String(request.get("biome", "forest"))) as Node3D
	if proxy == null:
		if not bool(body.get_meta("tree_collision_before_visual_breach_recorded", false)):
			body.set_meta("tree_collision_before_visual_breach_recorded", true)
			collision_before_visual_invariant_breach_count += 1
		return false
	proxy.name = "TreeVisibilityProxy"
	proxy.set_meta("tree_visibility_proxy_reason", reason)
	proxy.set_meta("tree_visibility_proxy_attached_usec", Time.get_ticks_usec())
	body.add_child(proxy)
	# The near collision silhouette is now visible. Retire the horizon batch
	# slot only after attaching it, so approach never creates a blank interval.
	release_horizon_visible_representation(body)
	body.set_meta("tree_visibility_proxy", true)
	body.set_meta("tree_visibility_proxy_reason", reason)
	body.set_meta("tree_visibility_proxy_attached_usec", int(proxy.get_meta("tree_visibility_proxy_attached_usec", 0)))
	record_first_collision_visible(body, "shared_visibility_proxy")
	collision_visibility_proxy_attach_count += 1
	collision_visibility_proxy_active_count += 1
	collision_visibility_proxy_peak_count = maxi(collision_visibility_proxy_peak_count, collision_visibility_proxy_active_count)
	return true

func release_collision_visibility_proxy(body: StaticBody3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	var proxy := body.get_node_or_null("TreeVisibilityProxy") as Node3D
	if proxy == null or not is_instance_valid(proxy):
		return
	var now_usec := Time.get_ticks_usec()
	var attached_usec := int(proxy.get_meta("tree_visibility_proxy_attached_usec", now_usec))
	var lifetime_usec := maxi(0, now_usec - attached_usec)
	body.remove_child(proxy)
	proxy.queue_free()
	body.remove_meta("tree_visibility_proxy")
	body.remove_meta("tree_visibility_proxy_reason")
	body.remove_meta("tree_visibility_proxy_attached_usec")
	collision_visibility_proxy_release_count += 1
	collision_visibility_proxy_active_count = maxi(0, collision_visibility_proxy_active_count - 1)
	collision_visibility_proxy_lifetime_total_usec += lifetime_usec
	collision_visibility_proxy_lifetime_max_usec = maxi(collision_visibility_proxy_lifetime_max_usec, lifetime_usec)

func refresh_collision_visibility_proxies() -> void:
	if current_viewer_position() == Vector3.INF:
		return
	var remaining := MAX_COLLISION_VISIBILITY_PROXIES_PER_FRAME
	# Active workers and a detached publication task are few by construction.
	for task in active:
		if remaining <= 0:
			return
		var body: StaticBody3D = _publication_body(task)
		if body != null and ensure_collision_visible_representation(body, task.get("request", {}), "proximity_guard"):
			remaining -= 1
	if not staged_publication_task.is_empty() and remaining > 0:
		var staged_body: StaticBody3D = _publication_body(staged_publication_task)
		if staged_body != null and ensure_collision_visible_representation(staged_body, staged_publication_task.get("request", {}), "proximity_guard"):
			remaining -= 1
	if remaining <= 0:
		return
	var viewer_position := current_viewer_position()
	var center_cell := completed_priority_cell(viewer_position)
	# Inspect only the already local spatial buckets.  This is a collision safety
	# net, not a global scan of a streamed horizon backlog.
	for radius in range(COMPLETED_PRIORITY_LOCAL_CELL_RADIUS + 1):
		for z_offset in range(-radius, radius + 1):
			for x_offset in range(-radius, radius + 1):
				if radius > 0 and abs(x_offset) != radius and abs(z_offset) != radius:
					continue
				var bucket_key := completed_bucket_key_for_cell(Vector2i(center_cell.x + x_offset, center_cell.y + z_offset))
				for bucket_kind in ["pending", "completed"]:
					var bucket_map: Dictionary = pending_spatial_buckets if bucket_kind == "pending" else completed_spatial_buckets
					var entries = bucket_map.get(bucket_key, [])
					if entries is not Array:
						continue
					for entry in entries as Array:
						if remaining <= 0:
							return
						var task: Dictionary = pending_tasks.get(int(entry), {}) if bucket_kind == "pending" else (completed[int(entry)] if int(entry) >= 0 and int(entry) < completed.size() else {})
						if task.is_empty():
							continue
						var body: StaticBody3D = _publication_body(task)
						if body != null and ensure_collision_visible_representation(body, task.get("request", {}), "proximity_guard"):
							remaining -= 1

func selected_lod_tier(request: Dictionary, current_tier := "") -> String:
	var viewer_node: Node3D = _live_viewer()
	if viewer_node != null and is_instance_valid(viewer_node):
		var position_value = request.get("treeWorldPosition", null)
		if position_value is Vector3:
			return publication_service.lod_tier_for_distance(request, viewer_node.global_position.distance_to(position_value as Vector3), current_tier)
	var priority := float(request.get("publicationPriority", INF))
	if is_finite(priority):
		return publication_service.lod_tier_for_distance(request, sqrt(maxf(0.0, priority)), current_tier)
	# Service/PoC callers without a live player intentionally retain the full
	# recipe for inspection. Runtime chunk callers always provide a priority.
	return publication_service.lod_tier_for_distance(request, 0.0, current_tier)

func refresh_published_lods() -> void:
	if viewer == null or published_lod_records.is_empty():
		return
	var viewer_node: Node3D = _live_viewer()
	if viewer_node == null or not is_instance_valid(viewer_node):
		return
	var checks := mini(MAX_LOD_REEVALUATIONS_PER_FRAME, published_lod_records.size())
	for _index in range(checks):
		if published_lod_records.is_empty():
			return
		lod_recheck_cursor = posmod(lod_recheck_cursor, published_lod_records.size())
		var record_index := lod_recheck_cursor
		var record: Dictionary = published_lod_records[record_index]
		var body: StaticBody3D = _publication_body(record)
		if body == null or not is_instance_valid(body):
			remove_published_render_stats(int(record.get("bodyInstanceId", 0)))
			published_lod_records.remove_at(lod_recheck_cursor)
			continue
		lod_recheck_cursor = posmod(record_index + 1, published_lod_records.size())
		if not _is_live_node(body):
			continue
		if bool(record.get("rebuildPending", false)):
			continue
		var request: Dictionary = (record.get("request", {}) as Dictionary).duplicate(true)
		request["treeWorldPosition"] = body.global_position
		var current_tier := String(record.get("tier", "near"))
		var desired_tier := selected_lod_tier(request, current_tier)
		if desired_tier == current_tier:
			continue
		record["rebuildPending"] = true
		published_lod_records[record_index] = record
		request["renderLodTier"] = desired_tier
		request["publicationPriority"] = body.global_position.distance_squared_to(viewer_node.global_position)
		if enqueue(body, request):
			lod_rebuild_count += 1
		else:
			record["rebuildPending"] = false
			published_lod_records[record_index] = record

func remember_published_lod(body: StaticBody3D, request: Dictionary,
		section_value_members: Array = [], recipe_snapshot: Dictionary = {},
		section_owned := false) -> void:
	var record := {
		"body": weakref(body),
		"bodyInstanceId": body.get_instance_id(),
		"request": request.duplicate(true),
		"tier": String(request.get("renderLodTier", "near")),
		"rebuildPending": false,
		"sectionOwned":section_owned,
		"sectionValueMembers": _freeze_section_value(section_value_members),
		"recipeSnapshot": _freeze_section_value(recipe_snapshot),
		"recipeSignature":String(recipe_snapshot.get("signature", ""))
	}
	for index in range(published_lod_records.size()):
		var existing: Dictionary = published_lod_records[index]
		var existing_body: StaticBody3D = _publication_body(existing)
		if existing_body == body:
			published_lod_records[index] = record
			return
	published_lod_records.append(record)


func set_section_owned_publication_enabled(enabled: bool) -> void:
	section_owned_publication_enabled = enabled


func prepared_section_value_record_for_body(body: StaticBody3D) -> Dictionary:
	if not is_instance_valid(body):
		return {}
	for record_value: Variant in prepared_section_value_records:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		var body_ref := record.get("body") as WeakRef
		if body_ref != null and body_ref.get_ref() == body \
				and int(record.get("bodyInstanceId", 0)) == body.get_instance_id():
			return record
	return {}


func build_tree_section_recipe_input_record(task: Dictionary, body: StaticBody3D,
		recipe: Dictionary) -> Dictionary:
	var request_value: Variant = task.get("request", null)
	if not is_instance_valid(body) or body.is_queued_for_deletion() \
			or bool(body.get_meta("tree_publication_cancelled", false)) \
			or not request_value is Dictionary or request_value.is_empty() or recipe.is_empty():
		return {"status":"pending", "reason":"tree_section_recipe_input_authority_missing"}
	var request: Dictionary = request_value
	var prop_id := String(request.get("treeId", ""))
	var seed := String(request.get("worldSeed", ""))
	var tier := String(request.get("renderLodTier", ""))
	var position_value: Variant = request.get("treeWorldPosition", null)
	var transform := body.global_transform
	if prop_id.is_empty() or seed.is_empty() or tier.is_empty() \
			or String(body.get_meta("prop_id", "")) != prop_id \
			or not position_value is Vector3 or not (position_value as Vector3).is_finite() \
			or not (position_value as Vector3).is_equal_approx(body.global_position) \
			or not transform.is_finite():
		return {"status":"pending", "reason":"tree_section_recipe_input_identity_stale"}
	var normalized_value: Variant = publication_service.normalize_request(request)
	if not normalized_value is Dictionary or normalized_value.is_empty():
		return {"status":"pending", "reason":"tree_section_recipe_input_request_invalid"}
	var normalized: Dictionary = normalized_value
	var recipe_signature := String(publication_service.runtime_recipe_signature(recipe, normalized))
	if recipe_signature.is_empty() or recipe_signature != String(recipe.get("signature", "")):
		return {"status":"pending", "reason":"tree_section_recipe_input_signature_stale"}
	var frozen_request: Dictionary = _freeze_section_value(normalized)
	var frozen_recipe: Dictionary = _freeze_section_value(recipe)
	var content_values := [TREE_SECTION_RECIPE_INPUT_SCHEMA,
		TREE_SECTION_RECIPE_COMPILER_REVISION, seed, prop_id, tier,
		recipe_signature, frozen_request, frozen_recipe]
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(content_values)) != OK:
		return {"status":"pending", "reason":"tree_section_recipe_input_digest_failed"}
	var content_revision := context.finish().hex_encode()
	section_recipe_input_generation += 1
	var record := {"schema":TREE_SECTION_RECIPE_INPUT_SCHEMA,
		"artifactGeneration":section_recipe_input_generation,
		"producerGeneration":int(task.get("enqueueSequence", 0)),
		"worldOwnerInstanceId":get_parent().get_instance_id() if get_parent() != null else 0,
		"worldSeed":seed, "sourceId":"%s:tree:%s" % [seed, prop_id],
		"propId":prop_id, "body":weakref(body), "bodyInstanceId":body.get_instance_id(),
		"bodyGlobalTransform":transform,
		"logicalOwnerCell":StaticRenderSectionGridScript.logical_owner_cell_for_world_position(body.global_position),
		"request":frozen_request, "recipeSnapshot":frozen_recipe,
		"recipeSignature":recipe_signature, "renderLodTier":tier,
		"compilerRevision":TREE_SECTION_RECIPE_COMPILER_REVISION,
		"contentRevision":content_revision}
	record.make_read_only()
	return {"status":"ready", "record":record}


func retain_tree_section_recipe_input_record(record: Dictionary) -> Dictionary:
	if String(record.get("schema", "")) != TREE_SECTION_RECIPE_INPUT_SCHEMA \
			or not record.is_read_only():
		return {"status":"failed", "reason":"tree_section_recipe_input_record_invalid"}
	var body_ref := record.get("body") as WeakRef
	var body: StaticBody3D = body_ref.get_ref() as StaticBody3D if body_ref != null else null
	if not is_instance_valid(body) or body.is_queued_for_deletion() \
			or int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
			or (int(body.get_meta("tree_section_recipe_input_expected_generation", 0)) > 0 \
				and int(record.get("producerGeneration", 0)) != int(body.get_meta("tree_section_recipe_input_expected_generation", 0))) \
			or not (record.get("bodyGlobalTransform", Transform3D.IDENTITY) as Transform3D).is_equal_approx(body.global_transform) \
			or String(body.get_meta("prop_id", "")) != String(record.get("propId", "")) \
			or bool(body.get_meta("tree_publication_cancelled", false)):
		return {"status":"pending", "reason":"tree_section_recipe_input_owner_stale"}
	for index in range(section_recipe_input_records.size() - 1, -1, -1):
		var existing: Dictionary = section_recipe_input_records[index]
		var existing_ref := existing.get("body") as WeakRef
		if existing_ref != null and existing_ref.get_ref() == body:
			section_recipe_input_records.remove_at(index)
	section_recipe_input_records.append(record)
	return {"status":"retained", "sourceId":String(record.get("sourceId", "")),
		"artifactGeneration":int(record.get("artifactGeneration", 0))}


func tree_section_recipe_input_record_for_body(body: StaticBody3D) -> Dictionary:
	if not is_instance_valid(body):
		return {}
	for record_value: Variant in section_recipe_input_records:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		var body_ref := record.get("body") as WeakRef
		if body_ref == null or body_ref.get_ref() != body \
				or int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
				or (int(body.get_meta("tree_section_recipe_input_expected_generation", 0)) > 0 \
					and int(record.get("producerGeneration", 0)) != int(body.get_meta("tree_section_recipe_input_expected_generation", 0))) \
				or String(body.get_meta("prop_id", "")) != String(record.get("propId", "")) \
				or bool(body.get_meta("tree_publication_cancelled", false)) \
				or not (record.get("bodyGlobalTransform", Transform3D.IDENTITY) as Transform3D).is_equal_approx(body.global_transform):
			continue
		return record
	return {}


func _remove_tree_section_recipe_input_record_for_body(body: StaticBody3D) -> void:
	for index in range(section_recipe_input_records.size() - 1, -1, -1):
		var record: Dictionary = section_recipe_input_records[index]
		var body_ref := record.get("body") as WeakRef
		if body_ref != null and body_ref.get_ref() == body \
				and int(record.get("bodyInstanceId", 0)) == body.get_instance_id():
			section_recipe_input_records.remove_at(index)


func seal_prepared_section_value_record(task: Dictionary,
		body: StaticBody3D) -> Dictionary:
	var request_value: Variant = task.get("request", null)
	var recipe_value: Variant = task.get("recipe", null)
	var members_value: Variant = task.get("sectionValueMembers", null)
	if not is_instance_valid(body) or not body.is_inside_tree() \
			or not request_value is Dictionary or not recipe_value is Dictionary \
			or not members_value is Array or members_value.is_empty() \
			or not String(task.get("sectionValueCapturePending", "")).is_empty():
		return {"status":"pending", "reason":"prepared_tree_section_values_incomplete"}
	var request: Dictionary = request_value
	var recipe: Dictionary = recipe_value
	var prop_id := String(request.get("treeId", ""))
	var seed := String(request.get("worldSeed", ""))
	var tier := String(request.get("renderLodTier", ""))
	var recipe_signature := String(recipe.get("signature", ""))
	var foliage_count := 0
	var bole_count := 0
	var branches_count := 0
	for member_value: Variant in members_value:
		if not member_value is Dictionary or not member_value.is_read_only():
			return {"status":"pending", "reason":"prepared_tree_member_mutable_or_invalid"}
		var member: Dictionary = member_value
		if not member.get("mesh") is Mesh or not member.get("material") is Material \
				or not member.get("localTransform") is Transform3D \
				or not member.get("transforms") is Array \
				or not member.get("colors") is Array \
				or not member.get("customData") is Array:
			return {"status":"pending", "reason":"prepared_tree_member_layout_invalid"}
		match String(member.get("role", "")):
			"bole": bole_count += 1
			"branches": branches_count += 1
			"foliage": foliage_count += 1
			_: return {"status":"pending", "reason":"prepared_tree_member_role_invalid"}
	if prop_id.is_empty() or seed.is_empty() or tier.is_empty() \
			or recipe_signature.is_empty() or bole_count != 1 \
			or branches_count > 1 or foliage_count > 1 \
			or String(body.get_meta("prop_id", "")) != prop_id \
			or not (request.get("treeWorldPosition", Vector3.INF) as Vector3).is_equal_approx(body.global_position) \
			or bool(recipe.get("runtimeImpostor", false)):
		return {"status":"pending", "reason":"prepared_tree_identity_or_topology_invalid"}
	prepared_section_generation += 1
	var frozen_request: Dictionary = _freeze_section_value(request)
	var frozen_recipe: Dictionary = _freeze_section_value(recipe)
	var frozen_members: Array = _freeze_section_value(members_value)
	var record := {"schema":"prepared-tree-section-artifact/v1",
		"artifactGeneration":prepared_section_generation,
		"sourceId":"%s:tree:%s" % [seed, prop_id], "propId":prop_id,
		"body":weakref(body), "bodyInstanceId":body.get_instance_id(),
		"bodyGlobalTransform":body.global_transform,
		"request":frozen_request, "recipeSnapshot":frozen_recipe,
		"recipeSignature":recipe_signature, "tier":tier,
		"rebuildPending":false, "sectionValueMembers":frozen_members}
	record.make_read_only()
	return {"status":"ready", "record":record}


func retain_prepared_section_value_record(record: Dictionary) -> Dictionary:
	if String(record.get("schema", "")) != "prepared-tree-section-artifact/v1" \
			or not record.is_read_only():
		return {"status":"failed", "reason":"prepared_tree_record_invalid"}
	var body_ref := record.get("body") as WeakRef
	var body: StaticBody3D = body_ref.get_ref() as StaticBody3D if body_ref != null else null
	if not is_instance_valid(body) or int(record.get("bodyInstanceId", 0)) != body.get_instance_id():
		return {"status":"pending", "reason":"prepared_tree_body_replaced"}
	for index in range(prepared_section_value_records.size() - 1, -1, -1):
		var existing: Dictionary = prepared_section_value_records[index]
		var existing_body_ref := existing.get("body") as WeakRef
		if existing_body_ref != null and existing_body_ref.get_ref() == body:
			prepared_section_acknowledgements.erase(int(existing.get("artifactGeneration", 0)))
			prepared_section_value_records.remove_at(index)
	prepared_section_value_records.append(record)
	return {"status":"retained", "sourceId":String(record.get("sourceId", "")),
		"artifactGeneration":int(record.get("artifactGeneration", 0))}


func acknowledge_prepared_tree_section_install(source_id: String,
		source_revision: String, required_sections: Array[Vector3i],
		installed_receipts: Dictionary) -> Dictionary:
	if source_id.is_empty() or source_revision.is_empty() \
			or required_sections.is_empty() or installed_receipts.size() != required_sections.size():
		return {"status":"pending", "reason":"tree_section_receipt_not_current"}
	for section_key: Vector3i in required_sections:
		var receipt_value: Variant = installed_receipts.get(section_key, null)
		if not receipt_value is Dictionary or String(receipt_value.get("status", "")) != "installed" \
				or receipt_value.get("sectionKey") != section_key \
				or int(receipt_value.get("generation", 0)) <= 0 \
				or String(receipt_value.get("contentManifestDigest", "")).is_empty():
			return {"status":"pending", "reason":"tree_section_receipt_not_current"}
	var record_index := -1
	var record: Dictionary = {}
	for index in range(prepared_section_value_records.size()):
		var row: Dictionary = prepared_section_value_records[index]
		if String(row.get("sourceId", "")) == source_id:
			record_index = index
			record = row
			break
	if record_index < 0 or String(record.get("recipeSignature", "")).is_empty():
		return {"status":"pending", "reason":"prepared_tree_record_missing"}
	var ack: Dictionary = {"sourceRevision":source_revision,
		"requiredSections":required_sections.duplicate(),
		"receipts":installed_receipts.duplicate(false)}
	prepared_section_acknowledgements[int(record.get("artifactGeneration", 0))] = ack
	var body_ref := record.get("body") as WeakRef
	var body: StaticBody3D = body_ref.get_ref() as StaticBody3D if body_ref != null else null
	if not is_instance_valid(body) or int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
			or not body.is_inside_tree() \
			or not (record.get("bodyGlobalTransform", Transform3D.IDENTITY) as Transform3D).is_equal_approx(body.global_transform):
		return {"status":"pending", "reason":"prepared_tree_body_changed_before_retirement"}
	_retire_legacy_tree_visual_for_section_owner(body)
	var frozen_request: Dictionary = record.get("request", {})
	var frozen_members: Array = record.get("sectionValueMembers", [])
	var frozen_recipe: Dictionary = record.get("recipeSnapshot", {})
	remember_published_lod(body, frozen_request, frozen_members, frozen_recipe, true)
	body.set_meta("tree_visual_state", "section_owned")
	body.set_meta("visual_source", "chunk_owned_static_section")
	_remove_tree_section_recipe_input_record_for_body(body)
	prepared_section_acknowledgements.erase(int(record.get("artifactGeneration", 0)))
	prepared_section_value_records.remove_at(record_index)
	return {"status":"acknowledged", "sourceId":source_id,
		"sectionCount":required_sections.size(), "visualRetired":true,
		"gameplayBodyRetained":true}


func _retire_legacy_tree_visual_for_section_owner(body: StaticBody3D) -> void:
	var visual := body.get_node_or_null("GeneratedTreeVisual") as Node3D
	if visual != null and is_instance_valid(visual):
		body.remove_child(visual)
		visual.queue_free()
	release_collision_visibility_proxy(body)
	release_horizon_visible_representation(body)
	release_chunk_static_visual(body)

func retier_task_for_current_viewer(task: Dictionary, body: StaticBody3D) -> bool:
	# This helper is intentionally for pending work only. Callers that already
	# hold a recipe/visual must use the published-LOD reconciliation path below
	# rather than re-evaluating policy every renderer slice.
	var completed_recipe: Dictionary = task.get("recipe", {})
	if not completed_recipe.is_empty() or task.has("visual"):
		return false
	if viewer == null or not _is_live_node(body):
		return false
	var viewer_node: Node3D = _live_viewer()
	if viewer_node == null or not is_instance_valid(viewer_node):
		return false
	var request: Dictionary = task.get("request", {})
	if request.is_empty():
		return false
	request["treeWorldPosition"] = body.global_position
	var current_tier := String(request.get("renderLodTier", "near"))
	var desired_tier := selected_lod_tier(request, current_tier)
	if desired_tier == current_tier:
		return false
	# Retier only before any recipe work begins. Releasing a completed graph or a
	# staged MultiMesh is observable main-thread work; doing it while the player
	# runs turns an otherwise asynchronous result into a publication hitch. Once
	# work exists, finish its atomic visual and let `refresh_published_lods` queue
	# the correct tier through the ordinary, bounded reconciliation path.
	request["renderLodTier"] = desired_tier
	request["publicationPriority"] = body.global_position.distance_squared_to(viewer_node.global_position)
	task["request"] = request
	task["publicationPosition"] = body.global_position
	task["recipeCacheKey"] = publication_service.recipe_cache_key(request)
	task["recipeIdentityKey"] = publication_service.recipe_identity_key(request)
	for key in ["recipe", "lodSourceRecipe", "renderStage", "visual", "woodRoot", "typedBranches", "boleBuildState", "boleBuildComplete", "distalBuildState", "distalBuildComplete", "foliageBuildState", "foliageBuildComplete", "sectionValueMembers", "sectionValueCapturePending"]:
		task.erase(key)
	var cached_recipe: Dictionary = recipe_cache.fetch(String(task.get("recipeCacheKey", "")))
	if not cached_recipe.is_empty():
		task["recipe"] = cached_recipe
		enqueue_completed_task(task)
		recipe_cache_reused_count += 1
		body.set_meta("tree_visual_state", "recipe_cached")
	else:
		var lod_source_recipe: Dictionary = recipe_cache.fetch_compatible_lod_source(
			String(task.get("recipeIdentityKey", "")),
			String(request.get("renderLodTier", "near"))
		)
		if not lod_source_recipe.is_empty():
			task["lodSourceRecipe"] = lod_source_recipe
			lod_recipe_derivation_requested_count += 1
			body.set_meta("tree_visual_state", "recipe_lod_derivation_queued")
		enqueue_pending_task(task)
		if not task.has("lodSourceRecipe"):
			body.set_meta("tree_visual_state", "queued")
	return true

func _process(_delta: float) -> void:
	refresh_viewer_motion_snapshot()
	refresh_collision_visibility_proxies()
	refresh_published_lods()
	start_pending_workers()
	collect_completed_workers()
	publish_completed_recipes()

func start_pending_workers() -> void:
	while active.size() < MAX_ACTIVE_WORKERS and has_pending_tasks():
		# Recipe work is pure and deterministic, so this can improve perceived
		# publication latency without touching placement RNG or gameplay state.
		var task: Dictionary = take_highest_priority_pending_task()
		if task.is_empty():
			break
		var body: StaticBody3D = _publication_body(task)
		if body == null or not is_instance_valid(body):
			cancelled_count += 1
			continue
		if retier_task_for_current_viewer(task, body):
			continue
		var worker_service = TreeSpawnServiceScript.new()
		var thread := Thread.new()
		var worker_callable := Callable(worker_service, "build_recipe_for_worker")
		var worker_arguments := [task.get("request", {})]
		if task.has("lodSourceRecipe"):
			worker_callable = Callable(worker_service, "derive_recipe_for_lod")
			worker_arguments = [task.get("lodSourceRecipe", {}), task.get("request", {})]
		var start_error := thread.start(worker_callable.bindv(worker_arguments))
		if start_error != OK:
			failed_count += 1
			body.set_meta("tree_visual_state", "failed")
			continue
		task["thread"] = thread
		task["workerService"] = worker_service
		body.set_meta("tree_visual_state", "building")
		active.append(task)

func enqueue_pending_task(task: Dictionary) -> void:
	var sequence := int(task.get("enqueueSequence", 0))
	if sequence <= 0:
		return
	pending_tasks[sequence] = task
	pending_order.append(sequence)
	var bucket_key := completed_bucket_key(task)
	var bucket_value: Variant = pending_spatial_buckets.get(bucket_key)
	if bucket_value is Array:
		(bucket_value as Array).append(sequence)
	else:
		pending_spatial_buckets[bucket_key] = [sequence]

func has_pending_tasks() -> bool:
	return not pending_tasks.is_empty()

func take_highest_priority_pending_task() -> Dictionary:
	var sequence := highest_priority_pending_sequence()
	if sequence <= 0:
		return {}
	var task: Dictionary = pending_tasks.get(sequence, {})
	if task.is_empty():
		return {}
	var viewer_position := current_viewer_position()
	if viewer_position != Vector3.INF and task_uses_directional_priority(task, viewer_position):
		directional_worker_selection_count += 1
	pending_tasks.erase(sequence)
	remove_pending_task_from_bucket(sequence, task)
	if sequence == oldest_pending_sequence():
		oldest_pending_sequence()
	return task

func remove_pending_task_from_bucket(sequence: int, task: Dictionary) -> void:
	var bucket_key := completed_bucket_key(task)
	var bucket_value: Variant = pending_spatial_buckets.get(bucket_key)
	if bucket_value is not Array:
		return
	var bucket: Array = bucket_value
	bucket.erase(sequence)
	if bucket.is_empty():
		pending_spatial_buckets.erase(bucket_key)
	else:
		pending_spatial_buckets[bucket_key] = bucket

func highest_priority_pending_sequence() -> int:
	var selection_started_usec := Time.get_ticks_usec()
	var viewer_node: Node3D = _live_viewer()
	if viewer_node != null and is_instance_valid(viewer_node):
		var viewer_position := viewer_node.global_position
		var local_sequence := highest_priority_local_pending_sequence(viewer_position, selection_started_usec)
		var oldest_sequence := oldest_pending_sequence()
		if local_sequence > 0:
			if oldest_sequence > 0:
				var oldest_task: Dictionary = pending_tasks.get(oldest_sequence, {})
				var local_task: Dictionary = pending_tasks.get(local_sequence, {})
				if not oldest_task.is_empty() and not local_task.is_empty() and priority_score_precedes(
					oldest_task,
					effective_priority_at(oldest_task, selection_started_usec, viewer_position),
					local_task,
					worker_local_selection_score
				):
					record_worker_priority_selection(worker_local_selection_candidate_count, Time.get_ticks_usec() - selection_started_usec)
					return oldest_sequence
			record_worker_priority_selection(worker_local_selection_candidate_count, Time.get_ticks_usec() - selection_started_usec)
			return local_sequence
		if oldest_sequence > 0:
			record_worker_priority_selection(worker_local_selection_candidate_count, Time.get_ticks_usec() - selection_started_usec)
			return oldest_sequence
	# Viewless service/PoC callers retain FIFO behavior without a global scan.
	worker_priority_selection_full_fallback_count += 1
	var oldest_sequence := oldest_pending_sequence()
	record_worker_priority_selection(1 if oldest_sequence > 0 else 0, Time.get_ticks_usec() - selection_started_usec)
	return oldest_sequence

func highest_priority_local_pending_sequence(viewer_position: Vector3, now_usec: int) -> int:
	var center_cell := completed_priority_cell(viewer_position)
	var best_sequence := -1
	var best_score := INF
	var inspected := 0
	# Search the current cell plus a short predicted corridor before the regular
	# local rings.  This remains a constant-size bucket query, but lets a tree a
	# sprint ahead compete with an equally near side/behind tree rather than
	# being hidden by the first occupied square ring.
	for bucket_key in directional_priority_cells(viewer_position):
		var directional_bucket_value: Variant = pending_spatial_buckets.get(bucket_key)
		if directional_bucket_value is not Array:
			continue
		for raw_sequence in directional_bucket_value as Array:
			var sequence := int(raw_sequence)
			var candidate_value: Variant = pending_tasks.get(sequence)
			if candidate_value is not Dictionary:
				continue
			var candidate: Dictionary = candidate_value
			if candidate.is_empty():
				continue
			inspected += 1
			var candidate_score := effective_priority_at(candidate, now_usec, viewer_position)
			if best_sequence < 0 or priority_score_precedes(candidate, candidate_score, pending_tasks.get(best_sequence, {}), best_score):
				best_sequence = sequence
				best_score = candidate_score
	if best_sequence >= 0:
		worker_local_selection_candidate_count = inspected
		worker_local_selection_score = best_score
		return best_sequence
	# Same local-ring policy as completed recipes, but here it prevents worker
	# launch from ever sorting a full streamed-in backlog on the main thread.
	for radius in range(COMPLETED_PRIORITY_LOCAL_CELL_RADIUS + 1):
		for z_offset in range(-radius, radius + 1):
			for x_offset in range(-radius, radius + 1):
				if radius > 0 and abs(x_offset) != radius and abs(z_offset) != radius:
					continue
				var bucket_key := completed_bucket_key_for_cell(Vector2i(center_cell.x + x_offset, center_cell.y + z_offset))
				# Empty cells dominate a sprinting viewer's local selection ring.
				# Avoid materialising a throwaway Array for every such probe: an
				# absent bucket has no candidate and cannot influence the exact
				# distance/age ordering below.
				var bucket_value: Variant = pending_spatial_buckets.get(bucket_key)
				if bucket_value is not Array:
					continue
				var bucket: Array = bucket_value
				for raw_sequence in bucket:
					var sequence := int(raw_sequence)
					var candidate_value: Variant = pending_tasks.get(sequence)
					if candidate_value is not Dictionary:
						continue
					var candidate: Dictionary = candidate_value
					if candidate.is_empty():
						continue
					inspected += 1
					var candidate_score := effective_priority_at(candidate, now_usec, viewer_position)
					if best_sequence < 0 or priority_score_precedes(candidate, candidate_score, pending_tasks.get(best_sequence, {}), best_score):
						best_sequence = sequence
						best_score = candidate_score
		if best_sequence >= 0:
			break
	worker_local_selection_candidate_count = inspected
	worker_local_selection_score = best_score
	return best_sequence

func oldest_pending_sequence() -> int:
	while pending_order_head < pending_order.size():
		var sequence := int(pending_order[pending_order_head])
		if pending_tasks.has(sequence):
			return sequence
		pending_order_head += 1
	return -1

func record_worker_priority_selection(inspected: int, elapsed_usec: int) -> void:
	worker_priority_selection_count += 1
	worker_priority_selection_candidate_total += maxi(0, inspected)
	worker_priority_selection_max_candidates = maxi(worker_priority_selection_max_candidates, inspected)
	worker_priority_selection_sample_cursor = append_bounded_timing_sample(
		worker_priority_selection_samples_usec,
		worker_priority_selection_sample_cursor,
		maxi(0, elapsed_usec)
	)

func worker_priority_selection_timing() -> Dictionary:
	if worker_priority_selection_samples_usec.is_empty():
		return {"sampleCount": 0, "p50Usec": 0, "p95Usec": 0, "p99Usec": 0, "maxUsec": 0}
	var sorted: Array[int] = worker_priority_selection_samples_usec.duplicate()
	sorted.sort()
	return {
		"sampleCount": sorted.size(),
		"p50Usec": timing_percentile(sorted, 0.50),
		"p95Usec": timing_percentile(sorted, 0.95),
		"p99Usec": timing_percentile(sorted, 0.99),
		"maxUsec": sorted.back()
	}

func collect_completed_workers() -> void:
	var still_active: Array[Dictionary] = []
	for task in active:
		var thread := task.get("thread") as Thread
		if thread == null:
			failed_count += 1
			continue
		if thread.is_alive():
			still_active.append(task)
			continue
		var recipe_value = thread.wait_to_finish()
		if recipe_value is Dictionary and not (recipe_value as Dictionary).is_empty():
			task["recipe"] = recipe_value
			# Workers return one already-reduced recipe. The bounded queue cache owns
			# that result from this point on; do not retain the worker's private
			# canonical-grammar cache until the visual finally commits.
			task.erase("workerService")
			recipe_cache.store(
				String(task.get("recipeCacheKey", "")),
				recipe_value as Dictionary,
				String(task.get("recipeIdentityKey", "")),
				String((task.get("request", {}) as Dictionary).get("renderLodTier", "near"))
			)
			if task.has("lodSourceRecipe"):
				lod_recipe_derivation_completed_count += 1
			enqueue_completed_task(task)
		else:
			var body: StaticBody3D = _publication_body(task)
			if body != null and is_instance_valid(body):
				body.set_meta("tree_visual_state", "failed")
			failed_count += 1
	active = still_active
func task_precedes(left: Dictionary, right: Dictionary) -> bool:
	var viewer_node: Node3D = _live_viewer()
	var viewer_position := viewer_node.global_position if viewer_node != null and is_instance_valid(viewer_node) else Vector3.INF
	return task_precedes_at(left, right, Time.get_ticks_usec(), viewer_position)

func task_precedes_at(left: Dictionary, right: Dictionary, now_usec: int, viewer_position := Vector3.INF) -> bool:
	var left_score := effective_priority_at(left, now_usec, viewer_position)
	var right_score := effective_priority_at(right, now_usec, viewer_position)
	return priority_score_precedes(left, left_score, right, right_score)

func priority_score_precedes(left: Dictionary, left_score: float, right: Dictionary, right_score: float) -> bool:
	if not is_equal_approx(left_score, right_score):
		return left_score < right_score
	return int(left.get("enqueueSequence", 0)) < int(right.get("enqueueSequence", 0))

func effective_priority(task: Dictionary, now_usec: int) -> float:
	var viewer_node: Node3D = _live_viewer()
	var viewer_position := viewer_node.global_position if viewer_node != null and is_instance_valid(viewer_node) else Vector3.INF
	return effective_priority_at(task, now_usec, viewer_position)

func effective_priority_at(task: Dictionary, now_usec: int, viewer_position := Vector3.INF) -> float:
	var base := live_publication_priority_at(task, viewer_position)
	if not is_finite(base):
		return base
	var waited_seconds := maxf(0.0, float(now_usec - int(task.get("enqueuedUsec", now_usec))) / 1000000.0)
	# A positive floor lets a very old distant request eventually beat even a
	# zero-distance local request; square root restores world-distance units.
	return sqrt(maxf(0.0, base) + 1.0) / (1.0 + waited_seconds / PUBLICATION_PRIORITY_AGE_SCALE_SECONDS)

func live_publication_priority(task: Dictionary) -> float:
	# Publication order is presentation-only and must follow the current player
	# position, including tasks whose immutable recipe is already worker-complete
	# or partially assembled off-tree. The request retains its original priority
	# for deterministic diagnostics; this live value only decides which bounded
	# renderer slice receives the next frame.
	var viewer_node: Node3D = _live_viewer()
	var viewer_position := viewer_node.global_position if viewer_node != null and is_instance_valid(viewer_node) else Vector3.INF
	return live_publication_priority_at(task, viewer_position)

func live_publication_priority_at(task: Dictionary, viewer_position := Vector3.INF) -> float:
	var task_position = task.get("publicationPosition", null)
	if task_position is Vector3 and viewer_position != Vector3.INF:
		var base_priority := viewer_position.distance_squared_to(task_position as Vector3)
		var motion := viewer_motion_for_position(viewer_position)
		if motion.is_empty():
			return base_priority
		var heading: Vector3 = motion.get("heading", Vector3.ZERO)
		var relative := (task_position as Vector3) - viewer_position
		relative.y = 0.0
		var forward_distance := relative.dot(heading)
		if forward_distance <= 0.0:
			# Behind-the-player work remains eligible and age-fair, but it should
			# not consume a renderer slice that would make a sprinting player meet
			# a collision before its forward tree becomes visible.
			return base_priority * (1.0 + BACKWARD_PRIORITY_PENALTY)
		var lateral_distance := maxf(0.0, sqrt(maxf(0.0, relative.length_squared() - forward_distance * forward_distance)))
		var corridor_half_width := clampf(
			FORWARD_CORRIDOR_MIN_HALF_WIDTH + forward_distance * 0.18,
			FORWARD_CORRIDOR_MIN_HALF_WIDTH,
			FORWARD_CORRIDOR_MAX_HALF_WIDTH
		)
		if lateral_distance > corridor_half_width:
			return base_priority + lateral_distance * lateral_distance * BACKWARD_PRIORITY_PENALTY
		var predicted_position: Vector3 = motion.get("predictedPosition", viewer_position)
		var predicted_delta := (task_position as Vector3) - predicted_position
		predicted_delta.y = 0.0
		# Arrival-oriented distance makes a tree straight ahead win against an
		# equal-distance lateral/behind task without inventing a magic authored
		# priority. Lateral cost preserves a narrow, natural viewing corridor.
		return predicted_delta.length_squared() + lateral_distance * lateral_distance * FORWARD_CORRIDOR_LATERAL_WEIGHT
	return float(task.get("publicationPriority", INF))

func task_uses_directional_priority(task: Dictionary, viewer_position: Vector3) -> bool:
	var task_position = task.get("publicationPosition", null)
	var motion := viewer_motion_for_position(viewer_position)
	if task_position is not Vector3 or motion.is_empty():
		return false
	var heading: Vector3 = motion.get("heading", Vector3.ZERO)
	var relative := (task_position as Vector3) - viewer_position
	relative.y = 0.0
	var forward_distance := relative.dot(heading)
	if forward_distance <= 0.0:
		return false
	var lateral_distance := maxf(0.0, sqrt(maxf(0.0, relative.length_squared() - forward_distance * forward_distance)))
	var corridor_half_width := clampf(
		FORWARD_CORRIDOR_MIN_HALF_WIDTH + forward_distance * 0.18,
		FORWARD_CORRIDOR_MIN_HALF_WIDTH,
		FORWARD_CORRIDOR_MAX_HALF_WIDTH
	)
	return lateral_distance <= corridor_half_width

func directional_priority_cells(viewer_position: Vector3) -> Array[Vector2i]:
	var motion := viewer_motion_for_position(viewer_position)
	if motion.is_empty():
		return []
	var heading: Vector3 = motion.get("heading", Vector3.ZERO)
	var lookahead_distance := float(motion.get("lookaheadDistance", 0.0))
	if heading.length_squared() <= 0.0001 or lookahead_distance <= 0.0:
		return []
	var cells: Array[Vector2i] = []
	var center := completed_priority_cell(viewer_position)
	cells.append(center)
	var scan_distance := minf(VIEWER_MOTION_MAX_LOOKAHEAD_DISTANCE + COMPLETED_PRIORITY_CELL_SIZE * 0.5, lookahead_distance + COMPLETED_PRIORITY_CELL_SIZE * 0.5)
	for index in range(1, MAX_DIRECTIONAL_PRIORITY_CELLS + 1):
		var distance := minf(scan_distance, COMPLETED_PRIORITY_CELL_SIZE * float(index))
		if distance <= 0.0:
			continue
		var cell := completed_priority_cell(viewer_position + heading * distance)
		if cell not in cells:
			cells.append(cell)
	return cells

func publish_completed_recipes() -> void:
	var work_units := 0
	var frame_started_usec := Time.get_ticks_usec()
	var last_stage := ""
	var last_scheduler_usec := 0
	var last_validation_usec := 0
	var last_stage_usec := 0
	var last_reporting_usec := 0
	var last_unattributed_usec := 0
	var last_accounted_elapsed_usec := 0
	var completed_before_last_stage := completed_count + (1 if not staged_publication_task.is_empty() else 0)
	while work_units < MAX_PUBLICATION_WORK_UNITS_PER_FRAME and has_completed_tasks():
		# Cancellation cleanup is real main-thread work too. Check the elapsed
		# budget before *every* dequeue so a stream-out cannot drain an arbitrary
		# number of invalid bodies in one gameplay frame.
		if Time.get_ticks_usec() - frame_started_usec >= MAX_PUBLICATION_WORK_USEC_PER_FRAME:
			break
		var scheduler_started_usec := Time.get_ticks_usec()
		promote_higher_priority_completed_task()
		var selected_completed_index := highest_priority_completed_index() if staged_publication_task.is_empty() else -1
		var next_task: Dictionary = peek_next_completed_task(selected_completed_index)
		var next_stage := String(next_task.get("renderStage", "root"))
		var elapsed_usec := Time.get_ticks_usec() - frame_started_usec
		if work_units > 0 and elapsed_usec + estimated_stage_cost_usec(next_stage) > MAX_PUBLICATION_WORK_USEC_PER_FRAME:
			break
		var task: Dictionary = take_next_completed_task(selected_completed_index)
		var scheduler_elapsed_usec := Time.get_ticks_usec() - scheduler_started_usec
		record_publication_scheduler_work(scheduler_elapsed_usec)
		if task.is_empty():
			break
		var validation_started_usec := Time.get_ticks_usec()
		var body: StaticBody3D = _publication_body(task)
		var validation_elapsed_usec := Time.get_ticks_usec() - validation_started_usec
		record_publication_validation(validation_elapsed_usec)
		if body == null or not is_instance_valid(body):
			var cancellation_started_usec := Time.get_ticks_usec()
			release_staged_visual(task)
			var cancellation_elapsed_usec := Time.get_ticks_usec() - cancellation_started_usec
			var cancellation_reporting_started_usec := Time.get_ticks_usec()
			record_publication_work("cancellation", cancellation_elapsed_usec)
			record_publication_bookkeeping(
				Time.get_ticks_usec() - frame_started_usec - scheduler_elapsed_usec - validation_elapsed_usec - cancellation_elapsed_usec
			)
			var cancellation_reporting_elapsed_usec := Time.get_ticks_usec() - cancellation_reporting_started_usec
			record_publication_reporting(cancellation_reporting_elapsed_usec)
			var cancellation_frame_elapsed_usec := Time.get_ticks_usec() - frame_started_usec
			var cancellation_unattributed_usec := maxi(0, cancellation_frame_elapsed_usec - scheduler_elapsed_usec - validation_elapsed_usec - cancellation_elapsed_usec - cancellation_reporting_elapsed_usec)
			record_publication_unattributed(cancellation_unattributed_usec)
			last_stage = "cancellation"
			last_scheduler_usec = scheduler_elapsed_usec
			last_validation_usec = validation_elapsed_usec
			last_stage_usec = cancellation_elapsed_usec
			last_reporting_usec = cancellation_reporting_elapsed_usec
			last_unattributed_usec = cancellation_unattributed_usec
			last_accounted_elapsed_usec = cancellation_frame_elapsed_usec
			completed_before_last_stage = completed_count + (1 if not staged_publication_task.is_empty() else 0)
			cancelled_count += 1
			work_units += 1
			continue
		var stage := String(task.get("renderStage", "root"))
		var started_usec := Time.get_ticks_usec()
		advance_publication_task(task, body)
		var stage_elapsed_usec := Time.get_ticks_usec() - started_usec
		var reporting_started_usec := Time.get_ticks_usec()
		record_publication_work(stage, stage_elapsed_usec)
		record_publication_bookkeeping(
			Time.get_ticks_usec() - frame_started_usec - scheduler_elapsed_usec - validation_elapsed_usec - stage_elapsed_usec
		)
		var reporting_elapsed_usec := Time.get_ticks_usec() - reporting_started_usec
		record_publication_reporting(reporting_elapsed_usec)
		var current_frame_elapsed_usec := Time.get_ticks_usec() - frame_started_usec
		var unattributed_elapsed_usec := maxi(0, current_frame_elapsed_usec - scheduler_elapsed_usec - validation_elapsed_usec - stage_elapsed_usec - reporting_elapsed_usec)
		record_publication_unattributed(unattributed_elapsed_usec)
		last_stage = stage
		last_scheduler_usec = scheduler_elapsed_usec
		last_validation_usec = validation_elapsed_usec
		last_stage_usec = stage_elapsed_usec
		last_reporting_usec = reporting_elapsed_usec
		last_unattributed_usec = unattributed_elapsed_usec
		last_accounted_elapsed_usec = current_frame_elapsed_usec
		completed_before_last_stage = completed_count + (1 if not staged_publication_task.is_empty() else 0)
		work_units += 1
	if work_units > 0:
		# Take the frame timestamp before its own monitoring writes. The earlier
		# form sampled after recording timing dictionaries, which made the reported
		# aggregate include the telemetry's allocation/GC cost but made the
		# per-stage breakdown impossible to reconcile with it.
		var frame_elapsed_usec := maxi(0, Time.get_ticks_usec() - frame_started_usec)
		var loop_tail_usec := maxi(0, frame_elapsed_usec - last_accounted_elapsed_usec)
		record_publication_loop_tail(loop_tail_usec)
		record_worst_publication_frame(
			frame_elapsed_usec,
			last_stage,
			last_scheduler_usec,
			last_validation_usec,
			last_stage_usec,
			last_reporting_usec,
			last_unattributed_usec,
			loop_tail_usec,
			completed_before_last_stage
		)
		publication_frame_sample_cursor = append_bounded_timing_sample(
			publication_frame_samples_usec,
			publication_frame_sample_cursor,
			frame_elapsed_usec
		)

func enqueue_completed_task(task: Dictionary) -> void:
	# Seal deterministic section inputs at worker completion, ahead of the legacy
	# staged node/mesh publisher. The existing publisher remains active as the
	# visual fallback until the section compiler and native receipts take over.
	if section_owned_publication_enabled and not task.has("sectionRecipeInputRecord"):
		var recipe_body: StaticBody3D = _publication_body(task)
		var recipe_value: Variant = task.get("recipe", null)
		if recipe_body != null and recipe_value is Dictionary:
			var sealed := build_tree_section_recipe_input_record(task, recipe_body, recipe_value)
			if sealed.get("status") == "ready":
				var record: Dictionary = sealed.get("record", {})
				var retained := retain_tree_section_recipe_input_record(record)
				if retained.get("status") == "retained":
					task["sectionRecipeInputRecord"] = record
	if not task.has("publicationPosition"):
		var body: StaticBody3D = _publication_body(task)
		var request: Dictionary = task.get("request", {})
		task["publicationPosition"] = body.global_position if _is_live_node(body) else request.get("treeWorldPosition", null)
	var index := completed.size()
	completed.append(task)
	completed_count += 1
	var bucket_key := completed_bucket_key(task)
	var bucket_value: Variant = completed_spatial_buckets.get(bucket_key)
	if bucket_value is Array:
		(bucket_value as Array).append(index)
	else:
		completed_spatial_buckets[bucket_key] = [index]

func has_completed_tasks() -> bool:
	return not staged_publication_task.is_empty() or completed_count > 0

func promote_higher_priority_completed_task() -> void:
	# A partial visual is deliberately detached from the gameplay body, so it is
	# safe to pause. Do that when an already-built nearby recipe becomes more
	# important than the tree currently consuming one renderer slice per frame.
	# This preserves atomic attachment, avoids cancellation/rebuild churn, and
	# prevents a far crown's long bole/foliage stage from hiding a local tree.
	if staged_publication_task.is_empty() or String(staged_publication_task.get("renderStage", "root")) == "commit":
		return
	var candidate_index := highest_priority_completed_index()
	if candidate_index < 0:
		return
	var candidate: Dictionary = completed[candidate_index]
	var viewer_node: Node3D = _live_viewer()
	var viewer_position := viewer_node.global_position if viewer_node != null and is_instance_valid(viewer_node) else Vector3.INF
	if not task_precedes_at(candidate, staged_publication_task, Time.get_ticks_usec(), viewer_position):
		return
	var paused_task := staged_publication_task
	paused_task["publicationPreemptions"] = int(paused_task.get("publicationPreemptions", 0)) + 1
	enqueue_completed_task(paused_task)
	staged_publication_task = {}
	preempted_publication_count += 1
	if viewer_position != Vector3.INF and task_uses_directional_priority(candidate, viewer_position):
		directional_preemption_count += 1

func highest_priority_completed_index() -> int:
	var selection_started_usec := Time.get_ticks_usec()
	var viewer_node: Node3D = _live_viewer()
	if viewer_node != null and is_instance_valid(viewer_node):
		var viewer_position := viewer_node.global_position
		var local_index := highest_priority_local_completed_index(viewer_position, selection_started_usec)
		var oldest_index := oldest_completed_index()
		if local_index >= 0:
			# The oldest request is the only non-local candidate that can outrank
			# a local request through monotonic age weighting. Comparing just
			# these two preserves starvation protection without a global rescan.
			if oldest_index >= 0 and priority_score_precedes(
				completed[oldest_index],
				effective_priority_at(completed[oldest_index], selection_started_usec, viewer_position),
				completed[local_index],
				local_selection_score
			):
				record_priority_selection(local_selection_candidate_count, Time.get_ticks_usec() - selection_started_usec)
				return oldest_index
			record_priority_selection(local_selection_candidate_count, Time.get_ticks_usec() - selection_started_usec)
			return local_index
		if oldest_index >= 0:
			record_priority_selection(local_selection_candidate_count, Time.get_ticks_usec() - selection_started_usec)
			return oldest_index
	# There is no meaningful distance priority without a valid viewer. FIFO is
	# deterministic and starvation-safe for startup, service fixtures, and the
	# transient teardown/rebind windows where a global scan would otherwise
	# amplify a large completed backlog into a gameplay-frame spike.
	priority_selection_viewless_fifo_count += 1
	var oldest_viewless_index := oldest_completed_index()
	record_priority_selection(1 if oldest_viewless_index >= 0 else 0, Time.get_ticks_usec() - selection_started_usec)
	return oldest_viewless_index

func highest_priority_local_completed_index(viewer_position: Vector3, now_usec: int) -> int:
	var center_cell := completed_priority_cell(viewer_position)
	var best_index := -1
	var best_score := INF
	var inspected := 0
	# See the equivalent pending-worker corridor above. Completed recipes need
	# the same small forward look-ahead or worker completion order can undo the
	# readiness win by publishing a lateral tree first.
	for bucket_key in directional_priority_cells(viewer_position):
		var directional_bucket_value: Variant = completed_spatial_buckets.get(bucket_key)
		if directional_bucket_value is not Array:
			continue
		for raw_index in directional_bucket_value as Array:
			var index := int(raw_index)
			if index < completed_head or index >= completed.size():
				continue
			var candidate: Dictionary = completed[index]
			if candidate.is_empty():
				continue
			inspected += 1
			var candidate_score := effective_priority_at(candidate, now_usec, viewer_position)
			if best_index < 0 or priority_score_precedes(candidate, candidate_score, completed[best_index], best_score):
				best_index = index
				best_score = candidate_score
	if best_index >= 0:
		local_selection_candidate_count = inspected
		local_selection_score = best_score
		return best_index
	# Check increasingly distant square rings.  The first occupied ring bounds
	# work to nearby buckets; every candidate within that ring still receives an
	# exact distance-and-age comparison, so this is not authored ordering.
	for radius in range(COMPLETED_PRIORITY_LOCAL_CELL_RADIUS + 1):
		for z_offset in range(-radius, radius + 1):
			for x_offset in range(-radius, radius + 1):
				if radius > 0 and abs(x_offset) != radius and abs(z_offset) != radius:
					continue
				var bucket_key := completed_bucket_key_for_cell(Vector2i(center_cell.x + x_offset, center_cell.y + z_offset))
				var bucket_value: Variant = completed_spatial_buckets.get(bucket_key)
				if bucket_value is not Array:
					continue
				var bucket: Array = bucket_value
				for raw_index in bucket:
					var index := int(raw_index)
					if index < completed_head or index >= completed.size():
						continue
					var candidate: Dictionary = completed[index]
					if candidate.is_empty():
						continue
					inspected += 1
					var candidate_score := effective_priority_at(candidate, now_usec, viewer_position)
					if best_index < 0 or priority_score_precedes(candidate, candidate_score, completed[best_index], best_score):
						best_index = index
						best_score = candidate_score
		if best_index >= 0:
			break
	local_selection_candidate_count = inspected
	local_selection_score = best_score
	return best_index

func oldest_completed_index() -> int:
	while completed_head < completed.size() and completed[completed_head].is_empty():
		completed_head += 1
	return completed_head if completed_head < completed.size() else -1

func completed_priority_cell(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / COMPLETED_PRIORITY_CELL_SIZE), floori(position.z / COMPLETED_PRIORITY_CELL_SIZE))

func completed_bucket_key_for_cell(cell: Vector2i) -> Vector2i:
	return cell

func completed_bucket_key(task: Dictionary) -> Vector2i:
	var cached_position = task.get("publicationPosition", null)
	if cached_position is Vector3 and (cached_position as Vector3).is_finite():
		return completed_bucket_key_for_cell(completed_priority_cell(cached_position as Vector3))
	# A task admitted without a world binding stays in the unplaced bucket.
	# Reattachment must not change its removal key while the entry is indexed.
	if task.has("publicationPosition"):
		return COMPLETED_UNPLACED_CELL
	var body: StaticBody3D = _publication_body(task)
	if _is_live_node(body):
		return completed_bucket_key_for_cell(completed_priority_cell(body.global_position))
	var request: Dictionary = task.get("request", {})
	var fallback_position = request.get("treeWorldPosition", null)
	if fallback_position is Vector3 and (fallback_position as Vector3).is_finite():
		return completed_bucket_key_for_cell(completed_priority_cell(fallback_position as Vector3))
	return COMPLETED_UNPLACED_CELL

func record_priority_selection(inspected: int, elapsed_usec: int) -> void:
	priority_selection_count += 1
	priority_selection_candidate_total += maxi(0, inspected)
	priority_selection_max_candidates = maxi(priority_selection_max_candidates, inspected)
	priority_selection_sample_cursor = append_bounded_timing_sample(
		priority_selection_samples_usec,
		priority_selection_sample_cursor,
		maxi(0, elapsed_usec)
	)

func priority_selection_timing() -> Dictionary:
	if priority_selection_samples_usec.is_empty():
		return {"sampleCount": 0, "p50Usec": 0, "p95Usec": 0, "p99Usec": 0, "maxUsec": 0}
	var sorted: Array[int] = priority_selection_samples_usec.duplicate()
	sorted.sort()
	return {
		"sampleCount": sorted.size(),
		"p50Usec": timing_percentile(sorted, 0.50),
		"p95Usec": timing_percentile(sorted, 0.95),
		"p99Usec": timing_percentile(sorted, 0.99),
		"maxUsec": sorted.back()
	}

func peek_next_completed_task(selected_completed_index := -1) -> Dictionary:
	if not staged_publication_task.is_empty():
		return staged_publication_task
	var best_index := selected_completed_index
	if best_index < 0:
		best_index = highest_priority_completed_index()
	if best_index >= 0:
		return completed[best_index]
	return {}

func take_next_completed_task(selected_completed_index := -1) -> Dictionary:
	if not staged_publication_task.is_empty():
		var staged := staged_publication_task
		staged_publication_task = {}
		return staged
	var best_index := selected_completed_index
	if best_index < 0:
		best_index = highest_priority_completed_index()
	if best_index < 0:
		return {}
	var task: Dictionary = completed[best_index]
	var viewer_position := current_viewer_position()
	if viewer_position != Vector3.INF and task_uses_directional_priority(task, viewer_position):
		directional_publication_selection_count += 1
	remove_completed_task_from_bucket(best_index, task)
	completed[best_index] = {}
	completed_count = maxi(0, completed_count - 1)
	if best_index == completed_head:
		oldest_completed_index()
	# Clear only after consuming the final value. Tombstones avoid array shifts
	# and keep spatial-bucket indices valid until that point.
	if completed_count == 0:
		completed.clear()
		completed_head = 0
		completed_spatial_buckets.clear()
	return task

func remove_completed_task_from_bucket(index: int, task: Dictionary) -> void:
	# Completed storage intentionally keeps a tombstone so the oldest-task head
	# stays O(1), but a spatial bucket must retain only live indices. Otherwise
	# a long sprint repeatedly scans historical tombstones inside the player's
	# local cells even though its measured candidate count is small.
	var bucket_key := completed_bucket_key(task)
	var bucket_value: Variant = completed_spatial_buckets.get(bucket_key)
	if bucket_value is not Array:
		return
	var bucket: Array = bucket_value
	bucket.erase(index)
	if bucket.is_empty():
		completed_spatial_buckets.erase(bucket_key)
	else:
		completed_spatial_buckets[bucket_key] = bucket

func continue_publication_task(task: Dictionary) -> void:
	# A single tree remains atomic across its render stages, but it lives outside
	# the FIFO queue so `push_front()` cannot move every other completed recipe.
	staged_publication_task = task

func advance_publication_task(task: Dictionary, body: StaticBody3D) -> void:
	var request: Dictionary = task.get("request", {})
	var recipe: Dictionary = task.get("recipe", {})
	var stage := String(task.get("renderStage", "root"))
	if stage == "root":
		var visual_factory = publication_service.get_visual_factory()
		if bool(recipe.get("runtimeImpostor", false)):
			if publish_chunk_owned_impostor(body, request, recipe):
				commit_published_visual(task, body, null, request, recipe, true)
				publication_stage_counts["root"] = int(publication_stage_counts.get("root", 0)) + 1
				publication_stage_counts["impostor"] = int(publication_stage_counts.get("impostor", 0)) + 1
				publication_stage_counts["chunkImpostor"] = int(publication_stage_counts.get("chunkImpostor", 0)) + 1
				return
		var root: Node3D = visual_factory.create_recipe_root(
			recipe,
			String(request.get("biome", "forest")),
			String(request.get("treeId", "procedural-tree"))
		)
		if root == null:
			body.set_meta("tree_visual_state", "failed")
			failed_count += 1
			return
		root.name = "GeneratedTreeVisual"
		root.position = Vector3.ZERO
		root.rotation = Vector3.ZERO
		root.scale = Vector3.ONE
		var wood_root := Node3D.new()
		wood_root.name = "ProceduralTreeWood"
		wood_root.set_meta("tree_wood_topology", "continuous_structural_wood_with_instanced_supported_twigs")
		root.add_child(wood_root)
		# If a chunk batch is unavailable (for example, a headless renderer), keep
		# the established per-tree impostor fallback. Near/mid/far recipes retain
		# the normal atomic multi-stage path.
		if bool(recipe.get("runtimeImpostor", false)):
			var impostor: Node3D = visual_factory.instantiate_runtime_impostor(recipe, String(request.get("biome", "forest"))) as Node3D
			if impostor != null:
				root.add_child(impostor)
			commit_published_visual(task, body, root, request, recipe)
			publication_stage_counts["root"] = int(publication_stage_counts.get("root", 0)) + 1
			publication_stage_counts["impostor"] = int(publication_stage_counts.get("impostor", 0)) + 1
			return
		task["visual"] = root
		task["woodRoot"] = wood_root
		task["renderStage"] = "bole"
		body.set_meta("tree_visual_state", "assembling")
		publication_stage_counts["root"] = int(publication_stage_counts.get("root", 0)) + 1
		continue_publication_task(task)
		return
	var visual: Node3D = task.get("visual", null) as Node3D
	if visual == null or not is_instance_valid(visual):
		body.set_meta("tree_visual_state", "failed")
		failed_count += 1
		return
	var wood_root: Node3D = task.get("woodRoot", null) as Node3D
	if wood_root == null or not is_instance_valid(wood_root):
		body.set_meta("tree_visual_state", "failed")
		failed_count += 1
		return
	var branches: Array[Dictionary] = []
	var cached_branches = task.get("typedBranches", null)
	if cached_branches is Array:
		for cached_branch in cached_branches:
			if cached_branch is Dictionary:
				branches.append(cached_branch as Dictionary)
	if branches.is_empty():
		for branch_value in recipe.get("branches", []):
			if branch_value is Dictionary:
				branches.append(branch_value as Dictionary)
		task["typedBranches"] = branches
	if stage == "bole":
		var visual_factory = publication_service.get_visual_factory()
		if not task.has("boleBuildState"):
			var initial_bole_build_state: Dictionary = visual_factory.begin_runtime_bole_build(branches)
			if initial_bole_build_state.is_empty():
				body.set_meta("tree_visual_state", "failed")
				failed_count += 1
				return
			# Graph partitioning is deterministic but can be the expensive part of a
			# dense trunk build.  Keep it in its own queue slice, then append the
			# actual connected wood progressively on following frames.
			task["boleBuildState"] = initial_bole_build_state
			continue_publication_task(task)
			return
		var bole_build_state: Dictionary = task.get("boleBuildState", {})
		if bole_build_state.is_empty():
			# A staged state must never be lost silently; this also protects a
			# future chunk-cancellation path from publishing a partial trunk.
			body.set_meta("tree_visual_state", "failed")
			failed_count += 1
			return
		if bool(task.get("boleBuildComplete", false)):
			var completed_bole_visual: MeshInstance3D = visual_factory.finish_runtime_bole(
				recipe,
				bole_build_state,
				String(request.get("biome", "forest"))
			)
			if completed_bole_visual != null:
				wood_root.add_child(completed_bole_visual)
				_append_section_value_member(task, completed_bole_visual, "bole")
			# `finish_runtime_bole` transfers the ArrayMesh to the attached visual.
			# Do not keep the completed SurfaceTool/build-state graph alive until
			# the local task happens to fall out of scope after commit: releasing it
			# there was an unmeasured main-thread teardown tail. Erasing the task
			# owner here makes the final local reference release inside this already
			# budgeted, timed publication stage.
			task.erase("boleBuildState")
			task["renderStage"] = "distal"
			publication_stage_counts["bole"] = int(publication_stage_counts.get("bole", 0)) + 1
			continue_publication_task(task)
			return
		var bole_complete: bool = bool(visual_factory.advance_runtime_bole_build(bole_build_state, 1))
		task["boleBuildState"] = bole_build_state
		if not bole_complete:
			continue_publication_task(task)
			return
		# ArrayMesh.commit() also uploads a resource.  Give that finalization its
		# own bounded queue slice instead of coupling it to the final tube/hull.
		task["boleBuildComplete"] = true
		continue_publication_task(task)
		return
	if stage == "distal":
		var distal_factory = publication_service.get_visual_factory()
		if not task.has("distalBuildState"):
			var initial_distal_build_state: Dictionary = distal_factory.begin_runtime_distal_build(
				recipe,
				branches,
				String(request.get("biome", "forest")),
				String(request.get("treeId", "procedural-tree"))
			)
			if initial_distal_build_state.is_empty():
				task["renderStage"] = "foliage"
				continue_publication_task(task)
				return
			task["distalBuildState"] = initial_distal_build_state
			continue_publication_task(task)
			return
		var distal_build_state: Dictionary = task.get("distalBuildState", {})
		if distal_build_state.is_empty():
			body.set_meta("tree_visual_state", "failed")
			failed_count += 1
			return
		if bool(task.get("distalBuildComplete", false)):
			var distal_visual: MultiMeshInstance3D = distal_factory.finish_runtime_distal_build(
				distal_build_state,
				recipe,
				String(request.get("biome", "forest"))
			)
			if distal_visual != null:
				wood_root.add_child(distal_visual)
				_append_section_value_member(task, distal_visual, "branches")
			# The visual now owns the MultiMesh. Release the detached builder and
			# the typed branch projection before this stage returns, not when the
			# completed task dictionary is later destroyed outside the budget.
			task.erase("distalBuildState")
			task.erase("typedBranches")
			task["renderStage"] = "foliage"
			publication_stage_counts["distal"] = int(publication_stage_counts.get("distal", 0)) + 1
			continue_publication_task(task)
			return
		var distal_complete: bool = bool(distal_factory.advance_runtime_distal_build(distal_build_state, MAX_DISTAL_INSTANCES_PER_SLICE))
		task["distalBuildState"] = distal_build_state
		if not distal_complete:
			continue_publication_task(task)
			return
		task["distalBuildComplete"] = true
		continue_publication_task(task)
		return
	if stage == "foliage":
		var foliage_factory = publication_service.get_visual_factory()
		if not task.has("foliageBuildState"):
			var initial_foliage_build_state: Dictionary = foliage_factory.begin_runtime_foliage_build(
				recipe,
				recipe.get("foliage", []),
				String(request.get("biome", "forest")),
				String(request.get("treeId", "procedural-tree"))
			)
			if initial_foliage_build_state.is_empty():
				task["renderStage"] = "commit"
				continue_publication_task(task)
				return
			task["foliageBuildState"] = initial_foliage_build_state
			continue_publication_task(task)
			return
		var foliage_build_state: Dictionary = task.get("foliageBuildState", {})
		if foliage_build_state.is_empty():
			body.set_meta("tree_visual_state", "failed")
			failed_count += 1
			return
		if bool(task.get("foliageBuildComplete", false)):
			var foliage_visual: Node3D = foliage_factory.finish_runtime_foliage_build(
				foliage_build_state,
				recipe,
				String(request.get("biome", "forest"))
			) as Node3D
			if foliage_visual != null:
				visual.add_child(foliage_visual)
				if foliage_visual.get_child_count() == 1 \
						and foliage_visual.get_child(0) is MultiMeshInstance3D:
					_append_section_value_member(task,
						foliage_visual.get_child(0) as MultiMeshInstance3D, "foliage")
			# Same ownership transfer as the wood stages: the attached node owns
			# the finished MultiMesh, so retire the detached state while this timed
			# finalization slice is active.
			task.erase("foliageBuildState")
			task["renderStage"] = "commit"
			publication_stage_counts["foliage"] = int(publication_stage_counts.get("foliage", 0)) + 1
			continue_publication_task(task)
			return
		var foliage_complete: bool = bool(foliage_factory.advance_runtime_foliage_build(foliage_build_state, MAX_FOLIAGE_INSTANCES_PER_SLICE))
		task["foliageBuildState"] = foliage_build_state
		if not foliage_complete:
			continue_publication_task(task)
			return
		task["foliageBuildComplete"] = true
		continue_publication_task(task)
		return
	if stage == "commit" and section_owned_publication_enabled:
		var sealed := seal_prepared_section_value_record(task, body)
		if sealed.get("status") == "ready":
			var retained := retain_prepared_section_value_record(sealed.record)
			if retained.get("status") == "retained":
				body.set_meta("tree_visual_state", "section_candidate_pending")
				body.set_meta("tree_recipe_signature", String(sealed.record.get(
					"recipeSignature", "")))
				body.set_meta("tree_render_lod_tier", String(sealed.record.get("tier", "")))
				# Renderer resources now live in the sealed value artifact. Drop only
				# this detached scene graph; keep the gameplay body, its collision,
				# and any previously accepted per-tree visual until receipt.
				if visual.get_parent() == null:
					visual.free()
				tree_section_values_prepared.emit(body)
				return
	commit_published_visual(task, body, visual, request, recipe)

func commit_published_visual(task: Dictionary, body: StaticBody3D, visual: Node3D,
		request: Dictionary, recipe: Dictionary, keep_chunk_batch := false) -> void:
	var prior_visual := body.get_node_or_null("GeneratedTreeVisual") as Node3D
	if prior_visual != null and is_instance_valid(prior_visual):
		body.remove_child(prior_visual)
		prior_visual.queue_free()
	if visual != null:
		body.add_child(visual)
	# The replacement chunk slot is installed before this method is called. Keep
	# it through commit for the impostor tier; all other tiers retire the waiting
	# silhouette after their per-tree visual is attached.
	record_first_collision_visible(body, "chunk_tree_impostor" if keep_chunk_batch else "procedural_tree_recipe")
	release_collision_visibility_proxy(body)
	if not keep_chunk_batch:
		release_horizon_visible_representation(body)
		release_chunk_static_visual(body)
	body.set_meta("visual_source", "chunk_tree_impostor" if keep_chunk_batch else "procedural_tree_recipe")
	body.set_meta("visual_asset_id", "procedural:%s" % String(request.get("speciesGrammar", "tree")))
	body.set_meta("tree_recipe_signature", String(recipe.get("signature", "")))
	body.set_meta("tree_branch_count", int(recipe.get("branchCount", 0)))
	body.set_meta("tree_foliage_cluster_count", int(recipe.get("foliageClusterCount", 0)))
	body.set_meta("tree_render_lod_tier", String((recipe.get("renderLod", {}) as Dictionary).get("tier", "near")))
	body.set_meta("tree_crown_habit", String(recipe.get("crownHabit", "natural")))
	body.set_meta("tree_visual_state", "published")
	body.set_meta("tree_visual_queue_wait_usec", Time.get_ticks_usec() - int(task.get("enqueuedUsec", Time.get_ticks_usec())))
	replace_published_render_stats(body, recipe)
	published_count += 1
	remember_published_lod(body, request, task.get("sectionValueMembers", []), recipe)
	publication_stage_counts["commit"] = int(publication_stage_counts.get("commit", 0)) + 1
	tree_visual_published.emit(body, recipe)


## Capture renderer inputs at the producer handoff, while the queue still owns
## the exact completed geometry. Later section consumers read this sealed value
## record instead of treating a scene-tree traversal as the source of truth.
func _append_section_value_member(task: Dictionary, instance: GeometryInstance3D,
		role: String) -> void:
	var tree_visual: Node3D = task.get("visual", null) as Node3D
	var captured := capture_section_value_member(instance, role, tree_visual)
	if captured.get("status") != "ready":
		task["sectionValueCapturePending"] = String(captured.get("reason", "unknown"))
		return
	var members: Array = task.get("sectionValueMembers", [])
	members.append(captured.member)
	task["sectionValueMembers"] = members


func capture_section_value_member(instance: GeometryInstance3D, role: String,
		tree_visual: Node3D = null) -> Dictionary:
	if not is_instance_valid(instance) or not is_instance_valid(tree_visual) \
			or role not in ["bole", "branches", "foliage"]:
		return {"status":"pending", "reason":"tree_section_member_owner_missing"}
	var member_to_tree := _transform_relative_to_root(instance, tree_visual)
	if member_to_tree.get("status") != "ready":
		return member_to_tree
	var mesh: Mesh
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var custom_values: Array[Color] = []
	if instance is MeshInstance3D:
		var mesh_instance := instance as MeshInstance3D
		mesh = mesh_instance.mesh
		# The full node path is carried by localTransform below. Keep the
		# per-instance lane identity for a non-instanced MeshInstance.
		transforms.append(Transform3D.IDENTITY)
		colors.append(Color.WHITE)
		custom_values.append(Color(0.0, 0.0, 0.0, 1.0))
	elif instance is MultiMeshInstance3D:
		var multi_instance := instance as MultiMeshInstance3D
		var multi_mesh := multi_instance.multimesh
		if multi_mesh == null or not multi_mesh.use_custom_data \
				or multi_mesh.transform_format != MultiMesh.TRANSFORM_3D:
			return {"status":"pending", "reason":"tree_section_multimesh_layout_unsupported"}
		mesh = multi_mesh.mesh
		for index: int in range(multi_mesh.instance_count):
			transforms.append(multi_mesh.get_instance_transform(index))
			colors.append(multi_mesh.get_instance_color(index) if multi_mesh.use_colors else Color.WHITE)
			custom_values.append(multi_mesh.get_instance_custom_data(index))
	else:
		return {"status":"pending", "reason":"tree_section_member_type_unsupported"}
	if not is_instance_valid(mesh) or transforms.is_empty() or instance.material_override == null:
		return {"status":"pending", "reason":"tree_section_member_resources_missing"}
	transforms.make_read_only()
	colors.make_read_only()
	custom_values.make_read_only()
	var member := {"schema":"tree-section-render-member/v1", "role":role,
		"mesh":mesh, "material":instance.material_override,
		"localTransform":member_to_tree.transform, "transforms":transforms,
		"colors":colors, "customData":custom_values,
		"producerElementCount":int(instance.get_meta("tree_wood_segment_count", -1)),
		"visibilityRangeEnd":float(instance.visibility_range_end),
		"fadeMargin":float(instance.visibility_range_end_margin),
		"castShadows":instance.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF}
	member.make_read_only()
	return {"status":"ready", "member":member}


func _transform_relative_to_root(instance: Node3D, root: Node3D) -> Dictionary:
	var accumulated := Transform3D.IDENTITY
	var current := instance
	while current != root:
		accumulated = current.transform * accumulated
		var parent_value: Variant = current.get_parent()
		if not parent_value is Node3D:
			return {"status":"pending", "reason":"tree_section_member_outside_visual_root"}
		current = parent_value as Node3D
	accumulated = root.transform * accumulated
	return {"status":"ready", "transform":accumulated}


func _freeze_section_value(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value:
			result[key] = _freeze_section_value(value[key])
		result.make_read_only()
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(_freeze_section_value(item))
		result.make_read_only()
		return result
	return value

func replace_published_render_stats(body: StaticBody3D, recipe: Dictionary) -> void:
	if body == null or not is_instance_valid(body):
		return
	var body_instance_id := body.get_instance_id()
	remove_published_render_stats(body_instance_id)
	var render_metrics := recipe_render_metrics(recipe)
	var lod_tier := String((recipe.get("renderLod", {}) as Dictionary).get("tier", "near"))
	var entry := {
		"lodTier": lod_tier,
		"branchInstances": int(recipe.get("branchCount", 0)),
		"foliageInstances": int(recipe.get("foliageClusterCount", 0)),
		"estimatedDrawCalls": int(render_metrics.get("drawCalls", 0)),
		"estimatedTriangles": int(render_metrics.get("triangles", 0)),
		"estimatedShadowTriangles": int(render_metrics.get("shadowTriangles", 0))
	}
	published_render_stats[body_instance_id] = entry
	published_render_totals["visibleTrees"] = int(published_render_totals.get("visibleTrees", 0)) + 1
	published_render_totals["branchInstances"] = int(published_render_totals.get("branchInstances", 0)) + int(entry.get("branchInstances", 0))
	published_render_totals["foliageInstances"] = int(published_render_totals.get("foliageInstances", 0)) + int(entry.get("foliageInstances", 0))
	published_render_totals["estimatedDrawCalls"] = int(published_render_totals.get("estimatedDrawCalls", 0)) + int(entry.get("estimatedDrawCalls", 0))
	published_render_totals["estimatedTriangles"] = int(published_render_totals.get("estimatedTriangles", 0)) + int(entry.get("estimatedTriangles", 0))
	published_render_totals["estimatedShadowTriangles"] = int(published_render_totals.get("estimatedShadowTriangles", 0)) + int(entry.get("estimatedShadowTriangles", 0))
	var lod_distribution: Dictionary = published_render_totals.get("lodDistribution", {})
	lod_distribution[lod_tier] = int(lod_distribution.get(lod_tier, 0)) + 1
	published_render_totals["lodDistribution"] = lod_distribution

func recipe_render_metrics(recipe: Dictionary) -> Dictionary:
	var render_lod: Dictionary = recipe.get("renderLod", {})
	var lod_tier := String(render_lod.get("tier", "near"))
	if lod_tier == "impostor":
		return {
			"drawCalls": 3,
			"triangles": ESTIMATED_IMPOSTOR_TRIANGLES,
			"shadowTriangles": 0
		}
	var branches: Array = recipe.get("branches", [])
	var structural_segments := 0
	for branch_value in branches:
		if branch_value is Dictionary and int((branch_value as Dictionary).get("order", 1)) == 0:
			structural_segments += 1
	var distal_segments := maxi(0, branches.size() - structural_segments)
	var foliage_clusters := int(recipe.get("foliageClusterCount", 0))
	var draw_calls := 0
	if structural_segments > 0:
		draw_calls += 1
	if distal_segments > 0:
		draw_calls += 1
	if foliage_clusters > 0:
		draw_calls += 1
	var triangles := structural_segments * ESTIMATED_RUNTIME_BOLE_TRIANGLES_PER_SEGMENT \
		+ distal_segments * ESTIMATED_SHARED_BRANCH_TRIANGLES \
		+ foliage_clusters * ESTIMATED_RUNTIME_FOLIAGE_CLUSTER_TRIANGLES
	return {
		"drawCalls": draw_calls,
		"triangles": triangles,
		"shadowTriangles": triangles if VisualFactoryScript.recipe_casts_shadows(recipe) else 0
	}

func remove_published_render_stats(body_instance_id: int) -> void:
	if body_instance_id <= 0:
		return
	var prior: Dictionary = published_render_stats.get(body_instance_id, {})
	if prior.is_empty():
		return
	published_render_stats.erase(body_instance_id)
	published_render_totals["visibleTrees"] = maxi(0, int(published_render_totals.get("visibleTrees", 0)) - 1)
	for key in ["branchInstances", "foliageInstances", "estimatedDrawCalls", "estimatedTriangles", "estimatedShadowTriangles"]:
		published_render_totals[key] = maxi(0, int(published_render_totals.get(key, 0)) - int(prior.get(key, 0)))
	var lod_tier := String(prior.get("lodTier", "near"))
	var lod_distribution: Dictionary = published_render_totals.get("lodDistribution", {})
	lod_distribution[lod_tier] = maxi(0, int(lod_distribution.get(lod_tier, 0)) - 1)
	published_render_totals["lodDistribution"] = lod_distribution

func record_publication_work(stage: String, elapsed_usec: int) -> void:
	var bounded_elapsed_usec := maxi(0, elapsed_usec)
	publication_work_sample_cursor = append_bounded_timing_sample(
		publication_work_samples_usec,
		publication_work_sample_cursor,
		bounded_elapsed_usec
	)
	var stage_samples: Array = publication_stage_samples_usec.get(stage, [])
	var stage_cursor := int(publication_stage_sample_cursors.get(stage, 0))
	stage_cursor = append_bounded_timing_sample(stage_samples, stage_cursor, bounded_elapsed_usec)
	publication_stage_samples_usec[stage] = stage_samples
	publication_stage_sample_cursors[stage] = stage_cursor
	# High-water rather than an average is deliberate: a renderer/resource
	# allocation can spike within one stage, and the subsequent frame must leave
	# enough room for that real cost instead of assuming the mean is safe.
	var prior_estimate := int(publication_stage_estimates_usec.get(stage, MAX_PUBLICATION_WORK_USEC_PER_FRAME))
	var observed_estimate := mini(
		MAX_PUBLICATION_WORK_USEC_PER_FRAME,
		bounded_elapsed_usec + PUBLICATION_STAGE_SAFETY_MARGIN_USEC
	)
	publication_stage_estimates_usec[stage] = observed_estimate if prior_estimate >= MAX_PUBLICATION_WORK_USEC_PER_FRAME else maxi(prior_estimate, observed_estimate)

func estimated_stage_cost_usec(stage: String) -> int:
	return clampi(
		int(publication_stage_estimates_usec.get(stage, MAX_PUBLICATION_WORK_USEC_PER_FRAME)),
		1,
		MAX_PUBLICATION_WORK_USEC_PER_FRAME
	)

func release_staged_visual(task: Dictionary) -> void:
	var visual: Node3D = task.get("visual", null) as Node3D
	if visual != null and is_instance_valid(visual):
		# A tree can stream out after several publication slices. Mark its
		# detached partial visual for Godot's deferred lifecycle rather than
		# synchronously destroying a dense MultiMesh while the player is moving.
		# It has never been attached to the prop body, so this cannot alter
		# collision, interaction, drops, or save state.
		visual.queue_free()

func publication_timing() -> Dictionary:
	if publication_work_samples_usec.is_empty():
		return {"sampleCount": 0, "p50Usec": 0, "p95Usec": 0, "p99Usec": 0, "maxUsec": 0}
	var sorted: Array[int] = publication_work_samples_usec.duplicate()
	sorted.sort()
	return {
		"sampleCount": sorted.size(),
		"p50Usec": timing_percentile(sorted, 0.50),
		"p95Usec": timing_percentile(sorted, 0.95),
		"p99Usec": timing_percentile(sorted, 0.99),
		"maxUsec": sorted.back()
	}

func publication_frame_timing() -> Dictionary:
	if publication_frame_samples_usec.is_empty():
		return {"sampleCount": 0, "p50Usec": 0, "p95Usec": 0, "p99Usec": 0, "maxUsec": 0}
	var sorted: Array[int] = publication_frame_samples_usec.duplicate()
	sorted.sort()
	return {
		"sampleCount": sorted.size(),
		"p50Usec": timing_percentile(sorted, 0.50),
		"p95Usec": timing_percentile(sorted, 0.95),
		"p99Usec": timing_percentile(sorted, 0.99),
		"maxUsec": sorted.back()
	}

func publication_scheduler_timing() -> Dictionary:
	if publication_scheduler_samples_usec.is_empty():
		return {"sampleCount": 0, "p50Usec": 0, "p95Usec": 0, "p99Usec": 0, "maxUsec": 0}
	var sorted: Array[int] = publication_scheduler_samples_usec.duplicate()
	sorted.sort()
	return {
		"sampleCount": sorted.size(),
		"p50Usec": timing_percentile(sorted, 0.50),
		"p95Usec": timing_percentile(sorted, 0.95),
		"p99Usec": timing_percentile(sorted, 0.99),
		"maxUsec": sorted.back()
	}

func publication_validation_timing() -> Dictionary:
	return timing_summary(publication_validation_samples_usec)

func publication_bookkeeping_timing() -> Dictionary:
	if publication_bookkeeping_samples_usec.is_empty():
		return {"sampleCount": 0, "p50Usec": 0, "p95Usec": 0, "p99Usec": 0, "maxUsec": 0}
	var sorted: Array[int] = publication_bookkeeping_samples_usec.duplicate()
	sorted.sort()
	return {
		"sampleCount": sorted.size(),
		"p50Usec": timing_percentile(sorted, 0.50),
		"p95Usec": timing_percentile(sorted, 0.95),
		"p99Usec": timing_percentile(sorted, 0.99),
		"maxUsec": sorted.back()
	}

func publication_reporting_timing() -> Dictionary:
	return timing_summary(publication_reporting_samples_usec)

func publication_unattributed_timing() -> Dictionary:
	return timing_summary(publication_unattributed_samples_usec)

func publication_loop_tail_timing() -> Dictionary:
	return timing_summary(publication_loop_tail_samples_usec)

func timing_summary(samples: Array) -> Dictionary:
	if samples.is_empty():
		return {"sampleCount": 0, "p50Usec": 0, "p95Usec": 0, "p99Usec": 0, "maxUsec": 0}
	var sorted: Array = samples.duplicate()
	sorted.sort()
	return {
		"sampleCount": sorted.size(),
		"p50Usec": timing_percentile(sorted, 0.50),
		"p95Usec": timing_percentile(sorted, 0.95),
		"p99Usec": timing_percentile(sorted, 0.99),
		"maxUsec": sorted.back()
	}

func record_publication_scheduler_work(elapsed_usec: int) -> void:
	publication_scheduler_sample_cursor = append_bounded_timing_sample(
		publication_scheduler_samples_usec,
		publication_scheduler_sample_cursor,
		maxi(0, elapsed_usec)
	)

func record_publication_validation(elapsed_usec: int) -> void:
	publication_validation_sample_cursor = append_bounded_timing_sample(
		publication_validation_samples_usec,
		publication_validation_sample_cursor,
		maxi(0, elapsed_usec)
	)

func record_publication_bookkeeping(elapsed_usec: int) -> void:
	publication_bookkeeping_sample_cursor = append_bounded_timing_sample(
		publication_bookkeeping_samples_usec,
		publication_bookkeeping_sample_cursor,
		maxi(0, elapsed_usec)
	)

func record_publication_reporting(elapsed_usec: int) -> void:
	publication_reporting_sample_cursor = append_bounded_timing_sample(
		publication_reporting_samples_usec,
		publication_reporting_sample_cursor,
		maxi(0, elapsed_usec)
	)

func record_publication_unattributed(elapsed_usec: int) -> void:
	publication_unattributed_sample_cursor = append_bounded_timing_sample(
		publication_unattributed_samples_usec,
		publication_unattributed_sample_cursor,
		maxi(0, elapsed_usec)
	)

func record_publication_loop_tail(elapsed_usec: int) -> void:
	publication_loop_tail_sample_cursor = append_bounded_timing_sample(
		publication_loop_tail_samples_usec,
		publication_loop_tail_sample_cursor,
		maxi(0, elapsed_usec)
	)

func record_worst_publication_frame(
	elapsed_usec: int,
	stage: String,
	scheduler_usec: int,
	validation_usec: int,
	stage_usec: int,
	reporting_usec: int,
	unattributed_usec: int,
	loop_tail_usec: int,
	completed_before: int
) -> void:
	if elapsed_usec <= int(worst_publication_frame.get("elapsedUsec", 0)):
		return
	worst_publication_frame = {
		"elapsedUsec": elapsed_usec,
		"stage": stage,
		"schedulerUsec": scheduler_usec,
		"validationUsec": validation_usec,
		"stageUsec": stage_usec,
		"reportingUsec": reporting_usec,
		"unattributedUsec": unattributed_usec,
		"loopTailUsec": loop_tail_usec,
		"completedBefore": completed_before,
		"pending": pending_tasks.size()
	}

func append_bounded_timing_sample(samples: Array, cursor: int, value: int) -> int:
	if samples.size() < PUBLICATION_TIMING_SAMPLE_LIMIT:
		samples.append(value)
		return 0
	var write_index := posmod(cursor, PUBLICATION_TIMING_SAMPLE_LIMIT)
	samples[write_index] = value
	return posmod(write_index + 1, PUBLICATION_TIMING_SAMPLE_LIMIT)

func publication_stage_timing() -> Dictionary:
	var result := {}
	for stage_value in publication_stage_samples_usec.keys():
		var stage := String(stage_value)
		var raw: Array = publication_stage_samples_usec.get(stage, [])
		if raw.is_empty():
			result[stage] = {"sampleCount": 0, "p50Usec": 0, "p95Usec": 0, "p99Usec": 0, "maxUsec": 0}
			continue
		var sorted: Array = raw.duplicate()
		sorted.sort()
		result[stage] = {
			"sampleCount": sorted.size(),
			"p50Usec": timing_percentile(sorted, 0.50),
			"p95Usec": timing_percentile(sorted, 0.95),
			"p99Usec": timing_percentile(sorted, 0.99),
			"maxUsec": sorted.back()
		}
	return result

func timing_percentile(sorted: Array, fraction: float) -> int:
	if sorted.is_empty():
		return 0
	var index := clampi(ceili(float(sorted.size()) * fraction) - 1, 0, sorted.size() - 1)
	return sorted[index]

func metrics() -> Dictionary:
	return {
		"pending": pending_tasks.size(),
		"activeWorkers": active.size(),
		"completed": completed_count + (1 if not staged_publication_task.is_empty() else 0),
		"queued": queued_count,
		"published": published_count,
		"dropped": dropped_count,
		"cancelled": cancelled_count,
		"failed": failed_count,
		"recipeCache": recipe_cache.metrics(),
		"recipeCacheReused": recipe_cache_reused_count,
		"lodRecipeDerivation": {
			"requested": lod_recipe_derivation_requested_count,
			"completed": lod_recipe_derivation_completed_count
		},
		"lod": {
			"trackedTrees": published_lod_records.size(),
			"rebuilds": lod_rebuild_count,
			"maxReevaluationsPerFrame": MAX_LOD_REEVALUATIONS_PER_FRAME
		},
		"render": published_render_totals.duplicate(true),
		"priorityScheduling": {
			"enabled": true,
			"queuedWithViewerPriority": priority_scheduled_count,
			"preemptedDetachedTasks": preempted_publication_count,
			"ageScaleSeconds": PUBLICATION_PRIORITY_AGE_SCALE_SECONDS,
			"spatialCellSize": COMPLETED_PRIORITY_CELL_SIZE,
			"localCellRadius": COMPLETED_PRIORITY_LOCAL_CELL_RADIUS,
			"selectionCount": priority_selection_count,
			"selectionCandidateTotal": priority_selection_candidate_total,
			"maxSelectionCandidates": priority_selection_max_candidates,
			"fullFallbackSelections": priority_selection_full_fallback_count,
			"viewlessFifoSelections": priority_selection_viewless_fifo_count,
			"directionalPublicationSelections": directional_publication_selection_count,
			"directionalPreemptions": directional_preemption_count,
			"directionalWorkerSelections": directional_worker_selection_count,
			"viewerHeadingConfidentFrames": viewer_heading_confident_frame_count,
			"viewerHeadingFallbackFrames": viewer_heading_fallback_frame_count,
			"lookaheadSeconds": VIEWER_MOTION_LOOKAHEAD_SECONDS,
			"maxLookaheadDistance": VIEWER_MOTION_MAX_LOOKAHEAD_DISTANCE,
			"forwardCorridorMaxHalfWidth": FORWARD_CORRIDOR_MAX_HALF_WIDTH,
			"selectionTiming": priority_selection_timing()
		},
		"collisionVisibility": {
			"proxyDistance": COLLISION_VISIBILITY_PROXY_DISTANCE,
			"proxyAttachments": collision_visibility_proxy_attach_count,
			"proxyReleases": collision_visibility_proxy_release_count,
			"activeProxies": collision_visibility_proxy_active_count,
			"peakActiveProxies": collision_visibility_proxy_peak_count,
			"averageProxyLifetimeUsec": float(collision_visibility_proxy_lifetime_total_usec) / float(maxi(1, collision_visibility_proxy_release_count)),
			"maxProxyLifetimeUsec": collision_visibility_proxy_lifetime_max_usec,
			"firstVisibleCount": collision_to_first_visible_count,
			"averageRelevantCollisionToFirstVisibleLagUsec": float(collision_to_first_visible_total_lag_usec) / float(maxi(1, collision_to_first_visible_count)),
			"maxRelevantCollisionToFirstVisibleLagUsec": collision_to_first_visible_max_lag_usec,
			"collisionBeforeVisualInvariantBreaches": collision_before_visual_invariant_breach_count
		},
		"workerPriorityScheduling": {
			"enabled": true,
			"queueModel": "indexed_local_priority_fifo_fairness",
			"spatialCellSize": COMPLETED_PRIORITY_CELL_SIZE,
			"localCellRadius": COMPLETED_PRIORITY_LOCAL_CELL_RADIUS,
			"selectionCount": worker_priority_selection_count,
			"selectionCandidateTotal": worker_priority_selection_candidate_total,
			"maxSelectionCandidates": worker_priority_selection_max_candidates,
			"fullFallbackSelections": worker_priority_selection_full_fallback_count,
			"selectionTiming": worker_priority_selection_timing()
		},
		"maxActiveWorkers": MAX_ACTIVE_WORKERS,
		"maxPublicationWorkUnitsPerFrame": MAX_PUBLICATION_WORK_UNITS_PER_FRAME,
		"maxPublicationWorkUsecPerFrame": MAX_PUBLICATION_WORK_USEC_PER_FRAME,
		"stageCounts": publication_stage_counts.duplicate(),
		"stageEstimatedUsec": publication_stage_estimates_usec.duplicate(),
		"publicationTiming": publication_timing(),
		"publicationFrameTiming": publication_frame_timing(),
		"publicationSchedulerTiming": publication_scheduler_timing(),
		"publicationValidationTiming": publication_validation_timing(),
		"publicationBookkeepingTiming": publication_bookkeeping_timing(),
		"publicationReportingTiming": publication_reporting_timing(),
		"publicationUnattributedTiming": publication_unattributed_timing(),
		"publicationLoopTailTiming": publication_loop_tail_timing(),
		"publicationWorstFrame": worst_publication_frame.duplicate(),
		"publicationStageTiming": publication_stage_timing()
	}

func _exit_tree() -> void:
	# Godot requires joining started threads before their wrappers are released.
	# Workers build bounded pure data only; they never access scene objects.
	for task in active:
		var thread := task.get("thread") as Thread
		if thread != null and thread.is_started():
			thread.wait_to_finish()
	if not staged_publication_task.is_empty():
		release_staged_visual(staged_publication_task)
	for task_index in range(completed_head, completed.size()):
		release_staged_visual(completed[task_index])
