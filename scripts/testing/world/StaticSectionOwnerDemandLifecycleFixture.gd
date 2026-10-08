extends SceneTree

const CoordinatorScript := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const PacketOwner := preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstallSession := preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const SECTION := Vector3i.ZERO
const WORLD := "owner-demand-lifecycle-fixture-world"
const PROVIDER_ID := "owner-demand-fixture"
const REPORT_ENV := "VOXEL_STATIC_SECTION_OWNER_DEMAND_REPORT"

class MainRuntimeHarness extends "res://scripts/Main.gd":
	func _ready() -> void: pass
	func _process(_delta: float) -> void: pass
	func _physics_process(_delta: float) -> void: pass

class FixtureProvider extends RefCounted:
	const WORLD_ID := "owner-demand-lifecycle-fixture-world"
	const PROVIDER_KEY := "owner-demand-fixture"
	const SECTION_KEY := Vector3i.ZERO
	const SOURCE_PART_ID := "owner-demand-fixture:part"
	const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
	const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
	const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
	var world_id := WORLD_ID
	var mesh: Mesh
	var material: Material
	var batch_key := ""
	var compatibility: Dictionary = {}

	func _source_revision() -> String:
		var fingerprint: Dictionary = MeshFingerprint.inspect(mesh)
		if fingerprint.get("status") != "ready" or not material is StandardMaterial3D:
			return ""
		return Marshalls.raw_to_base64(var_to_bytes([
			"owner-demand-source-r1",
			String(fingerprint.get("contentDigest", "")),
			(material as StandardMaterial3D).albedo_color])).sha256_text()

	func capture_static_section_sources(request_world_id: String,
		section_keys: Array) -> Dictionary:
		if request_world_id != world_id or section_keys != [SECTION_KEY]:
			return {"status":"failed", "reason":"unexpected_fixture_census_query"}
		var revision := _source_revision()
		if revision.is_empty():
			return {"status":"pending", "reason":"fixture_mesh_or_material_unavailable",
				"retryable":true}
		var ids: Array[String] = [SOURCE_PART_ID]
		ids.make_read_only()
		var row := {"status":"complete", "coverageRevision":"fixture-coverage-r1",
			"sourcePartIds":ids}
		row.make_read_only()
		var revisions := {SOURCE_PART_ID:revision}
		revisions.make_read_only()
		var sections := {SECTION_KEY:row}
		sections.make_read_only()
		var result := {"status":"complete", "worldId":world_id,
			"authorityRevision":"fixture-authority-r1",
			"sourceRevisions":revisions, "sections":sections}
		result.make_read_only()
		return result

	func capture_static_section_contribution(census: Dictionary,
		section_key: Vector3i) -> Dictionary:
		var revision := _source_revision()
		var expected: Variant = census.get("expectedContributorsBySection", {}).get(section_key, [])
		if census.get("status") != "complete" or census.get("worldId") != world_id \
				or section_key != SECTION_KEY or SOURCE_PART_ID not in expected \
				or revision.is_empty() \
				or String(census.get("sourceRevisions", {}).get(SOURCE_PART_ID, "")) != revision:
			return {"status":"pending", "reason":"fixture_contribution_census_stale",
				"retryable":true}
		var values: Array[float] = []
		for value: float in Attributes.encode(Transform3D.IDENTITY, Color.WHITE):
			values.append(value)
		values.make_read_only()
		var transform := Transform3D(Basis.IDENTITY, Vector3(2.0, 0.0, 2.0))
		var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
			"sourceId":SOURCE_PART_ID, "sourcePartId":SOURCE_PART_ID,
			"sourceRevision":revision,
			"ownerCell":Grid.logical_owner_cell_for_world_position(transform.origin),
			"sourceToWorld":transform,
			"meshLocalBounds":mesh.get_aabb(), "batchKey":batch_key,
			"segmentId":SOURCE_PART_ID + ":mesh", "buffer":values,
			"instanceCount":1}
		input.make_read_only()
		var inputs: Array[Dictionary] = [input]
		inputs.make_read_only()
		var authority_revisions := {SOURCE_PART_ID:revision}
		authority_revisions.make_read_only()
		var compatibility_by_key := {batch_key:compatibility}
		compatibility_by_key.make_read_only()
		var materials := {"fixture:material":material}
		materials.make_read_only()
		var meshes := {"owner-demand:mesh":mesh}
		meshes.make_read_only()
		var binding := {"material":material, "mesh":mesh}
		binding.make_read_only()
		var resources := {batch_key:binding}
		resources.make_read_only()
		var contribution := {"providerId":PROVIDER_KEY, "sectionKey":section_key,
			"coverageRevision":String(census.providerCoverageRevisions[PROVIDER_KEY][section_key]),
			"authorityRevision":String(census.providerSnapshotRevisions[PROVIDER_KEY]),
			"authoritySourceRevisions":authority_revisions, "inputs":inputs,
			"compatibilityByKey":compatibility_by_key,
			"materialBindings":materials, "meshBindings":meshes,
			"resourceBindings":resources}
		contribution.make_read_only()
		return {"status":"ready", "contribution":contribution}

var checks: Dictionary = {}
var evidence: Dictionary = {}
var coordinator: Object
var main_harness: MainRuntimeHarness
var provider: FixtureProvider


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("ChunkRenderPacketBackend"):
		_check("native_backend_available", false, "ChunkRenderPacketBackend is not registered")
		_finish()
		return
	main_harness = MainRuntimeHarness.new()
	main_harness.name = "StaticSectionOwnerDemandMainHarness"
	root.add_child(main_harness)
	current_scene = main_harness
	var render_root := Node3D.new()
	render_root.name = "StaticSectionRenderOwners"
	main_harness.add_child(render_root)
	main_harness.static_section_render_root = render_root
	coordinator = CoordinatorScript.new()
	main_harness.world_static_section_coordinator = coordinator
	var configured: Dictionary = coordinator.call("configure", WORLD)
	var required_providers: Array[String] = [PROVIDER_ID]
	required_providers.make_read_only()
	var roster: Dictionary = coordinator.call("configure_source_roster", required_providers)
	provider = FixtureProvider.new()
	_build_fixture_batch()
	var registration: Dictionary = coordinator.call("register_source_provider",
		PROVIDER_ID, provider, "capture_static_section_sources")
	_check("isolated_main_and_fixture_provider_configured",
		configured.get("status") == "ready" and roster.get("status") == "ready" \
		and registration.get("status") == "ready", {
			"world":configured, "roster":roster, "provider":registration})
	if not checks["isolated_main_and_fixture_provider_configured"]:
		_finish()
		return
	var owner_cell := Grid.chunk_key_for_section(SECTION)
	var entered_initial := int(main_harness.call("sync_static_section_render_owner_demands",
		{owner_cell:true}))
	var admission: Dictionary = await _admit_compiled_candidate(coordinator, SECTION, 1)
	var candidate_jobs: Variant = coordinator.get("_production_candidate_jobs")
	var initial_job: Dictionary = candidate_jobs.get(SECTION, {}) \
		if candidate_jobs is Dictionary else {}
	var candidate: Dictionary = initial_job.get("candidate", {})
	var initial_install: Dictionary = {"status":"not_started"}
	var owner: Node3D
	var backend: Node
	for turn in range(120):
		initial_install = coordinator.call("advance_complete_section_candidate", SECTION, 8)
		var owner_result: Dictionary = main_harness.call(
			"get_static_section_render_owner", owner_cell, false)
		owner = owner_result.get("owner") as Node3D
		backend = owner_result.get("backend") as Node
		if initial_install.get("status") == "installed":
			break
		if initial_install.get("status") in ["failed", "pending_owner"]:
			break
		await process_frame
	var generation := int(candidate.get("generation", 0))
	var digest := String(candidate.get("contentManifestDigest", ""))
	var slot := InstallSession.slot_id(WORLD, SECTION)
	var prior_owner_id := owner.get_instance_id() if is_instance_valid(owner) else 0
	var prior_backend_id := backend.get_instance_id() if is_instance_valid(backend) else 0
	var initial_native_receipt: bool = is_instance_valid(backend) and generation > 0 \
		and initial_install.get("status") == "installed" \
		and bool(backend.call("receipt_installed", slot, generation,
			"%s:%d" % [WORLD, generation], digest))
	var initial_receipt: Dictionary = coordinator.get(
		"_production_candidate_receipts").get(SECTION, {})
	_check("production_candidate_installs_with_current_native_receipt",
		entered_initial == 1 and admission.get("status") == "queued" \
		and candidate.is_read_only() and initial_native_receipt \
		and not initial_receipt.is_empty() \
		and int(initial_receipt.get("chunkInstanceId", 0)) == prior_owner_id \
		and int(initial_receipt.get("backendInstanceId", 0)) == prior_backend_id, {
			"initialDemandEntered":entered_initial,
			"admissionStatus":String(admission.get("status", "")),
			"admissionReason":String(admission.get("reason", "")),
			"installStatus":String(initial_install.get("status", "")),
			"installReason":String(initial_install.get("reason", "")),
			"candidateGeneration":generation,
			"candidateDigest":digest,
			"ownerId":prior_owner_id,
			"backendId":prior_backend_id,
			"receipt":initial_receipt})
	if not checks["production_candidate_installs_with_current_native_receipt"]:
		_finish()
		return

	var demand_exit_count := int(main_harness.call(
		"sync_static_section_render_owner_demands", {}))
	var retired_count := int(main_harness.call("prune_static_section_render_owners", {}))
	var retained_candidates: Variant = coordinator.get("_production_candidates_by_section")
	var receipts_after_exit: Variant = coordinator.get("_production_candidate_receipts")
	var old_receipt_current := bool(coordinator.call("_receipt_is_live",
		candidate, initial_receipt))
	var candidate_retained := retained_candidates is Dictionary \
		and (retained_candidates as Dictionary).has(SECTION) \
		and candidate.is_read_only() \
		and String((retained_candidates as Dictionary)[SECTION].get(
			"contentManifestDigest", "")) == digest
	var production_receipt_invalidated := receipts_after_exit is Dictionary \
		and not (receipts_after_exit as Dictionary).has(SECTION) \
		and not old_receipt_current
	_check("main_demand_exit_invalidates_receipt_and_retains_candidate",
		demand_exit_count == 0 and retired_count == 1 \
		and not main_harness.get("static_section_render_owners").has(owner_cell) \
		and candidate_retained and production_receipt_invalidated, {
			"demandExitEdges":demand_exit_count,
			"retiredOwners":retired_count,
			"candidateRetained":candidate_retained,
			"productionReceiptEntryRemoved":receipts_after_exit is Dictionary \
				and not (receipts_after_exit as Dictionary).has(SECTION),
			"priorReceiptStillCurrent":old_receipt_current,
			"candidateDigest":digest})
	if not checks["main_demand_exit_invalidates_receipt_and_retains_candidate"]:
		_finish()
		return

	# Force the next coordinator advance to reach Main's lazy-owner resolver and
	# remain pending without an owner. No frame yield occurs between job admission
	# and the second demand exit below.
	var pending_entered := int(main_harness.call(
		"sync_static_section_render_owner_demands", {owner_cell:true}))
	main_harness.static_section_render_root = null
	var pending_owner: Dictionary = coordinator.call(
		"advance_complete_section_candidate", SECTION, 1)
	main_harness.static_section_render_root = render_root
	var pending_jobs_before: Variant = coordinator.get("_production_candidate_jobs")
	var pending_job_before: Dictionary = pending_jobs_before.get(SECTION, {}) \
		if pending_jobs_before is Dictionary else {}
	var pending_job_count_before: int = pending_jobs_before.size() \
		if pending_jobs_before is Dictionary else -1
	var pending_job_has_candidate: bool = pending_job_before.get("candidate") == \
		(retained_candidates as Dictionary).get(SECTION)
	var pending_session: Variant = pending_job_before.get("session")
	var pending_session_empty: bool = pending_session == null
	var demand_exit_without_owner := int(main_harness.call(
		"sync_static_section_render_owner_demands", {}))
	var pending_jobs_after: Variant = coordinator.get("_production_candidate_jobs")
	var receipts_after_pending_exit: Variant = coordinator.get(
		"_production_candidate_receipts")
	var candidate_after_pending_exit: Variant = coordinator.get(
		"_production_candidates_by_section")
	var pending_job_cancelled: bool = pending_jobs_after is Dictionary \
		and not (pending_jobs_after as Dictionary).has(SECTION)
	var pending_job_count_after: int = pending_jobs_after.size() \
		if pending_jobs_after is Dictionary else -1
	var candidate_still_retained: bool = candidate_after_pending_exit is Dictionary \
		and (candidate_after_pending_exit as Dictionary).get(SECTION) == candidate
	var no_production_receipt := receipts_after_pending_exit is Dictionary \
		and not (receipts_after_pending_exit as Dictionary).has(SECTION)
	var installed_history: Variant = coordinator.get("_installed_receipts")
	var stale_history: Dictionary = installed_history.get(SECTION, {}) \
		if installed_history is Dictionary else {}
	var stale_history_not_current := stale_history.is_empty() \
		or not bool(coordinator.call("_receipt_is_live", candidate, stale_history))
	var no_owner_after_pending_exit: bool = not main_harness.get(
		"static_section_render_owners").has(owner_cell)
	var no_demand_install_attempt: Dictionary = coordinator.call(
		"advance_complete_section_candidate", SECTION, 1)
	var no_stale_install_without_demand: bool = no_demand_install_attempt.get("status") == "idle" \
		and not main_harness.get("static_section_render_owners").has(owner_cell)
	var pending_cancel_passed: bool = pending_entered == 1 \
		and pending_owner.get("status") == "pending_owner" \
		and pending_job_has_candidate and pending_session_empty \
		and pending_job_count_before == 1 and demand_exit_without_owner == 0 \
		and pending_job_cancelled and pending_job_count_after == 0 \
		and candidate_still_retained and no_production_receipt \
		and stale_history_not_current and no_owner_after_pending_exit \
		and no_stale_install_without_demand
	_check("ownerless_demand_exit_cancels_pending_owner_job_only",
		pending_cancel_passed, {
		"pendingDemandEntered":pending_entered,
		"pendingOwnerStatus":String(pending_owner.get("status", "")),
		"pendingOwnerReason":String(pending_owner.get("reason", "")),
			"jobPresentBeforeExit":not pending_job_before.is_empty(),
			"jobCountBeforeExit":pending_job_count_before,
			"jobReferencesSameImmutableCandidate":pending_job_has_candidate,
			"sessionNotCreatedBeforeOwner":pending_session_empty,
			"ownerlessDemandExitEdge":demand_exit_without_owner,
			"jobRemoved":pending_job_cancelled,
			"jobCountAfterExit":pending_job_count_after,
		"noDemandInstallStatus":String(no_demand_install_attempt.get("status", "")),
			"staleJobCannotInstallWithoutDemand":no_stale_install_without_demand,
			"candidateStillRetained":candidate_still_retained,
			"productionReceiptAbsent":no_production_receipt,
			"legacyInstalledReceiptRecordCurrent":not stale_history_not_current,
			"ownerStillAbsent":no_owner_after_pending_exit,
			"scope":"synthetic provider and one Main-owned section; no normal world startup or visual/gameplay acceptance"})
	if not pending_cancel_passed:
		_finish()
		return

	# The old owner is outside demand. Allow it to finish deferred destruction,
	# then re-enter demand and require a new exact owner/backend receipt.
	await process_frame
	await process_frame
	var old_owner_freed := not is_instance_valid(owner)
	var replay_entered := int(main_harness.call(
		"sync_static_section_render_owner_demands", {owner_cell:true}))
	var replay_install: Dictionary = {"status":"not_started"}
	var replay_owner: Node3D
	var replay_backend: Node
	var replay_receipt: Dictionary = {}
	for replay_turn in range(120):
		replay_install = coordinator.call("advance_complete_section_candidate", SECTION, 8)
		var replay_owner_result: Dictionary = main_harness.call(
			"get_static_section_render_owner", owner_cell, false)
		replay_owner = replay_owner_result.get("owner") as Node3D
		replay_backend = replay_owner_result.get("backend") as Node
		var current_receipts: Variant = coordinator.get("_production_candidate_receipts")
		replay_receipt = current_receipts.get(SECTION, {}) \
			if current_receipts is Dictionary else {}
		if replay_install.get("status") == "installed":
			break
		if replay_install.get("status") in ["failed", "pending_owner"]:
			break
		await process_frame
	var replay_native_current: bool = is_instance_valid(replay_owner) \
		and is_instance_valid(replay_backend) \
		and replay_receipt.get("status") == "installed" \
		and int(replay_receipt.get("chunkInstanceId", 0)) == replay_owner.get_instance_id() \
		and int(replay_receipt.get("backendInstanceId", 0)) == replay_backend.get_instance_id() \
		and int(replay_receipt.get("generation", 0)) == generation \
		and String(replay_receipt.get("contentManifestDigest", "")) == digest \
		and bool(replay_backend.call("receipt_installed", slot, generation,
			"%s:%d" % [WORLD, generation], digest))
	var replay_passed: bool = old_owner_freed and replay_entered == 1 \
		and replay_install.get("status") == "installed" \
		and is_instance_valid(replay_owner) and replay_owner.get_instance_id() != prior_owner_id \
		and is_instance_valid(replay_backend) and replay_backend.get_instance_id() != prior_backend_id \
		and replay_native_current
	_check("reentry_replays_candidate_to_fresh_native_owner_receipt", replay_passed, {
		"oldOwnerFreed":old_owner_freed,
		"demandReentered":replay_entered,
		"installStatus":String(replay_install.get("status", "")),
		"installReason":String(replay_install.get("reason", "")),
		"priorOwnerId":prior_owner_id,
		"replayOwnerId":replay_owner.get_instance_id() \
			if is_instance_valid(replay_owner) else 0,
		"priorBackendId":prior_backend_id,
		"replayBackendId":replay_backend.get_instance_id() \
			if is_instance_valid(replay_backend) else 0,
		"receiptStatus":String(replay_receipt.get("status", "")),
		"receiptGeneration":int(replay_receipt.get("generation", 0)),
		"receiptManifestDigest":String(replay_receipt.get("contentManifestDigest", "")),
		"nativeReceiptCurrent":replay_native_current})

	_finish()


func _build_fixture_batch() -> void:
	provider.mesh = ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, 0.0, -0.5), Vector3(0.5, 0.0, -0.5), Vector3(0.0, 0.0, 0.5)])
	(provider.mesh as ArrayMesh).add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	provider.material = StandardMaterial3D.new()
	(provider.material as StandardMaterial3D).albedo_color = Color(0.25, 0.55, 0.35)
	var fingerprint: Dictionary = MeshFingerprint.inspect(provider.mesh)
	var resource_key := "owner-demand:mesh"
	var pipeline := "owner-demand-lifecycle-v1"
	var mesh_key := "%s|pipeline=%s|layer=opaque|sort=none" % [resource_key, pipeline]
	var raw := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":"fixture:material", "renderTier":"detail",
		"meshResourceKey":resource_key, "meshKey":mesh_key,
		"meshContentDigest":String(fingerprint.get("contentDigest", "")),
		"meshLocalBounds":provider.mesh.get_aabb(), "pipelineRevision":pipeline,
		"renderLayer":"opaque", "translucentSortPolicy":"none",
		"castShadows":true, "visibilityRangeEnd":100.0, "fadeMargin":0.0}
	provider.batch_key = SnapshotBuilder.batch_compatibility_key(raw)
	raw["batchKey"] = provider.batch_key
	raw["compatibilityKey"] = provider.batch_key
	raw.make_read_only()
	provider.compatibility = raw


func _check(name: String, passed: bool, detail: Variant) -> void:
	checks[name] = passed
	evidence[name] = detail


func _finish() -> void:
	var main_weak: WeakRef
	var owner_weaks: Array[WeakRef] = []
	var report_path := OS.get_environment(REPORT_ENV)
	if is_instance_valid(main_harness):
		main_weak = weakref(main_harness)
		var owners: Dictionary = main_harness.get("static_section_render_owners")
		for owner_value: Variant in owners.values():
			var owner := owner_value as Node3D
			if is_instance_valid(owner):
				owner_weaks.append(weakref(owner))
		main_harness.call("clear_static_section_render_owners")
		main_harness.queue_free()
		await process_frame
		await process_frame
	main_harness = null
	coordinator = null
	provider = null
	var owners_freed := true
	for owner_weak: WeakRef in owner_weaks:
		owners_freed = owners_freed and owner_weak.get_ref() == null
	var main_freed := main_weak == null or main_weak.get_ref() == null
	var cleanup_passed := main_freed and owners_freed
	_check("fixture_teardown_frees_Main_and_native_owner_nodes", cleanup_passed, {
		"mainFreed":main_freed, "trackedOwnerCount":owner_weaks.size(),
		"ownersFreed":owners_freed})
	var passed := checks.size() > 0 and not checks.values().has(false)
	var report := {"schema":"static-section-owner-demand-lifecycle/v1",
		"evidenceLevel":"isolated_Main_owner_lifecycle_contract",
		"stageStatus":"preparatory_only_stage_1_and_full_stage_2_open",
		"passed":passed, "checks":checks, "evidence":evidence,
		"doesNotProve":["normal Main startup or world streaming",
			"production provider/source parity", "visual continuity or gameplay",
			"Stage 1 completion", "full Stage 2 exit"]}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	quit(0 if passed else 1)

## Admission now queues a native worker. Wait for its current identity receipt
## before the fixture inspects candidate data or controls upload/frame stages.
func _admit_compiled_candidate(owner_coordinator, section_key: Vector3i,
		generation: int) -> Dictionary:
	var admission: Dictionary = owner_coordinator.call(
		"assemble_and_submit_complete_section_candidate", section_key, generation)
	if admission.get("status") != "queued": return admission
	for wait_frame in range(1200):
		var outcomes: Array = owner_coordinator.call("_advance_section_compiles", 1)
		for outcome: Dictionary in outcomes:
			if outcome.get("sectionKey") == section_key and int(outcome.get("generation", -1)) == generation:
				if outcome.get("status") != "queued": return outcome
		var jobs: Dictionary = owner_coordinator.get("_production_candidate_jobs")
		var candidate: Dictionary = jobs.get(section_key, {}).get("candidate", {})
		if int(candidate.get("generation", -1)) == generation:
			var receipt: Dictionary = candidate.get("nativeCompileReceipt", {})
			if receipt.get("status") != "compiled":
				return {"status":"failed", "reason":"fixture_native_compile_receipt_missing"}
			var accepted := admission.duplicate(false)
			accepted["acceptedStage"] = "native_compile_accepted"
			accepted["compileWaitFrames"] = wait_frame
			accepted["nativeCompileReceipt"] = receipt
			return accepted
		await process_frame
	return {"status":"failed", "reason":"fixture_native_compile_wait_exhausted",
		"stage":"native_compile", "sectionKey":section_key, "generation":generation}
