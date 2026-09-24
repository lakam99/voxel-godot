extends SceneTree

const MAIN = preload("res://scripts/Main.gd")
const STRUCTURES = preload("res://scripts/StructureSystem.gd")
const WORLD = preload("res://scripts/WorldGenerationSystem.gd")
const REQUEST = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const PAGES = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const PLANNER = preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const BROKER = preload("res://scripts/terrain/NativeTerrainArtifactRequests.gd")
const OWNER = preload("res://scripts/terrain/NativeResidentCollisionOwner.gd")
const MEMORY_POLICY = preload("res://scripts/terrain/NativeCollisionMemoryPolicy.gd")
const MEMORY_ADMISSION = preload("res://scripts/terrain/NativeCollisionMemoryAdmission.gd")
const EDIT_PLAN = preload("res://scripts/terrain/NativeTerrainEditRepublicationPlan.gd")
const PUBLICATION = preload("res://scripts/terrain/NativeTerrainCollisionPublicationRuntime.gd")

# The production runtime-owner facade is deliberately thin. This fixture
# delegates its N3 contracts to the real broker while keeping the source,
# coordinator, resident owner, memory ledger and physics bodies genuine.
class BrokerRuntimeFacade extends RefCounted:
	var broker
	var row_requests := 0
	var layout_calls := 0

	func _init(value) -> void:
		broker = value

	func advance_collision_artifacts() -> Dictionary:
		return broker.advance()

	func request_collision_artifact(block: Vector3i) -> Dictionary:
		return broker.request_block(block)

	func collision_window_layout() -> Dictionary:
		return broker.collision_window_layout()

	func collision_window_layout_ticket() -> Dictionary:
		layout_calls += 1
		var layout: Dictionary = broker.collision_window_layout()
		return broker.collision_window_layout_ticket() if layout.get("status") == "ready" \
			else layout

	func collision_window_source(id: Vector3i, token: String) -> Dictionary:
		return broker.collision_window_source(id, token)

	func acknowledge_collision_window_retired(token: String,
			receipt: Dictionary) -> Dictionary:
		return broker.acknowledge_collision_window_retired(token, receipt)

	func claim_collision_window_retirement(token: String, layout_token: String,
			epoch: String) -> Dictionary:
		return broker.claim_collision_window_retirement(token, layout_token, epoch)

	func validate_collision_window_retirement(token: String, lease: String,
			epoch: String) -> Dictionary:
		return broker.validate_collision_window_retirement(token, lease, epoch)

	func abort_collision_window_retirement(token: String, lease: String,
			epoch: String) -> Dictionary:
		return broker.abort_collision_window_retirement(token, lease, epoch)

func _init() -> void:
	call_deferred("_run")

func _observe_work(runtime: Node, maxima: Dictionary) -> void:
	var step: Dictionary = runtime.work_step_snapshot()
	for key in ["layoutChecks", "rowSnapshots", "windowsAdvanced", "artifactRequests"]:
		maxima[key] = maxi(int(maxima.get(key, 0)), int(step.get(key, 0)))

func _memory(epoch: String):
	var policy = MEMORY_POLICY.new()
	var configured: Dictionary = policy.configure({
		"maxVerticesPerRow":65536, "verticesPerShape":768,
		"rowEntryBytes":1, "bodyEntryBytes":1, "shapeEntryBytes":1,
		"physicsPayloadMultiplier":1, "maxRowsPerWindow":4096,
		"maxWindowChargedBytes":400000000,
		"maxAggregateChargedBytes":800000000,
		"maxReservations":8192})
	if configured.get("status") != "ready": return null
	var admission = MEMORY_ADMISSION.new()
	return admission if admission.setup(policy, epoch,
		"n5-runtime-fixture:%d" % Time.get_ticks_usec()).get("status") == "ready" \
		else null

func _run() -> void:
	var evidence := {}
	var main = MAIN.new()
	main.seed_text = "n5-collision-publication-runtime"
	main.seed_hash = main.hash_string(main.seed_text)
	main.setup_noise()
	main.structure_system = STRUCTURES.new()
	main.structure_system.citadel_terrain_admission.configure(main.seed_text, {},
		{"regionCells":main.STRUCTURE_REGION_CELLS,
			"spawnChance":main.STRUCTURE_SPAWN_CHANCE})
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	var source_request: Dictionary = REQUEST.from_main_with_save_volume(main,
		{"schemaVersion":1, "sectionSize":16, "revision":0, "sections":[]})
	var backend = ClassDB.instantiate("NativeWorldBackend")
	if backend == null or source_request.get("status") != "ready":
		_finish(false, {"reason":"native_source_unavailable"})
		return
	var initialized: Dictionary = backend.initialize_from_save_v2(source_request.request)
	var pages = PAGES.new()
	var page_setup: Dictionary = pages.setup(backend,
		main.structure_system.citadel_terrain_admission)
	var planner = PLANNER.new()
	var planner_setup: Dictionary = planner.setup(91)
	var surface: float = main.world_generation_system.surface_y_for_cell(Vector3i.ZERO)
	var base_y := floori(float(floori(surface / main.CELL)) / 16.0)
	var planned: Dictionary = planner.replace_sources(
		{"position":Vector3.ZERO, "distance":0}, [], [], [],
		Vector2i(base_y * 16, (base_y + 1) * 16))
	var broker = BROKER.new()
	var broker_setup: Dictionary = broker.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, planner, main.CELL,
		91, OWNER.MAX_RESIDENT)
	evidence["setup"] = {"native":initialized.get("status"),
		"pages":page_setup.get("status"), "planner":planner_setup.get("status"),
		"plan":planned.get("status"), "broker":broker_setup.get("status")}
	var facade = BrokerRuntimeFacade.new(broker)
	var scene_root := Node3D.new()
	root.add_child(scene_root)
	var memory = _memory("n5-runtime-fixture")
	var runtime = PUBLICATION.new()
	# setup-before-tree is intentional: _ready must preserve active processing.
	var setup: Dictionary = runtime.setup(facade, scene_root, memory)
	evidence["setup"]["publication"] = setup.get("status")
	scene_root.add_child(runtime)
	var coordinator = runtime.get("_coordinator")
	var guard_actor: CharacterBody3D = null
	var guard_motion := Vector3.ZERO
	var early_admission_denied := false
	var first_pending := false
	var first_unpublished := false
	var first_unpublished_token := ""
	var first_unpublished_owner: Node3D = null
	var first_publish_pending_reason := ""
	var edit_state := {"materialId":3, "biomeId":13, "fluidId":0,
		"solid":true, "density":1.5, "light":Vector2i.ZERO,
		"metadata":{"saveDelta":true,"source":"terrain_edit"},
		"blockId":"n5-runtime-edit", "editReason":"contract"}
	var distant_cell := Vector3i(1000, -1, 1000)
	var distant_commit: Dictionary = {}
	var verified_distant: Dictionary = {}
	var edit_during_initial := false
	var initial_local_identity: Dictionary = {}
	var work_maxima := {"layoutChecks":0, "rowSnapshots":0,
		"windowsAdvanced":0, "artifactRequests":0}
	var initial: Dictionary = {}
	for frame in range(900):
		var snapshot: Dictionary = runtime.closure_snapshot()
		if snapshot.get("status") == "pending": first_pending = true
		for entry in (runtime.get("_windows") as Dictionary).values():
			if not bool(entry.get("published", false)):
				if guard_actor == null:
					guard_actor = CharacterBody3D.new()
					guard_actor.position = entry.bounds.position \
						- Vector3(main.CELL * 8.0, 0, 0)
					var guard_shape := CollisionShape3D.new()
					var guard_sphere := SphereShape3D.new()
					guard_sphere.radius = main.CELL * 0.05
					guard_shape.shape = guard_sphere
					guard_actor.add_child(guard_shape)
					scene_root.add_child(guard_actor)
					guard_motion = entry.bounds.get_center() - guard_actor.position
				early_admission_denied = early_admission_denied \
					or not coordinator.admit_motion(guard_actor, guard_motion)
				first_unpublished = true
				first_unpublished_token = String(entry.get("window", {}).get("windowToken", ""))
				first_unpublished_owner = entry.get("owner")
				if String(snapshot.get("reason", "")) in ["actor_census_in_progress",
						"physical_publication_pending", "resident_collision_not_current"]:
					first_publish_pending_reason = String(snapshot.reason)
				if not edit_during_initial:
					initial_local_identity = entry.get("window", {}).get("identity", {}).duplicate(true)
					distant_commit = backend.commit_durable_cells({
						"schema":"n3-native-durable-cell-transaction/v1",
						"transactionId":"n5-runtime:distant",
						"expectedRevision":0,
						"operations":[{"kind":"set", "cell":distant_cell,
							"state":edit_state}]})
					var distant_plan: Dictionary = EDIT_PLAN.for_committed_cells(
						[distant_cell], distant_commit.get("affectedSections", []), 1,
						String(backend.status().get("sourceIdentity", {}).get("hex", "")))
					verified_distant = broker.observe_verified_durable_edit(
						distant_commit, distant_plan)
					edit_during_initial = true
		_observe_work(runtime, work_maxima)
		if snapshot.get("status") == "ready" \
				and int(snapshot.get("identity", {}).get("sourceRevision", -1)) == 1:
			initial = snapshot
			break
		await process_frame
	var initial_windows: Dictionary = runtime.get("_windows")
	var initial_owner: Node3D = null
	var initial_token := ""
	if not initial_windows.is_empty():
		var initial_entry: Dictionary = initial_windows.values()[0]
		initial_owner = initial_entry.get("owner")
		initial_token = String(initial_entry.get("window", {}).get("windowToken", ""))
	var first_published := bool(initial_windows.values()[0].get("published", false)) \
		if not initial_windows.is_empty() else false
	var first_same_token := not first_unpublished_token.is_empty() \
		and first_unpublished_token == initial_token
	var first_same_owner := first_unpublished_owner != null \
		and first_unpublished_owner == initial_owner
	var initial_final_closure: Dictionary = runtime.closure_snapshot()
	var initial_receipt: Dictionary = initial_final_closure.get("receipt", {})
	var initial_layout: Dictionary = broker.collision_window_layout()
	var proof_window: Dictionary = initial_layout.get("windows", [{}])[0]
	var proof_receipt: Dictionary = initial_owner.physical_receipt_for_layout(
		proof_window.get("identity", {}), proof_window.get("localCurrentProof", {}),
		initial_layout.get("identity", {})) if initial_owner != null else {}
	var proof_matches: bool = bool(proof_receipt.get("ready", false)) \
		and proof_receipt.get("provenance", {}).get("requestIdentity") \
			== proof_window.get("identity", {}) \
		and proof_receipt.get("provenance", {}).get("globalLayoutIdentity") \
			== initial_layout.get("identity", {}) \
		and proof_receipt.get("provenance", {}).get("localCurrentProof") \
			== proof_window.get("localCurrentProof", {})
	var barrier_debug := {"aggregate":coordinator.aggregate_readiness(
		initial_layout.get("identity", {})).get("status", ""),
		"runtimeIdentity":runtime.get("_identity").get("sourceRevision", -1),
		"runtimeWindowCursor":runtime.get("_window_cursor")}
	if not initial_windows.is_empty():
		barrier_debug["entryIdentity"] = initial_windows.values()[0].get(
			"identity", {}).get("sourceRevision", -1)
		var entry_barrier: RefCounted = initial_windows.values()[0].get("barrier")
		barrier_debug["entryBarrierActive"] = entry_barrier != null \
			and entry_barrier.is_active()
	for id in (coordinator.get("_barriers") as Dictionary):
		var active_barrier: RefCounted = (coordinator.get("_barriers") as Dictionary)[id]
		barrier_debug["currentActive"] = active_barrier.is_active()
		barrier_debug["currentIdentity"] = (coordinator.get("_barrier_identities") as Dictionary).get(id, {}).get("sourceRevision", -1)
		barrier_debug["currentClearance"] = active_barrier.clearance(
			initial_layout.get("identity", {})).get("reason", "clear")
	for retired_record in (coordinator.get("_retired_barriers") as Array):
		var retired_barrier: RefCounted = retired_record.barrier
		barrier_debug["retiredActive"] = retired_barrier.is_active()
		barrier_debug["retiredIdentity"] = retired_record.get("identity", {}).get("sourceRevision", -1)
		barrier_debug["retiredClearance"] = retired_barrier.clearance(
			retired_record.identity).get("reason", "clear")
	var initial_aggregate_ready: bool = barrier_debug.aggregate == "ready"
	var initial_barriers_released: bool = coordinator.active_barrier_count() == 0
	var admitted_after_ready: bool = coordinator.admit_motion(guard_actor,
		guard_motion) if guard_actor != null else false
	evidence["initial"] = {"status":initial.get("status", "pending"),
		"pendingObserved":first_pending, "unpublishedObserved":first_unpublished,
		"publicationPendingReason":first_publish_pending_reason,
		"sameTokenPublished":first_same_token,
		"sameOwnerPublished":first_same_owner,
		"published":first_published,
		"distantEditDuringPending":edit_during_initial,
		"localRevisionDuringPending":initial_local_identity.get("sourceRevision", -1),
		"globalRevisionAfterPublish":initial.get("identity", {}).get("sourceRevision", -1),
		"finalReason":initial_final_closure.get("reason", ""),
		"receiptReason":initial_receipt.get("reason", ""),
		"rebindReason":initial_receipt.get("sourceTicketRebind", {}).get("reason", ""),
		"layoutRevision":initial_layout.get("identity", {}).get("sourceRevision", -1),
		"layoutProofKind":initial_layout.get("windows", [{}])[0] \
			.get("localCurrentProof", {}).get("kind", ""),
		"proofReceiptReady":proof_receipt.get("ready", false),
		"proofMatchesLocalAndGlobalIdentity":proof_matches,
		"earlyAdmissionDenied":early_admission_denied,
		"aggregateReady":initial_aggregate_ready,
		"barrierCountAfterReady":coordinator.active_barrier_count(),
		"admittedAfterReady":admitted_after_ready,
		"barriers":barrier_debug,
		"ownerCount":initial_windows.size(), "token":initial_token}
	if initial.get("status") != "ready":
		var early_drain: Dictionary = await runtime.stop_and_drain()
		var early_broker_stop: Dictionary = broker.stop()
		for frame in range(500):
			if early_broker_stop.get("status") == "ready": break
			await process_frame
			early_broker_stop = broker.drain_step()
		evidence["drain"] = {"runtime":early_drain.get("status"),
			"broker":early_broker_stop.get("status")}
		scene_root.queue_free()
		main.free()
		_finish(false, evidence)
		return
	var retained: Dictionary = {}
	var retained_layout: Dictionary = {}
	for frame in range(900):
		_observe_work(runtime, work_maxima)
		retained_layout = broker.collision_window_layout()
		var snapshot: Dictionary = runtime.closure_snapshot()
		if snapshot.get("status") == "ready" \
				and int(snapshot.get("identity", {}).get("sourceRevision", -1)) == 1:
			retained = snapshot
			break
		await process_frame
	var retained_owner: Node3D = null
	var retained_token := ""
	if not (runtime.get("_windows") as Dictionary).is_empty():
		var retained_entry: Dictionary = (runtime.get("_windows") as Dictionary).values()[0]
		retained_owner = retained_entry.get("owner")
		retained_token = String(retained_entry.get("window", {}).get("windowToken", ""))
	evidence["retained"] = {"status":retained.get("status", "pending"),
		"revision":retained.get("identity", {}).get("sourceRevision", -1),
		"localRevision":retained_layout.get("windows", [{}])[0].get("identity", {}) \
			.get("sourceRevision", -1),
		"sameOwner":retained_owner == initial_owner,
		"sameToken":retained_token == initial_token,
		"verifiedEdit":verified_distant.get("status")}
	var changed_cell := Vector3i(0, base_y * 16, 0)
	var changed_commit: Dictionary = backend.commit_durable_cells({
		"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"n5-runtime:local",
		"expectedRevision":1,
		"operations":[{"kind":"set", "cell":changed_cell,
			"state":edit_state}]})
	var changed_plan: Dictionary = EDIT_PLAN.for_committed_cells(
		[changed_cell], changed_commit.get("affectedSections", []), 2,
		String(backend.status().get("sourceIdentity", {}).get("hex", "")))
	var verified_changed: Dictionary = broker.observe_verified_durable_edit(
		changed_commit, changed_plan)
	var replacement_pending := false
	var old_owner_preserved := false
	var replacement: Dictionary = {}
	for frame in range(900):
		_observe_work(runtime, work_maxima)
		var entries: Dictionary = runtime.get("_windows")
		if not entries.is_empty():
			var entry: Dictionary = entries.values()[0]
			if not (entry.get("candidate", {}) as Dictionary).is_empty():
				replacement_pending = true
				old_owner_preserved = entry.get("owner") == initial_owner
		var snapshot: Dictionary = runtime.closure_snapshot()
		if snapshot.get("status") == "ready" \
				and int(snapshot.get("identity", {}).get("sourceRevision", -1)) == 2:
			replacement = snapshot
			break
		await process_frame
	var replaced_owner: Node3D = null
	if not (runtime.get("_windows") as Dictionary).is_empty():
		replaced_owner = (runtime.get("_windows") as Dictionary).values()[0].get("owner")
	var owner_changed := replaced_owner != initial_owner
	evidence["replacement"] = {"status":replacement.get("status", "pending"),
		"revision":replacement.get("identity", {}).get("sourceRevision", -1),
		"stagedObserved":replacement_pending,
		"oldOwnerPreservedWhileStaged":old_owner_preserved,
		"ownerChanged":owner_changed,
		"verifiedEdit":verified_changed.get("status")}
	# Start another real replacement, then reverse demand while the candidate
	# awaits publication. The broker ticket changes; the coordinator must
	# drain only the obsolete stage and leave the committed owner intact.
	var reversal_state := edit_state.duplicate(true)
	reversal_state.materialId = 4
	var reversal_commit: Dictionary = backend.commit_durable_cells({
		"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"n5-runtime:reversal",
		"expectedRevision":2,
		"operations":[{"kind":"set", "cell":changed_cell,
			"state":reversal_state}]})
	var reversal_plan: Dictionary = EDIT_PLAN.for_committed_cells(
		[changed_cell], reversal_commit.get("affectedSections", []), 3,
		String(backend.status().get("sourceIdentity", {}).get("hex", "")))
	var verified_reversal: Dictionary = broker.observe_verified_durable_edit(
		reversal_commit, reversal_plan)
	var candidate_seen := false
	var cancel_observed := false
	var incumbent_held_during_cancel := false
	var ticket_drift_seen := false
	var candidate_epoch := ""
	var far_plan: Dictionary = {}
	for frame in range(900):
		_observe_work(runtime, work_maxima)
		var entries: Dictionary = runtime.get("_windows")
		if not entries.is_empty():
			var entry: Dictionary = entries.values()[0]
			var candidate: Dictionary = entry.get("candidate", {})
			if not candidate_seen and not candidate.is_empty():
				candidate_seen = true
				candidate_epoch = String(candidate.owner.retirement_owner_epoch())
				incumbent_held_during_cancel = entry.get("owner") == replaced_owner
				far_plan = planner.replace_sources(
					{"position":Vector3(main.CELL * 512.0, 0, 0), "distance":0},
					[], [], [], Vector2i(base_y * 16, (base_y + 1) * 16))
			if candidate_seen and candidate.is_empty() \
					and (runtime.get("_coordinator").get("_staged_owners") as Dictionary).is_empty():
				cancel_observed = true
				incumbent_held_during_cancel = incumbent_held_during_cancel \
					and entry.get("owner") == replaced_owner
				break
		var reason := String(runtime.closure_snapshot().get("reason", ""))
		if reason in ["layout_ticket_changed_during_candidate_publication",
				"layout_ticket_changed_during_window_publication"]:
			ticket_drift_seen = true
		await process_frame
	evidence["reversal"] = {"verifiedEdit":verified_reversal.get("status"),
		"candidateSeen":candidate_seen, "candidateEpoch":candidate_epoch,
		"farPlan":far_plan.get("status"), "ticketDriftSeen":ticket_drift_seen,
		"candidateCancelled":cancel_observed,
		"incumbentPreserved":incumbent_held_during_cancel,
		"finalClosure":runtime.closure_snapshot().get("reason", ""),
		"acknowledgement":runtime.closure_snapshot().get("cancellation", {}) \
			.get("acknowledgement", {}),
		"stageCount":(runtime.get("_coordinator").get("_staged_owners") as Dictionary).size(),
		"windowCount":(runtime.get("_windows") as Dictionary).size(),
		"runtimeTicket":runtime.get("_ticket"),
		"brokerTicket":broker.collision_window_layout_ticket().get("ticket", "")}
	var drained: Dictionary = await runtime.stop_and_drain()
	var broker_stop: Dictionary = broker.stop()
	for frame in range(500):
		if broker_stop.get("status") == "ready": break
		await process_frame
		broker_stop = broker.drain_step()
	scene_root.queue_free()
	main.free()
	var checks := {"nativeReady":initialized.get("status") == "ready",
		"pagesReady":page_setup.get("status") == "ready",
		"plannerReady":planner_setup.get("status") == "ready",
		"demandReady":planned.get("status") == "ready",
		"brokerReady":broker_setup.get("status") == "ready",
		"runtimeReady":setup.get("status") == "ready",
		"firstPending":first_pending,
		"firstUnpublished":first_unpublished,
		"specificPublicationPending":not first_publish_pending_reason.is_empty(),
		"sameFirstTokenPublished":first_same_token,
		"sameFirstOwnerPublished":first_same_owner,
		"firstOwnerPublished":first_published,
		"earlyAdmissionDenied":early_admission_denied,
		"initialAggregateReady":initial_aggregate_ready,
		"initialBarriersReleased":initial_barriers_released,
		"admittedAfterReady":admitted_after_ready,
		"editOverlappedFirstPublish":edit_during_initial,
		"firstLocalIdentityRetained":int(initial_local_identity.get("sourceRevision", -1)) == 0,
		"firstGlobalIdentityRebound":int(initial.get("identity", {}).get(
			"sourceRevision", -1)) == 1,
		"exactLocalGlobalProofReceipt":proof_matches,
		"firstPhysicalReady":initial.get("status") == "ready",
		"distantEditVerified":verified_distant.get("status") == "ready",
		"retainedReady":retained.get("status") == "ready",
		"sameOwner":retained_owner == initial_owner,
		"sameToken":retained_token == initial_token,
		"localEditVerified":verified_changed.get("status") == "ready",
		"candidateStaged":replacement_pending,
		"oldOwnerPreserved":old_owner_preserved,
		"replacementReady":replacement.get("status") == "ready",
		"ownerChanged":owner_changed,
		"reversalEditVerified":verified_reversal.get("status") == "ready",
		"reversalCandidateSeen":candidate_seen,
		"reversalDemandAccepted":far_plan.get("status") == "ready",
		"reversalTicketDrift":ticket_drift_seen,
		"reversalCandidateCancelled":cancel_observed,
		"reversalIncumbentPreserved":incumbent_held_during_cancel,
		"runtimeDrained":drained.get("status") == "ready",
		"brokerDrained":broker_stop.get("status") == "ready"}
	checks["layoutStepBounded"] = int(work_maxima.layoutChecks) \
		<= PUBLICATION.MAX_LAYOUT_CHECKS_PER_FRAME
	checks["rowStepBounded"] = int(work_maxima.rowSnapshots) \
		<= PUBLICATION.MAX_ROW_SNAPSHOTS_PER_FRAME
	checks["windowStepBounded"] = int(work_maxima.windowsAdvanced) \
		<= PUBLICATION.MAX_WINDOWS_PER_FRAME
	checks["requestStepBounded"] = int(work_maxima.artifactRequests) \
		<= PUBLICATION.MAX_ARTIFACT_REQUESTS_PER_FRAME
	var passed := not checks.values().has(false)
	evidence["checks"] = checks
	evidence["drain"] = {"runtime":drained.get("status"),
		"broker":broker_stop.get("status")}
	evidence["workMaxima"] = work_maxima
	_finish(passed, evidence)

func _finish(passed: bool, evidence: Dictionary) -> void:
	var report := {"passed":passed, "evidence":evidence}
	var path := OS.get_environment("N5_COLLISION_PUBLICATION_RUNTIME_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
	print("N5_COLLISION_PUBLICATION_RUNTIME " + ("PASS" if passed else "FAIL"))
	quit(0 if passed else 1)
