extends SceneTree
## Synthetic coordinator demand-scheduler contract. It verifies native-section
## demand admission, provider-complete gating, bounded retries and fair priority
## without starting a renderer installation.

const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const MainRuntime := preload("res://scripts/MainRuntimeTools.gd")
const SectionGrid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const TerrainRuntime := preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
const TerrainVolume := preload("res://scripts/TerrainVolumeService.gd")
const WorldGeneration := preload("res://scripts/WorldGenerationSystem.gd")
const SourceRoster := preload("res://scripts/world/StaticSectionSourceRoster.gd")


class FixtureCoordinator extends "res://scripts/world/WorldStaticSectionCoordinator.gd":
	func _receipt_is_live(candidate: Dictionary, receipt: Dictionary) -> bool:
		return receipt.get("status") == "installed" \
			and receipt.get("worldId") == candidate.get("worldId") \
			and receipt.get("sectionKey") == candidate.get("sectionKey") \
			and int(receipt.get("generation", 0)) == int(candidate.get("generation", 0)) \
			and receipt.get("contentManifestDigest") == candidate.get("contentManifestDigest")


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
	var cancelled := false

	func configure(candidate: Dictionary) -> void:
		receipt = {"status":"installed",
			"worldId":String(candidate.get("worldId", "")),
			"sectionKey":candidate.get("sectionKey", Vector3i.ZERO),
			"generation":int(candidate.get("generation", 0)),
			"censusDigest":String(candidate.get("censusDigest", "")),
			"contentManifestDigest":String(candidate.get("contentManifestDigest", "")),
			"backendInstanceId":101, "chunkInstanceId":202, "ownerCell":Vector2i(2, 0)}
		receipt.make_read_only()

	func advance(_max_upload_units: int) -> Dictionary:
		return {"status":"installed", "receipt":receipt}

	func cancel() -> Dictionary:
		cancelled = true
		return {"status":"cancelled"}

class EmptySectionProvider extends RefCounted:
	var provider_id := ""
	var configured_world_id := ""
	var authority_revision := 1

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
			"authorityRevision":provider_id + ":authority:" + str(authority_revision),
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


class StaleSnapshotProvider extends RefCounted:
	func capture_static_section_sources(_world_id: String, _sections: Array) -> Dictionary:
		return {"status":"pending", "retryable":true,
			"reason":"ecology_chunk_source_snapshot_revision_stale",
			"chunk":Vector2i(2, -1), "snapshotRemovedPropsRevision":3,
			"currentRemovedPropsRevision":3, "snapshotSourceRevision":"terrain-5",
			"currentSourceRevision":"terrain-6",
			"snapshotValidation":{"status":"ready", "reason":""}}


var checks: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var world_id := "seed:visible-section-demand-contract:1"
	var stale_roster := SourceRoster.new()
	var stale_provider := StaleSnapshotProvider.new()
	stale_roster.bind_world(world_id + ":stale-snapshot", ["ecology_and_static_props"])
	stale_roster.register_provider("ecology_and_static_props", stale_provider,
		"capture_static_section_sources")
	var stale_census: Dictionary = stale_roster.capture_sections([Vector3i.ZERO])
	var stale_details: Dictionary = stale_census.get("providerDetails", {})
	check("pending_provider_wrapper_preserves_nested_reason_and_bounded_revision_details",
		stale_census.get("status") == "pending"
			and stale_census.get("reason") == "static_source_provider_pending"
			and stale_census.get("providerReason") == "ecology_chunk_source_snapshot_revision_stale"
			and stale_details.get("snapshotSourceRevision") == "terrain-5"
			and stale_details.get("currentSourceRevision") == "terrain-6"
			and stale_details.get("snapshotValidationStatus") == "ready",
		stale_census)
	var required: Array[String] = ["terrain", "ecology"]
	required.make_read_only()
	var coordinator = FixtureCoordinator.new()
	var configured: Dictionary = coordinator.configure(world_id)
	var roster_configured: Dictionary = coordinator.configure_source_roster(required)
	var section_near := Vector3i(0, 0, 0)
	var section_far := Vector3i(3, 0, 0)
	var signal_coordinator = FixtureCoordinator.new()
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
	var edited_coordinator = FixtureCoordinator.new()
	edited_coordinator.configure(world_id + ":terrain-edit")
	var volume := TerrainVolume.new()
	var world := WorldGeneration.new()
	world.terrain_volume_service = volume
	var edit_runtime := MainRuntime.new()
	edit_runtime.world_generation_system = world
	edit_runtime.world_static_section_coordinator = edited_coordinator
	var voxel_runtime := TerrainRuntime.new()
	voxel_runtime.main = edit_runtime
	edit_runtime.voxel_terrain_runtime = voxel_runtime
	var resident_sections: Array[Vector3i] = []
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var resident_key := Vector3i(x, y, z)
				resident_sections.append(resident_key)
				voxel_runtime.published_mesh_blocks[resident_key] = true
				voxel_runtime.mesh_block_revisions[resident_key] = 1
	voxel_runtime.connect_terrain_volume_revision_signal()
	edit_runtime.connect_voxel_terrain_section_demand_signal()
	volume.set_cell_state(Vector3i.ZERO,
		{"solid":true, "density":1.0, "material":"stone"}, "section_render_invalidation_contract")
	var exact_halo_sections_redemanded := true
	var exact_halo_revision_count := 0
	for z in range(-1, 1):
		for y in range(-1, 1):
			for x in range(-1, 1):
				var affected_key := Vector3i(x, y, z)
				exact_halo_sections_redemanded = exact_halo_sections_redemanded \
					and edited_coordinator._visible_section_demands.has(affected_key)
				exact_halo_revision_count += int(
					int(voxel_runtime.mesh_block_revisions.get(affected_key, 0)) > 1)
	check("authoritative_terrain_revision_invalidates_resident_core_and_transvoxel_halo",
		exact_halo_sections_redemanded and exact_halo_revision_count == 8
		and edited_coordinator._visible_section_demands.size() == 8,
		{"residentSections":resident_sections.size(),
			"redemandedSections":edited_coordinator._visible_section_demands.size(),
			"exactExpectedHaloSections":8,
			"revisions":voxel_runtime.mesh_block_revisions})
	voxel_runtime.free()
	edit_runtime.free()
	var priority_coordinator = FixtureCoordinator.new()
	priority_coordinator.configure(world_id + ":urgent-recompile")
	var edited_section := Vector3i(8, 0, 0)
	var installed_candidate := {"sectionKey":edited_section, "generation":4}
	priority_coordinator._production_candidates_by_section[edited_section] = installed_candidate
	priority_coordinator.request_visible_section_demand(edited_section, 10, 900.0)
	var installed_demand: Dictionary = priority_coordinator._visible_section_demands[edited_section]
	installed_demand["stage"] = "installed"
	installed_demand["installedGeneration"] = 4
	installed_demand["queued"] = false
	priority_coordinator._visible_section_demands[edited_section] = installed_demand
	priority_coordinator._visible_section_demand_queue.clear()
	priority_coordinator._visible_section_demand_head = 0
	priority_coordinator._visible_section_demand_tail = 0
	priority_coordinator._visible_section_demand_count = 0
	for index in range(3):
		priority_coordinator.request_visible_section_demand(
			Vector3i(index, 0, 0), 1, 0.01 + float(index))
	var revision_request: Dictionary = priority_coordinator.request_visible_section_demand(
		edited_section, 11, 900.0)
	var selected_recompile: Dictionary = priority_coordinator._take_next_visible_section_demand()
	var refreshed_demand: Dictionary = priority_coordinator._visible_section_demands[edited_section]
	check("installed_section_revision_change_preempts_first_time_nearby_sections",
		revision_request.get("status") == "queued"
		and bool(refreshed_demand.get("urgentRecompile", false))
		and float(refreshed_demand.get("priority", INF)) == 0.0
		and selected_recompile.get("status") == "ready"
		and selected_recompile.get("sectionKey") == edited_section
		and priority_coordinator._production_candidates_by_section.get(edited_section) == installed_candidate,
		{"request":revision_request, "selected":selected_recompile,
			"demand":refreshed_demand,
			"previousCandidateRetained":priority_coordinator._production_candidates_by_section.get(edited_section) == installed_candidate})
	var saturated_coordinator = FixtureCoordinator.new()
	saturated_coordinator.configure(world_id + ":urgent-saturated-queue")
	for index in range(1000):
		saturated_coordinator.request_visible_section_demand(
			Vector3i(index, 1, 0), 1, float(index + 1))
	var saturated_key := Vector3i(2000, 1, 0)
	var saturated_candidate := {"sectionKey":saturated_key, "generation":12}
	saturated_coordinator._production_candidates_by_section[saturated_key] = saturated_candidate
	saturated_coordinator.request_visible_section_demand(saturated_key, 1, 999999.0)
	var saturated_state: Dictionary = saturated_coordinator._visible_section_demands[saturated_key]
	saturated_state["stage"] = "installed"
	saturated_state["installedGeneration"] = 12
	saturated_state["queued"] = false
	saturated_coordinator._visible_section_demands[saturated_key] = saturated_state
	saturated_coordinator.invalidate_visible_section_source(saturated_key,
		"terrain", "terrain:installed:fixture", "revision-2")
	var urgent_head := saturated_coordinator.has_urgent_visible_section_recompile()
	var saturated_selection := saturated_coordinator._take_next_visible_section_demand(true)
	check("urgent_installed_replacement_preempts_saturated_fifo_with_bounded_scan",
		urgent_head and saturated_selection.get("status") == "ready"
			and saturated_selection.get("sectionKey") == saturated_key
			and saturated_coordinator._production_candidates_by_section.get(saturated_key)
				== saturated_candidate
			and saturated_coordinator._visible_section_demand_count > 0,
		{"urgentHead":urgent_head, "selection":saturated_selection,
			"remainingQueueCount":saturated_coordinator._visible_section_demand_count,
			"pendingDemandCount":saturated_coordinator._visible_section_demands.size()})
	var bounded_admission_details: Dictionary = Coordinator._visible_section_admission_details({
		"status":"pending", "providerId":"ecology_and_static_props",
		"reason":"static_source_provider_pending",
		"providerReason":"ecology_chunk_source_snapshot_revision_stale",
		"providerDetails":{"chunk":Vector2i(2, -1), "snapshotRemovedPropsRevision":3,
			"currentRemovedPropsRevision":3, "snapshotSourceRevision":"old",
			"currentSourceRevision":"new", "snapshotValidationStatus":"ready"},
		"unboundedPayload":PackedByteArray([1, 2, 3])})
	check("provider_stale_revision_details_are_retained_as_bounded_scalar_telemetry",
		bounded_admission_details.get("providerReason") == "ecology_chunk_source_snapshot_revision_stale"
			and bounded_admission_details.get("snapshotSourceRevision") == "old"
			and bounded_admission_details.get("currentSourceRevision") == "new"
			and bounded_admission_details.get("snapshotValidationStatus") == "ready"
			and not bounded_admission_details.has("unboundedPayload"), bounded_admission_details)
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
	var lifecycle := FixtureCoordinator.new()
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
	var prior_candidate: Dictionary = lifecycle._production_candidates_by_section[installed_key]
	var indexed_candidate: Dictionary = prior_candidate.duplicate(false)
	var prior_source_revisions := {"ecology:part:fixture":"prop-revision-1"}
	prior_source_revisions.make_read_only()
	indexed_candidate["sourceRevisions"] = prior_source_revisions
	var indexed_prepared: Dictionary = prior_candidate.candidate.duplicate(true)
	var indexed_snapshot: Dictionary = indexed_prepared.snapshot.duplicate(true)
	indexed_snapshot["manifest"] = [{"sourceId":"ecology:prop:fixture",
		"sourcePartId":"ecology:part:fixture", "sourceRevision":"prop-revision-1"}]
	indexed_prepared["snapshot"] = indexed_snapshot
	indexed_candidate["candidate"] = indexed_prepared
	lifecycle._replace_section_source_index(installed_key, prior_candidate, indexed_candidate)
	lifecycle._production_candidates_by_section[installed_key] = indexed_candidate
	prior_candidate = indexed_candidate
	var prior_generation := int(installed_state.get("installedGeneration", 0))
	lifecycle_ecology.authority_revision = 2
	var invalidation: Dictionary = lifecycle.invalidate_visible_static_source(
		"ecology", "ecology:prop:fixture", "prop-revision-2")
	var invalidated_state: Dictionary = lifecycle._visible_section_demands[installed_key].duplicate(true)
	var invalidation_results: Array = invalidation.get("results", [])
	var first_invalidation: Dictionary = invalidation_results[0] if not invalidation_results.is_empty() else {}
	var invalidation_checks := {"queued":invalidation.get("status") == "queued",
		"previous_generation":first_invalidation.get("previousInstalledGeneration") == prior_generation,
		"representation_retained":bool(first_invalidation.get("previousRepresentationRetained", false)),
		"waiting":invalidated_state.get("stage") == "waiting",
		"still_queued":bool(invalidated_state.get("queued", false)),
		"urgent_recompile":bool(invalidated_state.get("urgentRecompile", false)),
		"urgent_priority":float(invalidated_state.get("priority", INF)) == 0.0,
		"old_generation_retained":int(invalidated_state.get("installedGeneration", 0)) == prior_generation,
		"old_candidate_retained":is_same(lifecycle._production_candidates_by_section[installed_key], prior_candidate),
		"index_uses_source_id_not_source_part_id":lifecycle._visible_sections_by_source_id.has("ecology:prop:fixture")
			and not lifecycle._visible_sections_by_source_id.has("ecology:part:fixture")}
	check("source_revision_invalidation_queues_complete_rebuild_and_keeps_old_receipt",
		not invalidation_checks.values().has(false),
		{"invalidation":invalidation, "state":invalidated_state,
		"checks":invalidation_checks,
		"sourceIndexedByManifestIdentity":lifecycle._visible_sections_by_source_id.has("ecology:prop:fixture")
			and not lifecycle._visible_sections_by_source_id.has("ecology:part:fixture"),
		"candidateSame":is_same(lifecycle._production_candidates_by_section[installed_key], prior_candidate)})
	var replacement_admission: Dictionary = lifecycle.advance_visible_section_candidate_demands(1)
	var replacement_job: Dictionary = lifecycle._production_candidate_jobs.get(installed_key, {})
	var replacement_candidate: Dictionary = replacement_job.get("candidate", {})
	var replacement_session := FakeInstalledSession.new()
	replacement_session.configure(replacement_candidate)
	replacement_job["session"] = replacement_session
	lifecycle._production_candidate_jobs[installed_key] = replacement_job
	var replacement_outcome: Dictionary = lifecycle.advance_complete_section_candidate(installed_key, 1)
	var replaced_state: Dictionary = lifecycle._visible_section_demands[installed_key]
	check("changed_source_replaces_candidate_only_after_current_install_receipt",
		replacement_admission.get("attemptCount") == 1
		and replacement_job.get("candidate", {}).get("censusDigest") != prior_candidate.get("censusDigest")
		and replacement_outcome.get("status") == "installed"
		and replaced_state.get("stage") == "installed"
		and int(replaced_state.get("installedGeneration", 0)) > prior_generation
		and not replaced_state.has("sourceInvalidation")
		and int(lifecycle._production_candidates_by_section[installed_key].get("generation", 0)) \
			== int(replacement_candidate.get("generation", 0))
		and not lifecycle._visible_sections_by_source_id.has("ecology:prop:fixture"),
		{"admission":replacement_admission, "outcome":replacement_outcome,
			"installedGeneration":replaced_state.get("installedGeneration", 0)})
	var added_source_bounds := AABB(SectionGrid.origin_for_key(installed_key),
		Vector3.ONE * SectionGrid.SECTION_SIZE_METERS)
	var added_source_invalidation: Dictionary = lifecycle.invalidate_visible_static_source(
		"ecology", "ecology:new:fixture", "new-source-revision", added_source_bounds)
	var added_source_state: Dictionary = lifecycle._visible_section_demands[installed_key]
	check("new_static_source_bounds_invalidate_intersecting_demanded_section",
		added_source_invalidation.get("status") == "queued"
		and added_source_invalidation.get("affectedSectionKeys") == [installed_key]
		and int(added_source_invalidation.get("queuedCount", 0)) == 1
		and added_source_state.get("stage") == "waiting"
		and added_source_state.get("queued"),
		{"invalidation":added_source_invalidation, "state":added_source_state})
	var replay_lifecycle := FixtureCoordinator.new()
	var replay_world := world_id + ":withdrawn-source-replay"
	replay_lifecycle.configure(replay_world)
	replay_lifecycle.configure_source_roster(required)
	var replay_terrain := EmptySectionProvider.new()
	replay_terrain.configure("terrain", replay_world)
	var replay_ecology := EmptySectionProvider.new()
	replay_ecology.configure("ecology", replay_world)
	replay_lifecycle.register_source_provider("terrain", replay_terrain,
		"capture_static_section_sources")
	replay_lifecycle.register_source_provider("ecology", replay_ecology,
		"capture_static_section_sources")
	var replay_key := Vector3i(4, 0, 0)
	replay_lifecycle.request_visible_section_demand(replay_key, 41, 1.0)
	replay_lifecycle.advance_visible_section_candidate_demands(1)
	var replay_job: Dictionary = replay_lifecycle._production_candidate_jobs.get(replay_key, {})
	var replay_original: Dictionary = replay_job.get("candidate", {})
	var replay_session := FakeInstalledSession.new()
	replay_session.configure(replay_original)
	replay_job["session"] = replay_session
	replay_lifecycle._production_candidate_jobs[replay_key] = replay_job
	var replay_install: Dictionary = replay_lifecycle.advance_complete_section_candidate(replay_key, 1)
	var replay_indexed: Dictionary = replay_lifecycle._production_candidates_by_section[replay_key].duplicate(false)
	var replay_prepared: Dictionary = replay_indexed.candidate.duplicate(true)
	var replay_snapshot: Dictionary = replay_prepared.snapshot.duplicate(true)
	replay_snapshot["manifest"] = [{"sourceId":"ecology:prop:replay",
		"sourcePartId":"ecology:part:replay", "sourceRevision":"prop-revision-1"}]
	replay_prepared["snapshot"] = replay_snapshot
	replay_indexed["candidate"] = replay_prepared
	replay_lifecycle._replace_section_source_index(replay_key,
		replay_lifecycle._production_candidates_by_section[replay_key], replay_indexed)
	replay_lifecycle._production_candidates_by_section[replay_key] = replay_indexed
	replay_lifecycle._committed_candidates[replay_key] = replay_indexed
	replay_lifecycle._replay_set[replay_key] = true
	replay_lifecycle._replay_queue.append(replay_key)
	var legacy_active_session := FakeInstalledSession.new()
	legacy_active_session.configure(replay_indexed)
	replay_lifecycle._active_replay = {"candidate":replay_indexed,
		"sectionKey":replay_key, "installSession":legacy_active_session}
	var replay_withdrawal: Dictionary = replay_lifecycle.withdraw_visible_section_demand(replay_key)
	replay_ecology.authority_revision = 2
	var replay_invalidation: Dictionary = replay_lifecycle.invalidate_visible_static_source(
		"ecology", "ecology:prop:replay", "prop-revision-2")
	var replay_dirty: Dictionary = replay_lifecycle._dirty_source_sections.get(replay_key, {})
	var replay_invalidation_rows: Array = replay_invalidation.get("results", [])
	var replay_invalidation_row: Dictionary = replay_invalidation_rows[0] \
		if not replay_invalidation_rows.is_empty() else {}
	var owner_cell := SectionGrid.chunk_key_for_section(replay_key)
	var unload_count: int = replay_lifecycle.notify_stream_chunk_unloaded(owner_cell, 202)
	var load_count: int = replay_lifecycle.notify_stream_chunk_loaded(owner_cell)
	var replay_request_blocked: bool = not replay_lifecycle.request_section_replay(replay_key)
	var no_stale_replay_job := not replay_lifecycle._production_candidate_jobs.has(replay_key)
	var no_legacy_replay_work := replay_lifecycle._replay_queue.is_empty() \
		and not replay_lifecycle._replay_set.has(replay_key) \
		and replay_lifecycle._active_replay.is_empty() and legacy_active_session.cancelled
	var late_legacy_session := FakeInstalledSession.new()
	late_legacy_session.configure(replay_indexed)
	replay_lifecycle._active_replay = {"candidate":replay_indexed,
		"sectionKey":replay_key, "installSession":late_legacy_session}
	var empty_revision_map: Dictionary = {}
	empty_revision_map.make_read_only()
	var empty_census_map: Dictionary = {}
	empty_census_map.make_read_only()
	var dirty_replay_advance: Dictionary = replay_lifecycle.advance_replay(
		empty_revision_map, empty_census_map, {}, {})
	var dirty_advance_blocked: bool = dirty_replay_advance.get("status") == "deferred_dirty" \
		and late_legacy_session.cancelled and replay_lifecycle._active_replay.is_empty()
	replay_lifecycle.request_visible_section_demand(replay_key, 41, 1.0)
	var fresh_admission: Dictionary = replay_lifecycle.advance_visible_section_candidate_demands(1)
	var fresh_candidate_job: Dictionary = replay_lifecycle._production_candidate_jobs.get(replay_key, {})
	var fresh_candidate: Dictionary = fresh_candidate_job.get("candidate", {})
	var replay_checks := {"initial_candidate_installed":replay_install.get("status") == "installed",
		"demand_withdrawn":replay_withdrawal.get("status") == "withdrawn",
		"invalidation_deferred_but_retained":replay_invalidation.get("status") == "deferred"
			and bool(replay_invalidation_row.get("dirtyRetained", false)),
		"dirty_source_identity_retained":replay_dirty.has("ecology:prop:replay"),
		"owner_unloaded":unload_count == 1,
		"stale_replay_not_queued":load_count == 0 and replay_request_blocked
			and no_stale_replay_job,
		"queued_and_active_legacy_replay_cancelled":no_legacy_replay_work,
		"late_active_legacy_replay_blocked_at_advance":dirty_advance_blocked,
		"fresh_demand_reassembles":fresh_admission.get("attemptCount") == 1
			and int(fresh_candidate.get("generation", 0)) > int(replay_indexed.get("generation", 0)),
		"dirty_marker_survives_until_receipt":replay_lifecycle._dirty_source_sections.has(replay_key)}
	check("withdrawn_source_invalidation_survives_unload_and_blocks_stale_replay",
		not replay_checks.values().has(false),
		{"checks":replay_checks, "withdrawal":replay_withdrawal,
			"invalidation":replay_invalidation, "dirtySources":replay_dirty,
			"unloadCount":unload_count, "loadReplayCount":load_count,
			"legacyReplayQueue":replay_lifecycle._replay_queue,
			"legacyReplaySetContainsSection":replay_lifecycle._replay_set.has(replay_key),
			"legacyActiveReplayEmpty":replay_lifecycle._active_replay.is_empty(),
			"legacyReplaySessionCancelled":legacy_active_session.cancelled,
			"dirtyReplayAdvance":dirty_replay_advance,
			"lateLegacyReplaySessionCancelled":late_legacy_session.cancelled,
			"freshAdmission":fresh_admission,
			"freshCandidateGeneration":fresh_candidate.get("generation"),
			"staleGeneration":replay_indexed.get("generation")})
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
