extends SceneTree
## Synthetic source-family/queue boundary; no live generation or rendering claim.

const Domain := preload("res://scripts/world/EcologyProducerDomain.gd")
const Queue := preload("res://scripts/environment/TreePublicationQueue.gd")
const Compiler := preload("res://scripts/world/TreeRecipeSectionCompiler.gd")
const AdapterFixture := preload("res://scripts/testing/world/EcologySectionValueAdapterContract.gd")

class Authority extends AdapterFixture.ProductionAuthority:
	var currentness_calls := 0
	var stale_reason := ""
	func ecology_source_publication_local_is_current(view: Dictionary, token: String) -> Dictionary:
		currentness_calls += 1
		var current: Dictionary = super.ecology_source_publication_local_is_current(view, token)
		if current.get("status") != "ready": return current
		return {"status":"ready"} if stale_reason.is_empty() else {
			"status":"failed", "reason":stale_reason}

var checks: Dictionary = {}
var bundle_catalog_tokens: Dictionary = {}

func _init() -> void:
	call_deferred("_run")

func _bundle(authority: Authority, families: Array, completed: Array) -> Dictionary:
	var world_id := "synthetic-tree-family-world"
	var chunk := Vector2i(2, -3)
	var inputs: Dictionary = authority._canonical_fixture_inputs(world_id, chunk,
		authority.seed_text, {})
	var artifact: Dictionary = authority._fixture_artifact_for(inputs)
	var lease := authority.acquire_ecology_catalog_artifact_lease(String(inputs.get("catalogArtifactId", "")),
		"synthetic_tree_family", str(families), world_id, authority.ecology_world_epoch)
	var token := String(lease.get("leaseToken", ""))
	var removal_digest := Domain.digest_value([])
	var request := Domain.build_source_family_request(families, world_id,
		authority.seed_text, chunk, inputs, removal_digest, artifact, token)
	var bundle := Domain.seal_source_domain_family_bundle({
		"worldId":world_id, "worldSeed":authority.seed_text, "sourceChunkKey":chunk,
		"sourceInputs":inputs, "removedSourceProjectionDigest":removal_digest,
		"catalogLeaseToken":token, "familyRequest":request, "sourceRows":[],
		"actorIntentSnapshot":[], "completedFamilies":completed}, artifact)
	bundle_catalog_tokens[Domain.digest_value(bundle)] = token
	return bundle

func _run() -> void:
	var authority := Authority.new()
	root.add_child(authority)
	var queue := Queue.new()
	authority.add_child(queue)
	queue.set_process(false)
	var details := _bundle(authority, ["details"], ["details"])
	var details_request: Dictionary = queue.request_ecology_tree_source_compile(authority, details, "details")
	checks["details_only_does_not_prove_empty_trees"] = details_request.get("status") != "ready" \
		and queue.ecology_source_compile_jobs.is_empty()
	var trees := _bundle(authority, ["trees"], ["trees"])
	var tree_result := Domain.source_family_result(trees, "trees", authority._fixture_artifact_for(trees.get("sourceInputs", {})))
	checks["explicit_tree_empty_is_complete"] = tree_result.get("status") == "ready" \
		and tree_result.get("disposition") == "complete_empty"
	var first: Dictionary = queue.request_ecology_tree_source_compile(authority, trees, "first")
	checks["empty_tree_job_admitted"] = first.get("status") == "ready"
	var key := String(first.get("jobKey", ""))
	var retained_view: Dictionary = queue.ecology_source_compile_jobs.get(key, {}).get("publicationView", {})
	checks["queue_retains_exact_publication_payload"] = is_same(retained_view.get("payload", {}), trees)
	var alias_reuse: Dictionary = queue.request_ecology_tree_source_compile(authority, trees, "alias-reuse", retained_view)
	checks["admitted_publication_view_reuses_same_job"] = alias_reuse.get("status") == "ready" \
		and alias_reuse.get("jobKey") == key
	queue.cancel_ecology_tree_source_compile(key, "alias-reuse")
	var copied_payload: Dictionary = Domain.freeze_value(trees.duplicate(true))
	checks["detached_equal_payload_cannot_impersonate_publication"] = queue.request_ecology_tree_source_compile(
		authority, copied_payload, "detached", retained_view).get("reason") == "ecology_source_publication_payload_alias_mismatch"
	var polled: Dictionary = queue.poll_ecology_tree_source_compile(key, "first")
	checks["empty_tree_job_polls_current_authority"] = polled.get("status") == "ready" \
		and authority.currentness_calls >= 2
	var artifact: Dictionary = polled.get("artifact", {})
	checks["empty_artifact_binds_family_manifest"] = artifact.get("treeFamilyRevision") \
		== tree_result.get("familyRevision") and artifact.get("treeFamilyManifestDigest") \
		== tree_result.get("sourceManifestDigest") and artifact.get("sources", []).is_empty()
	for reason: String in ["synthetic_catalog_replaced", "synthetic_removal_changed", "synthetic_source_revision_changed"]:
		authority.stale_reason = reason
		var stale: Dictionary = queue.poll_ecology_tree_source_compile(key, "first")
		checks["empty_rejects_" + reason] = stale.get("status") == "failed" and stale.get("reason") == reason
	authority.stale_reason = ""
	var second: Dictionary = queue.request_ecology_tree_source_compile(authority, trees, "second")
	queue.cancel_ecology_tree_source_compile(key, "first")
	checks["shared_empty_job_retains_remaining_subscriber"] = second.get("jobKey") == key \
		and queue.ecology_source_compile_jobs.get(key, {}).get("consumers", {}).has("second") \
		and queue.poll_ecology_tree_source_compile(key, "second").get("status") == "ready"
	var wider_pending := _bundle(authority, ["trees", "details"], ["trees"])
	checks["incomplete_wider_bundle_not_admitted"] = queue.request_ecology_tree_source_compile(
		authority, wider_pending, "wide-pending").get("status") != "ready"
	var wider := _bundle(authority, ["trees", "details"], ["trees", "details"])
	var wider_request: Dictionary = queue.request_ecology_tree_source_compile(authority, wider, "wide")
	checks["complete_wider_bundle_shares_tree_job"] = wider_request.get("status") == "ready" \
		and wider_request.get("jobKey") == key
	checks["wider_request_preserves_tree_family_identity"] = Domain.source_family_result(wider,
		"trees", authority._fixture_artifact_for(wider.get("sourceInputs", {}))).get("familyRevision") == tree_result.get("familyRevision")
	var tampered: Dictionary = trees.duplicate(true)
	tampered["sourceManifestDigest"] = "0".repeat(64)
	tampered = Domain.freeze_value(tampered)
	checks["manifest_tamper_not_admitted"] = queue.request_ecology_tree_source_compile(
		authority, tampered, "tampered").get("status") != "ready"
	var compiler := Compiler.new()
	var direct: Dictionary = compiler.begin_from_source_records(authority,
		String(details.get("worldId", "")), queue, [{}], details)
	checks["direct_compiler_requires_tree_coverage"] = direct.get("reason") == "tree_source_family_coverage_incomplete"
	authority.release_ecology_catalog_artifact_lease(String(bundle_catalog_tokens.get(Domain.digest_value(trees), "")))
	queue.cancel_ecology_tree_source_compile(key, "second")
	checks["wider_subscriber_survives_first_capture_lease_release"] = queue.poll_ecology_tree_source_compile(key, "wide").get("status") == "ready"
	var job_token := String(queue.ecology_source_compile_jobs.get(key, {}).get("publicationLeaseToken", ""))
	var replacement := Authority.new()
	root.add_child(replacement)
	queue.reparent(replacement)
	var replacement_bundle := _bundle(replacement, ["trees"], ["trees"])
	var replacement_request: Dictionary = queue.request_ecology_tree_source_compile(replacement, replacement_bundle, "replacement")
	checks["replacement_owner_gets_separate_current_job"] = replacement_request.get("status") == "ready" \
		and replacement_request.get("jobKey") != key \
		and queue.poll_ecology_tree_source_compile(String(replacement_request.get("jobKey", "")), "replacement").get("status") == "ready"
	checks["old_owner_job_cannot_poll_after_reparent"] = queue.poll_ecology_tree_source_compile(key, "wide").get("reason") \
		== "ecology_source_compile_owner_replaced"
	queue.cancel_ecology_tree_source_compile(key, "wide")
	checks["last_subscriber_release_retires_job_lease"] = not queue.ecology_source_compile_jobs.has(key) \
		and authority.resolve_ecology_source_publication(job_token, String(trees.get("worldId", "")),
			int(trees.get("worldEpoch", -1))).get("status") != "ready"
	var replacement_token := String(queue.ecology_source_compile_jobs.get(String(replacement_request.get("jobKey", "")), {}).get("publicationLeaseToken", ""))
	queue.reset_ecology_source_compilers()
	checks["reset_drains_completed_job_and_lease"] = queue.ecology_source_compile_jobs.is_empty() \
		and replacement.resolve_ecology_source_publication(replacement_token, String(replacement_bundle.get("worldId", "")),
			int(replacement_bundle.get("worldEpoch", -1))).get("status") != "ready"
	var passed := true
	for value: Variant in checks.values():
		passed = passed and value == true
	var report_path := OS.get_environment("VOXEL_TREE_SOURCE_FAMILY_REPORT")
	if report_path.is_empty():
		report_path = "res://artifacts/tree-source-family-coverage-contract.json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(report_path).get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"schema":"tree-source-family-coverage-contract/v1",
			"passed":passed, "checks":checks,
			"evidenceLevel":"synthetic_tree_family_admission_and_empty_currentness_contract",
			"scope":"Real queue/compiler admission with sealed synthetic empty source bundles and mocked domain currentness; no nonempty mesh, live generation, renderer or gameplay proof."}, "  "))
		file.close()
	authority.free()
	replacement.free()
	quit(0 if passed and file != null else 1)
