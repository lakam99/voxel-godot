extends Node3D

const OwnerScript = preload("res://scripts/terrain/NativeResidentCollisionOwner.gd")
const BarrierScript = preload("res://scripts/terrain/NativeCollisionAdmissionBarrier.gd")
const RetirementReceipt = preload("res://scripts/terrain/NativeCollisionRetirementReceipt.gd")

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
	var main_drain: Dictionary = await _owner.stop_and_drain()
	var staged_drain: Dictionary = await staged_owner.stop_and_drain()
	var stop_during_prepare: Dictionary = await _shutdown_case("prepare")
	var stop_during_post_prepare: Dictionary = await _shutdown_case(
		"post_prepare_validation")
	var stop_during_pre_switch: Dictionary = await _shutdown_case(
		"pre_switch_validation")
	var stop_during_ack: Dictionary = await _shutdown_case("ack_validation")
	var stop_during_rollback: Dictionary = await _shutdown_case("rollback")
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
		and main_drain.get("status") == "ready" and int(main_drain.get("remainingBodies", -1)) == 0 \
		and staged_drain.get("status") == "ready" and int(staged_drain.get("remainingBodies", -1)) == 0 \
		and bool(stop_during_prepare.get("passed", false)) \
		and bool(stop_during_post_prepare.get("passed", false)) \
		and bool(stop_during_pre_switch.get("passed", false)) \
		and bool(stop_during_ack.get("passed", false)) \
		and bool(stop_during_rollback.get("passed", false)) \
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
		"drain": {"main": main_drain, "staged": staged_drain,
			"duringPrepare": stop_during_prepare,
			"duringPostPrepareValidation": stop_during_post_prepare,
			"duringPreSwitchValidation": stop_during_pre_switch,
			"duringAck": stop_during_ack,
			"duringRollback": stop_during_rollback},
		"sameRevisionDrift": same_revision_drift,
		"preSwitchDrift": pre_switch_drift,
		"midSwitchDrift": mid_switch_drift,
		"boundedPreparation": bounded_prepare,
		"boundedDrain": bounded_drain,
		"boundedValidation": bounded_validation,
		"retirementReceipt": retirement_receipt_contract})


func _bounded_validation_contract() -> Dictionary:
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
		and int(wide_check.get("maxValidationStepUsec", 0)) >= 0 \
		and wide_drain.get("status") == "ready" \
		and over_check.get("status") == "failed" \
		and over_check.get("reason") == "resident_request_capacity_invalid" \
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
		"maxResident":{"status":wide_check.get("status"),
			"maxOperations":wide_check.get("maxValidationOperations", -1),
			"maxStepUsec":wide_check.get("maxValidationStepUsec", -1),
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


func _shutdown_case(phase: String) -> Dictionary:
	var source := FakeSource.new()
	var owner = OwnerScript.new()
	add_child(owner)
	owner.bind_source(source)
	var identity := _identity(1)
	var phase_x := {"prepare": 400, "post_prepare_validation": 500,
		"pre_switch_validation": 600, "ack_validation": 700,
		"rollback": 800}
	var blocks: Array[Vector3i] = [Vector3i(int(phase_x.get(phase, 900)), 0, 0)]
	var seeded_live := true
	var seed_outcome := {}
	var seed_released := false
	if phase == "rollback":
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
	var token := "%s-%d" % [phase, Time.get_ticks_usec()]
	var stop_triggered := [false]
	var enabled_candidate_observed := [false]
	var rollback_failure_forced := [false]
	var rollback_wait_observed := [false]
	var candidate_body: Array[StaticBody3D] = [null]
	var row_queries := [0]
	var prior_live_body_ids := {}
	if phase == "rollback":
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
	if phase == "rollback":
		phase_observed = phase_observed and bool(rollback_failure_forced[0]) \
			and bool(rollback_wait_observed[0])
	var terminal_hold := not barrier.admit_motion(_actor, Vector3.ZERO)
	_actor.position = Vector3(100, 0, 0)
	await get_tree().physics_frame
	return {"passed": seeded_live and bool(stop_triggered[0]) and first_stop_completed \
		and phase_observed and outcome.get("status") == "failed" \
		and outcome.get("reason") == "resident_owner_stopping" \
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
