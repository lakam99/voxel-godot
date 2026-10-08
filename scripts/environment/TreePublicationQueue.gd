extends Node
class_name TreePublicationQueue

var _presentation_coordinator: WeakRef
# Indexes address the existing owned records; they never establish readiness.
var _published_record_index_by_body: Dictionary = {}
var _source_record_by_body: Dictionary = {}

func _published_record_for_body_id(body_id: int) -> Dictionary:
	var index := int(_published_record_index_by_body.get(body_id, -1))
	if index < 0 or index >= published_lod_records.size(): return {}
	var record: Dictionary = published_lod_records[index]
	return record if int(record.get("bodyInstanceId", 0)) == body_id else {}

func _remove_published_record_at(index: int) -> void:
	_published_record_index_by_body.erase(int(published_lod_records[index].get("bodyInstanceId", 0)))
	published_lod_records.remove_at(index)
	for shifted in range(index, published_lod_records.size()):
		_published_record_index_by_body[int(published_lod_records[shifted].get("bodyInstanceId", 0))] = shifted

func _index_source_record(stage: String, record: Dictionary) -> void:
	var rows: Dictionary = _source_record_by_body.get(stage, {})
	rows[int(record.get("bodyInstanceId", 0))] = record
	_source_record_by_body[stage] = rows

func _unindex_source_record(stage: String, record: Dictionary) -> void:
	var rows: Dictionary = _source_record_by_body.get(stage, {})
	var body_id := int(record.get("bodyInstanceId", 0))
	var current: Dictionary = rows.get(body_id, {})
	# Old compiled generations may retire after the current one was indexed.
	if not current.is_empty() and is_same(current, record): rows.erase(body_id)
	if rows.is_empty(): _source_record_by_body.erase(stage)

func _source_record_for_body(stage: String, body: StaticBody3D) -> Dictionary:
	if not is_instance_valid(body): return {}
	var record: Dictionary = _source_record_by_body.get(stage, {}).get(body.get_instance_id(), {})
	var reference: Variant = record.get("body")
	return record if reference is WeakRef and reference.get_ref() == body else {}

func bind_presentation_coordinator(coordinator: Object) -> bool:
	if not is_instance_valid(coordinator) or not coordinator.has_method("installed_section_contains_source") \
			or not coordinator.has_method("installed_section_receipt_is_current"): return false
	if _presentation_coordinator != null and is_instance_valid(_presentation_coordinator.get_ref()) \
			and _presentation_coordinator.get_ref() != coordinator: return false
	_presentation_coordinator = weakref(coordinator)
	return true

## Read-only query. Preparation is not installation. The accepted record remains
## independent from an in-flight LOD replacement's producer generation.
func tree_publication_proof(body_value: Variant, include_installed := true) -> Dictionary:
	if not is_instance_valid(body_value) or not body_value is StaticBody3D:
		return {"status":"failed", "reason":"tree_publication_owner_lost"}
	var body: StaticBody3D = body_value
	if not body.has_meta("tree_publication_owner"):
		return {"status":"failed", "reason":"tree_publication_authority_missing"}
	var owner_reference: Variant = body.get_meta("tree_publication_owner")
	if not owner_reference is WeakRef or owner_reference.get_ref() != self:
		return {"status":"failed", "reason":"tree_publication_authority_replaced"}
	if not body.is_inside_tree() or body.is_queued_for_deletion() \
			or bool(body.get_meta("tree_publication_cancelled", false)):
		return {"status":"failed", "reason":"tree_publication_owner_inactive"}
	var prepared := tree_section_recipe_input_record_for_body(body)
	if prepared.is_empty(): prepared = prepared_section_value_record_for_body(body)
	var prepared_current := _presentation_source_current(prepared, body, true)
	var accepted := _published_record_for_body_id(body.get_instance_id())
	var accepted_source: bool = _presentation_source_current(accepted, body, false) \
		and not String(accepted.get("recipeIdentityKey", "")).is_empty() \
		and accepted.get("recipeIdentityKey") == accepted.get("expectedRecipeIdentityKey")
	if String(body.get_meta("tree_visual_state", "")) == "failed" and not accepted_source:
		return {"status":"failed", "reason":"tree_publication_failed"}
	prepared_current = prepared_current or accepted_source
	var installed := include_installed and _accepted_presentation_current(accepted, body)
	return {"status":"ready" if installed or prepared_current else "pending",
		"reason":"" if installed or prepared_current else "tree_source_preparation_pending",
		"bodyInstanceId":body.get_instance_id(), "propId":String(body.get_meta("prop_id", "")),
		"sourcePrepared":prepared_current or installed,
		"preparedRevision":String(prepared.get("contentRevision", prepared.get("recipeArtifactRevision", ""))),
		"installed":installed, "representation":String(accepted.get("presentationKind", "")) if installed else "",
		"tier":String(accepted.get("tier", "")), "recipeSignature":String(accepted.get("recipeSignature", ""))}

func visual_receipt_installed(source_identity: String, source_revision: String,
		world_revision: String, view_revision: int, candidate_id: String,
		metadata: Dictionary, representation_id: String, tier: String) -> bool:
	if source_identity.is_empty() or source_revision.is_empty() or world_revision.is_empty() \
			or view_revision <= 0 or representation_id != candidate_id + ":tree-publication": return false
	var body_id := int(metadata.get("candidateBodyInstanceId", 0))
	var record := _published_record_for_body_id(body_id)
	var reference: Variant = record.get("body")
	var body: Variant = reference.get_ref() if reference is WeakRef else null
	if not is_instance_valid(body): return false
	var proof := tree_publication_proof(body)
	return bool(proof.get("installed", false)) and proof.get("propId") == candidate_id \
		and proof.get("recipeSignature") == metadata.get("treeRecipeSignature") \
		and (tier == "horizon" or proof.get("tier") == "near")

## Capture the actual retained compiler artifact without translating its source
## identity. Providers may name a contributor differently, but must retain this
## exact producer identity alongside that alias through installation and ACK.
func capture_section_source(body_value: Variant, world_seed: String) -> Dictionary:
	if not is_instance_valid(body_value) or not body_value is StaticBody3D:
		return {"status":"pending", "reason":"tree_source_owner_unavailable"}
	var body: StaticBody3D = body_value
	var proof := tree_publication_proof(body, false)
	if not bool(proof.get("sourcePrepared", false)): return proof
	var compiled := compiled_tree_section_record_for_body(body)
	if compiled.is_empty():
		return {"status":"pending", "reason":"tree_source_compile_pending", "retryable":true}
	var input: Dictionary = compiled.get("record", {})
	var output: Dictionary = compiled.get("compiled", {})
	if not compiled.is_read_only() or not output.is_read_only() \
			or not _presentation_source_current(input, body, true) \
			or String(input.get("worldSeed", "")) != world_seed \
			or String(compiled.get("contentRevision", "")) != String(input.get("contentRevision", "")):
		return {"status":"pending", "reason":"tree_source_compile_stale", "retryable":true}
	var source_id := String(input.get("sourceId", ""))
	var manifest: Dictionary = {}
	for value: Variant in output.get("sources", []):
		if value is Dictionary and value.get("sourceId") == source_id:
			if not manifest.is_empty():
				return {"status":"failed", "reason":"tree_source_compile_ambiguous"}
			manifest = value
	if manifest.is_empty() or not manifest.is_read_only() \
			or String(manifest.get("sourceRevision", "")).is_empty() \
			or String(manifest.get("compiledAttributeDigest", "")).is_empty():
		return {"status":"pending", "reason":"tree_source_compile_manifest_unavailable"}
	var captured := {"status":"ready", "producerSourceId":source_id,
		"producerRevision":String(input.get("contentRevision", "")),
		"compiledSourceRevision":String(manifest.sourceRevision),
		"body":weakref(body), "bodyInstanceId":body.get_instance_id(),
		"bodyGlobalTransform":body.global_transform, "propId":String(input.get("propId", "")),
		"queue":weakref(self), "queueInstanceId":get_instance_id(),
		"input":input, "compiledRecord":compiled, "sourceManifest":manifest}
	captured.make_read_only()
	return captured

func _presentation_source_current(record: Dictionary, body: StaticBody3D,
		require_current_generation: bool) -> bool:
	var request: Variant = record.get("request")
	if record.is_empty() or not request is Dictionary \
			or int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
			or String(record.get("propId", "")) != String(body.get_meta("prop_id", "")) \
			or String(body.get_meta("static_ecology_source_id", "")) != "%s:tree:%s" % [
				String(record.get("worldSeed", "")), String(record.get("propId", ""))] \
			or record.get("bodyGlobalTransform") != body.global_transform: return false
	return not require_current_generation or int(record.get("producerGeneration", 0)) == int(
		body.get_meta("tree_section_recipe_input_expected_generation", -1))

func _accepted_presentation_current(record: Dictionary, body: StaticBody3D) -> bool:
	if not _presentation_source_current(record, body, false): return false
	if String(record.get("recipeIdentityKey", "")).is_empty() or record.get("recipeIdentityKey") \
			!= record.get("expectedRecipeIdentityKey"): return false
	var signature := String(record.get("recipeSignature", ""))
	if signature.is_empty(): return false
	var witness: Dictionary = record.get("presentationWitness", {})
	match String(record.get("presentationKind", "")):
		"legacy_mesh":
			# A mutable legacy mesh remains a visible fallback and a retained
			# producer source. Complete presentation is owned by a native slot or
			# shared section, never by repeated mesh-buffer readback here.
			return false
		"native_impostor":
			var weak: Variant = witness.get("publisher")
			var publisher: Variant = weak.get_ref() if weak is WeakRef else null
			if not is_instance_valid(publisher) or not publisher.has_method("installed_snapshot") \
					or publisher.get_instance_id() != witness.get("publisherId"): return false
			var actual: Dictionary = publisher.call("installed_snapshot", body)
			return actual.get("status") == "ready" and actual == witness.get("snapshot") \
				and actual.get("recipeSignature") == signature
		"section":
			var alias_binding: Dictionary = witness.get("providerBinding", {})
			if not alias_binding.is_empty():
				var alias_reference: Variant = alias_binding.get("job")
				var alias_owner: Variant = alias_reference.get_ref() if alias_reference is WeakRef else null
				if not is_instance_valid(alias_owner) or not alias_owner.has_method("tree_section_alias_is_current") \
						or not bool(alias_owner.call("tree_section_alias_is_current", alias_binding)): return false
			var coordinator: Variant = _presentation_coordinator.get_ref() if _presentation_coordinator != null else null
			if not is_instance_valid(coordinator) or coordinator.get_instance_id() != witness.get("coordinatorId"): return false
			var sections: Variant = witness.get("sections")
			var receipts: Variant = witness.get("receipts")
			if not sections is Array or sections.is_empty() or not receipts is Dictionary \
					or receipts.size() != sections.size(): return false
			for key: Variant in sections:
				if not key is Vector3i or not receipts.get(key) is Dictionary: return false
				var receipt: Dictionary = receipts[key]
				if receipt.get("worldId") != witness.get("worldId") \
						or not coordinator.call("installed_section_receipt_is_current", key, receipt) \
						or not coordinator.call("installed_section_contains_source", key,
							String(witness.get("sourceId", "")), String(witness.get("sourceRevision", ""))): return false
			return true
	return false

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
const TreeRecipeSectionCompilerScript := preload("res://scripts/world/TreeRecipeSectionCompiler.gd")
const EcologyProducerDomainScript := preload("res://scripts/world/EcologyProducerDomain.gd")
const ActiveRemovedPropsSnapshotScript := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const CompiledTreeSectionArtifact := preload("res://scripts/world/CompiledTreeSectionArtifact.gd")
const OwnedValueArtifactRetirementScript := preload("res://scripts/world/OwnedValueArtifactRetirement.gd")
const TREE_SECTION_RECIPE_INPUT_SCHEMA := "tree-section-recipe-input/v1"
const TREE_SECTION_RECIPE_COMPILER_REVISION := "tree-recipe-section-compiler/v1"
const MAX_ACTIVE_WORKERS := 2
const MAX_SOURCE_RECIPE_PENDING := 256
const MAX_ECOLOGY_SOURCE_COMPILE_JOBS := 128
const ECOLOGY_SOURCE_COMPILE_WORK_UNITS_PER_JOB := 2
const MAX_TREE_BAND_COMPILE_JOBS := 128
const TREE_BAND_COMPILE_ADVANCES_PER_FRAME := 2
const TREE_BAND_PRIORITY_SCAN_LIMIT := 16
const TREE_BAND_PRIORITY_AGE_SCALE_SECONDS := 18.0
const SOURCE_RECIPE_SCHEMA := "ecology-tree-source-recipe-artifact/v1"
const TREE_SOURCE_RECORD_CACHE_REVISION := "tree-source-record-cache/v1"
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
const MAX_STARTUP_TREE_DIAGNOSTIC_ACK_RECORDS := 256
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
const TREE_SECTION_COMPILER_WORK_UNITS_PER_FRAME := 8

# Pending recipes use an indexed priority queue rather than sorting and
# shifting the entire stream-in backlog whenever a worker becomes free.  The
# graph work is still deterministic; only worker launch order follows the
# current viewer so a local tree does not wait behind a distant horizon.
var pending_tasks := {}
var pending_order: Array[int] = []
var pending_order_head := 0
var pending_spatial_buckets := {}
var active: Array[Dictionary] = []
## Node-free ecology source recipes share the existing worker service but keep
## their values and completion artifacts separate from body-backed visuals.
var source_recipe_jobs: Dictionary = {}
var source_publication_consumer_serial := 0
var source_recipe_pending_order: Array[String] = []
var source_recipe_workers: Array[Dictionary] = []
var source_recipe_completed: Dictionary = {}
var source_recipe_completed_order: Array[String] = []
## Source-domain compiles are independent jobs keyed by the sealed producer
## snapshot identity. Each compiler advances here, outside the adapter's
## census call, and keeps its result until its consumer releases the receipt.
var ecology_source_compile_jobs: Dictionary = {}
var ecology_source_compile_order: Array[String] = []
## Section-band tree jobs are distinct from whole source-domain compiles. The
## key includes the admitted band authority so sibling sections can progress
## independently while duplicate consumers share one immutable result.
var ecology_tree_band_compile_jobs: Dictionary = {}
var ecology_tree_band_compile_order: Array[String] = []
var ecology_tree_band_compile_cursor := 0
var ecology_tree_band_consumer_serial := 0
var ecology_tree_source_record_compile_start_count := 0
var ecology_tree_source_record_cache_reuse_count := 0
var ecology_tree_source_band_projection_count := 0
var ecology_tree_source_record_work_unit_count := 0
var ecology_tree_source_band_projection_usec := 0
## Large immutable tree value graphs retire on one persistent owned worker.
## RefCounted renderer/build handles remain on Main until each completion ACK.
var tree_value_retirement_owner = OwnedValueArtifactRetirementScript.new()
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
var tree_recipe_section_compiler = TreeRecipeSectionCompilerScript.new()
var native_tree_geometry_dispatcher: RefCounted
var active_tree_section_compile_record: Dictionary = {}
var legacy_tree_compiler_retirement_pending := false
var legacy_tree_compiler_retirement_roots: Array[Dictionary] = []
var legacy_tree_compiler_retirement_keepalives: Array[RefCounted] = []
var pending_compiled_section_retirement_records: Array[Dictionary] = []
var compiled_tree_section_records: Array[Dictionary] = []
var tree_section_compile_started_count := 0
var tree_section_compile_completed_count := 0
var tree_section_compile_stale_count := 0
var last_tree_section_compile_advance := {}
## Diagnostic-only indexes for the small set of exact tree candidates requested
## by startup. Production arrays remain authoritative and keep their existing
## scheduling order; index rows are removed alongside their source records.
var _startup_tree_diagnostic_records_by_id := {}
var _startup_tree_diagnostic_ack_by_id := {}
var _startup_tree_diagnostic_ack_order: Array[String] = []
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
	var normalized_request: Dictionary = publication_service.normalize_request(prepared_request)
	var selected_tier := selected_lod_tier_from_normalized(prepared_request, normalized_request)
	prepared_request["renderLodTier"] = selected_tier
	if not normalized_request.is_empty():
		normalized_request["renderLodTier"] = selected_tier
	var recipe_key := publication_service.recipe_cache_key_from_normalized(normalized_request)
	var recipe_identity_key := publication_service.recipe_identity_key_from_normalized(normalized_request)
	var accepted := _published_record_for_body_id(body.get_instance_id())
	if not accepted.is_empty():
		# LOD changes retain the prior proof; a changed recipe identity does not.
		accepted["expectedRecipeIdentityKey"] = recipe_identity_key
	enqueue_sequence += 1
	var priority := maxf(0.0, float(prepared_request.get("publicationPriority", INF)))
	if is_finite(priority):
		priority_scheduled_count += 1
	var task := {
		"propId":String(body.get_meta("prop_id", "")),
		"worldSeed":_publication_world_seed(prepared_request),
		"body": weakref(body),
		"bodyGlobalTransform": body.global_transform,
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
	body.set_meta("tree_publication_owner", weakref(self))
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
		_set_tree_preparation_state(body, "recipe_cached")
		return true
	var lod_source_recipe: Dictionary = recipe_cache.fetch_compatible_lod_source(
		recipe_identity_key,
		String(prepared_request.get("renderLodTier", "near"))
	)
	if not lod_source_recipe.is_empty():
		task["lodSourceRecipe"] = lod_source_recipe
		lod_recipe_derivation_requested_count += 1
		_set_tree_preparation_state(body, "recipe_lod_derivation_queued")
	enqueue_pending_task(task)
	if not task.has("lodSourceRecipe"):
		_set_tree_preparation_state(body, "queued")
	return true


func _has_accepted_tree_visual(body: StaticBody3D) -> bool:
	return bool(tree_publication_proof(body).get("installed", false))


func _set_tree_preparation_state(body: StaticBody3D, state: String) -> void:
	# Keep the adapter's currentness gate bound to the still-visible accepted
	# representation while a replacement task is preparing off to the side.
	if _has_accepted_tree_visual(body):
		return
	body.set_meta("tree_visual_state", state)


func _task_generation_is_current(task: Dictionary, body: StaticBody3D) -> bool:
	if not is_instance_valid(body) or body.is_queued_for_deletion() \
			or bool(body.get_meta("tree_publication_cancelled", false)):
		return false
	var task_generation := int(task.get("enqueueSequence", 0))
	var expected_generation := int(body.get_meta(
		"tree_section_recipe_input_expected_generation", 0))
	return task_generation == expected_generation


func _section_task_matches_current_producer(task: Dictionary, body: StaticBody3D,
		request: Dictionary, recipe: Dictionary) -> bool:
	if not is_instance_valid(body) or body.is_queued_for_deletion() \
			or bool(body.get_meta("tree_publication_cancelled", false)):
		return false
	var enqueue_generation := int(task.get("enqueueSequence", 0))
	var expected_generation := int(body.get_meta(
		"tree_section_recipe_input_expected_generation", 0))
	if expected_generation > 0 and enqueue_generation != expected_generation:
		return false
	if enqueue_generation > 0 and expected_generation != enqueue_generation:
		return false
	if String(body.get_meta("prop_id", "")) != String(task.get("propId", request.get("treeId", ""))) \
			or not request.get("treeWorldPosition", Vector3.INF) is Vector3 \
			or not (request.get("treeWorldPosition") as Vector3).is_equal_approx(body.global_position) \
			or not body.global_transform.is_equal_approx(task.get(
				"bodyGlobalTransform", body.global_transform) as Transform3D):
		return false
	var task_recipe_signature := String(recipe.get("signature", ""))
	var request_tier := String(request.get("renderLodTier", ""))
	var lod_value: Variant = recipe.get("renderLod", {})
	if task_recipe_signature.is_empty() or request_tier.is_empty() \
			or not lod_value is Dictionary \
			or String(lod_value.get("tier", request_tier)) != request_tier:
		return false
	if bool(task.get("sectionOwnedCompile", false)):
		var input_value: Variant = task.get("sectionRecipeInputRecord", null)
		if not input_value is Dictionary or not input_value.is_read_only():
			return false
		var input: Dictionary = input_value
		var input_body_ref := input.get("body") as WeakRef
		if String(input.get("schema", "")) != TREE_SECTION_RECIPE_INPUT_SCHEMA \
				or int(input.get("producerGeneration", 0)) != enqueue_generation \
				or int(input.get("bodyInstanceId", 0)) != body.get_instance_id() \
				or input_body_ref == null or input_body_ref.get_ref() != body \
				or String(input.get("recipeSignature", "")) != task_recipe_signature \
				or String(input.get("renderLodTier", "")) != request_tier \
				or not (input.get("bodyGlobalTransform", Transform3D.IDENTITY) as Transform3D).is_equal_approx(body.global_transform):
			return false
		var retained_input := tree_section_recipe_input_record_for_body(body)
		if retained_input.is_empty() \
				or String(retained_input.get("contentRevision", "")) != String(input.get("contentRevision", "")):
			return false
	return true

## Cancel this exact scene instance without harvesting it or waiting for recipe
## workers on the gameplay thread. All queued/LOD/proxy consumers resolve the
## same instance flag; a fresh same-ID tree remains independently publishable.
func cancel_body_publication(body: StaticBody3D) -> Dictionary:
	if not is_instance_valid(body): return {"status":"failed", "reason":"invalid_tree"}
	body.set_meta("tree_publication_cancelled", true)
	var accepted_index := int(_published_record_index_by_body.get(body.get_instance_id(), -1))
	if accepted_index >= 0: _remove_published_record_at(accepted_index)
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
	return selected_lod_tier_from_normalized(request,
		publication_service.normalize_request(request), current_tier)

func selected_lod_tier_from_normalized(request: Dictionary, normalized_request: Dictionary,
		current_tier := "") -> String:
	if normalized_request.is_empty():
		return "near"
	var viewer_node: Node3D = _live_viewer()
	if viewer_node != null and is_instance_valid(viewer_node):
		var position_value = request.get("treeWorldPosition", null)
		if position_value is Vector3:
			return publication_service.lod_tier_for_distance_normalized(
				normalized_request,
				viewer_node.global_position.distance_to(position_value as Vector3), current_tier)
	var priority := float(request.get("publicationPriority", INF))
	if is_finite(priority):
		return publication_service.lod_tier_for_distance_normalized(
			normalized_request, sqrt(maxf(0.0, priority)), current_tier)
	# Service/PoC callers without a live player intentionally retain the full
	# recipe for inspection. Runtime chunk callers always provide a priority.
	return publication_service.lod_tier_for_distance_normalized(
		normalized_request, 0.0, current_tier)

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
			_remove_published_record_at(lod_recheck_cursor)
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

func _publication_world_seed(request: Dictionary) -> String:
	var main := get_parent()
	# Standalone queue contracts have no world owner. Production Main owns the
	# world seed; a structure recipe may carry a distinct deterministic seed.
	return String(main.get("seed_text")) if is_instance_valid(main) and "seed_text" in main \
		else String(request.get("worldSeed", ""))


func remember_published_lod(body: StaticBody3D, request: Dictionary,
		section_value_members: Array = [], recipe_snapshot: Dictionary = {},
		section_owned := false, presentation_kind := "", presentation_witness: Dictionary = {}) -> void:
	var identity := publication_service.recipe_identity_key_from_normalized(
		publication_service.normalize_request(request))
	var record := {
		"propId":String(body.get_meta("prop_id", "")),
		"worldSeed":_publication_world_seed(request),
		"recipeIdentityKey":identity, "expectedRecipeIdentityKey":identity,
		"body": weakref(body),
		"bodyInstanceId": body.get_instance_id(),
		"bodyGlobalTransform":body.global_transform,
		"producerGeneration":int(body.get_meta("tree_section_recipe_input_expected_generation", 0)),
		"presentationKind":presentation_kind, "presentationWitness":presentation_witness,
		"request": request.duplicate(true),
		"tier": String(request.get("renderLodTier", "near")),
		"rebuildPending": false,
		"sectionOwned":section_owned,
		"sectionValueMembers": _freeze_section_value(section_value_members),
		"recipeSnapshot": _freeze_section_value(recipe_snapshot),
		"recipeSignature":String(recipe_snapshot.get("signature", ""))
	}
	var index := int(_published_record_index_by_body.get(body.get_instance_id(), -1))
	if index >= 0:
		published_lod_records[index] = record
		return
	_published_record_index_by_body[body.get_instance_id()] = published_lod_records.size()
	published_lod_records.append(record)


func set_section_owned_publication_enabled(enabled: bool) -> void:
	section_owned_publication_enabled = enabled


func prepared_section_value_record_for_body(body: StaticBody3D) -> Dictionary:
	return _source_record_for_body("prepared", body)


func build_tree_section_recipe_input_record(task: Dictionary, body: StaticBody3D,
		recipe: Dictionary) -> Dictionary:
	var request_value: Variant = task.get("request", null)
	if not is_instance_valid(body) or body.is_queued_for_deletion() \
			or bool(body.get_meta("tree_publication_cancelled", false)) \
			or not request_value is Dictionary or request_value.is_empty() or recipe.is_empty():
		return {"status":"pending", "reason":"tree_section_recipe_input_authority_missing"}
	var request: Dictionary = request_value
	var prop_id := String(task.get("propId", request.get("treeId", "")))
	var seed := String(task.get("worldSeed", request.get("worldSeed", "")))
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
	var support_envelope_result: Dictionary = \
		TreeRecipeSectionCompilerScript.certify_recipe_support_envelope(recipe, transform)
	if support_envelope_result.get("status") != "ready":
		return {"status":"pending", "reason":String(support_envelope_result.get(
			"reason", "tree_section_recipe_support_envelope_pending"))}
	var support_envelope: Dictionary = support_envelope_result.value
	var frozen_request: Dictionary = _freeze_section_value(normalized)
	var frozen_recipe: Dictionary = _freeze_section_value(recipe)
	var frozen_support_envelope: Dictionary = _freeze_section_value(support_envelope)
	var content_values := [TREE_SECTION_RECIPE_INPUT_SCHEMA,
		TREE_SECTION_RECIPE_COMPILER_REVISION, seed, prop_id, tier,
		recipe_signature, frozen_request, frozen_recipe, frozen_support_envelope]
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
		"supportEnvelope":frozen_support_envelope,
		"certifiedEnvelopeDigest":String(support_envelope.get("certifiedEnvelopeDigest", "")),
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
			_startup_tree_diagnostic_unindex("section_recipe_input", existing)
			_unindex_source_record("input", existing)
			section_recipe_input_records.remove_at(index)
	section_recipe_input_records.append(record)
	_index_source_record("input", record)
	_startup_tree_diagnostic_index("section_recipe_input", record)
	return {"status":"retained", "sourceId":String(record.get("sourceId", "")),
		"artifactGeneration":int(record.get("artifactGeneration", 0))}


func tree_section_recipe_input_record_for_body(body: StaticBody3D) -> Dictionary:
	if not is_instance_valid(body):
		return {}
	var record := _source_record_for_body("input", body)
	if record.is_empty() or (int(body.get_meta("tree_section_recipe_input_expected_generation", 0)) > 0 \
			and int(record.get("producerGeneration", 0)) != int(body.get_meta("tree_section_recipe_input_expected_generation", 0))) \
			or String(body.get_meta("prop_id", "")) != String(record.get("propId", "")) \
			or bool(body.get_meta("tree_publication_cancelled", false)) \
			or record.get("bodyGlobalTransform") != body.global_transform:
		return {}
	return record


func _remove_tree_section_recipe_input_record_for_body(body: StaticBody3D) -> void:
	for index in range(section_recipe_input_records.size() - 1, -1, -1):
		var record: Dictionary = section_recipe_input_records[index]
		var body_ref := record.get("body") as WeakRef
		if body_ref != null and body_ref.get_ref() == body \
				and int(record.get("bodyInstanceId", 0)) == body.get_instance_id():
			_startup_tree_diagnostic_unindex("section_recipe_input", record)
			_unindex_source_record("input", record)
			section_recipe_input_records.remove_at(index)
	if active_tree_section_compile_record.get("bodyInstanceId", 0) == body.get_instance_id():
		legacy_tree_compiler_retirement_pending = true
	for index in range(compiled_tree_section_records.size() - 1, -1, -1):
		var compiled: Dictionary = compiled_tree_section_records[index]
		var reference := compiled.get("body") as WeakRef
		if reference != null and reference.get_ref() == body \
				and int(compiled.get("bodyInstanceId", 0)) == body.get_instance_id():
			_startup_tree_diagnostic_unindex("section_compiled", compiled)
			_unindex_source_record("compiled", compiled)
			compiled_tree_section_records.remove_at(index)
			pending_compiled_section_retirement_records.append(compiled)
	var prior_ack: Dictionary = _startup_tree_diagnostic_ack_by_id.get(
		String(body.get_meta("prop_id", "")), {})
	if int(prior_ack.get("bodyInstanceId", 0)) == body.get_instance_id():
		_startup_tree_diagnostic_ack_by_id.erase(String(body.get_meta("prop_id", "")))


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
	if not _section_task_matches_current_producer(task, body, request, recipe):
		return {"status":"pending", "reason":"prepared_tree_producer_generation_stale"}
	var prop_id := String(task.get("propId", request.get("treeId", "")))
	var seed := String(task.get("worldSeed", request.get("worldSeed", "")))
	var tier := String(request.get("renderLodTier", ""))
	var recipe_signature := String(recipe.get("signature", ""))
	var recipe_input_value: Variant = task.get("sectionRecipeInputRecord", {})
	var recipe_artifact_revision := ""
	if recipe_input_value is Dictionary:
		recipe_artifact_revision = String(recipe_input_value.get("contentRevision", ""))
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
		"worldSeed":seed,
		"artifactGeneration":prepared_section_generation,
		"producerGeneration":int(task.get("enqueueSequence", 0)),
		"sourceId":"%s:tree:%s" % [seed, prop_id], "propId":prop_id,
		"body":weakref(body), "bodyInstanceId":body.get_instance_id(),
		"bodyGlobalTransform":body.global_transform,
		"request":frozen_request, "recipeSnapshot":frozen_recipe,
		"recipeSignature":recipe_signature,
		"recipeArtifactRevision":recipe_artifact_revision, "tier":tier,
		"rebuildPending":false, "sectionValueMembers":frozen_members}
	record.make_read_only()
	return {"status":"ready", "record":record}


func retain_prepared_section_value_record(record: Dictionary) -> Dictionary:
	if String(record.get("schema", "")) != "prepared-tree-section-artifact/v1" \
			or not record.is_read_only():
		return {"status":"failed", "reason":"prepared_tree_record_invalid"}
	var body_ref := record.get("body") as WeakRef
	var body: StaticBody3D = body_ref.get_ref() as StaticBody3D if body_ref != null else null
	var producer_generation := int(record.get("producerGeneration", 0))
	var expected_generation := int(body.get_meta(
		"tree_section_recipe_input_expected_generation", 0)) if is_instance_valid(body) else 0
	var request_value: Variant = record.get("request", {})
	var record_request: Dictionary = request_value if request_value is Dictionary else {}
	if not is_instance_valid(body) or body.is_queued_for_deletion() \
			or bool(body.get_meta("tree_publication_cancelled", false)) \
			or int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
			or (expected_generation > 0 and producer_generation != expected_generation) \
			or (producer_generation > 0 and expected_generation != producer_generation) \
			or not (record.get("bodyGlobalTransform", Transform3D.IDENTITY) as Transform3D).is_equal_approx(body.global_transform) \
			or not (record_request.get("treeWorldPosition", Vector3.INF) as Vector3).is_equal_approx(body.global_position) \
			or String(body.get_meta("prop_id", "")) != String(record.get("propId", "")):
		return {"status":"pending", "reason":"prepared_tree_body_replaced"}
	for existing_value: Variant in prepared_section_value_records:
		if not existing_value is Dictionary:
			continue
		var existing: Dictionary = existing_value
		var existing_body_ref := existing.get("body") as WeakRef
		if existing_body_ref != null and existing_body_ref.get_ref() == body \
				and int(existing.get("producerGeneration", 0)) > producer_generation:
			return {"status":"pending", "reason":"prepared_tree_record_superseded"}
	for index in range(prepared_section_value_records.size() - 1, -1, -1):
		var existing: Dictionary = prepared_section_value_records[index]
		var existing_body_ref := existing.get("body") as WeakRef
		if existing_body_ref != null and existing_body_ref.get_ref() == body:
			prepared_section_acknowledgements.erase(int(existing.get("artifactGeneration", 0)))
			_startup_tree_diagnostic_unindex("section_prepared", existing)
			_unindex_source_record("prepared", existing)
			prepared_section_value_records.remove_at(index)
	prepared_section_value_records.append(record)
	_index_source_record("prepared", record)
	_startup_tree_diagnostic_index("section_prepared", record)
	return {"status":"retained", "sourceId":String(record.get("sourceId", "")),
		"artifactGeneration":int(record.get("artifactGeneration", 0))}


func acknowledge_prepared_tree_section_install(source_id: String,
		source_revision: String, required_sections: Array[Vector3i],
		installed_receipts: Dictionary, provider_binding: Dictionary = {}) -> Dictionary:
	var producer_source_id := source_id
	if not provider_binding.is_empty():
		var job_reference: Variant = provider_binding.get("job")
		var job: Variant = job_reference.get_ref() if job_reference is WeakRef else null
		if not provider_binding.is_read_only() or not is_instance_valid(job) \
				or not job.has_method("tree_section_alias_is_current") \
				or provider_binding.get("sourceId") != source_id \
				or not bool(job.call("tree_section_alias_is_current", provider_binding)):
			return {"status":"pending", "reason":"tree_section_provider_alias_stale"}
		producer_source_id = String(provider_binding.get("producerSourceId", ""))
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
	var compiled_manifest: Dictionary = {}
	for index in range(prepared_section_value_records.size()):
		var row: Dictionary = prepared_section_value_records[index]
		if String(row.get("sourceId", "")) == producer_source_id:
			record_index = index
			record = row
			break
	if record_index < 0:
		for compiled_index in range(compiled_tree_section_records.size() - 1, -1, -1):
			var compiled: Dictionary = compiled_tree_section_records[compiled_index]
			if String(compiled.get("sourceId", "")) == producer_source_id:
				record = compiled.get("record", {})
				for row: Dictionary in compiled.get("compiled", {}).get("sources", []):
					if String(row.get("sourceId", "")) == producer_source_id: compiled_manifest = row
				break
	if record.is_empty() or String(record.get("recipeSignature", "")).is_empty():
		return {"status":"pending", "reason":"prepared_tree_record_missing"}
	if not provider_binding.is_empty() and (
			provider_binding.get("producerRevision") != record.get("contentRevision") \
			or provider_binding.get("bodyInstanceId") != record.get("bodyInstanceId") \
			or provider_binding.get("compiledSourceRevision") != compiled_manifest.get("sourceRevision")):
		return {"status":"pending", "reason":"tree_section_provider_recipe_stale"}
	var ack: Dictionary = {"sourceRevision":source_revision,
		"requiredSections":required_sections.duplicate(),
		"receipts":installed_receipts.duplicate(false)}
	prepared_section_acknowledgements[int(record.get("artifactGeneration", 0))] = ack
	var body_ref := record.get("body") as WeakRef
	var body: StaticBody3D = body_ref.get_ref() as StaticBody3D if body_ref != null else null
	if not is_instance_valid(body) or int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
			or not body.is_inside_tree() \
			or bool(body.get_meta("tree_publication_cancelled", false)) \
			or not (record.get("bodyGlobalTransform", Transform3D.IDENTITY) as Transform3D).is_equal_approx(body.global_transform):
		return {"status":"pending", "reason":"prepared_tree_body_changed_before_retirement"}
	var required_section_values: Array[Vector3i] = required_sections.duplicate()
	var expected_sections: Array = []
	if record_index < 0:
		expected_sections = compiled_manifest.get("ownedSectionKeys", []).duplicate()
	else:
		for member: Dictionary in record.get("sectionValueMembers", []):
			var mesh: Mesh = member.get("mesh")
			if not is_instance_valid(mesh): return {"status":"pending", "reason":"tree_section_member_resource_lost"}
			for instance: Transform3D in member.get("transforms", []):
				var bounds: AABB = body.global_transform * member.localTransform * instance * mesh.get_aabb()
				var key := StaticRenderSectionGridScript.key_for_world_position(bounds.get_center())
				if key not in expected_sections: expected_sections.append(key)
	if expected_sections.is_empty() or expected_sections.size() != required_sections.size():
		return {"status":"pending", "reason":"tree_section_owner_roster_incomplete"}
	for expected: Variant in expected_sections:
		if not expected is Vector3i or expected not in required_sections:
			return {"status":"pending", "reason":"tree_section_owner_roster_changed"}
	var coordinator: Variant = _presentation_coordinator.get_ref() if _presentation_coordinator != null else null
	if not is_instance_valid(coordinator) or not _presentation_source_current(record, body, true):
		return {"status":"pending", "reason":"tree_section_presentation_owner_stale"}
	var world_id := ""
	for section: Vector3i in required_sections:
		var actual: Dictionary = installed_receipts[section]
		if world_id.is_empty(): world_id = String(actual.get("worldId", ""))
		if world_id.is_empty() or actual.get("worldId") != world_id \
				or not coordinator.call("installed_section_receipt_is_current", section, actual) \
				or not coordinator.call("installed_section_contains_source", section, source_id, source_revision):
			return {"status":"pending", "reason":"tree_section_receipt_not_current"}
	var presentation := {"coordinatorId":coordinator.get_instance_id(), "worldId":world_id,
		"sourceId":source_id, "sourceRevision":source_revision,
		"sections":required_sections.duplicate(), "receipts":installed_receipts.duplicate(true),
		"providerBinding":provider_binding}
	var diagnostic_ack := {"sourceId":source_id,
		"propId":String(record.get("propId", "")),
		"bodyInstanceId":int(record.get("bodyInstanceId", 0)),
		"body":weakref(body),
		"artifactGeneration":int(record.get("artifactGeneration", 0)),
		"producerGeneration":int(record.get("producerGeneration", 0)),
		"recipeSignature":String(record.get("recipeSignature", "")),
		"recipeArtifactRevision":String(record.get("recipeArtifactRevision", "")),
		"sourceRevision":source_revision,
		"sectionKeys":required_section_values,
		"receiptCount":installed_receipts.size()}
	_retire_legacy_tree_visual_for_section_owner(body)
	var frozen_request: Dictionary = record.get("request", {})
	var frozen_members: Array = record.get("sectionValueMembers", [])
	var frozen_recipe: Dictionary = record.get("recipeSnapshot", {})
	var compact_recipe := {"signature":String(record.get("recipeSignature", "")),
		"renderLod":{"tier":String(frozen_request.get("renderLodTier", ""))}}
	remember_published_lod(body, frozen_request, frozen_members, compact_recipe, true,
		"section", presentation)
	body.set_meta("tree_visual_state", "section_owned")
	body.set_meta("visual_source", "chunk_owned_static_section")
	if record_index >= 0:
		_remove_tree_section_recipe_input_record_for_body(body)
	var prop_id := String(record.get("propId", ""))
	if not _startup_tree_diagnostic_ack_by_id.has(prop_id):
		_startup_tree_diagnostic_ack_order.append(prop_id)
	_startup_tree_diagnostic_ack_by_id[prop_id] = diagnostic_ack
	while _startup_tree_diagnostic_ack_order.size() > MAX_STARTUP_TREE_DIAGNOSTIC_ACK_RECORDS:
		var retired_id: String = _startup_tree_diagnostic_ack_order.pop_front()
		if not _startup_tree_diagnostic_ack_order.has(retired_id):
			_startup_tree_diagnostic_ack_by_id.erase(retired_id)
	prepared_section_acknowledgements.erase(int(record.get("artifactGeneration", 0)))
	_startup_tree_diagnostic_unindex("section_prepared", record)
	if record_index >= 0:
		_unindex_source_record("prepared", record)
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
		_set_tree_preparation_state(body, "recipe_cached")
	else:
		var lod_source_recipe: Dictionary = recipe_cache.fetch_compatible_lod_source(
			String(task.get("recipeIdentityKey", "")),
			String(request.get("renderLodTier", "near"))
		)
		if not lod_source_recipe.is_empty():
			task["lodSourceRecipe"] = lod_source_recipe
			lod_recipe_derivation_requested_count += 1
			_set_tree_preparation_state(body, "recipe_lod_derivation_queued")
		enqueue_pending_task(task)
		if not task.has("lodSourceRecipe"):
			_set_tree_preparation_state(body, "queued")
	return true

func _ready() -> void:
	_ensure_tree_value_retirement_worker()
	if is_instance_valid(tree_recipe_section_compiler) \
			and tree_recipe_section_compiler.progress_snapshot().get("status", "") != "idle":
		legacy_tree_compiler_retirement_pending = true


func _process(_delta: float) -> void:
	_advance_tree_value_retirement()
	_advance_pending_tree_value_retirements()
	refresh_viewer_motion_snapshot()
	refresh_collision_visibility_proxies()
	refresh_published_lods()
	start_pending_workers()
	collect_completed_workers()
	publish_completed_recipes()
	# Body-bound records already own admitted recipe values and removal proofs.
	# Only source-family compilation needs the live ecology catalog scope.
	advance_tree_section_compiler(TREE_SECTION_COMPILER_WORK_UNITS_PER_FRAME)
	_advance_source_compilers_in_catalog_scope()


func _advance_tree_value_retirement() -> void:
	if is_instance_valid(tree_value_retirement_owner):
		tree_value_retirement_owner.advance()


func _advance_pending_tree_value_retirements() -> void:
	if not _can_enqueue_tree_value_retirement(): return
	_advance_legacy_tree_compiler_retirement()
	_advance_compiled_section_retirements()
	for key_value: Variant in ecology_source_compile_order.duplicate():
		var key := String(key_value)
		if not ecology_source_compile_jobs.has(key): continue
		var job: Dictionary = ecology_source_compile_jobs[key]
		if not bool(job.get("retirementPending", false)): continue
		_retire_tree_source_cache_job(key, job)
	for key_value: Variant in ecology_tree_band_compile_order.duplicate():
		var key := String(key_value)
		if not ecology_tree_band_compile_jobs.has(key): continue
		var job: Dictionary = ecology_tree_band_compile_jobs[key]
		if not bool(job.get("retirementPending", false)): continue
		_retire_tree_band_cache_job(key, job)


func _advance_legacy_tree_compiler_retirement() -> bool:
	if not legacy_tree_compiler_retirement_pending:
		return true
	if legacy_tree_compiler_retirement_roots.is_empty() \
			and legacy_tree_compiler_retirement_keepalives.is_empty():
		if not is_instance_valid(tree_recipe_section_compiler) \
				or not tree_recipe_section_compiler.has_method("take_source_retirement_values"):
			return false
		if not _can_enqueue_tree_value_retirement(): return false
		var retirement: Dictionary = tree_recipe_section_compiler.call(
			"take_source_retirement_values")
		if String(retirement.get("status", "")) != "ready": return false
		var roots: Array[Dictionary] = []
		var value_roots: Variant = retirement.get("valueRoots", {})
		if value_roots is Dictionary and not value_roots.is_empty():
			if not _append_tree_value_retirement_root(value_roots, roots): return false
		var keepalives: Array[RefCounted] = []
		var keepalive_values: Variant = retirement.get("mainRefCountedKeepalives", [])
		if keepalive_values is Array:
			for ref_value: Variant in keepalive_values:
				if not ref_value is RefCounted or not is_instance_valid(ref_value): return false
				keepalives.append(ref_value as RefCounted)
		legacy_tree_compiler_retirement_roots = roots
		legacy_tree_compiler_retirement_keepalives = keepalives
	if not _can_enqueue_tree_value_retirement(): return false
	var queued: Dictionary = tree_value_retirement_owner.enqueue(
		legacy_tree_compiler_retirement_roots,
		legacy_tree_compiler_retirement_keepalives)
	if String(queued.get("status", "")) != "ready": return false
	legacy_tree_compiler_retirement_roots.clear()
	legacy_tree_compiler_retirement_keepalives.clear()
	legacy_tree_compiler_retirement_pending = false
	# This record can be a sealed read-only snapshot. Releasing the active
	# reference is sufficient; mutating it would violate the producer's
	# immutable handoff contract during retirement.
	active_tree_section_compile_record = {}
	return true


func _advance_compiled_section_retirements() -> void:
	var index := pending_compiled_section_retirement_records.size() - 1
	while index >= 0:
		var record: Dictionary = pending_compiled_section_retirement_records[index]
		if not _retire_compiled_tree_section_record(record):
			index -= 1
			continue
		pending_compiled_section_retirement_records.remove_at(index)
		index -= 1


func _retire_compiled_tree_section_record(record: Dictionary) -> bool:
	if not _can_enqueue_tree_value_retirement(): return false
	var compiled_value: Variant = record.get("compiled", null)
	if not compiled_value is Dictionary: return false
	var compiled_artifact: Dictionary = compiled_value
	var value_record := record.duplicate(false)
	value_record.erase("body")
	var recipe_record: Variant = value_record.get("record", null)
	if recipe_record is Dictionary:
		var detached_recipe_record: Dictionary = recipe_record.duplicate(false)
		detached_recipe_record.erase("body")
		detached_recipe_record.make_read_only()
		value_record["record"] = detached_recipe_record
	var artifact_values := compiled_artifact.duplicate(false)
	var empty_bindings: Dictionary = {}
	empty_bindings.make_read_only()
	artifact_values["resourceBindings"] = empty_bindings
	artifact_values.make_read_only()
	value_record["compiled"] = artifact_values
	value_record.make_read_only()
	var roots: Array[Dictionary] = [value_record]
	var keepalives: Array[RefCounted] = []
	var bindings: Variant = compiled_artifact.get("resourceBindings", {})
	if not bindings is Dictionary: return false
	for resource_value: Variant in bindings.values():
		if not resource_value is RefCounted or not is_instance_valid(resource_value): return false
		var resource: RefCounted = resource_value as RefCounted
		var found := false
		for prior: RefCounted in keepalives:
			if is_same(prior, resource): found = true; break
		if not found: keepalives.append(resource)
	var queued: Dictionary = tree_value_retirement_owner.enqueue(roots, keepalives)
	return String(queued.get("status", "")) == "ready"


func _drain_tree_value_retirements() -> bool:
	if not is_instance_valid(tree_value_retirement_owner): return false
	var drained: Dictionary = tree_value_retirement_owner.drain()
	return String(drained.get("status", "")) == "ready"


func _ensure_tree_value_retirement_worker() -> Dictionary:
	if not is_instance_valid(tree_value_retirement_owner):
		return {"status":"pending", "reason":"tree_value_retirement_owner_missing",
			"retryable":true}
	var state: Dictionary = tree_value_retirement_owner.snapshot()
	if bool(state.get("workerStarted", false)):
		return {"status":"ready", "started":false}
	return tree_value_retirement_owner.start_worker()


func _can_enqueue_tree_value_retirement() -> bool:
	return String(_ensure_tree_value_retirement_worker().get("status", "")) == "ready" \
		and tree_value_retirement_owner.can_accept()


func _queue_tree_value_retirement(value_roots: Array[Dictionary],
		main_refcounted_keepalives: Array[RefCounted] = []) -> bool:
	if value_roots.is_empty(): return true
	if not _can_enqueue_tree_value_retirement(): return false
	var queued: Dictionary = tree_value_retirement_owner.enqueue(value_roots,
		main_refcounted_keepalives)
	return String(queued.get("status", "")) == "ready"


func _retire_untracked_tree_compiler(compiler: Object) -> bool:
	if not is_instance_valid(compiler) \
			or not compiler.has_method("take_source_retirement_values") \
			or not _can_enqueue_tree_value_retirement():
		return false
	var retirement: Dictionary = compiler.call("take_source_retirement_values")
	if String(retirement.get("status", "")) != "ready": return false
	var roots: Array[Dictionary] = []
	var value_roots: Variant = retirement.get("valueRoots", {})
	if value_roots is Dictionary and not value_roots.is_empty():
		if not _append_tree_value_retirement_root(value_roots, roots): return false
	var keepalives: Array[RefCounted] = []
	var keepalive_values: Variant = retirement.get("mainRefCountedKeepalives", [])
	if keepalive_values is Array:
		for ref_value: Variant in keepalive_values:
			if not ref_value is RefCounted or not is_instance_valid(ref_value):
				return false
			keepalives.append(ref_value as RefCounted)
	return _queue_tree_value_retirement(roots, keepalives)


func _append_tree_value_retirement_root(value: Variant,
		roots: Array[Dictionary]) -> bool:
	if not value is Dictionary: return false
	var root: Dictionary = value
	if not root.is_read_only(): root = root.duplicate(false)
	if not root.is_read_only(): root.make_read_only()
	roots.append(root)
	return true


func _tree_artifact_holder(artifact_value: Dictionary) -> Dictionary:
	var resource_bindings: Variant = artifact_value.get("resourceBindings", {})
	if not resource_bindings is Dictionary: return {}
	var value_artifact := artifact_value.duplicate(false)
	var empty_bindings: Dictionary = {}
	empty_bindings.make_read_only()
	value_artifact["resourceBindings"] = empty_bindings
	value_artifact.make_read_only()
	return {"schema":"tree-source-artifact-holder/v1",
		"valueArtifact":value_artifact, "resourceBindings":resource_bindings}


func _tree_artifact_holder_view(holder: Dictionary) -> Dictionary:
	var value_artifact: Variant = holder.get("valueArtifact", null)
	var resource_bindings: Variant = holder.get("resourceBindings", null)
	if String(holder.get("schema", "")) != "tree-source-artifact-holder/v1" \
			or not value_artifact is Dictionary or not value_artifact.is_read_only() \
			or not resource_bindings is Dictionary:
		return {}
	var view: Dictionary = value_artifact.duplicate(false)
	view["resourceBindings"] = resource_bindings
	view.make_read_only()
	return view


func _append_tree_artifact_retirement(holder_value: Variant,
		value_roots: Array[Dictionary], keepalives: Array[RefCounted]) -> bool:
	if not holder_value is Dictionary: return true
	var holder: Dictionary = holder_value
	var value_artifact: Variant = holder.get("valueArtifact", null)
	var resource_bindings: Variant = holder.get("resourceBindings", null)
	if not value_artifact is Dictionary or not resource_bindings is Dictionary: return false
	value_roots.append(value_artifact)
	var compiler_roots: Variant = holder.get("compilerValueRoots", {})
	if compiler_roots is Dictionary and not compiler_roots.is_empty():
		value_roots.append(compiler_roots)
	var compiler_resources: Variant = holder.get("compilerMainRefCountedKeepalives", [])
	if compiler_resources is Array:
		for resource_value: Variant in compiler_resources:
			if not resource_value is RefCounted or not is_instance_valid(resource_value): return false
			var compiler_resource_found := false
			for prior_resource: RefCounted in keepalives:
				if is_same(prior_resource, resource_value): compiler_resource_found = true; break
			if not compiler_resource_found: keepalives.append(resource_value as RefCounted)
	for resource_value: Variant in resource_bindings.values():
		if not resource_value is RefCounted or not is_instance_valid(resource_value): return false
		var found := false
		for prior: RefCounted in keepalives:
			if is_same(prior, resource_value): found = true; break
		if not found: keepalives.append(resource_value as RefCounted)
	return true


func _retire_tree_source_cache_job(key: String, job: Dictionary) -> bool:
	if not _can_enqueue_tree_value_retirement(): return false
	var roots: Array[Dictionary] = []
	var keepalives: Array[RefCounted] = []
	var holder: Variant = job.get("resultHolder", null)
	if not holder is Dictionary:
		var artifact: Variant = job.get("result", null)
		if artifact is Dictionary and not artifact.is_empty():
			holder = _tree_artifact_holder(artifact)
	if holder is Dictionary and not holder.is_empty() \
			and not _append_tree_artifact_retirement(holder, roots, keepalives):
		return false
	var source_values: Dictionary = {}
	for value_key: String in ["snapshot", "sourceRecord", "publicationView"]:
		var source_value: Variant = job.get(value_key, null)
		if source_value is Dictionary and not source_value.is_empty():
			source_values[value_key] = source_value
	if not source_values.is_empty():
		source_values.make_read_only()
		if not _append_tree_value_retirement_root(source_values, roots): return false
	var compiler: Object = job.get("compiler") as Object
	if is_instance_valid(compiler) and compiler.has_method("take_source_retirement_values"):
		var compiler_retirement: Dictionary = compiler.call("take_source_retirement_values")
		if String(compiler_retirement.get("status", "")) == "ready":
			var compiler_roots: Variant = compiler_retirement.get("valueRoots", {})
			if compiler_roots is Dictionary and not compiler_roots.is_empty():
				if not _append_tree_value_retirement_root(compiler_roots, roots): return false
			var compiler_resources: Variant = compiler_retirement.get(
				"mainRefCountedKeepalives", [])
			if compiler_resources is Array:
				for resource_value: Variant in compiler_resources:
					if not resource_value is RefCounted or not is_instance_valid(resource_value):
						return false
					keepalives.append(resource_value as RefCounted)
		else:
			return false
	elif is_instance_valid(compiler):
		return false
	if not _queue_tree_value_retirement(roots, keepalives): return false
	job["result"] = {}
	job["resultHolder"] = {}
	job["compiler"] = null
	job["snapshot"] = {}
	job["sourceRecord"] = {}
	_release_ecology_compile_catalog_lease(job)
	ecology_source_compile_jobs.erase(key)
	ecology_source_compile_order.erase(key)
	return true


func _retire_tree_band_cache_job(key: String, job: Dictionary) -> bool:
	if not _can_enqueue_tree_value_retirement(): return false
	var roots: Array[Dictionary] = []
	var keepalives: Array[RefCounted] = []
	var band_holder: Variant = job.get("artifactHolder", null)
	if band_holder is Dictionary and not band_holder.is_empty() \
			and not _append_tree_artifact_retirement(band_holder, roots, keepalives):
		return false
	var source_holders: Variant = job.get("sourceArtifactsById", {})
	if source_holders is Dictionary:
		for holder_value: Variant in source_holders.values():
			if not _append_tree_artifact_retirement(holder_value, roots, keepalives):
				return false
	var compiler: Object = job.get("compiler") as Object
	if is_instance_valid(compiler):
		if not compiler.has_method("take_source_retirement_values"): return false
		var compiler_retirement: Dictionary = compiler.call("take_source_retirement_values")
		if String(compiler_retirement.get("status", "")) != "ready": return false
		var compiler_roots: Variant = compiler_retirement.get("valueRoots", {})
		if compiler_roots is Dictionary and not compiler_roots.is_empty():
			if not _append_tree_value_retirement_root(compiler_roots, roots): return false
		var compiler_resources: Variant = compiler_retirement.get(
			"mainRefCountedKeepalives", [])
		if compiler_resources is Array:
			for resource_value: Variant in compiler_resources:
				if not resource_value is RefCounted or not is_instance_valid(resource_value): return false
				keepalives.append(resource_value as RefCounted)
	var band_values: Dictionary = {}
	for value_key: String in ["records", "recordsById", "snapshot",
			"publicationView", "authority"]:
		var value: Variant = job.get(value_key, null)
		if value is Dictionary and not value.is_empty(): band_values[value_key] = value
		elif value is Array and not value.is_empty(): band_values[value_key] = value
	if not band_values.is_empty():
		band_values.make_read_only()
		if not _append_tree_value_retirement_root(band_values, roots): return false
	if not _queue_tree_value_retirement(roots, keepalives): return false
	job["artifact"] = {}
	job["artifactHolder"] = {}
	job["sourceArtifactsById"] = {}
	job["compiler"] = null
	job["records"] = []
	job["recordsById"] = {}
	job["snapshot"] = {}
	job["publicationView"] = {}
	ecology_tree_band_compile_jobs.erase(key)
	ecology_tree_band_compile_order.erase(key)
	return true


func _advance_source_compilers_in_catalog_scope() -> void:
	if not _has_catalog_scoped_source_work():
		return
	var main: Object = get_parent() as Object
	if not is_instance_valid(main) \
			or not main.has_method("begin_ecology_source_catalog_context_scope") \
			or not main.has_method("end_ecology_source_catalog_context_scope"):
		return
	var scope: Dictionary = main.call("begin_ecology_source_catalog_context_scope")
	if String(scope.get("status", "")) != "ready":
		# Leave every source request queued when its catalog authority is pending.
		return
	start_pending_source_recipe_workers()
	collect_completed_source_recipe_workers()
	advance_ecology_source_compilers()
	main.call("end_ecology_source_catalog_context_scope", scope)


func _has_catalog_scoped_source_work() -> bool:
	# Band compiles are advanced only inside the catalog context scope below.
	# Keep that scope open even when a band job is the only pending source work;
	# otherwise the queued compiler can never start or make progress.
	for band_job_value: Variant in ecology_tree_band_compile_jobs.values():
		if not band_job_value is Dictionary:
			continue
		var band_status := String(band_job_value.get("status", ""))
		if band_status == "queued" or band_status == "active":
			return true
	for key_value: Variant in ecology_source_compile_order:
		var job: Dictionary = ecology_source_compile_jobs.get(String(key_value), {})
		var compile_status := String(job.get("status", ""))
		if compile_status == "queued" or compile_status == "active":
			return true
	for task_value: Variant in source_recipe_jobs.values():
		if not task_value is Dictionary:
			continue
		var status := String(task_value.get("status", ""))
		if status == "queued" or status == "awaiting_validation":
			return true
	for task_value: Variant in source_recipe_workers:
		if not task_value is Dictionary:
			continue
		var thread := task_value.get("thread") as Thread
		if thread == null or not thread.is_alive():
			return true
	return false


## Admit a values-only tree compile for one complete canonical producer domain.
## The compiler owns recipes and geometry preparation; this queue owns job
## identity, per-frame advancement, replay, and bounded result retention.
func _retain_source_publication(main: Object, snapshot: Dictionary,
		view: Dictionary, owner_kind: String) -> Dictionary:
	if not is_instance_valid(main) or not main.has_method("admit_ecology_source_publication") \
			or not main.has_method("acquire_ecology_source_publication") \
			or not main.has_method("ecology_source_publication_local_is_current") \
			or not main.has_method("ecology_source_publication_record_is_current"):
		return {"status":"pending", "reason":"ecology_source_publication_owner_unavailable", "retryable":true}
	source_publication_consumer_serial += 1
	var owner_key := "%d:%s:%d" % [get_instance_id(), owner_kind, source_publication_consumer_serial]
	var retained: Dictionary
	if not view.is_empty():
		if not is_same(view.get("payload", {}), snapshot):
			return {"status":"failed", "reason":"ecology_source_publication_payload_alias_mismatch"}
		retained = main.call("acquire_ecology_source_publication", String(view.get("publicationId", "")), owner_kind, owner_key)
	else:
		var catalog: Dictionary = main.call("acquire_ecology_catalog_artifact_lease",
			String(snapshot.get("catalogArtifactId", "")), owner_kind, owner_key,
			String(snapshot.get("worldId", "")), int(snapshot.get("worldEpoch", -1)))
		if catalog.get("status") != "ready": return catalog
		var catalog_token := String(catalog.get("leaseToken", ""))
		retained = main.call("admit_ecology_source_publication", snapshot, catalog_token, owner_kind, owner_key)
		main.call("release_ecology_catalog_artifact_lease", catalog_token)
	if retained.get("status") != "ready": return retained
	var admitted_view: Dictionary = retained.get("view", {})
	if not is_same(admitted_view.get("payload", {}), snapshot):
		main.call("release_ecology_source_publication", String(retained.get("leaseToken", "")))
		return {"status":"failed", "reason":"ecology_source_publication_payload_alias_mismatch"}
	return retained


func request_ecology_tree_source_compile(main: Object, snapshot: Dictionary,
		consumer_token := "", publication_view: Dictionary = {}) -> Dictionary:
	var retirement_worker: Dictionary = _ensure_tree_value_retirement_worker()
	if String(retirement_worker.get("status", "")) != "ready":
		return {"status":"pending", "reason":"tree_value_retirement_worker_unavailable",
			"retryable":true, "details":retirement_worker}
	var retained := _retain_source_publication(main, snapshot, publication_view, "tree_section_compile")
	if retained.get("status") != "ready": return retained
	var view: Dictionary = retained.get("view", {})
	var token := String(retained.get("leaseToken", ""))
	var result := _request_ecology_tree_source_compile_owned(main, snapshot, consumer_token, view, token)
	var job: Dictionary = ecology_source_compile_jobs.get(String(result.get("jobKey", "")), {})
	if String(job.get("publicationLeaseToken", "")) != token:
		main.call("release_ecology_source_publication", token)
	return result


func _request_ecology_tree_source_compile_owned(main: Object, snapshot: Dictionary,
		consumer_token: String, publication_view: Dictionary, publication_token: String) -> Dictionary:
	if not is_instance_valid(main) or not snapshot.is_read_only() \
			or String(snapshot.get("status", "")) != "ready":
		return {"status":"pending", "reason":"ecology_source_compile_snapshot_unsealed",
			"retryable":true}
	var tree_family: Dictionary = publication_view.get("familyResultsById", {}).get("trees", {})
	if String(tree_family.get("status", "")) != "ready":
		return {"status":"pending", "reason":"ecology_tree_family_coverage_incomplete",
			"familyDisposition":String(tree_family.get("disposition", "")), "retryable":true}
	var domain_current: Variant = main.call("ecology_source_publication_local_is_current", publication_view, publication_token)
	if not domain_current is Dictionary or String(domain_current.get("status", "")) != "ready":
		return domain_current if domain_current is Dictionary else {
			"status":"pending", "reason":"ecology_tree_domain_currentness_unavailable", "retryable":true}
	var world_id := String(snapshot.get("worldId", ""))
	var chunk: Variant = snapshot.get("sourceChunkKey", null)
	var source_revision := String(snapshot.get("sourceRevision", ""))
	var producer_revision := String(snapshot.get("producerSnapshotRevision", ""))
	var source_digest := String(snapshot.get("sourceManifestDigest", ""))
	if world_id.is_empty() or not chunk is Vector2i or source_revision.is_empty() \
			or producer_revision.is_empty() or source_digest.length() != 64:
		return {"status":"pending", "reason":"ecology_source_compile_identity_incomplete",
			"retryable":true}
	var key := _ecology_source_compile_key(world_id, chunk, source_revision,
		String(tree_family.get("familyRevision", "")),
		String(tree_family.get("sourceManifestDigest", ""))) + "|owner:" + str(main.get_instance_id()) \
		+ "|catalog:" + String(snapshot.get("catalogArtifactId", ""))
	var job: Dictionary = ecology_source_compile_jobs.get(key, {})
	if not job.is_empty():
		var existing_owner := job.get("main") as WeakRef
		if existing_owner == null or existing_owner.get_ref() != main:
			return {"status":"pending", "reason":"ecology_source_compile_owner_replaced", "retryable":true}
		var existing_current: Variant = main.call("ecology_source_publication_local_is_current",
			job.get("publicationView", {}), String(job.get("publicationLeaseToken", "")))
		if not existing_current is Dictionary or String(existing_current.get("status", "")) != "ready":
			return existing_current if existing_current is Dictionary else {
				"status":"pending", "reason":"ecology_tree_domain_currentness_unavailable", "retryable":true}
	if job.is_empty():
		if ecology_source_compile_jobs.size() >= MAX_ECOLOGY_SOURCE_COMPILE_JOBS:
			var evicted := false
			for old_key_value: Variant in ecology_source_compile_order.duplicate():
				var old_key := String(old_key_value)
				var old_job: Dictionary = ecology_source_compile_jobs.get(old_key, {})
				if old_job.get("status", "") == "complete" \
						and old_job.get("consumers", {}).is_empty():
					if _retire_tree_source_cache_job(old_key, old_job):
						evicted = true
						break
			if not evicted:
				return {"status":"pending", "reason":"ecology_source_compile_queue_full",
					"retryable":true, "jobKey":key}
		var frozen_snapshot: Dictionary = snapshot
		var tree_records: Array = []
		for row_value: Variant in frozen_snapshot.get("sourceRows", []):
			if not row_value is Dictionary:
				return {"status":"failed", "reason":"ecology_source_compile_row_invalid"}
			if String(row_value.get("producerFamily", "")) == "trees":
				tree_records.append(row_value)
		var native_dispatcher := _tree_geometry_dispatcher()
		if native_dispatcher == null:
			return {"status":"pending", "reason":"native_tree_geometry_dispatcher_unavailable",
				"retryable":true, "jobKey":key}
		var compiler = TreeRecipeSectionCompilerScript.new()
		compiler.set_native_tree_geometry_dispatcher(native_dispatcher)
		job = {"key":key, "worldId":world_id, "sourceChunkKey":chunk,
			"main":weakref(main),
			"publicationLeaseToken":publication_token, "publicationView":publication_view,
			"treeFamilyRevision":String(tree_family.get("familyRevision", "")),
			"treeFamilyManifestDigest":String(tree_family.get("sourceManifestDigest", "")),
			"sourceRevision":source_revision, "producerSnapshotRevision":producer_revision,
			"sourceManifestDigest":source_digest, "snapshot":frozen_snapshot,
			"snapshotDigest":String(publication_view.get("contentDigest", "")),
			"compiler":compiler, "consumers":{}, "status":"queued",
			"result":{}, "reason":"ecology_tree_source_compile_queued",
			"startedUsec":Time.get_ticks_usec(), "workUnits":0}
		if tree_records.is_empty():
			# A complete source domain can authoritatively contain no trees. Keep
			# this explicit empty result distinct from a missing or pending domain.
			job["status"] = "complete"
			job["result"] = {"status":"ready", "schema":CompiledTreeSectionArtifact.FAMILY_SOURCE_SCHEMA,
				"treeFamilyRevision":String(tree_family.get("familyRevision", "")),
				"treeFamilyManifestDigest":String(tree_family.get("sourceManifestDigest", "")),
				"worldId":world_id, "sourceChunkKey":chunk,
				"sourceRevision":source_revision,
				"producerSnapshotRevision":producer_revision,
				"sourceManifestDigest":source_digest,
				"sources":[], "batches":[], "resourceBindings":{},
				"oldRepresentationRetention":"caller_owned_until_receipt"}
			job["result"] = _freeze_section_value(job["result"])
		else:
			if not _can_enqueue_tree_value_retirement():
				return {"status":"pending", "reason":"tree_value_retirement_backpressure",
					"retryable":true, "jobKey":key}
			var begun: Dictionary = compiler.begin_from_source_records(main, world_id,
				self, tree_records, frozen_snapshot, publication_view)
			if String(begun.get("status", "")) == "failed":
				if not _retire_untracked_tree_compiler(compiler):
					push_error("Could not transfer rejected tree source compiler values to retirement")
				_release_ecology_compile_catalog_lease(job)
				return begun
			var admitted_progress: Dictionary = compiler.progress_snapshot()
			if String(begun.get("status", "")) != "pending" \
					or String(admitted_progress.get("status", "")) != "pending" \
					or int(admitted_progress.get("recordCount", 0)) != tree_records.size():
				if not _retire_untracked_tree_compiler(compiler):
					push_error("Could not transfer incomplete tree source compiler values to retirement")
				_release_ecology_compile_catalog_lease(job)
				return {"status":"pending", "reason":String(begun.get("reason",
					"ecology_source_compile_admission_pending")),
					"detail":begun, "compilerProgress":admitted_progress,
					"retryable":true}
		ecology_source_compile_jobs[key] = job
		ecology_source_compile_order.append(key)
	if not consumer_token.is_empty():
		var consumers: Dictionary = job.get("consumers", {})
		consumers[consumer_token] = true
		job["consumers"] = consumers
		ecology_source_compile_jobs[key] = job
	return {"status":"ready" if job.get("status", "") == "complete" else "pending",
		"reason":String(job.get("reason", "ecology_tree_source_compile_pending")),
		"jobKey":key, "retryable":job.get("status", "") != "failed"}


## Admit one exact tree producer record to the existing ecology compiler queue.
## This is the shared geometry unit used by multiple target-section projections.
func request_ecology_tree_source_record_compile(main: Object, snapshot: Dictionary,
		source_record: Dictionary, publication_view: Dictionary,
		consumer_token: String, priority_distance_squared := INF) -> Dictionary:
	var retirement_worker: Dictionary = _ensure_tree_value_retirement_worker()
	if String(retirement_worker.get("status", "")) != "ready":
		return {"status":"pending", "reason":"tree_value_retirement_worker_unavailable",
			"retryable":true, "details":retirement_worker}
	if consumer_token.is_empty():
		return {"status":"failed", "reason":"tree_source_record_consumer_identity_required"}
	var retained := _retain_source_publication(main, snapshot, publication_view,
		"tree_source_record_geometry")
	if String(retained.get("status", "")) != "ready": return retained
	var admitted_view: Dictionary = retained.get("view", {})
	var publication_token := String(retained.get("leaseToken", ""))
	var result := _request_ecology_tree_source_record_compile_owned(main, snapshot,
		source_record, admitted_view, publication_token, consumer_token,
		priority_distance_squared)
	var job: Dictionary = ecology_source_compile_jobs.get(String(result.get("jobKey", "")), {})
	if String(job.get("publicationLeaseToken", "")) != publication_token:
		main.call("release_ecology_source_publication", publication_token)
	return result


func _request_ecology_tree_source_record_compile_owned(main: Object,
		snapshot: Dictionary, source_record: Dictionary,
		publication_view: Dictionary, publication_token: String,
		consumer_token: String, priority_distance_squared: float) -> Dictionary:
	if not is_instance_valid(main) or not snapshot.is_read_only() \
			or not source_record.is_read_only() \
			or not is_same(snapshot, publication_view.get("payload", {})) \
			or String(snapshot.get("status", "")) != "ready":
		return {"status":"pending", "reason":"tree_source_record_snapshot_unsealed",
			"retryable":true}
	var family: Dictionary = publication_view.get("familyResultsById", {}).get("trees", {})
	if String(family.get("status", "")) != "ready":
		return {"status":"pending", "reason":"tree_source_record_family_incomplete",
			"retryable":true}
	var source_id := String(source_record.get("sourceId", ""))
	if source_id.is_empty():
		return {"status":"failed", "reason":"tree_source_record_identity_missing"}
	var exact_alias := false
	for family_row_value: Variant in family.get("sourceRows", []):
		if not family_row_value is Dictionary:
			return {"status":"pending", "reason":"tree_source_record_family_row_invalid",
				"retryable":true}
		if String(family_row_value.get("sourceId", "")) == source_id:
			if exact_alias:
				return {"status":"failed", "reason":"tree_source_record_family_id_duplicate"}
			exact_alias = is_same(family_row_value, source_record)
	if not exact_alias:
		return {"status":"failed", "reason":"tree_source_record_not_exact_family_alias"}
	var domain_current: Variant = main.call("ecology_source_publication_local_is_current",
		publication_view, publication_token) \
		if main.has_method("ecology_source_publication_local_is_current") else null
	if not domain_current is Dictionary or String(domain_current.get("status", "")) != "ready":
		return domain_current if domain_current is Dictionary else {"status":"pending",
			"reason":"tree_source_record_domain_currentness_unavailable", "retryable":true}
	var member_current: Variant = main.call("ecology_source_publication_record_is_current",
		publication_view, publication_token, source_record) \
		if main.has_method("ecology_source_publication_record_is_current") else null
	if not member_current is Dictionary or String(member_current.get("status", "")) != "ready":
		return member_current if member_current is Dictionary else {"status":"pending",
			"reason":"tree_source_record_currentness_unavailable", "retryable":true}
	var member_digest := String(member_current.get("memberDigest", ""))
	var world_id := String(snapshot.get("worldId", ""))
	var world_epoch := int(snapshot.get("worldEpoch", -1))
	var chunk: Variant = snapshot.get("sourceChunkKey", null)
	var source_revision := String(snapshot.get("sourceRevision", ""))
	var producer_revision := String(source_record.get("producerRevision", ""))
	var artifact_generation := int(source_record.get("artifactGeneration", 1))
	var catalog_id := String(snapshot.get("catalogArtifactId", ""))
	var catalog_digest := String(snapshot.get("catalogContentDigest", ""))
	var family_revision := String(family.get("familyRevision", ""))
	var family_digest := String(family.get("sourceManifestDigest", ""))
	if world_id.is_empty() or world_epoch < 0 or not chunk is Vector2i \
			or source_revision.is_empty() or producer_revision.is_empty() \
			or artifact_generation < 1 or member_digest.length() != 64 \
			or catalog_id.is_empty() or catalog_digest.length() != 64 \
			or family_revision.is_empty() or family_digest.length() != 64:
		return {"status":"pending", "reason":"tree_source_record_semantic_identity_incomplete",
			"retryable":true}
	var key := "tree-source-record-geometry|%s|%d|%d,%d|%s|%s|%s|%s|%s|%s|%s|%d|%s|%s" % [
		world_id, world_epoch, chunk.x, chunk.y, source_revision, catalog_id,
		catalog_digest, family_revision, family_digest, source_id,
		producer_revision, artifact_generation, member_digest,
		TREE_SOURCE_RECORD_CACHE_REVISION + ":" + CompiledTreeSectionArtifact.SOURCE_RECORD_GEOMETRY_SCHEMA]
	var job: Dictionary = ecology_source_compile_jobs.get(key, {})
	if not job.is_empty():
		var owner_ref: WeakRef = job.get("main") as WeakRef
		if owner_ref == null or owner_ref.get_ref() != main:
			if not _retire_tree_source_cache_job(key, job):
				return {"status":"pending", "reason":"tree_source_value_retirement_backpressure",
					"retryable":true, "jobKey":key}
			job = {}
	if not job.is_empty():
		var old_consumers: Dictionary = job.get("consumers", {})
		if String(job.get("artifactKind", "")) != "tree_source_record_geometry" \
				or String(job.get("sourceId", "")) != source_id \
				or String(job.get("memberDigest", "")) != member_digest:
			return {"status":"failed", "reason":"tree_source_record_compile_key_collision",
				"jobKey":key}
		if String(job.get("status", "")) == "failed":
			return {"status":"failed", "reason":String(job.get("reason",
				"tree_source_record_compile_failed")), "jobKey":key,
				"sourceId":source_id, "memberDigest":member_digest}
		old_consumers[consumer_token] = true
		ecology_tree_source_record_cache_reuse_count += 1
		job["consumers"] = old_consumers
		job["priorityDistanceSquared"] = minf(float(job.get("priorityDistanceSquared", INF)),
			priority_distance_squared)
		ecology_source_compile_jobs[key] = job
		var completed_holder: Variant = job.get("resultHolder", null)
		var completed_artifact: Dictionary = _tree_artifact_holder_view(completed_holder) \
			if completed_holder is Dictionary else {}
		return {"status":"ready" if String(job.get("status", "")) == "complete" else "pending",
			"reason":String(job.get("reason", "tree_source_record_compile_pending")),
			"jobKey":key, "sourceId":source_id, "memberDigest":member_digest,
			"consumerToken":consumer_token, "retryable":String(job.get("status", "")) != "failed",
			"artifact":completed_artifact, "sourceArtifactHolder":completed_holder}
	if ecology_source_compile_jobs.size() >= MAX_ECOLOGY_SOURCE_COMPILE_JOBS:
		var evicted := false
		for old_key_value: Variant in ecology_source_compile_order.duplicate():
			var old_key := String(old_key_value)
			var old_job: Dictionary = ecology_source_compile_jobs.get(old_key, {})
			if String(old_job.get("status", "")) == "complete" \
					and old_job.get("consumers", {}).is_empty():
				if _retire_tree_source_cache_job(old_key, old_job):
					evicted = true
					break
		if not evicted:
			return {"status":"pending", "reason":"ecology_source_compile_queue_full",
				"retryable":true}
	if not _can_enqueue_tree_value_retirement():
		return {"status":"pending", "reason":"tree_value_retirement_backpressure",
			"retryable":true}
	var native_dispatcher := _tree_geometry_dispatcher()
	if native_dispatcher == null:
		return {"status":"pending", "reason":"native_tree_geometry_dispatcher_unavailable",
			"retryable":true}
	var compiler := TreeRecipeSectionCompilerScript.new()
	compiler.set_native_tree_geometry_dispatcher(native_dispatcher)
	var begun: Dictionary = compiler.begin_from_source_record(main, world_id, self,
		source_record, snapshot, publication_view)
	if String(begun.get("status", "")) != "pending":
		if not _retire_untracked_tree_compiler(compiler):
			push_error("Could not transfer rejected tree source record values to retirement")
		return begun
	var progress: Dictionary = compiler.progress_snapshot()
	if String(progress.get("status", "")) != "pending" \
			or int(progress.get("recordCount", 0)) != 1:
		if not _retire_untracked_tree_compiler(compiler):
			push_error("Could not transfer incomplete tree source record values to retirement")
		return {"status":"pending", "reason":"tree_source_record_compile_admission_incomplete",
			"compilerProgress":progress, "retryable":true}
	job = {"key":key, "artifactKind":"tree_source_record_geometry",
		"worldId":world_id, "worldEpoch":world_epoch, "sourceChunkKey":chunk,
		"sourceRevision":source_revision, "producerSnapshotRevision":producer_revision,
		"treeFamilyRevision":family_revision, "treeFamilyManifestDigest":family_digest,
		"sourceId":source_id, "memberDigest":member_digest,
		"publicationLeaseToken":publication_token, "publicationView":publication_view,
		"snapshot":snapshot, "sourceRecord":source_record,
		"main":weakref(main), "compiler":compiler,
		"consumers":{consumer_token:true}, "status":"queued", "result":{},
		"reason":"tree_source_record_compile_queued", "workUnits":0,
		"lastReportedWorkUnits":0, "priorityDistanceSquared":priority_distance_squared,
		"startedUsec":Time.get_ticks_usec()}
	ecology_tree_source_record_compile_start_count += 1
	ecology_source_compile_jobs[key] = job
	ecology_source_compile_order.append(key)
	return {"status":"pending", "reason":"tree_source_record_compile_queued",
		"jobKey":key, "sourceId":source_id, "memberDigest":member_digest,
		"consumerToken":consumer_token, "retryable":true}


func poll_ecology_tree_source_record_compile(job_key: String,
		consumer_token: String) -> Dictionary:
	if consumer_token.is_empty():
		return {"status":"failed", "reason":"tree_source_record_consumer_identity_required",
			"jobKey":job_key}
	var job: Dictionary = ecology_source_compile_jobs.get(job_key, {})
	if job.is_empty() or String(job.get("artifactKind", "")) != "tree_source_record_geometry":
		return {"status":"pending", "reason":"tree_source_record_compile_job_missing",
			"retryable":true, "jobKey":job_key}
	if not job.get("consumers", {}).has(consumer_token):
		return {"status":"failed", "reason":"tree_source_record_consumer_not_attached",
			"jobKey":job_key}
	if String(job.get("status", "")) == "failed":
		return {"status":"failed", "reason":String(job.get("reason",
			"tree_source_record_compile_failed")), "jobKey":job_key}
	var main_ref: WeakRef = job.get("main") as WeakRef
	var main: Object = main_ref.get_ref() if main_ref != null else null
	var view: Dictionary = job.get("publicationView", {})
	var token := String(job.get("publicationLeaseToken", ""))
	if not is_instance_valid(main) or token.is_empty() \
			or not is_same(job.get("snapshot", {}), view.get("payload", {})):
		return {"status":"pending", "reason":"tree_source_record_compile_authority_unavailable",
			"retryable":true, "jobKey":job_key}
	var current: Variant = main.call("ecology_source_publication_local_is_current", view, token) \
		if main.has_method("ecology_source_publication_local_is_current") else null
	if not current is Dictionary or String(current.get("status", "")) != "ready":
		return current if current is Dictionary else {"status":"pending",
			"reason":"tree_source_record_compile_domain_currentness_unavailable",
			"retryable":true, "jobKey":job_key}
	var row: Dictionary = job.get("sourceRecord", {})
	var row_current: Variant = main.call("ecology_source_publication_record_is_current",
		view, token, row) if main.has_method("ecology_source_publication_record_is_current") else null
	if not row_current is Dictionary or String(row_current.get("status", "")) != "ready":
		return row_current if row_current is Dictionary else {"status":"pending",
			"reason":"tree_source_record_compile_member_currentness_unavailable",
			"retryable":true, "jobKey":job_key}
	if String(row_current.get("memberDigest", "")) != String(job.get("memberDigest", "")):
		return {"status":"failed", "reason":"tree_source_record_member_digest_stale",
			"jobKey":job_key}
	if String(job.get("status", "")) != "complete":
		return {"status":"pending", "reason":String(job.get("reason",
			"tree_source_record_compile_pending")), "retryable":true, "jobKey":job_key,
			"workUnits":int(job.get("workUnits", 0))}
	var holder: Variant = job.get("resultHolder", null)
	var artifact: Dictionary = _tree_artifact_holder_view(holder) \
		if holder is Dictionary else {}
	if not artifact is Dictionary or not artifact.is_read_only() \
			or String(artifact.get("schema", "")) \
			!= CompiledTreeSectionArtifact.SOURCE_RECORD_GEOMETRY_SCHEMA \
			or String(artifact.get("sourceId", "")) != String(job.get("sourceId", "")) \
			or String(artifact.get("sourceRecordDigest", "")) != String(job.get("memberDigest", "")):
		return {"status":"failed", "reason":"tree_source_record_compile_artifact_identity_mismatch",
			"jobKey":job_key}
	return {"status":"ready", "artifact":artifact, "sourceArtifactHolder":holder,
		"jobKey":job_key,
		"sourceId":String(job.get("sourceId", "")),
		"sourceArtifactDigest":String(artifact.get("sourceArtifactDigest", ""))}


## Admit a tree compile for one certified producer band. Source-family coverage
## remains whole-domain authority; only the exact projected source IDs enter
## this compiler job.
func request_ecology_tree_source_band_compile(main: Object, snapshot: Dictionary,
		section_key: Vector3i, authority: Dictionary,
		publication_view: Dictionary = {}, consumer_token := "",
		priority_distance_squared := INF) -> Dictionary:
	var retirement_worker: Dictionary = _ensure_tree_value_retirement_worker()
	if String(retirement_worker.get("status", "")) != "ready":
		return {"status":"pending", "reason":"tree_value_retirement_worker_unavailable",
			"retryable":true, "details":retirement_worker}
	if not is_instance_valid(main) or not snapshot.is_read_only() \
			or String(snapshot.get("status", "")) != "ready" \
			or String(authority.get("schema", "")) != "ecology-tree-source-family-band-authority/v1" \
			or authority.get("sectionKey", null) != section_key \
			or authority.get("sourceChunkKey", null) != snapshot.get("sourceChunkKey", null) \
			or String(authority.get("sourceRevision", "")) != String(snapshot.get("sourceRevision", "")) \
			or String(authority.get("sourcePublicationId", "")) \
			!= String(publication_view.get("publicationId", "")) \
			or String(authority.get("sourcePublicationContentDigest", "")) \
			!= String(publication_view.get("contentDigest", "")):
		return {"status":"pending", "reason":"tree_source_band_admission_identity_pending",
			"retryable":true}
	var current: Variant = main.call("ecology_source_publication_local_is_current",
		publication_view, String(authority.get("publicationLeaseToken", ""))) \
		if main.has_method("ecology_source_publication_local_is_current") else null
	if not current is Dictionary or String(current.get("status", "")) != "ready":
		return current if current is Dictionary else {"status":"pending",
			"reason":"tree_source_band_publication_currentness_unavailable", "retryable":true}
	var expected_ids_value: Variant = authority.get("producerSourceIds", null)
	var tree_family: Dictionary = publication_view.get("familyResultsById", {}).get("trees", {})
	if not expected_ids_value is Array or String(tree_family.get("status", "")) != "ready" \
			or String(tree_family.get("familyRevision", "")) != String(
				authority.get("sourceFamilyRevision", "")) \
			or String(tree_family.get("sourceManifestDigest", "")) != String(
				authority.get("sourceFamilyManifestDigest", "")):
		return {"status":"pending", "reason":"tree_source_band_family_authority_pending",
			"retryable":true}
	var expected_ids: Array[String] = []
	for value: Variant in expected_ids_value:
		if not value is String or String(value).is_empty() or String(value) in expected_ids:
			return {"status":"failed", "reason":"tree_source_band_expected_ids_invalid"}
		expected_ids.append(String(value))
	expected_ids.sort()
	var records_by_id: Dictionary = {}
	for value: Variant in tree_family.get("sourceRows", []):
		if not value is Dictionary:
			return {"status":"pending", "reason":"tree_source_band_family_row_invalid",
				"retryable":true}
		var row: Dictionary = value
		var id := String(row.get("sourceId", ""))
		if id.is_empty() or records_by_id.has(id):
			return {"status":"failed", "reason":"tree_source_band_family_id_duplicate"}
		records_by_id[id] = row
	var records: Array = []
	for id: String in expected_ids:
		if not records_by_id.has(id):
			return {"status":"pending", "reason":"tree_source_band_source_record_missing",
				"sourceId":id, "retryable":true}
		var row: Dictionary = records_by_id[id]
		var row_current: Variant = main.call("ecology_source_publication_record_is_current",
			publication_view, String(authority.get("publicationLeaseToken", "")), row) \
			if main.has_method("ecology_source_publication_record_is_current") else null
		if not row_current is Dictionary or String(row_current.get("status", "")) != "ready":
			return row_current if row_current is Dictionary else {"status":"pending",
				"reason":"tree_source_band_record_currentness_unavailable", "retryable":true}
		records.append(row)
	var world_id := String(snapshot.get("worldId", ""))
	var chunk: Variant = snapshot.get("sourceChunkKey", null)
	var authority_digest := String(authority.get("authorityDigest", ""))
	var source_revision := String(snapshot.get("sourceRevision", ""))
	var family_revision := String(tree_family.get("familyRevision", ""))
	var family_digest := String(tree_family.get("sourceManifestDigest", ""))
	if world_id.is_empty() or not chunk is Vector2i or authority_digest.length() != 64 \
			or source_revision.is_empty() or family_revision.is_empty() \
			or family_digest.length() != 64:
		return {"status":"pending", "reason":"tree_source_band_compile_identity_missing",
			"retryable":true}
	var key := "%s|%d,%d|%d,%d,%d|%s|%s|%s|%s" % [world_id,
		chunk.x, chunk.y, section_key.x, section_key.y, section_key.z,
		authority_digest, source_revision, family_revision, family_digest]
	if consumer_token.is_empty():
		ecology_tree_band_consumer_serial += 1
		consumer_token = "tree-band-consumer:%d:%d" % [get_instance_id(),
			ecology_tree_band_consumer_serial]
	return _request_tree_source_record_band_projection(main, snapshot, publication_view,
		section_key, authority, expected_ids, records, key, consumer_token,
		priority_distance_squared)


func _request_tree_source_record_band_projection(main: Object, snapshot: Dictionary,
		publication_view: Dictionary, section_key: Vector3i, authority: Dictionary,
		expected_ids: Array[String], records: Array, key: String,
		consumer_token: String, priority_distance_squared: float) -> Dictionary:
	var job: Dictionary = ecology_tree_band_compile_jobs.get(key, {})
	if job.is_empty():
		if ecology_tree_band_compile_jobs.size() >= MAX_TREE_BAND_COMPILE_JOBS:
			var evicted := false
			for old_key_value: Variant in ecology_tree_band_compile_order.duplicate():
				var old_key := String(old_key_value)
				var old_job: Dictionary = ecology_tree_band_compile_jobs.get(old_key, {})
				if String(old_job.get("status", "")) in ["complete", "failed", "suspended"] \
						and old_job.get("consumers", {}).is_empty():
					if _retire_tree_band_cache_job(old_key, old_job):
						evicted = true
						break
			if not evicted:
				return {"status":"pending", "reason":"tree_source_band_queue_full",
					"retryable":true, "jobKey":key}
		var record_map: Dictionary = {}
		for row_value: Variant in records:
			if not row_value is Dictionary:
				return {"status":"failed", "reason":"tree_source_band_record_invalid"}
			record_map[String(row_value.get("sourceId", ""))] = row_value
		var empty := expected_ids.is_empty()
		var artifact: Dictionary = {}
		if empty:
			artifact = {
				"status":"ready", "schema":CompiledTreeSectionArtifact.SCHEMA,
				"worldId":String(snapshot.get("worldId", "")),
				"sourceChunkKey":snapshot.get("sourceChunkKey", Vector2i.ZERO),
				"sectionKey":section_key,
				"sourceRevision":String(snapshot.get("sourceRevision", "")),
				"treeFamilyRevision":String(authority.get("sourceFamilyRevision", "")),
				"treeFamilyManifestDigest":String(authority.get("sourceFamilyManifestDigest", "")),
				"authorityDigest":String(authority.get("authorityDigest", "")),
				"expectedSourceIds":[], "sourceArtifactDigests":[],
				"sourceCompletionManifest":[], "sourceCompletionDigest":_source_recipe_digest([]),
				"sources":[], "batches":[], "resourceBindings":{},
				"ownerBatchContributors":[], "ownerBatchPayloadDigest":_source_recipe_digest([]),
				"disposition":"complete_empty",
				"oldRepresentationRetention":"caller_owned_until_receipt"}
			_freeze_tree_band_artifact_in_place(artifact)
		var artifact_holder: Dictionary = _tree_artifact_holder(artifact) if empty else {}
		if empty and artifact_holder.is_empty():
			return {"status":"failed", "reason":"tree_source_band_empty_holder_invalid"}
		job = {"key":key, "artifactKind":"tree_source_record_projection",
			"status":"complete" if empty else "queued",
			"reason":"tree_source_band_compile_empty" if empty else "tree_source_record_projection_waiting",
			"worldId":String(snapshot.get("worldId", "")),
			"sourceChunkKey":snapshot.get("sourceChunkKey", Vector2i.ZERO),
			"sectionKey":section_key, "authority":authority,
			"authorityDigest":String(authority.get("authorityDigest", "")),
			"snapshot":snapshot, "publicationView":publication_view,
			"expectedSourceIds":expected_ids, "records":records,
			"recordsById":record_map, "recordJobKeys":{},
			"sourceArtifactsById":{},
			"recordConsumerTokensByConsumer":{}, "artifact":{},
			"artifactHolder":artifact_holder,
			"main":weakref(main),
			"consumers":{}, "enqueuedUsec":Time.get_ticks_usec(),
			"priorityDistanceSquared":priority_distance_squared,
			"projectionCount":0, "projectionUsec":0}
		ecology_tree_band_compile_jobs[key] = job
		ecology_tree_band_compile_order.append(key)
	else:
		if String(job.get("authorityDigest", "")) != String(authority.get("authorityDigest", "")):
			return {"status":"failed", "reason":"tree_source_band_compile_key_collision",
				"jobKey":key}
		if String(job.get("status", "")) == "failed":
			return {"status":"failed", "reason":String(job.get("reason",
				"tree_source_band_compile_failed")), "jobKey":key,
				"retryable":false}
		if String(job.get("status", "")) == "suspended":
			job["status"] = "queued"
			job["reason"] = "tree_source_record_projection_resumed"
	var consumers: Dictionary = job.get("consumers", {})
	consumers[consumer_token] = true
	job["consumers"] = consumers
	job["priorityDistanceSquared"] = minf(float(job.get("priorityDistanceSquared", INF)),
		priority_distance_squared)
	var token_map_by_consumer: Dictionary = job.get("recordConsumerTokensByConsumer", {})
	var token_map: Dictionary = token_map_by_consumer.get(consumer_token, {})
	var record_keys: Dictionary = job.get("recordJobKeys", {})
	for source_id: String in expected_ids:
		if job.get("sourceArtifactsById", {}).has(source_id):
			token_map.erase(source_id)
			continue
		if not record_map_has_source(job, source_id):
			job["recordJobKeys"] = record_keys
			token_map_by_consumer[consumer_token] = token_map
			job["recordConsumerTokensByConsumer"] = token_map_by_consumer
			ecology_tree_band_compile_jobs[key] = job
			return {"status":"pending", "reason":"tree_source_band_source_record_missing",
				"sourceId":source_id, "retryable":true, "jobKey":key,
				"consumerToken":consumer_token}
		var source_consumer := "tree-band-source:%s:%s" % [
			_source_recipe_digest([key, consumer_token, source_id]), source_id]
		var admitted: Dictionary = request_ecology_tree_source_record_compile(main,
			snapshot, job.get("recordsById", {}).get(source_id, {}),
			publication_view, source_consumer, priority_distance_squared)
		if String(admitted.get("status", "")) == "failed":
			job["status"] = "failed"
			job["reason"] = String(admitted.get("reason",
				"tree_source_record_compile_failed"))
			job["consumers"] = consumers
			var failed_source_job_key := String(admitted.get("jobKey", ""))
			var failed_source_consumer := String(admitted.get("consumerToken", ""))
			if not failed_source_job_key.is_empty() and not failed_source_consumer.is_empty():
				record_keys[source_id] = failed_source_job_key
				token_map[source_id] = failed_source_consumer
			job["recordJobKeys"] = record_keys
			token_map_by_consumer[consumer_token] = token_map
			job["recordConsumerTokensByConsumer"] = token_map_by_consumer
			ecology_tree_band_compile_jobs[key] = job
			return {"status":"failed", "reason":String(job.get("reason", "")),
				"retryable":false, "jobKey":key,
				"consumerToken":consumer_token}
		var source_job_key := String(admitted.get("jobKey", ""))
		if source_job_key.is_empty():
			job["reason"] = String(admitted.get("reason",
				"tree_source_record_compile_backpressure"))
			job["consumers"] = consumers
			job["recordJobKeys"] = record_keys
			token_map_by_consumer[consumer_token] = token_map
			job["recordConsumerTokensByConsumer"] = token_map_by_consumer
			ecology_tree_band_compile_jobs[key] = job
			return {"status":"pending", "reason":String(job.get("reason", "")),
				"sourceId":source_id, "retryable":true, "jobKey":key,
				"consumerToken":consumer_token}
		var source_consumer_receipt := String(admitted.get("consumerToken", ""))
		if source_consumer_receipt.is_empty():
			# A pending source request can carry a prospective cache key while
			# retirement backpressure prevents attachment. Keep this band demand
			# retryable, but retain only consumers admitted by earlier records.
			if String(admitted.get("status", "")) == "pending":
				job["reason"] = String(admitted.get("reason",
					"tree_source_record_compile_backpressure"))
				job["consumers"] = consumers
				job["recordJobKeys"] = record_keys
				token_map_by_consumer[consumer_token] = token_map
				job["recordConsumerTokensByConsumer"] = token_map_by_consumer
				ecology_tree_band_compile_jobs[key] = job
				return {"status":"pending", "reason":String(job.get("reason", "")),
					"sourceId":source_id, "retryable":true, "jobKey":key,
					"consumerToken":consumer_token,
					"sourceAdmissionJobKey":source_job_key}
			job["status"] = "failed"
			job["reason"] = "tree_source_record_admission_consumer_missing"
			job["consumers"] = consumers
			job["recordJobKeys"] = record_keys
			token_map_by_consumer[consumer_token] = token_map
			job["recordConsumerTokensByConsumer"] = token_map_by_consumer
			ecology_tree_band_compile_jobs[key] = job
			return {"status":"failed", "reason":String(job["reason"]),
				"retryable":false, "jobKey":key,
				"consumerToken":consumer_token}
		record_keys[source_id] = source_job_key
		token_map[source_id] = source_consumer_receipt
		job["recordJobKeys"] = record_keys
		token_map_by_consumer[consumer_token] = token_map
		job["recordConsumerTokensByConsumer"] = token_map_by_consumer
		ecology_tree_band_compile_jobs[key] = job
	job["recordJobKeys"] = record_keys
	token_map_by_consumer[consumer_token] = token_map
	job["recordConsumerTokensByConsumer"] = token_map_by_consumer
	job["reason"] = "tree_source_record_projection_waiting"
	ecology_tree_band_compile_jobs[key] = job
	var artifact_holder: Variant = job.get("artifactHolder", null)
	var artifact_view: Dictionary = _tree_artifact_holder_view(artifact_holder) \
		if artifact_holder is Dictionary else {}
	return {"status":"ready" if String(job.get("status", "")) == "complete" else "pending",
		"reason":String(job.get("reason", "tree_source_record_projection_waiting")),
		"jobKey":key, "consumerToken":consumer_token,
		"artifact":artifact_view, "retryable":true,
		"sourceJobCount":record_keys.size()}


func record_map_has_source(job: Dictionary, source_id: String) -> bool:
	return job.get("recordsById", {}).has(source_id)


func poll_ecology_tree_source_band_compile(job_key: String,
		consumer_token := "") -> Dictionary:
	if consumer_token.is_empty():
		return {"status":"failed", "reason":"tree_source_band_consumer_identity_required",
			"jobKey":job_key}
	var job: Dictionary = ecology_tree_band_compile_jobs.get(job_key, {})
	if job.is_empty():
		return {"status":"pending", "reason":"tree_source_band_compile_job_missing",
			"retryable":true, "jobKey":job_key}
	if not job.get("consumers", {}).has(consumer_token):
		return {"status":"failed", "reason":"tree_source_band_consumer_not_attached",
			"jobKey":job_key}
	if String(job.get("status", "")) == "failed":
		return {"status":"failed", "reason":String(job.get("reason", "tree_source_band_compile_failed")),
			"jobKey":job_key}
	if String(job.get("status", "")) != "complete":
		return {"status":"pending", "reason":String(job.get("reason",
			"tree_source_band_compile_pending")), "retryable":true, "jobKey":job_key}
	var artifact_holder: Variant = job.get("artifactHolder", null)
	var artifact: Dictionary = _tree_artifact_holder_view(artifact_holder) \
		if artifact_holder is Dictionary else {}
	if not artifact is Dictionary or not artifact.is_read_only() \
			or artifact.get("sectionKey", null) != job.get("sectionKey", null) \
			or String(artifact.get("authorityDigest", "")) != String(job.get("authorityDigest", "")):
		return {"status":"pending", "reason":"tree_source_band_artifact_identity_stale",
			"retryable":true, "jobKey":job_key}
	var current := _tree_band_compile_sources_current(job)
	if not current is Dictionary or String(current.get("status", "")) != "ready":
		return current if current is Dictionary else {"status":"pending",
			"reason":"tree_source_band_currentness_unavailable", "retryable":true}
	return {"status":"ready", "artifact":artifact, "jobKey":job_key}


func cancel_ecology_tree_source_band_compile(job_key: String,
		consumer_token := "") -> void:
	if consumer_token.is_empty(): return
	if not ecology_tree_band_compile_jobs.has(job_key): return
	var job: Dictionary = ecology_tree_band_compile_jobs[job_key]
	var consumers: Dictionary = job.get("consumers", {})
	if not consumer_token.is_empty(): consumers.erase(consumer_token)
	job["consumers"] = consumers
	var token_maps: Dictionary = job.get("recordConsumerTokensByConsumer", {})
	var token_map: Dictionary = token_maps.get(consumer_token, {})
	var record_job_keys: Dictionary = job.get("recordJobKeys", {})
	for source_id_value: Variant in token_map:
		var source_id := String(source_id_value)
		var source_job_key := String(record_job_keys.get(source_id, ""))
		var source_token := String(token_map[source_id_value])
		if not source_job_key.is_empty() and not source_token.is_empty():
			cancel_ecology_tree_source_compile(source_job_key, source_token)
	token_maps.erase(consumer_token)
	job["recordConsumerTokensByConsumer"] = token_maps
	if not consumers.is_empty():
		ecology_tree_band_compile_jobs[job_key] = job
		return
	if String(job.get("status", "")) in ["queued", "active", "suspended"]:
		# Keep completed source aliases under the existing bounded band-cache
		# owner. The per-band compiler remains paused with its exact partial state;
		# a later matching request resumes it without dropping partial buffers.
		job["status"] = "suspended"
		job["reason"] = "tree_source_record_projection_suspended_without_consumers"
		ecology_tree_band_compile_jobs[job_key] = job
	elif String(job.get("status", "")) == "failed":
		if not _retire_tree_band_cache_job(job_key, job):
			job["retirementPending"] = true
			ecology_tree_band_compile_jobs[job_key] = job
	else:
		ecology_tree_band_compile_jobs[job_key] = job


func poll_ecology_tree_source_compile(job_key: String,
		consumer_token := "") -> Dictionary:
	if not ecology_source_compile_jobs.has(job_key):
		return {"status":"pending", "reason":"ecology_source_compile_job_missing",
			"retryable":true, "jobKey":job_key}
	var job: Dictionary = ecology_source_compile_jobs[job_key]
	if not consumer_token.is_empty():
		var consumers: Dictionary = job.get("consumers", {})
		consumers[consumer_token] = true
		job["consumers"] = consumers
		ecology_source_compile_jobs[job_key] = job
	if not is_same(job.get("snapshot", {}), job.get("publicationView", {}).get("payload", {})):
		job["status"] = "failed"
		job["reason"] = "ecology_source_compile_snapshot_identity_changed"
		_release_ecology_compile_catalog_lease(job)
		ecology_source_compile_jobs[job_key] = job
		return {"status":"failed", "reason":String(job.reason), "jobKey":job_key}
	if String(job.get("status", "")) == "failed":
		return {"status":"failed", "reason":String(job.get("reason", "ecology_source_compile_failed")),
			"jobKey":job_key}
	if String(job.get("status", "")) != "complete":
		return {"status":"pending", "reason":String(job.get("reason",
			"ecology_tree_source_compile_pending")), "retryable":true, "jobKey":job_key,
			"workUnits":int(job.get("workUnits", 0))}
	# The queue can be hosted by a world/runtime node while detached Main is
	# still the producer authority (for example, during loading or a fixture).
	# Bind completion to the authority captured when this job was admitted;
	# the queue's current parent is only its execution owner.
	var authority_ref := job.get("main") as WeakRef
	var main: Object = authority_ref.get_ref() if authority_ref != null else null
	if not is_instance_valid(main) or not main.has_method("ecology_source_publication_local_is_current"):
		return {"status":"pending", "reason":"ecology_source_compile_authority_unavailable",
			"retryable":true, "jobKey":job_key}
	var snapshot: Dictionary = job.get("snapshot", {})
	var view: Dictionary = job.get("publicationView", {})
	var tree_family: Dictionary = view.get("familyResultsById", {}).get("trees", {})
	if String(tree_family.get("status", "")) != "ready" \
			or String(tree_family.get("familyRevision", "")) != String(job.get("treeFamilyRevision", "")) \
			or String(tree_family.get("sourceManifestDigest", "")) != String(job.get("treeFamilyManifestDigest", "")):
		return {"status":"failed", "reason":"ecology_tree_family_identity_changed", "jobKey":job_key}
	# This is required even for zero tree rows: absence cannot bypass source,
	# removal or catalog authority checks merely because no record can be polled.
	var domain_current: Variant = main.call("ecology_source_publication_local_is_current", view,
		String(job.get("publicationLeaseToken", "")))
	if not domain_current is Dictionary or String(domain_current.get("status", "")) != "ready":
		return domain_current if domain_current is Dictionary else {
			"status":"pending", "reason":"ecology_tree_domain_currentness_unavailable", "retryable":true}
	for row_value: Variant in snapshot.get("sourceRows", []):
		if not row_value is Dictionary or String(row_value.get("producerFamily", "")) != "trees":
			continue
		var current: Variant = main.call("ecology_source_publication_record_is_current", view,
			String(job.get("publicationLeaseToken", "")), row_value)
		if not current is Dictionary or String(current.get("status", "")) != "ready":
			return {"status":"pending" if not current is Dictionary or current.get("status", "") == "pending" else "failed",
				"reason":String(current.get("reason", "ecology_source_compile_source_stale")) \
					if current is Dictionary else "ecology_source_compile_currentness_unavailable",
				"retryable":current is Dictionary and current.get("status", "") == "pending",
				"jobKey":job_key}
	return {"status":"ready", "artifact":job.get("result", {}), "jobKey":job_key}


func cancel_ecology_tree_source_compile(job_key: String, consumer_token := "") -> void:
	if not ecology_source_compile_jobs.has(job_key):
		return
	var job: Dictionary = ecology_source_compile_jobs[job_key]
	var consumers: Dictionary = job.get("consumers", {})
	if not consumer_token.is_empty(): consumers.erase(consumer_token)
	job["consumers"] = consumers
	if not consumers.is_empty():
		ecology_source_compile_jobs[job_key] = job
		return
	if String(job.get("artifactKind", "")) == "tree_source_record_geometry" \
			and String(job.get("status", "")) == "complete":
		# Completed source geometry is a bounded reusable cache entry. Its
		# publication lease remains held until ordinary capacity eviction.
		ecology_source_compile_jobs[job_key] = job
		return
	if not _retire_tree_source_cache_job(job_key, job):
		job["retirementPending"] = true
		job["reason"] = "tree_source_compile_retirement_backpressure"
		ecology_source_compile_jobs[job_key] = job


func _release_ecology_compile_catalog_lease(job: Dictionary) -> void:
	var owner_ref := job.get("main") as WeakRef
	var owner: Object = owner_ref.get_ref() if owner_ref != null else null
	var token := String(job.get("publicationLeaseToken", ""))
	if is_instance_valid(owner) and not token.is_empty() \
			and owner.has_method("release_ecology_source_publication"):
		owner.call("release_ecology_source_publication", token)
	job["publicationLeaseToken"] = ""


func advance_ecology_source_compilers() -> void:
	for key_value: Variant in ecology_source_compile_order.duplicate():
		var key := String(key_value)
		if not ecology_source_compile_jobs.has(key):
			continue
		var job: Dictionary = ecology_source_compile_jobs[key]
		if bool(job.get("retirementPending", false)):
			continue
		if String(job.get("status", "")) != "queued" and String(job.get("status", "")) != "active":
			continue
		var compiler: Object = job.get("compiler")
		if not is_instance_valid(compiler):
			job["status"] = "failed"
			job["reason"] = "ecology_source_compile_compiler_missing"
			_release_ecology_compile_catalog_lease(job)
			ecology_source_compile_jobs[key] = job
			continue
		job["status"] = "active"
		var advanced: Dictionary = compiler.call("advance",
			ECOLOGY_SOURCE_COMPILE_WORK_UNITS_PER_JOB)
		var progress: Dictionary = compiler.call("progress_snapshot") \
			if compiler.has_method("progress_snapshot") else {"status":"unavailable"}
		job["workUnits"] = maxi(0, int(job.get("workUnits", 0)) + int(
			progress.get("workUnits", 0)) - int(job.get("lastReportedWorkUnits", 0)))
		var work_delta := maxi(0, int(progress.get("workUnits", 0)) - int(
			job.get("lastReportedWorkUnits", 0)))
		job["lastReportedWorkUnits"] = int(progress.get("workUnits", 0))
		if String(job.get("artifactKind", "")) == "tree_source_record_geometry":
			ecology_tree_source_record_work_unit_count += work_delta
		job["reason"] = String(advanced.get("reason", "ecology_tree_source_compile_pending"))
		if String(advanced.get("status", "")) == "ready":
			var artifact: Dictionary = advanced.duplicate(true)
			if String(job.get("artifactKind", "")) == "tree_source_record_geometry":
				if String(artifact.get("schema", "")) \
						!= CompiledTreeSectionArtifact.SOURCE_RECORD_GEOMETRY_SCHEMA \
						or String(artifact.get("sourceId", "")) \
						!= String(job.get("sourceId", "")) \
						or String(artifact.get("sourceRecordDigest", "")) \
						!= String(job.get("memberDigest", "")) \
						or artifact.get("sources", []).size() != 1:
					job["status"] = "failed"
					job["reason"] = "tree_source_record_compile_output_identity_mismatch"
					_release_ecology_compile_catalog_lease(job)
					ecology_source_compile_jobs[key] = job
					continue
				var main_ref: WeakRef = job.get("main") as WeakRef
				var main: Object = main_ref.get_ref() if main_ref != null else null
				var current: Dictionary = _tree_source_record_job_current(main, job)
				if String(current.get("status", "")) != "ready":
					job["status"] = "failed"
					job["reason"] = String(current.get("reason",
						"tree_source_record_compile_became_stale"))
					_release_ecology_compile_catalog_lease(job)
					ecology_source_compile_jobs[key] = job
					continue
				artifact["sourceChunkKey"] = job.get("sourceChunkKey", Vector2i.ZERO)
				artifact["sourceRevision"] = String(job.get("sourceRevision", ""))
				artifact["treeFamilyRevision"] = String(job.get("treeFamilyRevision", ""))
				artifact["treeFamilyManifestDigest"] = String(job.get(
					"treeFamilyManifestDigest", ""))
				# These are owned transport copies. Freeze recursively in place so
				# typed float arrays and nested immutable aliases keep their schema.
				_freeze_tree_band_artifact_in_place(artifact)
				var holder := _tree_artifact_holder(artifact)
				if holder.is_empty():
					job["status"] = "failed"
					job["reason"] = "tree_source_record_artifact_holder_invalid"
					_release_ecology_compile_catalog_lease(job)
					ecology_source_compile_jobs[key] = job
					continue
				var compiler_retirement: Dictionary = compiler.call(
					"take_completed_source_retirement_values") \
					if compiler.has_method("take_completed_source_retirement_values") else {}
				if String(compiler_retirement.get("status", "")) != "ready":
					job["status"] = "failed"
					job["reason"] = String(compiler_retirement.get("reason",
						"tree_source_compiler_retirement_unavailable"))
					_release_ecology_compile_catalog_lease(job)
					ecology_source_compile_jobs[key] = job
					continue
				holder["compilerValueRoots"] = compiler_retirement.get("valueRoots", {})
				holder["compilerMainRefCountedKeepalives"] = compiler_retirement.get(
					"mainRefCountedKeepalives", [])
				job["result"] = {}
				job["resultHolder"] = holder
				job["compiler"] = null
				job["status"] = "complete"
				job["reason"] = "tree_source_record_compile_ready"
				ecology_source_compile_jobs[key] = job
				continue
			artifact["worldId"] = String(job.get("worldId", ""))
			artifact["sourceChunkKey"] = job.get("sourceChunkKey", Vector2i.ZERO)
			artifact["sourceRevision"] = String(job.get("sourceRevision", ""))
			artifact["producerSnapshotRevision"] = String(job.get("producerSnapshotRevision", ""))
			artifact["sourceManifestDigest"] = String(job.get("sourceManifestDigest", ""))
			artifact["treeFamilyRevision"] = String(job.get("treeFamilyRevision", ""))
			artifact["treeFamilyManifestDigest"] = String(job.get("treeFamilyManifestDigest", ""))
			job["result"] = _freeze_section_value(artifact)
			job["status"] = "complete"
			job["reason"] = "ecology_tree_source_compile_ready"
		elif String(advanced.get("status", "")) == "failed":
			job["status"] = "failed"
			job["reason"] = String(advanced.get("reason", "ecology_tree_source_compile_failed"))
		elif String(progress.get("status", "")) == "failed":
			job["status"] = "failed"
			job["reason"] = String(progress.get("failureReason",
				advanced.get("reason", "ecology_tree_source_compile_rejected")))
		elif String(progress.get("status", "")) == "idle":
			# The compiler clears its job when it rejects stale/invalid inputs.
			# Promote that terminal rejection instead of polling an idle compiler
			# forever as though the source were still being compiled.
			job["status"] = "failed"
			job["reason"] = String(advanced.get("reason",
				"ecology_tree_source_compile_rejected"))
		if String(job.get("status", "")) == "failed":
			_release_ecology_compile_catalog_lease(job)
		ecology_source_compile_jobs[key] = job
	_advance_tree_band_compile_jobs()


func _tree_source_record_job_current(main: Object, job: Dictionary) -> Dictionary:
	if not is_instance_valid(main) or not main.has_method(
			"ecology_source_publication_local_is_current") \
			or not main.has_method("ecology_source_publication_record_is_current"):
		return {"status":"pending", "reason":"tree_source_record_authority_unavailable"}
	var view: Dictionary = job.get("publicationView", {})
	var token := String(job.get("publicationLeaseToken", ""))
	var current: Variant = main.call("ecology_source_publication_local_is_current", view, token)
	if not current is Dictionary or String(current.get("status", "")) != "ready":
		return current if current is Dictionary else {"status":"pending",
			"reason":"tree_source_record_domain_currentness_unavailable"}
	var row: Dictionary = job.get("sourceRecord", {})
	var row_current: Variant = main.call("ecology_source_publication_record_is_current",
		view, token, row)
	if not row_current is Dictionary or String(row_current.get("status", "")) != "ready":
		return row_current if row_current is Dictionary else {"status":"pending",
			"reason":"tree_source_record_member_currentness_unavailable"}
	if String(row_current.get("memberDigest", "")) != String(job.get("memberDigest", "")):
		return {"status":"failed", "reason":"tree_source_record_member_digest_stale"}
	return {"status":"ready", "memberDigest":String(row_current.get("memberDigest", ""))}


func _advance_tree_band_compile_jobs() -> void:
	if ecology_tree_band_compile_order.is_empty():
		ecology_tree_band_compile_cursor = 0
		return
	var viewer_position := current_viewer_position()
	var inspected := 0
	var candidates: Array[Dictionary] = []
	var order_size := ecology_tree_band_compile_order.size()
	while inspected < mini(TREE_BAND_PRIORITY_SCAN_LIMIT, order_size):
		if ecology_tree_band_compile_cursor >= ecology_tree_band_compile_order.size():
			ecology_tree_band_compile_cursor = 0
		var key := ecology_tree_band_compile_order[ecology_tree_band_compile_cursor]
		ecology_tree_band_compile_cursor += 1
		inspected += 1
		var job: Dictionary = ecology_tree_band_compile_jobs.get(key, {})
		if String(job.get("status", "")) not in ["queued", "active"]:
			continue
		var section: Variant = job.get("sectionKey", null)
		var distance_sq := float(job.get("priorityDistanceSquared", INF))
		if is_finite(viewer_position.x) and section is Vector3i:
			distance_sq = viewer_position.distance_squared_to(
				StaticRenderSectionGridScript.origin_for_key(section) + Vector3.ONE * 8.0)
		var age_seconds := maxf(0.0, float(Time.get_ticks_usec() - int(
			job.get("enqueuedUsec", Time.get_ticks_usec()))) / 1000000.0)
		candidates.append({"key":key, "score":distance_sq - age_seconds \
			* TREE_BAND_PRIORITY_AGE_SCALE_SECONDS * TREE_BAND_PRIORITY_AGE_SCALE_SECONDS})
	if candidates.is_empty(): return
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("score", INF)) < float(b.get("score", INF)))
	var advance_count := mini(TREE_BAND_COMPILE_ADVANCES_PER_FRAME, candidates.size())
	for index in advance_count:
		var key := String(candidates[index].get("key", ""))
		var job: Dictionary = ecology_tree_band_compile_jobs.get(key, {})
		if job.is_empty() or String(job.get("status", "")) not in ["queued", "active"]:
			continue
		if String(job.get("artifactKind", "")) != "tree_source_record_projection":
			job["status"] = "failed"
			job["reason"] = "tree_source_band_legacy_compiler_path_retired"
			ecology_tree_band_compile_jobs[key] = job
			continue
		_advance_tree_source_record_band_projection(key, job)


func _advance_tree_source_record_band_projection(key: String, job: Dictionary) -> void:
	var external_consumers: Dictionary = job.get("consumers", {})
	if external_consumers.is_empty(): return
	var token_maps: Dictionary = job.get("recordConsumerTokensByConsumer", {})
	var artifacts_by_id: Dictionary = job.get("sourceArtifactsById", {})
	var expected_ids: Array = job.get("expectedSourceIds", [])
	var record_keys: Dictionary = job.get("recordJobKeys", {})
	for source_id_value: Variant in expected_ids:
		var source_id := String(source_id_value)
		if artifacts_by_id.has(source_id):
			continue
		var source_job_key := String(record_keys.get(source_id, ""))
		if source_job_key.is_empty():
			var admission := _admit_missing_tree_record_band_source_jobs(job, source_id)
			if String(admission.get("status", "")) != "ready":
				job["reason"] = String(admission.get("reason",
					"tree_source_record_projection_job_pending"))
				if String(admission.get("status", "")) == "failed":
					job["status"] = "failed"
				ecology_tree_band_compile_jobs[key] = job
				return
			record_keys = job.get("recordJobKeys", {})
			token_maps = job.get("recordConsumerTokensByConsumer", {})
			source_job_key = String(record_keys.get(source_id, ""))
			if source_job_key.is_empty():
				job["reason"] = "tree_source_record_projection_job_pending"
				ecology_tree_band_compile_jobs[key] = job
				return
		var source_token := ""
		var source_job: Dictionary = ecology_source_compile_jobs.get(source_job_key, {})
		var attached_source_consumers: Dictionary = source_job.get("consumers", {})
		for external_token_value: Variant in external_consumers:
			var token_map: Dictionary = token_maps.get(String(external_token_value), {})
			var candidate_token := String(token_map.get(source_id, ""))
			if not candidate_token.is_empty() and attached_source_consumers.has(candidate_token):
				source_token = candidate_token
				break
		if source_token.is_empty():
			job["reason"] = "tree_source_record_projection_consumer_pending"
			ecology_tree_band_compile_jobs[key] = job
			return
		var polled := poll_ecology_tree_source_record_compile(source_job_key, source_token)
		if String(polled.get("status", "")) == "failed":
			job["status"] = "failed"
			job["reason"] = String(polled.get("reason", "tree_source_record_compile_failed"))
			ecology_tree_band_compile_jobs[key] = job
			return
		if String(polled.get("status", "")) != "ready":
			job["reason"] = String(polled.get("reason",
				"tree_source_record_projection_waiting"))
			ecology_tree_band_compile_jobs[key] = job
			return
		var artifact: Variant = polled.get("artifact", null)
		if not artifact is Dictionary:
			job["status"] = "failed"
			job["reason"] = "tree_source_record_projection_artifact_missing"
			ecology_tree_band_compile_jobs[key] = job
			return
		# The band job now owns this exact immutable source artifact. Detach all
		# per-consumer cache leases for this record so the bounded shared cache
		# can evict it under pressure without losing this band's proof input.
		artifacts_by_id[source_id] = polled.get("sourceArtifactHolder", {})
		if not artifacts_by_id[source_id] is Dictionary:
			job["status"] = "failed"
			job["reason"] = "tree_source_record_artifact_holder_missing"
			ecology_tree_band_compile_jobs[key] = job
			return
		for external_token_value: Variant in token_maps.keys():
			var external_token := String(external_token_value)
			var token_map: Dictionary = token_maps.get(external_token, {})
			var detach_token := String(token_map.get(source_id, ""))
			if not detach_token.is_empty():
				cancel_ecology_tree_source_compile(source_job_key, detach_token)
				token_map.erase(source_id)
				token_maps[external_token] = token_map
		job["sourceArtifactsById"] = artifacts_by_id
		job["recordConsumerTokensByConsumer"] = token_maps
		# Keep the mutable queue state synchronized before processing another
		# record; cancellation can evict cache entries but never this local alias.
		ecology_tree_band_compile_jobs[key] = job
	var artifacts: Array = []
	var sorted_source_ids: Array[String] = []
	for source_id_value: Variant in expected_ids:
		sorted_source_ids.append(String(source_id_value))
	sorted_source_ids.sort()
	if artifacts_by_id.size() != sorted_source_ids.size():
		job["reason"] = "tree_source_record_projection_artifacts_incomplete"
		ecology_tree_band_compile_jobs[key] = job
		return
	for source_id: String in sorted_source_ids:
		var source_holder: Variant = artifacts_by_id.get(source_id, null)
		var source_artifact: Dictionary = _tree_artifact_holder_view(source_holder) \
			if source_holder is Dictionary else {}
		if source_artifact.is_empty() or not source_artifact.is_read_only():
			job["status"] = "failed"
			job["reason"] = "tree_source_record_projection_artifact_missing"
			ecology_tree_band_compile_jobs[key] = job
			return
		artifacts.append(source_artifact)
	var current := _tree_band_compile_sources_current(job)
	if String(current.get("status", "")) != "ready":
		job["status"] = "failed"
		job["reason"] = String(current.get("reason", "tree_source_band_compile_became_stale"))
		ecology_tree_band_compile_jobs[key] = job
		return
	var projector := TreeRecipeSectionCompilerScript.new()
	var started := Time.get_ticks_usec()
	var authority: Dictionary = job.get("authority", {})
	var family: Dictionary = job.get("publicationView", {}).get(
		"familyResultsById", {}).get("trees", {})
	var projected: Dictionary = projector.project_source_record_artifacts_to_band(
		String(job.get("worldId", "")), Vector2i(job.get("sourceChunkKey", Vector2i.ZERO)),
		Vector3i(job.get("sectionKey", Vector3i.ZERO)),
		String(job.get("snapshot", {}).get("sourceRevision", "")),
		String(family.get("familyRevision", "")),
		String(family.get("sourceManifestDigest", "")), authority, expected_ids, artifacts)
	job["projectionUsec"] = maxi(0, Time.get_ticks_usec() - started)
	job["projectionCount"] = int(job.get("projectionCount", 0)) + 1
	job["projectedSourceCount"] = artifacts.size()
	if String(projected.get("status", "")) != "ready":
		job["status"] = "failed" if String(projected.get("status", "")) == "failed" else "queued"
		job["reason"] = String(projected.get("reason", "tree_source_record_projection_failed"))
		ecology_tree_band_compile_jobs[key] = job
		return
	var band_artifact: Dictionary = projected.get("artifact", {})
	if band_artifact.is_empty() or not band_artifact.is_read_only():
		job["status"] = "failed"
		job["reason"] = "tree_source_record_projection_unsealed"
	else:
		var band_holder := _tree_artifact_holder(band_artifact)
		if band_holder.is_empty():
			job["status"] = "failed"
			job["reason"] = "tree_source_band_artifact_holder_invalid"
		else:
			job["artifact"] = {}
			job["artifactHolder"] = band_holder
			job["status"] = "complete"
			job["reason"] = "tree_source_record_projection_ready"
			ecology_tree_source_band_projection_count += 1
			ecology_tree_source_band_projection_usec += int(job.get("projectionUsec", 0))
		ecology_tree_band_compile_jobs[key] = job


func _admit_missing_tree_record_band_source_jobs(job: Dictionary,
		source_id: String) -> Dictionary:
	var source_record: Dictionary = job.get("recordsById", {}).get(source_id, {})
	var main_ref: WeakRef = job.get("main") as WeakRef
	var main: Object = main_ref.get_ref() if main_ref != null else null
	if not is_instance_valid(main) or source_record.is_empty():
		return {"status":"pending", "reason":"tree_source_band_record_admission_unavailable",
			"retryable":true}
	var token_maps: Dictionary = job.get("recordConsumerTokensByConsumer", {})
	var record_keys: Dictionary = job.get("recordJobKeys", {})
	var external_consumers: Dictionary = job.get("consumers", {})
	for external_token_value: Variant in external_consumers:
		var external_token := String(external_token_value)
		var token_map: Dictionary = token_maps.get(external_token, {})
		var source_token := String(token_map.get(source_id, ""))
		if source_token.is_empty():
			source_token = "tree-band-source:%s:%s" % [
				_source_recipe_digest([String(job.get("key", "")),
					external_token, source_id]), source_id]
		var admitted := request_ecology_tree_source_record_compile(main,
			job.get("snapshot", {}), source_record,
			job.get("publicationView", {}), source_token,
			float(job.get("priorityDistanceSquared", INF)))
		if String(admitted.get("status", "")) == "failed":
			return {"status":"failed", "reason":String(admitted.get("reason",
				"tree_source_record_compile_failed")), "sourceId":source_id}
		var source_job_key := String(admitted.get("jobKey", ""))
		if source_job_key.is_empty():
			job["recordJobKeys"] = record_keys
			job["recordConsumerTokensByConsumer"] = token_maps
			return {"status":"pending", "reason":String(admitted.get("reason",
				"tree_source_record_compile_backpressure")), "sourceId":source_id,
				"retryable":true}
		record_keys[source_id] = source_job_key
		token_map[source_id] = source_token
		token_maps[external_token] = token_map
	job["recordJobKeys"] = record_keys
	job["recordConsumerTokensByConsumer"] = token_maps
	return {"status":"ready", "jobKey":String(record_keys.get(source_id, "")),
		"sourceId":source_id}


func _tree_band_compile_sources_current(job: Dictionary) -> Dictionary:
	var main_ref: WeakRef = job.get("main") as WeakRef
	var main: Object = main_ref.get_ref() if main_ref != null else null
	var view: Dictionary = job.get("publicationView", {})
	var authority: Dictionary = job.get("authority", {})
	var lease_token := String(authority.get("publicationLeaseToken", ""))
	if not is_instance_valid(main) or lease_token.is_empty() \
			or not main.has_method("ecology_source_publication_local_is_current"):
		return {"status":"pending", "reason":"tree_source_band_currentness_unavailable"}
	var current: Variant = main.call("ecology_source_publication_local_is_current",
		view, lease_token)
	if not current is Dictionary or String(current.get("status", "")) != "ready":
		return current if current is Dictionary else {"status":"pending",
			"reason":"tree_source_band_currentness_unavailable"}
	for row_value: Variant in job.get("records", []):
		if not row_value is Dictionary or not main.has_method(
				"ecology_source_publication_record_is_current"):
			return {"status":"pending", "reason":"tree_source_band_record_validator_unavailable"}
		var row_current: Variant = main.call("ecology_source_publication_record_is_current",
			view, lease_token, row_value)
		if not row_current is Dictionary or String(row_current.get("status", "")) != "ready":
			return row_current if row_current is Dictionary else {"status":"pending",
				"reason":"tree_source_band_record_currentness_unavailable"}
	return {"status":"ready"}


func _ecology_source_compile_key(world_id: String, chunk: Vector2i,
		source_revision: String, producer_revision: String, source_digest: String) -> String:
	return "%s|%d,%d|%s|%s|%s" % [world_id, chunk.x, chunk.y,
		source_revision, producer_revision, source_digest]


## Admit a pure recipe build for a sealed deterministic source row. The input
## contains no gameplay Node and is kept independent from legacy body visuals.
func request_ecology_source_recipe(main: Object, record: Dictionary,
		provenance: Dictionary, request: Dictionary, consumer_token := "",
		publication_view: Dictionary = {}) -> Dictionary:
	var retained := _retain_source_publication(main, provenance, publication_view, "tree_recipe")
	if retained.get("status") != "ready": return retained
	var token := String(retained.get("leaseToken", ""))
	var result := _request_ecology_source_recipe_owned(main, record, provenance, request,
		consumer_token, retained.get("view", {}), token)
	var job: Dictionary = source_recipe_jobs.get(String(result.get("jobKey", "")), {})
	if String(job.get("publicationLeaseToken", "")) != token:
		main.call("release_ecology_source_publication", token)
	return result


func _request_ecology_source_recipe_owned(main: Object, record: Dictionary,
		provenance: Dictionary, request: Dictionary, consumer_token: String,
		publication_view: Dictionary, publication_token: String) -> Dictionary:
	if not record.is_read_only() or not provenance.is_read_only() \
			or not is_instance_valid(main) \
			or request.is_empty() \
			or not _source_recipe_values_are_node_free(request):
		return {"status":"failed", "reason":"ecology_tree_recipe_input_unsealed_or_non_value"}
	# Source aliases belong to the admitted publication; only the derived worker
	# request needs its own frozen value snapshot here.
	var frozen_record: Dictionary = record
	var frozen_provenance: Dictionary = provenance
	var frozen_request: Dictionary = _freeze_section_value(request.duplicate(true))
	if not _source_recipe_value_tree_is_read_only(frozen_request):
		return {"status":"failed", "reason":"ecology_tree_recipe_request_snapshot_not_frozen"}
	var source_id := String(record.get("sourceId", ""))
	var source_revision := String(record.get("sourceRevision", ""))
	var producer_revision := String(record.get("producerRevision", ""))
	if source_id.is_empty() or source_revision.is_empty() or producer_revision.is_empty():
		return {"status":"failed", "reason":"ecology_tree_recipe_identity_missing"}
	var request_digest := _source_recipe_digest(frozen_request)
	if request_digest.is_empty():
		return {"status":"failed", "reason":"ecology_tree_recipe_request_digest_failed"}
	var provenance_digest := String(publication_view.get("contentDigest", ""))
	var source_current: Variant = main.call("ecology_source_publication_local_is_current", publication_view, publication_token)
	if source_current is Dictionary and source_current.get("status") == "ready":
		source_current = main.call("ecology_source_publication_record_is_current", publication_view,
			publication_token, frozen_record)
	if not source_current is Dictionary:
		return {"status":"pending", "reason":"ecology_tree_recipe_currentness_unavailable",
			"retryable":true}
	if source_current.get("status", "") != "ready":
		return source_current
	var source_record_digest := String(source_current.get("memberDigest", ""))
	if source_record_digest.is_empty() or provenance_digest.is_empty():
		return {"status":"failed", "reason":"ecology_tree_recipe_source_digest_failed"}
	var key := _source_recipe_job_key(source_id, source_revision,
		producer_revision, request_digest, source_record_digest, provenance_digest) \
		+ "|owner:" + str(main.get_instance_id()) + "|publication:" + String(publication_view.get("publicationId", ""))
	var completed_value: Variant = source_recipe_completed.get(key, null)
	if completed_value is Dictionary:
		var cached_job: Dictionary = source_recipe_jobs.get(key, {})
		var cache_current := _validate_ecology_source_recipe_current(cached_job)
		if cache_current.get("status") != "ready": return cache_current
		var cache_consumers: Dictionary = cached_job.get("consumers", {})
		if not consumer_token.is_empty(): cache_consumers[consumer_token] = true
		cached_job["consumers"] = cache_consumers
		return {"status":"ready", "artifact":completed_value, "jobKey":key}
	if source_recipe_jobs.has(key):
		var current: Dictionary = source_recipe_jobs[key]
		# A canceled worker still owns this deterministic key until it has been
		# collected and retired. Do not attach new demand to it: its completion
		# path will erase the canceled task. Leave the producer request retryable
		# without a job key so the caller can admit a fresh incarnation afterward.
		if bool(current.get("cancelled", false)) \
				or String(current.get("status", "")) == "cancelled":
			return {"status":"pending",
				"reason":"ecology_tree_recipe_cancellation_draining",
				"retryable":true, "stage":"cancellation_drain"}
		if current.get("status", "") == "failed":
			return {"status":"failed", "reason":String(current.get("reason",
				"ecology_tree_recipe_job_failed")), "jobKey":key}
		var consumers: Dictionary = current.get("consumers", {})
		if not consumer_token.is_empty(): consumers[consumer_token] = true
		current["consumers"] = consumers
		source_recipe_jobs[key] = current
		if current.get("status", "") == "awaiting_validation":
			var validated := _validate_ecology_source_recipe_current(current)
			if validated.get("status") == "ready":
				var artifact := _seal_ecology_source_recipe_artifact(current,
					current.get("workerResult", {}))
				if not artifact.is_empty():
					source_recipe_completed[key] = artifact
					current["status"] = "complete"
					current["stage"] = "recipe_ready"
					current.erase("workerResult")
					source_recipe_jobs[key] = current
					return {"status":"ready", "artifact":artifact, "jobKey":key}
		return {"status":"pending", "reason":String(current.get("reason",
			"ecology_tree_recipe_worker_pending")), "retryable":true,
			"jobKey":key, "stage":String(current.get("stage", "queued"))}
	if source_recipe_jobs.size() >= MAX_SOURCE_RECIPE_PENDING:
		return {"status":"pending", "reason":"ecology_tree_recipe_backpressure",
			"retryable":true, "stage":"queue_capacity"}
	var new_consumers: Dictionary = {}
	if not consumer_token.is_empty(): new_consumers[consumer_token] = true
	var task := {"key":key, "mainRef":weakref(main), "sourceId":source_id,
		"main":weakref(main), "publicationView":publication_view, "publicationLeaseToken":publication_token,
		"sourceRevision":source_revision, "producerRevision":producer_revision,
		"requestDigest":request_digest, "sourceRecordDigest":source_record_digest,
		"provenanceDigest":provenance_digest,
		"record":frozen_record, "provenance":frozen_provenance,
		"request":frozen_request,
		"status":"queued", "stage":"queued", "cancelled":false,
		"consumers":new_consumers}
	source_recipe_jobs[key] = task
	source_recipe_pending_order.append(key)
	return {"status":"pending", "reason":"ecology_tree_recipe_queued",
		"retryable":true, "jobKey":key, "stage":"queued"}


func poll_ecology_source_recipe(job_key: String, record: Dictionary,
		provenance: Dictionary, consumer_token := "") -> Dictionary:
	if job_key.is_empty():
		return {"status":"pending", "reason":"ecology_tree_recipe_job_missing",
			"retryable":true, "jobKey":job_key}
	if not source_recipe_jobs.has(job_key):
		return {"status":"pending", "reason":"ecology_tree_recipe_job_missing",
			"retryable":true, "jobKey":job_key}
	var job: Dictionary = source_recipe_jobs[job_key]
	if job.get("status", "") == "failed":
		return {"status":"failed", "reason":String(job.get("reason",
			"ecology_tree_recipe_job_failed")), "jobKey":job_key}
	if String(job.get("sourceId", "")) != String(record.get("sourceId", "")) \
			or String(job.get("sourceRevision", "")) != String(record.get("sourceRevision", "")) \
			or String(job.get("producerRevision", "")) \
			!= String(record.get("producerRevision", "")) \
			or not is_same(job.get("record", {}), record) \
			or not is_same(job.get("provenance", {}), provenance):
		return {"status":"failed", "reason":"ecology_tree_recipe_poll_identity_mismatch"}
	var current := _validate_ecology_source_recipe_current(job)
	if current.get("status") == "failed":
		cancel_ecology_source_recipe(job_key, consumer_token)
		return current
	if current.get("status") == "pending":
		return current
	if not consumer_token.is_empty():
		var consumers: Dictionary = job.get("consumers", {})
		consumers[consumer_token] = true
		job["consumers"] = consumers
		source_recipe_jobs[job_key] = job
	var cached: Variant = source_recipe_completed.get(job_key, null)
	if cached is Dictionary:
		return {"status":"ready", "artifact":cached, "jobKey":job_key}
	if job.get("status", "") == "awaiting_validation":
		var artifact := _seal_ecology_source_recipe_artifact(job, job.get("workerResult", {}))
		if not artifact.is_empty():
			source_recipe_completed[job_key] = artifact
			job["status"] = "complete"
			job["stage"] = "recipe_ready"
			job.erase("workerResult")
			source_recipe_jobs[job_key] = job
			return {"status":"ready", "artifact":artifact, "jobKey":job_key}
	return {"status":"pending", "reason":String(job.get("reason",
		"ecology_tree_recipe_worker_pending")), "retryable":true,
		"jobKey":job_key, "stage":String(job.get("stage", "queued"))}


func cancel_ecology_source_recipe(job_key: String, consumer_token := "") -> void:
	if source_recipe_jobs.has(job_key):
		var job: Dictionary = source_recipe_jobs[job_key]
		var consumers: Dictionary = job.get("consumers", {})
		if not consumer_token.is_empty(): consumers.erase(consumer_token)
		job["consumers"] = consumers
		if not consumers.is_empty():
			source_recipe_jobs[job_key] = job
			return
		if job.get("status", "") == "complete":
			_retire_source_recipe_job(job_key)
			return
		job["cancelled"] = true
		job["status"] = "cancelled"
		source_recipe_jobs[job_key] = job
		source_recipe_pending_order.erase(job_key)
		var worker_active := false
		for worker_value: Variant in source_recipe_workers:
			if worker_value is Dictionary and String(worker_value.get("key", "")) == job_key:
				worker_active = true
				break
		if not worker_active:
			_retire_source_recipe_job(job_key)


func consume_ecology_source_recipe(job_key: String, consumer_token := "") -> void:
	if not source_recipe_completed.has(job_key):
		return
	if source_recipe_jobs.has(job_key):
		var job: Dictionary = source_recipe_jobs[job_key]
		var consumers: Dictionary = job.get("consumers", {})
		if not consumer_token.is_empty(): consumers.erase(consumer_token)
		job["consumers"] = consumers
		if consumers.is_empty(): _retire_source_recipe_job(job_key)
		else: source_recipe_jobs[job_key] = job


func _retire_source_recipe_job(job_key: String) -> void:
	var job: Dictionary = source_recipe_jobs.get(job_key, {})
	_release_ecology_compile_catalog_lease(job)
	source_recipe_jobs.erase(job_key)
	source_recipe_completed.erase(job_key)
	source_recipe_completed_order.erase(job_key)
	source_recipe_pending_order.erase(job_key)


## Drain ecology-only compilation/admission state before a world epoch changes.
## Gameplay tree publication jobs are independent and remain owned by their
## existing chunk lifecycle.
func reset_ecology_source_compilers() -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_source_compiler_reset_requires_main_thread"}
	var compiler_progress: Dictionary = tree_recipe_section_compiler.progress_snapshot()
	if String(compiler_progress.get("status", "")) != "idle":
		legacy_tree_compiler_retirement_pending = true
	if legacy_tree_compiler_retirement_pending \
			and not _advance_legacy_tree_compiler_retirement():
		return {"status":"pending", "reason":"tree_section_compiler_retirement_pending",
			"retryable":true}
	var cancelled_compile_count := 0
	for key_value: Variant in ecology_source_compile_jobs.keys():
		var key := String(key_value)
		var job: Dictionary = ecology_source_compile_jobs.get(key, {})
		var consumers: Dictionary = job.get("consumers", {})
		for consumer_value: Variant in consumers.keys():
			cancel_ecology_tree_source_compile(key, String(consumer_value))
		if ecology_source_compile_jobs.has(key):
			cancel_ecology_tree_source_compile(key)
		if ecology_source_compile_jobs.has(key):
			if not _can_enqueue_tree_value_retirement():
				if not _drain_tree_value_retirements():
					return {"status":"pending", "reason":"tree_value_retirement_pending",
						"retryable":true}
			if _retire_tree_source_cache_job(key, ecology_source_compile_jobs[key]):
				cancelled_compile_count += 1
	var cancelled_band_compile_count := 0
	for key_value: Variant in ecology_tree_band_compile_jobs.keys():
		var key := String(key_value)
		var job: Dictionary = ecology_tree_band_compile_jobs.get(key, {})
		var consumers: Dictionary = job.get("consumers", {})
		for consumer_value: Variant in consumers.keys():
			cancel_ecology_tree_source_band_compile(key, String(consumer_value))
		if ecology_tree_band_compile_jobs.has(key):
			var band_job: Dictionary = ecology_tree_band_compile_jobs[key]
			if not _can_enqueue_tree_value_retirement():
				if not _drain_tree_value_retirements():
					return {"status":"pending", "reason":"tree_value_retirement_pending",
						"retryable":true}
			if _retire_tree_band_cache_job(key, band_job):
				cancelled_band_compile_count += 1
			else:
				band_job["retirementPending"] = true
				ecology_tree_band_compile_jobs[key] = band_job
	ecology_tree_band_compile_cursor = 0
	var cancelled_recipe_count := 0
	for key_value: Variant in source_recipe_jobs.keys():
		var key := String(key_value)
		var job: Dictionary = source_recipe_jobs.get(key, {})
		var consumers: Dictionary = job.get("consumers", {})
		for consumer_value: Variant in consumers.keys():
			cancel_ecology_source_recipe(key, String(consumer_value))
		if source_recipe_jobs.has(key):
			cancel_ecology_source_recipe(key)
		cancelled_recipe_count += 1
	source_recipe_completed.clear()
	source_recipe_completed_order.clear()
	if not _drain_tree_value_retirements():
		return {"status":"pending", "reason":"tree_value_retirement_pending",
			"retryable":true, "cancelledCompileCount":cancelled_compile_count,
			"cancelledBandCompileCount":cancelled_band_compile_count}
	return {"status":"ready", "cancelledCompileCount":cancelled_compile_count,
		"cancelledBandCompileCount":cancelled_band_compile_count,
		"cancelledRecipeCount":cancelled_recipe_count,
		"inFlightRecipeWorkerCount":source_recipe_workers.size()}


func start_pending_source_recipe_workers() -> void:
	var index := 0
	while source_recipe_workers.size() + active.size() < MAX_ACTIVE_WORKERS \
			and index < source_recipe_pending_order.size():
		var key := source_recipe_pending_order[index]
		index += 1
		if not source_recipe_jobs.has(key):
			continue
		var task: Dictionary = source_recipe_jobs[key]
		if bool(task.get("cancelled", false)) or task.get("status", "") != "queued":
			continue
		var validator := _validate_ecology_source_recipe_current(task)
		if validator.get("status") != "ready":
			task["status"] = "queued" if validator.get("status") == "pending" else "failed"
			if task["status"] == "failed": _release_ecology_compile_catalog_lease(task)
			task["stage"] = String(validator.get("stage", "source_validation"))
			task["reason"] = String(validator.get("reason", "ecology_tree_recipe_source_stale"))
			source_recipe_jobs[key] = task
			continue
		var worker_service = TreeSpawnServiceScript.new()
		var thread := Thread.new()
		var start_error := thread.start(Callable(worker_service,
			"build_recipe_for_worker").bind(task.request))
		if start_error != OK:
			task["status"] = "queued"
			task["stage"] = "worker_admission"
			task["reason"] = "ecology_tree_recipe_worker_start_failed"
			source_recipe_jobs[key] = task
			continue
		task["status"] = "active"
		task["stage"] = "recipe_worker"
		task["workerService"] = worker_service
		task["thread"] = thread
		source_recipe_jobs[key] = task
		source_recipe_workers.append(task)
	source_recipe_pending_order.clear()
	for key_value: Variant in source_recipe_jobs:
		var task: Dictionary = source_recipe_jobs[key_value]
		if task.get("status", "") == "queued":
			source_recipe_pending_order.append(String(key_value))
		source_recipe_pending_order.sort()


func collect_completed_source_recipe_workers() -> void:
	var still_active: Array[Dictionary] = []
	for task_value: Variant in source_recipe_workers:
		if not task_value is Dictionary:
			continue
		var task: Dictionary = task_value
		var thread := task.get("thread") as Thread
		if thread == null:
			_retire_source_recipe_job(String(task.get("key", "")))
			continue
		if thread.is_alive():
			still_active.append(task)
			continue
		var recipe_value: Variant = thread.wait_to_finish()
		var key := String(task.get("key", ""))
		var validator := _validate_ecology_source_recipe_current(task)
		if bool(task.get("cancelled", false)) or validator.get("status") == "failed":
			_retire_source_recipe_job(key)
			continue
		if validator.get("status") == "pending":
			task["status"] = "awaiting_validation"
			task["stage"] = "source_validation"
			task["reason"] = String(validator.get("reason", "ecology_tree_recipe_source_pending"))
			task["workerResult"] = recipe_value if recipe_value is Dictionary else {}
			task.erase("thread")
			task.erase("workerService")
			source_recipe_jobs[key] = task
			continue
		if not recipe_value is Dictionary or recipe_value.is_empty():
			_release_ecology_compile_catalog_lease(task)
			task["status"] = "failed"
			task["stage"] = "recipe_worker"
			task["reason"] = "ecology_tree_recipe_worker_returned_empty"
			task.erase("thread")
			task.erase("workerService")
			source_recipe_jobs[key] = task
			continue
		var artifact := _seal_ecology_source_recipe_artifact(task, recipe_value)
		if artifact.is_empty():
			_release_ecology_compile_catalog_lease(task)
			task["status"] = "failed"
			task["stage"] = "recipe_worker"
			task["reason"] = "ecology_tree_recipe_artifact_seal_failed"
			task.erase("thread")
			task.erase("workerService")
			source_recipe_jobs[key] = task
			continue
		source_recipe_completed[key] = artifact
		source_recipe_completed_order.append(key)
		while source_recipe_completed_order.size() > MAX_SOURCE_RECIPE_PENDING:
			var retired_key: String = source_recipe_completed_order.pop_front()
			source_recipe_completed.erase(retired_key)
		task["status"] = "complete"
		task["stage"] = "recipe_ready"
		task.erase("thread")
		task.erase("workerService")
		source_recipe_jobs[key] = task
	source_recipe_workers = still_active


func _seal_ecology_source_recipe_artifact(task: Dictionary, recipe_value: Variant) -> Dictionary:
	if not recipe_value is Dictionary or recipe_value.is_empty() \
			or not _source_recipe_values_are_node_free(recipe_value):
		return {}
	var recipe: Dictionary = _freeze_section_value(recipe_value)
	var artifact := {"schema":SOURCE_RECIPE_SCHEMA,
		"jobKey":String(task.get("key", "")),
		"sourceId":String(task.get("sourceId", "")),
		"sourceRevision":String(task.get("sourceRevision", "")),
		"sourceDomainRevision":String(task.get("sourceRevision", "")),
		"producerRevision":String(task.get("producerRevision", "")),
		"requestDigest":String(task.get("requestDigest", "")),
		"sourceRecordDigest":String(task.get("sourceRecordDigest", "")),
		"provenanceDigest":String(task.get("provenanceDigest", "")),
		"request":task.get("request", {}), "recipe":recipe,
		"recipeSignature":String(recipe.get("signature", "")),
		"provenance":task.get("provenance", {})}
	artifact.make_read_only()
	return artifact


func _validate_ecology_source_recipe_current(task: Dictionary) -> Dictionary:
	var main_ref := task.get("mainRef") as WeakRef
	var main: Object = main_ref.get_ref() if main_ref != null else null
	if not is_instance_valid(main) or not main.has_method("ecology_source_publication_local_is_current"):
		return {"status":"pending", "reason":"ecology_source_currentness_validator_unavailable",
			"retryable":true}
	var record: Variant = task.get("record", {})
	var provenance: Variant = task.get("provenance", {})
	var request: Variant = task.get("request", {})
	if not record is Dictionary or not provenance is Dictionary or not request is Dictionary \
			or not is_same(provenance, task.get("publicationView", {}).get("payload", {})) \
			or not _source_recipe_value_tree_is_read_only(request) \
			or _source_recipe_digest(request) != String(task.get("requestDigest", "")):
		return {"status":"failed", "reason":"ecology_tree_recipe_frozen_identity_changed"}
	var result: Variant = main.call("ecology_source_publication_local_is_current",
		task.get("publicationView", {}), String(task.get("publicationLeaseToken", "")))
	if result is Dictionary and result.get("status") == "ready":
		result = main.call("ecology_source_publication_record_is_current", task.get("publicationView", {}),
			String(task.get("publicationLeaseToken", "")), record)
	if not result is Dictionary:
		return {"status":"pending", "reason":"ecology_source_currentness_result_invalid",
			"retryable":true}
	return result


func _source_recipe_values_are_node_free(value: Variant) -> bool:
	if value is Object or value is RID or value is Callable or value is Signal:
		return false
	if value is Dictionary:
		for key: Variant in value:
			if not _source_recipe_values_are_node_free(key) \
					or not _source_recipe_values_are_node_free(value[key]): return false
	elif value is Array:
		for child: Variant in value:
			if not _source_recipe_values_are_node_free(child): return false
	return true


func _source_recipe_value_tree_is_read_only(value: Variant) -> bool:
	if value is Dictionary:
		if not value.is_read_only(): return false
		for key: Variant in value:
			if not _source_recipe_value_tree_is_read_only(key) \
					or not _source_recipe_value_tree_is_read_only(value[key]): return false
	elif value is Array:
		if not value.is_read_only(): return false
		for child: Variant in value:
			if not _source_recipe_value_tree_is_read_only(child): return false
	return true


func _source_recipe_digest(value: Variant) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(value)) != OK:
		return ""
	return context.finish().hex_encode()


func _source_recipe_job_key(source_id: String, source_revision: String,
		producer_revision: String, request_digest: String,
		source_record_digest := "", provenance_digest := "") -> String:
	return "%s|%s|%s|%s|%s|%s" % [source_id, source_revision,
		producer_revision, request_digest, source_record_digest, provenance_digest]




## Advances the recipe-fed section compiler independently from legacy visual
## construction. A tree remains retryable until a current immutable section
## value record has completed; this method never retires its existing visual.
func advance_tree_section_compiler(work_units := TREE_SECTION_COMPILER_WORK_UNITS_PER_FRAME) -> Dictionary:
	if not section_owned_publication_enabled:
		return {"status":"idle", "reason":"section_owned_tree_publication_disabled"}
	if legacy_tree_compiler_retirement_pending:
		return {"status":"pending", "reason":"tree_section_compiler_retirement_pending",
			"retryable":true}
	if active_tree_section_compile_record.is_empty() \
			and tree_recipe_section_compiler.progress_snapshot().get("status", "") != "idle":
		legacy_tree_compiler_retirement_pending = true
		if not _advance_legacy_tree_compiler_retirement():
			return {"status":"pending", "reason":"tree_section_compiler_retirement_backpressure",
				"retryable":true}
	var main: Object = get_parent() as Object
	if not is_instance_valid(main):
		return {"status":"pending", "reason":"tree_section_main_owner_unavailable"}
	if active_tree_section_compile_record.is_empty():
		var retirement_admission: Dictionary = _ensure_tree_value_retirement_worker()
		if String(retirement_admission.get("status", "")) != "ready" \
				or not tree_value_retirement_owner.can_accept():
			return {"status":"pending", "reason":"tree_value_retirement_worker_unavailable",
				"retryable":true}
		var candidate: Dictionary = _next_tree_section_recipe_input()
		if candidate.is_empty():
			return {"status":"idle", "reason":"tree_section_recipe_input_unavailable"}
		var body_ref := candidate.get("body") as WeakRef
		var body := body_ref.get_ref() as StaticBody3D if body_ref != null else null
		if not is_instance_valid(body):
			return {"status":"pending", "reason":"tree_section_recipe_owner_unavailable"}
		var removed := ActiveRemovedPropsSnapshotScript.capture_for_ids(main,
			[String(candidate.get("propId", ""))])
		if not bool(removed.get("ok", false)):
			return {"status":"pending", "reason":"tree_section_removed_props_pending"}
		var world_id := "seed:%s:%d" % [String(main.get("seed_text")), int(main.get("seed_hash"))]
		var native_dispatcher := _tree_geometry_dispatcher()
		if native_dispatcher == null:
			return {"status":"pending", "reason":"native_tree_geometry_dispatcher_unavailable",
				"retryable":true}
		tree_recipe_section_compiler.set_native_tree_geometry_dispatcher(native_dispatcher)
		var begun: Dictionary = tree_recipe_section_compiler.begin(main, world_id,
			[candidate], removed)
		if String(begun.get("reason", "")) != "tree_section_compile_started":
			return begun
		active_tree_section_compile_record = candidate
		tree_section_compile_started_count += 1
	var output: Dictionary = tree_recipe_section_compiler.advance(work_units)
	last_tree_section_compile_advance = {"status":String(output.get("status", "")),
		"reason":String(output.get("reason", ""))}
	for field: String in ["workUnits", "recordIndex", "roleIndex"]:
		if output.has(field):
			last_tree_section_compile_advance[field] = output[field]
	if output.get("status") == "ready":
		var sealed := {"schema":CompiledTreeSectionArtifact.SCHEMA,
			"record":active_tree_section_compile_record,
			"body":active_tree_section_compile_record.get("body"),
			"bodyInstanceId":int(active_tree_section_compile_record.get("bodyInstanceId", 0)),
			"propId":String(active_tree_section_compile_record.get("propId", "")),
			"sourceId":String(active_tree_section_compile_record.get("sourceId", "")),
			"contentRevision":String(active_tree_section_compile_record.get("contentRevision", "")),
			"recipeSignature":String(active_tree_section_compile_record.get("recipeSignature", "")),
			"artifactGeneration":int(active_tree_section_compile_record.get("artifactGeneration", 0)),
			"compiled":output}
		sealed.make_read_only()
		compiled_tree_section_records.append(sealed)
		_index_source_record("compiled", sealed)
		_startup_tree_diagnostic_index("section_compiled", sealed)
		var compiled_owner_reference: Variant = sealed.get("body")
		var compiled_owner: Variant = compiled_owner_reference.get_ref() if compiled_owner_reference is WeakRef else null
		if is_instance_valid(compiled_owner) and compiled_owner is StaticBody3D:
			tree_section_values_prepared.emit(compiled_owner)
		tree_section_compile_completed_count += 1
		active_tree_section_compile_record = {}
		legacy_tree_compiler_retirement_pending = true
		while compiled_tree_section_records.size() > section_recipe_input_records.size():
			var evicted: Dictionary = compiled_tree_section_records.pop_front()
			_unindex_source_record("compiled", evicted)
			_startup_tree_diagnostic_unindex("section_compiled", evicted)
			pending_compiled_section_retirement_records.append(evicted)
	elif String(output.get("reason", "")) != "tree_section_compile_in_progress":
		tree_section_compile_stale_count += 1
		legacy_tree_compiler_retirement_pending = true
	return output


func _tree_geometry_dispatcher() -> RefCounted:
	if is_instance_valid(native_tree_geometry_dispatcher):
		return native_tree_geometry_dispatcher
	if not ClassDB.class_exists("NativeTreeGeometryDispatcher"):
		return null
	native_tree_geometry_dispatcher = ClassDB.instantiate(
		"NativeTreeGeometryDispatcher") as RefCounted
	return native_tree_geometry_dispatcher


## Read-only, constant-size snapshot for the Main startup diagnostics. The
## compiler supplies live work position; this queue contributes its actual
## last advance result and existing lifecycle totals.
func startup_tree_section_compile_diagnostics() -> Dictionary:
	var result := {"schema":"tree-section-compile-progress/v1",
		"startedCount":tree_section_compile_started_count,
		"completedCount":tree_section_compile_completed_count,
		"staleCount":tree_section_compile_stale_count,
		"lastAdvance":last_tree_section_compile_advance.duplicate(true)}
	var progress: Dictionary = {"status":"idle", "reason":"tree_section_compile_not_active"}
	if not active_tree_section_compile_record.is_empty():
		progress = tree_recipe_section_compiler.progress_snapshot()
	result["compiler"] = progress
	result["activeCandidateId"] = String(progress.get("activeCandidateId", ""))
	result["activeSourceId"] = String(progress.get("activeSourceId", ""))
	return result


## Join only the caller's bounded exact prop IDs. Returned values are scalar
## lifecycle evidence; weak owners, meshes and instance buffers stay private.
func startup_tree_candidate_diagnostics(prop_ids: Array[String]) -> Dictionary:
	var result := {}
	for prop_id: String in prop_ids:
		var stages: Dictionary = _startup_tree_diagnostic_records_by_id.get(prop_id, {})
		var rows := {}
		for stage: String in ["section_recipe_input", "section_compiled", "section_prepared"]:
			var indexed: Array = stages.get(stage, [])
			var summaries: Array[Dictionary] = []
			for row_value: Variant in indexed:
				if not row_value is Dictionary:
					continue
				var row: Dictionary = row_value
				var nested: Dictionary = row.get("record", {}) if row.get("record", {}) is Dictionary else {}
				var owner_ref := row.get("body", nested.get("body")) as WeakRef
				var owner: Object = owner_ref.get_ref() if owner_ref != null else null
				var body_owner := owner as StaticBody3D if owner is StaticBody3D else null
				var body_id := int(row.get("bodyInstanceId", nested.get("bodyInstanceId", 0)))
				var expected_generation := int(body_owner.get_meta(
					"tree_section_recipe_input_expected_generation", 0)) if body_owner != null else 0
				var producer_generation := int(row.get("producerGeneration", nested.get("producerGeneration", 0)))
				var row_transform: Variant = row.get("bodyGlobalTransform",
					nested.get("bodyGlobalTransform", null))
				var row_current := body_owner != null and body_owner.is_inside_tree() \
					and not body_owner.is_queued_for_deletion() \
					and not bool(body_owner.get_meta("tree_publication_cancelled", false)) \
					and body_id == body_owner.get_instance_id() \
					and (expected_generation <= 0 or producer_generation == expected_generation) \
					and String(body_owner.get_meta("prop_id", "")) == prop_id \
					and (row_transform == null or (row_transform is Transform3D \
						and (row_transform as Transform3D).is_equal_approx(body_owner.global_transform)))
				var summary := {"sourceId":String(row.get("sourceId", nested.get("sourceId", ""))),
					"bodyInstanceId":body_id, "ownerLive":is_instance_valid(owner),
					"ownerIdentityCurrent":row_current,
					"state":"current" if row_current else "stale_owner",
					"artifactGeneration":int(row.get("artifactGeneration", nested.get("artifactGeneration", 0))),
					"contentRevision":String(row.get("contentRevision", nested.get("contentRevision", ""))),
					"recipeSignature":String(row.get("recipeSignature", nested.get("recipeSignature", "")))}
				if stage == "section_compiled":
					var compiled: Dictionary = row.get("compiled", {})
					var source_rows: Array = compiled.get("sources", [])
					for source_value: Variant in source_rows:
						if source_value is Dictionary and String(source_value.get("sourceId", "")) == String(summary.sourceId):
							var section_keys: Array = source_value.get("sectionKeys", [])
							summary["sectionKeys"] = section_keys.duplicate()
							summary["sourceRevision"] = String(source_value.get("sourceRevision", ""))
							summary["recipeArtifactRevision"] = String(source_value.get("recipeArtifactRevision", ""))
							break
				elif stage == "section_prepared":
					var ack: Dictionary = prepared_section_acknowledgements.get(
						int(row.get("artifactGeneration", 0)), {})
					if not ack.is_empty():
						summary["installAckPendingRetirement"] = true
						summary["ackSectionCount"] = ack.get("requiredSections", []).size()
					for compiled_value: Variant in stages.get("section_compiled", []):
						if not compiled_value is Dictionary:
							continue
						var compiled_row: Dictionary = compiled_value
						if String(compiled_row.get("sourceId", "")) != String(summary.sourceId):
							continue
						for source_value: Variant in compiled_row.get("compiled", {}).get("sources", []):
							if source_value is Dictionary and String(source_value.get("sourceId", "")) == String(summary.sourceId):
								summary["sectionKeys"] = source_value.get("sectionKeys", []).duplicate()
								summary["sourceRevision"] = String(source_value.get("sourceRevision", ""))
								summary["recipeArtifactRevision"] = String(source_value.get("recipeArtifactRevision", ""))
								break
					if not summary.has("recipeArtifactRevision"):
						summary["recipeArtifactRevision"] = String(row.get("recipeArtifactRevision", ""))
				summaries.append(summary)
			rows[stage] = summaries
		var ack_value: Variant = _startup_tree_diagnostic_ack_by_id.get(prop_id, {})
		if ack_value is Dictionary and not (ack_value as Dictionary).is_empty():
			var ack_source: Dictionary = ack_value
			var ack_summary := {}
			for field: String in ["sourceId", "propId", "bodyInstanceId", "artifactGeneration",
					"producerGeneration", "sourceRevision", "recipeSignature", "recipeArtifactRevision",
					"sectionKeys", "receiptCount"]:
				if ack_source.has(field):
					ack_summary[field] = ack_source[field].duplicate() \
						if field == "sectionKeys" else ack_source[field]
			var ack_body_ref := ack_source.get("body") as WeakRef
			var body := ack_body_ref.get_ref() as StaticBody3D if ack_body_ref != null else null
			ack_summary["ownerIdentityCurrent"] = is_instance_valid(body) and body.is_inside_tree() \
				and not body.is_queued_for_deletion() \
				and not bool(body.get_meta("tree_publication_cancelled", false)) \
				and int(ack_summary.get("bodyInstanceId", 0)) == body.get_instance_id() \
				and String(body.get_meta("tree_visual_state", "")) == "section_owned" \
				and String(body.get_meta("visual_source", "")) == "chunk_owned_static_section" \
				and int(body.get_meta("tree_section_recipe_input_expected_generation", 0)) \
					== int(ack_source.get("producerGeneration", 0))
			rows["section_acknowledged"] = ack_summary
		result[prop_id] = rows
	# Empty stage arrays and an unresolved revisionJoin are query scaffolding, not
	# retained candidate state. Count only indexed artifacts or an accepted ack.
	var known_count := 0
	for value: Variant in result.values():
		if not value is Dictionary:
			continue
		var candidate_rows: Dictionary = value
		var has_candidate_artifact := false
		for stage: String in ["section_recipe_input", "section_compiled", "section_prepared"]:
			var stage_rows: Variant = candidate_rows.get(stage, [])
			if stage_rows is Array and not (stage_rows as Array).is_empty():
				has_candidate_artifact = true
				break
		var acknowledgement: Variant = candidate_rows.get("section_acknowledged", {})
		if acknowledgement is Dictionary and not (acknowledgement as Dictionary).is_empty():
			has_candidate_artifact = true
		if has_candidate_artifact:
			known_count += 1
	for prop_id: String in prop_ids:
		var stages: Dictionary = result.get(prop_id, {})
		var canonical_recipe := ""
		var canonical_signature := ""
		var revision_conflicts: Array[String] = []
		for stage: String in ["section_recipe_input", "section_compiled", "section_prepared"]:
			for summary_value: Variant in stages.get(stage, []):
				if not summary_value is Dictionary:
					continue
				var summary: Dictionary = summary_value
				if not bool(summary.get("ownerIdentityCurrent", false)):
					continue
				var recipe_revision := String(summary.get("recipeArtifactRevision",
					summary.get("contentRevision", "")))
				var signature := String(summary.get("recipeSignature", ""))
				if not recipe_revision.is_empty():
					if canonical_recipe.is_empty(): canonical_recipe = recipe_revision
					elif canonical_recipe != recipe_revision: revision_conflicts.append("recipe_artifact_revision")
				if not signature.is_empty():
					if canonical_signature.is_empty(): canonical_signature = signature
					elif canonical_signature != signature: revision_conflicts.append("recipe_signature")
		var acknowledged: Dictionary = stages.get("section_acknowledged", {})
		if not acknowledged.is_empty():
			if not canonical_signature.is_empty() \
					and String(acknowledged.get("recipeSignature", "")) != canonical_signature:
				revision_conflicts.append("ack_recipe_signature")
			if not canonical_recipe.is_empty() \
					and String(acknowledged.get("recipeArtifactRevision", "")) != canonical_recipe:
				revision_conflicts.append("ack_recipe_artifact_revision")
		stages["revisionJoin"] = {"status":"mismatch" if not revision_conflicts.is_empty() else \
			("matched" if not canonical_recipe.is_empty() else "unresolved"),
			"recipeArtifactRevision":canonical_recipe,
			"recipeSignature":canonical_signature,
			"conflicts":revision_conflicts}
		result[prop_id] = stages
	return {"byPropId":result, "queryCount":prop_ids.size(), "indexBacked":true,
		"knownCandidateCount":known_count}


func _startup_tree_diagnostic_index(stage: String, row: Dictionary) -> void:
	var prop_id := String(row.get("propId", row.get("record", {}).get("propId", "")))
	if prop_id.is_empty():
		return
	var stages: Dictionary = _startup_tree_diagnostic_records_by_id.get(prop_id, {})
	var indexed: Array = stages.get(stage, [])
	var identity := _startup_tree_diagnostic_identity(row)
	for existing: Variant in indexed:
		if existing is Dictionary and _startup_tree_diagnostic_identity(existing) == identity:
			return
	indexed.append(row)
	stages[stage] = indexed
	_startup_tree_diagnostic_records_by_id[prop_id] = stages


func _startup_tree_diagnostic_unindex(stage: String, row: Dictionary) -> void:
	var prop_id := String(row.get("propId", row.get("record", {}).get("propId", "")))
	var stages: Dictionary = _startup_tree_diagnostic_records_by_id.get(prop_id, {})
	var indexed: Array = stages.get(stage, [])
	var identity := _startup_tree_diagnostic_identity(row)
	for index in range(indexed.size() - 1, -1, -1):
		if indexed[index] is Dictionary and _startup_tree_diagnostic_identity(indexed[index]) == identity:
			indexed.remove_at(index)
	if indexed.is_empty():
		stages.erase(stage)
	else:
		stages[stage] = indexed
	if stages.is_empty():
		_startup_tree_diagnostic_records_by_id.erase(prop_id)
	else:
		_startup_tree_diagnostic_records_by_id[prop_id] = stages


func _startup_tree_diagnostic_identity(row: Dictionary) -> String:
	var nested: Dictionary = row.get("record", {}) if row.get("record", {}) is Dictionary else {}
	return "%s|%d|%d|%s" % [String(row.get("sourceId", nested.get("sourceId", ""))),
		int(row.get("bodyInstanceId", nested.get("bodyInstanceId", 0))),
		int(row.get("artifactGeneration", nested.get("artifactGeneration", 0))),
		String(row.get("contentRevision", nested.get("contentRevision", "")))]


func _next_tree_section_recipe_input() -> Dictionary:
	for value: Variant in section_recipe_input_records:
		if not value is Dictionary or not value.is_read_only():
			continue
		var record: Dictionary = value
		var body_ref := record.get("body") as WeakRef
		var body := body_ref.get_ref() as StaticBody3D if body_ref != null else null
		if not is_instance_valid(body) or not body.is_inside_tree() \
				or body.is_queued_for_deletion() \
				or int(record.get("bodyInstanceId", 0)) != body.get_instance_id():
			continue
		var compiled := _source_record_for_body("compiled", body)
		var already_compiled := not compiled.is_empty() and String(compiled.get("contentRevision", "")) \
			== String(record.get("contentRevision", "")) \
			and int(compiled.get("record", {}).get("producerGeneration", -1)) == int(record.get("producerGeneration", 0))
		if already_compiled:
			continue
		return record
	return {}


func compiled_tree_section_record_for_body(body: StaticBody3D) -> Dictionary:
	if not is_instance_valid(body) or not body.is_inside_tree() \
			or body.is_queued_for_deletion() \
			or bool(body.get_meta("tree_publication_cancelled", false)):
		return {}
	var compiled := _source_record_for_body("compiled", body)
	var input: Dictionary = compiled.get("record", {})
	if not input.is_read_only() or not input.get("bodyGlobalTransform") is Transform3D \
			or input.bodyGlobalTransform != body.global_transform \
			or String(input.get("propId", "")) != String(body.get_meta("prop_id", "")) \
			or int(input.get("producerGeneration", 0)) != int(body.get_meta("tree_section_recipe_input_expected_generation", -1)):
		return {}
	return compiled

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
		if not _task_generation_is_current(task, body):
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
			_set_tree_preparation_state(body, "failed")
			continue
		task["thread"] = thread
		task["workerService"] = worker_service
		_set_tree_preparation_state(body, "building")
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
		var completed_body: StaticBody3D = _publication_body(task)
		if completed_body == null or not _task_generation_is_current(task, completed_body):
			cancelled_count += 1
			continue
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
				_set_tree_preparation_state(body, "failed")
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
		if body == null or not is_instance_valid(body) \
				or not _task_generation_is_current(task, body):
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
	if not task.has("sectionOwnedCompile"):
		task["sectionOwnedCompile"] = section_owned_publication_enabled
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
	var compile_to_section := bool(task.get("sectionOwnedCompile", false))
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
			_set_tree_preparation_state(body, "failed")
			failed_count += 1
			return
		root.name = "GeneratedTreeVisual"
		root.position = Vector3.ZERO
		root.rotation = Vector3.ZERO
		root.scale = Vector3.ONE
		if compile_to_section and not bool(recipe.get("runtimeImpostor", false)):
			# Section-owned output finishes directly into sealed resources. This
			# detached root carries transform identity only; it creates no per-tree
			# render instances and is discarded after its section artifact is sealed.
			var section_wood_root := Node3D.new()
			section_wood_root.name = "ProceduralTreeWood"
			root.add_child(section_wood_root)
			task["visual"] = root
			task["woodRoot"] = section_wood_root
			task["renderStage"] = "bole"
			_set_tree_preparation_state(body, "assembling_section_values")
			publication_stage_counts["root"] = int(publication_stage_counts.get("root", 0)) + 1
			continue_publication_task(task)
			return
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
		_set_tree_preparation_state(body, "assembling")
		publication_stage_counts["root"] = int(publication_stage_counts.get("root", 0)) + 1
		continue_publication_task(task)
		return
	var visual: Node3D = task.get("visual", null) as Node3D
	if visual == null or not is_instance_valid(visual):
		_set_tree_preparation_state(body, "failed")
		failed_count += 1
		return
	var wood_root: Node3D = task.get("woodRoot", null) as Node3D
	if wood_root == null or not is_instance_valid(wood_root):
		_set_tree_preparation_state(body, "failed")
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
				_set_tree_preparation_state(body, "failed")
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
			_set_tree_preparation_state(body, "failed")
			failed_count += 1
			return
		if bool(task.get("boleBuildComplete", false)):
			if compile_to_section:
				var bole_values: Dictionary = visual_factory.finish_runtime_bole_values(
					recipe, bole_build_state, String(request.get("biome", "forest")))
				if not bole_values.is_empty():
					var bole_metadata: Dictionary = bole_values.get("metadata", {})
					_append_section_value_member_from_values(task, "bole",
						bole_values.get("mesh", null), null,
						bole_values.get("material", null), bole_values.get("renderPolicy", {}),
						int(bole_metadata.get("tree_wood_segment_count", -1)))
			else:
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
			_set_tree_preparation_state(body, "failed")
			failed_count += 1
			return
		if bool(task.get("distalBuildComplete", false)):
			if compile_to_section:
				var distal_values: Dictionary = distal_factory.finish_runtime_distal_build_values(
					distal_build_state, recipe, String(request.get("biome", "forest")))
				if not distal_values.is_empty():
					var distal_multimesh := distal_values.get("multiMesh", null) as MultiMesh
					_append_section_value_member_from_values(task, "branches",
						distal_multimesh.mesh if distal_multimesh != null else null,
						distal_multimesh, distal_values.get("material", null),
						distal_values.get("renderPolicy", {}), -1)
			else:
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
			_set_tree_preparation_state(body, "failed")
			failed_count += 1
			return
		if bool(task.get("foliageBuildComplete", false)):
			if compile_to_section:
				var foliage_values: Dictionary = foliage_factory.finish_runtime_foliage_build_values(
					foliage_build_state, recipe, String(request.get("biome", "forest")))
				if not foliage_values.is_empty() and not bool(foliage_values.get("headlessVisualProxy", false)):
					var foliage_multimesh := foliage_values.get("multiMesh", null) as MultiMesh
					_append_section_value_member_from_values(task, "foliage",
						foliage_multimesh.mesh if foliage_multimesh != null else null,
						foliage_multimesh, foliage_values.get("material", null),
						foliage_values.get("renderPolicy", {}), -1)
			else:
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
	if stage == "commit" and compile_to_section:
		var sealed := seal_prepared_section_value_record(task, body)
		if sealed.get("status") == "ready":
			var retained := retain_prepared_section_value_record(sealed.record)
			if retained.get("status") == "retained":
				_set_tree_preparation_state(body, "section_candidate_pending")
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
		# Section-owned mode has no per-tree geometry graph to fall back to. Reject
		# the incomplete artifact rather than promoting an empty root. The previous
		# visual remains attached; a first-time tree retains its collision proxy.
		var failure_reason := String(sealed.get("reason",
			"prepared_tree_section_values_incomplete"))
		body.set_meta("tree_section_value_failure_reason", failure_reason)
		_set_tree_preparation_state(body, "section_compile_failed")
		var rejected_visual: Node3D = task.get("visual", null) as Node3D
		if is_instance_valid(rejected_visual) and rejected_visual.get_parent() == null:
			rejected_visual.free()
		failed_count += 1
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
	var witness: Dictionary = {}
	if keep_chunk_batch:
		var publisher: Variant = body.get_meta("static_chunk_render_publisher", null)
		if is_instance_valid(publisher) and publisher.has_method("installed_snapshot"):
			witness = {"publisher":weakref(publisher), "publisherId":publisher.get_instance_id(),
				"snapshot":publisher.call("installed_snapshot", body)}
	remember_published_lod(body, request, task.get("sectionValueMembers", []), recipe, false,
		"native_impostor" if keep_chunk_batch else "legacy_mesh", witness)
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


func _append_section_value_member_from_values(task: Dictionary, role: String,
		mesh: Mesh, multi_mesh: MultiMesh, material: Material,
		render_policy: Dictionary, producer_element_count: int) -> void:
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var custom_values: Array[Color] = []
	if multi_mesh == null:
		transforms.append(Transform3D.IDENTITY)
		colors.append(Color.WHITE)
		custom_values.append(Color(0.0, 0.0, 0.0, 1.0))
	else:
		if not multi_mesh.use_custom_data \
				or multi_mesh.transform_format != MultiMesh.TRANSFORM_3D:
			task["sectionValueCapturePending"] = "tree_section_multimesh_layout_unsupported"
			return
		for index: int in range(multi_mesh.instance_count):
			transforms.append(multi_mesh.get_instance_transform(index))
			colors.append(multi_mesh.get_instance_color(index) if multi_mesh.use_colors else Color.WHITE)
			custom_values.append(multi_mesh.get_instance_custom_data(index))
	if not is_instance_valid(mesh) or material == null or transforms.is_empty():
		task["sectionValueCapturePending"] = "tree_section_member_resources_missing"
		return
	transforms.make_read_only()
	colors.make_read_only()
	custom_values.make_read_only()
	var member := {"schema":"tree-section-render-member/v1", "role":role,
		"mesh":mesh, "material":material, "localTransform":Transform3D.IDENTITY,
		"transforms":transforms, "colors":colors, "customData":custom_values,
		"producerElementCount":producer_element_count,
		"visibilityRangeEnd":float(render_policy.get("visibilityRangeEnd", 0.0)),
		"fadeMargin":float(render_policy.get("visibilityRangeEndMargin", 0.0)),
		"castShadows":int(render_policy.get("castShadow",
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)) \
			!= GeometryInstance3D.SHADOW_CASTING_SETTING_OFF}
	member.make_read_only()
	var members: Array = task.get("sectionValueMembers", [])
	members.append(member)
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


func _freeze_tree_band_artifact_in_place(value: Variant) -> void:
	if value is Dictionary:
		for key: Variant in value:
			_freeze_tree_band_artifact_in_place(value[key])
		(value as Dictionary).make_read_only()
	elif value is Array:
		for nested: Variant in value:
			_freeze_tree_band_artifact_in_place(nested)
		(value as Array).make_read_only()

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
	for task in source_recipe_workers:
		var thread := task.get("thread") as Thread
		if thread != null and thread.is_started():
			thread.wait_to_finish()
	_ensure_tree_value_retirement_worker()
	if is_instance_valid(tree_recipe_section_compiler) \
			and tree_recipe_section_compiler.progress_snapshot().get("status", "") != "idle":
		legacy_tree_compiler_retirement_pending = true
	while legacy_tree_compiler_retirement_pending:
		if not _can_enqueue_tree_value_retirement(): _drain_tree_value_retirements()
		if not _advance_legacy_tree_compiler_retirement():
			push_error("Could not detach legacy tree compiler for worker retirement")
			break
	while not pending_compiled_section_retirement_records.is_empty():
		_advance_compiled_section_retirements()
		if not pending_compiled_section_retirement_records.is_empty() \
				and not _drain_tree_value_retirements():
			push_error("Could not retire compiled tree section values before queue teardown")
			break
	for key_value: Variant in ecology_source_compile_jobs.keys():
		var key := String(key_value)
		while ecology_source_compile_jobs.has(key):
			if not _can_enqueue_tree_value_retirement():
				_drain_tree_value_retirements()
			if not _retire_tree_source_cache_job(key, ecology_source_compile_jobs[key]):
				push_error("Could not detach tree source job for worker retirement: " + key)
				break
	for key_value: Variant in ecology_tree_band_compile_jobs.keys():
		var key := String(key_value)
		while ecology_tree_band_compile_jobs.has(key):
			if not _can_enqueue_tree_value_retirement():
				_drain_tree_value_retirements()
			if not _retire_tree_band_cache_job(key, ecology_tree_band_compile_jobs[key]):
				push_error("Could not detach tree band job for worker retirement: " + key)
				break
	if is_instance_valid(native_tree_geometry_dispatcher):
		native_tree_geometry_dispatcher.call("drain_tree_geometry_compiles")
		native_tree_geometry_dispatcher = null
	if not _drain_tree_value_retirements():
		push_error("Tree value retirement did not drain before queue teardown")
	if is_instance_valid(tree_value_retirement_owner):
		var shutdown: Dictionary = tree_value_retirement_owner.shutdown()
		if String(shutdown.get("status", "")) != "ready":
			push_error("Tree value retirement worker did not join before queue teardown")
	if not staged_publication_task.is_empty():
		release_staged_visual(staged_publication_task)
	for task_index in range(completed_head, completed.size()):
		release_staged_visual(completed[task_index])
