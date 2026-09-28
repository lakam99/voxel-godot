extends Node3D

const OwnerScript = preload("res://scripts/terrain/NativeResidentCollisionOwner.gd")
const BarrierScript = preload("res://scripts/terrain/NativeCollisionAdmissionBarrier.gd")
const RetirementReceipt = preload("res://scripts/terrain/NativeCollisionRetirementReceipt.gd")
const AdmissionScript = preload("res://scripts/terrain/NativeCollisionMemoryAdmission.gd")
const PolicyScript = preload("res://scripts/terrain/NativeCollisionMemoryPolicy.gd")

class FakeSource:
	extends RefCounted
	var current := {}
	var rows := {}
	var row_query_hook: Callable
	var ticket_query_hook: Callable
	var ticket_checks := 0
	var ticket_snapshot_queries := 0
	func collision_source_ticket() -> Dictionary:
		ticket_snapshot_queries += 1
		var snapshot: Dictionary = current.duplicate(false)
		snapshot["ticket"] = _ticket_value()
		return snapshot
	func collision_source_ticket_current(ticket: String) -> bool:
		ticket_checks += 1
		if ticket_query_hook.is_valid(): ticket_query_hook.call(ticket)
		return _ticket_value() == ticket
	func collision_source_artifact_key(block: Vector3i, ticket: String) -> Dictionary:
		if _ticket_value() != ticket:
			return {"status":"pending", "reason":"fake_ticket_stale"}
		var artifacts: Dictionary = current.get("artifacts", {})
		if not artifacts.has(block): return {"status":"pending"}
		return {"status":"ready", "artifactKey":String(artifacts[block])}
	func _ticket_value() -> String:
		var identity: Dictionary = current.get("identity", {})
		var membership: Dictionary = current.get("membershipProvenance", {})
		var source_identity: Dictionary = current.get("sourceIdentity", {})
		return "fixture-ticket-%d-%d-%d-%s-%s" % [
			int(identity.get("sourceRevision", -1)),
			int(identity.get("cancellationEpoch", -1)),
			int(membership.get("demandRevision", -1)),
			String(membership.get("closureToken", "")),
			String(source_identity.get("hex", ""))]
	func collision_source_snapshot() -> Dictionary:
		return current.duplicate(true)
	func collision_artifact_row(block: Vector3i, identity: Dictionary) -> Dictionary:
		if row_query_hook.is_valid():
			row_query_hook.call(block)
		if current.get("identity") != identity or not rows.has(block):
			return {"status": "pending"}
		return {"status": "ready", "row": (rows[block] as Dictionary).duplicate(true)}
	func collision_artifact_row_snapshot(block: Vector3i,
			identity: Dictionary) -> Dictionary:
		if row_query_hook.is_valid():
			row_query_hook.call(block)
		if current.get("identity") != identity or not rows.has(block):
			return {"status": "pending"}
		return {"status": "ready",
			"row": (rows[block] as Dictionary).duplicate(false)}

class DeferredReleaseFault:
	extends RefCounted
	var _limits := {"maxReservations":8}
	var failures_remaining := 0
	var abort_registration_fails := false
	var reserve_calls := 0
	var defer_calls := 0
	var cancel_calls := 0
	var cancel_failures_remaining := 0
	var return_empty_token := false
	var abort_registration_calls := 0
	var ack_failures_remaining := 0
	var ack_calls := 0
	var mark_constructed_calls := 0
	var abort_body_ids_received: Array = []
	var cancel_body: Object
	var cancel_body_was_valid := false
	var reservation_count := 1
	var charged_bytes := 256
	var _ledger_epoch := "n5-dispose-fault-epoch"
	var _ledger_identity := "n5-dispose-fault-ledger"
	func reserve_candidate(_owner: String, _window: String, _id: String,
			_rows: Array) -> Dictionary:
		reserve_calls += 1
		if return_empty_token:
			return {"status":"ready", "token":""}
		return {"status":"failed", "reason":"unused_fixture_api"}
	func mark_candidate_constructed(_token: String, _owner: String,
			_body_ids: Array) -> Dictionary:
		mark_constructed_calls += 1
		return {"status":"failed", "reason":"fixture_mark_constructed_rejected"}
	func register_candidate_abort_body(_token: String, _owner: String,
			body_ids: Array) -> Dictionary:
		abort_registration_calls += 1
		abort_body_ids_received = body_ids.duplicate()
		if abort_registration_fails:
			return {"status":"failed", "reason":"fixture_abort_registration_rejected"}
		if body_ids.size() != 1 or int(body_ids[0]) <= 0:
			return {"status":"failed", "reason":"fixture_abort_body_identity_invalid"}
		return {"status":"ready", "state":"candidate_constructed",
			"bodyInstanceIds":body_ids.duplicate()}
	func commit_live(_token: String, _owner: String) -> Dictionary:
		return {"status":"failed", "reason":"unused_fixture_api"}
	func cancel_unconstructed(_token: String, _owner: String) -> Dictionary:
		cancel_calls += 1
		cancel_body_was_valid = is_instance_valid(cancel_body)
		if cancel_failures_remaining > 0:
			cancel_failures_remaining -= 1
			return {"status":"failed", "reason":"fixture_cancel_rejected"}
		reservation_count = maxi(0, reservation_count - 1)
		charged_bytes = 0 if reservation_count == 0 else charged_bytes
		return {"status":"ready"}
	func defer_release(_token: String, _owner: String, _physics: int,
			_process: int) -> Dictionary:
		defer_calls += 1
		if failures_remaining > 0:
			failures_remaining -= 1
			return {"status":"failed", "reason":"fixture_defer_rejected"}
		return {"status":"ready"}
	func acknowledge_deferred_release(_token: String, _owner: String,
			_ack: Dictionary) -> Dictionary:
		ack_calls += 1
		if ack_failures_remaining > 0:
			ack_failures_remaining -= 1
			return {"status":"failed", "reason":"fixture_ack_rejected"}
		reservation_count = maxi(0, reservation_count - 1)
		charged_bytes = 0 if reservation_count == 0 else charged_bytes
		return {"status":"ready"}
	func snapshot() -> Dictionary:
		return {"ledgerEpoch":_ledger_epoch,
			"ledgerIdentity":_ledger_identity,
			"reservationCount":reservation_count,
			"totalChargedBytes":charged_bytes, "status":"ready"}
	func owner_reservation_receipt(_owner: String, _window: String) -> Dictionary:
		return {"status":"ready", "reservationCount":reservation_count,
			"chargedBytes":charged_bytes}
	func drain_receipt() -> Dictionary:
		return {"status":"ready"}
	func is_active() -> bool:
		return true

var _source := FakeSource.new()
var _owner: Node3D
var _actor: CharacterBody3D
var _started_usec := 0
var _captured_drains := {}


func _ready() -> void:
	_started_usec = Time.get_ticks_usec()
	call_deferred("_run")


func _run() -> void:
	var retirement_receipt_contract: Dictionary = _retirement_receipt_contract()
	_owner = OwnerScript.new()
	add_child(_owner)
	if not _owner.bind_source(_source):
		_finish(false, {"reason": "source_bind_failed"})
		return
	_actor = CharacterBody3D.new()
	_actor.position = Vector3(100, 0, 0)
	_actor.collision_mask = 2
	var actor_shape := CollisionShape3D.new()
	actor_shape.shape = BoxShape3D.new()
	_actor.add_child(actor_shape)
	add_child(_actor)
	var blocks: Array[Vector3i] = [Vector3i.ZERO, Vector3i(1, 0, 0)]
	var first := _identity(1)
	_source.current = _snapshot(first, blocks, "a1", "b1")
	var initial_rows := [_row(blocks[0], "a1", 0.5, first),
		_row(blocks[1], "b1", 0.5, first)]
	_source.rows = {blocks[0]: initial_rows[0], blocks[1]: initial_rows[1]}
	var startup_barrier = BarrierScript.new()
	var started: Dictionary = startup_barrier.begin(self, _owner, first,
		initial_rows[0].bounds.merge(initial_rows[1].bounds))
	while started.get("status") == "pending":
		await get_tree().process_frame
		started = startup_barrier.census_progress(first)
	var startup: Dictionary = await _owner.publish(_request(first, blocks, blocks,
		initial_rows), startup_barrier)
	var startup_ready: Dictionary = _owner.startup_readiness(first)
	var revision_invalidation: Dictionary = _owner.physical_receipt(first)
	var startup_released: bool = startup_barrier.release(first)
	_actor.position = Vector3(0.35, 2, 0.5)
	await get_tree().physics_frame
	var actor_contact: KinematicCollision3D = _actor.move_and_collide(Vector3(0, -4, 0))
	var actor_contact_detail := {"collision": actor_contact != null,
		"colliderIsStatic": actor_contact != null and actor_contact.get_collider() is StaticBody3D,
		"finalY": _actor.position.y}
	var actor_landed: bool = actor_contact != null and actor_contact.get_collider() is StaticBody3D \
		and _actor.position.y >= 0.45
	_actor.position = Vector3(100, 0, 0)
	await get_tree().physics_frame
	var second := _identity(2)
	var changed: Array[Vector3i] = [blocks[0]]
	_source.current = _snapshot(second, blocks, "a2", "b1")
	var old_revision_invalidated: bool = not bool(_owner.physical_receipt(first).get("ready", false))
	var second_row: Dictionary = _row(blocks[0], "a2", 1.0, second)
	_source.rows[blocks[0]] = second_row
	var edit_barrier = BarrierScript.new()
	var edit_started: Dictionary = edit_barrier.begin(self, _owner, second,
		second_row.bounds)
	while edit_started.get("status") == "pending":
		await get_tree().process_frame
		edit_started = edit_barrier.census_progress(second)
	var altered_row: Dictionary = second_row.duplicate(true)
	var altered_vertices: PackedVector3Array = altered_row.vertices
	altered_vertices[0] += Vector3(0.01, 0, 0)
	altered_row.vertices = altered_vertices
	var altered_candidate: Dictionary = await _owner.publish(_request(second, blocks,
		changed, [altered_row]), edit_barrier)
	_actor.position = Vector3(0.35, 2, 0.5)
	await get_tree().physics_frame
	var occupied_edit: Dictionary = await _owner.publish(_request(second, blocks,
		changed, [second_row]), edit_barrier)
	_actor.position = Vector3(100, 0, 0)
	await get_tree().physics_frame
	var edit: Dictionary = await _owner.publish(_request(second, blocks,
		changed, [second_row]), edit_barrier)
	var edit_window: Dictionary = _owner.affected_window_readiness(second,
		changed)
	var edit_released: bool = edit_barrier.release(second)
	var third := _identity(3)
	_source.current = _snapshot(third, blocks, "a3", "b1")
	var failure_row: Dictionary = _row(blocks[0], "a3", 2.0, third)
	_source.rows[blocks[0]] = failure_row
	failure_row.probeFrom = Vector3(1.5, 2.8, 0.5)
	failure_row.probeTo = Vector3(1.5, 0.2, 0.5)
	_source.rows[blocks[0]] = failure_row
	var rollback_barrier = BarrierScript.new()
	var rollback_started: Dictionary = rollback_barrier.begin(self, _owner, third,
		failure_row.bounds)
	while rollback_started.get("status") == "pending":
		await get_tree().process_frame
		rollback_started = rollback_barrier.census_progress(third)
	var rejected: Dictionary = await _owner.publish(_request(third, blocks,
		changed, [failure_row]), rollback_barrier)
	var stale_ready: Dictionary = _owner.startup_readiness(second)
	var premature_release: bool = rollback_barrier.release(third)
	var corrected_row: Dictionary = _row(blocks[0], "a3", 2.0, third)
	_source.rows[blocks[0]] = corrected_row
	var retried: Dictionary = await _owner.publish(_request(third, blocks,
		changed, [corrected_row]), rollback_barrier)
	var final_ready: Dictionary = _owner.startup_readiness(third)
	var final_released: bool = rollback_barrier.release(third)
	var staged_source := FakeSource.new()
	var staged_owner = OwnerScript.new()
	add_child(staged_owner)
	staged_owner.bind_source(staged_source)
	var staged_identity := _identity(1)
	var staged_blocks: Array[Vector3i] = []
	var staged_artifacts := {}
	var staged_rows: Array[Dictionary] = []
	for index in range(65):
		var block := Vector3i(1000 + index, 0, 0)
		staged_blocks.append(block)
		staged_artifacts[block] = "empty-%d" % index
		var x := float(block.x) * 3.0
		var empty_row := {"block": block, "artifactKey": staged_artifacts[block],
			"vertices": PackedVector3Array(), "bounds": AABB(Vector3(x, 0, 0),
				Vector3(3, 3, 3)), "probeFrom": Vector3(x + 0.35, 2.8, 0.5),
			"probeTo": Vector3(x + 0.35, 0.2, 0.5), "expectedHit": false}
		staged_rows.append(_source_fields(empty_row, staged_identity,
			{"hex": "65-empty-blocks"}))
		staged_source.rows[block] = staged_rows[-1]
	staged_source.current = {"status": "ready", "identity": staged_identity,
		"sourceIdentity": {"hex": "65-empty-blocks"},
		"sourceEpoch": staged_identity.sourceEpoch,
		"nativeRevision": staged_identity.sourceRevision,
		"ownerGeneration": staged_identity.ownerGeneration,
		"cancellationEpoch": staged_identity.cancellationEpoch,
		"requiredResidentBlocks": staged_blocks.duplicate(),
		"residentBlocks": staged_blocks.duplicate(),
		"membershipProvenance": {"authority": "pinned_demand", "demandRevision": 1,
			"closureToken": "65-block-closure"}, "artifacts": staged_artifacts}
	staged_source.current.artifacts.erase(staged_blocks[64])
	var missing_artifact: Dictionary = await staged_owner.publish(_request(staged_identity,
		staged_blocks, [staged_blocks[0]], [staged_rows[0]]))
	staged_source.current.artifacts[staged_blocks[64]] = "empty-64"
	var staged_barrier = BarrierScript.new()
	var stage_begin: Dictionary = staged_barrier.begin(self, staged_owner,
		staged_identity, staged_rows[0].bounds.merge(staged_rows[64].bounds))
	while stage_begin.get("status") == "pending":
		await get_tree().process_frame
		stage_begin = staged_barrier.census_progress(staged_identity)
	var first_batch: Array[Vector3i] = []
	var first_rows: Array[Dictionary] = []
	for index in range(64):
		first_batch.append(staged_blocks[index])
		first_rows.append(staged_rows[index])
	var staged_first: Dictionary = await staged_owner.publish(_request(staged_identity,
		staged_blocks, first_batch, first_rows), staged_barrier)
	var staged_early_ready: Dictionary = staged_owner.startup_readiness(staged_identity)
	var staged_early_release: bool = staged_barrier.release(staged_identity)
	var last_batch: Array[Vector3i] = [staged_blocks[64]]
	var staged_last: Dictionary = await staged_owner.publish(_request(staged_identity,
		staged_blocks, last_batch, [staged_rows[64]]), staged_barrier)
	var staged_final_ready: Dictionary = staged_owner.startup_readiness(staged_identity)
	var staged_final_release: bool = staged_barrier.release(staged_identity)
	var physical_health: Dictionary = await _physical_health_contract()
	var disposal_failure: Dictionary = await _disposal_failure_contract()
	var main_drain: Dictionary = await _owner.stop_and_drain()
	var staged_drain: Dictionary = await staged_owner.stop_and_drain()
	var stop_during_prepare: Dictionary = await _shutdown_case("prepare")
	var stop_during_post_prepare: Dictionary = await _shutdown_case(
		"post_prepare_validation")
	var stop_during_pre_switch: Dictionary = await _shutdown_case(
		"pre_switch_validation")
	var stop_during_ack: Dictionary = await _shutdown_case("ack_validation")
	var stop_during_rollback: Dictionary = await _shutdown_case("rollback")
	var stop_after_commit: Dictionary = await _shutdown_case("post_commit_health")
	var same_revision_drift: Dictionary = await _source_drift_case()
	var pre_switch_drift: Dictionary = await _pre_switch_drift_case()
	var mid_switch_drift: Dictionary = await _mid_switch_drift_case()
	var bounded_prepare: Dictionary = await _bounded_prepare_case()
	var bounded_drain: Dictionary = await _bounded_drain_case()
	var bounded_validation: Dictionary = await _bounded_validation_contract()
	var passed: bool = startup.get("status") == "ready" \
		and startup_ready.get("status") == "ready" and revision_invalidation.get("ready", false) \
		and old_revision_invalidated and startup_released \
		and actor_landed and altered_candidate.get("status") == "failed" \
		and altered_candidate.get("reason") == "candidate_source_row_mismatch" \
		and occupied_edit.get("status") == "pending" \
		and occupied_edit.get("reason") == "actor_clearance_pending" \
		and edit.get("status") == "ready" and edit_window.get("status") == "ready" \
		and edit_released and rejected.get("status") == "pending" \
		and bool(rejected.get("oldPhysicalRestored", false)) \
		and int(rejected.get("oldPhysicsFrame", -1)) >= 0 \
		and stale_ready.get("status") == "pending" and not premature_release \
		and retried.get("status") == "ready" \
		and final_ready.get("status") == "ready" and final_released \
		and staged_first.get("status") == "pending" \
		and missing_artifact.get("status") == "pending" \
		and missing_artifact.get("reason") == "required_resident_artifacts_incomplete" \
		and staged_early_ready.get("status") == "pending" and not staged_early_release \
		and staged_last.get("status") == "ready" \
		and staged_final_ready.get("status") == "ready" and staged_final_release \
		and bool(physical_health.get("passed", false)) \
		and bool(disposal_failure.get("passed", false)) \
		and main_drain.get("status") == "ready" and int(main_drain.get("remainingBodies", -1)) == 0 \
		and staged_drain.get("status") == "ready" and int(staged_drain.get("remainingBodies", -1)) == 0 \
		and bool(stop_during_prepare.get("passed", false)) \
		and bool(stop_during_post_prepare.get("passed", false)) \
		and bool(stop_during_pre_switch.get("passed", false)) \
		and bool(stop_during_ack.get("passed", false)) \
		and bool(stop_during_rollback.get("passed", false)) \
		and bool(stop_after_commit.get("passed", false)) \
		and bool(same_revision_drift.get("passed", false)) \
		and bool(pre_switch_drift.get("passed", false)) \
		and bool(mid_switch_drift.get("passed", false)) \
		and bool(bounded_prepare.get("passed", false)) \
		and bool(bounded_drain.get("passed", false)) \
		and bool(bounded_validation.get("passed", false)) \
		and bool(retirement_receipt_contract.get("passed", false))
	_finish(passed, {"startup": startup, "startupReady": startup_ready,
		"sourceTicket": {"initialReady":revision_invalidation,
			"oldRevisionInvalidated":old_revision_invalidated,
			"ticketChecks":_source.ticket_checks},
		"actorLanded": actor_landed, "actorContact": actor_contact_detail,
		"alteredCandidate": altered_candidate, "occupiedEdit": occupied_edit,
		"edit": edit, "editWindow": edit_window, "rejected": rejected,
		"oldReadinessAfterSourceChange": stale_ready,
		"prematureRelease": premature_release, "retry": retried,
		"finalReady": final_ready, "finalReleased": final_released,
		"staged65": {"missingArtifact": missing_artifact,
			"first": staged_first, "earlyReady": staged_early_ready,
			"earlyRelease": staged_early_release, "last": staged_last,
			"finalReady": staged_final_ready, "finalRelease": staged_final_release},
		"physicalHealth":physical_health,
		"disposalFailureRetention":disposal_failure,
		"drain": {"main": main_drain, "staged": staged_drain,
			"duringPrepare": stop_during_prepare,
			"duringPostPrepareValidation": stop_during_post_prepare,
			"duringPreSwitchValidation": stop_during_pre_switch,
			"duringAck": stop_during_ack,
			"duringRollback": stop_during_rollback,
			"postCommitHealthAwait": stop_after_commit},
		"sameRevisionDrift": same_revision_drift,
		"preSwitchDrift": pre_switch_drift,
		"midSwitchDrift": mid_switch_drift,
		"boundedPreparation": bounded_prepare,
		"boundedDrain": bounded_drain,
		"boundedValidation": bounded_validation,
		"retirementReceipt": retirement_receipt_contract})


func _physical_health_contract() -> Dictionary:
	var block := Vector3i(3000, 0, 0)
	var identity := _identity(51)
	var source_blocks: Array[Vector3i] = [block, block + Vector3i(1, 0, 0)]
	var health_source := FakeSource.new()
	health_source.current = _snapshot(identity, source_blocks,
		"health-body", "health-other")
	var layer_owner = _make_health_owner(health_source, block, identity)
	var baseline: Dictionary = layer_owner.physical_receipt(identity)
	var baseline_epoch: int = layer_owner.physical_readiness_epoch()
	var disabled: Dictionary = layer_owner.set_collision_entry_enabled(block, false)
	var disabled_before_ack: Dictionary = layer_owner.physical_receipt(identity)
	await get_tree().physics_frame
	var disabled_receipt: Dictionary = layer_owner.physical_receipt(identity)
	var reenabled: Dictionary = layer_owner.set_collision_entry_enabled(block, true)
	var reenabled_before_ack: Dictionary = layer_owner.physical_receipt(identity)
	await get_tree().physics_frame
	var restored: Dictionary = layer_owner.physical_receipt(identity)
	var shape_retired: Dictionary = layer_owner.retire_collision_entry_shape(block, 0)
	var shape_before_ack: Dictionary = layer_owner.physical_receipt(identity)
	await get_tree().physics_frame
	var shape_receipt: Dictionary = layer_owner.physical_receipt(identity)
	var shape_set_rejected: bool = not layer_owner._entry_shapes_usable(
		layer_owner._live[block], layer_owner._live[block].body)
	var body_health_source := FakeSource.new()
	body_health_source.current = _snapshot(identity, source_blocks,
		"health-body-free", "health-other")
	var body_owner = _make_health_owner(body_health_source, block, identity)
	var body_baseline: Dictionary = body_owner.physical_receipt(identity)
	var body_epoch: int = body_owner.physical_readiness_epoch()
	var body_ref: StaticBody3D = body_owner._live[block].body
	var body_retired: Dictionary = body_owner.retire_collision_entry(block)
	var disposal_disabled_before_queued_free: bool = is_instance_valid(body_ref) \
		and body_ref.collision_layer == 0 and body_ref.is_queued_for_deletion()
	var body_before_ack: Dictionary = body_owner.physical_receipt(identity)
	await get_tree().physics_frame
	var freed_receipt: Dictionary = body_owner.physical_receipt(identity)
	var layer_drain: Dictionary = await layer_owner.stop_and_drain()
	var body_drain: Dictionary = await body_owner.stop_and_drain()
	var passed: bool = baseline.get("ready") == true \
		and disabled.get("status") == "ready" \
		and layer_owner.physical_readiness_epoch() > baseline_epoch \
		and disabled_before_ack.get("ready") != true \
		and disabled_before_ack.get("reason") == "physical_health_physics_ack_pending" \
		and disabled_receipt.get("ready") != true \
		and disabled_receipt.get("reason") == "resident_collision_entry_unhealthy" \
		and disabled_receipt.get("healthValidation", {}).get("healthFailure") \
			== "physical_body_layer_mismatch" \
		and reenabled.get("status") == "ready" \
		and reenabled_before_ack.get("ready") != true \
		and reenabled_before_ack.get("reason") == "physical_health_physics_ack_pending" \
		and restored.get("ready") == true \
		and shape_retired.get("status") == "pending" \
		and shape_before_ack.get("ready") != true \
		and shape_before_ack.get("reason") == "physical_health_physics_ack_pending" \
		and shape_set_rejected \
		and shape_receipt.get("ready") != true \
		and shape_receipt.get("reason") == "resident_collision_entry_unhealthy" \
		and body_baseline.get("ready") == true and body_retired.get("status") == "pending" \
		and body_owner.physical_readiness_epoch() > body_epoch \
		and body_before_ack.get("ready") != true \
		and body_before_ack.get("reason") == "resident_collision_not_current" \
		and disposal_disabled_before_queued_free \
		and freed_receipt.get("ready") != true \
		and freed_receipt.get("reason") == "resident_collision_not_current" \
		and layer_drain.get("status") == "ready" and body_drain.get("status") == "ready"
	return {"passed":passed, "baseline":baseline, "disabled":disabled,
		"disabledBeforeAck":disabled_before_ack,
		"disabledReceipt":disabled_receipt, "reenabled":reenabled,
		"reenabledBeforeAck":reenabled_before_ack,
		"restored":restored, "shapeRetired":shape_retired,
		"shapeBeforeAck":shape_before_ack,
		"shapeSetRejected":shape_set_rejected, "shapeReceipt":shape_receipt,
		"bodyRetired":body_retired,
		"bodyDisposalDisabledBeforeQueuedFree":disposal_disabled_before_queued_free,
		"bodyBeforeAck":body_before_ack,
		"freedReceipt":freed_receipt, "layerDrain":layer_drain,
		"bodyDrain":body_drain}


func _disposal_failure_contract() -> Dictionary:
	var direct := _make_deferred_release_fault_owner(
		Vector3i(4100, 0, 0), "direct-retire-token")
	var direct_owner = direct.owner
	var direct_entry: Dictionary = direct.entry
	direct.admission.failures_remaining = 1
	var direct_result: Dictionary = direct_owner.retire_collision_entry(
		Vector3i(4100, 0, 0))
	var direct_retained: bool = direct_owner._live.has(Vector3i(4100, 0, 0)) \
		and int(direct_owner._disposal_retry_entries.size()) == 1 \
		and is_instance_valid(direct_entry.body) \
		and not direct_entry.body.is_queued_for_deletion()
	var direct_drain: Dictionary = await direct_owner.stop_and_drain()
	var transient_defer_recovered: bool = direct_result.get("status") == "failed" \
		and direct_drain.get("status") == "ready" \
		and direct.admission.defer_calls == 2

	var persistent_defer := _make_deferred_release_fault_owner(
		Vector3i(4107, 0, 0), "persistent-defer-token")
	persistent_defer.admission.failures_remaining = 10
	var persistent_defer_drain: Dictionary = \
		await persistent_defer.owner.stop_and_drain()
	var persistent_defer_blocked: bool = persistent_defer_drain.get("status") == "failed" \
		and persistent_defer_drain.get("blocked") == true \
		and persistent_defer_drain.get("terminalMemoryFailure", {}).get("phase") \
			== "defer_release" \
		and persistent_defer_drain.get("terminalMemoryFailure", {}).get("token") \
			== "persistent-defer-token" \
		and persistent_defer_drain.get("terminalMemoryFailure", {}).get("attempts") == 3 \
		and persistent_defer.admission.defer_calls == 3 \
		and persistent_defer.admission.reservation_count == 1 \
		and persistent_defer.admission.charged_bytes > 0 \
		and persistent_defer.owner._live.has(Vector3i(4107, 0, 0)) \
		and is_instance_valid(persistent_defer.entry.body) \
		and not persistent_defer.entry.body.is_queued_for_deletion() \
		and persistent_defer.entry.body.collision_layer == 0 \
		and persistent_defer.entry.body.collision_mask == 0 \
		and persistent_defer.entry.shapes[0].disabled
	var persistent_defer_again: Dictionary = persistent_defer.owner.drain_step()
	var persistent_defer_sticky: bool = persistent_defer_again.get("status") == "failed" \
		and persistent_defer.admission.defer_calls == 3 \
		and is_instance_valid(persistent_defer.entry.body)

	var transient_ack := _make_deferred_release_fault_owner(
		Vector3i(4108, 0, 0), "transient-ack-token")
	transient_ack.admission.ack_failures_remaining = 1
	var transient_ack_drain: Dictionary = await transient_ack.owner.stop_and_drain()
	var transient_ack_recovered: bool = transient_ack_drain.get("status") == "ready" \
		and transient_ack.admission.ack_calls == 2 \
		and transient_ack.admission.reservation_count == 0 \
		and transient_ack.admission.charged_bytes == 0

	var persistent_ack := _make_deferred_release_fault_owner(
		Vector3i(4109, 0, 0), "persistent-ack-token")
	var terminal_source := FakeSource.new()
	assert(persistent_ack.owner.bind_source(terminal_source),
		"persistent acknowledgement fixture binds a source before stop")
	persistent_ack.admission.ack_failures_remaining = 10
	var persistent_ack_drain: Dictionary = await persistent_ack.owner.stop_and_drain()
	var persistent_ack_blocked: bool = persistent_ack_drain.get("status") == "failed" \
		and persistent_ack_drain.get("blocked") == true \
		and persistent_ack_drain.get("terminalMemoryFailure", {}).get("phase") \
			== "acknowledge_deferred_release" \
		and persistent_ack_drain.get("terminalMemoryFailure", {}).get("token") \
			== "persistent-ack-token" \
		and persistent_ack_drain.get("terminalMemoryFailure", {}).get("attempts") == 3 \
		and persistent_ack.admission.ack_calls == 3 \
		and persistent_ack.admission.reservation_count == 1 \
		and persistent_ack.admission.charged_bytes > 0 \
		and persistent_ack.owner._retired_memory_entries.size() == 1
	var persistent_ack_again: Dictionary = persistent_ack.owner.drain_step()
	var persistent_ack_sticky: bool = persistent_ack_again.get("status") == "failed" \
		and persistent_ack.admission.ack_calls == 3 \
		and persistent_ack.admission.reservation_count == 1 \
		and persistent_ack.admission.charged_bytes > 0
	var persistent_ack_publish: Dictionary = await persistent_ack.owner.publish({})
	var persistent_ack_admission_blocked: bool = persistent_ack.owner._failed \
		and persistent_ack_publish.get("status") == "failed" \
		and persistent_ack_publish.get("reason") \
			== "resident_owner_memory_release_terminal_failure" \
		and persistent_ack.admission.reserve_calls == 0 \
		and persistent_ack.admission.reservation_count == 1 \
		and persistent_ack.admission.charged_bytes > 0

	var transient_cancel := _make_unconstructed_cancel_owner("transient-cancel-token")
	transient_cancel.admission.cancel_failures_remaining = 1
	var transient_cancel_drain: Dictionary = await transient_cancel.owner.stop_and_drain()
	var transient_cancel_recovered: bool = transient_cancel_drain.get("status") == "ready" \
		and transient_cancel.admission.cancel_calls == 2 \
		and transient_cancel.admission.reservation_count == 0 \
		and transient_cancel.admission.charged_bytes == 0 \
		and transient_cancel.owner._unconstructed_memory_tokens.is_empty()
	var persistent_cancel := _make_unconstructed_cancel_owner("persistent-cancel-token")
	persistent_cancel.admission.cancel_failures_remaining = 10
	var persistent_cancel_drain: Dictionary = await persistent_cancel.owner.stop_and_drain()
	var persistent_cancel_blocked: bool = persistent_cancel_drain.get("status") == "failed" \
		and persistent_cancel_drain.get("blocked") == true \
		and persistent_cancel_drain.get("terminalMemoryFailure", {}).get("phase") \
			== "cancel_unconstructed" \
		and persistent_cancel_drain.get("terminalMemoryFailure", {}).get("token") \
			== "persistent-cancel-token" \
		and persistent_cancel.admission.cancel_calls == 3 \
		and persistent_cancel.admission.reservation_count == 1 \
		and persistent_cancel.admission.charged_bytes > 0 \
		and persistent_cancel.owner._unconstructed_memory_tokens.has(\
			"persistent-cancel-token")

	var missing_token_owner := _make_deferred_release_fault_owner(
		Vector3i(4112, 0, 0), "originally-present-token")
	missing_token_owner.entry.memoryToken = ""
	var missing_token_dispose: Dictionary = missing_token_owner.owner._dispose(
		missing_token_owner.entry)
	var missing_token_blocked: bool = missing_token_dispose.get("status") == "failed" \
		and missing_token_dispose.get("retryTracked") == true \
		and missing_token_owner.owner._failed \
		and missing_token_owner.owner._drain_terminal_failure.get("reason") \
			== "collision_memory_dispose_retry_token_missing" \
		and missing_token_owner.owner._disposal_retry_orphans.size() == 1 \
		and is_instance_valid(missing_token_owner.entry.body) \
		and not missing_token_owner.entry.body.is_queued_for_deletion() \
		and missing_token_owner.entry.body.collision_layer == 0 \
		and missing_token_owner.entry.shapes[0].disabled

	var unbound_retry_owner = OwnerScript.new()
	add_child(unbound_retry_owner)
	var unbound_retry_body := StaticBody3D.new()
	unbound_retry_body.collision_layer = OwnerScript.COLLISION_LAYER
	unbound_retry_owner.add_child(unbound_retry_body)
	var unbound_retry_shape := CollisionShape3D.new()
	unbound_retry_shape.shape = BoxShape3D.new()
	unbound_retry_body.add_child(unbound_retry_shape)
	var unbound_retry_entry := {"body":unbound_retry_body,
		"shapes":[unbound_retry_shape], "retiredShapes":[], "memoryToken":""}
	var unbound_retry_result: Dictionary = unbound_retry_owner._retain_disposal_retry(
		unbound_retry_entry)
	var unbound_retry_blocked: bool = unbound_retry_result.get("tracked") == true \
		and unbound_retry_result.get("orphaned") == true \
		and unbound_retry_owner._failed \
		and unbound_retry_owner._disposal_retry_orphans.size() == 1 \
		and not unbound_retry_body.is_queued_for_deletion()

	var empty_token_source := FakeSource.new()
	var empty_token_owner = OwnerScript.new()
	add_child(empty_token_owner)
	var empty_token_identity := _identity(1)
	var empty_token_block := Vector3i(4113, 0, 0)
	var empty_token_blocks: Array[Vector3i] = []
	empty_token_blocks.append(empty_token_block)
	var empty_token_rows: Array[Dictionary] = []
	var empty_token_row: Dictionary = _row(empty_token_block,
		"empty-token-artifact", 0.5, empty_token_identity)
	empty_token_rows.append(empty_token_row)
	empty_token_source.rows[empty_token_block] = empty_token_row
	empty_token_source.current = _shutdown_snapshot(empty_token_identity,
		empty_token_blocks, "empty-token-artifact",
		String(empty_token_row.get("sourceIdentity", {}).get("hex", "")),
		"empty-token-closure")
	empty_token_owner.bind_source(empty_token_source)
	var empty_token_admission := DeferredReleaseFault.new()
	empty_token_admission.return_empty_token = true
	var empty_token_epoch := "fixture-empty-token-owner"
	assert(empty_token_owner.assign_retirement_owner_epoch(empty_token_epoch),
		"empty-token fixture assigns owner epoch")
	assert(empty_token_owner.bind_memory_admission(empty_token_admission,
		"fixture-empty-token-window", empty_token_epoch),
		"empty-token fixture binds admission ledger")
	var empty_token_barrier = BarrierScript.new()
	var empty_token_begin: Dictionary = empty_token_barrier.begin(self,
		empty_token_owner, empty_token_identity, empty_token_row.bounds)
	while empty_token_begin.get("status") == "pending":
		await get_tree().process_frame
		empty_token_begin = empty_token_barrier.census_progress(empty_token_identity)
	var empty_token_publish: Dictionary = await empty_token_owner.publish(
		_request(empty_token_identity, empty_token_blocks,
			empty_token_blocks, empty_token_rows), empty_token_barrier)
	var empty_token_second_publish: Dictionary = await empty_token_owner.publish({})
	var empty_token_drain: Dictionary = await empty_token_owner.stop_and_drain()
	var bound_empty_token_blocked: bool = empty_token_publish.get("status") == "failed" \
		and empty_token_publish.get("reason") == "collision_memory_token_missing" \
		and empty_token_owner._failed \
		and empty_token_owner._drain_terminal_failure.get("phase") \
			== "candidate_reservation" \
		and empty_token_admission.reserve_calls == 1 \
		and empty_token_owner.get_child_count() == 0 \
		and empty_token_second_publish.get("reason") \
			== "resident_owner_memory_release_terminal_failure" \
		and empty_token_drain.get("status") == "failed" \
		and empty_token_admission.reservation_count == 1 \
		and empty_token_admission.charged_bytes > 0

	var capacity := _make_deferred_release_fault_owner(
		Vector3i(4110, 0, 0), "retry-capacity-owner-token")
	capacity.admission._limits.maxReservations = 1
	var capacity_entry := _entry_for_fault_owner(capacity, "retry-capacity-overflow-token")
	var capacity_first: Dictionary = capacity.owner._retain_disposal_retry(capacity.entry)
	var capacity_overflow: Dictionary = capacity.owner._retain_disposal_retry(capacity_entry)
	var capacity_blocked: bool = capacity_first.get("tracked") == true \
		and capacity_overflow.get("orphaned") == true \
		and capacity.owner._disposal_retry_entries.size() == 1 \
		and capacity.owner._disposal_retry_orphans.size() == 1 \
		and not capacity_entry.body.is_queued_for_deletion() \
		and capacity.owner._drain_terminal_failure.get("reason") \
			== "collision_memory_dispose_retry_capacity_exhausted"
	var capacity_blocked_drain: Dictionary = await capacity.owner.stop_and_drain()
	capacity_blocked = capacity_blocked and capacity_blocked_drain.get("status") == "failed" \
		and is_instance_valid(capacity_entry.body) \
		and is_instance_valid(capacity.entry.body)

	var conflict := _make_deferred_release_fault_owner(
		Vector3i(4111, 0, 0), "retry-conflicting-token")
	var conflict_entry := _entry_for_fault_owner(conflict, "retry-conflicting-token")
	var conflict_first: Dictionary = conflict.owner._retain_disposal_retry(conflict.entry)
	var conflict_second: Dictionary = conflict.owner._retain_disposal_retry(conflict_entry)
	var conflict_blocked_drain: Dictionary = await conflict.owner.stop_and_drain()
	var retry_collision_blocked: bool = conflict_first.get("tracked") == true \
		and conflict_second.get("conflict") == true \
		and conflict.owner._disposal_retry_entries.get("retry-conflicting-token", {}) \
			.get("conflicts", []).size() == 1 \
		and conflict_blocked_drain.get("status") == "failed" \
		and is_instance_valid(conflict.entry.body) \
		and is_instance_valid(conflict_entry.body) \
		and not conflict.entry.body.is_queued_for_deletion() \
		and not conflict_entry.body.is_queued_for_deletion()

	var prepare := _make_deferred_release_fault_owner(
		Vector3i(4101, 0, 0), "prepare-reject-token")
	prepare.owner._live.clear()
	prepare.owner._resident_blocks.clear()
	prepare.admission.failures_remaining = 2
	var invalid_row := {"vertices":PackedVector3Array([Vector3.ZERO]),
		"bounds":AABB(Vector3.ZERO, Vector3.ONE)}
	var prepare_result: Dictionary = await prepare.owner._prepare_row_bounded(
		invalid_row, {}, prepare.entry)
	var prepare_sweep: Dictionary = prepare.owner._dispose_candidates({
		Vector3i(4101, 0, 0):prepare.entry})
	prepare.owner._pending_candidates = {Vector3i(4101, 0, 0):prepare.entry}
	prepare.owner._pending_candidate_keys.clear()
	prepare.owner._pending_candidate_keys.append(Vector3i(4101, 0, 0))
	var prepare_retained: bool = prepare_result.get("disposal", {}).get("status") == "failed" \
		and prepare_sweep.get("status") == "failed" \
		and prepare.owner._disposal_retry_entries.has("prepare-reject-token") \
		and is_instance_valid(prepare.entry.body) \
		and not prepare.entry.body.is_queued_for_deletion()
	var prepare_drain: Dictionary = await prepare.owner.stop_and_drain()

	var rollback := _make_deferred_release_fault_owner(
		Vector3i(4102, 0, 0), "rollback-reject-token")
	rollback.owner._live.clear()
	rollback.owner._resident_blocks.clear()
	rollback.admission.failures_remaining = 1
	var rollback_result: Dictionary = await rollback.owner._rollback({
		Vector3i(4102, 0, 0):rollback.entry}, {})
	var rollback_retained: bool = not bool(rollback_result.get(
		"candidateDisposalReady", true)) \
		and rollback.owner._disposal_retry_entries.has("rollback-reject-token") \
		and is_instance_valid(rollback.entry.body) \
		and not rollback.entry.body.is_queued_for_deletion()
	rollback.owner._pending_candidates = {Vector3i(4102, 0, 0):rollback.entry}
	rollback.owner._pending_candidate_keys.clear()
	rollback.owner._pending_candidate_keys.append(Vector3i(4102, 0, 0))
	var rollback_drain: Dictionary = await rollback.owner.stop_and_drain()

	var previous := _make_deferred_release_fault_owner(
		Vector3i(4103, 0, 0), "previous-row-reject-token")
	previous.owner._live.clear()
	previous.owner._resident_blocks.clear()
	previous.admission.failures_remaining = 1
	var previous_result: Dictionary = previous.owner._dispose_previous_live_entries({
		Vector3i(4103, 0, 0):previous.entry})
	var previous_retained: bool = previous_result.get("status") == "failed" \
		and previous.owner._disposal_retry_entries.has("previous-row-reject-token") \
		and is_instance_valid(previous.entry.body) \
		and not previous.entry.body.is_queued_for_deletion()
	var previous_drain: Dictionary = await previous.owner.stop_and_drain()

	var post_commit := _make_deferred_release_fault_owner(
		Vector3i(4104, 0, 0), "post-commit-old-token")
	post_commit.admission.reservation_count = 2
	post_commit.admission.charged_bytes = 512
	post_commit.owner._live.clear()
	post_commit.owner._resident_blocks.clear()
	var committed_body := StaticBody3D.new()
	committed_body.collision_layer = OwnerScript.COLLISION_LAYER
	committed_body.collision_mask = 0
	post_commit.owner.add_child(committed_body)
	var committed_shape := CollisionShape3D.new()
	committed_shape.shape = BoxShape3D.new()
	committed_body.add_child(committed_shape)
	var committed_entry := {"body":committed_body,
		"shapes":[committed_shape], "retiredShapes":[],
		"memoryToken":"post-commit-new-token", "expectedHit":true}
	post_commit.owner._live = {Vector3i(4104, 0, 0):committed_entry}
	post_commit.owner._resident_blocks.clear()
	post_commit.owner._resident_blocks.append(Vector3i(4104, 0, 0))
	post_commit.owner._pending_candidates = {Vector3i(4104, 0, 0):committed_entry}
	post_commit.owner._pending_candidate_keys.clear()
	post_commit.owner._pending_candidate_keys.append(Vector3i(4104, 0, 0))
	post_commit.owner.request_stop()
	# Targeted branch contract for the two post-commit publish stop exits: both
	# call _finish_stopped_committed_publish(old), whose ownership transfer is
	# exercised here against populated live, pending, and old-entry structures.
	var post_commit_stop: Dictionary = \
		post_commit.owner._finish_stopped_committed_publish({
			Vector3i(4104, 0, 0):post_commit.entry})
	var post_commit_retained: bool = post_commit_stop.get("status") == "failed" \
		and post_commit.owner._pending_candidates.is_empty() \
		and post_commit.owner._pending_candidate_keys.is_empty() \
		and post_commit.owner._live.get(Vector3i(4104, 0, 0), {}).get("body") \
			== committed_body \
		and post_commit.owner._disposal_retry_entries.get(
			"post-commit-old-token", {}).get("entry", {}).get("body") \
			== post_commit.entry.body \
		and not post_commit.entry.body.is_queued_for_deletion() \
		and not committed_body.is_queued_for_deletion()
	var post_commit_drain: Dictionary = await post_commit.owner.stop_and_drain()

	var abort_recovered := _make_shape_less_reserved_body_owner(
		Vector3i(4105, 0, 0), "abort-recovered-token")
	abort_recovered.owner._live.clear()
	abort_recovered.owner._resident_blocks.clear()
	abort_recovered.owner._unconstructed_memory_tokens.append(
		"abort-recovered-token")
	abort_recovered.owner._pending_candidates = {
		Vector3i(4105, 0, 0):abort_recovered.entry}
	abort_recovered.owner._pending_candidate_keys.clear()
	abort_recovered.owner._pending_candidate_keys.append(Vector3i(4105, 0, 0))
	var original_construct_failure: Dictionary = \
		abort_recovered.admission.mark_candidate_constructed(
			"abort-recovered-token", abort_recovered.owner.retirement_owner_epoch(),
			[abort_recovered.entry.body.get_instance_id()])
	var recovered_result: Dictionary = abort_recovered.owner._fail_candidate_construction(
		{Vector3i(4105, 0, 0):abort_recovered.entry}, abort_recovered.entry,
		original_construct_failure)
	var abort_recovery_valid: bool = recovered_result.get("status") == "failed" \
		and recovered_result.get("constructionFailure", {}).get("reason") \
			== "fixture_mark_constructed_rejected" \
		and recovered_result.get("abortBodyRegistration", {}).get("status") == "ready" \
		and abort_recovered.admission.abort_body_ids_received == \
			[abort_recovered.entry.body.get_instance_id()] \
		and abort_recovered.admission.defer_calls == 1 \
		and abort_recovered.admission.cancel_calls == 0
	var abort_recovery_drain: Dictionary = await abort_recovered.owner.stop_and_drain()

	var abort_blocked := _make_shape_less_reserved_body_owner(
		Vector3i(4106, 0, 0), "abort-blocked-token")
	abort_blocked.owner._live.clear()
	abort_blocked.owner._resident_blocks.clear()
	abort_blocked.owner._unconstructed_memory_tokens.append("abort-blocked-token")
	abort_blocked.owner._pending_candidates = {
		Vector3i(4106, 0, 0):abort_blocked.entry}
	abort_blocked.owner._pending_candidate_keys.clear()
	abort_blocked.owner._pending_candidate_keys.append(Vector3i(4106, 0, 0))
	abort_blocked.admission.abort_registration_fails = true
	var original_blocked_failure: Dictionary = \
		abort_blocked.admission.mark_candidate_constructed("abort-blocked-token",
			abort_blocked.owner.retirement_owner_epoch(),
			[abort_blocked.entry.body.get_instance_id()])
	var blocked_result: Dictionary = abort_blocked.owner._fail_candidate_construction(
		{Vector3i(4106, 0, 0):abort_blocked.entry}, abort_blocked.entry,
		original_blocked_failure)
	var blocked_drain: Dictionary = await abort_blocked.owner.stop_and_drain()
	var abort_failure_stays_blocked: bool = blocked_result.get("reason") \
		== "collision_memory_candidate_construction_unresolved" \
		and blocked_drain.get("status") == "failed" \
		and blocked_drain.get("blocked") == true \
		and blocked_drain.get("drained") == false \
		and blocked_drain.get("memoryAdmission", {}).get("ledger", {}).get(
			"reservationCount", 0) == 1 \
		and blocked_drain.get("memoryAdmission", {}).get("ledger", {}).get(
			"totalChargedBytes", 0) > 0 \
		and abort_blocked.owner._pending_candidates.has(Vector3i(4106, 0, 0)) \
		and abort_blocked.owner._unconstructed_memory_tokens.has("abort-blocked-token") \
		and is_instance_valid(abort_blocked.entry.body) \
		and not abort_blocked.entry.body.is_queued_for_deletion() \
		and abort_blocked.admission.defer_calls == 0 \
		and abort_blocked.admission.cancel_calls == 0
	var passed: bool = direct_result.get("status") == "failed" and direct_retained \
		and transient_defer_recovered and persistent_defer_blocked \
		and persistent_defer_sticky and transient_ack_recovered \
		and persistent_ack_blocked and persistent_ack_sticky \
		and persistent_ack_admission_blocked \
		and transient_cancel_recovered and persistent_cancel_blocked \
		and missing_token_blocked and unbound_retry_blocked \
		and bound_empty_token_blocked and capacity_blocked and retry_collision_blocked \
		and direct_drain.get("status") == "ready" \
		and prepare_retained and prepare_drain.get("status") == "ready" \
		and rollback_retained and rollback_drain.get("status") == "ready" \
		and previous_retained and previous_drain.get("status") == "ready" \
		and post_commit_retained and post_commit_drain.get("status") == "ready" \
		and abort_recovery_valid and abort_recovery_drain.get("status") == "ready" \
		and abort_failure_stays_blocked
	return {"passed":passed,
		"evidenceLevel":"injected release/cancel failures with real owner scene-tree drain; no-ledger direct dispose is a fixture/service mode, while retry tracking and bound empty-token admission fail closed; stub does not model ledger byte accounting",
		"directRetirement":{"result":direct_result, "retained":direct_retained,
			"drain":direct_drain,
			"transientDeferRecovered":transient_defer_recovered},
		"persistentDefer":{"drain":persistent_defer_drain,
			"blocked":persistent_defer_blocked,
			"sticky":persistent_defer_sticky,
			"retryReceipt":persistent_defer_again},
		"transientAck":{"drain":transient_ack_drain,
			"recovered":transient_ack_recovered},
		"persistentAck":{"drain":persistent_ack_drain,
			"blocked":persistent_ack_blocked,
			"sticky":persistent_ack_sticky,
			"subsequentPublishBlocked":persistent_ack_admission_blocked,
			"publish":persistent_ack_publish,
			"retryReceipt":persistent_ack_again},
		"transientCancel":{"drain":transient_cancel_drain,
			"recovered":transient_cancel_recovered},
		"persistentCancel":{"drain":persistent_cancel_drain,
			"blocked":persistent_cancel_blocked},
		"missingRetryToken":{"dispose":missing_token_dispose,
			"blocked":missing_token_blocked},
		"unboundRetryToken":{"result":unbound_retry_result,
			"blocked":unbound_retry_blocked},
		"boundEmptyAdmissionToken":{"publish":empty_token_publish,
			"secondPublish":empty_token_second_publish,
			"drain":empty_token_drain,"blocked":bound_empty_token_blocked},
		"retryCapacity":{"first":capacity_first, "overflow":capacity_overflow,
			"blocked":capacity_blocked, "drain":capacity_blocked_drain},
		"retryTokenCollision":{"first":conflict_first, "second":conflict_second,
			"blocked":retry_collision_blocked, "drain":conflict_blocked_drain},
		"prepareAndCandidateSweep":{"prepare":prepare_result,
			"sweep":prepare_sweep, "retained":prepare_retained,
			"drain":prepare_drain},
		"rollback":{"result":rollback_result, "retained":rollback_retained,
			"drain":rollback_drain},
		"previousLiveReplacement":{"result":previous_result,
			"retained":previous_retained, "drain":previous_drain},
		"postCommitStop":{"result":post_commit_stop,
			"retained":post_commit_retained, "drain":post_commit_drain,
			"branchContract":"publish health-await and post-loop stop exits share _finish_stopped_committed_publish; fixture exercises its populated owner-state handoff, not the health-await scheduling itself"},
		"candidateAbortRecovery":{"result":recovered_result,
			"valid":abort_recovery_valid, "drain":abort_recovery_drain},
		"candidateAbortBlocked":{"result":blocked_result,
			"drain":blocked_drain, "retained":abort_failure_stays_blocked}}


func _make_deferred_release_fault_owner(block: Vector3i, token: String) -> Dictionary:
	var owner = OwnerScript.new()
	add_child(owner)
	var epoch := "fixture-owner-%s" % token
	var admission := DeferredReleaseFault.new()
	assert(owner.assign_retirement_owner_epoch(epoch),
		"fault fixture assigns a unique retirement owner epoch")
	assert(owner.bind_memory_admission(admission, "fixture-window-%s" % token,
		epoch), "fault fixture binds injected admission ledger")
	owner._membership_provenance = {"windowToken":"fixture-window-%s" % token}
	var body := StaticBody3D.new()
	body.collision_layer = OwnerScript.COLLISION_LAYER
	body.collision_mask = 0
	owner.add_child(body)
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	body.add_child(shape)
	var entry := {"body":body, "shapes":[shape], "retiredShapes":[],
		"memoryToken":token, "expectedHit":true,
		"probeFrom":Vector3(float(block.x) * 3.0 + 0.5, 2.8, 0.5),
		"probeTo":Vector3(float(block.x) * 3.0 + 0.5, 0.2, 0.5)}
	owner._live = {block:entry}
	owner._resident_blocks.clear()
	owner._resident_blocks.append(block)
	admission.cancel_body = body
	return {"owner":owner, "admission":admission, "entry":entry}


func _new_fixture_ledger(epoch: String) -> Object:
	# These intentionally small synthetic values exercise the owner lifecycle;
	# they are not measurements or production memory limits.
	var policy = PolicyScript.new()
	var configured: Dictionary = policy.configure({
		"maxVerticesPerRow":64, "verticesPerShape":16,
		"rowEntryBytes":64, "bodyEntryBytes":64, "shapeEntryBytes":64,
		"physicsPayloadMultiplier":2, "maxRowsPerWindow":64,
		"maxWindowChargedBytes":1048576,
		"maxAggregateChargedBytes":4194304, "maxReservations":128})
	assert(configured.get("status") == "ready",
		"synthetic N5 fixture policy configures")
	var admission = AdmissionScript.new()
	var setup: Dictionary = admission.setup(policy, epoch,
		"fixture-instance-%s" % epoch)
	assert(setup.get("status") == "ready",
		"synthetic N5 fixture ledger configures")
	return admission


func _make_unconstructed_cancel_owner(token: String) -> Dictionary:
	var owner = OwnerScript.new()
	add_child(owner)
	var epoch := "fixture-owner-%s" % token
	var admission := DeferredReleaseFault.new()
	assert(owner.assign_retirement_owner_epoch(epoch),
		"cancel fixture assigns a unique retirement owner epoch")
	assert(owner.bind_memory_admission(admission, "fixture-window-%s" % token,
		epoch), "cancel fixture binds injected admission ledger")
	owner._unconstructed_memory_tokens.append(token)
	return {"owner":owner, "admission":admission}


func _entry_for_fault_owner(fault: Dictionary, token: String) -> Dictionary:
	var owner = fault.owner
	var body := StaticBody3D.new()
	body.collision_layer = OwnerScript.COLLISION_LAYER
	body.collision_mask = 0
	owner.add_child(body)
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	body.add_child(shape)
	return {"body":body, "shapes":[shape], "retiredShapes":[],
		"memoryToken":token, "expectedHit":true}


func _make_shape_less_reserved_body_owner(block: Vector3i,
		token: String) -> Dictionary:
	var owner = OwnerScript.new()
	add_child(owner)
	var epoch := "fixture-owner-%s" % token
	var admission := DeferredReleaseFault.new()
	assert(owner.assign_retirement_owner_epoch(epoch),
		"abort fixture assigns a unique retirement owner epoch")
	assert(owner.bind_memory_admission(admission, "fixture-window-%s" % token,
		epoch), "abort fixture binds injected admission ledger")
	owner._membership_provenance = {"windowToken":"fixture-window-%s" % token}
	var body := StaticBody3D.new()
	body.collision_layer = OwnerScript.COLLISION_LAYER
	body.collision_mask = 0
	owner.add_child(body)
	var entry := {"body":body, "shapes":[], "retiredShapes":[],
		"memoryToken":token, "expectedHit":true,
		"probeFrom":Vector3(float(block.x) * 3.0 + 0.5, 2.8, 0.5),
		"probeTo":Vector3(float(block.x) * 3.0 + 0.5, 0.2, 0.5)}
	owner._live = {block:entry}
	owner._resident_blocks.clear()
	owner._resident_blocks.append(block)
	admission.cancel_body = body
	return {"owner":owner, "admission":admission, "entry":entry}


func _make_health_owner(source: FakeSource, block: Vector3i,
		identity: Dictionary):
	var health_owner = OwnerScript.new()
	add_child(health_owner)
	assert(health_owner.bind_source(source), "health fixture binds immutable source ticket")
	var body := StaticBody3D.new()
	body.collision_layer = OwnerScript.COLLISION_LAYER
	body.collision_mask = 0
	health_owner.add_child(body)
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	body.add_child(shape)
	var source_identity: Dictionary = source.current.sourceIdentity
	health_owner._live = {block:{"body":body, "shapes":[shape],
		"artifactKey":source.current.artifacts[block], "expectedHit":true}}
	health_owner._identity = identity.duplicate(true)
	health_owner._source_identity = source_identity.duplicate(true)
	health_owner._source_ticket = source._ticket_value()
	health_owner._membership_provenance = source.current.membershipProvenance.duplicate(true)
	var resident_blocks: Array[Vector3i] = [block]
	health_owner._resident_blocks.clear()
	health_owner._receipt_resident_blocks.clear()
	for resident_block: Vector3i in resident_blocks:
		health_owner._resident_blocks.append(resident_block)
		health_owner._receipt_resident_blocks.append(resident_block)
	health_owner._receipt_resident_blocks.make_read_only()
	health_owner._readiness_epoch = 1
	return health_owner


func _bounded_validation_contract() -> Dictionary:
	var health_cursor := _bounded_physical_health_cursor_case()
	var health_shapes := await _bounded_health_shape_cursor_case()
	var wide := _cursor_source(OwnerScript.MAX_RESIDENT, 30, "wide")
	var wide_owner = OwnerScript.new()
	add_child(wide_owner)
	wide_owner.bind_source(wide.source)
	var wide_request := _request(wide.identity, wide.blocks, [wide.blocks[0]], [wide.row])
	var wide_check: Dictionary = await wide_owner._validate_request(wide_request)
	var wide_drain: Dictionary = await wide_owner.stop_and_drain()
	var over := _cursor_source(OwnerScript.MAX_RESIDENT + 1, 31, "over")
	var over_owner = OwnerScript.new()
	add_child(over_owner)
	over_owner.bind_source(over.source)
	var over_request := {"schema":"n5-resident-collision-publication/v1",
		"identity":over.identity, "residentBlocks":over.blocks,
		"affectedBlocks":[Vector3i.ZERO], "rows":[{}]}
	var over_check: Dictionary = await over_owner._validate_request(over_request)
	var early_source_calls := int(over.source.ticket_snapshot_queries)
	var over_drain: Dictionary = await over_owner.stop_and_drain()
	var caps := _cursor_source(1, 34, "caps")
	var caps_owner = OwnerScript.new()
	add_child(caps_owner)
	caps_owner.bind_source(caps.source)
	var sixty_five: Array = []
	for index in range(OwnerScript.MAX_AFFECTED + 1):
		sixty_five.append(Vector3i(index, 0, 0))
	var row_oversize: Dictionary = await caps_owner._validate_request({
		"schema":"n5-resident-collision-publication/v1", "identity":caps.identity,
		"residentBlocks":[Vector3i.ZERO], "affectedBlocks":[Vector3i.ZERO],
		"rows":sixty_five})
	var affected_oversize: Dictionary = await caps_owner._validate_request({
		"schema":"n5-resident-collision-publication/v1", "identity":caps.identity,
		"residentBlocks":[Vector3i.ZERO], "affectedBlocks":sixty_five,
		"rows":[caps.row]})
	var caps_source_calls := int(caps.source.ticket_snapshot_queries)
	var caps_drain: Dictionary = await caps_owner.stop_and_drain()
	var drifting := _cursor_source(256, 32, "drift")
	var drift_owner = OwnerScript.new()
	add_child(drift_owner)
	drift_owner.bind_source(drifting.source)
	var drift_triggered := [false]
	drifting.source.ticket_query_hook = func(_ticket: String):
		if not bool(drift_triggered[0]):
			drift_triggered[0] = true
			drifting.source.current.membershipProvenance.closureToken = "changed-during-cursor"
	var drift_result: Dictionary = await drift_owner.publish(
		_request(drifting.identity, drifting.blocks, [drifting.blocks[0]], [drifting.row]))
	drifting.source.ticket_query_hook = Callable()
	var drift_shapes := drift_owner.get_child_count()
	var drift_drain: Dictionary = await drift_owner.stop_and_drain()
	var cancelling := _cursor_source(256, 33, "cancel")
	var cancel_owner = OwnerScript.new()
	add_child(cancel_owner)
	cancel_owner.bind_source(cancelling.source)
	var cancel_triggered := [false]
	cancelling.source.ticket_query_hook = func(_ticket: String):
		if not bool(cancel_triggered[0]):
			cancel_triggered[0] = true
			cancel_owner.request_stop()
	var cancel_result: Dictionary = await cancel_owner.publish(
		_request(cancelling.identity, cancelling.blocks,
			[cancelling.blocks[0]], [cancelling.row]))
	cancelling.source.ticket_query_hook = Callable()
	var cancel_shapes := cancel_owner.get_child_count()
	var cancel_drain: Dictionary = await cancel_owner.stop_and_drain()
	wide_owner.queue_free()
	over_owner.queue_free()
	caps_owner.queue_free()
	drift_owner.queue_free()
	cancel_owner.queue_free()
	await get_tree().process_frame
	var passed: bool = wide_check.get("status") == "ready" \
		and int(wide_check.get("maxValidationOperations", 0)) <= 128 \
		and bool(health_cursor.get("passed", false)) \
		and bool(health_shapes.get("passed", false)) \
		and wide_drain.get("status") == "ready" \
		and over_check.get("status") == "pending" \
		and over_check.get("reason") == "resident_window_capacity_backpressure" \
		and bool(over_check.get("retryable", false)) \
		and bool(over_check.get("demandRetained", false)) \
		and early_source_calls == 0 and over_drain.get("status") == "ready" \
		and row_oversize.get("reason") == "resident_request_capacity_invalid" \
		and affected_oversize.get("reason") == "resident_request_capacity_invalid" \
		and caps_source_calls == 0 and caps_drain.get("status") == "ready" \
		and bool(drift_triggered[0]) and drift_result.get("status") == "pending" \
		and drift_result.get("reason") == "resident_validation_interrupted" \
		and drift_shapes == 0 and drift_drain.get("status") == "ready" \
		and bool(cancel_triggered[0]) and cancel_result.get("reason") == "resident_owner_stopping" \
		and cancel_shapes == 0 and cancel_drain.get("status") == "ready"
	return {"passed":passed, "maxResidentCount":OwnerScript.MAX_RESIDENT,
		"physicalHealthCursor":health_cursor,
		"physicalHealthShapeCursor":health_shapes,
		"maxResident":{"status":wide_check.get("status"),
			"maxOperations":wide_check.get("maxValidationOperations", -1),
			"maxStepUsec":wide_check.get("maxValidationStepUsec", -1),
			"maxStepUsecBudget":OwnerScript.VALIDATION_STEP_USEC_BUDGET,
			"wallClockHardPreemption":false,
			"ticketChecks":wide.source.ticket_checks,
			"drainStatus":wide_drain.get("status")},
		"oversize":{"status":over_check.get("status"),
			"reason":over_check.get("reason"), "sourceTicketQueries":early_source_calls,
			"drainStatus":over_drain.get("status"),
			"oversizeRows":row_oversize.get("reason"),
			"oversizeAffected":affected_oversize.get("reason"),
			"affectedRowsSourceTicketQueries":caps_source_calls,
			"affectedRowsDrainStatus":caps_drain.get("status")},
		"revisionDrift":{"triggered":drift_triggered[0],
			"result":drift_result, "candidateChildren":drift_shapes,
			"drainStatus":drift_drain.get("status")},
		"cancellation":{"triggered":cancel_triggered[0],
			"result":cancel_result, "candidateChildren":cancel_shapes,
		"drainStatus":cancel_drain.get("status")}}


func _bounded_physical_health_cursor_case() -> Dictionary:
	var fixture := _cursor_source(OwnerScript.MAX_RESIDENT, 35, "health-wide")
	var owner = OwnerScript.new()
	owner.bind_source(fixture.source)
	owner._identity = fixture.identity.duplicate(true)
	owner._source_identity = fixture.sourceIdentity.duplicate(true)
	owner._source_ticket = fixture.source._ticket_value()
	owner._membership_provenance = fixture.source.current.membershipProvenance.duplicate(true)
	owner._resident_blocks.clear()
	owner._receipt_resident_blocks.clear()
	for resident_block: Vector3i in fixture.blocks:
		owner._resident_blocks.append(resident_block)
		owner._receipt_resident_blocks.append(resident_block)
	owner._receipt_resident_blocks.make_read_only()
	owner._readiness_epoch = 1
	owner._live = {}
	for block: Vector3i in fixture.blocks:
		owner._live[block] = {"expectedHit":false, "body":null, "shapes":[]}
	var result: Dictionary = {"status":"pending"}
	var steps := 0
	var max_operations := 0
	var max_step_usec := 0
	while result.get("status") == "pending" and steps < 64:
		result = owner._advance_physical_health_validation(fixture.identity)
		steps += 1
		max_operations = maxi(max_operations, int(result.get("operations", 0)))
		max_step_usec = maxi(max_step_usec, int(result.get("maxStepUsec", 0)))
	var passed: bool = result.get("status") == "ready" and steps > 1 \
		and max_operations <= OwnerScript.HEALTH_VALIDATION_OPERATION_BUDGET \
		and owner._health_validated_epoch == owner.physical_readiness_epoch()
	owner.free()
	return {"passed":passed, "result":result, "steps":steps,
		"residentCount":fixture.blocks.size(), "maxOperations":max_operations,
		"operationBudget":OwnerScript.HEALTH_VALIDATION_OPERATION_BUDGET,
		"maxStepUsec":max_step_usec,
		"stepUsecBudget":OwnerScript.HEALTH_VALIDATION_STEP_USEC_BUDGET,
		"wallClockHardPreemption":false}


func _bounded_health_shape_cursor_case() -> Dictionary:
	var fixture := _cursor_source(2, 36, "shape-health")
	var owner = OwnerScript.new()
	add_child(owner)
	owner.bind_source(fixture.source)
	owner._identity = fixture.identity.duplicate(true)
	owner._source_identity = fixture.sourceIdentity.duplicate(true)
	owner._source_ticket = fixture.source._ticket_value()
	owner._membership_provenance = fixture.source.current.membershipProvenance.duplicate(true)
	owner._resident_blocks.clear()
	owner._receipt_resident_blocks.clear()
	for resident_block: Vector3i in fixture.blocks:
		owner._resident_blocks.append(resident_block)
		owner._receipt_resident_blocks.append(resident_block)
	owner._receipt_resident_blocks.make_read_only()
	owner._readiness_epoch = 1
	owner._live = {}
	for block: Vector3i in fixture.blocks:
		var body := StaticBody3D.new()
		body.collision_layer = OwnerScript.COLLISION_LAYER
		body.collision_mask = 0
		owner.add_child(body)
		var shapes: Array = []
		for index in range(OwnerScript.MAX_SHAPES_PER_BLOCK):
			var shape := CollisionShape3D.new()
			shape.shape = BoxShape3D.new()
			body.add_child(shape)
			shapes.append(shape)
		owner._live[block] = {"expectedHit":true, "body":body,
			"shapes":shapes, "artifactKey":fixture.source.current.artifacts[block]}
	var result: Dictionary = {"status":"pending"}
	var steps := 0
	var max_operations := 0
	var max_step_usec := 0
	while result.get("status") == "pending" and steps < 8:
		result = owner._advance_physical_health_validation(fixture.identity)
		steps += 1
		max_operations = maxi(max_operations, int(result.get("operations", 0)))
		max_step_usec = maxi(max_step_usec, int(result.get("maxStepUsec", 0)))
	var shape_checks := int(result.get("shapeChecks", 0))
	var passed: bool = result.get("status") == "ready" and steps > 1 \
		and max_operations <= OwnerScript.HEALTH_VALIDATION_OPERATION_BUDGET \
		and shape_checks == 2 * OwnerScript.MAX_SHAPES_PER_BLOCK \
		and owner._health_validated_epoch == owner.physical_readiness_epoch()
	owner.queue_free()
	await get_tree().process_frame
	return {"passed":passed, "result":result, "steps":steps,
		"residentCount":fixture.blocks.size(),
		"shapesPerResident":OwnerScript.MAX_SHAPES_PER_BLOCK,
		"shapeChecks":shape_checks, "maxOperations":max_operations,
		"operationBudget":OwnerScript.HEALTH_VALIDATION_OPERATION_BUDGET,
		"maxStepUsec":max_step_usec,
		"stepUsecBudget":OwnerScript.HEALTH_VALIDATION_STEP_USEC_BUDGET,
		"wallClockHardPreemption":false}


func _cursor_source(count: int, revision: int, label: String) -> Dictionary:
	var source := FakeSource.new()
	var identity := _identity(revision)
	var source_identity := {"hex":"cursor-source-%s-%d" % [label, revision]}
	var blocks: Array[Vector3i] = []
	var artifacts := {}
	for index in range(count):
		var block := Vector3i(index, 0, 0)
		blocks.append(block)
		artifacts[block] = "%s-artifact-%d" % [label, index]
	var row := _source_fields({"block":blocks[0], "artifactKey":artifacts[blocks[0]],
		"vertices":PackedVector3Array(), "bounds":AABB(Vector3.ZERO, Vector3.ONE * 3.0),
		"probeFrom":Vector3(0.5, 2.8, 0.5), "probeTo":Vector3(0.5, 0.2, 0.5),
		"expectedHit":false}, identity, source_identity)
	source.rows = {blocks[0]:row}
	source.current = {"status":"ready", "identity":identity,
		"sourceIdentity":source_identity, "sourceEpoch":identity.sourceEpoch,
		"nativeRevision":revision, "ownerGeneration":identity.ownerGeneration,
		"cancellationEpoch":identity.cancellationEpoch,
		"requiredResidentBlocks":blocks, "residentBlocks":blocks,
		"membershipProvenance":{"authority":"pinned_demand",
			"demandRevision":revision, "closureToken":"%s-closure" % label},
		"artifacts":artifacts}
	return {"source":source, "identity":identity, "sourceIdentity":source_identity,
		"blocks":blocks, "row":row}


func _retirement_receipt_contract() -> Dictionary:
	var source_identity := {"hex":"n5-retirement-source"}
	var identity := {"ownerGeneration":17, "sourceRevision":29,
		"cancellationEpoch":31, "sourceEpoch":"17:n5-retirement-source",
		"sourceIdentity":source_identity}
	var membership := {"authority":"pinned_demand", "demandRevision":37,
		"closureToken":"n5-retirement-closure", "windowToken":"n5-retirement-window"}
	var physical_owner_a = OwnerScript.new()
	var physical_owner_b = OwnerScript.new()
	var physical_owners_distinct: bool = physical_owner_a != physical_owner_b
	var owner_a_assigned: bool = physical_owner_a.assign_retirement_owner_epoch(
		"coordinator-a:install-1")
	var owner_b_assigned: bool = physical_owner_b.assign_retirement_owner_epoch(
		"coordinator-a:install-2")
	var owner_a_epoch: String = physical_owner_a.retirement_owner_epoch()
	var owner_b_epoch: String = physical_owner_b.retirement_owner_epoch()
	physical_owner_a.free()
	physical_owner_b.free()
	var blocks: Array[Vector3i] = [Vector3i(4, 0, -2), Vector3i(5, 0, -2)]
	var record := {"identity":identity, "sourceIdentity":source_identity,
		"membershipProvenance":membership, "blocks":blocks,
		"physicalOwnerEpoch":owner_a_epoch}
	var lease := {"leaseId":"n5-retirement-lease",
		"physicalOwnerEpoch":owner_a_epoch,
		"windowToken":membership.windowToken,
		"expectedLayoutToken":"n5-new-layout",
		"recordIdentity":identity.duplicate(true),
		"sourceIdentity":source_identity.duplicate(true),
		"membershipProvenance":membership.duplicate(true),
		"residentBlocks":blocks.duplicate()}
	var receipt := {"status":"ready", "drained":true, "remainingBodies":0,
		"remainingPendingEntries":0, "remainingLiveEntries":0,
		"sourceReleased":true, "barrierOwnershipReleased":true,
		"windowToken":"n5-retirement-window", "retirementLeaseId":lease.leaseId,
		"identity":identity.duplicate(true),
		"sourceIdentity":source_identity.duplicate(true),
		"membershipProvenance":membership.duplicate(true),
		"physicalOwnerEpoch":owner_a_epoch,
		"residentBlockCount":blocks.size(), "residentBlocks":blocks.duplicate(),
		"requiredResidentBlocks":blocks.duplicate()}
	var valid_current := RetirementReceipt.matches_record(
		membership.windowToken, receipt, record, lease)
	var reordered_current := receipt.duplicate(true)
	reordered_current.residentBlocks.reverse()
	reordered_current.requiredResidentBlocks.reverse()
	var canonical_order_accepted := RetirementReceipt.matches_record(
		membership.windowToken, reordered_current, record, lease)
	var stale_owner := receipt.duplicate(true)
	stale_owner.identity.ownerGeneration += 1
	var stale_owner_same_token_lease := not RetirementReceipt.matches_record(
		membership.windowToken, stale_owner, record, lease)
	var owner_b_record: Dictionary = record.duplicate(true)
	owner_b_record.physicalOwnerEpoch = owner_b_epoch
	var owner_b_lease: Dictionary = lease.duplicate(true)
	owner_b_lease.physicalOwnerEpoch = owner_b_epoch
	var owner_b_receipt_replay_rejected := not RetirementReceipt.matches_record(
		membership.windowToken, receipt, owner_b_record, owner_b_lease)
	var owner_b_current_receipt := receipt.duplicate(true)
	owner_b_current_receipt.physicalOwnerEpoch = owner_b_epoch
	var owner_b_current_accepted := RetirementReceipt.matches_record(
		membership.windowToken, owner_b_current_receipt, owner_b_record,
		owner_b_lease)
	var stale_source := receipt.duplicate(true)
	stale_source.sourceIdentity.hex = "old-source"
	var stale_source_rejected := not RetirementReceipt.matches_record(
		membership.windowToken, stale_source, record, lease)
	var stale_membership := receipt.duplicate(true)
	stale_membership.membershipProvenance.closureToken = "old-closure"
	var stale_membership_rejected := not RetirementReceipt.matches_record(
		membership.windowToken, stale_membership, record, lease)
	var wrong_blocks := receipt.duplicate(true)
	wrong_blocks.residentBlocks[1] = Vector3i(99, 0, 0)
	var wrong_block_membership_rejected := not RetirementReceipt.matches_record(
		membership.windowToken, wrong_blocks, record, lease)
	var duplicate_blocks := receipt.duplicate(true)
	duplicate_blocks.residentBlocks[1] = duplicate_blocks.residentBlocks[0]
	var duplicate_rejected := not RetirementReceipt.matches_record(
		membership.windowToken, duplicate_blocks, record, lease)
	var wrong_count := receipt.duplicate(true)
	wrong_count.residentBlockCount -= 1
	var count_rejected := not RetirementReceipt.matches_record(
		membership.windowToken, wrong_count, record, lease)
	var wrong_token := receipt.duplicate(true)
	wrong_token.windowToken = "reused-token"
	var token_rejected := not RetirementReceipt.matches_record(
		membership.windowToken, wrong_token, record, lease)
	var wrong_lease := receipt.duplicate(true)
	wrong_lease.retirementLeaseId = "reused-lease"
	var lease_rejected := not RetirementReceipt.matches_record(
		membership.windowToken, wrong_lease, record, lease)
	var stale_lease := lease.duplicate(true)
	stale_lease.recordIdentity.ownerGeneration += 1
	var stale_lease_rejected := not RetirementReceipt.lease_matches_record(
		membership.windowToken, record, stale_lease)
	var missing_required_members := receipt.duplicate(true)
	missing_required_members.requiredResidentBlocks.pop_back()
	var required_members_rejected := not RetirementReceipt.matches_record(
		membership.windowToken, missing_required_members, record, lease)
	return {"passed":valid_current and canonical_order_accepted \
		and physical_owners_distinct and owner_a_assigned and owner_b_assigned \
		and stale_owner_same_token_lease \
		and owner_b_receipt_replay_rejected and owner_b_current_accepted \
		and stale_source_rejected and stale_membership_rejected \
		and wrong_block_membership_rejected and duplicate_rejected \
		and count_rejected and token_rejected and lease_rejected \
		and stale_lease_rejected and required_members_rejected,
		"validCurrentReceiptAccepted":valid_current,
		"canonicalMembershipOrderAccepted":canonical_order_accepted,
		"staleOwnerSameTokenLeaseRejected":stale_owner_same_token_lease,
		"distinctPhysicalOwnerInstances":physical_owners_distinct,
		"bothOwnerEpochsAssigned":owner_a_assigned and owner_b_assigned,
		"distinctPhysicalOwnerReceiptReplayRejected":owner_b_receipt_replay_rejected,
		"distinctPhysicalOwnerCurrentReceiptAccepted":owner_b_current_accepted,
		"staleSourceIdentityRejected":stale_source_rejected,
		"staleMembershipRejected":stale_membership_rejected,
		"wrongResidentMembershipRejected":wrong_block_membership_rejected,
		"duplicateResidentRejected":duplicate_rejected,
		"residentCountRejected":count_rejected,
		"windowTokenRejected":token_rejected,
		"retirementLeaseRejected":lease_rejected,
		"staleLeaseRecordRejected":stale_lease_rejected,
		"requiredResidentMembershipRejected":required_members_rejected}


func _bounded_prepare_case() -> Dictionary:
	var source := FakeSource.new()
	var owner = OwnerScript.new()
	add_child(owner)
	owner.bind_source(source)
	var identity := _identity(11)
	var block := Vector3i(900, 0, 0)
	var row := _row(block, "bounded-prepare", 0.5, identity)
	var source_vertices := PackedVector3Array()
	for quad_index in range(384):
		var quad_left := 2700.0 + 3.0 * float(quad_index) / 384.0
		var quad_right := 2700.0 + 3.0 * float(quad_index + 1) / 384.0
		source_vertices.append_array(PackedVector3Array([
			Vector3(quad_left, 0.5, 0.0), Vector3(quad_right, 0.5, 0.0),
			Vector3(quad_right, 0.5, 1.0), Vector3(quad_left, 0.5, 0.0),
			Vector3(quad_right, 0.5, 1.0), Vector3(quad_left, 0.5, 1.0)]))
	row.vertices = source_vertices
	row.block = block
	row.artifactKey = "bounded-prepare"
	row.bounds = AABB(Vector3(2700, 0, 0), Vector3(3, 3, 3))
	row.probeFrom = Vector3(2700.35, 2.8, 0.5)
	row.probeTo = Vector3(2700.35, 0.2, 0.5)
	row = _source_fields(row, identity, {"hex": "fixture-source-11"})
	source.rows = {block: row}
	source.current = {"status": "ready", "identity": identity,
		"sourceIdentity": {"hex": "fixture-source-11"},
		"sourceEpoch": identity.sourceEpoch, "nativeRevision": identity.sourceRevision,
		"ownerGeneration": identity.ownerGeneration,
		"cancellationEpoch": identity.cancellationEpoch,
		"requiredResidentBlocks": [block], "residentBlocks": [block],
		"membershipProvenance": {"authority": "pinned_demand", "demandRevision": 11,
			"closureToken": "bounded-prepare-closure"},
		"artifacts": {block: "bounded-prepare"}}
	var barrier = BarrierScript.new()
	var begun: Dictionary = barrier.begin(self, owner, identity, row.bounds)
	while begun.get("status") == "pending":
		await get_tree().process_frame
		begun = barrier.census_progress(identity)
	var outcome: Dictionary = await owner.publish(_request(identity, [block],
		[block], [row]), barrier)
	var flattened := PackedVector3Array()
	var emitted_shape_sizes: Array[int] = []
	var published_body: StaticBody3D = null
	for body in owner.get_children():
		if body is StaticBody3D:
			published_body = body
			for child in body.get_children():
				if child is CollisionShape3D and child.shape is ConcavePolygonShape3D:
					var shape_vertices: PackedVector3Array = child.shape.data
					emitted_shape_sizes.append(shape_vertices.size())
					flattened.append_array(shape_vertices)
	var seam_hits: Array[Dictionary] = []
	if published_body != null:
		for seam_x in [2701.0, 2702.0]:
			for side in [-1.0, 1.0]:
				var sample_x: float = seam_x + side * 0.002
				var query := PhysicsRayQueryParameters3D.create(
					Vector3(sample_x, 2.8, 0.5), Vector3(sample_x, 0.2, 0.5), 2)
				var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
				seam_hits.append({"seamX": seam_x, "side": side,
					"colliderMatches": hit.get("collider") == published_body})
	var released: bool = barrier.release(identity)
	var drained: Dictionary = await owner.stop_and_drain()
	var chunks_within_budget := true
	for size in emitted_shape_sizes:
		if size <= 0 or size > OwnerScript.PREPARE_VERTEX_BUDGET or size % 3 != 0:
			chunks_within_budget = false
	var seam_probes_hit := seam_hits.size() == 4
	for seam_hit in seam_hits:
		seam_probes_hit = seam_probes_hit and bool(seam_hit.colliderMatches)
	return {"passed": outcome.get("status") == "ready" \
		and int(outcome.get("prepareVertexBudget", -1)) == OwnerScript.PREPARE_VERTEX_BUDGET \
		and int(outcome.get("prepareMaxWorkUnits", -1)) <= OwnerScript.PREPARE_VERTEX_BUDGET \
		and flattened == source_vertices and emitted_shape_sizes.size() == 3 \
		and chunks_within_budget and seam_probes_hit \
		and released and drained.get("status") == "ready",
		"outcome": outcome, "emittedShapeSizes": emitted_shape_sizes,
		"exactGeometryPreserved": flattened == source_vertices,
		"chunksWithinBudget": chunks_within_budget,
		"seamProbeHits": seam_hits,
		"barrierReleased": released, "drain": drained}


func _bounded_drain_case() -> Dictionary:
	var source := FakeSource.new()
	var owner = OwnerScript.new()
	add_child(owner)
	owner.bind_source(source)
	var identity := _identity(12)
	var source_identity := {"hex": "70-live-body-source"}
	var membership := {"authority": "pinned_demand", "demandRevision": 12,
		"closureToken": "70-live-body-closure", "windowToken": "window-n5-70"}
	var blocks: Array[Vector3i] = []
	var rows: Array[Dictionary] = []
	var artifacts := {}
	for index in range(70):
		var block := Vector3i(1200 + index, 0, 0)
		var artifact := "live-body-%d" % index
		var row := _row(block, artifact, 0.5, identity, source_identity)
		var drain_vertices := PackedVector3Array()
		for quad_index in range(256):
			var x0 := float(block.x * 3) + float(quad_index) * (3.0 / 256.0)
			var x1 := float(block.x * 3) + float(quad_index + 1) * (3.0 / 256.0)
			drain_vertices.append_array(PackedVector3Array([
				Vector3(x0, 0.5, 0), Vector3(x1, 0.5, 0), Vector3(x1, 0.5, 1),
				Vector3(x0, 0.5, 0), Vector3(x1, 0.5, 1), Vector3(x0, 0.5, 1)]))
		row.vertices = drain_vertices
		row.bounds = AABB(Vector3(float(block.x * 3), 0, 0), Vector3(3, 3, 3))
		row.probeFrom = Vector3(float(block.x * 3) + 0.35, 2.8, 0.5)
		row.probeTo = Vector3(float(block.x * 3) + 0.35, 0.2, 0.5)
		row.empty = false
		blocks.append(block)
		rows.append(row)
		artifacts[block] = artifact
		source.rows[block] = row
	source.current = {"status": "ready", "identity": identity,
		"sourceIdentity": source_identity, "sourceEpoch": identity.sourceEpoch,
		"nativeRevision": identity.sourceRevision,
		"ownerGeneration": identity.ownerGeneration,
		"cancellationEpoch": identity.cancellationEpoch,
		"requiredResidentBlocks": blocks.duplicate(),
		"residentBlocks": blocks.duplicate(), "membershipProvenance": membership,
		"artifacts": artifacts}
	var barrier = BarrierScript.new()
	var bounds: AABB = rows[0].bounds.merge(rows[69].bounds)
	var begun: Dictionary = barrier.begin(self, owner, identity, bounds)
	while begun.get("status") == "pending":
		await get_tree().process_frame
		begun = barrier.census_progress(identity)
	var first_blocks: Array[Vector3i] = blocks.slice(0, 64)
	var first_rows: Array[Dictionary] = rows.slice(0, 64)
	var first_batch: Dictionary = await owner.publish(_request(identity, blocks,
		first_blocks, first_rows), barrier)
	var last_blocks: Array[Vector3i] = blocks.slice(64, 70)
	var last_rows: Array[Dictionary] = rows.slice(64, 70)
	var last_batch: Dictionary = await owner.publish(_request(identity, blocks,
		last_blocks, last_rows), barrier)
	var bodies_before_stop := owner.get_child_count()
	var live_before_stop := int((owner.get("_live") as Dictionary).size())
	var shapes_before_stop := 0
	for live_value in (owner.get("_live") as Dictionary).values():
		shapes_before_stop += (live_value as Dictionary).get("shapes", []).size()
	var source_before_stop = owner.get("_source")
	var barrier_before_stop = owner.get("_admission_barrier")
	var stop_request: Dictionary = owner.request_stop()
	var unchanged_on_request: bool = owner.get_child_count() == bodies_before_stop \
		and int((owner.get("_live") as Dictionary).size()) == live_before_stop \
		and owner.get("_source") == source_before_stop \
		and owner.get("_admission_barrier") == barrier_before_stop
	var admission_held := not barrier.admit_motion(_actor, Vector3.ZERO)
	var steps: Array[Dictionary] = []
	var bounded_steps := true
	var refs_retained_until_ready := true
	var key_retirement_bounded := true
	var max_work_units := 0
	var max_retired_bodies := 0
	var max_retired_keys := 0
	var terminal: Dictionary = {"status": "pending"}
	for _attempt in range(64):
		var pending_keys_before := (owner.get("_pending_candidate_keys") as Array).size()
		var live_keys_before := (owner.get("_resident_blocks") as Array).size()
		terminal = owner.drain_step()
		steps.append(terminal)
		var work_units := int(terminal.get("drainWorkUnitsThisStep", 0))
		var retired_bodies := int(terminal.get("drainedBodiesThisStep", 0))
		var keys_retired := pending_keys_before \
			- (owner.get("_pending_candidate_keys") as Array).size() \
			+ live_keys_before - (owner.get("_resident_blocks") as Array).size()
		max_work_units = maxi(max_work_units, work_units)
		max_retired_bodies = maxi(max_retired_bodies, retired_bodies)
		max_retired_keys = maxi(max_retired_keys, keys_retired)
		if work_units > OwnerScript.DRAIN_WORK_BUDGET \
				or retired_bodies > OwnerScript.DRAIN_BODY_BUDGET:
			bounded_steps = false
		if keys_retired > work_units:
			key_retirement_bounded = false
		if terminal.get("status") == "ready":
			break
		refs_retained_until_ready = refs_retained_until_ready \
			and owner.get("_source") == source \
			and owner.get("_admission_barrier") == barrier \
			and bool(terminal.get("sourceRetained", false)) \
			and bool(terminal.get("barrierRetained", false))
		await get_tree().process_frame
	var receipt_exact: bool = terminal.get("status") == "ready" \
		and bool(terminal.get("drained", false)) \
		and int(terminal.get("remainingBodies", -1)) == 0 \
		and int(terminal.get("remainingPendingEntries", -1)) == 0 \
		and int(terminal.get("remainingLiveEntries", -1)) == 0 \
		and (owner.get("_pending_candidate_keys") as Array).is_empty() \
		and (owner.get("_resident_blocks") as Array).is_empty() \
		and (owner.get("_pending_candidates") as Dictionary).is_empty() \
		and (owner.get("_live") as Dictionary).is_empty() \
		and bool(terminal.get("sourceReleased", false)) \
		and bool(terminal.get("barrierOwnershipReleased", false)) \
		and int(terminal.get("residentBlockCount", -1)) == blocks.size() \
		and terminal.get("residentBlocks") == blocks \
		and terminal.get("requiredResidentBlocks") == blocks \
		and terminal.get("windowToken") == membership.windowToken \
		and terminal.get("identity") == identity \
		and terminal.get("sourceIdentity") == source_identity \
		and terminal.get("membershipProvenance") == membership
	var internal_refs_released := owner.get("_source") == null \
		and owner.get("_admission_barrier") == null \
		and (owner.get("_identity") as Dictionary).is_empty() \
		and (owner.get("_source_identity") as Dictionary).is_empty() \
		and (owner.get("_membership_provenance") as Dictionary).is_empty()
	return {"passed": first_batch.get("status") == "pending" \
		and last_batch.get("status") == "ready" and bodies_before_stop == 70 \
		and shapes_before_stop == 140 \
		and live_before_stop == 70 and stop_request.get("status") == "pending" \
		and unchanged_on_request and admission_held and bounded_steps \
		and key_retirement_bounded and refs_retained_until_ready \
		and receipt_exact and internal_refs_released,
		"firstBatch": first_batch.get("status"), "lastBatch": last_batch.get("status"),
		"bodiesBeforeStop": bodies_before_stop, "liveEntriesBeforeStop": live_before_stop,
		"childShapesBeforeStop": shapes_before_stop,
		"stopRequest": stop_request, "unchangedOnRequest": unchanged_on_request,
		"admissionHeld": admission_held, "boundedSteps": bounded_steps,
		"keyRetirementBounded": key_retirement_bounded,
		"maxWorkUnits": max_work_units, "maxRetiredBodies": max_retired_bodies,
		"maxRetiredKeys": max_retired_keys,
		"stepCount": steps.size(), "steps": steps,
		"referencesRetainedUntilReady": refs_retained_until_ready,
		"receiptExact": receipt_exact, "internalRefsReleased": internal_refs_released,
		"childShapesPerBody": 2, "receipt": terminal}


func _mid_switch_drift_case() -> Dictionary:
	var source := FakeSource.new()
	var owner = OwnerScript.new()
	add_child(owner)
	owner.bind_source(source)
	var first := _identity(1)
	var blocks: Array[Vector3i] = [Vector3i(800, 0, 0), Vector3i(801, 0, 0)]
	var old_rows := [_row(blocks[0], "mid-old-a", 0.5, first),
		_row(blocks[1], "mid-old-b", 0.5, first)]
	source.rows = {blocks[0]: old_rows[0], blocks[1]: old_rows[1]}
	source.current = _snapshot(first, blocks, "mid-old-a", "mid-old-b")
	var first_barrier = BarrierScript.new()
	var begun: Dictionary = first_barrier.begin(self, owner, first,
		old_rows[0].bounds.merge(old_rows[1].bounds))
	while begun.get("status") == "pending":
		await get_tree().process_frame
		begun = first_barrier.census_progress(first)
	var startup: Dictionary = await owner.publish(_request(first, blocks, blocks,
		old_rows), first_barrier)
	var old_body: StaticBody3D = null
	var old_body_ids := {}
	for child in owner.get_children():
		if child is StaticBody3D:
			old_body_ids[child.get_instance_id()] = true
	var original_hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(old_rows[0].probeFrom,
			old_rows[0].probeTo, 2))
	old_body = original_hit.get("collider") as StaticBody3D
	var second := _identity(2)
	var new_rows := [_row(blocks[0], "mid-new-a", 1.0, second),
		_row(blocks[1], "mid-new-b", 1.0, second)]
	source.rows = {blocks[0]: new_rows[0], blocks[1]: new_rows[1]}
	source.current = _snapshot(second, blocks, "mid-new-a", "mid-new-b")
	var second_barrier = BarrierScript.new()
	var second_begun: Dictionary = second_barrier.begin(self, owner, second,
		new_rows[0].bounds.merge(new_rows[1].bounds))
	while second_begun.get("status") == "pending":
		await get_tree().process_frame
		second_begun = second_barrier.census_progress(second)
	var changed := [false]
	var on_row_query := func(block: Vector3i):
		if block != blocks[1] or changed[0]:
			return
		for child in owner.get_children():
			if child is StaticBody3D and not old_body_ids.has(child.get_instance_id()) \
					and child.collision_layer == 2:
				var altered: Dictionary = new_rows[1].duplicate(true)
				altered.probeFrom.x += 0.01
				source.rows[blocks[1]] = altered
				changed[0] = true
				return
	source.row_query_hook = on_row_query
	var refused: Dictionary = await owner.publish(_request(second, blocks, blocks,
		new_rows), second_barrier)
	source.row_query_hook = Callable()
	var old_hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(old_rows[0].probeFrom,
			old_rows[0].probeTo, 2))
	var old_restored: bool = old_body != null and old_hit.get("collider") == old_body
	source.rows[blocks[1]] = new_rows[1]
	var retry: Dictionary = await owner.publish(_request(second, blocks, blocks,
		new_rows), second_barrier)
	var released: bool = second_barrier.release(second)
	var drained: Dictionary = await owner.stop_and_drain()
	return {"passed": startup.get("status") == "ready" and changed[0] \
		and refused.get("status") == "pending" \
		and refused.get("reason") == "candidate_source_row_drift" \
		and bool(refused.get("oldPhysicalRestored", false)) and old_restored \
		and retry.get("status") == "ready" and released \
		and drained.get("status") == "ready",
		"startup": startup, "driftTriggeredAfterFirstSwitch": changed[0],
		"refused": refused, "oldColliderRestored": old_restored,
		"retry": retry, "released": released, "drained": drained}


func _pre_switch_drift_case() -> Dictionary:
	var source := FakeSource.new()
	var owner = OwnerScript.new()
	add_child(owner)
	owner.bind_source(source)
	var identity := _identity(1)
	var blocks: Array[Vector3i] = [Vector3i(700, 0, 0), Vector3i(701, 0, 0)]
	var first_row: Dictionary = _row(blocks[0], "pre-a", 0.5, identity)
	var second_row: Dictionary = _row(blocks[1], "pre-b", 0.5, identity)
	source.rows = {blocks[0]: first_row, blocks[1]: second_row}
	source.current = _snapshot(identity, blocks, "pre-a", "pre-b")
	var barrier = BarrierScript.new()
	var begun: Dictionary = barrier.begin(self, owner, identity,
		first_row.bounds.merge(second_row.bounds))
	while begun.get("status") == "pending":
		await get_tree().process_frame
		begun = barrier.census_progress(identity)
	var ticks := [0]
	var mutate := func():
		ticks[0] = int(ticks[0]) + 1
		if int(ticks[0]) == 2:
			var altered: Dictionary = first_row.duplicate(true)
			altered.probeFrom = Vector3(altered.probeFrom.x + 0.01,
				altered.probeFrom.y, altered.probeFrom.z)
			source.rows[blocks[0]] = altered
	get_tree().process_frame.connect(mutate)
	var refused: Dictionary = await owner.publish(_request(identity, blocks, blocks,
		[first_row, second_row]), barrier)
	if get_tree().process_frame.is_connected(mutate):
		get_tree().process_frame.disconnect(mutate)
	source.rows[blocks[0]] = first_row
	var retried: Dictionary = await owner.publish(_request(identity, blocks, blocks,
		[first_row, second_row]), barrier)
	var released: bool = barrier.release(identity)
	var drained: Dictionary = await owner.stop_and_drain()
	return {"passed": refused.get("status") == "pending" \
		and refused.get("reason") == "candidate_source_row_drift" \
		and bool(refused.get("oldPhysicalUnchanged", false)) \
		and retried.get("status") == "ready" and released \
		and drained.get("status") == "ready" \
		and int(drained.get("remainingBodies", -1)) == 0,
		"refused": refused, "retry": retried, "released": released,
		"drained": drained, "processFrames": int(ticks[0])}


func _source_drift_case() -> Dictionary:
	var source := FakeSource.new()
	var owner = OwnerScript.new()
	add_child(owner)
	owner.bind_source(source)
	var identity := _identity(1)
	var blocks: Array[Vector3i] = [Vector3i(600, 0, 0)]
	var row: Dictionary = _row(blocks[0], "drift-artifact", 0.5,
		identity, {"hex": "drift-source"})
	source.rows[blocks[0]] = row
	source.current = {"status": "ready", "identity": identity,
		"sourceIdentity": {"hex": "drift-source"},
		"sourceEpoch": identity.sourceEpoch,
		"nativeRevision": identity.sourceRevision,
		"ownerGeneration": identity.ownerGeneration,
		"cancellationEpoch": identity.cancellationEpoch,
		"requiredResidentBlocks": blocks.duplicate(),
		"residentBlocks": blocks.duplicate(),
		"membershipProvenance": {"authority": "pinned_demand", "demandRevision": 1,
			"closureToken": "first-closure"},
		"artifacts": {blocks[0]: "drift-artifact"}}
	var barrier = BarrierScript.new()
	var begun: Dictionary = barrier.begin(self, owner, identity, row.bounds)
	while begun.get("status") == "pending":
		await get_tree().process_frame
		begun = barrier.census_progress(identity)
	var change_closure := func():
		source.current.membershipProvenance.closureToken = "changed-same-revision"
	get_tree().process_frame.connect(change_closure, CONNECT_ONE_SHOT)
	var outcome: Dictionary = await owner.publish(_request(identity, blocks,
		blocks, [row]), barrier)
	var readiness: Dictionary = owner.startup_readiness(identity)
	var release: bool = barrier.release(identity)
	source.current.membershipProvenance.closureToken = "first-closure"
	var retried: Dictionary = await owner.publish(_request(identity, blocks,
		blocks, [row]), barrier)
	var retried_release: bool = barrier.release(identity)
	var drained: Dictionary = await owner.stop_and_drain()
	return {"passed": outcome.get("status") == "pending" \
		and not bool(outcome.get("sourceCurrent", true)) \
		and bool(outcome.get("oldPhysicalRestored", false)) \
		and readiness.get("status") == "pending" and not release \
		and retried.get("status") == "ready" and retried_release \
		and drained.get("status") == "ready" \
		and int(drained.get("remainingBodies", -1)) == 0,
		"outcome": outcome, "readiness": readiness, "release": release,
		"retry": retried, "retryRelease": retried_release,
		"drained": drained}


func _capture_first_drain(owner: Node3D, token: String) -> void:
	_captured_drains[token] = await owner.stop_and_drain()


func _capture_rollback_drain(owner: Node3D, token: String,
		prior_live_body_ids: Dictionary, candidate_body: StaticBody3D,
		rollback_wait_observed: Array) -> void:
	var old_live_enabled := false
	for child in owner.get_children():
		if child is StaticBody3D and prior_live_body_ids.has(child.get_instance_id()) \
				and child.collision_layer == 2:
			old_live_enabled = true
			break
	var candidate_retired := not is_instance_valid(candidate_body) \
		or candidate_body.collision_layer == 0 and candidate_body.is_queued_for_deletion()
	rollback_wait_observed[0] = bool(owner.get("_busy")) \
		and old_live_enabled and candidate_retired
	_captured_drains[token] = await owner.stop_and_drain()


func _capture_post_commit_drain(owner: Node3D, token: String,
		identity: Dictionary, block: Vector3i, prior_live_body_ids: Dictionary,
		stop_triggered: Array, observation: Array) -> void:
	for _frame in range(180):
		var candidate: Dictionary = owner.get("_live").get(block, {})
		var candidate_body = candidate.get("body")
		var old_body_present := false
		for child in owner.get_children():
			if child is StaticBody3D \
					and prior_live_body_ids.has(child.get_instance_id()):
				old_body_present = true
				break
		if bool(owner.get("_busy")) and owner.get("_identity") == identity \
				and is_instance_valid(candidate_body) \
				and not prior_live_body_ids.has(candidate_body.get_instance_id()) \
				and old_body_present:
			stop_triggered[0] = true
			observation[0] = {"observedPostCommitHealthAwait":true,
				"busy":bool(owner.get("_busy")),
				"identityCommitted":owner.get("_identity").duplicate(true),
				"candidateBodyInstanceId":candidate_body.get_instance_id(),
				"oldBodyStillPresent":old_body_present,
				"requiredPhysicsFrame":int(owner.get("_health_required_physics_frame")),
				"physicsFrame":Engine.get_physics_frames()}
			_captured_drains[token] = await owner.stop_and_drain()
			return
		await get_tree().process_frame
	observation[0] = {"observedPostCommitHealthAwait":false,
		"reason":"post_commit_state_not_observed"}


func _shutdown_case(phase: String) -> Dictionary:
	var source := FakeSource.new()
	var owner = OwnerScript.new()
	add_child(owner)
	owner.bind_source(source)
	var token := "%s-%d" % [phase, Time.get_ticks_usec()]
	if phase == "post_commit_health":
		var owner_epoch := "fixture-owner-%s" % token
		var admission: Object = _new_fixture_ledger("fixture-ledger-%s" % token)
		assert(owner.assign_retirement_owner_epoch(owner_epoch),
			"post-commit fixture assigns owner epoch")
		assert(owner.bind_memory_admission(admission,
			"fixture-window-%s" % token, owner_epoch),
			"post-commit fixture binds real admission ledger")
	var identity := _identity(1)
	var phase_x := {"prepare": 400, "post_prepare_validation": 500,
		"pre_switch_validation": 600, "ack_validation": 700,
		"rollback": 800, "post_commit_health": 900}
	var blocks: Array[Vector3i] = [Vector3i(int(phase_x.get(phase, 900)), 0, 0)]
	var seeded_live := true
	var seed_outcome := {}
	var seed_released := false
	if phase in ["rollback", "post_commit_health"]:
		var seed_row: Dictionary = _row(blocks[0], "shutdown-live-seed", 0.5,
			identity, {"hex": "shutdown-live-source"})
		source.rows[blocks[0]] = seed_row
		source.current = _shutdown_snapshot(identity, blocks,
			"shutdown-live-seed", "shutdown-live-source", "shutdown-live-closure")
		var seed_barrier = BarrierScript.new()
		var seed_begun: Dictionary = seed_barrier.begin(self, owner, identity,
			seed_row.bounds)
		while seed_begun.get("status") == "pending":
			await get_tree().process_frame
			seed_begun = seed_barrier.census_progress(identity)
		seed_outcome = await owner.publish(_request(identity, blocks, blocks,
			[seed_row]), seed_barrier)
		seed_released = seed_barrier.release(identity)
		seeded_live = seed_outcome.get("status") == "ready" and seed_released
		identity = _identity(2)
	var source_hex := "shutdown-source-%s" % phase
	var row: Dictionary = _row(blocks[0], "shutdown-artifact", 1.0,
		identity, {"hex": source_hex})
	source.rows[blocks[0]] = row
	source.current = _shutdown_snapshot(identity, blocks, "shutdown-artifact",
		source_hex, "shutdown-closure-%s" % phase)
	var barrier = BarrierScript.new()
	var begun: Dictionary = barrier.begin(self, owner, identity, row.bounds)
	while begun.get("status") == "pending":
		await get_tree().process_frame
		begun = barrier.census_progress(identity)
	var stop_triggered := [false]
	var post_commit_observation := [{}]
	var enabled_candidate_observed := [false]
	var rollback_failure_forced := [false]
	var rollback_wait_observed := [false]
	var candidate_body: Array[StaticBody3D] = [null]
	var row_queries := [0]
	var prior_live_body_ids := {}
	if phase in ["rollback", "post_commit_health"]:
		for child in owner.get_children():
			if child is StaticBody3D:
				prior_live_body_ids[child.get_instance_id()] = true
	var schedule_stop := func():
		if bool(stop_triggered[0]):
			return
		stop_triggered[0] = true
		_capture_first_drain(owner, token)
	if phase == "prepare":
		get_tree().process_frame.connect(schedule_stop, CONNECT_ONE_SHOT)
	elif phase in ["post_prepare_validation", "pre_switch_validation"]:
		var target_query := 2 if phase == "post_prepare_validation" else 3
		source.row_query_hook = func(_block: Vector3i):
			row_queries[0] = int(row_queries[0]) + 1
			if int(row_queries[0]) == target_query:
				get_tree().process_frame.connect(schedule_stop, CONNECT_ONE_SHOT)
	elif phase in ["ack_validation", "rollback"]:
		source.row_query_hook = func(block: Vector3i):
			row_queries[0] = int(row_queries[0]) + 1
			for child in owner.get_children():
				if child is StaticBody3D and child.collision_layer == 2 \
						and not prior_live_body_ids.has(child.get_instance_id()):
					enabled_candidate_observed[0] = true
					candidate_body[0] = child
					if phase == "rollback":
						_actor.position = row.bounds.position + Vector3(0.5, 0.5, 0.5)
						rollback_failure_forced[0] = true
						var stop_after_row_validation := func():
							stop_triggered[0] = true
							call_deferred("_capture_rollback_drain", owner, token,
								prior_live_body_ids, candidate_body[0],
								rollback_wait_observed)
						get_tree().process_frame.connect(stop_after_row_validation,
							CONNECT_ONE_SHOT)
					else:
						schedule_stop.call()
					return
	elif phase == "post_commit_health":
		call_deferred("_capture_post_commit_drain", owner, token, identity,
			blocks[0], prior_live_body_ids, stop_triggered,
			post_commit_observation)
	var outcome: Dictionary = await owner.publish(_request(identity, blocks, blocks,
		[row]), barrier)
	source.row_query_hook = Callable()
	for _wait_frame in range(30):
		if _captured_drains.has(token):
			break
		await get_tree().process_frame
	var first_stop_completed := _captured_drains.has(token)
	var drained: Dictionary
	if first_stop_completed:
		drained = _captured_drains[token]
		_captured_drains.erase(token)
	else:
		drained = await owner.stop_and_drain()
	var owner_failed_after_stop := bool(owner.get("_failed"))
	var later: Dictionary = await owner.publish(_request(identity, blocks, blocks, [row]), barrier)
	var phase_observed := true
	if phase in ["post_prepare_validation", "pre_switch_validation"]:
		phase_observed = int(row_queries[0]) == (2 if phase == "post_prepare_validation" else 3)
	elif phase in ["ack_validation", "rollback"]:
		phase_observed = bool(enabled_candidate_observed[0])
	elif phase == "post_commit_health":
		phase_observed = bool(post_commit_observation[0].get(
			"observedPostCommitHealthAwait", false))
	if phase == "rollback":
		phase_observed = phase_observed and bool(rollback_failure_forced[0]) \
			and bool(rollback_wait_observed[0])
	var terminal_hold := not barrier.admit_motion(_actor, Vector3.ZERO)
	_actor.position = Vector3(100, 0, 0)
	await get_tree().physics_frame
	var expected_stop_reason := "resident_owner_stopping_after_commit" \
		if phase == "post_commit_health" else "resident_owner_stopping"
	return {"passed": seeded_live and bool(stop_triggered[0]) and first_stop_completed \
		and phase_observed and outcome.get("status") == "failed" \
		and outcome.get("reason") == expected_stop_reason \
		and not outcome.has("oldPhysicalUnchanged") \
		and not outcome.has("oldPhysicalRestored") \
		and drained.get("status") == "ready" \
		and int(drained.get("remainingBodies", -1)) == 0 \
		and not owner_failed_after_stop \
		and later.get("status") == "failed" \
		and later.get("reason") == "resident_owner_unavailable" \
		and terminal_hold,
		"phase": phase, "stopTriggered": stop_triggered[0],
		"firstStopCompleted": first_stop_completed,
		"phaseObserved": phase_observed, "rowQueries": row_queries[0],
		"postCommitObservation":post_commit_observation[0],
		"enabledCandidateObserved": enabled_candidate_observed[0],
		"rollbackFailureForced": rollback_failure_forced[0],
		"rollbackWaitObserved": rollback_wait_observed[0],
		"seededLive": seeded_live, "seedOutcome": seed_outcome,
		"seedReleased": seed_released,
		"ownerFailedAfterStop": owner_failed_after_stop,
		"outcome": outcome, "drained": drained, "later": later,
		"terminalHold": terminal_hold}


func _shutdown_snapshot(identity: Dictionary, blocks: Array[Vector3i],
		artifact_key: String, source_hex: String, closure_token: String) -> Dictionary:
	return {"status": "ready", "identity": identity,
		"sourceIdentity": {"hex": source_hex},
		"sourceEpoch": identity.sourceEpoch,
		"nativeRevision": identity.sourceRevision,
		"ownerGeneration": identity.ownerGeneration,
		"cancellationEpoch": identity.cancellationEpoch,
		"requiredResidentBlocks": blocks.duplicate(),
		"residentBlocks": blocks.duplicate(),
		"membershipProvenance": {"authority": "pinned_demand", "demandRevision": 1,
			"closureToken": closure_token},
		"artifacts": {blocks[0]: artifact_key}}


func _identity(revision: int) -> Dictionary:
	return {"ownerGeneration": 1, "sourceRevision": revision,
		"cancellationEpoch": revision, "sourceEpoch": "fixture-epoch"}


func _snapshot(identity: Dictionary, blocks: Array[Vector3i],
		first_key: String, second_key: String) -> Dictionary:
	return {"status": "ready", "identity": identity.duplicate(true),
		"sourceIdentity": {"hex": "fixture-source-%d" % int(identity.sourceRevision)},
		"sourceEpoch": identity.sourceEpoch, "nativeRevision": identity.sourceRevision,
		"ownerGeneration": identity.ownerGeneration,
		"cancellationEpoch": identity.cancellationEpoch,
		"requiredResidentBlocks": blocks.duplicate(),
		"membershipProvenance": {"authority": "pinned_demand", "demandRevision": 1,
			"closureToken": "fixture-demand-closure"},
		"residentBlocks": blocks.duplicate(),
		"artifacts": {blocks[0]: first_key, blocks[1]: second_key}}


func _row(block: Vector3i, artifact_key: String, height: float,
		identity: Dictionary, source_identity: Dictionary = {}) -> Dictionary:
	var start_x := float(block.x * 3)
	var vertices := PackedVector3Array([
		Vector3(start_x, height, 0), Vector3(start_x + 1, height, 0),
		Vector3(start_x + 1, height, 1),
		Vector3(start_x, height, 0), Vector3(start_x + 1, height, 1),
		Vector3(start_x, height, 1)])
	var row := {"block": block, "artifactKey": artifact_key,
		"vertices": vertices, "bounds": AABB(Vector3(start_x, 0, 0),
			Vector3(3, 3, 3)), "probeFrom": Vector3(start_x + 0.35, 2.8, 0.5),
		"probeTo": Vector3(start_x + 0.35, 0.2, 0.5), "expectedHit": true}
	if source_identity.is_empty():
		source_identity = {"hex": "fixture-source-%d" % int(identity.sourceRevision)}
	return _source_fields(row, identity, source_identity)


func _source_fields(row: Dictionary, identity: Dictionary,
		source_identity: Dictionary) -> Dictionary:
	row["sourceIdentity"] = source_identity.duplicate(true)
	row["pinIdentity"] = {"hex": "fixture-pin-%s" % str(row.block)}
	row["blockContentIdentity"] = {"hex": "fixture-content-%s" % row.artifactKey}
	row["nativeRevision"] = identity.sourceRevision
	row["shapingRegistryRevision"] = 1
	row["sourceEpoch"] = identity.sourceEpoch
	row["ownerGeneration"] = identity.ownerGeneration
	row["cancellationEpoch"] = identity.cancellationEpoch
	row["coordinateFrame"] = "world"
	row["empty"] = (row.vertices as PackedVector3Array).is_empty()
	return row


func _request(identity: Dictionary, resident: Array[Vector3i],
		affected: Array[Vector3i], rows: Array) -> Dictionary:
	return {"schema": "n5-resident-collision-publication/v1",
		"identity": identity, "residentBlocks": resident,
		"affectedBlocks": affected, "rows": rows}


func _finish(passed: bool, evidence: Dictionary) -> void:
	var report := {"schema": "n5-resident-collision-owner-fixture/v1",
		"passed": passed, "evidenceLevel": "real Godot physics mechanism fixture",
		"productionCutover": false, "sourceRowsFixture": true,
		"elapsedMilliseconds": float(Time.get_ticks_usec() - _started_usec) / 1000.0,
		"godotVersion": Engine.get_version_info(), "evidence": evidence}
	var path := OS.get_environment("N5_RESIDENT_COLLISION_REPORT")
	if not path.is_empty():
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
			file.close()
	get_tree().quit(0 if passed else 1)
