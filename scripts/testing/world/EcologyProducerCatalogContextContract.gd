extends SceneTree
## Synthetic value/scope contract; does not run Main or prove gameplay.

const Context := preload("res://scripts/world/EcologyProducerCatalogContext.gd")
const Domain := preload("res://scripts/world/EcologyProducerDomain.gd")
var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var values := {"revision":7, "profiles":[{"density":0.5, "family":"oak"}],
		"bounds":AABB(Vector3.ZERO, Vector3.ONE)}
	var created := Context.create("world-a", "seed-a", values)
	_check("create_accepts_owned_values", created.get("status") == "ready")
	if created.get("status") != "ready":
		_finish()
		return
	var captured: Dictionary = created.context
	_check("create_does_not_freeze_caller_containers", not values.is_read_only() \
		and not values.profiles.is_read_only() and not values.profiles[0].is_read_only())
	values.profiles[0].density = 0.75
	values.profiles.append({"density":0.25, "family":"pine"})
	_check("captured_nested_values_are_owned_and_immutable", captured.is_read_only() \
		and captured.catalogInputs.is_read_only() and captured.catalogInputs.profiles.is_read_only() \
		and captured.catalogInputs.profiles[0].is_read_only() \
		and captured.catalogInputs.profiles.size() == 1 \
		and captured.catalogInputs.profiles[0].density == 0.5)
	var manager := Context.new()
	var outer := manager.begin_scope(captured)
	var nested := manager.begin_scope(captured)
	_check("nested_scope_retains_one_context_with_distinct_tokens", outer.get("status") == "ready" \
		and nested.get("status") == "ready" and outer.scopeId == nested.scopeId \
		and outer.tokenId != nested.tokenId and manager.scope_depth() == 2)
	_check("out_of_order_end_does_not_release_context", manager.end_scope(outer).get("status") == "failed" \
		and manager.scope_depth() == 2)
	_check("world_and_seed_are_required", manager.context_for("world-b", "seed-a").get("status") == "failed" \
		and manager.context_for("world-a", "seed-b").get("status") == "failed" \
		and manager.context_for("world-a", "seed-a").get("status") == "ready")
	var changed := Context.create("world-a", "seed-a", values)
	_check("same_revision_changed_values_have_new_digest", changed.get("status") == "ready" \
		and changed.catalogContextDigest != created.catalogContextDigest \
		and changed.context.catalogInputs.revision == captured.catalogInputs.revision)
	_check("changed_nested_context_rejected", manager.begin_scope(changed.context).get("status") == "failed" \
		and manager.scope_depth() == 2)
	_check("nested_end_keeps_outer_context", manager.end_scope(nested).get("status") == "ready" \
		and manager.scope_depth() == 1)
	var next_nested := manager.begin_scope(captured)
	_check("ended_token_cannot_close_later_same_depth_scope", manager.end_scope(nested).get("status") == "failed" \
		and manager.scope_depth() == 2 and next_nested.tokenId != nested.tokenId)
	manager.end_scope(next_nested)
	_check("outer_end_clears_context", manager.end_scope(outer).get("status") == "ready" \
		and manager.scope_depth() == 0 and manager.context_for("world-a", "seed-a").get("status") == "absent")
	var replacement := manager.begin_scope(changed.context)
	_check("next_scope_observes_changed_values", replacement.get("status") == "ready" \
		and manager.context_for("world-a", "seed-a").context.catalogInputs.profiles[0].density == 0.75 \
		and manager.end_scope(outer).get("status") == "failed")
	manager.end_scope(replacement)
	var early_result := _scoped_pending(manager, captured)
	_check("pending_operation_releases_scope", early_result.get("status") == "pending" \
		and manager.scope_depth() == 0)
	var forged: Dictionary = captured.duplicate(true)
	forged.catalogInputs.profiles[0].density = 0.9
	_check("declared_digest_cannot_hide_modified_values", manager.begin_scope(forged).get("reason") \
		== "ecology_catalog_context_content_digest_mismatch" and manager.scope_depth() == 0)
	var owner := Node.new()
	var resource := BoxMesh.new()
	for unsafe: Variant in [owner, resource, weakref(owner), Callable(self, "_finish"), RID()]:
		_check("rejects_reference_type_%s" % type_string(typeof(unsafe)) + str(checks.size()),
			Context.create("world-a", "seed-a", {"nested":[{"unsafe":unsafe}]}).get("status") == "failed")
	owner.free()
	_check("rejects_nonfinite_values", Context.create("world-a", "seed-a", {"value":NAN}).get("status") == "failed")
	var policy_inputs := {"producerCatalogRevision":"unchanged",
		"biomeProfileSnapshot":{"profiles":[{"density":0.5}]}}
	var policy_digest := Domain.support_policy_context_digest(policy_inputs)
	policy_inputs["supportPolicyContextDigest"] = policy_digest
	policy_inputs.biomeProfileSnapshot.profiles[0].density = 0.75
	var changed_policy_digest := Domain.support_policy_context_digest(policy_inputs)
	_check("policy_digest_uses_values_despite_unchanged_revision_or_declared_digest",
		changed_policy_digest != policy_digest \
		and Domain.support_policy(policy_inputs).get("runtimePolicyReason") == "ecology_support_policy_context_digest_mismatch")
	policy_inputs["supportPolicyContextDigest"] = "arbitrary"
	_check("supplied_policy_digest_does_not_define_cache_identity",
		Domain.support_policy_context_digest(policy_inputs) == changed_policy_digest)
	_finish()


func _scoped_pending(manager, context: Dictionary) -> Dictionary:
	var token: Dictionary = manager.begin_scope(context)
	if token.get("status") != "ready": return token
	var operation := {"status":"pending", "reason":"synthetic_dependency"}
	var ended: Dictionary = manager.end_scope(token)
	return operation if ended.get("status") == "ready" else ended


func _check(name: String, passed: bool) -> void:
	checks[name] = passed


func _finish() -> void:
	var report := {"schema":"ecology-producer-catalog-context-contract/v1",
		"passed":not checks.values().has(false), "checks":checks, "checkCount":checks.size(),
		"evidenceLevel":"synthetic_catalog_value_and_scope_lifecycle_contract",
		"doesNotProve":"Main catalog capture cost, live source publication, renderer installation, gameplay or performance."}
	var file := FileAccess.open(OS.get_environment("ECOLOGY_PRODUCER_CATALOG_CONTEXT_REPORT"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	print("ECOLOGY PRODUCER CATALOG CONTEXT ", JSON.stringify(report))
	quit(0 if report.passed else 1)
