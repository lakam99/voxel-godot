extends Node3D
class_name NativeWindowedCollisionCoordinator

signal window_retirement_drain_started(window_id: Vector3i,
	window_token: String, retirement_lease_id: String)

const Aggregate = preload("res://scripts/terrain/NativeWindowedCollisionReadiness.gd")
const AdmissionBarrier = preload("res://scripts/terrain/NativeCollisionAdmissionBarrier.gd")
const MAX_RETIRED_BARRIERS := 64
const MAX_ACTIVE_BARRIERS := 128
const MAX_STAGED_REPLACEMENTS := 1
const MAX_DISPLACED_OWNERS := 1
const AGGREGATE_VALIDATION_OPERATION_BUDGET := 96
const AGGREGATE_VALIDATION_STEP_USEC_BUDGET := 1500

## Composes current N3 logical windows with N5 physical owners and owns the
## actor admission barriers. A window owner cannot release a global gate.
var _broker: Object
var _actor_root: Node
var _memory_admission: Object
var _owners := {}
var _owner_windows := {}
## One make-before-break candidate may exist at a time. It is deliberately
## excluded from aggregate admission until commit_staged_replacement atomically
## switches the authoritative owner tuple.
var _staged_owners := {}
## The displaced physical owner remains independently addressable until its
## old window token has been drained and acknowledged by the broker.
var _displaced_owners := {}
var _owner_epochs := {}
var _owner_epoch_sequence := 0
var _window_tokens := {}
var _retirement_leases := {}
var _retirement_inflight := {}
var _barriers := {}
var _barrier_identities := {}
var _barrier_bounds := {}
var _barrier_window_tokens := {}
var _retired_barriers: Array[Dictionary] = []
var _stopping := false
var _aggregate_ticket := ""
var _aggregate_source_ticket := ""
var _aggregate_layout := {}
var _aggregate_identity := {}
var _aggregate_receipts := {}
var _aggregate_owner_epochs := {}
var _aggregate_cursor := {}
var _aggregate_window_cursor := 0
var _aggregate_result := {}
var _aggregate_last_step_frame := -1

func _process(_delta: float) -> void:
	_advance_aggregate_validation()

func setup(broker: Object, actor_root: Node,
		memory_admission: Object = null) -> Dictionary:
	if _broker != null or broker == null or actor_root == null \
			or memory_admission == null \
			or not memory_admission.has_method("is_active") \
			or not memory_admission.has_method("snapshot") \
			or not memory_admission.has_method("owner_reservation_receipt") \
			or not memory_admission.has_method("drain_receipt") \
			or not broker.has_method("collision_window_layout") \
			or not broker.has_method("acknowledge_collision_window_retired") \
			or not broker.has_method("claim_collision_window_retirement") \
			or not broker.has_method("validate_collision_window_retirement") \
			or not broker.has_method("abort_collision_window_retirement") \
			or not bool(memory_admission.call("is_active")):
		return {"status":"failed", "reason":"window_coordinator_source_invalid"}
	_broker = broker
	_actor_root = actor_root
	_memory_admission = memory_admission
	return {"status":"ready"}

## Admission target contract consumed by MainCore. It may bind during startup,
## but ingress stays closed until every demanded physical window is current.
func is_active() -> bool:
	return not _stopping and _broker != null and _actor_root != null

func can_unbind() -> bool:
	return _stopping and _owners.is_empty() and _staged_owners.is_empty() \
		and _displaced_owners.is_empty() and _retirement_inflight.is_empty() \
		and active_barrier_count() == 0

func _physical_admission_ready() -> bool:
	if not is_active(): return false
	var layout: Dictionary = _broker.collision_window_layout()
	if layout.get("status") != "ready" or not layout.get("identity") is Dictionary:
		return false
	return bool(physical_receipt(layout.identity).get("ready", false))

func register_window(window: Dictionary, owner: Node3D) -> Dictionary:
	if _stopping or owner == null or not owner.is_inside_tree() \
			or not owner.has_method("physical_receipt") \
			or not owner.has_method("retirement_owner_epoch") \
			or not window.get("id") is Vector3i \
			or String(window.get("windowToken", "")).is_empty():
		return {"status":"failed", "reason":"physical_window_registration_invalid"}
	var layout: Dictionary = _broker.collision_window_layout()
	if layout.get("status") != "ready" or not (layout.windows as Array).has(window):
		return {"status":"pending", "reason":"physical_window_layout_changed"}
	if _owners.has(window.id) and _owners[window.id] != owner:
		return {"status":"pending", "reason":"old_physical_window_not_retired"}
	if not _owners.has(window.id):
		if not owner.has_method("assign_retirement_owner_epoch") \
				or not owner.has_method("bind_memory_admission"):
			return {"status":"failed", "reason":"physical_window_owner_epoch_api_missing"}
		_owner_epoch_sequence += 1
		var owner_epoch := "%d:%d" % [get_instance_id(), _owner_epoch_sequence]
		if not bool(owner.call("assign_retirement_owner_epoch", owner_epoch)):
			return {"status":"failed", "reason":"physical_window_owner_epoch_rejected"}
		if not bool(owner.call("bind_memory_admission", _memory_admission,
				String(window.windowToken), owner_epoch)):
			return {"status":"failed", "reason":"physical_window_memory_ledger_binding_rejected"}
		_owner_epochs[window.id] = owner_epoch
	_owners[window.id] = owner
	_window_tokens[window.id] = window.windowToken
	_owner_windows[window.id] = window.duplicate(true)
	return {"status":"ready", "windowId":window.id,
		"windowToken":window.windowToken,
		"physicalOwnerEpoch":_owner_epochs[window.id]}

## Prepare a full replacement beside the current physical owner. The active
## registry remains unchanged; callers must publish and health-validate the
## candidate before commit_staged_replacement.
func stage_window_replacement(window: Dictionary, owner: Node3D) -> Dictionary:
	if _stopping or owner == null or not owner.is_inside_tree() \
			or not owner.has_method("physical_receipt") \
			or not owner.has_method("assign_retirement_owner_epoch") \
			or not owner.has_method("bind_memory_admission") \
			or not owner.has_method("retirement_owner_epoch") \
			or not owner.has_method("physical_readiness_epoch") \
			or not window.get("id") is Vector3i \
			or String(window.get("windowToken", "")).is_empty():
		return {"status":"failed", "reason":"physical_window_replacement_invalid"}
	if _staged_owners.size() >= MAX_STAGED_REPLACEMENTS:
		return {"status":"pending", "reason":"physical_window_replacement_capacity",
			"retryable":true, "candidateCount":_staged_owners.size()}
	if not _owners.has(window.id) or _displaced_owners.has(window.id):
		return {"status":"pending", "reason":"physical_window_replacement_owner_unavailable"}
	if _retirement_leases.has(window.id) or _retirement_inflight.has(window.id):
		return {"status":"pending", "reason":"physical_window_incumbent_retirement_inflight"}
	var layout_ticket: Dictionary = _broker.call("collision_window_layout_ticket") \
		if _broker.has_method("collision_window_layout_ticket") else {}
	var layout: Dictionary = layout_ticket.get("layout", {})
	if layout_ticket.get("status") != "ready" \
			or layout.get("identity") != window.get("identity") \
			or not (layout.get("windows", []) as Array).has(window):
		return {"status":"pending", "reason":"physical_window_layout_changed"}
	var id: Vector3i = window.id
	var old_owner: Node3D = _owners[id]
	if not is_instance_valid(old_owner) \
			or String(old_owner.call("retirement_owner_epoch")) \
			!= String(_owner_epochs.get(id, "")):
		return {"status":"failed", "reason":"physical_window_owner_epoch_mismatch"}
	var old_token := String(_window_tokens.get(id, ""))
	if old_token.is_empty() or String(window.windowToken) == old_token:
		return {"status":"failed", "reason":"physical_window_replacement_token_not_distinct"}
	var owner_epoch := "%d:%d" % [get_instance_id(), _next_owner_epoch()]
	if not bool(owner.call("assign_retirement_owner_epoch", owner_epoch)):
		return {"status":"failed", "reason":"physical_window_memory_ledger_binding_rejected"}
	var old_window: Dictionary = _owner_windows.get(id, {}).duplicate(true)
	var stage := {"id":id, "owner":owner, "ownerEpoch":owner_epoch,
		"window":window.duplicate(true), "windowToken":String(window.windowToken),
		"layoutToken":String(layout_ticket.get("ticket", "")),
		"sourceTicket":String(layout_ticket.get("sourceTicket", "")),
		"oldOwner":old_owner, "oldOwnerEpoch":String(_owner_epochs[id]),
		"oldWindowToken":old_token, "oldWindow":old_window}
	_staged_owners[id] = stage
	if old_window.is_empty():
		return {"status":"failed", "reason":"physical_window_old_layout_missing",
			"candidateRetainedForDrain":true, "physicalOwnerEpoch":owner_epoch}
	if not bool(owner.call("bind_memory_admission", _memory_admission,
			String(window.windowToken), owner_epoch)):
		return {"status":"failed", "reason":"physical_window_memory_ledger_binding_rejected",
			"candidateRetainedForDrain":true, "physicalOwnerEpoch":owner_epoch}
	return {"status":"ready", "windowId":id,
		"windowToken":stage.windowToken, "physicalOwnerEpoch":owner_epoch,
		"oldWindowToken":stage.oldWindowToken,
		"oldOwnerEpoch":stage.oldOwnerEpoch,
		"layoutToken":stage.layoutToken}

## Cancel only the exact staged candidate. The currently committed owner tuple
## is checked before and after its bounded drain and is never touched here.
func cancel_staged_replacement(id: Vector3i, owner_epoch: String) -> Dictionary:
	var stage: Dictionary = _staged_owners.get(id, {})
	if stage.is_empty() or String(stage.get("ownerEpoch", "")) != owner_epoch:
		return {"status":"failed", "reason":"physical_window_candidate_not_staged"}
	if _owners.get(id) != stage.get("oldOwner") \
			or _owner_epochs.get(id) != stage.get("oldOwnerEpoch") \
			or _window_tokens.get(id) != stage.get("oldWindowToken"):
		return {"status":"failed", "reason":"physical_window_committed_owner_changed"}
	var drained: Dictionary = await _drain_noncurrent_owner(stage.owner,
		String(stage.ownerEpoch), String(stage.windowToken), false)
	if drained.get("status") != "ready":
		return {"status":"pending", "reason":"physical_window_candidate_cancel_pending",
			"drain":drained}
	if _owners.get(id) != stage.get("oldOwner") \
			or _owner_epochs.get(id) != stage.get("oldOwnerEpoch") \
			or _window_tokens.get(id) != stage.get("oldWindowToken"):
		return {"status":"failed", "reason":"physical_window_committed_owner_changed",
			"drain":drained}
	var layout: Dictionary = _broker.collision_window_layout()
	if layout.get("status") != "ready":
		return {"status":"pending", "reason":"physical_window_candidate_cancel_layout_pending",
			"drain":drained, "layout":layout}
	var candidate_active := false
	var other_active_token := ""
	for current_window in layout.get("windows", []):
		if current_window.get("id") != id: continue
		var current_token := String(current_window.get("windowToken", ""))
		if current_token == String(stage.windowToken): candidate_active = true
		elif not current_token.is_empty(): other_active_token = current_token
	if candidate_active:
		if not other_active_token.is_empty():
			return {"status":"pending", "reason":"physical_window_candidate_layout_ambiguous",
				"activeReplacementToken":other_active_token, "drain":drained}
		if not String(stage.get("retirementLeaseId", "")).is_empty():
			return {"status":"failed", "reason":"physical_window_candidate_reactivated_after_drain",
				"drain":drained, "layout":layout,
				"leaseId":String(stage.retirementLeaseId)}
		_staged_owners.erase(id)
		stage.owner.queue_free()
		return {"status":"ready", "windowId":id, "candidateOwnerEpoch":owner_epoch,
			"oldOwnerEpoch":String(stage.oldOwnerEpoch), "brokerRecordRetained":true,
			"drain":drained}
	var telemetry: Dictionary = layout.get("retirementTelemetry", {})
	var retired_tokens: Array = layout.get("retiredWindowTokens",
		telemetry.get("retiredWindowTokens", []))
	if not retired_tokens.has(String(stage.windowToken)):
		return {"status":"pending", "reason":"physical_window_candidate_retirement_unproven",
			"drain":drained, "layoutToken":layout.get("layoutToken", "")}
	var layout_token := String(layout.get("layoutToken", ""))
	if layout_token.is_empty():
		return {"status":"pending", "reason":"physical_window_candidate_retirement_layout_missing",
			"drain":drained}
	var lease_id := String(stage.get("retirementLeaseId", ""))
	var claim: Dictionary = {"status":"ready", "leaseId":lease_id,
		"windowToken":String(stage.windowToken),
		"physicalOwnerEpoch":String(stage.ownerEpoch),
		"reused":true}
	if lease_id.is_empty():
		claim = _broker.claim_collision_window_retirement(
			String(stage.windowToken), layout_token, String(stage.ownerEpoch))
		if claim.get("status") != "ready" \
				or claim.get("windowToken") != String(stage.windowToken) \
				or claim.get("physicalOwnerEpoch") != String(stage.ownerEpoch) \
				or String(claim.get("leaseId", "")).is_empty():
			return {"status":"pending", "reason":"physical_window_candidate_retirement_lease_pending",
				"drain":drained, "lease":claim}
		lease_id = String(claim.leaseId)
		stage["retirementLeaseId"] = lease_id
		stage["retirementLeaseLayoutToken"] = layout_token
		_staged_owners[id] = stage
	var valid_lease: Dictionary = _broker.validate_collision_window_retirement(
		String(stage.windowToken), lease_id, String(stage.ownerEpoch))
	if valid_lease.get("status") != "ready" \
			or valid_lease.get("windowToken") != String(stage.windowToken) \
			or valid_lease.get("physicalOwnerEpoch") != String(stage.ownerEpoch):
		return {"status":"pending", "reason":"physical_window_candidate_retirement_lease_stale",
			"drain":drained, "lease":valid_lease}
	var final_layout: Dictionary = _broker.collision_window_layout()
	var final_telemetry: Dictionary = final_layout.get("retirementTelemetry", {})
	var final_retired: Array = final_layout.get("retiredWindowTokens",
		final_telemetry.get("retiredWindowTokens", []))
	var final_active := false
	for final_window in final_layout.get("windows", []):
		if final_window.get("id") == id and final_window.get("windowToken") \
				== String(stage.windowToken): final_active = true
	if final_layout.get("status") != "ready" or final_active \
			or not final_retired.has(String(stage.windowToken)):
		# Keep the exact lease and owner tuple while later layout revisions are
		# revalidated. The immutable retired token and broker record are the proof;
		# the expected layout token is not refreshed after physical drain.
		return {"status":"pending", "reason":"physical_window_candidate_retirement_layout_changed",
			"drain":drained, "layout":final_layout}
	var candidate_drain_receipt: Dictionary = drained.get("drain", {}).duplicate(true)
	candidate_drain_receipt["retirementLeaseId"] = lease_id
	candidate_drain_receipt["physicalOwnerEpoch"] = String(stage.ownerEpoch)
	# The first publication may never have happened. The owner then drains
	# with empty source fields; attest the exact staged broker record separately.
	if int(candidate_drain_receipt.get("residentBlockCount", -1)) == 0 \
			and candidate_drain_receipt.get("residentBlocks") == [] \
			and String(candidate_drain_receipt.get("windowToken", "")) == "":
		candidate_drain_receipt["retirementKind"] = "unpublished_staged_candidate/v1"
		candidate_drain_receipt["candidateWindowToken"] = String(stage.windowToken)
		candidate_drain_receipt["candidateRecordIdentity"] = \
			(stage.window.get("identity", {}) as Dictionary).duplicate(true)
		candidate_drain_receipt["candidateSourceIdentity"] = \
			(stage.window.get("identity", {}).get("sourceIdentity", {}) as Dictionary).duplicate(true)
		candidate_drain_receipt["candidateClosureToken"] = \
			String(stage.window.get("closureToken", ""))
		candidate_drain_receipt["candidateRecordBlocks"] = \
			(stage.window.get("blocks", []) as Array).duplicate()
		candidate_drain_receipt["memoryAdmission"] = \
			drained.get("memoryAdmission", {}).duplicate(true)
	var acknowledged: Dictionary = _broker.acknowledge_collision_window_retired(
		String(stage.windowToken), candidate_drain_receipt)
	if acknowledged.get("status") != "ready" \
			or acknowledged.get("retiredWindowToken") != String(stage.windowToken):
		return {"status":"pending", "reason":"physical_window_candidate_retirement_ack_pending",
			"drain":drained, "acknowledgement":acknowledged}
	_staged_owners.erase(id)
	stage.owner.queue_free()
	return {"status":"ready", "windowId":id, "candidateOwnerEpoch":owner_epoch,
		"oldOwnerEpoch":String(stage.oldOwnerEpoch), "brokerRecordRetained":false,
		"drain":drained, "candidateDrainReceipt":candidate_drain_receipt,
		"retirementLease":claim, "leaseValidation":valid_lease,
		"finalLayoutToken":layout_token, "acknowledgement":acknowledged}

## The switch is a single synchronous registry update after re-reading the
## exact broker ticket, candidate receipt, old-owner tuple and closed barrier.
## Until this returns ready, the old owner remains authoritative and installed.
func commit_staged_replacement(window: Dictionary, owner: Node3D,
		barrier: RefCounted) -> Dictionary:
	if _stopping or not window.get("id") is Vector3i:
		return {"status":"failed", "reason":"physical_window_replacement_unavailable"}
	var id: Vector3i = window.id
	var stage: Dictionary = _staged_owners.get(id, {})
	if stage.is_empty() or stage.get("owner") != owner \
			or stage.get("windowToken") != window.get("windowToken", "") \
			or stage.get("window", {}).get("id") != window.get("id") \
			or stage.get("window", {}).get("identity") != window.get("identity") \
			or stage.get("window", {}).get("blocks") != window.get("blocks"):
		return {"status":"failed", "reason":"physical_window_replacement_stage_mismatch"}
	if _retirement_leases.has(id) or _retirement_inflight.has(id):
		return {"status":"pending", "reason":"physical_window_incumbent_retirement_inflight"}
	var layout_ticket: Dictionary = _broker.call("collision_window_layout_ticket")
	if layout_ticket.get("status") != "ready" \
			or layout_ticket.get("ticket") != stage.get("layoutToken") \
			or layout_ticket.get("sourceTicket") != stage.get("sourceTicket"):
		return {"status":"pending", "reason":"physical_window_replacement_ticket_changed"}
	var layout: Dictionary = layout_ticket.get("layout", {})
	if layout.get("identity") != window.get("identity") \
			or not (layout.get("windows", []) as Array).has(window):
		return {"status":"pending", "reason":"physical_window_replacement_layout_changed"}
	if _owners.get(id) != stage.get("oldOwner") \
			or _owner_epochs.get(id) != stage.get("oldOwnerEpoch") \
			or _window_tokens.get(id) != stage.get("oldWindowToken") \
			or not is_instance_valid(stage.get("oldOwner")) \
			or String((stage.oldOwner as Node3D).call("retirement_owner_epoch")) \
			!= String(stage.oldOwnerEpoch):
		return {"status":"pending", "reason":"physical_window_old_owner_changed"}
	if String(owner.call("retirement_owner_epoch")) != String(stage.ownerEpoch) \
			or not is_instance_valid(barrier) or not barrier.is_active() \
			or _barriers.get(id) != barrier \
			or _barrier_identities.get(id) != layout.identity \
			or not bool(barrier.clearance(layout.identity).get("clear", false)):
		return {"status":"pending", "reason":"physical_window_replacement_barrier_pending"}
	var receipt: Dictionary = owner.physical_receipt(window.identity)
	if not bool(receipt.get("ready", false)) \
			or receipt.get("physicalOwnerEpoch") != stage.ownerEpoch \
			or receipt.get("provenance", {}).get("requestIdentity") != window.identity \
			or receipt.get("residentBlocks") != window.get("blocks", []):
		return {"status":"pending", "reason":receipt.get("reason",
			"physical_window_replacement_receipt_pending"), "receipt":receipt}
	var final_ticket: Dictionary = _broker.call("collision_window_layout_ticket")
	if final_ticket.get("status") != "ready" \
			or final_ticket.get("ticket") != stage.get("layoutToken") \
			or final_ticket.get("sourceTicket") != stage.get("sourceTicket") \
			or owner.physical_readiness_epoch() != receipt.get("healthEpoch") \
			or String(owner.call("retirement_owner_epoch")) != String(stage.ownerEpoch) \
			or not barrier.is_active() \
			or not bool(barrier.clearance(layout.identity).get("clear", false)) \
			or _owners.get(id) != stage.get("oldOwner") \
			or _owner_epochs.get(id) != stage.get("oldOwnerEpoch") \
			or _window_tokens.get(id) != stage.get("oldWindowToken"):
		return {"status":"pending", "reason":"physical_window_replacement_commit_revalidation_failed"}
	if _displaced_owners.size() >= MAX_DISPLACED_OWNERS:
		return {"status":"pending", "reason":"physical_window_displaced_owner_capacity"}
	var old_barrier_records := _retired_barrier_records(id,
		String(stage.get("oldWindowToken", "")))
	if old_barrier_records.is_empty():
		return {"status":"pending", "reason":"physical_window_old_barrier_not_retained"}
	var old_tuple := {"id":id, "owner":stage.oldOwner,
		"ownerEpoch":String(stage.oldOwnerEpoch),
		"windowToken":String(stage.oldWindowToken),
		"window":stage.get("oldWindow", {}),
		"oldBarrierRecords":old_barrier_records}
	_displaced_owners[id] = old_tuple
	_owners[id] = owner
	_owner_epochs[id] = String(stage.ownerEpoch)
	_window_tokens[id] = String(stage.windowToken)
	_owner_windows[id] = window.duplicate(true)
	_staged_owners.erase(id)
	_invalidate_aggregate_for_owner_switch()
	return {"status":"ready", "windowId":id,
		"windowToken":String(stage.windowToken),
		"physicalOwnerEpoch":String(stage.ownerEpoch),
		"displacedWindowToken":String(stage.oldWindowToken),
		"displacedOwnerEpoch":String(stage.oldOwnerEpoch),
		"receipt":receipt, "layoutTicket":String(stage.layoutToken)}

func _next_owner_epoch() -> int:
	_owner_epoch_sequence += 1
	return _owner_epoch_sequence

func _invalidate_aggregate_for_owner_switch() -> void:
	_aggregate_ticket = ""
	_aggregate_source_ticket = ""
	_aggregate_layout = {}
	_aggregate_identity = {}
	_aggregate_receipts = {}
	_aggregate_owner_epochs = {}
	_aggregate_cursor = {}
	_aggregate_window_cursor = 0
	_aggregate_result = {"status":"pending",
		"reason":"physical_owner_replacement_committed"}
	_aggregate_last_step_frame = -1

func _retired_barrier_records(id: Vector3i, window_token: String) -> Array[Dictionary]:
	var matches: Array[Dictionary] = []
	for record in _retired_barriers:
		if record.get("windowId") == id \
				and String(record.get("windowToken", "")) == window_token:
			matches.append({"barrier":record.get("barrier"),
				"identity":record.get("identity", {}).duplicate(true),
				"bounds":record.get("bounds")})
	return matches

func _displaced_barrier_clearance(id: Vector3i, displaced: Dictionary) -> Dictionary:
	var old_records: Array = displaced.get("oldBarrierRecords", [])
	if old_records.is_empty():
		return {"status":"pending", "reason":"displaced_old_barrier_missing"}
	var retained := _retired_barrier_records(id,
		String(displaced.get("windowToken", "")))
	if retained.size() != old_records.size():
		return {"status":"pending", "reason":"displaced_old_barrier_not_retained"}
	var replacement: Variant = _barriers.get(id)
	var identity: Dictionary = _barrier_identities.get(id, {})
	if not is_instance_valid(replacement) or not replacement.is_active() \
			or identity.is_empty():
		return {"status":"pending", "reason":"displaced_replacement_barrier_missing"}
	var covered_bounds := AABB()
	for old_record in old_records:
		var old_barrier: Variant = old_record.get("barrier")
		var old_identity: Dictionary = old_record.get("identity", {})
		var old_bounds: Variant = old_record.get("bounds")
		if old_identity.is_empty() or not old_bounds is AABB \
				or not is_instance_valid(old_barrier) or not old_barrier.is_active():
			return {"status":"pending", "reason":"displaced_old_barrier_not_retained"}
		var found := false
		for current_record in retained:
			if current_record.get("barrier") == old_barrier \
					and current_record.get("identity") == old_identity \
					and current_record.get("bounds") == old_bounds:
				found = true
				break
		if not found:
			return {"status":"pending", "reason":"displaced_old_barrier_not_retained"}
		if not replacement.covers_bounds(identity, old_bounds):
			return {"status":"pending", "reason":"displaced_replacement_barrier_does_not_cover_old_bounds",
				"oldBounds":old_bounds}
		var old_clearance: Dictionary = old_barrier.clearance(old_identity)
		if not bool(old_clearance.get("clear", false)):
			return {"status":"pending", "reason":"displaced_old_barrier_clearance_pending",
				"oldClearance":old_clearance}
		covered_bounds = old_bounds if covered_bounds == AABB() \
			else covered_bounds.merge(old_bounds)
	var replacement_clearance: Dictionary = replacement.clearance(identity)
	if not bool(replacement_clearance.get("clear", false)):
		return {"status":"pending", "reason":"displaced_replacement_barrier_clearance_pending",
			"replacementClearance":replacement_clearance}
	return {"status":"ready", "replacementIdentity":identity,
		"oldBounds":covered_bounds, "oldBarrierCount":old_records.size()}

func begin_window_barrier(window: Dictionary, bounds: AABB,
		identity: Dictionary) -> Dictionary:
	if _stopping or _actor_root == null or not is_inside_tree() \
			or not window.get("id") is Vector3i:
		return {"status":"failed", "reason":"window_barrier_owner_invalid"}
	if active_barrier_count() >= MAX_ACTIVE_BARRIERS:
		return {"status":"pending", "reason":"window_barrier_retention_backpressure",
			"activeBarrierCount":active_barrier_count()}
	if _barriers.has(window.id) and _barriers[window.id].is_active() \
			and _retired_barriers.size() >= MAX_RETIRED_BARRIERS:
		return {"status":"pending", "reason":"window_barrier_retention_backpressure",
			"retiredBarrierCount":_retired_barriers.size()}
	var barrier = AdmissionBarrier.new()
	var begun: Dictionary = barrier.begin(_actor_root, self, identity, bounds)
	if begun.get("status") == "failed": return begun
	if _barriers.has(window.id) and _barriers[window.id].is_active():
		_retired_barriers.append({"barrier":_barriers[window.id],
			"identity":_barrier_identities[window.id], "windowId":window.id,
			"windowToken":String(_barrier_window_tokens.get(window.id, "")),
			"bounds":_barrier_bounds[window.id]})
	_barriers[window.id] = barrier
	_barrier_identities[window.id] = identity.duplicate(true)
	_barrier_bounds[window.id] = bounds
	_barrier_window_tokens[window.id] = String(window.get("windowToken", ""))
	return {"status":begun.status, "windowId":window.id,
		"barrier":barrier, "census":begun}

func window_barrier(id: Vector3i) -> RefCounted:
	return _barriers.get(id)

func active_barrier_count() -> int:
	var count := 0
	for barrier in _barriers.values():
		if barrier.is_active(): count += 1
	for record in _retired_barriers:
		var barrier: RefCounted = record.barrier
		if barrier.is_active(): count += 1
	return count

func has_displaced_window(id: Vector3i) -> bool:
	return _displaced_owners.has(id)

func aggregate_readiness(identity: Dictionary) -> Dictionary:
	if _stopping or _broker == null:
		return {"status":"pending", "reason":"window_coordinator_stopping"}
	if not _broker.has_method("collision_window_layout_ticket"):
		return {"status":"pending", "reason":"immutable_collision_source_ticket_required"}
	var ticket_result: Dictionary = _broker.call("collision_window_layout_ticket")
	if ticket_result.get("status") != "ready":
		return {"status":"pending", "reason":ticket_result.get("reason",
			"logical_collision_layout_pending")}
	var source_ticket := String(ticket_result.get("sourceTicket", ""))
	if source_ticket.is_empty():
		return {"status":"pending", "reason":"immutable_collision_source_ticket_missing"}
	var layout: Dictionary = ticket_result.get("layout", ticket_result)
	if layout.get("identity") != identity:
		return {"status":"pending", "reason":"logical_collision_identity_changed"}
	var ticket := String(ticket_result.get("ticket", ticket_result.get("layoutToken", "")))
	if ticket.is_empty():
		return {"status":"pending", "reason":"logical_collision_ticket_missing"}
	if _aggregate_ticket != ticket:
		_begin_aggregate_validation(ticket, source_ticket, layout, identity)
	elif _aggregate_result.get("status") == "ready" \
			and not _aggregate_owner_epochs_current():
		_begin_aggregate_validation(ticket, source_ticket, layout, identity)
	if _aggregate_result.get("status") == "failed" \
			and _aggregate_result.get("ticket") == ticket:
		return _aggregate_result.result
	if _aggregate_result.get("status") == "ready" \
			and _aggregate_result.get("ticket") == ticket \
			and _aggregate_owner_epochs_current():
		return _aggregate_result.result
	_advance_aggregate_validation()
	if _aggregate_result.get("status") == "failed" \
			and _aggregate_result.get("ticket") == ticket:
		return _aggregate_result.result
	if _aggregate_result.get("status") == "ready" \
			and _aggregate_result.get("ticket") == ticket \
			and _aggregate_owner_epochs_current():
		return _aggregate_result.result
	return {"status":"pending", "reason":_aggregate_result.get("reason",
		"collision_aggregate_validation_in_progress"),
		"validationOperations":int(_aggregate_result.get("operations", 0)),
		"validationOperationBudget":AGGREGATE_VALIDATION_OPERATION_BUDGET,
		"validationStepUsecBudget":AGGREGATE_VALIDATION_STEP_USEC_BUDGET}

func _begin_aggregate_validation(ticket: String, source_ticket: String,
		layout: Dictionary, identity: Dictionary) -> void:
	_aggregate_ticket = ticket
	_aggregate_source_ticket = source_ticket
	_aggregate_layout = layout
	_aggregate_identity = identity.duplicate(true)
	_aggregate_receipts = {}
	_aggregate_owner_epochs = {}
	_aggregate_cursor = {}
	_aggregate_window_cursor = 0
	_aggregate_result = {"status":"pending",
		"reason":"collision_aggregate_validation_in_progress"}
	_aggregate_last_step_frame = -1
	var windows: Array = layout.get("windows", [])
	var required: Array = layout.get("requiredBlocks", [])
	if windows.size() > Aggregate.MAX_AGGREGATE_WINDOWS \
			or required.size() > Aggregate.MAX_AGGREGATE_BLOCKS:
		_aggregate_result = {"status":"failed", "ticket":ticket,
			"result":{"status":"failed",
				"reason":"logical_collision_layout_capacity_invalid"}}
	elif _owners.size() != windows.size():
		_aggregate_result = {"status":"pending",
			"reason":"obsolete_physical_window_retirement_pending"}

func _advance_aggregate_validation() -> void:
	if _stopping or _aggregate_ticket.is_empty() \
			or _aggregate_result.get("status") == "failed" \
			or Engine.get_process_frames() == _aggregate_last_step_frame:
		return
	_aggregate_last_step_frame = Engine.get_process_frames()
	if not _broker.has_method("collision_window_layout_ticket"):
		_aggregate_ticket = ""
		_aggregate_result = {"status":"pending",
			"reason":"immutable_collision_source_ticket_required"}
		return
	var live_ticket: Dictionary = _broker.call("collision_window_layout_ticket")
	if live_ticket.get("status") != "ready" \
			or live_ticket.get("ticket") != _aggregate_ticket \
			or live_ticket.get("sourceTicket") != _aggregate_source_ticket:
		_aggregate_ticket = ""
		_aggregate_source_ticket = ""
		_aggregate_result = {"status":"pending",
			"reason":"logical_collision_ticket_changed"}
		return
	var started := Time.get_ticks_usec()
	var operations := 0
	var windows: Array = _aggregate_layout.get("windows", [])
	while _aggregate_cursor.is_empty() and _aggregate_window_cursor < windows.size() \
			and operations < AGGREGATE_VALIDATION_OPERATION_BUDGET \
			and Time.get_ticks_usec() - started < AGGREGATE_VALIDATION_STEP_USEC_BUDGET:
		var window: Dictionary = windows[_aggregate_window_cursor]
		var id: Vector3i = window.get("id", Vector3i.ZERO)
		if not _owners.has(id) or _window_tokens.get(id) != window.get("windowToken"):
			_aggregate_result = {"status":"pending",
				"reason":"obsolete_physical_window_retirement_pending",
				"windowId":id, "operations":operations + 1}
			return
		var owner: Node3D = _owners[id]
		if is_instance_valid(owner):
			var receipt: Dictionary = owner.physical_receipt_for_layout(
				window.get("identity", {}), window.get("localCurrentProof", {}),
				_aggregate_layout.get("identity", {})) \
				if owner.has_method("physical_receipt_for_layout") \
				else owner.physical_receipt(window.get("identity", {}))
			_aggregate_receipts[id] = receipt
			_aggregate_owner_epochs[id] = int(owner.call("physical_readiness_epoch")) \
				if owner.has_method("physical_readiness_epoch") else -1
			if _owner_receipt_is_terminal(receipt):
				var terminal := {"status":"failed",
					"reason":receipt.get("reason", "physical_window_owner_terminal_failure"),
					"windowId":id, "ownerReceipt":receipt}
				_aggregate_result = {"status":"failed", "ticket":_aggregate_ticket,
					"reason":terminal.reason, "result":terminal,
					"operations":operations + 1}
				return
		else:
			_aggregate_receipts[id] = {"ready":false}
		_aggregate_window_cursor += 1
		operations += 1
	if _aggregate_cursor.is_empty() and _aggregate_window_cursor >= windows.size():
		_aggregate_cursor = Aggregate.begin_cursor(_aggregate_layout, _aggregate_receipts)
		if _aggregate_cursor.get("status") != "pending":
			_aggregate_result = {"status":"failed",
				"reason":_aggregate_cursor.get("reason", "logical_collision_layout_invalid"),
				"operations":operations}
			return
	if not _aggregate_cursor.is_empty() \
			and Time.get_ticks_usec() - started < AGGREGATE_VALIDATION_STEP_USEC_BUDGET:
		var remaining_ops := AGGREGATE_VALIDATION_OPERATION_BUDGET - operations
		var remaining_usec := AGGREGATE_VALIDATION_STEP_USEC_BUDGET - (Time.get_ticks_usec() - started)
		if remaining_ops <= 0 or remaining_usec <= 0: return
		var cursor_result: Dictionary = Aggregate.advance_cursor(_aggregate_cursor,
			remaining_ops, remaining_usec)
		if cursor_result.get("status") == "ready" or cursor_result.get("status") == "failed":
			if cursor_result.get("status") == "ready" \
					and not _aggregate_owner_epochs_current():
				_aggregate_ticket = ""
				_aggregate_result = {"status":"pending",
					"reason":"physical_owner_readiness_changed"}
				return
			_aggregate_result = {"status":cursor_result.status,
				"result":cursor_result, "ticket":_aggregate_ticket,
				"operations":operations + int(cursor_result.get("operations", 0))}
		elif cursor_result.get("reason") == "collision_window_physics_pending":
			_aggregate_result = {"status":"pending", "reason":cursor_result.reason,
				"operations":operations + int(cursor_result.get("operations", 0))}
			_aggregate_window_cursor = 0
			_aggregate_receipts = {}
			_aggregate_cursor = {}
		else:
			_aggregate_result = {"status":"pending",
				"reason":cursor_result.get("reason",
				"collision_aggregate_validation_in_progress"),
				"operations":operations + int(cursor_result.get("operations", 0))}

func _owner_receipt_is_terminal(receipt: Dictionary) -> bool:
	if receipt.get("status") == "failed": return true
	var health: Dictionary = receipt.get("healthValidation", {})
	return health.get("status") == "failed"

func _aggregate_owner_epochs_current() -> bool:
	for id in _aggregate_owner_epochs:
		var owner: Node3D = _owners.get(id)
		if not is_instance_valid(owner) or not owner.has_method("physical_readiness_epoch") \
				or int(owner.call("physical_readiness_epoch")) \
				!= int(_aggregate_owner_epochs[id]):
			return false
	return true

func physical_receipt(identity: Dictionary) -> Dictionary:
	var aggregate: Dictionary = aggregate_readiness(identity)
	if aggregate.get("status") != "ready":
		return {"ready":false, "reason":aggregate.get("reason", "")}
	return {"ready":true, "physicsFrame":Engine.get_physics_frames(),
		"provenance":{"requestIdentity":identity.duplicate(true),
			"logicalClosureToken":aggregate.logicalClosureToken,
			"layoutToken":aggregate.layoutToken},
		"aggregate":aggregate}

func release_barriers(identity: Dictionary) -> Dictionary:
	if not bool(physical_receipt(identity).get("ready", false)):
		return {"status":"pending", "reason":"aggregate_collision_not_physical"}
	var pending: Array[Vector3i] = []
	var still_retired: Array[Dictionary] = []
	for record in _retired_barriers:
		var barrier: RefCounted = record.barrier
		# A previous partial release may have completed this barrier while another
		# window remained held. It no longer owns admission or retirement demand.
		if not barrier.is_active():
			continue
		var displaced: Dictionary = _displaced_owners.get(record.windowId, {})
		if displaced.get("windowToken") == record.get("windowToken"):
			pending.append(record.windowId)
			still_retired.append(record)
			continue
		var replacement: RefCounted = _barriers.get(record.windowId)
		if replacement == null or not replacement.is_active() \
				or not replacement.covers_bounds(identity, record.bounds) \
				or not bool(replacement.clearance(identity).get("clear", false)) \
				or not barrier.release_after_replacement(
					record.identity, identity):
			pending.append(record.windowId)
			still_retired.append(record)
	_retired_barriers = still_retired
	if not pending.is_empty():
		return {"status":"pending", "reason":"window_actor_clearance_pending",
			"pendingWindowIds":pending}
	for id in _barriers:
		var barrier: RefCounted = _barriers[id]
		if barrier.is_active() and not barrier.release(identity):
			pending.append(id)
	if not pending.is_empty():
		return {"status":"pending", "reason":"window_actor_clearance_pending",
			"pendingWindowIds":pending}
	_barriers.clear()
	_barrier_identities.clear()
	_barrier_bounds.clear()
	_barrier_window_tokens.clear()
	_retired_barriers.clear()
	return {"status":"ready", "aggregate":aggregate_readiness(identity)}

func admit_motion(actor: PhysicsBody3D, motion: Vector3) -> bool:
	if _stopping: return false
	if not _physical_admission_ready(): return false
	for barrier in _barriers.values():
		if barrier.is_active() and not barrier.admit_motion(actor, motion):
			return false
	for record in _retired_barriers:
		var barrier: RefCounted = record.barrier
		if barrier.is_active() and not barrier.admit_motion(actor, motion):
			return false
	return true

func admit_placement(actor: PhysicsBody3D, transform: Transform3D) -> bool:
	if _stopping: return false
	if not _physical_admission_ready(): return false
	for barrier in _barriers.values():
		if barrier.is_active() and not barrier.admit_placement(actor, transform):
			return false
	for record in _retired_barriers:
		var barrier: RefCounted = record.barrier
		if barrier.is_active() and not barrier.admit_placement(actor, transform):
			return false
	return true

func register_moving_actor(actor: PhysicsBody3D) -> bool:
	if _stopping: return false
	if not _physical_admission_ready(): return false
	for barrier in _barriers.values():
		if barrier.is_active() and not barrier.register_moving_actor(actor):
			return false
	for record in _retired_barriers:
		var barrier: RefCounted = record.barrier
		if barrier.is_active() and not barrier.register_moving_actor(actor):
			return false
	return true

func retire_window(id: Vector3i) -> Dictionary:
	if _stopping or not _owners.has(id):
		return {"status":"failed", "reason":"physical_window_not_registered"}
	if _displaced_owners.has(id):
		return {"status":"pending", "reason":"displaced_physical_owner_retirement_required"}
	if _staged_owners.has(id):
		return {"status":"pending", "reason":"physical_window_replacement_staged"}
	var current_layout: Dictionary = _broker.collision_window_layout()
	if current_layout.get("status") == "ready":
		for current_window in current_layout.get("windows", []):
			if current_window.get("id") == id \
					and String(current_window.get("windowToken", "")) \
					!= String(_window_tokens.get(id, "")):
				return {"status":"pending",
					"reason":"physical_window_replacement_staging_required",
					"incumbentWindowToken":String(_window_tokens.get(id, "")),
					"replacementWindowToken":String(current_window.get("windowToken", ""))}
	var owner: Node3D = _owners[id]
	var token := String(_window_tokens[id])
	var owner_epoch := String(_owner_epochs.get(id, ""))
	var inflight := {"owner":owner, "windowToken":token, "ownerEpoch":owner_epoch}
	_retirement_inflight[id] = inflight
	var retired: Dictionary = await _retire_owner_tuple(id, owner, token, owner_epoch, false)
	if _retirement_inflight.get(id) == inflight:
		_retirement_inflight.erase(id)
	return retired

func retire_displaced_window(id: Vector3i) -> Dictionary:
	if _stopping or not _displaced_owners.has(id):
		return {"status":"failed", "reason":"displaced_physical_window_not_registered"}
	if _retirement_inflight.has(id):
		return {"status":"pending", "reason":"physical_window_retirement_inflight"}
	var displaced: Dictionary = _displaced_owners[id]
	var inflight := {"owner":displaced.owner,
		"windowToken":String(displaced.windowToken),
		"ownerEpoch":String(displaced.ownerEpoch)}
	_retirement_inflight[id] = inflight
	var retired: Dictionary = await _retire_owner_tuple(id, displaced.owner,
		String(displaced.windowToken), String(displaced.ownerEpoch), true)
	if _retirement_inflight.get(id) == inflight:
		_retirement_inflight.erase(id)
	return retired

func _retire_owner_tuple(id: Vector3i, owner: Node3D, token: String,
		owner_epoch: String, displaced: bool) -> Dictionary:
	var displaced_clearance: Dictionary = {}
	if displaced:
		var captured: Dictionary = _displaced_owners.get(id, {})
		if captured.get("owner") != owner or captured.get("windowToken") != token \
				or captured.get("ownerEpoch") != owner_epoch \
				or _owners.get(id) == owner or _window_tokens.get(id) == token:
			return {"status":"failed", "reason":"displaced_physical_owner_tuple_invalid"}
		displaced_clearance = _displaced_barrier_clearance(id, captured)
		if displaced_clearance.get("status") != "ready":
			return displaced_clearance
	if owner_epoch.is_empty():
		return {"status":"failed", "reason":"physical_window_owner_epoch_missing"}
	var layout: Dictionary = _broker.collision_window_layout()
	var lease: Dictionary = _retirement_leases.get(id, {})
	if lease.is_empty():
		if layout.get("status") == "ready":
			for window in layout.windows:
				if not displaced and window.get("id") == id \
						and String(window.get("windowToken", "")) != token:
					return {"status":"pending",
						"reason":"physical_window_replacement_staging_required",
						"replacementWindowToken":String(window.get("windowToken", ""))}
				if window.get("windowToken") == token:
					return {"status":"pending", "reason":"physical_window_still_demanded"}
		elif layout.get("reason") != "collision_window_retirement_backpressure":
			return {"status":"pending", "reason":"physical_window_retirement_not_requested"}
	if not _barriers.has(id) or not _barriers[id].is_active():
		return {"status":"pending", "reason":"window_actor_barrier_required"}
	var barrier: RefCounted = _barriers[id]
	var identity: Dictionary = _barrier_identities[id]
	if not bool(barrier.clearance(identity).get("clear", false)):
		return {"status":"pending", "reason":"window_actor_clearance_pending"}
	if displaced:
		displaced_clearance = _displaced_barrier_clearance(id,
			_displaced_owners.get(id, {}))
		if displaced_clearance.get("status") != "ready": return displaced_clearance
	if lease.is_empty():
		var layout_token := String(layout.get("layoutToken", ""))
		var claim: Dictionary = _broker.claim_collision_window_retirement(token,
			layout_token, owner_epoch)
		if claim.get("status") != "ready":
			return {"status":"pending", "reason":claim.get("reason",
				"window_retirement_lease_pending"), "lease":claim}
		if claim.get("physicalOwnerEpoch") != owner_epoch:
			return {"status":"failed", "reason":"window_retirement_owner_epoch_mismatch",
				"lease":claim}
		lease = {"leaseId":String(claim.get("leaseId", "")),
			"layoutToken":layout_token, "physicalOwnerEpoch":owner_epoch}
		if String(lease.leaseId).is_empty():
			return {"status":"pending", "reason":"window_retirement_lease_invalid"}
		_retirement_leases[id] = lease
	else:
		var valid_lease: Dictionary = _broker.validate_collision_window_retirement(
			token, String(lease.leaseId), owner_epoch)
		if valid_lease.get("status") != "ready" \
				or valid_lease.get("physicalOwnerEpoch") != owner_epoch:
			return {"status":"pending", "reason":"window_retirement_lease_stale",
				"lease":valid_lease}
	if not is_instance_valid(owner):
		return {"status":"failed", "reason":"physical_window_owner_invalid"}
	if String(owner.call("retirement_owner_epoch")) != owner_epoch:
		return {"status":"failed", "reason":"physical_window_owner_epoch_mismatch"}
	window_retirement_drain_started.emit(id, token, String(lease.leaseId))
	var drained: Dictionary = await owner.stop_and_drain()
	if drained.get("status") != "ready" or not bool(drained.get("drained", false)) \
			or int(drained.get("remainingBodies", -1)) != 0 \
			or drained.get("windowToken") != token \
			or drained.get("physicalOwnerEpoch") != owner_epoch:
		if bool(drained.get("ownerUnchanged", false)) \
				and _broker.abort_collision_window_retirement(token,
					String(lease.leaseId), true).get("status") == "ready":
			_retirement_leases.erase(id)
			return {"status":"pending", "reason":"physical_window_drain_retry",
				"drain":drained}
		if drained.get("status") == "pending":
			return {"status":"pending", "reason":"physical_window_drain_pending",
				"drain":drained}
		return {"status":"failed", "reason":"physical_window_drain_unproven_terminal_hold",
			"drain":drained}
	if displaced:
		var retained_tuple: Dictionary = _displaced_owners.get(id, {})
		if retained_tuple.get("owner") != owner \
				or retained_tuple.get("windowToken") != token \
				or retained_tuple.get("ownerEpoch") != owner_epoch \
				or _owners.get(id) == owner or _window_tokens.get(id) == token:
			return {"status":"pending", "reason":"displaced_physical_owner_changed",
				"drain":drained}
		displaced_clearance = _displaced_barrier_clearance(id, retained_tuple)
		if displaced_clearance.get("status") != "ready":
			return {"status":"pending", "reason":"displaced_barrier_clearance_changed",
				"drain":drained, "clearance":displaced_clearance}
	var owner_memory: Dictionary = _memory_admission.call(
		"owner_reservation_receipt", owner_epoch, token)
	if owner_memory.get("status") != "ready" \
			or int(owner_memory.get("reservationCount", -1)) != 0 \
			or int(owner_memory.get("chargedBytes", -1)) != 0:
		return {"status":"pending", "reason":"physical_window_memory_charge_retained",
			"drain":drained, "memoryAdmission":owner_memory}
	var lease_valid: Dictionary = _broker.validate_collision_window_retirement(
		token, String(lease.leaseId), owner_epoch)
	if lease_valid.get("status") != "ready" \
			or lease_valid.get("physicalOwnerEpoch") != owner_epoch:
		return {"status":"pending", "reason":"window_retirement_lease_stale",
			"drain":drained, "lease":lease_valid}
	if displaced:
		var final_clearance: Dictionary = _displaced_barrier_clearance(id,
			_displaced_owners.get(id, {}))
		if final_clearance.get("status") != "ready":
			return {"status":"pending", "reason":"displaced_barrier_clearance_changed",
				"drain":drained, "clearance":final_clearance}
	drained["retirementLeaseId"] = lease.leaseId
	drained["physicalOwnerEpoch"] = owner_epoch
	var acknowledged: Dictionary = _broker.acknowledge_collision_window_retired(
		token, drained)
	if acknowledged.get("status") != "ready":
		return {"status":"pending", "reason":"window_retirement_ack_pending",
			"drain":drained, "acknowledgement":acknowledged}
	if displaced:
		if _displaced_owners.get(id, {}).get("owner") != owner \
				or _displaced_owners.get(id, {}).get("windowToken") != token \
				or _displaced_owners.get(id, {}).get("ownerEpoch") != owner_epoch:
			return {"status":"pending", "reason":"displaced_physical_owner_changed",
				"drain":drained, "acknowledgement":acknowledged}
		_displaced_owners.erase(id)
	else:
		if _owners.get(id) != owner or _window_tokens.get(id) != token \
				or _owner_epochs.get(id) != owner_epoch:
			return {"status":"pending", "reason":"physical_window_owner_changed",
				"drain":drained, "acknowledgement":acknowledged}
		_owners.erase(id)
		_window_tokens.erase(id)
		_owner_epochs.erase(id)
		_owner_windows.erase(id)
	_retirement_leases.erase(id)
	owner.queue_free()
	return {"status":"ready", "windowId":id, "windowToken":token,
		"drain":drained, "acknowledgement":acknowledged}

func stop_and_drain() -> Dictionary:
	_stopping = true
	if not _retirement_inflight.is_empty():
		return {"status":"pending", "reason":"physical_window_retirement_inflight",
			"inflightWindowIds":_retirement_inflight.keys()}
	for barrier in _barriers.values():
		if barrier.is_active(): barrier.owner_stopped(self)
	for record in _retired_barriers:
		var barrier: RefCounted = record.barrier
		if barrier.is_active(): barrier.owner_stopped(self)
	var incomplete: Array[Vector3i] = []
	for id in _owners.keys():
		var owner: Node3D = _owners[id]
		var owner_epoch := String(_owner_epochs.get(id, ""))
		if not is_instance_valid(owner):
			incomplete.append(id)
			continue
		if owner_epoch.is_empty() or not owner.has_method("retirement_owner_epoch") \
				or String(owner.call("retirement_owner_epoch")) != owner_epoch:
			incomplete.append(id)
			continue
		var drained: Dictionary = await owner.stop_and_drain()
		if drained.get("status") != "ready" \
				or not bool(drained.get("drained", false)) \
				or int(drained.get("remainingBodies", -1)) != 0 \
				or drained.get("physicalOwnerEpoch") != owner_epoch:
			incomplete.append(id)
			continue
		var owner_memory: Dictionary = _memory_admission.call(
			"owner_reservation_receipt", owner_epoch,
			String(_window_tokens.get(id, "")))
		if owner_memory.get("status") != "ready" \
				or int(owner_memory.get("reservationCount", -1)) != 0 \
				or int(owner_memory.get("chargedBytes", -1)) != 0:
			incomplete.append(id)
			continue
		owner.queue_free()
		_owners.erase(id)
		_window_tokens.erase(id)
		_owner_epochs.erase(id)
		_owner_windows.erase(id)
	for id in _staged_owners.keys():
		var stage: Dictionary = _staged_owners[id]
		var staged_owner: Node3D = stage.get("owner")
		var staged_drain: Dictionary = await _drain_noncurrent_owner(staged_owner,
			String(stage.get("ownerEpoch", "")), String(stage.get("windowToken", "")))
		if staged_drain.get("status") != "ready":
			incomplete.append(id)
			continue
		_staged_owners.erase(id)
	for id in _displaced_owners.keys():
		var displaced: Dictionary = _displaced_owners[id]
		var displaced_owner: Node3D = displaced.get("owner")
		var displaced_drain: Dictionary = await _drain_noncurrent_owner(
			displaced_owner, String(displaced.get("ownerEpoch", "")),
			String(displaced.get("windowToken", "")))
		if displaced_drain.get("status") != "ready":
			incomplete.append(id)
			continue
		_displaced_owners.erase(id)
	if not incomplete.is_empty():
		return {"status":"pending", "reason":"physical_window_drain_pending",
			"incompleteWindowIds":incomplete,
			"remainingOwners":_owners.size(),
			"activeBarriers":active_barrier_count()}
	await get_tree().process_frame
	if get_child_count() != 0:
		return {"status":"pending", "reason":"physical_window_children_draining",
			"remainingChildren":get_child_count(),
			"activeBarriers":active_barrier_count()}
	var memory_drain: Dictionary = _memory_admission.call("drain_receipt")
	if memory_drain.get("status") != "ready" \
			or not bool(memory_drain.get("drained", false)):
		return {"status":"pending", "reason":"collision_memory_ledger_drain_pending",
			"memoryAdmission":memory_drain,
			"remainingChildren":get_child_count()}
	_barriers.clear()
	_barrier_identities.clear()
	_barrier_bounds.clear()
	_barrier_window_tokens.clear()
	_retired_barriers.clear()
	_retirement_leases.clear()
	return {"status":"ready", "drained":true,
		"remainingChildren":get_child_count(),
		"memoryAdmission":memory_drain,
		"activeBarriers":active_barrier_count()}

func _drain_noncurrent_owner(owner: Node3D, owner_epoch: String,
		window_token: String, free_on_success: bool = true) -> Dictionary:
	if not is_instance_valid(owner) or owner_epoch.is_empty() \
			or not owner.has_method("retirement_owner_epoch") \
			or String(owner.call("retirement_owner_epoch")) != owner_epoch:
		return {"status":"failed", "reason":"physical_window_owner_epoch_mismatch"}
	var drained: Dictionary = await owner.stop_and_drain()
	if drained.get("status") != "ready" or not bool(drained.get("drained", false)) \
			or int(drained.get("remainingBodies", -1)) != 0 \
			or drained.get("physicalOwnerEpoch") != owner_epoch:
		return {"status":"pending", "reason":"physical_window_drain_pending",
			"drain":drained}
	var memory: Dictionary = _memory_admission.call("owner_reservation_receipt",
		owner_epoch, window_token)
	if memory.get("status") != "ready" \
			or int(memory.get("reservationCount", -1)) != 0 \
			or int(memory.get("chargedBytes", -1)) != 0:
		return {"status":"pending", "reason":"physical_window_memory_charge_retained",
			"drain":drained, "memoryAdmission":memory}
	if free_on_success: owner.queue_free()
	return {"status":"ready", "drain":drained, "memoryAdmission":memory}
