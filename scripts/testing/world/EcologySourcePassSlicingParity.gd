extends SceneTree
## Production source-pass slicing parity service fixture; not gameplay evidence.

const MainScene := preload("res://scenes/Main.tscn")
const ActiveRemovedProps := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const ProducerDomain := preload("res://scripts/world/EcologyProducerDomain.gd")
const StructureSystem := preload("res://scripts/StructureSystem.gd")
const TreeCompiler := preload("res://scripts/world/TreeRecipeSectionCompiler.gd")
const REQUIRED_STATIC_FAMILIES := ["surface_rocks", "ore", "forage", "details",
	"underground_props"]
const REPORT_SCHEMA := "ecology-source-pass-slicing-parity/v1"
const MAX_CANDIDATE_CHUNKS := 96
const MAX_PASS_CALLS := 50000
const PROGRESS_INTERVAL_CALLS := 250

var report_path := ""
var progress_path := ""
var seed_text := "ecology-source-pass-slicing-parity-v1"
var main: Node3D
var checks: Array[Dictionary] = []
var started_usec := 0
var _search_diagnostics: Dictionary = {}
var _publication_handles_by_family_key: Dictionary = {}


func _initialize() -> void:
	seed_text = OS.get_environment("ECOLOGY_SOURCE_PASS_PARITY_SEED").strip_edges()
	if seed_text.is_empty():
		seed_text = "ecology-source-pass-slicing-parity-v1"
	report_path = OS.get_environment("ECOLOGY_SOURCE_PASS_PARITY_REPORT")
	progress_path = OS.get_environment("ECOLOGY_SOURCE_PASS_PARITY_PROGRESS")
	call_deferred("_run")


func _run() -> void:
	started_usec = Time.get_ticks_usec()
	_write_progress("initializing_production_main_authorities", {})
	main = MainScene.instantiate() as Node3D
	if not is_instance_valid(main):
		_record("production_main_instantiated", false, {})
		_finish("main_scene_instantiation_failed")
		return
	# Service-level fixture: initialize the actual source authorities without
	# environment, actor, story or gameplay streaming setup. Those services need
	# a live scene and are outside the contract compared here.
	main.set("seed_text", seed_text)
	main.set("seed_hash", int(main.call("hash_string", seed_text)))
	main.call("apply_world_seed", seed_text, false)
	main.call("setup_materials")
	main.call("setup_biome_environment_catalog")
	main.call("setup_visual_asset_registry")
	main.call("setup_animated_asset_registry")
	var structures := StructureSystem.new()
	main.set("structure_system", structures)
	structures.setup(main)
	var coordinator: Object = main.get("world_static_section_coordinator")
	var configured: Dictionary = coordinator.call("configure", "seed:%s:%d" % [
		seed_text, int(main.get("seed_hash"))])
	var world_id := String(main.get("world_static_section_coordinator").call(
		"world_identity"))
	var setup_ready := String(configured.get("status", "")) == "ready" \
		and not world_id.is_empty() \
		and is_instance_valid(main.get("world_generation_system")) \
		and is_instance_valid(main.get("structure_system")) \
		and is_instance_valid(main.get("visual_asset_registry")) \
		and is_instance_valid(main.get("animated_asset_registry"))
	_record("real_main_generation_catalog_and_structure_authorities_initialized",
		setup_ready, {"worldId":world_id, "seed":seed_text,
		"mainInsideSceneTree":main.is_inside_tree(),
		"gameplayStartupStarted":false})
	if not setup_ready:
		_finish("production_authority_setup_incomplete")
		return
	var scope: Dictionary = main.call("begin_ecology_source_catalog_context_scope")
	if String(scope.get("status", "")) != "ready":
		_record("real_catalog_publications_admitted", false, scope)
		_finish("catalog_scope_not_ready")
		return
	var artifact_result: Dictionary = main.call("_active_ecology_catalog_artifact",
		world_id, seed_text)
	if String(artifact_result.get("status", "")) != "ready":
		_record("real_catalog_publications_admitted", false, artifact_result)
		main.call("end_ecology_source_catalog_context_scope", scope)
		_finish("catalog_artifact_not_ready")
		return
	var artifact: Dictionary = artifact_result.get("artifact", {})
	_record("real_catalog_publications_admitted", not artifact.is_empty(), {
		"artifactId":String(artifact.get("artifactId", "")),
		"catalogContentDigest":String(artifact.get("catalogContentDigest", ""))})
	if artifact.is_empty():
		main.call("end_ecology_source_catalog_context_scope", scope)
		_finish("catalog_artifact_empty")
		return
	var town_finalization := _finalize_seeded_town_inputs_for_candidates(artifact)
	_record("production_town_region_inputs_finalized_before_admission",
		String(town_finalization.get("status", "")) == "ready", town_finalization)
	if String(town_finalization.get("status", "")) != "ready":
		main.call("end_ecology_source_catalog_context_scope", scope)
		_finish("production_town_inputs_not_finalized")
		return
	var target_key: Variant = _find_natural_output_chunk(world_id, artifact)
	if target_key == null:
		main.call("end_ecology_source_catalog_context_scope", scope)
		_record("naturally_generated_chunk_has_static_and_actor_outputs", false, {
			"actorCaseUnavailable":true, "searchedChunkCount":_search_count,
			"candidateDiagnostics":_search_diagnostics,
			"note":"No contributor or actor was injected; no candidate met the natural source requirements."})
		_finish("natural_static_and_actor_case_unavailable")
		return
	_record("naturally_generated_chunk_has_static_and_actor_outputs", true, {
		"sourceChunkKey":target_key, "searchedChunkCount":int(_search_count)})
	var prepared: Dictionary = _prepared_source_inputs(world_id, target_key, artifact)
	if String(prepared.get("status", "")) != "ready":
		main.call("end_ecology_source_catalog_context_scope", scope)
		_record("chosen_source_inputs_are_current_and_ready", false, prepared)
		_finish("chosen_source_inputs_not_ready")
		return
	var one: Dictionary = _run_complete_pass(world_id, target_key, prepared, artifact, 1)
	if String(one.get("status", "")) != "ready":
		main.call("end_ecology_source_catalog_context_scope", scope)
		_record("one_attempt_budget_pass_completed", false, one)
		_finish("one_attempt_budget_pass_incomplete")
		return
	_record("one_attempt_budget_pass_completed", true, {
		"callCount":one.get("callCount", 0), "sourceCount":one.get("sourceCount", 0),
		"actorIntentCount":one.get("actorIntentCount", 0)})
	var eight: Dictionary = _run_complete_pass(world_id, target_key, prepared, artifact, 8)
	if String(eight.get("status", "")) != "ready":
		main.call("end_ecology_source_catalog_context_scope", scope)
		_record("eight_attempt_budget_pass_completed", false, eight)
		_finish("eight_attempt_budget_pass_incomplete")
		return
	_record("eight_attempt_budget_pass_completed", true, {
		"callCount":eight.get("callCount", 0), "sourceCount":eight.get("sourceCount", 0),
		"actorIntentCount":eight.get("actorIntentCount", 0)})
	var same_sources := String(one.get("sourceManifestDigest", "")) \
		== String(eight.get("sourceManifestDigest", ""))
	var same_actors := String(one.get("actorIntentDigest", "")) \
		== String(eight.get("actorIntentDigest", ""))
	var same_rng: bool = one.get("finalRngState", {}) == eight.get("finalRngState", {})
	_record("canonical_static_source_manifest_matches_across_budgets", same_sources, {
		"oneAttemptDigest":one.get("sourceManifestDigest", ""),
		"eightAttemptDigest":eight.get("sourceManifestDigest", ""),
		"oneAttemptSourceCount":one.get("sourceCount", 0),
		"eightAttemptSourceCount":eight.get("sourceCount", 0)})
	_record("wildlife_actor_intent_manifest_matches_across_budgets", same_actors, {
		"oneAttemptDigest":one.get("actorIntentDigest", ""),
		"eightAttemptDigest":eight.get("actorIntentDigest", ""),
		"oneAttemptActorCount":one.get("actorIntentCount", 0),
		"eightAttemptActorCount":eight.get("actorIntentCount", 0)})
	_record("all_producer_rng_streams_match_after_complete_pass", same_rng, {
		"oneAttempt":one.get("finalRngState", {}),
		"eightAttempt":eight.get("finalRngState", {})})
	_run_public_family_widening(world_id, target_key, prepared, artifact, one)
	var end_result: Dictionary = main.call("end_ecology_source_catalog_context_scope", scope)
	_record("catalog_capture_scope_closed", String(end_result.get("status", "")) == "ready",
		end_result)
	var passed := _all_checks_passed()
	_finish("source_pass_slicing_parity_complete" if passed else "source_pass_slicing_parity_failed")


var _search_count := 0


func _probe_rejected_queue_record(queue: Object, valid_snapshot: Dictionary,
		catalog_token: String, artifact: Dictionary) -> void:
	# Explicit synthetic negative input, kept separate from generated parity rows.
	var malformed_rows: Array = valid_snapshot.get("sourceRows", []).duplicate(true)
	for row: Dictionary in malformed_rows:
		row["schema"] = "synthetic-invalid-tree-schema"
	var malformed := ProducerDomain.seal_source_domain_family_bundle({
		"worldId":valid_snapshot.worldId, "worldSeed":valid_snapshot.worldSeed,
		"sourceChunkKey":valid_snapshot.sourceChunkKey,
		"sourceInputs":valid_snapshot.sourceInputs,
		"familyRequest":valid_snapshot.familyRequest,
		"sourceRows":malformed_rows, "actorIntentSnapshot":[],
		"completedFamilies":["trees"],
		"removedSourceProjectionDigest":valid_snapshot.removedSourceProjectionDigest}, artifact)
	var admission: Dictionary = main.call("admit_ecology_source_publication", malformed,
		catalog_token, "synthetic_queue_rejection", "wrong-schema")
	var before: Dictionary = main.call("ecology_source_capture_diagnostics_snapshot")
	var queue_jobs: Dictionary = queue.get("ecology_source_compile_jobs")
	var jobs_before := queue_jobs.size()
	var rejected: Dictionary = queue.call("request_ecology_tree_source_compile",
		main, malformed, "synthetic-queue-rejection", admission.get("view", {}))
	var after: Dictionary = main.call("ecology_source_capture_diagnostics_snapshot")
	_record("synthetic_invalid_tree_record_is_not_accepted_as_queued_work",
		admission.get("status", "") == "ready" \
		and rejected.get("status", "") == "pending" \
		and rejected.get("reason", "") == "tree_source_record_schema_or_family_invalid" \
		and String(rejected.get("jobKey", "")).is_empty() \
		and queue_jobs.size() == jobs_before \
		and before.get("sourcePublication", {}).get("consumerLeaseCount", -1) \
			== after.get("sourcePublication", {}).get("consumerLeaseCount", -2),
		{"evidenceLevel":"synthetic_negative_admission", "result":rejected})
	main.call("release_ecology_source_publication", String(admission.get("leaseToken", "")))


func _run_public_family_widening(world_id: String, key: Vector2i,
		prepared: Dictionary, artifact: Dictionary, reference: Dictionary) -> void:
	var narrow_lease: Dictionary = main.call("acquire_ecology_catalog_artifact_lease",
		String(artifact.artifactId), "source_pass_parity", "narrow", world_id,
		int(artifact.worldEpoch))
	var wide_lease: Dictionary = main.call("acquire_ecology_catalog_artifact_lease",
		String(artifact.artifactId), "source_pass_parity", "wide", world_id,
		int(artifact.worldEpoch))
	var narrow_token := String(narrow_lease.get("leaseToken", ""))
	var wide_token := String(wide_lease.get("leaseToken", ""))
	var leases_ready := not narrow_token.is_empty() and not wide_token.is_empty() \
		and narrow_token != wide_token
	_record("family_requests_have_independent_live_leases", leases_ready, {})
	if not leases_ready: return
	var narrow := _capture_families(world_id, key, prepared, artifact,
		narrow_token, ["trees"])
	_record("tree_only_public_capture_completes", narrow.get("status") == "ready", {
		"status":narrow.get("status"), "reason":narrow.get("reason", "")})
	if narrow.get("status") == "ready":
		var narrow_handle: Dictionary = _publication_handles_by_family_key.get(
			_family_publication_key(["trees"]), {})
		var original_digest := ProducerDomain.digest_value(narrow)
		var sessions: Dictionary = main.get("_ecology_source_capture_sessions")
		var identity := ProducerDomain.snapshot_cache_identity(world_id, key,
			prepared.sourceInputs, String(narrow.removedSourceProjectionDigest), artifact)
		var narrow_state: Dictionary = sessions.get(identity, {}).get("state", {})
		var surface_rng: RandomNumberGenerator = narrow_state.get("rng")
		var surface_rng_state := surface_rng.state if surface_rng != null else -1
		var before_widen: Dictionary = main.call("ecology_source_capture_diagnostics_snapshot")
		var narrow_view_value: Variant = narrow_handle.get("view", {})
		var narrow_view: Dictionary = narrow_view_value if narrow_view_value is Dictionary else {}
		var narrow_family_results_value: Variant = narrow_view.get("familyResultsById", {})
		var narrow_family_results: Dictionary = narrow_family_results_value \
			if narrow_family_results_value is Dictionary else {}
		var tree_only_value: Variant = narrow_family_results.get("trees", {})
		var tree_only: Dictionary = tree_only_value if tree_only_value is Dictionary else {}
		var current_tree_count := 0
		var first_currentness_failure: Dictionary = {}
		var local_currentness: Dictionary = main.call(
			"ecology_source_publication_local_is_current",
			narrow_view, String(narrow_handle.get("leaseToken", "")))
		for tree_row: Dictionary in tree_only.get("sourceRows", []):
			var currentness: Dictionary = main.call(
				"ecology_source_publication_record_is_current",
				narrow_view,
				String(narrow_handle.get("leaseToken", "")), tree_row)
			if currentness.get("status") == "ready":
				current_tree_count += 1
			elif first_currentness_failure.is_empty():
				first_currentness_failure = currentness
		_record("retained_surface_session_proves_nonempty_tree_currentness",
			local_currentness.get("status") == "ready" and current_tree_count > 0 \
			and first_currentness_failure.is_empty(), {
				"currentTreeCount":current_tree_count, "local":local_currentness,
				"failure":first_currentness_failure})
		# Service compilation through the actual queue; this does not execute a
		# gameplay frame or prove renderer installation.
		var queue: Object = main.call("ensure_tree_publication_queue")
		_probe_rejected_queue_record(queue, narrow, narrow_token, artifact)
		_probe_empty_queue_publication(queue, narrow, narrow_token, artifact)
		var before_queue: Dictionary = main.call("ecology_source_capture_diagnostics_snapshot")
		var queue_admission: Dictionary = queue.call("request_ecology_tree_source_compile",
			main, narrow, "source-parity-real-queue", narrow_view)
		var queue_job_key := String(queue_admission.get("jobKey", ""))
		var queue_jobs: Dictionary = queue.get("ecology_source_compile_jobs")
		var queue_job: Dictionary = queue_jobs.get(queue_job_key, {})
		var compiler: Object = queue_job.get("compiler") as Object
		var compiler_progress: Dictionary = compiler.call("progress_snapshot") \
			if is_instance_valid(compiler) else {}
		var generated_tree_schemas: Array[String] = []
		for row: Dictionary in tree_only.get("sourceRows", []):
			var schema := String(row.get("schema", ""))
			if schema not in generated_tree_schemas:
				generated_tree_schemas.append(schema)
		_record("generated_tree_publication_admitted_by_actual_queue",
			queue_admission.get("status", "") in ["pending", "ready"] \
			and not queue_job_key.is_empty() and queue_jobs.has(queue_job_key) \
			and compiler_progress.get("status", "") == "pending" \
			and int(compiler_progress.get("recordCount", 0)) == current_tree_count,
			{"admission":queue_admission, "compiler":compiler_progress,
				"generatedSchemas":generated_tree_schemas})
		_probe_generated_tree_completion(queue, queue_job_key, compiler, narrow, narrow_view)
		if not queue_job_key.is_empty():
			queue.call("cancel_ecology_tree_source_compile", queue_job_key,
				"source-parity-real-queue")
		var after_queue: Dictionary = main.call("ecology_source_capture_diagnostics_snapshot")
		_record("actual_queue_admission_release_preserves_capture_publication",
			before_queue.get("sourcePublication", {}).get("consumerLeaseCount", -1) \
			== after_queue.get("sourcePublication", {}).get("consumerLeaseCount", -2) \
			and not queue_jobs.has(queue_job_key), {})
		var details_value: Variant = narrow_family_results.get("details", {})
		var details: Dictionary = details_value if details_value is Dictionary else {}
		_record("tree_only_capture_defers_details_without_empty_success",
			tree_only.get("status") == "ready" and details.get("status") == "pending" \
			and details.get("disposition") == "deferred_unrequested", {})
		var wider := _capture_families(world_id, key, prepared, artifact,
			wide_token, ProducerDomain.REQUIRED_CATEGORIES)
		_record("widened_public_capture_completes", wider.get("status") == "ready", {
			"status":wider.get("status"), "reason":wider.get("reason", "")})
		if wider.get("status") == "ready":
			var wide_handle: Dictionary = _publication_handles_by_family_key.get(
				_family_publication_key(ProducerDomain.REQUIRED_CATEGORIES), {})
			var after_widen: Dictionary = main.call("ecology_source_capture_diagnostics_snapshot")
			var duplicate_member_rows := _duplicate_source_member_identity_rows(
				wider.get("sourceRows", []))
			_record("public_family_bundle_has_unique_source_member_pairs",
				duplicate_member_rows.is_empty(), {
					"rowCount":(wider.get("sourceRows", []) as Array).size(),
					"duplicateIdentitySampleCount":duplicate_member_rows.size(),
					"duplicateSamples":duplicate_member_rows})
			var full_request := ProducerDomain.build_source_family_request(
				ProducerDomain.REQUIRED_CATEGORIES, world_id, seed_text, key,
				prepared.sourceInputs, String(narrow.removedSourceProjectionDigest),
				artifact, wide_token)
			var reference_bundle := ProducerDomain.seal_source_domain_family_bundle({
				"worldId":world_id, "worldSeed":seed_text, "sourceChunkKey":key,
				"sourceInputs":prepared.sourceInputs, "familyRequest":full_request,
				"catalogLeaseToken":wide_token,
				"removedSourceProjectionDigest":String(narrow.removedSourceProjectionDigest),
				"sourceRows":reference.get("sourceRows", []),
				"actorIntentSnapshot":reference.get("actorIntents", []),
				"completedFamilies":ProducerDomain.REQUIRED_CATEGORIES}, artifact)
			_record("widening_preserves_original_sealed_tree_bundle",
				ProducerDomain.digest_value(narrow) == original_digest \
				and ProducerDomain.source_family_result(wider, "trees", artifact).get(
					"familyRevision") == tree_only.get("familyRevision"), {})
			_record("widening_reuses_surface_rng_without_resampling",
				not narrow_state.is_empty() and surface_rng != null \
				and surface_rng.state == surface_rng_state \
				and int(narrow_state.get("propIndex", -1)) == 28 \
				and before_widen.get("sessionLifecycle", {}).get("created", -1) \
					== after_widen.get("sessionLifecycle", {}).get("created", -2), {
					"before":before_widen.get("sessionLifecycle", {}),
					"after":after_widen.get("sessionLifecycle", {})})
			_record("public_widening_matches_full_pass_sources_and_actors",
				reference_bundle.get("status") == "ready" \
				and wider.get("sourceRows", []) == reference_bundle.get("sourceRows", []) \
				and wider.get("actorIntentDigest") == reference_bundle.get("actorIntentDigest"), {
					"referenceStatus":reference_bundle.get("status"),
					"referenceRowsDigest":ProducerDomain.digest_value(reference_bundle.get("sourceRows", [])),
					"actualRowsDigest":ProducerDomain.digest_value(wider.get("sourceRows", [])),
					"differential":_bounded_bundle_difference(wider, reference_bundle)})
			var duplicate_admission: Dictionary = main.call(
				"admit_ecology_source_publication", wider, wide_token,
				"source_pass_parity_duplicate", "wide-family-bundle")
			var duplicate_view_value: Variant = duplicate_admission.get(
				"sourcePublicationView", duplicate_admission.get("view", {}))
			var duplicate_view: Dictionary = duplicate_view_value \
				if duplicate_view_value is Dictionary else {}
			var wide_view_value: Variant = wide_handle.get("view", {})
			var wide_view: Dictionary = wide_view_value if wide_view_value is Dictionary else {}
			var duplicate_publication_token := String(duplicate_admission.get(
				"sourcePublicationLeaseToken", duplicate_admission.get("leaseToken", "")))
			var caller_release: Dictionary = main.call(
				"release_ecology_catalog_artifact_lease", wide_token)
			var publication_resolve: Dictionary = main.call(
				"resolve_ecology_source_publication", duplicate_publication_token,
				world_id, int(artifact.worldEpoch))
			var duplicate_row_check := {"status":"pending"}
			var wide_rows: Array = wider.get("sourceRows", [])
			if not wide_rows.is_empty():
				duplicate_row_check = main.call(
					"ecology_source_publication_record_is_current", duplicate_view,
					duplicate_publication_token, wide_rows[0])
			_record("public_duplicate_admission_retains_exact_view_after_caller_lease_release",
				String(duplicate_admission.get("status", "")) == "ready" \
				and String(caller_release.get("status", "")) == "ready" \
				and is_same(duplicate_view, wide_view) \
				and String(publication_resolve.get("status", "")) == "ready" \
				and String(duplicate_row_check.get("status", "")) == "ready", {
					"admissionStatus":duplicate_admission.get("status", ""),
					"releaseStatus":caller_release.get("status", ""),
					"resolveStatus":publication_resolve.get("status", ""),
					"recordStatus":duplicate_row_check.get("status", ""),
					"sameViewAlias":is_same(duplicate_view, wide_view)})
			main.call("release_ecology_source_publication", duplicate_publication_token)
			main.call("release_ecology_source_publication",
				String(wide_handle.get("leaseToken", "")))
		main.call("release_ecology_source_publication",
			String(narrow_handle.get("leaseToken", "")))
	main.call("release_ecology_catalog_artifact_lease", narrow_token)
	main.call("release_ecology_catalog_artifact_lease", wide_token)


func _probe_empty_queue_publication(queue: Object, snapshot: Dictionary,
		catalog_token: String, catalog: Dictionary) -> void:
	# Synthetic authoritative-empty contract; never cited as generated gameplay.
	var empty := ProducerDomain.seal_source_domain_family_bundle({
		"worldId":snapshot.worldId, "worldSeed":snapshot.worldSeed,
		"sourceChunkKey":snapshot.sourceChunkKey, "sourceInputs":snapshot.sourceInputs,
		"familyRequest":snapshot.familyRequest, "sourceRows":[], "actorIntentSnapshot":[],
		"completedFamilies":["trees"],
		"removedSourceProjectionDigest":snapshot.removedSourceProjectionDigest}, catalog)
	var admitted: Dictionary = main.call("admit_ecology_source_publication", empty,
		catalog_token, "synthetic_empty_queue", "empty")
	var view: Dictionary = admitted.get("sourcePublicationView", admitted.get("view", {}))
	var token := String(admitted.get("sourcePublicationLeaseToken", admitted.get("leaseToken", "")))
	var request: Dictionary = queue.call("request_ecology_tree_source_compile",
		main, empty, "synthetic-empty-queue", view)
	var key := String(request.get("jobKey", ""))
	var polled: Dictionary = queue.call("poll_ecology_tree_source_compile", key,
		"synthetic-empty-queue")
	var output: Dictionary = polled.get("artifact", {})
	_record("authoritative_empty_queue_output_is_sealed_and_current",
		admitted.get("status") == "ready" and polled.get("status") == "ready" \
			and output.get("sources", [null]).is_empty() \
			and output.get("batches", [null]).is_empty() \
			and _containers_are_read_only(output), {
			"admissionStatus":admitted.get("status"), "pollStatus":polled.get("status"),
			"artifactContainersReadOnly":_containers_are_read_only(output),
			"evidenceLevel":"synthetic_authoritative_empty_queue_contract"})
	queue.call("cancel_ecology_tree_source_compile", key, "synthetic-empty-queue")
	main.call("release_ecology_source_publication", token)


func _probe_generated_tree_completion(queue: Object, job_key: String, compiler: Object,
		snapshot: Dictionary, publication: Dictionary) -> void:
	var deadline := Time.get_ticks_msec() + 20000
	var job := {}
	while not job_key.is_empty() and Time.get_ticks_msec() < deadline:
		queue.call("start_pending_source_recipe_workers")
		queue.call("collect_completed_source_recipe_workers")
		queue.call("advance_ecology_source_compilers")
		job = queue.get("ecology_source_compile_jobs").get(job_key, {})
		if job.get("status") in ["complete", "failed"] \
				or job.get("reason") == "tree_source_family_envelope_unproven":
			break
		OS.delay_msec(1)
	var bounds_evidence := {}
	if is_instance_valid(compiler):
		var compiler_job: Dictionary = compiler.get("_job")
		var recipe_results: Dictionary = queue.get("source_recipe_completed")
		for record: Dictionary in compiler_job.get("records", []):
			var recipe_artifact: Dictionary = recipe_results.get(record.get("recipeJobKey", ""), {})
			if recipe_artifact.is_empty(): continue
			var envelope := TreeCompiler.certify_recipe_support_envelope(
				recipe_artifact.get("recipe", {}), record.bodyGlobalTransform)
			var proof: Dictionary = record.get("supportProof", {})
			var declared: Variant = proof.get("worldBounds")
			var actual: Variant = envelope.get("value", {}).get("worldBounds")
			bounds_evidence = {"sourceId":record.get("sourceId"),
				"proof":proof, "envelopeStatus":envelope.get("status"),
				"actualWorldBounds":actual,
				"declaredContainsActual":declared is AABB and actual is AABB \
					and TreeCompiler._bounds_contains(declared, actual)}
			break
	_record("generated_tree_publication_compiles_through_actual_queue",
		job.get("status") == "complete" and not job.get("result", {}).is_empty() \
			and _containers_are_read_only(job.get("result", {})), {
			"status":job.get("status", "missing"), "reason":job.get("reason", ""),
			"artifactContainersReadOnly":_containers_are_read_only(job.get("result", {})),
			"bounds":bounds_evidence,
			"evidenceLevel":"real_generated_source_recipe_and_section_compile_service",
			"gameplayAcceptance":false})
	_probe_generated_tree_support(job.get("result", {}), snapshot, publication)


func _probe_generated_tree_support(artifact: Dictionary, snapshot: Dictionary,
		publication: Dictionary) -> void:
	# Load this downstream probe after Main's owner-bound catalog is captured;
	# adding an early preload changes process-local owner instance identities.
	var adapter: Object = load("res://scripts/world/EcologySectionValueAdapter.gd").new()
	adapter.configure(String(snapshot.worldId))
	var index: Object = adapter.get("_support_index")
	var family: Dictionary = publication.get("familyResultsById", {}).get("trees", {})
	var source_by_id := {}
	for row: Dictionary in family.get("sourceRows", []):
		source_by_id[String(row.sourceId)] = row
	var member_count := 0
	var manifest_count := 0
	var failure := {}
	for manifest: Dictionary in artifact.get("sources", []):
		var source: Dictionary = source_by_id.get(String(manifest.get("sourceId", "")), {})
		var bound: Dictionary = adapter.call("_bind_tree_compiler_manifest_to_source",
			manifest, source, snapshot.sourceChunkKey, snapshot, family)
		if bound.get("status") != "ready":
			failure = bound
			break
		var projected: Dictionary = adapter.tree_support_rows_from_manifest(bound.manifest)
		if projected.get("status") != "ready":
			failure = projected
			break
		for member: Dictionary in projected.rows:
			var validated: Dictionary = index.call("_validate_source_row", member,
				String(snapshot.worldId), snapshot.sourceChunkKey,
				String(snapshot.sourceRevision), publication.supportPolicy)
			if validated.get("status") != "ready" \
					or not (member.sourceOrigin as Vector3).is_equal_approx(source.sourceOrigin):
				failure = {"validation":validated, "actualOrigin":member.sourceOrigin,
					"expectedOrigin":source.sourceOrigin}
				break
			member_count += 1
		if not failure.is_empty(): break
		manifest_count += 1
	_record("generated_nonzero_chunk_tree_support_validates_against_index",
		snapshot.sourceChunkKey != Vector2i.ZERO and failure.is_empty() \
			and member_count > 0 and manifest_count == source_by_id.size(), {
			"sourceChunkKey":snapshot.sourceChunkKey, "manifestCount":manifest_count,
			"validatedMemberCount":member_count, "failure":failure,
			"evidenceLevel":"real_generated_artifact_support_projection_service",
			"doesNotProve":"full section census, contribution, native installation or gameplay"})


func _containers_are_read_only(value: Variant) -> bool:
	if value is Dictionary:
		if not value.is_read_only(): return false
		for key: Variant in value:
			if not _containers_are_read_only(value[key]): return false
	elif value is Array:
		if not value.is_read_only(): return false
		for entry: Variant in value:
			if not _containers_are_read_only(entry): return false
	return true


func _bounded_bundle_difference(actual: Dictionary, expected: Dictionary) -> Dictionary:
	var actual_rows_value: Variant = actual.get("sourceRows", [])
	var expected_rows_value: Variant = expected.get("sourceRows", [])
	var actual_rows: Array = actual_rows_value if actual_rows_value is Array else []
	var expected_rows: Array = expected_rows_value if expected_rows_value is Array else []
	var actual_by_identity: Dictionary = {}
	var expected_by_identity: Dictionary = {}
	var actual_identity_counts: Dictionary = {}
	var expected_identity_counts: Dictionary = {}
	var actual_family_counts: Dictionary = {}
	var expected_family_counts: Dictionary = {}
	for row_value: Variant in actual_rows:
		if row_value is Dictionary:
			var actual_identity := "%s|%s" % [String(row_value.get("sourceId", "")),
				String(row_value.get("sourcePartId", ""))]
			actual_by_identity[actual_identity] = row_value
			actual_identity_counts[actual_identity] = int(
				actual_identity_counts.get(actual_identity, 0)) + 1
			var actual_family := String(row_value.get("producerFamily", ""))
			actual_family_counts[actual_family] = int(actual_family_counts.get(actual_family, 0)) + 1
	for row_value: Variant in expected_rows:
		if row_value is Dictionary:
			var expected_identity := "%s|%s" % [String(row_value.get("sourceId", "")),
				String(row_value.get("sourcePartId", ""))]
			expected_by_identity[expected_identity] = row_value
			expected_identity_counts[expected_identity] = int(
				expected_identity_counts.get(expected_identity, 0)) + 1
			var expected_family := String(row_value.get("producerFamily", ""))
			expected_family_counts[expected_family] = int(
				expected_family_counts.get(expected_family, 0)) + 1
	var identities: Array[String] = []
	for identity_value: Variant in actual_by_identity.keys():
		identities.append(String(identity_value))
	for identity_value: Variant in expected_by_identity.keys():
		if not identities.has(String(identity_value)):
			identities.append(String(identity_value))
	identities.sort()
	var first_difference: Dictionary = {}
	var missing_from_actual: Array[String] = []
	var missing_from_expected: Array[String] = []
	var duplicate_count_differences: Array[Dictionary] = []
	for identity: String in identities:
		var has_actual := actual_by_identity.has(identity)
		var has_expected := expected_by_identity.has(identity)
		var actual_count := int(actual_identity_counts.get(identity, 0))
		var expected_count := int(expected_identity_counts.get(identity, 0))
		if actual_count != expected_count and duplicate_count_differences.size() < 8:
			var exemplar: Dictionary = actual_by_identity.get(identity,
				expected_by_identity.get(identity, {}))
			var content_exemplar: Dictionary = exemplar.duplicate(true)
			content_exemplar.erase("familyRevision")
			content_exemplar.erase("producerSnapshotRevision")
			content_exemplar.erase("familyManifestDigest")
			duplicate_count_differences.append({"identity":identity,
				"family":String(exemplar.get("producerFamily", "")),
				"actualCount":actual_count, "expectedCount":expected_count,
				"unstampedContentDigest":ProducerDomain.digest_value(content_exemplar)})
		if not has_actual:
			if missing_from_actual.size() < 5: missing_from_actual.append(identity)
			continue
		if not has_expected:
			if missing_from_expected.size() < 5: missing_from_expected.append(identity)
			continue
		var actual_row: Dictionary = actual_by_identity[identity]
		var expected_row: Dictionary = expected_by_identity[identity]
		if actual_row == expected_row:
			continue
		var fields: Array[String] = []
		var row_keys: Dictionary = {}
		for field_value: Variant in actual_row.keys():
			row_keys[String(field_value)] = true
		for field_value: Variant in expected_row.keys():
			row_keys[String(field_value)] = true
		for field_value: Variant in row_keys.keys():
			var field := String(field_value)
			if actual_row.get(field, null) != expected_row.get(field, null):
				fields.append(field)
		fields.sort()
		first_difference = {"identity":identity, "differentFields":fields.slice(0, 12),
			"actualRowDigest":ProducerDomain.digest_value(actual_row),
			"expectedRowDigest":ProducerDomain.digest_value(expected_row),
			"actualFamilyRevision":actual_row.get("familyRevision", ""),
			"expectedFamilyRevision":expected_row.get("familyRevision", ""),
			"actualProducerSnapshotRevision":actual_row.get("producerSnapshotRevision", ""),
			"expectedProducerSnapshotRevision":expected_row.get("producerSnapshotRevision", "")}
		break
	var actual_actors: Variant = actual.get("actorIntentSnapshot", [])
	var expected_actors: Variant = expected.get("actorIntentSnapshot", [])
	var actual_actor_array: Array = actual_actors if actual_actors is Array else []
	var expected_actor_array: Array = expected_actors if expected_actors is Array else []
	return {"actualRowCount":actual_rows.size(), "expectedRowCount":expected_rows.size(),
		"actualFamilyRowCounts":actual_family_counts,
		"expectedFamilyRowCounts":expected_family_counts,
		"duplicateIdentityCountDifferenceSamples":duplicate_count_differences,
		"actualSourceRevision":actual.get("sourceRevision", ""),
		"expectedSourceRevision":expected.get("sourceRevision", ""),
		"actualProducerSnapshotRevision":actual.get("producerSnapshotRevision", ""),
		"expectedProducerSnapshotRevision":expected.get("producerSnapshotRevision", ""),
		"actualFamilyCoverageDigest":actual.get("familyCoverageDigest", ""),
		"expectedFamilyCoverageDigest":expected.get("familyCoverageDigest", ""),
		"actualActorIntentDigest":actual.get("actorIntentDigest", ""),
		"expectedActorIntentDigest":expected.get("actorIntentDigest", ""),
		"actualActorIntentCount":actual_actor_array.size(),
		"expectedActorIntentCount":expected_actor_array.size(),
		"actualActorIntentSnapshotDigest":ProducerDomain.digest_value(actual_actor_array),
		"expectedActorIntentSnapshotDigest":ProducerDomain.digest_value(expected_actor_array),
		"firstDifferingRow":first_difference,
		"missingFromActual":missing_from_actual,
		"missingFromExpected":missing_from_expected}


func _duplicate_source_member_identity_rows(rows_value: Variant) -> Array[Dictionary]:
	var rows: Array = rows_value if rows_value is Array else []
	var counts: Dictionary = {}
	var exemplars: Dictionary = {}
	for row_value: Variant in rows:
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		var identity := "%s|%s" % [String(row.get("sourceId", "")),
			String(row.get("sourcePartId", ""))]
		counts[identity] = int(counts.get(identity, 0)) + 1
		exemplars[identity] = row
	var duplicates: Array[Dictionary] = []
	var identities: Array = counts.keys()
	identities.sort()
	for identity_value: Variant in identities:
		var identity := String(identity_value)
		var count := int(counts[identity])
		if count <= 1:
			continue
		var row: Dictionary = exemplars[identity]
		duplicates.append({"identity":identity, "count":count,
			"family":String(row.get("producerFamily", "")),
			"rowContentDigest":ProducerDomain.digest_value(row)})
		if duplicates.size() >= 8:
			break
	return duplicates


func _capture_families(world_id: String, key: Vector2i, prepared: Dictionary,
		artifact: Dictionary, lease_token: String, families: Array) -> Dictionary:
	var removed := ActiveRemovedProps.capture(main)
	var projection: Dictionary = main.call("_removed_props_projection_for_source_chunk", key, removed)
	var request := ProducerDomain.build_source_family_request(families, world_id,
		seed_text, key, prepared.sourceInputs, String(projection.get("digest", "")),
		artifact, lease_token)
	var result: Dictionary = {}
	for call_index in range(MAX_PASS_CALLS):
		result = main.call("capture_ecology_source_domain", world_id, key, seed_text,
			prepared.sourceInputs, removed, lease_token, request)
		if String(result.get("status", "")) in ["ready", "failed", "stale"]:
			if String(result.get("status", "")) != "ready": return result
			var snapshot_value: Variant = result.get("snapshot", null)
			var view_value: Variant = result.get("sourcePublicationView", null)
			if not snapshot_value is Dictionary or not view_value is Dictionary:
				return {"status":"failed", "reason":"capture_publication_envelope_missing"}
			var snapshot: Dictionary = snapshot_value
			var publication_view: Dictionary = view_value
			var source_publication_token := String(result.get(
				"sourcePublicationLeaseToken", ""))
			if source_publication_token.is_empty():
				return {"status":"failed", "reason":"capture_publication_lease_missing"}
			_publication_handles_by_family_key[_family_publication_key(families)] = {
				"publicationId":String(result.get("sourcePublicationId", "")),
				"leaseToken":source_publication_token,
				"view":publication_view}
			return snapshot
		if call_index % PROGRESS_INTERVAL_CALLS == 0:
			_write_progress("public_family_capture", {"families":families,
				"calls":call_index + 1, "reason":result.get("reason", ""),
				"captureProgress":result.get("captureProgress", {})})
	return result


func _family_publication_key(families: Array) -> String:
	var canonical: Array[String] = []
	for family_value: Variant in families:
		var family := String(family_value)
		if family not in canonical: canonical.append(family)
	canonical.sort()
	return ",".join(canonical)


func _find_natural_output_chunk(world_id: String, artifact: Dictionary) -> Variant:
	_search_diagnostics = {"candidateLimit":MAX_CANDIDATE_CHUNKS,
		"readyInputCount":0, "inputStatusCounts":{}, "inputFailureSamples":[],
		"attemptCount":0, "chunksWithTree":0, "chunksWithStaticMembers":0,
		"chunksWithActorIntent":0, "chunksWithTreeAndStatic":0,
		"chunksWithTreeStaticAndActor":0, "bestCandidate":{}}
	_search_count = 0
	var candidates := _candidate_source_chunk_keys()
	var removed_snapshot: Dictionary = ActiveRemovedProps.capture(main)
	if not bool(removed_snapshot.get("ok", false)):
		_record("durable_removal_authority_ready", false, {
			"reason":String(removed_snapshot.get("reason", "removed_props_snapshot_unavailable"))})
		return null
	for key: Vector2i in candidates:
		if _search_count >= MAX_CANDIDATE_CHUNKS:
			break
		_search_count += 1
		var prepared := _prepared_source_inputs(world_id, key, artifact)
		if String(prepared.get("status", "")) != "ready":
			var input_status := "%s:%s" % [String(prepared.get("status", "unknown")),
				String(prepared.get("reason", "unspecified"))]
			var input_counts: Dictionary = _search_diagnostics.inputStatusCounts
			input_counts[input_status] = int(input_counts.get(input_status, 0)) + 1
			_search_diagnostics.inputStatusCounts = input_counts
			var input_samples: Array = _search_diagnostics.inputFailureSamples
			if input_samples.size() < 5:
				input_samples.append({"sourceChunkKey":key, "status":prepared.get("status", ""),
					"reason":prepared.get("reason", ""),
					"structureDependencyStatus":prepared.get("structureDependencyStatus", "")})
			_search_diagnostics.inputFailureSamples = input_samples
			continue
		_search_diagnostics.readyInputCount = int(_search_diagnostics.readyInputCount) + 1
		var state: Dictionary = _new_pass_state(world_id, key, prepared,
			artifact, removed_snapshot)
		var rng: RandomNumberGenerator = state.get("rng") as RandomNumberGenerator
		if rng == null:
			continue
		for attempt in range(28):
			main.call("spawn_chunk_prop_attempt", state, attempt, rng)
			if not (state.get("sourceFamilyFailures", {}) as Dictionary).is_empty():
				_record("production_source_attempt_has_no_terminal_failure", false, {
					"sourceChunkKey":key, "familyFailures":state.sourceFamilyFailures})
				return null
			if not String(state.get("sourceCaptureFailure", "")).is_empty():
				_record("production_source_attempt_has_no_terminal_failure", false, {
					"sourceChunkKey":key,
					"reason":String(state.get("sourceCaptureFailure", "")),
					"details":state.get("sourceCaptureFailureDetails", {})})
				return null
		var static_count := 0
		var tree_count := 0
		var family_counts: Dictionary = {}
		var static_source_ids: Array[String] = []
		var tree_source_ids: Array[String] = []
		for row_value: Variant in state.get("sourceRows", []):
			if not row_value is Dictionary: continue
			var family := String(row_value.get("producerFamily", ""))
			family_counts[family] = int(family_counts.get(family, 0)) + 1
			if family == "trees":
				tree_count += 1
				if tree_source_ids.size() < 3:
					tree_source_ids.append(String(row_value.get("sourceId", "")))
			if family in REQUIRED_STATIC_FAMILIES \
					and row_value.get("renderMembers", []) is Array \
					and not row_value.get("renderMembers", []).is_empty():
				static_count += 1
				if static_source_ids.size() < 3:
					static_source_ids.append(String(row_value.get("sourceId", "")))
		var actor_count := (state.get("actorIntents", []) as Array).size()
		var has_tree := tree_count > 0
		var has_static := static_count > 0
		var has_actor := actor_count > 0
		_search_diagnostics.attemptCount = int(_search_diagnostics.attemptCount) + 28
		if has_tree: _search_diagnostics.chunksWithTree = int(_search_diagnostics.chunksWithTree) + 1
		if has_static: _search_diagnostics.chunksWithStaticMembers = int(
			_search_diagnostics.chunksWithStaticMembers) + 1
		if has_actor: _search_diagnostics.chunksWithActorIntent = int(
			_search_diagnostics.chunksWithActorIntent) + 1
		if has_tree and has_static:
			_search_diagnostics.chunksWithTreeAndStatic = int(
				_search_diagnostics.chunksWithTreeAndStatic) + 1
		if has_tree and has_static and has_actor:
			_search_diagnostics.chunksWithTreeStaticAndActor = int(
				_search_diagnostics.chunksWithTreeStaticAndActor) + 1
		var best_score := tree_count + static_count + actor_count
		var previous_best: Dictionary = _search_diagnostics.bestCandidate
		if best_score > int(previous_best.get("score", -1)):
			_search_diagnostics.bestCandidate = {"sourceChunkKey":key,
				"score":best_score, "familyCounts":family_counts,
				"treeSourceIds":tree_source_ids, "staticSourceIds":static_source_ids,
				"actorIntentCount":actor_count,
				"actorIntentIds":_sample_actor_intent_ids(state.get("actorIntents", []))}
		if static_count > 0 and tree_count > 0 \
				and has_actor:
			return key
		if _search_count % 8 == 0:
			_write_progress("searching_real_seeded_source_chunks", {
				"searchedChunkCount":_search_count, "latestChunk":key,
				"staticRows":static_count,
				"actorIntents":actor_count,
				"candidateDiagnostics":_search_diagnostics})
	return null


func _sample_actor_intent_ids(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if not value is Array:
		return result
	for intent_value: Variant in value:
		if not intent_value is Dictionary:
			continue
		if result.size() >= 3:
			break
		result.append(String(intent_value.get("sourceId", intent_value.get("propId", ""))))
	return result


func _candidate_source_chunk_keys() -> Array[Vector2i]:
	var candidates: Array[Vector2i] = []
	for radius in range(4, 13):
		for x in range(-radius, radius + 1):
			candidates.append(Vector2i(x, -radius))
			candidates.append(Vector2i(x, radius))
		for z in range(-radius + 1, radius):
			candidates.append(Vector2i(-radius, z))
			candidates.append(Vector2i(radius, z))
		if candidates.size() >= MAX_CANDIDATE_CHUNKS:
			break
	candidates.resize(mini(candidates.size(), MAX_CANDIDATE_CHUNKS))
	return candidates


func _finalize_seeded_town_inputs_for_candidates(artifact: Dictionary) -> Dictionary:
	if not main.has_method("town_region") \
			or not main.has_method("finalize_production_town_inputs_for_loading"):
		return {"status":"failed", "reason":"production_town_input_authority_missing"}
	var chunk_cells := int(main.get("CHUNK_SIZE"))
	var town_region_cells := int(main.get("TOWN_REGION_CELLS"))
	if chunk_cells <= 0 or town_region_cells <= 0:
		return {"status":"failed", "reason":"production_town_grid_dimensions_invalid",
			"chunkCells":chunk_cells, "townRegionCells":town_region_cells}
	var catalog_inputs: Dictionary = artifact.get("catalogInputs", {})
	var tree_envelope: Dictionary = catalog_inputs.get("treeProducerEnvelope", {})
	var profiles: Array = catalog_inputs.get("biomeProfileSnapshot", {}).get("profiles", [])
	var max_trunk_radius := float(tree_envelope.get("maxTrunkRadiusMeters", NAN))
	var max_canopy_radius := float(tree_envelope.get("maxCanopyRadiusMeters", NAN))
	if String(tree_envelope.get("status", "")) != "ready" \
			or not is_finite(max_trunk_radius) or max_trunk_radius <= 0.0 \
			or not is_finite(max_canopy_radius) or max_canopy_radius <= 0.0:
		return {"status":"failed", "reason":"production_tree_request_envelope_invalid"}
	var max_exclusion := 0.0
	for profile_value: Variant in profiles:
		if not profile_value is Dictionary:
			return {"status":"failed", "reason":"production_biome_profile_invalid"}
		var encoded: Variant = profile_value.get("natural_prop_exclusion_margin", null)
		if not encoded is Dictionary:
			return {"status":"failed", "reason":"production_exclusion_margin_missing"}
		var margin_value: Variant = encoded.get("value", null)
		if not (margin_value is float or margin_value is int) \
				or not is_finite(float(margin_value)) or float(margin_value) < 0.0:
			return {"status":"failed", "reason":"production_exclusion_margin_invalid"}
		max_exclusion = maxf(max_exclusion, float(margin_value))
	var cell_size := float(main.get("CELL"))
	if cell_size <= 0.0 or not is_finite(cell_size):
		return {"status":"failed", "reason":"production_cell_size_invalid"}
	var natural_margin_cells := ceili((max_trunk_radius + max_exclusion) / cell_size)
	var structure_margin_cells := ceili((max_canopy_radius + max_exclusion) / cell_size)
	var coverage_margin := maxi(natural_margin_cells, structure_margin_cells)
	var queried_regions := 0
	var required_regions: Dictionary = {}
	for source_key: Vector2i in _candidate_source_chunk_keys():
		var source_bounds := Rect2i(source_key * chunk_cells, Vector2i.ONE * chunk_cells)
		var coverage := source_bounds.grow(coverage_margin)
		var low := Vector2i(floori(float(coverage.position.x) / town_region_cells),
			floori(float(coverage.position.y) / town_region_cells)) - Vector2i.ONE
		var high := Vector2i(floori(float(coverage.end.x - 1) / town_region_cells),
			floori(float(coverage.end.y - 1) / town_region_cells)) + Vector2i.ONE
		for region_z in range(low.y, high.y + 1):
			for region_x in range(low.x, high.x + 1):
				required_regions[Vector2i(region_x, region_z)] = true
	var sorted_regions: Array[Vector2i] = []
	for region_value: Variant in required_regions.keys():
		if region_value is Vector2i:
			sorted_regions.append(region_value)
	sorted_regions.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x if a.x != b.x else a.y < b.y)
	for region: Vector2i in sorted_regions:
		var town_value: Variant = main.call("town_region", region.x, region.y)
		if not town_value is Dictionary:
			return {"status":"failed", "reason":"production_town_region_invalid",
				"region":region}
		queried_regions += 1
	var finalized_value: Variant = main.call("finalize_production_town_inputs_for_loading")
	if not finalized_value is Dictionary:
		return {"status":"failed", "reason":"production_town_finalization_result_invalid"}
	var finalized: Dictionary = finalized_value
	if String(finalized.get("status", "")) != "ready":
		return {"status":"failed", "reason":String(finalized.get("reason",
			"production_town_finalization_failed")),
			"queriedRegions":queried_regions}
	var admission_value: Variant = main.get("structure_system").get(
		"citadel_terrain_admission")
	if admission_value == null or not admission_value.has_method(
			"finalized_town_inputs_snapshot"):
		return {"status":"failed", "reason":"finalized_town_admission_snapshot_unavailable"}
	var admission_snapshot: Dictionary = admission_value.call("finalized_town_inputs_snapshot")
	if String(admission_snapshot.get("status", "")) != "ready":
		return {"status":"failed", "reason":String(admission_snapshot.get("reason",
			"finalized_town_admission_snapshot_failed")),
			"queriedRegions":queried_regions}
	var town_cache_value: Variant = main.get("town_region_cache")
	var town_cache: Dictionary = town_cache_value if town_cache_value is Dictionary else {}
	var missing_cached_regions: Array[Vector2i] = []
	for region: Vector2i in sorted_regions:
		if not town_cache.has(region):
			missing_cached_regions.append(region)
	if not missing_cached_regions.is_empty():
		return {"status":"failed", "reason":"production_town_region_cache_incomplete",
			"missingRegions":missing_cached_regions.slice(0, 5),
			"requiredRegionCount":sorted_regions.size(),
			"cachedTownRegions":town_cache.size()}
	return {"status":"ready", "queriedRegions":queried_regions,
		"candidateSourceChunkCount":_candidate_source_chunk_keys().size(),
		"requiredTownRegionCount":sorted_regions.size(),
		"requiredInfluenceMarginCells":coverage_margin,
		"naturalMarginCells":natural_margin_cells,
		"structureMarginCells":structure_margin_cells,
		"townRegionCells":town_region_cells,
		"cachedTownRegions":town_cache.size(),
		"finalizedTownCount":(finalized.get("towns", {}) as Dictionary).size(),
		"admissionGeneration":admission_snapshot.get("generation", -1)}


func _prepared_source_inputs(world_id: String, key: Vector2i,
		artifact: Dictionary) -> Dictionary:
	var source_inputs: Dictionary = main.call("_ecology_source_capture_inputs",
		world_id, key, seed_text, {}, artifact)
	if String(source_inputs.get("_captureStatus", "")) != "":
		return {"status":String(source_inputs.get("_captureStatus", "pending")),
			"reason":String(source_inputs.get("_captureReason", "source_input_not_ready")),
			"sourceChunkKey":key,
			"structureDependencyStatus":source_inputs.get("structureDependencyStatus", "")}
	if String(source_inputs.get("schema", "")) != "ecology-source-domain-inputs/v2":
		return {"status":"failed", "reason":"source_inputs_not_canonical_v2",
			"sourceChunkKey":key}
	return {"status":"ready", "sourceInputs":source_inputs}


func _new_pass_state(world_id: String, key: Vector2i, prepared: Dictionary,
		artifact: Dictionary, removed_snapshot: Dictionary) -> Dictionary:
	var source_inputs: Dictionary = prepared.get("sourceInputs", {})
	var projection: Dictionary = main.call("_removed_props_projection_for_source_chunk",
		key, removed_snapshot)
	var removed_ids: Array = projection.get("removedIds", [])
	var removed_digest := ProducerDomain.digest_value(removed_ids)
	var policy: Dictionary = ProducerDomain.support_policy(source_inputs, artifact)
	var state: Dictionary = main.call("begin_chunk_prop_spawn_state", null, key.x, key.y)
	state["sourceCaptureMode"] = true
	state["sourceWorldId"] = world_id
	state["sourceWorldSeed"] = seed_text
	state["sourceInputs"] = source_inputs
	state["catalogInputs"] = artifact.get("catalogInputs", {})
	state["animatedAssetOwnerReceipt"] = main.call(
		"_ecology_catalog_owner_receipt", artifact, "animated_assets")
	state["visualAssetOwnerReceipt"] = main.call(
		"_ecology_catalog_owner_receipt", artifact, "visual_assets")
	state["sourceDomainRevision"] = ProducerDomain.source_domain_revision(
		world_id, seed_text, key, source_inputs, removed_digest, artifact)
	state["influencePolicyRevision"] = String(policy.get("revision", ""))
	state["influencePolicyDigest"] = String(policy.get("digest", ""))
	state["supportPolicy"] = policy
	state["removedSourceProjectionDigest"] = removed_digest
	state["removedSourceIds"] = removed_ids.duplicate()
	state["sourceRows"] = []
	state["actorIntents"] = []
	state["sourceFamilyFailures"] = {}
	state["completedSourceCategories"] = []
	state["requestedSourceFamilies"] = ProducerDomain.REQUIRED_CATEGORIES.duplicate()
	state["structureAdmissionStatus"] = String(source_inputs.get(
		"structureAdmissionStatus", "pending"))
	return state


func _run_complete_pass(world_id: String, key: Vector2i, prepared: Dictionary,
		artifact: Dictionary, attempt_budget: int) -> Dictionary:
	var removed_snapshot: Dictionary = ActiveRemovedProps.capture(main)
	var state := _new_pass_state(world_id, key, prepared, artifact, removed_snapshot)
	var calls := 0
	var complete := false
	while calls < MAX_PASS_CALLS:
		calls += 1
		complete = bool(main.call("process_chunk_prop_spawn_state", state,
			attempt_budget, attempt_budget, -1.0, 0))
		if not (state.get("sourceFamilyFailures", {}) as Dictionary).is_empty():
			return {"status":"failed", "reason":"source_family_capture_failed",
				"familyFailures":state.sourceFamilyFailures, "callCount":calls,
				"sourceChunkKey":key}
		if not String(state.get("sourceCaptureFailure", "")).is_empty():
			return {"status":"failed", "reason":String(state.sourceCaptureFailure),
				"failureDetails":state.get("sourceCaptureFailureDetails", {}),
				"callCount":calls, "sourceChunkKey":key,
				"progress":main.call("_ecology_source_pass_progress", state)}
		if complete:
			break
		if calls % PROGRESS_INTERVAL_CALLS == 0:
			_write_progress("running_%d_attempt_budget_pass" % attempt_budget, {
				"sourceChunkKey":key, "callCount":calls,
				"progress":main.call("_ecology_source_pass_progress", state)})
	if not complete or not bool(state.get("sourcePassComplete", false)):
		return {"status":"pending", "reason":"source_pass_call_bound_reached",
			"callCount":calls, "sourceChunkKey":key,
			"progress":main.call("_ecology_source_pass_progress", state)}
	var rng: RandomNumberGenerator = state.get("rng") as RandomNumberGenerator
	var detail_rng: RandomNumberGenerator = state.get("detailRng") as RandomNumberGenerator
	var underground_rng: RandomNumberGenerator = state.get("undergroundRng") as RandomNumberGenerator
	var snapshot: Dictionary = ProducerDomain.seal_source_domain_snapshot({
		"worldId":world_id, "worldSeed":seed_text, "sourceChunkKey":key,
		"sourceInputs":prepared.get("sourceInputs", {}),
		"sourceRows":state.get("sourceRows", []),
		"actorIntents":state.get("actorIntents", []),
		"categoriesComplete":state.get("completedSourceCategories", []),
		"producerComplete":true, "producerStatus":"ready",
		"removedSourceProjectionDigest":String(state.get(
			"removedSourceProjectionDigest", "")),
		"removedSourceIds":state.get("removedSourceIds", [])
	}, artifact)
	var snapshot_status := String(snapshot.get("status", "failed"))
	var source_manifest_digest := String(snapshot.get("sourceManifestDigest", ""))
	var actor_intent_digest := String(snapshot.get("actorIntentDigest", ""))
	var source_count := int(snapshot.get("enumeratedSourceCount", -1))
	var actor_intent_count := (snapshot.get("actorIntents", []) as Array).size()
	if snapshot_status != "ready" or source_manifest_digest.length() != 64 \
			or actor_intent_digest.length() != 64 or source_count <= 0 \
			or actor_intent_count <= 0:
		return {"status":snapshot_status if snapshot_status in ["pending", "failed"] \
			else "failed", "reason":String(snapshot.get("reason",
				"source_snapshot_not_complete")), "snapshotStatus":snapshot_status,
			"sourceManifestDigest":source_manifest_digest,
			"actorIntentDigest":actor_intent_digest, "sourceCount":source_count,
			"actorIntentCount":actor_intent_count, "callCount":calls,
			"sourceChunkKey":key, "staticFamilies":_static_families(
				snapshot.get("sourceRows", []))}
	return {"status":"ready", "snapshotStatus":snapshot_status,
		"sourceRows":snapshot.get("sourceRows", []),
		"actorIntents":snapshot.get("actorIntents", []),
		"snapshotReason":String(snapshot.get("reason", "")),
		"sourceManifestDigest":source_manifest_digest,
		"actorIntentDigest":actor_intent_digest,
		"sourceCount":source_count,
		"actorIntentCount":actor_intent_count,
		"staticFamilies":_static_families(snapshot.get("sourceRows", [])),
		"finalRngState":{"surface":rng.state if is_instance_valid(rng) else -1,
			"details":detail_rng.state if is_instance_valid(detail_rng) else -1,
			"underground":underground_rng.state if is_instance_valid(underground_rng) else -1},
		"callCount":calls}


func _static_families(rows_value: Variant) -> Array[String]:
	var result: Array[String] = []
	if not rows_value is Array: return result
	for row_value: Variant in rows_value:
		if not row_value is Dictionary: continue
		var family := String(row_value.get("producerFamily", ""))
		if family in REQUIRED_STATIC_FAMILIES and not result.has(family): result.append(family)
	result.sort()
	return result


func _record(name: String, passed: bool, details: Dictionary) -> void:
	checks.append({"name":name, "passed":passed, "details":details})
	_write_progress("checking", {"check":name, "passed":passed,
		"checkCount":checks.size(), "searchedChunkCount":_search_count})


func _all_checks_passed() -> bool:
	for row: Dictionary in checks:
		if not bool(row.get("passed", false)): return false
	return not checks.is_empty()


func _write_progress(stage: String, details: Dictionary) -> void:
	if progress_path.is_empty(): return
	var value := {"schema":"ecology-source-pass-slicing-progress/v1",
		"stage":stage, "elapsedUsec":Time.get_ticks_usec() - started_usec,
		"searchedChunkCount":_search_count, "details":details}
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file == null: return
	file.store_string(JSON.stringify(value, "\t"))
	file.flush()


func _finish(reason: String) -> void:
	if is_instance_valid(main): main.free()
	var passed := _all_checks_passed()
	var report := {"schema":REPORT_SCHEMA, "passed":passed,
		"evidenceLevel":"real_main_production_source_pass_service_parity",
		"gameplayAcceptance":false, "seed":seed_text,
		"reason":reason, "checks":checks, "checkCount":checks.size(),
		"elapsedUsec":Time.get_ticks_usec() - started_usec,
		"doesNotProve":["gameplay startup or rendering", "collision or traversal",
			"section installation", "performance"]}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.flush()
	quit(0 if passed else 1)
