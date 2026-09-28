extends SceneTree

const MAIN = preload("res://scripts/Main.gd")
const STRUCTURES = preload("res://scripts/StructureSystem.gd")
const WORLD = preload("res://scripts/WorldGenerationSystem.gd")
const REQUEST = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const PAGES = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const PLANNER = preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const BROKER = preload("res://scripts/terrain/NativeTerrainArtifactRequests.gd")
const OWNER = preload("res://scripts/terrain/NativeResidentCollisionOwner.gd")
const COORDINATOR = preload("res://scripts/terrain/NativeWindowedCollisionCoordinator.gd")
const MEMORY_POLICY = preload("res://scripts/terrain/NativeCollisionMemoryPolicy.gd")
const MEMORY_ADMISSION = preload("res://scripts/terrain/NativeCollisionMemoryAdmission.gd")
const EDIT_PLAN = preload("res://scripts/terrain/NativeTerrainEditRepublicationPlan.gd")
const RETIREMENT_RECEIPT = preload("res://scripts/terrain/NativeCollisionRetirementReceipt.gd")

class CaptureAckBroker extends RefCounted:
	var delegate: Object
	var captured := {}
	func _init(value: Object) -> void: delegate = value
	func collision_window_layout() -> Dictionary:
		return delegate.collision_window_layout()
	func claim_collision_window_retirement(token: String, layout_token: String,
			epoch: String) -> Dictionary:
		return delegate.claim_collision_window_retirement(token, layout_token, epoch)
	func validate_collision_window_retirement(token: String, lease: String,
			epoch: String) -> Dictionary:
		return delegate.validate_collision_window_retirement(token, lease, epoch)
	func acknowledge_collision_window_retired(token: String,
			receipt: Dictionary) -> Dictionary:
		captured = {"token":token, "receipt":receipt.duplicate(true)}
		return {"status":"pending", "reason":"fixture_ack_captured"}

func _init() -> void: call_deferred("_run")

func _layout(broker: Object, revision: int, prior_token: String = "") -> Dictionary:
	var layout := {}
	for frame in range(500):
		broker.advance()
		layout = broker.collision_window_layout()
		if layout.get("status") == "ready" \
				and int(layout.get("identity", {}).get("sourceRevision", -1)) == revision \
				and (prior_token.is_empty() or layout.get("layoutToken") != prior_token):
			return layout
		await process_frame
	return layout

func _edit(backend: Object, broker: Object, revision: int,
		cell: Vector3i) -> Dictionary:
	var committed: Dictionary = backend.commit_durable_cells({
		"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"unpublished-candidate:%d" % revision,
		"expectedRevision":revision - 1,
		"operations":[{"kind":"set", "cell":cell, "state":{
			"materialId":revision + 3, "biomeId":13, "fluidId":0,
			"solid":true, "density":1.5, "light":Vector2i.ZERO,
			"metadata":{"saveDelta":true,"source":"terrain_edit"},
			"blockId":"unpublished-candidate:%d" % revision,
			"editReason":"contract"}}]})
	var plan: Dictionary = EDIT_PLAN.for_committed_cells([cell],
		committed.get("affectedSections", []), revision,
		String(backend.status().get("sourceIdentity", {}).get("hex", "")))
	var observed: Dictionary = broker.observe_verified_durable_edit(committed, plan)
	return {"commit":committed, "observed":observed}

func _run() -> void:
	var main = MAIN.new()
	main.seed_text = "n5-unpublished-candidate-retirement"
	main.seed_hash = main.hash_string(main.seed_text)
	main.setup_noise()
	main.structure_system = STRUCTURES.new()
	main.structure_system.citadel_terrain_admission.configure(main.seed_text, {},
		{"regionCells":main.STRUCTURE_REGION_CELLS,
			"spawnChance":main.STRUCTURE_SPAWN_CHANCE})
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	var request: Dictionary = REQUEST.from_main_with_save_volume(main,
		{"schemaVersion":1, "sectionSize":16, "revision":0, "sections":[]})
	var backend = ClassDB.instantiate("NativeWorldBackend")
	if backend == null or request.get("status") != "ready":
		_finish(false, {"reason":"native_source_unavailable"})
		return
	var initialized: Dictionary = backend.initialize_from_save_v2(request.request)
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
	var required: Dictionary = planner.required_collision_mesh_blocks()
	var broker = BROKER.new()
	var broker_setup: Dictionary = broker.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, planner, main.CELL, 91,
		OWNER.MAX_RESIDENT)
	for block: Vector3i in required.get("blocks", []): broker.request_block(block)
	var layout: Dictionary = await _layout(broker, 0)
	var window: Dictionary = layout.get("windows", [{}])[0]
	var facade_status: Dictionary = broker.collision_window_source(
		window.id, layout.layoutToken)
	var facade = facade_status.get("source")
	var snapshot: Dictionary = facade.collision_source_snapshot() if facade != null else {}
	for frame in range(500):
		if snapshot.get("status") == "ready": break
		broker.advance()
		await process_frame
		snapshot = facade.collision_source_snapshot()
	var rows: Array[Dictionary] = []
	for block: Vector3i in window.blocks:
		var row: Dictionary = facade.collision_artifact_row_snapshot(block,
			layout.identity)
		if row.get("status") == "ready": rows.append(row.row)
	var root_3d := Node3D.new()
	root.add_child(root_3d)
	var coordinator = COORDINATOR.new()
	root_3d.add_child(coordinator)
	var policy = MEMORY_POLICY.new()
	var policy_setup: Dictionary = policy.configure({
		"maxVerticesPerRow":65536, "verticesPerShape":768,
		"rowEntryBytes":1, "bodyEntryBytes":1, "shapeEntryBytes":1,
		"physicsPayloadMultiplier":1, "maxRowsPerWindow":4096,
		"maxWindowChargedBytes":400000000,
		"maxAggregateChargedBytes":800000000, "maxReservations":8192})
	var memory = MEMORY_ADMISSION.new()
	var memory_setup: Dictionary = memory.setup(policy, "unpublished-fixture",
		"unpublished:%d" % Time.get_ticks_usec())
	var coordinator_setup: Dictionary = coordinator.setup(broker, root_3d, memory)
	var incumbent = OWNER.new()
	coordinator.add_child(incumbent)
	var bound: bool = incumbent.bind_source(facade)
	var registered: Dictionary = coordinator.register_window(window, incumbent)
	var bounds: AABB = rows[0].bounds if not rows.is_empty() \
		else AABB(Vector3.ZERO, Vector3.ONE)
	for row in rows: bounds = bounds.merge(row.bounds)
	var held: Dictionary = coordinator.begin_window_barrier(window, bounds,
		layout.identity)
	var barrier: RefCounted = held.get("barrier")
	var census: Dictionary = held.get("census", {})
	while census.get("status") == "pending":
		await process_frame
		census = barrier.census_progress(layout.identity)
	var published: Dictionary = await incumbent.publish({
		"schema":"n5-resident-collision-publication/v1",
		"identity":layout.identity, "residentBlocks":window.blocks,
		"affectedBlocks":window.blocks, "rows":rows}, barrier)
	var first_epoch := String(registered.get("physicalOwnerEpoch", ""))
	var first_token := String(window.windowToken)
	var edited: Dictionary = _edit(backend, broker, 1,
		Vector3i(0, base_y * 16, 0))
	var replacement_layout: Dictionary = await _layout(broker, 1,
		String(layout.layoutToken))
	var replacement_window: Dictionary = replacement_layout.get("windows", [{}])[0]
	var candidate = OWNER.new()
	coordinator.add_child(candidate)
	var staged: Dictionary = coordinator.stage_window_replacement(
		replacement_window, candidate)
	var candidate_epoch := String(staged.get("physicalOwnerEpoch", ""))
	var first_candidate_unpublished: bool = candidate._live.is_empty()
	var wrong_epoch: Dictionary = await coordinator.cancel_staged_replacement(
		replacement_window.id, "foreign-epoch")
	var active_layout_cancel: Dictionary = await coordinator.cancel_staged_replacement(
		replacement_window.id, candidate_epoch)
	var retry_candidate = OWNER.new()
	coordinator.add_child(retry_candidate)
	var restaged: Dictionary = coordinator.stage_window_replacement(
		replacement_window, retry_candidate)
	var retry_candidate_unpublished: bool = retry_candidate._live.is_empty()
	candidate_epoch = String(restaged.get("physicalOwnerEpoch", ""))
	var edited_again: Dictionary = _edit(backend, broker, 2,
		Vector3i(0, base_y * 16, 0))
	var retired_layout: Dictionary = await _layout(broker, 2,
		String(replacement_layout.layoutToken))
	var capture := CaptureAckBroker.new(broker)
	coordinator._broker = capture
	var deferred: Dictionary = await coordinator.cancel_staged_replacement(
		replacement_window.id, candidate_epoch)
	coordinator._broker = broker
	var receipt: Dictionary = capture.captured.get("receipt", {})
	var token := String(replacement_window.windowToken)
	var wrong_token := receipt.duplicate(true)
	wrong_token["candidateWindowToken"] = "foreign-token"
	var wrong_lease := receipt.duplicate(true)
	wrong_lease["retirementLeaseId"] = "foreign-lease"
	var wrong_owner := receipt.duplicate(true)
	wrong_owner["physicalOwnerEpoch"] = first_epoch
	var wrong_identity := receipt.duplicate(true)
	wrong_identity["candidateRecordIdentity"] = layout.identity
	var nonzero_memory := receipt.duplicate(true)
	var memory_receipt: Dictionary = nonzero_memory.get("memoryAdmission", {}).duplicate(true)
	memory_receipt["chargedBytes"] = 1
	nonzero_memory["memoryAdmission"] = memory_receipt
	var pending_body := receipt.duplicate(true)
	pending_body["remainingBodies"] = 1
	var pending_entry := receipt.duplicate(true)
	pending_entry["remainingPendingEntries"] = 1
	var pending_disposal := receipt.duplicate(true)
	pending_disposal["remainingDisposalRetryEntries"] = 1
	broker._active_window_tokens[token] = true
	var reactivated: Dictionary = broker.acknowledge_collision_window_retired(
		token, receipt)
	broker._active_window_tokens.erase(token)
	var negatives := {"wrongToken":broker.acknowledge_collision_window_retired(token,
		wrong_token), "wrongLease":broker.acknowledge_collision_window_retired(token,
		wrong_lease), "wrongEpoch":broker.acknowledge_collision_window_retired(token,
		wrong_owner), "wrongIdentity":broker.acknowledge_collision_window_retired(
		token, wrong_identity), "chargedMemory":broker.acknowledge_collision_window_retired(
		token, nonzero_memory), "pendingBody":broker.acknowledge_collision_window_retired(
		token, pending_body), "pendingEntry":broker.acknowledge_collision_window_retired(
		token, pending_entry), "pendingDisposal":broker.acknowledge_collision_window_retired(
		token, pending_disposal), "reactivated":reactivated}
	var record: Dictionary = broker._window_records.get(token, {})
	var lease: Dictionary = broker._retirement_leases.get(token, {})
	# An all-empty *published* window still declares every resident block. Its
	# zero-body receipt belongs to the strict path, not the staged-empty path.
	var all_empty_published := {"status":"ready", "drained":true,
		"retirementLeaseId":lease.get("leaseId", ""),
		"physicalOwnerEpoch":lease.get("physicalOwnerEpoch", ""),
		"windowToken":token, "identity":record.get("identity", {}),
		"sourceIdentity":record.get("sourceIdentity", {}),
		"membershipProvenance":record.get("membershipProvenance", {}),
		"residentBlockCount":(record.get("blocks", []) as Array).size(),
		"residentBlocks":record.get("blocks", []),
		"requiredResidentBlocks":record.get("blocks", []),
		"remainingBodies":0, "remainingPendingEntries":0,
		"remainingLiveEntries":0, "sourceReleased":true,
		"barrierOwnershipReleased":true}
	var published_strict: bool = RETIREMENT_RECEIPT.matches_record(
		token, all_empty_published, record, lease)
	var published_marker_rejected := all_empty_published.duplicate(true)
	published_marker_rejected["retirementKind"] = "unpublished_staged_candidate/v1"
	var published_cannot_use_unpublished: bool = \
		not RETIREMENT_RECEIPT.matches_unpublished_candidate(token,
			published_marker_rejected, record, lease) \
		and not RETIREMENT_RECEIPT.matches_record(token,
			published_marker_rejected, record, lease)
	var third_edit: Dictionary = _edit(backend, broker, 3,
		Vector3i(0, base_y * 16, 0))
	var drifted_layout: Dictionary = await _layout(broker, 3,
		String(retired_layout.layoutToken))
	var same_lease := String(coordinator._staged_owners.get(replacement_window.id,
		{}).get("retirementLeaseId", "")) == String(receipt.get("retirementLeaseId", ""))
	var cancelled: Dictionary = await coordinator.cancel_staged_replacement(
		replacement_window.id, candidate_epoch)
	var replay: Dictionary = broker.acknowledge_collision_window_retired(token, receipt)
	var incumbent_preserved: bool = coordinator._owners.get(window.id) == incumbent \
		and String(coordinator._owner_epochs.get(window.id, "")) == first_epoch \
		and String(coordinator._window_tokens.get(window.id, "")) == first_token \
		and incumbent.is_inside_tree() and not incumbent._live.is_empty()
	var broker_retired: bool = not broker._window_records.has(token)
	var coordinator_stop: Dictionary = await coordinator.stop_and_drain()
	var broker_stop: Dictionary = broker.stop()
	for frame in range(500):
		if broker_stop.get("status") == "ready": break
		await process_frame
		broker_stop = broker.drain_step()
	root_3d.queue_free()
	main.free()
	var checks := {"setup":initialized.get("status") == "ready" \
		and page_setup.get("status") == "ready" \
		and planner_setup.get("status") == "ready" \
		and planned.get("status") == "ready" \
		and broker_setup.get("status") == "ready" \
		and policy_setup.get("status") == "ready" \
		and memory_setup.get("status") == "ready" \
		and coordinator_setup.get("status") == "ready",
		"incumbentPublished":bound and registered.get("status") == "ready" \
			and published.get("status") == "ready",
		"stageNeverPublished":staged.get("status") == "ready" \
			and first_candidate_unpublished,
		"foreignEpochRejected":wrong_epoch.get("status") == "failed",
		"activeTokenRetained":active_layout_cancel.get("status") == "ready" \
			and bool(active_layout_cancel.get("brokerRecordRetained", false)),
		"candidateRestaged":restaged.get("status") == "ready" \
			and retry_candidate_unpublished,
		"capturePending":deferred.get("status") == "pending" \
			and deferred.get("reason") == "physical_window_candidate_retirement_ack_pending" \
			and receipt.get("retirementKind") == "unpublished_staged_candidate/v1",
		"allForeignReceiptsRejected":true,
		"allEmptyPublishedUsesStrictReceipt":published_strict \
			and published_cannot_use_unpublished,
		"sameLeaseAcrossDrift":same_lease,
		"cancelled":cancelled.get("status") == "ready",
		"replayRejected":replay.get("status") == "failed",
		"brokerRetired":broker_retired,
		"incumbentPreserved":incumbent_preserved,
		"cleanDrain":coordinator_stop.get("status") == "ready" \
			and broker_stop.get("status") == "ready"}
	for result in negatives.values():
		if result.get("status") != "failed":
			checks["allForeignReceiptsRejected"] = false
	var passed := true
	for value in checks.values():
		if not bool(value): passed = false
	_finish(passed, {"checks":checks, "stage":staged,
		"activeCancel":active_layout_cancel, "deferred":deferred,
		"receipt":receipt, "negatives":negatives, "cancelled":cancelled,
		"replay":replay,
		"edits":[edited, edited_again, third_edit],
		"layouts":[replacement_layout.get("layoutToken", ""),
			retired_layout.get("layoutToken", ""), drifted_layout.get("layoutToken", "")],
		"drain":{"coordinator":coordinator_stop, "broker":broker_stop}})

func _finish(passed: bool, evidence: Dictionary) -> void:
	var path := OS.get_environment("N5_UNPUBLISHED_RETIREMENT_REPORT")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify({"passed":passed,
		"evidence":evidence}, "  "))
	quit(0 if passed else 1)
