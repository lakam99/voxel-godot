extends SceneTree
## Synthetic Main-owned capture-session lifecycle contract; not gameplay evidence.

const MainCapture := preload("res://scripts/MainPlaytestTools.gd")
const CatalogContext := preload("res://scripts/world/EcologyProducerCatalogContext.gd")
const ProducerDomain := preload("res://scripts/world/EcologyProducerDomain.gd")
const BiomeCatalog := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const BiomeSnapshot := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")

class FakeWorldCoordinator:
	extends RefCounted
	var identity := ""
	func world_identity() -> String: return identity

class FakeValueRetirementQueue:
	extends RefCounted
	var retired_roots: Array[Dictionary] = []
	var retired_keepalives: Array[RefCounted] = []
	var reject_enqueue := false
	func _queue_tree_value_retirement(roots: Array[Dictionary],
			keepalives: Array[RefCounted] = []) -> bool:
		if reject_enqueue or roots.is_empty(): return false
		for root: Dictionary in roots:
			if not root.is_read_only(): return false
			retired_roots.append(root)
		for keepalive: RefCounted in keepalives:
			retired_keepalives.append(keepalive)
		return true

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main: Object = MainCapture.new()
	main.set("ecology_world_epoch", 19)
	var rng := RandomNumberGenerator.new()
	rng.seed = 8127
	var expected_rng := RandomNumberGenerator.new()
	expected_rng.seed = 8127
	var first_draw := rng.randi()
	var expected_first := expected_rng.randi()
	var expected_next := expected_rng.randi()
	var cache_identity := "synthetic-session-a"
	var world_id := "synthetic-world"
	var seed_text := "synthetic-seed"
	var key := Vector2i(4, -2)
	var state := {"cacheIdentity":cache_identity,
		"sourceDomainRevision":"source-a", "sourceWorldId":world_id,
		"sourceWorldSeed":seed_text, "cx":key.x, "cz":key.y,
		"rng":rng, "phase":"underground_props", "undergroundScanY":17,
		"sourceRows":[], "actorIntents":[]}
	var coordinator := FakeWorldCoordinator.new()
	coordinator.identity = world_id
	main.set("world_static_section_coordinator", coordinator)
	main.set("seed_text", seed_text)
	var catalog := BiomeCatalog.new()
	var catalog_ready: bool = catalog.setup()
	var profiles: Dictionary = BiomeSnapshot.capture(catalog) if catalog_ready else {}
	var tree_envelope := ProducerDomain.derive_tree_grammar_support_envelope(profiles) \
		if not profiles.is_empty() else {}
	var rock_digest := ProducerDomain.digest_value(["session-contract-rock",
		String(profiles.get("contentIdentity", ""))])
	var catalog_values := {"producerCatalogRevision":"session-contract-v1",
		"biomeProfileSnapshot":profiles,
		"treeGrammarEnvelopeDigest":String(tree_envelope.get("digest", "")),
		"rockSupportEnvelope":{"status":"ready",
		"profileCatalogRevision":String(profiles.get("contentIdentity", "")),
		"eligibleAssetSetDigest":rock_digest, "digest":rock_digest,
		"assetSetDigest":rock_digest, "registryRevision":"synthetic-rocks",
		"assetRows":[{"assetId":"synthetic-rock"}],
		"maxHorizontalSupportMeters":2.0, "maxVerticalSupportMeters":2.0}}
	var context: Object = main.get("ecology_producer_catalog_context")
	var session_catalog: Dictionary = context.call("intern_fresh", world_id,
		seed_text, 19, {"owner":"session-fixture"}, catalog_values)
	var session_lease: Dictionary = main.call("acquire_ecology_catalog_artifact_lease",
		String(session_catalog.get("artifactId", "")), "contract", cache_identity,
		world_id, 19) if session_catalog.get("status") == "ready" else {}
	var session_resolution: Dictionary = main.call("resolve_ecology_catalog_artifact",
		String(session_lease.get("leaseToken", "")), world_id, 19)
	var artifact: Dictionary = session_resolution.get("artifact", {})
	var session_owner_lease := String(session_lease.get("leaseToken", ""))
	var created: Dictionary = main.call("_new_ecology_source_capture_session",
		cache_identity, world_id, seed_text, key, "source-a", "removed-a",
		artifact, state, session_owner_lease)
	var sessions: Dictionary = main.get("_ecology_source_capture_sessions")
	var retained: Dictionary = sessions.get(cache_identity, {})
	var retained_state: Dictionary = retained.get("state", {})
	var retained_rng: RandomNumberGenerator = retained_state.get("rng") \
		as RandomNumberGenerator
	_check("session_owns_the_live_pass_state", created.get("cacheIdentity", "") == cache_identity \
		and retained_state == state)
	_check("session_resume_preserves_rng_draw_order", first_draw == expected_first \
		and is_instance_valid(retained_rng) and retained_rng.randi() == expected_next)
	var before_cursor: Dictionary = main.call("_ecology_source_pass_progress", state)
	state["undergroundScanY"] = 16
	var after_cursor: Dictionary = main.call("_ecology_source_pass_progress", state)
	_check("deep_floor_scan_y_is_visible_as_progress", int(before_cursor.get(
		"undergroundScanY", -1)) == 17 and int(after_cursor.get("undergroundScanY", -1)) == 16 \
		and before_cursor != after_cursor)
	_check("budgeted_slice_stays_productive_without_cursor_delta", \
		String(main.call("_ecology_source_capture_disposition", {"naturalPropAdmission":{
		"status":"ready"}})) == "progress")
	_check("external_admission_wait_is_explicitly_blocked", \
		String(main.call("_ecology_source_capture_disposition", {"naturalPropAdmission":{
		"status":"pending"}})) == "dependency_blocked")
	var exact_match: bool = main.call("_ecology_source_capture_session_matches",
		retained, cache_identity, world_id, seed_text, key, "removed-a", artifact,
		session_owner_lease)
	_check("current_session_identity_matches_exact_artifact_and_lease", exact_match)
	_check("wrong_artifact_cannot_resume_or_release_session", not bool(main.call(
		"_ecology_source_capture_session_matches", retained, cache_identity, world_id,
		seed_text, key, "removed-a", {"artifactId":"catalog-other"}, session_owner_lease)) \
		and sessions.has(cache_identity))
	_check("wrong_lease_cannot_resume_or_release_session", not bool(main.call(
		"_ecology_source_capture_session_matches", retained, cache_identity, world_id,
		seed_text, key, "removed-a", artifact, "lease-other")) and sessions.has(cache_identity))
	main.set("ecology_world_epoch", 20)
	_check("wrong_epoch_cannot_resume_session", not bool(main.call(
		"_ecology_source_capture_session_matches", retained, cache_identity, world_id,
		seed_text, key, "removed-a", artifact, "lease-a")) and sessions.has(cache_identity))
	main.set("ecology_world_epoch", 19)
	var diagnostics: Dictionary = main.call("ecology_source_capture_diagnostics_snapshot")
	_check("diagnostics_do_not_expose_mutable_pass_state", diagnostics.get("sessionCount", -1) == 1 \
		and not diagnostics.has("sourceRows") and not diagnostics.has("state"))

	# Exercise stale rejection through the production entry point: a valid source
	# lease refers to artifact A while the active no-yield scope has same-content
	# replacement artifact B. The source cannot resume under B's owner identity.
	var catalog_a: Dictionary = context.call("intern_fresh", world_id, seed_text, 19,
		{"owner":1}, catalog_values)
	var token_a: Dictionary = context.call("acquire_lease",
		String(catalog_a.get("artifactId", "")), "source_job", "stale-source",
		world_id, 19) if catalog_a.get("status") == "ready" else {}
	var catalog_b: Dictionary = context.call("intern_fresh", world_id, seed_text, 19,
		{"owner":2}, catalog_values) if catalog_a.get("status") == "ready" else {}
	var scope_b: Dictionary = context.call("begin_artifact_scope",
		String(catalog_b.get("artifactId", "")), world_id, 19) \
		if catalog_b.get("status") == "ready" else {}
	var token_a_text := String(token_a.get("leaseToken", ""))
	var artifact_a_id := String(catalog_a.get("artifactId", ""))
	var resolved_a: Dictionary = context.call("resolve_leased_artifact", token_a_text,
		world_id, 19) if not token_a_text.is_empty() else {}
	var artifact_a: Dictionary = resolved_a.get("artifact", {})
	var policy_a: Dictionary = artifact_a.get("supportPolicy", {})
	var stale_key := Vector2i(6, -5)
	var stale_identity := "session-contract-stale-v2"
	var stale_state := {"cacheIdentity":stale_identity, "sourceDomainRevision":"source-old",
		"sourceWorldId":world_id, "sourceWorldSeed":seed_text,
		"cx":stale_key.x, "cz":stale_key.y, "sourceRows":[]}
	main.call("_new_ecology_source_capture_session", stale_identity, world_id,
		seed_text, stale_key, "source-old", "removed-old", artifact_a,
		stale_state, token_a_text)
	var stale_inputs := {"schema":"ecology-source-domain-inputs/v2",
		"worldId":world_id, "worldSeed":seed_text, "worldEpoch":19,
		"sourceChunkKey":stale_key, "catalogArtifactId":artifact_a_id,
		"catalogContentDigest":String(catalog_a.get("catalogContentDigest", "")),
		"influencePolicyRevision":String(policy_a.get("revision", "")),
		"influencePolicyDigest":String(policy_a.get("digest", ""))}
	var stale_result: Dictionary = main.call("_capture_ecology_source_domain_impl",
		world_id, stale_key, seed_text, stale_inputs,
		{"ok":true, "scope":"world", "ids":[]}, token_a_text)
	sessions = main.get("_ecology_source_capture_sessions")
	_check("same_content_owner_replacement_stales_live_capture_and_retires_cursor", \
		catalog_a.get("status") == "ready" and catalog_b.get("status") == "ready" \
		and catalog_a.get("catalogContentDigest", "") == catalog_b.get("catalogContentDigest", "") \
		and String(catalog_a.get("artifactId", "")) != String(catalog_b.get("artifactId", "")) \
		and stale_result.get("requiresRecapture", false) \
		and stale_result.get("status", "") == "pending" and not sessions.has(stale_identity))
	if scope_b.get("status") == "ready": context.call("end_scope", scope_b)
	context.call("release_lease", token_a_text)

	# A terminal owner/lease rejection before cache lookup must not retain a task
	# session that no consumer can advance or release through its previous owner.
	var terminal_identity := "synthetic-terminal-session"
	var terminal_key := Vector2i(-3, 8)
	var terminal_state := {"cacheIdentity":terminal_identity,
		"sourceDomainRevision":"source-terminal", "sourceWorldId":world_id,
		"sourceWorldSeed":seed_text, "cx":terminal_key.x, "cz":terminal_key.y,
		"sourceRows":[]}
	main.call("_new_ecology_source_capture_session", terminal_identity,
		world_id, seed_text, terminal_key, "source-terminal", "removed-terminal",
		artifact_a, terminal_state, "invalid-terminal-lease")
	var terminal_result: Dictionary = main.call("_capture_ecology_source_domain_impl",
		world_id, terminal_key, seed_text,
		{"worldId":world_id, "worldSeed":seed_text,
		"catalogArtifactId":"catalog-terminal"},
		{"ok":true, "scope":"world", "ids":[]}, "invalid-terminal-lease")
	sessions = main.get("_ecology_source_capture_sessions")
	_check("terminal_pre_cache_failure_releases_matching_session", \
		terminal_result.get("status", "") == "failed" and not sessions.has(terminal_identity))

	# A published narrow family keeps the existing deterministic pass owner so a
	# later family can attach without a second session/revision or RNG replay.
	var retirement_queue: Object = FakeValueRetirementQueue.new()
	main.set("tree_publication_queue", retirement_queue)
	var invalidation_identity := "backpressured-invalidation-session"
	var invalidation_key := Vector2i(18, -21)
	var invalidation_lease_result: Dictionary = main.call(
		"acquire_ecology_catalog_artifact_lease",
		String(session_catalog.get("artifactId", "")), "source_capture_invalidation",
		invalidation_identity, world_id, 19)
	var invalidation_lease := String(invalidation_lease_result.get("leaseToken", ""))
	var invalidation_state := {"cacheIdentity":invalidation_identity,
		"sourceRows":[{"sourceId":"invalidation-row"}], "actorIntents":[]}
	main.call("_new_ecology_source_capture_session", invalidation_identity, world_id,
		seed_text, invalidation_key, "invalidation-revision", "invalidation-removals",
		artifact, invalidation_state, invalidation_lease)
	retirement_queue.set("reject_enqueue", true)
	var invalidation_pending: Dictionary = main.call(
		"invalidate_ecology_source_capture_chunk", world_id, invalidation_key)
	var invalidation_session_retained: bool = main.get(
		"_ecology_source_capture_sessions").has(invalidation_identity)
	var invalidation_lease_live: Dictionary = main.call("resolve_ecology_catalog_artifact",
		invalidation_lease, world_id, 19)
	retirement_queue.set("reject_enqueue", false)
	var invalidation_retried: Dictionary = main.call(
		"invalidate_ecology_source_capture_chunk", world_id, invalidation_key)
	_check("invalidation_backpressure_retains_session_and_retries_before_authority_change",
		invalidation_pending.get("status", "") == "pending" \
		and int(invalidation_pending.get("removedSessionCount", -1)) == 0 \
		and int(invalidation_pending.get("pendingSessionCount", 0)) == 1 \
		and invalidation_session_retained \
		and String(invalidation_lease_live.get("status", "")) == "ready" \
		and invalidation_retried.get("status", "") == "ready" \
		and int(invalidation_retried.get("removedSessionCount", 0)) == 1 \
		and not main.get("_ecology_source_capture_sessions").has(invalidation_identity))
	main.call("release_ecology_catalog_artifact_lease", invalidation_lease)
	var source_drop_identity := "backpressured-source-drop-session"
	var source_drop_key := Vector2i(-18, 21)
	var source_drop_lease_result: Dictionary = main.call(
		"acquire_ecology_catalog_artifact_lease",
		String(session_catalog.get("artifactId", "")), "source_capture_source_drop",
		source_drop_identity, world_id, 19)
	var source_drop_lease := String(source_drop_lease_result.get("leaseToken", ""))
	main.call("_new_ecology_source_capture_session", source_drop_identity, world_id,
		seed_text, source_drop_key, "source-drop-revision", "source-drop-removals",
		artifact, {"sourceRows":[{"sourceId":"source-drop-row"}]}, source_drop_lease)
	retirement_queue.set("reject_enqueue", true)
	var source_drop_pending: Dictionary = main.call(
		"_drop_ecology_source_capture_sessions_for_source", world_id,
		source_drop_key, String(session_catalog.get("artifactId", "")),
		source_drop_lease, "stale")
	var source_drop_still_owned: bool = main.get(
		"_ecology_source_capture_sessions").has(source_drop_identity)
	retirement_queue.set("reject_enqueue", false)
	var source_drop_retried: Dictionary = main.call(
		"_drop_ecology_source_capture_sessions_for_source", world_id,
		source_drop_key, String(session_catalog.get("artifactId", "")),
		source_drop_lease, "stale")
	_check("source_wide_drop_propagates_pending_and_retries_exact_session",
		source_drop_pending.get("status", "") == "pending" \
		and int(source_drop_pending.get("pendingSessionCount", 0)) == 1 \
		and source_drop_still_owned and source_drop_retried.get("status", "") == "ready" \
		and int(source_drop_retried.get("removedSessionCount", 0)) == 1)
	main.call("release_ecology_catalog_artifact_lease", source_drop_lease)
	var retained_identity := "synthetic-completed-pass-retained"
	var retained_key := Vector2i(-11, 7)
	var retained_lease_result: Dictionary = main.call("acquire_ecology_catalog_artifact_lease",
		String(session_catalog.get("artifactId", "")), "source_capture_family",
		retained_identity, world_id, 19)
	var retained_lease := String(retained_lease_result.get("leaseToken", ""))
	var retained_session_rng := RandomNumberGenerator.new()
	retained_session_rng.seed = 99173
	var retained_session_state := {"cacheIdentity":retained_identity,
		"sourceDomainRevision":"retained-source-revision", "sourceWorldId":world_id,
		"sourceWorldSeed":seed_text, "cx":retained_key.x, "cz":retained_key.y,
		"rng":retained_session_rng, "phase":"underground_props", "propIndex":28,
		"undergroundScanColumn":407, "sourceRows":[{"sourceId":"retained-row"}],
		"actorIntents":[{"actorId":"retained-actor"}],
		"completedSourceCategories":["trees", "surface_rocks", "ore", "forage",
			"details", "underground_props"],
		"requestedSourceFamilies":["surface_rocks"]}
	var retained_created: Dictionary = main.call("_new_ecology_source_capture_session",
		retained_identity, world_id, seed_text, retained_key,
		"retained-source-revision", "removed-a", artifact,
		retained_session_state, retained_lease)
	var retained_session: Dictionary = sessions.get(retained_identity, {})
	retained_session["publishedSourceFamilies"] = ["surface_rocks"]
	sessions[retained_identity] = retained_session
	var pass_retained: bool = main.call("_retain_completed_ecology_source_capture_pass",
		retained_identity, retained_session)
	var first_rng_state: int = retained_session_rng.state
	var first_rows: Array = retained_session_state.get("sourceRows", [])
	var detached: Dictionary = main.call("cancel_ecology_source_domain_capture",
		retained_identity, retained_lease)
	var later_lease_result: Dictionary = main.call("acquire_ecology_catalog_artifact_lease",
		String(session_catalog.get("artifactId", "")), "source_capture_family",
		retained_identity + "|details", world_id, 19)
	var later_lease := String(later_lease_result.get("leaseToken", ""))
	var retained_now: Dictionary = sessions.get(retained_identity, {})
	var retained_now_state: Dictionary = retained_now.get("state", {})
	var late_match: bool = main.call("_ecology_source_capture_session_matches",
		retained_now, retained_identity, world_id, seed_text, retained_key,
		"removed-a", artifact, later_lease)
	main.call("_retain_ecology_source_capture_subscriber", retained_now, later_lease)
	var late_families: Array[String] = main.call(
		"_merge_ecology_source_capture_family_union", retained_now_state, ["details"])
	sessions[retained_identity] = retained_now
	_check("late_distinct_family_reuses_retained_source_pass_without_replay",
		retained_created.get("cacheIdentity", "") == retained_identity \
		and pass_retained and detached.get("status", "") == "retained" \
		and late_match and retained_now_state == retained_session_state \
		and late_families == ["details", "surface_rocks"] \
		and retained_now.get("sourceDomainRevision", "") == "retained-source-revision" \
		and int(retained_now.get("sliceCount", 0)) == 0 \
		and retained_session_rng.state == first_rng_state and is_same(first_rows,
			retained_now_state.get("sourceRows", [])) \
		and int(retained_now_state.get("undergroundScanColumn", -1)) == 407)
	var full_family_pass: Dictionary = _run_seeded_family_pass(main, 23, -9, false)
	var late_family_pass: Dictionary = _run_seeded_family_pass(main, 23, -9, true)
	_check("same_seed_late_family_matches_full_family_pass",
		full_family_pass.get("status", "") == "ready" \
		and late_family_pass.get("status", "") == "ready" \
		and full_family_pass.get("requestedFamilies", []) == ["details", "surface_rocks"] \
		and late_family_pass.get("requestedFamilies", []) == ["details", "surface_rocks"] \
		and not bool(full_family_pass.get("detailsAdmittedLate", true)) \
		and bool(late_family_pass.get("detailsAdmittedLate", false)) \
		and int(late_family_pass.get("surfaceCursorAtLateAdmission", -1)) == 5 \
		and (full_family_pass.get("sourceRows", []) as Array).size() == 9 \
		and full_family_pass.get("sourceRows", []) == late_family_pass.get("sourceRows", []) \
		and full_family_pass.get("surfaceRngState", 0) ==
			late_family_pass.get("surfaceRngState", -1) \
		and full_family_pass.get("detailRngState", 0) ==
			late_family_pass.get("detailRngState", -1) \
		and full_family_pass.get("surfaceCursor", -1) ==
			late_family_pass.get("surfaceCursor", -2) \
		and full_family_pass.get("detailCursor", -1) ==
			late_family_pass.get("detailCursor", -2))
	var wrong_removed_match: bool = main.call("_ecology_source_capture_session_matches",
		retained_now, retained_identity, world_id, seed_text, retained_key,
		"changed-removal-digest", artifact, later_lease)
	_check("changed_source_removal_revision_cannot_reuse_retained_pass",
		not wrong_removed_match and sessions.has(retained_identity) \
		and String(retained_now.get("sourceDomainRevision", "")) ==
			"retained-source-revision")
	var retained_diagnostics: Dictionary = main.call(
		"ecology_source_capture_diagnostics_snapshot")
	_check("retained_pass_diagnostics_are_bounded_and_state_free",
		int(retained_diagnostics.get("completedPassCacheCount", 0)) == 1 \
		and int(retained_diagnostics.get("sessionCount", 0)) <= 128 \
		and not retained_diagnostics.has("sourceRows") \
		and not retained_diagnostics.has("state"))
	main.call("release_ecology_catalog_artifact_lease", later_lease)
	main.call("release_ecology_catalog_artifact_lease", retained_lease)

	var cancel_key := Vector2i(10, 11)
	var survivor_key := Vector2i(12, 13)
	for pair: Array in [["cancel-target", cancel_key], ["cancel-survivor", survivor_key]]:
		var pair_key: Vector2i = pair[1]
		var cancel_state := {"cacheIdentity":String(pair[0]),
			"sourceDomainRevision":"source-cancel", "sourceWorldId":world_id,
			"sourceWorldSeed":seed_text, "cx":pair_key.x,
			"cz":pair_key.y, "sourceRows":[] if String(pair[0]) == "cancel-target" \
				else [{"sourceId":"cancel-survivor-row"}]}
		main.call("_new_ecology_source_capture_session", String(pair[0]), world_id,
			seed_text, pair_key, "source-cancel", "removed-cancel",
		artifact, cancel_state, session_owner_lease)
	var cancelled: Dictionary = main.call("cancel_ecology_source_domain_capture",
		"cancel-target")
	sessions = main.get("_ecology_source_capture_sessions")
	_check("cancel_retires_only_the_exact_shared_capture_cursor", \
		bool(cancelled.get("sessionReleased", false)) and not sessions.has("cancel-target") \
		and sessions.has("cancel-survivor"))
	retirement_queue.set("reject_enqueue", true)
	var reset_pending: Dictionary = main.call("reset_ecology_source_capture_sessions")
	var reset_preserved_session: bool = main.get(
		"_ecology_source_capture_sessions").has("cancel-survivor")
	retirement_queue.set("reject_enqueue", false)
	var reset_result: Dictionary = main.call("reset_ecology_source_capture_sessions")
	sessions = main.get("_ecology_source_capture_sessions")
	_check("reset_retries_retirement_backpressure_before_releasing_capture_sessions", \
		reset_pending.get("status", "") == "pending" and reset_preserved_session \
		and reset_result.get("status", "") == "ready" and not sessions.has("cancel-survivor") \
		and sessions.is_empty())
	var retired_roots: Array[Dictionary] = retirement_queue.get("retired_roots")
	var exact_value_alias_retired: bool = false
	for root: Dictionary in retired_roots:
		if String(root.get("schema", "")) == "ecology-source-capture-values/v2":
			if is_same(root.get("sourceRows", null), first_rows) \
					and is_same(root.get("actorIntents", null),
						retained_session_state.get("actorIntents", null)):
				exact_value_alias_retired = true
				break
	_check("retained_source_values_transfer_through_existing_retirement_owner",
		exact_value_alias_retired)

	# Build the producer state through the real initializer, then attach bounded
	# nonempty values for each retained pass workspace. This proves the drop path
	# transfers the aliases that accumulate during generation, not only its final
	# public rows.
	var workspace_key := Vector2i(22, -17)
	var workspace_identity := "capture-workspace-retirement"
	var workspace_lease_result: Dictionary = main.call("acquire_ecology_catalog_artifact_lease",
		String(session_catalog.get("artifactId", "")), "source_capture_workspace",
		workspace_identity, world_id, 19)
	var workspace_lease := String(workspace_lease_result.get("leaseToken", ""))
	var workspace_state: Dictionary = main.call("begin_chunk_prop_spawn_state",
		null, workspace_key.x, workspace_key.y)
	var candidate_values: Array = [Vector3i(22, -9, -17), Vector3i(23, -8, -17)]
	var detail_values: Array = [Transform3D(Basis.IDENTITY, Vector3(1.0, 2.0, 3.0))]
	var detail_batch_values: Dictionary = {"fern":detail_values}
	var detail_row_values: Array = [{"sourceId":"detail-workspace-row"}]
	var active_detail_values: Dictionary = {"phase":"place", "attempt":3}
	var floor_scan_values: Dictionary = {"chunkKey":workspace_key,
		"columnIndex":4, "revision":"scan-workspace"}
	workspace_state["sourceRows"] = [{"sourceId":"workspace-row"}]
	workspace_state["actorIntents"] = [{"actorId":"workspace-actor"}]
	workspace_state["undergroundCandidates"] = candidate_values
	workspace_state["detailBatches"] = detail_batch_values
	workspace_state["detailSourceRows"] = detail_row_values
	workspace_state["detailBatchKeys"] = ["fern"]
	workspace_state["detailActiveAttempt"] = active_detail_values
	workspace_state["undergroundVolumeFloorScan"] = floor_scan_values
	var workspace_session: Dictionary = main.call("_new_ecology_source_capture_session",
		workspace_identity, world_id, seed_text, workspace_key, "workspace-revision",
		"workspace-removals", artifact, workspace_state, workspace_lease)
	var workspace_rng: Variant = workspace_state.get("rng", null)
	var workspace_underground_rng: Variant = workspace_state.get("undergroundRng", null)
	var workspace_detail_rng: Variant = workspace_state.get("detailRng", null)
	var workspace_ledger: Variant = workspace_state.get("ecologySourceLedger", null)
	var workspace_detail_keys: Array = workspace_state.get("detailBatchKeys", [])
	var workspace_estimate: int = main.call(
		"_ecology_source_capture_value_graph_estimate_bytes", workspace_session)
	var expected_workspace_estimate := 2048 + 1024 \
		+ candidate_values.size() * 512 + detail_row_values.size() * 2048 \
		+ detail_values.size() * 64 + workspace_detail_keys.size() * 64 \
		+ active_detail_values.size() * 128 + floor_scan_values.size() * 128
	retirement_queue.set("reject_enqueue", true)
	var workspace_backpressured: bool = not bool(main.call(
		"_drop_ecology_source_capture_session", workspace_identity, "cancelled"))
	var workspace_preserved: Dictionary = main.get(
		"_ecology_source_capture_sessions").get(workspace_identity, {})
	var workspace_lease_still_live: Dictionary = main.call("resolve_ecology_catalog_artifact",
		workspace_lease, world_id, 19)
	retirement_queue.set("reject_enqueue", false)
	var workspace_dropped: bool = main.call("_drop_ecology_source_capture_session",
		workspace_identity, "cancelled")
	var workspace_roots: Array[Dictionary] = retirement_queue.get("retired_roots")
	var workspace_keepalives: Array[RefCounted] = retirement_queue.get("retired_keepalives")
	var workspace_aliases_transferred: bool = false
	var workspace_handles_retained: bool = false
	for root_value: Dictionary in workspace_roots:
		if String(root_value.get("schema", "")) != "ecology-source-capture-values/v2":
			continue
		workspace_aliases_transferred = is_same(root_value.get("undergroundCandidates", null),
			candidate_values) and is_same(root_value.get("detailBatches", null),
			detail_batch_values) and is_same(root_value.get("detailSourceRows", null),
			detail_row_values) and is_same(root_value.get("detailActiveAttempt", null),
			active_detail_values) and is_same(root_value.get("undergroundVolumeFloorScan", null),
			floor_scan_values) and is_same(root_value.get("detailBatchKeys", null),
			workspace_state.get("detailBatchKeys", null)) \
			and is_same(root_value.get("sourceRows", null), workspace_state.get("sourceRows", null)) \
			and is_same(root_value.get("actorIntents", null), workspace_state.get("actorIntents", null)) \
			and not root_value.has("chunk") and not root_value.has("detailBatchRoot")
		if workspace_aliases_transferred: break
	workspace_handles_retained = workspace_rng in workspace_keepalives \
		and workspace_underground_rng in workspace_keepalives \
		and workspace_detail_rng in workspace_keepalives \
		and workspace_ledger in workspace_keepalives
	_check("initialized_capture_workspace_transfers_value_aliases_and_keeps_main_handles",
		workspace_session.get("state", {}) == workspace_state and workspace_dropped \
		and workspace_backpressured and workspace_preserved.get("state", {}) == workspace_state \
		and String(workspace_lease_still_live.get("status", "")) == "ready" \
		and workspace_aliases_transferred and workspace_handles_retained \
		and not main.get("_ecology_source_capture_sessions").has(workspace_identity))
	_check("retained_payload_estimate_accounts_for_detail_and_underground_workspaces",
		workspace_estimate == expected_workspace_estimate)
	main.call("release_ecology_catalog_artifact_lease", workspace_lease)

	var saved_sessions: Dictionary = main.get("_ecology_source_capture_sessions")
	var bounded_sessions: Dictionary = {}
	for index in range(128):
		var key_text := "bounded-cache-%03d" % index
		bounded_sessions[key_text] = {"completedPassCached":true, "retainedIdle":true,
			"subscriberLeaseTokens":[], "lastAccessUsec":index}
	bounded_sessions["pinned-active-family"] = {"completedPassCached":true,
		"retainedIdle":true, "subscriberLeaseTokens":["active-token"],
		"lastAccessUsec":9999}
	main.set("_ecology_source_capture_sessions", bounded_sessions)
	var capacity_recovered: bool = main.call("_make_room_for_ecology_source_capture_session")
	var after_capacity: Dictionary = main.get("_ecology_source_capture_sessions")
	_check("bounded_lru_evicts_idle_pass_but_never_a_subscribed_family", \
		capacity_recovered and after_capacity.size() == 127 \
		and not after_capacity.has("bounded-cache-000") \
		and not after_capacity.has("bounded-cache-001") \
		and after_capacity.has("pinned-active-family"))
	main.set("_ecology_source_capture_sessions", saved_sessions)
	var evicted_identity := "retained-pass-restart-after-eviction"
	var evicted_key := Vector2i(31, -9)
	var evicted_owner_result: Dictionary = main.call("acquire_ecology_catalog_artifact_lease",
		String(session_catalog.get("artifactId", "")), "source_capture_family",
		evicted_identity, world_id, 19)
	var evicted_owner := String(evicted_owner_result.get("leaseToken", ""))
	var old_rows: Array = [{"sourceId":"old-pass-row"}]
	var old_state := {"cacheIdentity":evicted_identity,
		"sourceDomainRevision":"same-source-revision", "sourceWorldId":world_id,
		"sourceWorldSeed":seed_text, "cx":evicted_key.x, "cz":evicted_key.y,
		"sourceRows":old_rows, "actorIntents":[],
		"completedSourceCategories":["trees", "surface_rocks", "ore", "forage",
			"details", "underground_props"],
		"requestedSourceFamilies":["surface_rocks"]}
	main.call("_new_ecology_source_capture_session", evicted_identity, world_id,
		seed_text, evicted_key, "same-source-revision", "removed-a", artifact,
		old_state, evicted_owner)
	var old_session: Dictionary = main.get("_ecology_source_capture_sessions").get(
		evicted_identity, {})
	old_session["publishedSourceFamilies"] = ["surface_rocks"]
	main.call("_retain_completed_ecology_source_capture_pass", evicted_identity,
		old_session)
	old_session["lastAccessUsec"] = 0
	var pressured_sessions: Dictionary = {}
	for index in range(127):
		pressured_sessions["other-cache-%03d" % index] = {"retainedIdle":true,
			"completedPassCached":true, "subscriberLeaseTokens":[],
			"lastAccessUsec":index + 10}
	pressured_sessions[evicted_identity] = old_session
	main.set("_ecology_source_capture_sessions", pressured_sessions)
	var payload_eviction_room: bool = main.call(
		"_make_room_for_ecology_source_capture_session")
	var after_eviction: Dictionary = main.get("_ecology_source_capture_sessions")
	var old_entry_was_evicted: bool = not after_eviction.has(evicted_identity)
	main.call("release_ecology_catalog_artifact_lease", evicted_owner)
	var new_owner_result: Dictionary = main.call("acquire_ecology_catalog_artifact_lease",
		String(session_catalog.get("artifactId", "")), "source_capture_family",
		evicted_identity + "|retry", world_id, 19)
	var new_owner := String(new_owner_result.get("leaseToken", ""))
	var fresh_state := {"cacheIdentity":evicted_identity,
		"sourceDomainRevision":"same-source-revision", "sourceWorldId":world_id,
		"sourceWorldSeed":seed_text, "cx":evicted_key.x, "cz":evicted_key.y,
		"sourceRows":[], "actorIntents":[], "completedSourceCategories":[],
		"requestedSourceFamilies":[], "phase":"props"}
	var fresh_session: Dictionary = main.call("_new_ecology_source_capture_session",
		evicted_identity, world_id, seed_text, evicted_key, "same-source-revision",
		"removed-a", artifact, fresh_state, new_owner)
	_check("evicted_pass_restarts_from_empty_cursor_without_false_empty_receipt",
		payload_eviction_room and old_entry_was_evicted \
		and String(fresh_session.get("sourceDomainRevision", "")) ==
			"same-source-revision" \
		and not bool(fresh_session.get("completedPassCached", false)) \
		and (fresh_session.get("state", {}).get("sourceRows", []) as Array).is_empty() \
		and (fresh_session.get("state", {}).get("completedSourceCategories", []) as Array).is_empty())
	main.call("release_ecology_catalog_artifact_lease", new_owner)
	main.call("cancel_ecology_source_domain_capture", evicted_identity, new_owner)

	var oversized_identity := "oversized-retained-pass"
	var oversized_state := {"sourceRows":[{"meshCpuArrayBytes":67108865}],
		"actorIntents":[], "sourceChunkKey":Vector2i.ZERO}
	var oversized_session := {"cacheIdentity":oversized_identity, "state":oversized_state,
		"subscriberLeaseTokens":[], "lastAccessUsec":1}
	saved_sessions[oversized_identity] = oversized_session
	main.set("_ecology_source_capture_sessions", saved_sessions)
	var oversized_cache_rejected: bool = not bool(main.call(
		"_retain_idle_ecology_source_capture_pass", oversized_identity,
		oversized_session))
	var queue_before_backpressure: int = retired_roots.size()
	retirement_queue.set("reject_enqueue", true)
	var blocked_retirement: bool = not bool(main.call(
		"_drop_ecology_source_capture_session", oversized_identity,
		"completed_cache_eviction"))
	var retained_on_backpressure: bool = main.get(
		"_ecology_source_capture_sessions").has(oversized_identity)
	retirement_queue.set("reject_enqueue", false)
	var retirement_retried: bool = bool(main.call(
		"_drop_ecology_source_capture_session", oversized_identity,
		"completed_cache_eviction"))
	_check("oversized_and_backpressured_passes_remain_owned_until_retirement",
		oversized_cache_rejected and blocked_retirement and retained_on_backpressure \
		and retirement_retried and not main.get(
			"_ecology_source_capture_sessions").has(oversized_identity) \
		and retired_roots.size() == queue_before_backpressure + 1)
	main.call("release_ecology_catalog_artifact_lease", session_owner_lease)

	main.free()
	_finish()


func _check(name: String, passed: bool) -> void:
	checks[name] = passed
	if not passed:
		push_error("Ecology capture session contract failed: %s" % name)


func _run_seeded_family_pass(main: Object, cx: int, cz: int,
		add_details_late: bool) -> Dictionary:
	# Synthetic scheduling parity only: exercise the production seeded pass
	# constructor and family-union method without claiming generated-world output.
	var state_value: Variant = main.call("begin_chunk_prop_spawn_state", null, cx, cz)
	if not (state_value is Dictionary): return {"status":"failed"}
	var state: Dictionary = state_value
	state["sourceRows"] = []
	var initial_families: Array[String] = ["surface_rocks"]
	if not add_details_late: initial_families.append("details")
	main.call("_merge_ecology_source_capture_family_union", state,
		initial_families)
	var surface_rng: RandomNumberGenerator = state.get("rng") as RandomNumberGenerator
	var detail_rng: RandomNumberGenerator = state.get("detailRng") as RandomNumberGenerator
	if not is_instance_valid(surface_rng) or not is_instance_valid(detail_rng):
		return {"status":"failed"}
	var rows: Array[Dictionary] = []
	var surface_cursor := 0
	for attempt in 5:
		rows.append({"family":"surface_rocks", "attempt":attempt,
			"sample":surface_rng.randi()})
		surface_cursor += 1
		state["surfaceCursor"] = surface_cursor
		state["sourceRows"] = rows
	if add_details_late:
		var surface_cursor_at_late_admission: int = surface_cursor
		main.call("_merge_ecology_source_capture_family_union", state, ["details"])
		state["detailsAdmittedLate"] = true
		state["surfaceCursorAtLateAdmission"] = surface_cursor_at_late_admission
	else:
		state["detailsAdmittedLate"] = false
		state["surfaceCursorAtLateAdmission"] = -1
	var detail_cursor := 0
	for attempt in 4:
		rows.append({"family":"details", "attempt":attempt,
			"sample":detail_rng.randi()})
		detail_cursor += 1
		state["detailCursor"] = detail_cursor
		state["sourceRows"] = rows
	return {"status":"ready",
		"requestedFamilies":(state.get("requestedSourceFamilies", []) as Array).duplicate(),
		"sourceRows":rows.duplicate(true),
		"surfaceRngState":surface_rng.state,
		"detailRngState":detail_rng.state,
		"surfaceCursor":surface_cursor, "detailCursor":detail_cursor,
		"detailsAdmittedLate":bool(state.get("detailsAdmittedLate", false)),
		"surfaceCursorAtLateAdmission":int(state.get(
			"surfaceCursorAtLateAdmission", -1))}


func _finish() -> void:
	var passed_count := 0
	for result_value: Variant in checks.values():
		if bool(result_value): passed_count += 1
	var report := {"schema":"ecology-source-capture-session-contract/v1",
		"evidenceLevel":"synthetic_main_capture_session_lifecycle_contract",
		"passed":passed_count == checks.size() and not checks.is_empty(),
		"checkCount":checks.size(), "passedCount":passed_count,
		"failedChecks":[], "checks":checks}
	for name: String in checks:
		if not bool(checks[name]): report.failedChecks.append(name)
	var report_path := OS.get_environment("ECOLOGY_SOURCE_CAPTURE_SESSION_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	if not report.passed:
		quit(1)
	else:
		quit(0)
