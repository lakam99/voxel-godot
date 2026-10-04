extends SceneTree
## Synthetic coordinator demand-scheduler contract. It verifies native-section
## demand admission, provider-complete gating, bounded retries and fair priority
## without starting a renderer installation.

const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const MainRuntime := preload("res://scripts/MainRuntimeTools.gd")
const SectionGrid := preload("res://scripts/world/StaticRenderSectionGrid.gd")


class FakeTerrainRuntime extends Node3D:
	signal visible_mesh_block_revision_changed(section_key: Vector3i, revision: int)
	var published_mesh_blocks: Dictionary = {}

	func enter_section(section_key: Vector3i, revision: int) -> void:
		published_mesh_blocks[section_key] = true
		visible_mesh_block_revision_changed.emit(section_key, revision)

	func exit_section(section_key: Vector3i, revision: int) -> void:
		published_mesh_blocks.erase(section_key)
		visible_mesh_block_revision_changed.emit(section_key, revision)


class FakeInstalledSession extends RefCounted:
	var receipt: Dictionary = {}

	func configure(candidate: Dictionary) -> void:
		receipt = {"status":"installed",
			"generation":int(candidate.get("generation", 0)),
			"censusDigest":String(candidate.get("censusDigest", "")),
			"contentManifestDigest":String(candidate.get("contentManifestDigest", "")),
			"backendInstanceId":101, "chunkInstanceId":202, "ownerCell":Vector2i(2, 0)}

	func advance(_max_upload_units: int) -> Dictionary:
		return {"status":"installed", "receipt":receipt}

class EmptySectionProvider extends RefCounted:
	var provider_id := ""
	var configured_world_id := ""

	func configure(next_provider_id: String, world_id: String) -> void:
		provider_id = next_provider_id
		configured_world_id = world_id

	func capture_static_section_sources(world_id: String, section_keys: Array) -> Dictionary:
		if world_id != configured_world_id:
			return {"status":"pending", "reason":"fixture_world_mismatch", "retryable":true}
		var sections: Dictionary = {}
		for section_key_value: Variant in section_keys:
			var coverage := {"status":"empty",
				"coverageRevision":"%s:%s" % [provider_id, str(section_key_value)],
				"sourcePartIds":[]}
			coverage["sourcePartIds"].make_read_only()
			coverage.make_read_only()
			sections[section_key_value] = coverage
		sections.make_read_only()
		var revisions: Dictionary = {}
		revisions.make_read_only()
		return {"status":"complete", "worldId":world_id,
			"authorityRevision":provider_id + ":authority:1",
			"sourceRevisions":revisions, "sections":sections}

	func capture_static_section_contribution(census: Dictionary,
			section_key: Vector3i) -> Dictionary:
		var coverage: Dictionary = census.providerCoverageRevisions.get(provider_id, {})
		var authority: Dictionary = census.providerSnapshotRevisions
		if not coverage.has(section_key) or not authority.has(provider_id):
			return {"status":"pending", "reason":"fixture_provider_coverage_missing",
				"retryable":true}
		var revisions: Dictionary = {}
		revisions.make_read_only()
		var inputs: Array[Dictionary] = []
		inputs.make_read_only()
		var compatibility: Dictionary = {}
		compatibility.make_read_only()
		var contribution := {"providerId":provider_id, "sectionKey":section_key,
			"coverageRevision":String(coverage[section_key]),
			"authorityRevision":String(authority[provider_id]),
			"authoritySourceRevisions":revisions,
			"inputs":inputs, "compatibilityByKey":compatibility}
		contribution.make_read_only()
		return {"status":"ready", "contribution":contribution}


var checks: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var world_id := "seed:visible-section-demand-contract:1"
	var required: Array[String] = ["terrain", "ecology"]
	required.make_read_only()
	var coordinator = Coordinator.new()
	var configured: Dictionary = coordinator.configure(world_id)
	var roster_configured: Dictionary = coordinator.configure_source_roster(required)
	var section_near := Vector3i(0, 0, 0)
	var section_far := Vector3i(3, 0, 0)
	var signal_coordinator = Coordinator.new()
	signal_coordinator.configure(world_id + ":signal")
	var main_runtime = MainRuntime.new()
	main_runtime.world_static_section_coordinator = signal_coordinator
	var fake_terrain := FakeTerrainRuntime.new()
	main_runtime.voxel_terrain_runtime = fake_terrain
	main_runtime.connect_voxel_terrain_section_demand_signal()
	fake_terrain.enter_section(section_near, 10)
	check("terrain_section_events_seed_demand_through_runtime_signal",
		main_runtime.voxel_terrain_section_demand_signal_connected
		and signal_coordinator._visible_section_demands.has(section_near)
		and int(signal_coordinator._visible_section_demands[section_near].terrainRevision) == 10,
		{"connected":main_runtime.voxel_terrain_section_demand_signal_connected,
			"demand":signal_coordinator._visible_section_demands.get(section_near, {})})
	fake_terrain.exit_section(section_near, 11)
	check("terrain_exit_event_withdraws_visible_demand",
		not signal_coordinator._visible_section_demands.has(section_near),
		{"remaining":signal_coordinator._visible_section_demands.keys()})
	fake_terrain.free()
	main_runtime.free()
	var demand: Dictionary = coordinator.request_visible_section_demand(section_far, 11, 900.0)
	check("native_mesh_section_demand_enters_retryable_coordinator_queue",
		configured.get("status") == "ready" and roster_configured.get("status") == "ready"
		and demand.get("status") == "queued"
		and coordinator._visible_section_demand_count == 1, demand)
	var missing_both: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	check("missing_terrain_and_ecology_providers_stay_pending_without_install",
		missing_both.get("status") == "advanced"
		and missing_both.results[0].admission.get("status") == "pending"
		and missing_both.results[0].admission.get("reason") == "static_source_provider_missing"
		and coordinator._production_candidate_jobs.is_empty()
		and String(coordinator._visible_section_demands[section_far].stage) == "waiting",
		missing_both)
	var terrain := EmptySectionProvider.new()
	terrain.configure("terrain", world_id)
	var terrain_registered: Dictionary = coordinator.register_source_provider(
		"terrain", terrain, "capture_static_section_sources")
	var missing_ecology: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	check("terrain_only_census_cannot_admit_partial_section",
		terrain_registered.get("status") == "ready"
		and missing_ecology.get("status") == "advanced"
		and missing_ecology.results[0].admission.get("status") == "pending"
		and missing_ecology.results[0].admission.get("reason") == "static_source_provider_missing"
		and coordinator._production_candidate_jobs.is_empty(), missing_ecology)
	var ecology := EmptySectionProvider.new()
	ecology.configure("ecology", world_id)
	var ecology_registered: Dictionary = coordinator.register_source_provider(
		"ecology", ecology, "capture_static_section_sources")
	var admitted: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	check("explicit_complete_empty_providers_admit_candidate_without_installing_it",
		ecology_registered.get("status") == "ready"
		and admitted.get("status") == "advanced"
		and admitted.results[0].admission.get("status") == "queued"
		and coordinator._production_candidate_jobs.has(section_far)
		and coordinator._production_candidates_by_section.is_empty(), admitted)
	coordinator.request_visible_section_demand(section_far, 11, 900.0)
	check("duplicate_native_revision_does_not_duplicate_or_requeue_admitted_work",
		String(coordinator._visible_section_demands[section_far].stage) == "candidate_queued"
		and coordinator._visible_section_demand_count == 0,
		{"state":coordinator._visible_section_demands.get(section_far, {}),
			"queueCount":coordinator._visible_section_demand_count})
	var revised: Dictionary = coordinator.request_visible_section_demand(section_far, 12, 900.0)
	check("new_native_revision_supersedes_pending_candidate_with_retryable_demand",
		revised.get("status") == "queued"
		and not coordinator._production_candidate_jobs.has(section_far)
		and coordinator._visible_section_demand_count == 1,
		{"request":revised, "jobs":coordinator._production_candidate_jobs.keys()})
	coordinator.withdraw_visible_section_demand(section_far)
	coordinator.request_visible_section_demand(section_far, 13, 900.0)
	coordinator.request_visible_section_demand(section_near, 21, 900.0)
	var near_center := SectionGrid.origin_for_key(section_near) \
		+ Vector3.ONE * (SectionGrid.SECTION_SIZE_METERS * 0.5)
	var refreshed: Dictionary = coordinator.refresh_visible_section_demand_priorities(
		near_center, 16)
	var nearest: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	check("bounded_camera_refresh_prioritizes_nearest_current_demand",
		refreshed.get("status") == "advanced" and refreshed.get("updatedCount") == 2
		and nearest.get("status") == "advanced"
		and nearest.results[0].get("sectionKey") == section_near
		and coordinator._visible_section_demands.has(section_far), nearest)
	var fair_followup: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	check("unselected_demand_remains_queued_for_fair_followup",
		fair_followup.get("status") == "advanced"
		and fair_followup.results[0].get("sectionKey") == section_far,
		fair_followup)
	var withdrawn: Dictionary = coordinator.withdraw_visible_section_demand(section_near)
	check("withdrawal_cancels_only_staged_work_and_keeps_accepted_visual_state",
		withdrawn.get("status") == "withdrawn"
		and not withdrawn.get("installedRepresentationRetained", true), withdrawn)
	var lifecycle := Coordinator.new()
	var lifecycle_world := world_id + ":candidate-lifecycle"
	lifecycle.configure(lifecycle_world)
	lifecycle.configure_source_roster(required)
	var lifecycle_terrain := EmptySectionProvider.new()
	lifecycle_terrain.configure("terrain", lifecycle_world)
	var lifecycle_ecology := EmptySectionProvider.new()
	lifecycle_ecology.configure("ecology", lifecycle_world)
	lifecycle.register_source_provider("terrain", lifecycle_terrain,
		"capture_static_section_sources")
	lifecycle.register_source_provider("ecology", lifecycle_ecology,
		"capture_static_section_sources")
	var installed_key := Vector3i(10, 0, 0)
	lifecycle.request_visible_section_demand(installed_key, 31, 1.0)
	var lifecycle_admission: Dictionary = lifecycle.advance_visible_section_candidate_demands(1)
	var candidate_job: Dictionary = lifecycle._production_candidate_jobs.get(installed_key, {})
	var actual_candidate: Dictionary = candidate_job.get("candidate", {})
	var fake_session := FakeInstalledSession.new()
	fake_session.configure(actual_candidate)
	candidate_job["session"] = fake_session
	lifecycle._production_candidate_jobs[installed_key] = candidate_job
	var install_outcome: Dictionary = lifecycle.advance_complete_section_candidate(installed_key, 1)
	var installed_state: Dictionary = lifecycle._visible_section_demands[installed_key]
	check("candidate_install_completion_receipt_marks_matching_visible_demand_installed",
		lifecycle_admission.get("attemptCount") == 1
		and lifecycle_admission.results[0].admission.get("status") == "queued"
		and install_outcome.get("status") == "installed"
		and installed_state.get("stage") == "installed"
		and int(installed_state.get("installedGeneration", 0)) \
			== int(actual_candidate.get("generation", 0))
		and installed_state.get("installedReceipt", {}).get("contentManifestDigest") \
			== String(actual_candidate.get("contentManifestDigest", ""))
		and lifecycle._production_candidate_receipts.has(installed_key),
		{"admission":lifecycle_admission, "outcome":install_outcome,
			"demand":installed_state})
	var unresolved_key := Vector3i(10, 1, 0)
	lifecycle.request_visible_section_demand(unresolved_key, 33, 9.0)
	lifecycle._pop_visible_section_demand()
	var unresolved_state: Dictionary = lifecycle._visible_section_demands[unresolved_key]
	unresolved_state["queued"] = false
	unresolved_state["stage"] = "candidate_queued"
	unresolved_state["candidateGeneration"] = 93
	lifecycle._visible_section_demands[unresolved_key] = unresolved_state
	lifecycle._reconcile_visible_section_candidate_outcome(unresolved_key, 93,
		{"status":"pending", "stage":"section_upload", "reason":"fixture_upload_pending",
			"retryable":true})
	var pending_install_state: Dictionary = lifecycle._visible_section_demands[unresolved_key].duplicate(true)
	lifecycle._reconcile_visible_section_candidate_outcome(unresolved_key, 93,
		{"status":"pending", "stage":"source_census", "reason":"fixture_census_stale",
			"retryable":true, "requiresReassembly":true})
	var stale_install_state: Dictionary = lifecycle._visible_section_demands[unresolved_key].duplicate(true)
	check("pending_install_session_is_retained_and_stale_census_requeues_reassembly",
		pending_install_state.get("stage") == "candidate_pending"
		and int(pending_install_state.get("candidateGeneration", 0)) == 93
		and stale_install_state.get("stage") == "waiting"
		and not stale_install_state.has("candidateGeneration")
		and stale_install_state.get("queued")
		and stale_install_state.get("lastInstallReason") == "fixture_census_stale",
		{"pending":pending_install_state, "stale":stale_install_state})
	var stale_queue_entry: Dictionary = lifecycle._pop_visible_section_demand()
	unresolved_state = lifecycle._visible_section_demands[unresolved_key]
	unresolved_state["queued"] = false
	unresolved_state["stage"] = "candidate_queued"
	unresolved_state["candidateGeneration"] = 94
	lifecycle._visible_section_demands[unresolved_key] = unresolved_state
	lifecycle._reconcile_visible_section_candidate_outcome(unresolved_key, 94,
		{"status":"failed", "reason":"fixture_nonretryable_install_failure"})
	var blocked_state: Dictionary = lifecycle._visible_section_demands[unresolved_key]
	check("nonretryable_install_failure_records_blocked_reason",
		stale_queue_entry.get("status") == "ready"
		and blocked_state.get("stage") == "blocked"
		and blocked_state.get("blockedReason") == "fixture_nonretryable_install_failure"
		and not blocked_state.has("candidateGeneration"), blocked_state)
	var retry_key := Vector3i(11, 0, 0)
	lifecycle.request_visible_section_demand(retry_key, 32, 4.0)
	var retry_demand: Dictionary = lifecycle._visible_section_demands[retry_key]
	lifecycle._pop_visible_section_demand()
	retry_demand["queued"] = false
	retry_demand["stage"] = "candidate_queued"
	retry_demand["candidateGeneration"] = 92
	lifecycle._visible_section_demands[retry_key] = retry_demand
	lifecycle._reconcile_visible_section_candidate_outcome(retry_key, 92,
		{"status":"failed", "reason":"fixture_transient_install_failure",
			"retryable":true})
	var retry_after_failure: Dictionary = lifecycle._visible_section_demands[retry_key].duplicate(true)
	var removed_for_wake: Dictionary = lifecycle.unregister_source_provider(
		"ecology", lifecycle_ecology)
	var restored_for_wake: Dictionary = lifecycle.register_source_provider(
		"ecology", lifecycle_ecology, "capture_static_section_sources")
	var recovered_admission: Dictionary = lifecycle.advance_visible_section_candidate_demands(1)
	check("retryable_failure_is_requeued_and_provider_wakeup_recovers_candidate",
		retry_after_failure.get("stage") == "waiting"
		and not retry_after_failure.has("candidateGeneration")
		and retry_after_failure.get("queued")
		and removed_for_wake.get("status") == "ready"
		and restored_for_wake.get("status") == "ready"
		and recovered_admission.get("attemptCount") == 1
		and recovered_admission.results[0].admission.get("status") == "queued"
		and lifecycle._visible_section_demands[retry_key].get("stage") == "candidate_queued",
		{"afterFailure":retry_after_failure, "removed":removed_for_wake,
			"restored":restored_for_wake, "recovered":recovered_admission})
	var output := {"schema":"visible-section-demand-driver-contract/v1",
		"passed":checks.all(func(row: Dictionary) -> bool: return bool(row.passed)),
		"complete":checks.all(func(row: Dictionary) -> bool: return bool(row.passed)),
		"checkCount":checks.size(),
		"evidenceLevel":"synthetic_native_section_demand_and_candidate_lifecycle_reconciliation",
		"checks":checks,
		"doesNotProve":"native rendering, actual terrain/ecology geometry parity, native install completion, legacy retirement, gameplay or performance"}
	var report_path := OS.get_environment("VOXEL_VISIBLE_SECTION_DEMAND_REPORT")
	if report_path.is_empty():
		push_error("VOXEL_VISIBLE_SECTION_DEMAND_REPORT is required")
		quit(2)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write visible-section demand report: " + report_path)
		quit(2)
	file.store_string(JSON.stringify(output, "\t"))
	file.close()
	quit(0 if output.passed else 1)


func check(name: String, passed: bool, evidence: Variant = {}) -> void:
	checks.append({"name":name, "passed":passed, "evidence":evidence})
	if not passed:
		push_error("Visible section demand contract failed: " + name + " " + str(evidence))
