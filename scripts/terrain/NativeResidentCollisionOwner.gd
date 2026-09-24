extends Node3D
class_name NativeResidentCollisionOwner

## A composed physical owner for a source-declared complete resident mesh set.
## The source must independently publish exact block keys, artifact keys and
## revision. The native triangle producer implements the source contract;
## live runtime collision binding remains a separate cutover.
const AdmissionBarrier = preload("res://scripts/terrain/NativeCollisionAdmissionBarrier.gd")
const SCHEMA := "n5-resident-collision-publication/v1"
const COLLISION_LAYER := 2
const MAX_RESIDENT := 4096
const MAX_AFFECTED := 64
const MAX_VERTICES_PER_BLOCK := 65536
# Each preparation advance validates and hands at most this many source
# vertices to one ConcavePolygonShape3D. Large artifacts become several
# child shapes on the same StaticBody3D; the triangle set is unchanged.
const PREPARE_VERTEX_BUDGET := 768
const MAX_SHAPES_PER_BLOCK := 86
const DRAIN_WORK_BUDGET := 64
const DRAIN_BODY_BUDGET := 16
const MAX_ACK_FRAMES := 6
const VALIDATION_OPERATION_BUDGET := 128
const VALIDATION_STEP_USEC_BUDGET := 1500
const HEALTH_VALIDATION_OPERATION_BUDGET := 96
const HEALTH_VALIDATION_STEP_USEC_BUDGET := 1500
const SOURCE_REBIND_OPERATION_BUDGET := 96
const SOURCE_REBIND_STEP_USEC_BUDGET := 1500
const MEMORY_RELEASE_MAX_ATTEMPTS := 3

var _source: Object
var _memory_admission: Object
var _memory_window_token := ""
var _memory_reservation_sequence := 0
var _unconstructed_memory_tokens: Array[String] = []
var _retired_memory_entries: Array[Dictionary] = []
var _memory_accounting_failure := ""
var _memory_last_candidate_admission := {}
var _live := {}
var _identity := {}
var _source_identity := {}
var _source_ticket := ""
var _membership_provenance := {}
var _resident_blocks: Array[Vector3i] = []
var _receipt_resident_blocks: Array[Vector3i] = []
var _startup_staging := false
var _busy := false
var _failed := false
var _stopping := false
var _stopped := false
var _pending_candidates := {}
var _pending_candidate_keys: Array[Vector3i] = []
var _disposal_retry_entries := {}
var _drain_terminal_failure := {}
var _memory_release_attempts := {}
var _admission_barrier: RefCounted
var _restored_old_frame := -1
var _last_probe_hit := {}
var _drain_receipt := {}
var _prepare_max_work_units := 0
var _prepare_total_work_units := 0
var _drain_last_queued_physics_frame := -1
var _drain_window_token := ""
var _retirement_owner_epoch := ""
var _drain_expected_resident_count := 0
var _drain_resident_blocks: Array[Vector3i] = []
var _drain_retired_candidate_count := 0
var _drain_retired_live_count := 0
var _readiness_epoch := 0
var _health_scan_blocks: Array[Vector3i] = []
var _health_scan_cursor := 0
var _health_scan_entry := {}
var _health_scan_shape_cursor := 0
var _health_scan_shape_checks := 0
var _health_scan_epoch := -1
var _health_scan_identity := {}
var _health_validated_epoch := -1
var _health_validated_source_ticket := ""
var _health_failure := {}
var _health_required_physics_frame := 0
var _source_rebind_state := {}
var _source_rebind_receipt := {}
var _receipt_global_identity := {}
var _receipt_local_current_proof := {}


func _process(_delta: float) -> void:
	_advance_retired_memory_entries()


## The coordinator assigns one immutable physical installation identity before
## this node is registered as a resident window owner. It is deliberately
## separate from source ownerGeneration, which can be shared across Node
## replacement.
func assign_retirement_owner_epoch(epoch: String) -> bool:
	if epoch.is_empty() or not _retirement_owner_epoch.is_empty() \
			or _stopping or _stopped or _busy or not _live.is_empty():
		return false
	_retirement_owner_epoch = epoch
	return true


func retirement_owner_epoch() -> String:
	return _retirement_owner_epoch

## Injected only by the owning window coordinator. Direct fixture owners may
## remain unbound, but coordinator-managed publication fails closed unless the
## single coordinator ledger and exact window identity are attached.
func bind_memory_admission(admission: Object, window_token: String,
		owner_epoch: String) -> bool:
	if admission == null or not admission.has_method("reserve_candidate") \
			or not admission.has_method("mark_candidate_constructed") \
			or not admission.has_method("register_candidate_abort_body") \
			or not admission.has_method("commit_live") \
			or not admission.has_method("cancel_unconstructed") \
			or not admission.has_method("defer_release") \
			or not admission.has_method("acknowledge_deferred_release") \
			or window_token.is_empty() or owner_epoch.is_empty() \
			or owner_epoch != _retirement_owner_epoch \
			or _memory_admission != null or not _live.is_empty():
		return false
	_memory_admission = admission
	_memory_window_token = window_token
	return true

func physical_readiness_epoch() -> int:
	return _readiness_epoch

## Owner-mediated maintenance APIs. Callers must not mutate published StaticBody3D
## or CollisionShape3D nodes directly; these methods invalidate cached physical
## health before returning, and the next receipt stays pending until a bounded
## live-state sweep validates the complete resident set.
func set_collision_entry_enabled(block: Vector3i, enabled: bool) -> Dictionary:
	if _busy or _stopping or _stopped or not _live.has(block):
		return {"status":"failed", "reason":"physical_entry_mutation_unavailable"}
	var entry: Dictionary = _live[block]
	if enabled and not _entry_shapes_usable(entry, entry.get("body")):
		return {"status":"failed", "reason":"physical_entry_not_healthy_for_enable"}
	_set_enabled(entry, enabled)
	return {"status":"ready", "enabled":enabled, "healthEpoch":_readiness_epoch}

func retire_collision_entry_shape(block: Vector3i, shape_index: int) -> Dictionary:
	if _busy or _stopping or _stopped or not _live.has(block):
		return {"status":"failed", "reason":"physical_entry_mutation_unavailable"}
	_set_enabled(_live[block], false)
	if not _remove_live_shape(block, shape_index):
		return {"status":"failed", "reason":"physical_shape_retirement_invalid"}
	return {"status":"pending", "reason":"physical_shape_retired_health_invalidated",
		"healthEpoch":_readiness_epoch}

func retire_collision_entry(block: Vector3i) -> Dictionary:
	if _busy or _failed or _stopping or _stopped or not _live.has(block):
		return {"status":"failed", "reason":"physical_entry_mutation_unavailable"}
	var entry: Dictionary = _live[block]
	var disposed: Dictionary = _dispose(entry)
	if disposed.get("status") != "ready":
		return {"status":"failed", "reason":"physical_entry_retirement_dispose_rejected",
			"dispose":disposed, "entryRetained":true}
	_live.erase(block)
	_invalidate_physical_health()
	return {"status":"pending", "reason":"physical_entry_retirement_started",
		"healthEpoch":_readiness_epoch}


func bind_source(source: Object) -> bool:
	if _source != null or source == null \
			or not source.has_method("collision_source_snapshot") \
			or not source.has_method("collision_artifact_row"):
		return false
	_source = source
	return true


func physical_receipt(identity: Dictionary) -> Dictionary:
	if _failed or _stopped or not _drain_terminal_failure.is_empty():
		return {"ready":false, "status":"failed",
			"reason":"resident_collision_owner_terminal_failure",
			"memoryFailure":_memory_accounting_failure,
			"drainFailure":_drain_terminal_failure.duplicate(true)}
	if _busy or _stopping or identity != _identity \
			or _live.size() != _resident_blocks.size() \
			or not _source_current(identity):
		return {"ready": false, "reason":"resident_collision_not_current"}
	return _current_physical_receipt(identity)


## A retained local artifact identity may remain physically current while the
## global source revision advances. The broker must prove that every intervening
## native edit excludes this exact window. This advances only the immutable
## source ticket; it never relabels revision-N geometry as revision N+1.
func physical_receipt_for_layout(local_artifact_identity: Dictionary,
		local_current_proof: Dictionary, global_layout_identity: Dictionary) -> Dictionary:
	if _failed or _stopped or not _drain_terminal_failure.is_empty():
		_source_rebind_state.clear()
		return {"ready":false, "status":"failed",
			"reason":"resident_collision_owner_terminal_failure",
			"memoryFailure":_memory_accounting_failure,
			"drainFailure":_drain_terminal_failure.duplicate(true)}
	if _busy or _stopping \
			or local_artifact_identity != _identity \
			or _live.size() != _resident_blocks.size():
		_source_rebind_state.clear()
		return {"ready":false, "reason":"resident_collision_not_current"}
	if not _source_current(local_artifact_identity):
		var rebound := _advance_source_ticket_rebind(local_artifact_identity,
			local_current_proof, global_layout_identity)
		if rebound.get("status") != "ready":
			return {"ready":false, "reason":rebound.get("reason",
				"resident_source_ticket_rebind_pending"),
				"sourceTicketRebind":rebound}
	if _receipt_global_identity != global_layout_identity \
			or _receipt_local_current_proof != local_current_proof:
		return {"ready":false, "reason":"resident_source_ticket_rebind_stale"}
	return _current_physical_receipt(local_artifact_identity)


func _current_physical_receipt(identity: Dictionary,
		allowed_overlap_live_tokens: Array = []) -> Dictionary:
	if not _memory_accounting_failure.is_empty():
		return {"ready":false, "status":"failed",
			"reason":"resident_collision_memory_accounting_failed",
			"memoryFailure":_memory_accounting_failure}
	var memory_owner_receipt := {}
	if _memory_admission != null:
		var expected_live_tokens: Array[String] = []
		for entry in _live.values():
			var token := String(entry.get("memoryToken", ""))
			if token.is_empty():
				return {"ready":false,
					"reason":"resident_collision_memory_token_missing"}
			expected_live_tokens.append(token)
		memory_owner_receipt = _memory_admission.call(
			"owner_reservation_receipt", _retirement_owner_epoch,
			_memory_window_token, expected_live_tokens,
			allowed_overlap_live_tokens)
		if memory_owner_receipt.get("status") != "ready" \
				or int(memory_owner_receipt.get("stateCounts", {}).get(
					"live_current", 0)) != (expected_live_tokens.size() \
					+ allowed_overlap_live_tokens.size()) \
				or int(memory_owner_receipt.get("stateCounts", {}).get(
					"candidate_reserved", 0)) != 0 \
				or int(memory_owner_receipt.get("stateCounts", {}).get(
					"candidate_constructed", 0)) != 0:
			return {"ready":false,
				"reason":"resident_collision_memory_reservations_not_live",
				"memoryAdmission":memory_owner_receipt}
	if _health_validated_epoch != _readiness_epoch \
			or _health_validated_source_ticket != _source_ticket:
		var health: Dictionary = _advance_physical_health_validation(identity)
		if health.get("status") != "ready":
			return {"ready":false, "status":health.get("status", "pending"),
				"reason":health.get("reason",
				"physical_health_validation_pending"),
				"healthValidation":health}
	return {"ready": true, "physicsFrame": Engine.get_physics_frames(),
		"physicalOwnerEpoch": _retirement_owner_epoch,
		"healthEpoch":_readiness_epoch,
		"healthValidatedCount":_receipt_resident_blocks.size(),
		"healthValidationBudget":{"operationBudget":HEALTH_VALIDATION_OPERATION_BUDGET,
			"stepUsecBudget":HEALTH_VALIDATION_STEP_USEC_BUDGET},
		"provenance": {"requestIdentity": _identity.duplicate(true),
			"sourceIdentity": _source_identity.duplicate(true),
			"globalLayoutIdentity":_receipt_global_identity.duplicate(true),
			"localCurrentProof":_receipt_local_current_proof.duplicate(true),
			"sourceTicket":_source_ticket,
			"membershipProvenance": _membership_provenance.duplicate(true)},
		"residentBlockCount": _resident_blocks.size(),
		"residentBlocks": _receipt_resident_blocks,
		"sourceTicketRebind":_source_rebind_receipt.duplicate(true),
		"memoryAdmission":memory_owner_receipt}


func _advance_source_ticket_rebind(local_identity: Dictionary,
		proof: Dictionary, global_identity: Dictionary) -> Dictionary:
	if _source == null or not is_instance_valid(_source) \
			or not _source.has_method("collision_source_ticket") \
			or not _source.has_method("collision_source_ticket_current") \
			or not _source.has_method("collision_source_artifact_key"):
		_source_rebind_state.clear()
		return {"status":"failed", "reason":"resident_source_ticket_api_missing"}
	var proof_revision := int(proof.get("throughGlobalRevision", -1))
	var local_revision := int(local_identity.get("sourceRevision", -1))
	if proof.get("kind") != "verified_native_affected_mesh_exclusion/v1" \
			or String(proof.get("digest", "")).length() != 64 \
			or proof_revision <= local_revision \
			or proof_revision != int(global_identity.get("sourceRevision", -2)) \
			or global_identity.get("sourceIdentity") != _source_identity \
			or global_identity.get("sourceEpoch") != local_identity.get("sourceEpoch") \
			or global_identity.get("ownerGeneration") != local_identity.get("ownerGeneration") \
			or int(global_identity.get("cancellationEpoch", -1)) \
				< int(local_identity.get("cancellationEpoch", -1)):
		_source_rebind_state.clear()
		return {"status":"failed", "reason":"resident_local_current_proof_invalid"}
	var source_ticket: Dictionary = _source.call("collision_source_ticket")
	if not _source_rebind_ticket_matches(source_ticket, local_identity, proof,
			global_identity):
		_source_rebind_state.clear()
		return {"status":"pending", "reason":source_ticket.get("reason",
			"resident_local_current_source_unproven")}
	var ticket := String(source_ticket.get("ticket", ""))
	if _source_rebind_state.get("ticket") != ticket \
			or _source_rebind_state.get("localIdentity") != local_identity \
			or _source_rebind_state.get("proof") != proof \
			or _source_rebind_state.get("globalIdentity") != global_identity:
		_source_rebind_state = {"ticket":ticket,
			"localIdentity":local_identity.duplicate(true),
			"proof":proof.duplicate(true),
			"globalIdentity":global_identity.duplicate(true),
			"cursor":0, "maxOperations":0, "maxStepUsec":0}
	var started := Time.get_ticks_usec()
	var operations := 0
	while int(_source_rebind_state.cursor) < _receipt_resident_blocks.size() \
			and operations < SOURCE_REBIND_OPERATION_BUDGET \
			and Time.get_ticks_usec() - started < SOURCE_REBIND_STEP_USEC_BUDGET:
		var block: Vector3i = _receipt_resident_blocks[int(_source_rebind_state.cursor)]
		var artifact: Dictionary = _source.call("collision_source_artifact_key",
			block, ticket)
		if artifact.get("status") != "ready" \
				or String(artifact.get("artifactKey", "")).is_empty() \
				or not _live.has(block) \
				or _live[block].get("artifactKey") != artifact.get("artifactKey"):
			_source_rebind_state.clear()
			return {"status":"failed", "reason":"resident_rebind_artifact_mismatch",
				"block":block}
		_source_rebind_state.cursor = int(_source_rebind_state.cursor) + 1
		operations += 1
	_source_rebind_state.maxOperations = maxi(
		int(_source_rebind_state.maxOperations), operations)
	_source_rebind_state.maxStepUsec = maxi(int(_source_rebind_state.maxStepUsec),
		Time.get_ticks_usec() - started)
	if int(_source_rebind_state.cursor) < _receipt_resident_blocks.size():
		if not bool(_source.call("collision_source_ticket_current", ticket)):
			_source_rebind_state.clear()
			return {"status":"pending", "reason":"resident_source_ticket_rebind_drift"}
		return {"status":"pending", "reason":"resident_source_ticket_rebind_scan_pending",
			"validatedBlocks":int(_source_rebind_state.cursor),
			"residentBlocks":_receipt_resident_blocks.size(),
			"operations":operations,
			"operationBudget":SOURCE_REBIND_OPERATION_BUDGET,
			"stepUsecBudget":SOURCE_REBIND_STEP_USEC_BUDGET}
	var after: Dictionary = _source.call("collision_source_ticket")
	if after != source_ticket \
			or not bool(_source.call("collision_source_ticket_current", ticket)) \
			or _busy or not _pending_candidates.is_empty() \
			or _live.size() != _resident_blocks.size():
		_source_rebind_state.clear()
		return {"status":"pending", "reason":"resident_source_ticket_rebind_drift"}
	var rebind_evidence := {"status":"ready", "ticket":ticket,
		"localArtifactIdentity":local_identity.duplicate(true),
		"globalLayoutIdentity":global_identity.duplicate(true),
		"localCurrentProof":proof.duplicate(true),
		"validatedBlocks":_receipt_resident_blocks.size(),
		"maxOperations":int(_source_rebind_state.maxOperations),
		"maxStepUsec":int(_source_rebind_state.maxStepUsec),
		"operationBudget":SOURCE_REBIND_OPERATION_BUDGET,
		"stepUsecBudget":SOURCE_REBIND_STEP_USEC_BUDGET}
	_source_ticket = ticket
	_receipt_global_identity = global_identity.duplicate(true)
	_receipt_local_current_proof = proof.duplicate(true)
	_source_rebind_receipt = rebind_evidence.duplicate(true)
	_source_rebind_state.clear()
	_invalidate_physical_health()
	return rebind_evidence


func _source_rebind_ticket_matches(ticket: Dictionary, local_identity: Dictionary,
		proof: Dictionary, global_identity: Dictionary) -> bool:
	return ticket.get("status") == "ready" \
		and not String(ticket.get("ticket", "")).is_empty() \
		and ticket.get("identity") == local_identity \
		and ticket.get("sourceIdentity") == _source_identity \
		and ticket.get("globalIdentity") == global_identity \
		and ticket.get("localCurrentProof") == proof \
		and ticket.get("requiredResidentBlocks") == _resident_blocks \
		and ticket.get("membershipProvenance") == _membership_provenance \
		and bool(_source.call("collision_source_ticket_current",
			String(ticket.get("ticket", ""))))

## One bounded cursor step over the exclusively-owned installed bodies. Node
## mutation and teardown must go through this owner; each supported mutation
## invalidates the epoch-cached proof before a caller can reuse a receipt.
func _advance_physical_health_validation(identity: Dictionary) -> Dictionary:
	if _health_validated_epoch == _readiness_epoch \
			and _health_validated_source_ticket == _source_ticket:
		return {"status":"ready", "cached":true,
			"healthEpoch":_readiness_epoch}
	if not _health_failure.is_empty() \
			and int(_health_failure.get("healthEpoch", -1)) == _readiness_epoch:
		return _health_failure.duplicate(false)
	if Engine.get_physics_frames() < _health_required_physics_frame:
		return {"status":"pending", "reason":"physical_health_physics_ack_pending",
			"requiredPhysicsFrame":_health_required_physics_frame,
			"currentPhysicsFrame":Engine.get_physics_frames(), "operations":0}
	if _health_scan_epoch != _readiness_epoch or _health_scan_identity != identity:
		_health_scan_blocks = _receipt_resident_blocks
		_health_scan_cursor = 0
		_health_scan_entry = {}
		_health_scan_shape_cursor = 0
		_health_scan_shape_checks = 0
		_health_scan_epoch = _readiness_epoch
		_health_scan_identity = identity.duplicate(true)
	var started := Time.get_ticks_usec()
	var operations := 0
	while operations < HEALTH_VALIDATION_OPERATION_BUDGET \
			and Time.get_ticks_usec() - started < HEALTH_VALIDATION_STEP_USEC_BUDGET:
		if not _health_scan_entry.is_empty():
			var shapes: Array = _health_scan_entry.get("shapes", [])
			if _health_scan_shape_cursor >= shapes.size():
				_health_scan_cursor += 1
				_health_scan_entry = {}
				_health_scan_shape_cursor = 0
				continue
			var shape = shapes[_health_scan_shape_cursor]
			var shape_failure := _entry_shape_health_failure(shape,
				_health_scan_entry.get("body"))
			operations += 1
			_health_scan_shape_checks += 1
			if not shape_failure.is_empty():
				return _cache_physical_health_failure(
					_health_scan_blocks[_health_scan_cursor], shape_failure)
			_health_scan_shape_cursor += 1
			continue
		if _health_scan_cursor >= _health_scan_blocks.size(): break
		var block: Vector3i = _health_scan_blocks[_health_scan_cursor]
		var entry: Dictionary = _live.get(block, {})
		operations += 1
		var health_failure := "physical_entry_missing" if entry.is_empty() \
			else _entry_health_header_failure(entry)
		if not health_failure.is_empty():
			return _cache_physical_health_failure(block, health_failure)
		if bool(entry.get("expectedHit", false)):
			_health_scan_entry = entry
			_health_scan_shape_cursor = 0
		else:
			_health_scan_cursor += 1
	if _health_scan_cursor >= _health_scan_blocks.size():
		if _health_scan_epoch != _readiness_epoch \
				or _health_scan_identity != identity or not _source_current(identity):
			_health_scan_blocks = []
			_health_scan_cursor = 0
			_health_scan_entry = {}
			_health_scan_shape_cursor = 0
			_health_scan_epoch = -1
			return {"status":"pending", "reason":"physical_health_validation_drift",
				"operations":operations}
		_health_validated_epoch = _readiness_epoch
		_health_validated_source_ticket = _source_ticket
		_health_failure = {}
		_health_scan_blocks = []
		_health_scan_cursor = 0
		_health_scan_entry = {}
		_health_scan_shape_cursor = 0
		_health_scan_epoch = -1
		return {"status":"ready", "operations":operations,
			"maxOperations":HEALTH_VALIDATION_OPERATION_BUDGET,
			"maxStepUsec":Time.get_ticks_usec() - started,
			"maxStepUsecBudget":HEALTH_VALIDATION_STEP_USEC_BUDGET,
			"healthEpoch":_readiness_epoch,
			"shapeChecks":_health_scan_shape_checks}
	return {"status":"pending", "reason":"physical_health_validation_pending",
		"cursor":_health_scan_cursor, "total":_health_scan_blocks.size(),
		"shapeCursor":_health_scan_shape_cursor,
		"shapeChecks":_health_scan_shape_checks,
		"operations":operations,
		"maxOperations":HEALTH_VALIDATION_OPERATION_BUDGET,
		"maxStepUsec":Time.get_ticks_usec() - started,
		"maxStepUsecBudget":HEALTH_VALIDATION_STEP_USEC_BUDGET,
		"healthEpoch":_health_scan_epoch}

func _cache_physical_health_failure(block: Vector3i, failure: String) -> Dictionary:
	_readiness_epoch += 1
	_health_validated_epoch = -1
	_health_validated_source_ticket = ""
	_health_scan_blocks = []
	_health_scan_cursor = 0
	_health_scan_entry = {}
	_health_scan_shape_cursor = 0
	_health_scan_epoch = -1
	_health_failure = {"status":"failed",
		"reason":"resident_collision_entry_unhealthy",
		"healthFailure":failure,
		"block":block, "healthEpoch":_readiness_epoch}
	return _health_failure.duplicate(false)

func _invalidate_physical_health() -> void:
	_readiness_epoch += 1
	_health_validated_epoch = -1
	_health_validated_source_ticket = ""
	_health_failure = {}
	_health_required_physics_frame = Engine.get_physics_frames() + 1
	_health_scan_blocks = []
	_health_scan_cursor = 0
	_health_scan_entry = {}
	_health_scan_shape_cursor = 0
	_health_scan_shape_checks = 0
	_health_scan_epoch = -1


func startup_readiness(identity: Dictionary) -> Dictionary:
	var receipt := physical_receipt(identity)
	return {"status": "ready" if bool(receipt.get("ready", false)) else "pending",
		"reason": "" if bool(receipt.get("ready", false)) else "resident_collision_not_physical",
		"physicalReceipt": receipt}


func affected_window_readiness(identity: Dictionary, blocks: Array[Vector3i]) -> Dictionary:
	var receipt: Dictionary = physical_receipt(identity)
	if not bool(receipt.get("ready", false)):
		return {"status": "pending", "reason": "resident_collision_not_physical"}
	var wanted := {}
	var rows: Array[Dictionary] = []
	for block in blocks:
		if wanted.has(block) or not _live.has(block):
			return {"status": "failed", "reason": "affected_window_invalid"}
		wanted[block] = true
		var entry: Dictionary = _live[block]
		rows.append({"block": block, "artifactKey": entry.artifactKey,
			"physicsFrame": entry.physicsFrame, "physicalReady": true})
	return {"status": "ready", "requestIdentity": identity.duplicate(true),
		"sourceIdentity": _source_identity.duplicate(true),
		"meshBlockReceipts": rows}


## request.rows is complete for affected blocks. The source snapshot is the
## independent membership/artifact authority for every resident block.
func publish(request: Dictionary, barrier: RefCounted = null) -> Dictionary:
	if not _drain_terminal_failure.is_empty():
		return {"status":"failed",
			"reason":"resident_owner_memory_release_terminal_failure",
			"terminalMemoryFailure":_drain_terminal_failure.duplicate(true)}
	if _busy or _failed or _stopping or _stopped or _source == null or not is_inside_tree():
		return {"status": "failed", "reason": "resident_owner_unavailable"}
	_busy = true
	_readiness_epoch += 1
	var checked: Dictionary = await _validate_request(request)
	if _stopping:
		return _finish_stopped_publish({})
	if checked.get("status") != "ready":
		_busy = false
		return checked
	var identity: Dictionary = checked.requestIdentity
	var affected: Array[Vector3i] = checked.affected
	if not barrier is AdmissionBarrier or not barrier.is_active():
		_busy = false
		return {"status": "pending", "reason": "actor_admission_required"}
	var rows: Array = checked.rows
	var affected_bounds: AABB = rows[0].bounds
	for row in rows:
		affected_bounds = affected_bounds.merge(row.bounds)
	if not barrier.covers_bounds(identity, affected_bounds):
		_busy = false
		return {"status": "failed", "reason": "actor_barrier_bounds_incomplete"}
	var clearance: Dictionary = barrier.clearance(identity)
	if not bool(clearance.get("clear", false)):
		_busy = false
		return {"status": "pending", "reason": "actor_clearance_pending",
			"guardReason": clearance.get("reason", "")}
	_admission_barrier = barrier
	var memory_tokens := {}
	var memory_reservations: Array[String] = []
	if _memory_admission != null:
		for row in rows:
			var canonical_row: Dictionary = checked.canonicalRows[row.block]
			var vertices = canonical_row.get("vertices")
			if not vertices is PackedVector3Array:
				_cancel_unconstructed_memory(memory_reservations)
				_busy = false
				return {"status":"failed", "reason":"canonical_collision_vertices_invalid"}
			_memory_reservation_sequence += 1
			var reservation_id := "%s:%d:%s" % [_retirement_owner_epoch,
				_memory_reservation_sequence, str(row.block)]
			var reserved: Dictionary = _memory_admission.call("reserve_candidate",
				_retirement_owner_epoch, _memory_window_token, reservation_id,
				[{"vertexCount":vertices.size(),
					"expectedHit":bool(canonical_row.get("expectedHit", false))}])
			if reserved.get("status") != "ready":
				_cancel_unconstructed_memory(memory_reservations)
				_busy = false
				return {"status":reserved.get("status", "failed"),
					"reason":reserved.get("reason", "collision_memory_admission_failed"),
					"retryable":bool(reserved.get("retryable", false)),
					"memoryAdmission":reserved}
			var reservation_token := String(reserved.get("token", ""))
			if reservation_token.is_empty():
				_cancel_unconstructed_memory(memory_reservations)
				_busy = false
				return {"status":"failed", "reason":"collision_memory_token_missing"}
			memory_tokens[row.block] = reservation_token
			memory_reservations.append(reservation_token)
			_unconstructed_memory_tokens.append(reservation_token)
	if _memory_admission != null:
		_memory_last_candidate_admission = _memory_admission.call("snapshot")
	var candidates := {}
	var rows_by_block := {}
	var max_prepare_usec := 0
	var total_prepare_usec := 0
	var max_ack_frames := 0
	_prepare_max_work_units = 0
	_prepare_total_work_units = 0
	for row in rows:
		var candidate_entry: Dictionary = _new_candidate_entry(row,
			String(memory_tokens.get(row.block, "")))
		candidates[row.block] = candidate_entry
		_pending_candidate_keys.append(row.block)
		_pending_candidates = candidates
		var canonical_row: Dictionary = checked.canonicalRows[row.block]
		if _memory_admission != null:
			var candidate_ids: Array = [candidate_entry.body.get_instance_id()] \
				if is_instance_valid(candidate_entry.get("body")) else []
			var constructed: Dictionary = _memory_admission.call(
				"mark_candidate_constructed", candidate_entry.memoryToken,
				_retirement_owner_epoch, candidate_ids)
			if constructed.get("status") != "ready":
				return _fail_candidate_construction(candidates, candidate_entry,
					constructed)
			_unconstructed_memory_tokens.erase(candidate_entry.memoryToken)
		var prepared: Dictionary = await _prepare_row_bounded(row,
			canonical_row, candidate_entry)
		if _stopping:
			return _finish_stopped_publish(candidates)
		max_prepare_usec = maxi(max_prepare_usec,
			int(prepared.get("maxStepCpuUsec", 0)))
		total_prepare_usec += int(prepared.get("totalCpuUsec", 0))
		if prepared.get("status") != "ready":
			var candidate_disposal: Dictionary = _dispose_candidates(candidates)
			if candidate_disposal.get("status") != "ready":
				_busy = false
				return {"status":"failed", "reason":"candidate_disposal_rejected",
					"prepare":prepared, "disposal":candidate_disposal,
					"candidatesRetainedForDrain":_pending_candidates.size()}
			_pending_candidates.clear()
			_pending_candidate_keys.clear()
			_busy = false
			return prepared
		candidates[row.block] = prepared.entry
		rows_by_block[row.block] = row
		_pending_candidates = candidates
		if _stopping:
			return _finish_stopped_publish(candidates)
		var prepared_row_current: bool = await _source_row_current(
			row.block, identity, row)
		if _stopping:
			return _finish_stopped_publish(candidates)
		if not prepared_row_current:
			var candidate_disposal: Dictionary = _dispose_candidates(candidates)
			if candidate_disposal.get("status") != "ready":
				_busy = false
				return {"status":"failed", "reason":"candidate_disposal_rejected",
					"disposal":candidate_disposal,
					"candidatesRetainedForDrain":_pending_candidates.size()}
			_pending_candidates.clear()
			_pending_candidate_keys.clear()
			_busy = false
			return {"status": "pending", "reason": "candidate_source_row_drift"}
	var old := {}
	for block in affected:
		if _live.has(block):
			old[block] = _live[block]
	var switched_any := false
	for block in affected:
		var pre_switch_row_current: bool = await _source_row_current(
			block, identity, rows_by_block[block])
		if _stopping:
			return _finish_stopped_publish(candidates)
		if not pre_switch_row_current:
			if switched_any:
				var restored_drift: Dictionary = await _rollback(candidates, old)
				if _stopping or bool(restored_drift.get("cancelled", false)):
					return _finish_stopped_publish(candidates)
				if not bool(restored_drift.get("candidateDisposalReady", false)):
					_busy = false
					return {"status":"failed", "reason":"candidate_disposal_rejected",
						"rollback":restored_drift,
						"candidatesRetainedForDrain":_pending_candidates.size()}
				_pending_candidates.clear()
				_pending_candidate_keys.clear()
				_busy = false
				return {"status": "pending" if bool(restored_drift.get("physicalReady", false)) else "failed",
					"reason": "candidate_source_row_drift",
					"oldPhysicalRestored": restored_drift.get("physicalReady", false),
					"oldPhysicsFrame": restored_drift.get("physicsFrame", -1)}
			var candidate_disposal: Dictionary = _dispose_candidates(candidates)
			if candidate_disposal.get("status") != "ready":
				_busy = false
				return {"status":"failed", "reason":"candidate_disposal_rejected",
					"disposal":candidate_disposal,
					"candidatesRetainedForDrain":_pending_candidates.size()}
			_pending_candidates.clear()
			_pending_candidate_keys.clear()
			_busy = false
			return {"status": "pending", "reason": "candidate_source_row_drift",
				"oldPhysicalUnchanged": true}
		if _live.has(block):
			_set_enabled(old[block], false)
		_set_enabled(candidates[block], true)
		switched_any = true
		var source_current := false
		var actor_clear := false
		var physics_probe := false
		var ack_frames := 0
		for _attempt in range(MAX_ACK_FRAMES):
			await get_tree().physics_frame
			ack_frames += 1
			if _stopping:
				return _finish_stopped_publish(candidates)
			source_current = _candidate_source_current(identity, checked)
			if source_current:
				source_current = await _source_row_current(block, identity,
					rows_by_block[block])
				if _stopping:
					return _finish_stopped_publish(candidates)
			actor_clear = bool(barrier.clearance(identity).get("clear", false))
			physics_probe = _probe(candidates[block])
			if not source_current or not actor_clear or physics_probe:
				break
		max_ack_frames = maxi(max_ack_frames, ack_frames)
		if not source_current or not actor_clear or not physics_probe:
			var restored: Dictionary = await _rollback(candidates, old)
			if _stopping or bool(restored.get("cancelled", false)):
				return _finish_stopped_publish(candidates)
			if not bool(restored.get("candidateDisposalReady", false)):
				_busy = false
				return {"status":"failed", "reason":"candidate_disposal_rejected",
					"rollback":restored,
					"candidatesRetainedForDrain":_pending_candidates.size()}
			_pending_candidates.clear()
			_pending_candidate_keys.clear()
			_busy = false
			return {"status": "pending" if bool(restored.get("physicalReady", false)) else "failed",
				"reason": "candidate_physics_unacknowledged",
				"sourceCurrent": source_current, "actorClear": actor_clear,
				"physicsProbe": physics_probe, "failedBlock": block,
				"probeHit": _last_probe_hit,
				"maxPrepareUsec": max_prepare_usec,
				"maxAckFrames": max_ack_frames,
				"oldPhysicalRestored": restored.get("physicalReady", false),
				"oldPhysicsFrame": restored.get("physicsFrame", -1)}
		candidates[block]["physicsFrame"] = Engine.get_physics_frames()
	var final_source: Dictionary = await _validate_request(request)
	if final_source.get("status") != "ready":
		var restored_stale: Dictionary = await _rollback(candidates, old)
		if _stopping or bool(restored_stale.get("cancelled", false)):
			return _finish_stopped_publish(candidates)
		if not bool(restored_stale.get("candidateDisposalReady", false)):
			_busy = false
			return {"status":"failed", "reason":"candidate_disposal_rejected",
				"rollback":restored_stale,
				"candidatesRetainedForDrain":_pending_candidates.size()}
		_pending_candidates.clear()
		_pending_candidate_keys.clear()
		_busy = false
		return {"status": "pending", "reason": "candidate_source_changed_before_commit",
			"oldPhysicalRestored": restored_stale.get("physicalReady", false)}
	var previous_live := _live.duplicate()
	var previous_identity := _identity.duplicate(true)
	var previous_source_identity := _source_identity.duplicate(true)
	var previous_source_ticket := _source_ticket
	var previous_rebind_receipt := _source_rebind_receipt.duplicate(true)
	var previous_global_identity := _receipt_global_identity.duplicate(true)
	var previous_local_proof := _receipt_local_current_proof.duplicate(true)
	var previous_membership := _membership_provenance.duplicate(true)
	var previous_resident := _resident_blocks.duplicate()
	var previous_staging := _startup_staging
	for block in affected:
		_live[block] = candidates[block]
		if _memory_admission != null:
			var committed: Dictionary = _memory_admission.call("commit_live",
				String(candidates[block].get("memoryToken", "")),
				_retirement_owner_epoch)
			if committed.get("status") != "ready":
				_memory_accounting_failure = String(committed.get("reason",
					"collision_memory_live_transition_failed"))
				_failed = true
				_live = previous_live
				_identity = previous_identity
				_source_identity = previous_source_identity
				_source_ticket = previous_source_ticket
				_source_rebind_receipt = previous_rebind_receipt
				_receipt_global_identity = previous_global_identity
				_receipt_local_current_proof = previous_local_proof
				_membership_provenance = previous_membership
				_resident_blocks = previous_resident
				_startup_staging = previous_staging
				var rollback: Dictionary = await _rollback(candidates, old)
				if _stopping or bool(rollback.get("cancelled", false)):
					return _finish_stopped_publish(candidates)
				# Keep the candidate map and keys owned by the normal stop/drain
				# path. Ledger refusal must never orphan candidate bodies or tokens.
				_pending_candidates = candidates
				_busy = false
				return {"status":"failed", "reason":"collision_memory_live_transition_failed",
					"memoryAdmission":committed,
					"oldPhysicalRestored":bool(rollback.get("physicalReady", false)),
					"candidatesRetainedForDrain":_pending_candidates.size()}
	_identity = identity.duplicate(true)
	_source_identity = checked.sourceIdentity.duplicate(true)
	_source_ticket = String(checked.get("sourceTicket", ""))
	_source_rebind_receipt = {}
	_receipt_global_identity = checked.get("globalIdentity", identity).duplicate(true)
	_receipt_local_current_proof = checked.get("localCurrentProof", {}).duplicate(true)
	_membership_provenance = checked.membership.duplicate(true)
	_resident_blocks = checked.resident
	_receipt_resident_blocks = _resident_blocks.duplicate()
	_receipt_resident_blocks.make_read_only()
	_startup_staging = _live.size() < _resident_blocks.size()
	_restored_old_frame = -1
	_invalidate_physical_health()
	var health: Dictionary = {"status":"pending"}
	var health_steps := 0
	var max_health_step_usec := 0
	while health.get("status") == "pending" and health_steps < MAX_RESIDENT + 4:
		health = _advance_physical_health_validation(identity)
		max_health_step_usec = maxi(max_health_step_usec,
			int(health.get("maxStepUsec", 0)))
		health_steps += 1
		if health.get("status") == "pending":
			await get_tree().process_frame
			if _stopping:
				return _finish_stopped_committed_publish(old)
	if _stopping:
		return _finish_stopped_committed_publish(old)
	_busy = false
	var allowed_old_memory_tokens: Array[String] = []
	for old_entry in old.values():
		var old_memory_token := String(old_entry.get("memoryToken", ""))
		if not old_memory_token.is_empty():
			allowed_old_memory_tokens.append(old_memory_token)
	var receipt: Dictionary = _current_physical_receipt(identity,
		allowed_old_memory_tokens) if health.get("status") == "ready" \
		else {"ready":false, "reason":health.get("reason",
			"physical_health_validation_incomplete"), "healthValidation":health}
	if not _startup_staging and not bool(receipt.get("ready", false)):
		_busy = true
		_live = previous_live
		_identity = previous_identity
		_source_identity = previous_source_identity
		_source_ticket = previous_source_ticket
		_source_rebind_receipt = previous_rebind_receipt
		_receipt_global_identity = previous_global_identity
		_receipt_local_current_proof = previous_local_proof
		_membership_provenance = previous_membership
		_resident_blocks = previous_resident
		_startup_staging = previous_staging
		var restored_unready: Dictionary = await _rollback(candidates, old)
		if _stopping or bool(restored_unready.get("cancelled", false)):
			return _finish_stopped_publish(candidates)
		if not bool(restored_unready.get("candidateDisposalReady", false)):
			_busy = false
			return {"status":"failed", "reason":"candidate_disposal_rejected",
				"rollback":restored_unready,
				"candidatesRetainedForDrain":_pending_candidates.size()}
		_pending_candidates.clear()
		_pending_candidate_keys.clear()
		_busy = false
		return {"status": "pending", "reason": "physical_receipt_not_complete",
			"oldPhysicalRestored": restored_unready.get("physicalReady", false)}
	var previous_live_disposal: Dictionary = _dispose_previous_live_entries(old)
	if previous_live_disposal.get("status") != "ready":
		# Candidate entries are now the live map's exact owners; release the
		# temporary publish aliases while retry-map retains rejected old rows.
		_pending_candidates.clear()
		_pending_candidate_keys.clear()
		_busy = false
		return previous_live_disposal
	if not _startup_staging:
		receipt = physical_receipt(identity)
		if not bool(receipt.get("ready", false)):
			_pending_candidates.clear()
			_pending_candidate_keys.clear()
			_busy = false
			return {"status":"pending", "reason":"physical_receipt_after_retirement_pending",
				"physicalReceipt":receipt}
	_pending_candidates.clear()
	_pending_candidate_keys.clear()
	return {"status": "pending" if _startup_staging else "ready",
		"reason": "resident_startup_incomplete" if _startup_staging else "",
		"physicalReceipt": receipt,
		"physicalHealthValidation":{"status":health.get("status", "failed"),
			"steps":health_steps, "maxStepUsec":max_health_step_usec,
			"operationBudget":HEALTH_VALIDATION_OPERATION_BUDGET,
			"stepUsecBudget":HEALTH_VALIDATION_STEP_USEC_BUDGET},
		"affectedBlocks": affected.size(), "residentBlocks": _resident_blocks.size(),
		"validationMaxOperations":int(checked.get("maxValidationOperations", 0)),
		"validationMaxStepUsec":int(checked.get("maxValidationStepUsec", 0)),
		"maxPrepareUsec": max_prepare_usec,
		"totalPrepareUsec": total_prepare_usec,
		"prepareMaxWorkUnits": _prepare_max_work_units,
		"prepareTotalWorkUnits": _prepare_total_work_units,
		"prepareVertexBudget": PREPARE_VERTEX_BUDGET,
		"maxAckFrames": max_ack_frames}


func memory_admission_receipt() -> Dictionary:
	if _memory_admission == null:
		return {"status":"unconfigured", "productionCapsConfigured":false}
	var ledger_receipt: Dictionary = _memory_admission.call("snapshot")
	return {"status":"ready" if _memory_accounting_failure.is_empty() else "failed",
		"failure":_memory_accounting_failure,
		"windowToken":_memory_window_token,
		"ownerEpoch":_retirement_owner_epoch,
		"retiredEntryCount":_retired_memory_entries.size(),
		"disposalRetryCount":_disposal_retry_entries.size(),
		"lastCandidateAdmission":_memory_last_candidate_admission.duplicate(true),
		"ledger":ledger_receipt,
		"releaseEvidence":"scene_nodes_absent_after_process_and_physics_frames",
		"allocatorBytesMeasured":false, "physics_server_bytes_measured":false}


func restored_old_physics_frame() -> int:
	return _restored_old_frame


func startup_empty_receipt(identity: Dictionary) -> Dictionary:
	return {"empty": not _busy and not _stopping and not _stopped \
		and identity.get("ownerGeneration") is int \
		and _live.is_empty() and _pending_candidates.is_empty() \
		and _disposal_retry_entries.is_empty()}


func request_stop() -> Dictionary:
	if _stopped:
		return _drain_receipt.duplicate(false)
	if not _stopping:
		_stopping = true
		_readiness_epoch += 1
		_drain_last_queued_physics_frame = -1
		_drain_window_token = String(_membership_provenance.get("windowToken", ""))
		_drain_expected_resident_count = _resident_blocks.size()
		_drain_resident_blocks = _resident_blocks.duplicate()
		_drain_retired_candidate_count = 0
		_drain_retired_live_count = 0
		if _admission_barrier is AdmissionBarrier:
			_admission_barrier.owner_stopped(self)
	var preserved_reservations: Array[String] = []
	for entry in _pending_candidates.values():
		var token := String(entry.get("memoryToken", ""))
		if not token.is_empty(): preserved_reservations.append(token)
	for retry in _disposal_retry_entries.values():
		var token := String(retry.get("entry", {}).get("memoryToken", ""))
		if not token.is_empty() and not preserved_reservations.has(token):
			preserved_reservations.append(token)
	_cancel_unconstructed_memory(_unconstructed_memory_tokens.duplicate(),
		preserved_reservations)
	return {"status": "pending", "stopRequested": true,
		"inFlightPublish": _busy,
		"pendingEntries": _pending_candidates.size(),
		"disposalRetryEntries":_disposal_retry_entries.size(),
		"liveEntries": _live.size(), "remainingBodies": get_child_count(),
		"sourceRetained": _source != null,
		"barrierRetained": _admission_barrier != null,
		"windowToken": _drain_window_token}


## One nonblocking bounded drain quantum. The caller retries on a later frame;
## source and admission-barrier references survive until the exact final receipt.
func drain_step() -> Dictionary:
	if _stopped:
		return _drain_receipt.duplicate(false)
	if not _stopping:
		request_stop()
	if not _drain_terminal_failure.is_empty():
		return _drain_blocked(String(_drain_terminal_failure.get("reason",
			"collision_memory_release_retry_exhausted")), 0, 0, 0)
	if _busy:
		return _drain_progress("publish_in_flight", 0, 0, 0)
	var work_used := 0
	var visited := 0
	var retired_bodies := 0
	var blocked_candidate_reason := ""
	while _drain_terminal_failure.is_empty() \
			and work_used < DRAIN_WORK_BUDGET and retired_bodies < DRAIN_BODY_BUDGET \
			and not _pending_candidate_keys.is_empty():
		var candidate_block: Vector3i = _pending_candidate_keys.back()
		visited += 1
		if not _pending_candidates.has(candidate_block):
			_pending_candidate_keys.pop_back()
			work_used += 1
			continue
		var candidate_entry: Dictionary = _pending_candidates[candidate_block]
		if bool(candidate_entry.get("memoryConstructionRejected", false)):
			blocked_candidate_reason = "collision_memory_candidate_construction_unresolved"
			break
		var candidate_step: Dictionary = _advance_entry_drain(candidate_entry,
			DRAIN_WORK_BUDGET - work_used - 1)
		work_used += int(candidate_step.workUnits)
		if bool(candidate_step.bodyQueued): retired_bodies += 1
		if bool(candidate_step.done):
			_disposal_retry_entries.erase(String(candidate_entry.get("memoryToken", "")))
			_pending_candidates.erase(candidate_block)
			_pending_candidate_keys.pop_back()
			_drain_retired_candidate_count += 1
			work_used += 1
		if int(candidate_step.workUnits) <= 0 or not bool(candidate_step.done):
			break
	while _drain_terminal_failure.is_empty() \
			and work_used < DRAIN_WORK_BUDGET and retired_bodies < DRAIN_BODY_BUDGET \
			and not _resident_blocks.is_empty():
		var live_block: Vector3i = _resident_blocks.back()
		visited += 1
		if not _live.has(live_block):
			_resident_blocks.pop_back()
			work_used += 1
			continue
		var live_entry: Dictionary = _live[live_block]
		var live_step: Dictionary = _advance_entry_drain(live_entry,
			DRAIN_WORK_BUDGET - work_used - 1)
		work_used += int(live_step.workUnits)
		if bool(live_step.bodyQueued): retired_bodies += 1
		if bool(live_step.done):
			_disposal_retry_entries.erase(String(live_entry.get("memoryToken", "")))
			_live.erase(live_block)
			_resident_blocks.pop_back()
			_drain_retired_live_count += 1
			work_used += 1
		if int(live_step.workUnits) <= 0 or not bool(live_step.done):
			break
	while _drain_terminal_failure.is_empty() \
			and work_used < DRAIN_WORK_BUDGET and retired_bodies < DRAIN_BODY_BUDGET \
			and not _disposal_retry_entries.is_empty():
		var retry_token := String(_disposal_retry_entries.keys()[0])
		var retry_record: Dictionary = _disposal_retry_entries[retry_token]
		if bool(retry_record.get("conflict", false)):
			break
		var retry_entry: Dictionary = retry_record.get("entry", {})
		var already_owned := false
		for owned_entry in _pending_candidates.values():
			if String(owned_entry.get("memoryToken", "")) == retry_token:
				already_owned = true
				break
		if not already_owned:
			for owned_live_entry in _live.values():
				if String(owned_live_entry.get("memoryToken", "")) == retry_token:
					already_owned = true
					break
		if already_owned:
			_disposal_retry_entries.erase(retry_token)
			work_used += 1
			continue
		visited += 1
		var retry_step: Dictionary = _advance_entry_drain(retry_entry,
			DRAIN_WORK_BUDGET - work_used - 1)
		work_used += int(retry_step.workUnits)
		if bool(retry_step.bodyQueued): retired_bodies += 1
		if bool(retry_step.done):
			_disposal_retry_entries.erase(retry_token)
			_drain_retired_live_count += 1
			work_used += 1
		if int(retry_step.workUnits) <= 0 or not bool(retry_step.done):
			break
	_advance_retired_memory_entries()
	if not _drain_terminal_failure.is_empty():
		return _drain_blocked(String(_drain_terminal_failure.get("reason",
			"collision_memory_release_retry_exhausted")), work_used, visited,
			retired_bodies)
	if not blocked_candidate_reason.is_empty():
		return _drain_blocked(blocked_candidate_reason, work_used, visited,
			retired_bodies)
	if _pending_candidates.is_empty() and _live.is_empty() \
			and _pending_candidate_keys.is_empty() and _resident_blocks.is_empty() \
			and get_child_count() == 0 \
		and _retired_memory_entries.is_empty() \
		and _disposal_retry_entries.is_empty() \
		and _unconstructed_memory_tokens.is_empty() \
		and (_drain_last_queued_physics_frame < 0 \
				or Engine.get_physics_frames() > _drain_last_queued_physics_frame):
		_identity.make_read_only()
		_source_identity.make_read_only()
		_membership_provenance.make_read_only()
		var receipt := {"status": "ready", "drained": true,
			"remainingBodies": 0, "remainingPendingEntries": 0,
			"remainingLiveEntries": 0, "remainingDisposalRetryEntries":0,
			"sourceReleased": true,
			"barrierOwnershipReleased": true,
			"windowToken": _drain_window_token,
			"physicalOwnerEpoch": _retirement_owner_epoch,
			"residentBlockCount": _drain_expected_resident_count,
			"residentBlocks": _drain_resident_blocks.duplicate(),
			"requiredResidentBlocks": _drain_resident_blocks.duplicate(),
			"retiredCandidateEntryCount": _drain_retired_candidate_count,
			"retiredLiveEntryCount": _drain_retired_live_count,
			"memoryAdmission":memory_admission_receipt(),
			"identity": _identity,
			"sourceIdentity": _source_identity,
			"membershipProvenance": _membership_provenance,
			"drainWorkBudget": DRAIN_WORK_BUDGET,
			"drainBodyBudget": DRAIN_BODY_BUDGET}
		if _memory_admission != null:
			var owner_memory: Dictionary = _memory_admission.call(
				"owner_reservation_receipt", _retirement_owner_epoch,
				_drain_window_token)
			if owner_memory.get("status") != "ready" \
					or int(owner_memory.get("reservationCount", -1)) != 0 \
					or int(owner_memory.get("chargedBytes", -1)) != 0:
				return _drain_progress("collision_memory_owner_reservations_retained",
					work_used, visited, retired_bodies)
			receipt["memoryAdmission"] = owner_memory
		_source = null
		_admission_barrier = null
		_identity = {}
		_source_identity = {}
		_source_ticket = ""
		_source_rebind_receipt = {}
		_receipt_global_identity = {}
		_receipt_local_current_proof = {}
		_source_rebind_state.clear()
		_membership_provenance = {}
		_stopped = true
		_drain_receipt = receipt
		return _drain_receipt.duplicate(false)
	return _drain_progress("draining", work_used, visited, retired_bodies)


func stop_and_drain() -> Dictionary:
	request_stop()
	while true:
		var result: Dictionary = drain_step()
		if result.get("status") in ["ready", "failed"]:
			return result
		await get_tree().process_frame
	return {"status": "pending", "reason": "resident_owner_drain_interrupted"}


func _advance_entry_drain(entry: Dictionary, work_budget: int) -> Dictionary:
	var work_used := 0
	if work_budget <= 0:
		return {"done": false, "bodyQueued": false, "workUnits": 0}
	if _memory_admission != null and not bool(entry.get("memoryDeferred", false)):
		var deferred: Dictionary = _memory_admission.call("defer_release",
			String(entry.get("memoryToken", "")), _retirement_owner_epoch,
			Engine.get_physics_frames(), Engine.get_process_frames())
		if deferred.get("status") != "ready":
			_memory_accounting_failure = String(deferred.get("reason",
				"collision_memory_drain_defer_failed"))
			_failed = true
			_disable_entry_collision(entry)
			var terminal := _record_memory_release_rejection(
				String(entry.get("memoryToken", "")),
				"defer_release", _memory_accounting_failure)
			return {"done":false, "bodyQueued":false, "workUnits":0,
				"terminal":terminal}
		entry.memoryDeferred = true
		entry.memoryQueuedPhysicsFrame = Engine.get_physics_frames()
		entry.memoryQueuedProcessFrame = Engine.get_process_frames()
		entry.memoryBodyInstanceId = int(entry.body.get_instance_id()) \
			if is_instance_valid(entry.get("body")) else 0
		_retired_memory_entries.append({"entry":entry,
			"token":String(entry.get("memoryToken", "")),
			"ownerEpoch":_retirement_owner_epoch,
			"windowToken":_memory_window_token,
			"queuedPhysicsFrame":int(entry.memoryQueuedPhysicsFrame),
			"queuedProcessFrame":int(entry.memoryQueuedProcessFrame),
			"bodyInstanceIds":[int(entry.memoryBodyInstanceId)] \
				if int(entry.memoryBodyInstanceId) > 0 else []})
	var body = entry.get("body")
	if is_instance_valid(body) and body is StaticBody3D:
		if body.collision_layer != 0:
			body.collision_layer = 0
			_invalidate_physical_health()
	if not bool(entry.get("drainStarted", false)):
		entry.drainStarted = true
		work_used += 1
	if work_used >= work_budget:
		return {"done": false, "bodyQueued": false, "workUnits": work_used}
	var shapes: Array = entry.get("shapes", [])
	while not shapes.is_empty() and work_used < work_budget:
		var shape = shapes.back()
		if is_instance_valid(shape) and shape is CollisionShape3D:
			var shape_parent = shape.get_parent()
			if shape_parent == body:
				body.remove_child(shape)
			(entry.get("retiredShapes", []) as Array).append(shape)
			if not shape.is_queued_for_deletion(): shape.queue_free()
			_invalidate_physical_health()
		shapes.pop_back()
		work_used += 1
	if not shapes.is_empty():
		return {"done": false, "bodyQueued": false, "workUnits": work_used}
	if work_used >= work_budget:
		return {"done": false, "bodyQueued": false, "workUnits": work_used}
	var body_queued := false
	if is_instance_valid(body) and body is StaticBody3D \
			and not body.is_queued_for_deletion():
		body.queue_free()
		_invalidate_physical_health()
		body_queued = true
		_drain_last_queued_physics_frame = maxi(_drain_last_queued_physics_frame,
			Engine.get_physics_frames())
		work_used += 1
	return {"done": true, "bodyQueued": body_queued, "workUnits": maxi(work_used, 1)}


func _drain_progress(reason: String, work_units: int, visited: int,
		retired_bodies: int) -> Dictionary:
	return {"status": "pending", "reason": reason,
		"drainWorkUnitsThisStep": work_units,
		"visitedEntriesThisStep": visited,
		"drainedBodiesThisStep": retired_bodies,
		"drainWorkBudget": DRAIN_WORK_BUDGET,
		"drainBodyBudget": DRAIN_BODY_BUDGET,
		"remainingPendingEntries": _pending_candidates.size(),
		"remainingLiveEntries": _live.size(),
		"remainingDisposalRetryEntries": _disposal_retry_entries.size(),
		"memoryAccountingFailure":_memory_accounting_failure,
		"terminalMemoryFailure":_drain_terminal_failure.duplicate(true),
		"disposalRetryConflict":_disposal_retry_has_conflict(),
		"remainingBodies": get_child_count(),
		"inFlightPublish": _busy, "sourceRetained": _source != null,
		"barrierRetained": _admission_barrier != null,
		"windowToken": _drain_window_token}


func _drain_blocked(reason: String, work_units: int, visited: int,
		retired_bodies: int) -> Dictionary:
	return {"status":"failed", "drained":false, "blocked":true,
		"reason":reason, "drainWorkUnitsThisStep":work_units,
		"visitedEntriesThisStep":visited,
		"drainedBodiesThisStep":retired_bodies,
		"remainingPendingEntries":_pending_candidates.size(),
		"remainingLiveEntries":_live.size(),
		"remainingDisposalRetryEntries":_disposal_retry_entries.size(),
		"remainingBodies":get_child_count(),
		"memoryAccountingFailure":_memory_accounting_failure,
		"terminalMemoryFailure":_drain_terminal_failure.duplicate(true),
		"retainedCandidateReservedTokens":_unconstructed_memory_tokens.duplicate(),
		"memoryAdmission":memory_admission_receipt(),
		"sourceRetained":_source != null,
		"barrierRetained":_admission_barrier != null,
		"windowToken":_drain_window_token}


func _disposal_retry_has_conflict() -> bool:
	for retry in _disposal_retry_entries.values():
		if bool(retry.get("conflict", false)):
			return true
	return false


func _validate_request(request: Dictionary) -> Dictionary:
	if request.get("schema") != SCHEMA or not request.get("identity") is Dictionary \
			or not request.get("rows") is Array or not request.get("affectedBlocks") is Array:
		return {"status": "failed", "reason": "resident_request_schema_invalid"}
	# Reject untrusted declared sizes before traversing or allocating membership
	# sets. The subsequent cursorized validator uses these same hard ceilings.
	if request.affectedBlocks.is_empty() or request.affectedBlocks.size() > MAX_AFFECTED \
			or request.rows.is_empty() or request.rows.size() > MAX_AFFECTED \
			or not request.get("residentBlocks") is Array \
			or request.residentBlocks.is_empty():
		return {"status": "failed", "reason": "resident_request_capacity_invalid"}
	if request.residentBlocks.size() > MAX_RESIDENT:
		return {"status":"pending", "reason":"resident_window_capacity_backpressure",
			"retryable":true, "requestedResidentBlocks":request.residentBlocks.size(),
			"maxResidentBlocks":MAX_RESIDENT, "demandRetained":true}
	var identity: Dictionary = request.identity.duplicate(true)
	var requested_resident: Array = request.residentBlocks.duplicate()
	var requested_affected: Array = request.affectedBlocks.duplicate()
	var request_rows: Array = []
	for input_row in request.rows:
		request_rows.append(input_row.duplicate(false) if input_row is Dictionary else input_row)
	for field in ["ownerGeneration", "sourceRevision", "cancellationEpoch"]:
		if not identity.get(field) is int:
			return {"status": "failed", "reason": "resident_identity_invalid"}
	if not identity.get("sourceEpoch") is String \
			or String(identity.sourceEpoch).is_empty():
		return {"status": "failed", "reason": "resident_identity_invalid"}
	var ticket_api: bool = _source.has_method("collision_source_ticket") \
		and _source.has_method("collision_source_artifact_key") \
		and _source.has_method("collision_source_ticket_current")
	var source_snapshot: Dictionary = _source.call("collision_source_ticket") \
		if ticket_api else _source.call("collision_source_snapshot")
	if source_snapshot.get("status") == "pending":
		return {"status": "pending", "reason": source_snapshot.get("reason",
			"resident_source_pending")}
	if source_snapshot.get("status") != "ready" \
			or source_snapshot.get("identity") != identity \
			or not source_snapshot.get("sourceIdentity") is Dictionary \
			or source_snapshot.get("sourceEpoch") != identity.sourceEpoch \
			or int(source_snapshot.get("nativeRevision", -1)) != int(identity.sourceRevision) \
			or int(source_snapshot.get("ownerGeneration", -1)) != int(identity.ownerGeneration) \
			or int(source_snapshot.get("cancellationEpoch", -1)) != int(identity.cancellationEpoch) \
			or not source_snapshot.get("requiredResidentBlocks") is Array \
			or not source_snapshot.get("membershipProvenance") is Dictionary:
		return {"status": "failed", "reason": "resident_source_revision_mismatch"}
	var cursor_state := {"operations":0, "stepStartedUsec":Time.get_ticks_usec(),
		"sourceTicket":String(source_snapshot.get("ticket", "")),
		"maxOperations":0, "maxStepUsec":0}
	if String(source_snapshot.get("ticket", "")).is_empty() and ticket_api:
		return {"status": "failed", "reason": "resident_source_ticket_missing"}
	var membership: Dictionary = source_snapshot.membershipProvenance
	if membership.get("authority") != "pinned_demand" \
			or int(membership.get("demandRevision", -1)) < 0 \
			or String(membership.get("closureToken", "")).is_empty():
		return {"status": "failed", "reason": "resident_membership_provenance_missing"}
	var resident: Array[Vector3i] = []
	var resident_set := {}
	if source_snapshot.requiredResidentBlocks.is_empty():
		return {"status": "failed", "reason": "resident_capacity_invalid"}
	if source_snapshot.requiredResidentBlocks.size() > MAX_RESIDENT:
		return {"status":"pending", "reason":"resident_window_capacity_backpressure",
			"retryable":true,
			"requestedResidentBlocks":source_snapshot.requiredResidentBlocks.size(),
			"maxResidentBlocks":MAX_RESIDENT, "demandRetained":true}
	for block in source_snapshot.requiredResidentBlocks:
		if not block is Vector3i or resident_set.has(block):
			return {"status": "failed", "reason": "resident_membership_invalid"}
		resident.append(block)
		resident_set[block] = true
		if not await _validation_step(cursor_state):
			return {"status":"pending", "reason":"resident_validation_interrupted"}
	if resident.is_empty() or resident.size() > MAX_RESIDENT:
		return {"status":"pending", "reason":"resident_window_capacity_backpressure",
			"retryable":true, "requestedResidentBlocks":resident.size(),
			"maxResidentBlocks":MAX_RESIDENT, "demandRetained":true}
	var artifacts: Dictionary = source_snapshot.get("artifacts", {})
	if not ticket_api:
		var produced: Array = source_snapshot.get("residentBlocks", [])
		if not artifacts is Dictionary or produced.size() != resident.size() \
				or artifacts.size() != resident.size():
			return {"status": "pending", "reason": "required_resident_artifacts_incomplete"}
		if produced.size() != resident.size():
			return {"status": "pending", "reason": "required_resident_artifacts_incomplete"}
		var produced_set := {}
		for block in produced:
			if not block is Vector3i or produced_set.has(block):
				return {"status":"pending", "reason":"required_resident_artifacts_incomplete"}
			produced_set[block] = true
			if not await _validation_step(cursor_state):
				return {"status":"pending", "reason":"resident_validation_interrupted"}
		for block in resident:
			if not produced_set.has(block) or not artifacts.has(block) \
					or String(artifacts[block]).is_empty():
				return {"status": "pending", "reason": "required_resident_artifacts_incomplete"}
			if not await _validation_step(cursor_state):
				return {"status":"pending", "reason":"resident_validation_interrupted"}
	var requested: Array = requested_resident
	if requested.size() != resident.size():
		return {"status": "failed", "reason": "request_resident_membership_mismatch"}
	var requested_set := {}
	for block in requested:
		if not block is Vector3i or requested_set.has(block):
			return {"status": "failed", "reason": "request_resident_membership_mismatch"}
		requested_set[block] = true
		if not await _validation_step(cursor_state):
			return {"status":"pending", "reason":"resident_validation_interrupted"}
	if requested_set.size() != resident.size():
		return {"status": "failed", "reason": "request_resident_membership_mismatch"}
	for block in resident:
		if not requested_set.has(block):
			return {"status": "failed", "reason": "request_resident_membership_mismatch"}
		if not await _validation_step(cursor_state):
			return {"status":"pending", "reason":"resident_validation_interrupted"}
	if ticket_api:
		for block in resident:
			var artifact: Dictionary = _source.call("collision_source_artifact_key",
				block, String(source_snapshot.ticket))
			if artifact.get("status") != "ready" or String(artifact.get("artifactKey", "")).is_empty():
				return {"status": "pending", "reason": artifact.get("reason",
				"required_resident_artifacts_incomplete")}
			artifacts[block] = String(artifact.artifactKey)
			if not await _validation_step(cursor_state):
				return {"status":"pending", "reason":"resident_validation_interrupted"}
	var affected: Array[Vector3i] = []
	var affected_set := {}
	for block in requested_affected:
		if not block is Vector3i or not resident_set.has(block) or affected_set.has(block):
			return {"status": "failed", "reason": "affected_membership_invalid"}
		affected.append(block)
		affected_set[block] = true
		if not await _validation_step(cursor_state):
			return {"status":"pending", "reason":"resident_validation_interrupted"}
	if affected.is_empty() or affected.size() > MAX_AFFECTED:
		return {"status": "failed", "reason": "affected_capacity_invalid"}
	if _startup_staging and (identity != _identity \
			or source_snapshot.sourceIdentity != _source_identity \
			or membership != _membership_provenance \
			or resident != _resident_blocks):
		return {"status": "failed", "reason": "staged_startup_source_changed"}
	if not _startup_staging and not _live.is_empty() and _live.size() != resident.size():
		return {"status": "failed", "reason": "resident_set_changed_requires_republication"}
	if _startup_staging:
		for block in affected:
			if _live.has(block):
				return {"status": "failed", "reason": "staged_startup_block_repeated"}
	var rows_seen := {}
	var canonical_rows := {}
	var validated_rows: Array = []
	for row in request_rows:
		if not row is Dictionary or not row.get("block") is Vector3i \
				or not affected_set.has(row.block) or rows_seen.has(row.block) \
				or row.get("artifactKey") != artifacts.get(row.block):
			return {"status": "failed", "reason": "candidate_artifact_mismatch"}
		if row.get("sourceIdentity") != source_snapshot.sourceIdentity \
				or row.get("sourceEpoch") != identity.sourceEpoch \
				or int(row.get("nativeRevision", -1)) != int(identity.sourceRevision) \
				or int(row.get("ownerGeneration", -1)) != int(identity.ownerGeneration) \
				or int(row.get("cancellationEpoch", -1)) != int(identity.cancellationEpoch) \
				or not row.get("pinIdentity") is Dictionary \
				or not row.get("blockContentIdentity") is Dictionary \
				or int(row.get("shapingRegistryRevision", -1)) < 0 \
				or row.get("coordinateFrame") != "world" \
				or row.get("empty") != not bool(row.get("expectedHit", false)) \
				or not _world_block_bounds_valid(row):
			return {"status": "failed", "reason": "candidate_source_coordinates_invalid"}
		if not _source.has_method("collision_artifact_row_snapshot"):
			return {"status": "failed", "reason": "canonical_collision_snapshot_api_missing"}
		var canonical: Dictionary = _source.call("collision_artifact_row_snapshot",
			row.block, identity)
		var canonical_row: Dictionary = canonical.get("row", {})
		if canonical.get("status") != "ready" or canonical_row.is_empty() \
				or not _row_metadata_matches(row, canonical_row) \
				or not canonical_row.get("vertices") is PackedVector3Array \
				or (canonical_row.vertices as PackedVector3Array).size() \
				!= (row.vertices as PackedVector3Array).size():
			return {"status": "failed", "reason": "candidate_source_row_mismatch"}
		canonical_rows[row.block] = canonical_row
		rows_seen[row.block] = true
		validated_rows.append(row)
		if not await _validation_step(cursor_state):
			return {"status":"pending", "reason":"resident_validation_interrupted"}
	if rows_seen.size() != affected.size():
		return {"status": "failed", "reason": "candidate_affected_set_incomplete"}
	for block in resident:
		if not affected_set.has(block):
			var old: Dictionary = _live.get(block, {})
			if _startup_staging and old.is_empty() or _live.is_empty():
				continue
			if old.get("artifactKey") != artifacts.get(block) or not _entry_live(old):
				return {"status": "failed", "reason": "unchanged_resident_artifact_invalid"}
			if not await _validation_step(cursor_state):
				return {"status":"pending", "reason":"resident_validation_interrupted"}
	return {"status": "ready", "affected": affected, "resident": resident,
		"requestIdentity":identity.duplicate(true), "rows":validated_rows,
		"sourceIdentity": source_snapshot.sourceIdentity,
		"membership": membership, "canonicalRows": canonical_rows,
		"sourceTicket":String(source_snapshot.get("ticket", "")),
		"globalIdentity":source_snapshot.get("globalIdentity", identity).duplicate(true),
		"localCurrentProof":source_snapshot.get("localCurrentProof", {}).duplicate(true),
		"artifactKeys":artifacts, "maxValidationOperations":cursor_state.maxOperations,
		"maxValidationStepUsec":cursor_state.maxStepUsec}


func _validation_step(state: Dictionary) -> bool:
	state.operations = int(state.get("operations", 0)) + 1
	state.maxOperations = maxi(int(state.get("maxOperations", 0)),
		int(state.operations))
	var elapsed := Time.get_ticks_usec() - int(state.get("stepStartedUsec", 0))
	if int(state.operations) < VALIDATION_OPERATION_BUDGET \
			and elapsed < VALIDATION_STEP_USEC_BUDGET:
		return not _stopping
	state.maxStepUsec = maxi(int(state.get("maxStepUsec", 0)), elapsed)
	await get_tree().process_frame
	if _stopping: return false
	var ticket := String(state.get("sourceTicket", ""))
	if not ticket.is_empty() and (_source == null \
			or not _source.has_method("collision_source_ticket_current") \
			or not bool(_source.call("collision_source_ticket_current", ticket))):
		state.invalidated = true
		return false
	if _stopping: return false
	state.operations = 0
	state.stepStartedUsec = Time.get_ticks_usec()
	return true


func _new_candidate_entry(row: Dictionary, memory_token: String = "") -> Dictionary:
	var body: StaticBody3D = null
	if bool(row.expectedHit):
		body = StaticBody3D.new()
		body.name = "NativeCollision_%s" % str(row.block)
		body.collision_layer = 0
		body.collision_mask = 0
		add_child(body)
	return {"body": body, "shapes": [], "retiredShapes": [],
		"memoryToken":memory_token, "artifactKey": row.artifactKey,
		"probeFrom": row.probeFrom, "probeTo": row.probeTo,
		"expectedHit": row.expectedHit, "physicsFrame": -1}


func _prepare_row_bounded(row: Dictionary, canonical: Dictionary,
		entry: Dictionary) -> Dictionary:
	var vertices = row.get("vertices")
	var canonical_vertices = canonical.get("vertices")
	var bounds = row.get("bounds")
	if not vertices is PackedVector3Array or not canonical_vertices is PackedVector3Array \
			or vertices.size() % 3 != 0 or vertices.size() > MAX_VERTICES_PER_BLOCK \
				or canonical_vertices.size() != vertices.size() \
			or not bounds is AABB or not row.get("probeFrom") is Vector3 \
			or not row.get("probeTo") is Vector3 \
			or not bounds.has_point(row.probeFrom) or not bounds.has_point(row.probeTo) \
			or row.get("expectedHit") != not vertices.is_empty():
		var disposed_geometry: Dictionary = _dispose(entry)
		return {"status": "failed", "reason": "candidate_geometry_or_probe_invalid",
			"disposal":disposed_geometry}
	var cursor := 0
	var total_cpu_usec := 0
	var max_step_cpu_usec := 0
	while cursor < vertices.size():
		var step_started_usec := Time.get_ticks_usec()
		var end := mini(cursor + PREPARE_VERTEX_BUDGET, vertices.size())
		for index in range(cursor, end):
			var vertex: Vector3 = vertices[index]
			if vertex != canonical_vertices[index]:
				var disposed_mismatch: Dictionary = _dispose(entry)
				return {"status": "failed", "reason": "candidate_source_row_mismatch",
					"disposal":disposed_mismatch}
			if not vertex.is_finite() or not bounds.has_point(vertex):
				var disposed_vertex: Dictionary = _dispose(entry)
				return {"status": "failed", "reason": "candidate_vertex_invalid",
					"disposal":disposed_vertex}
		var mesh := ConcavePolygonShape3D.new()
		mesh.data = vertices.slice(cursor, end)
		mesh.backface_collision = true
		var shape := CollisionShape3D.new()
		shape.shape = mesh
		(entry.shapes as Array).append(shape)
		entry.body.add_child(shape)
		var work_units := end - cursor
		var step_cpu_usec := Time.get_ticks_usec() - step_started_usec
		total_cpu_usec += step_cpu_usec
		max_step_cpu_usec = maxi(max_step_cpu_usec, step_cpu_usec)
		_prepare_max_work_units = maxi(_prepare_max_work_units, work_units)
		_prepare_total_work_units += work_units
		cursor = end
		await get_tree().process_frame
		if _stopping:
			var disposed_stopping: Dictionary = _dispose(entry)
			return {"status": "failed", "reason": "resident_owner_stopping",
				"disposal":disposed_stopping}
	return {"status": "ready", "entry": entry,
		"maxStepCpuUsec": max_step_cpu_usec, "totalCpuUsec": total_cpu_usec}


func _world_block_bounds_valid(row: Dictionary) -> bool:
	if not row.get("bounds") is AABB or not row.get("vertices") is PackedVector3Array:
		return false
	var bounds: AABB = row.bounds
	if not bounds.position.is_finite() or not bounds.size.is_finite() \
			or bounds.size.x <= 0.0 or absf(bounds.size.y - bounds.size.x) > 0.001 \
			or absf(bounds.size.z - bounds.size.x) > 0.001:
		return false
	var origin := Vector3(row.block) * bounds.size.x
	if bounds.position.distance_to(origin) > maxf(0.001, bounds.size.x * 0.0001):
		return false
	return true


func _row_metadata_matches(left: Dictionary, right: Dictionary) -> bool:
	for field in ["block", "artifactKey", "bounds", "probeFrom", "probeTo",
			"expectedHit", "sourceIdentity", "pinIdentity", "blockContentIdentity",
			"nativeRevision", "shapingRegistryRevision", "sourceEpoch",
			"ownerGeneration", "cancellationEpoch", "coordinateFrame", "empty"]:
		if left.get(field) != right.get(field):
			return false
	return true


func _probe(entry: Dictionary) -> bool:
	var query := PhysicsRayQueryParameters3D.create(entry.probeFrom, entry.probeTo,
		COLLISION_LAYER)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	_last_probe_hit = {"empty": hit.is_empty(),
		"colliderId": hit.get("collider_id", 0),
		"expectedId": entry.body.get_instance_id() if entry.get("body") is StaticBody3D else 0,
		"layer": entry.body.collision_layer if entry.get("body") is StaticBody3D else 0}
	return not hit.is_empty() and hit.get("collider") == entry.body \
		if bool(entry.expectedHit) else hit.is_empty()


func _entry_live(entry: Dictionary) -> bool:
	return _entry_health_failure(entry).is_empty()


func _entry_health_failure(entry: Dictionary) -> String:
	var header_failure := _entry_health_header_failure(entry)
	if not header_failure.is_empty(): return header_failure
	if not bool(entry.get("expectedHit", false)): return ""
	for shape in entry.shapes:
		var shape_failure := _entry_shape_health_failure(shape, entry.body)
		if not shape_failure.is_empty(): return shape_failure
	return ""


func _entry_health_header_failure(entry: Dictionary) -> String:
	if not bool(entry.get("expectedHit", false)):
		return "" if entry.get("body") == null \
			and entry.get("shapes", []).is_empty() else "unexpected_empty_block_body"
	var body = entry.get("body")
	if not is_instance_valid(body) or not body is StaticBody3D:
		return "physical_body_invalid"
	if not body.is_inside_tree(): return "physical_body_not_in_tree"
	if body.is_queued_for_deletion(): return "physical_body_queued_for_deletion"
	if body.get_parent() != self: return "physical_body_owner_mismatch"
	if body.collision_layer != COLLISION_LAYER or body.collision_mask != 0:
		return "physical_body_layer_mismatch"
	if not entry.get("shapes") is Array or (entry.shapes as Array).is_empty() \
			or (entry.shapes as Array).size() > MAX_SHAPES_PER_BLOCK:
		return "physical_shape_set_invalid"
	return ""


func _entry_shape_health_failure(shape, body) -> String:
	if not is_instance_valid(shape) or not shape is CollisionShape3D:
		return "physical_shape_invalid"
	if not shape.is_inside_tree(): return "physical_shape_not_in_tree"
	if shape.is_queued_for_deletion(): return "physical_shape_queued_for_deletion"
	if shape.get_parent() != body: return "physical_shape_owner_mismatch"
	if shape.disabled: return "physical_shape_disabled"
	if shape.shape == null: return "physical_shape_resource_missing"
	return ""


func _entry_shapes_usable(entry: Dictionary, body) -> bool:
	if not is_instance_valid(body) or not body is StaticBody3D \
			or not body.is_inside_tree() or body.is_queued_for_deletion() \
			or body.get_parent() != self \
			or body.collision_mask != 0 \
			or not entry.get("shapes") is Array or (entry.shapes as Array).is_empty() \
			or (entry.shapes as Array).size() > MAX_SHAPES_PER_BLOCK:
		return false
	for shape in entry.shapes:
		if not is_instance_valid(shape) or not shape is CollisionShape3D \
				or not shape.is_inside_tree() or shape.is_queued_for_deletion() \
				or shape.get_parent() != body or shape.disabled or shape.shape == null:
			return false
	return true


func _set_enabled(entry: Dictionary, enabled: bool) -> void:
	if is_instance_valid(entry.get("body")) and entry.get("body") is StaticBody3D:
		var layer := COLLISION_LAYER if enabled else 0
		if entry.body.collision_layer != layer:
			entry.body.collision_layer = layer
			_invalidate_physical_health()


func _disable_entry_collision(entry: Dictionary) -> void:
	var changed := false
	var body = entry.get("body")
	if is_instance_valid(body) and body is StaticBody3D:
		if body.collision_layer != 0:
			body.collision_layer = 0
			changed = true
		if body.collision_mask != 0:
			body.collision_mask = 0
			changed = true
	for shape in entry.get("shapes", []) + entry.get("retiredShapes", []):
		if is_instance_valid(shape) and shape is CollisionShape3D \
				and not shape.disabled:
			shape.disabled = true
			changed = true
	if changed:
		_invalidate_physical_health()


func _dispose(entry: Dictionary) -> Dictionary:
	if bool(entry.get("memoryDisposed", false)):
		return {"status":"ready", "alreadyDisposed":true}
	var body = entry.get("body")
	var retired_shapes: Array = entry.get("retiredShapes", [])
	if _memory_admission != null and not String(entry.get("memoryToken", "")).is_empty():
		if not bool(entry.get("memoryDeferred", false)):
			var deferred: Dictionary = _memory_admission.call("defer_release",
				String(entry.memoryToken), _retirement_owner_epoch,
				Engine.get_physics_frames(), Engine.get_process_frames())
			if deferred.get("status") != "ready":
				_memory_accounting_failure = String(deferred.get("reason",
					"collision_memory_dispose_defer_failed"))
				_failed = true
				var terminal := _record_memory_release_rejection(
					String(entry.get("memoryToken", "")),
					"defer_release", _memory_accounting_failure)
				var retained: Dictionary = _retain_disposal_retry(entry)
				_disable_entry_collision(entry)
				return {"status":"failed", "reason":_memory_accounting_failure,
					"terminal":terminal,
					"retryTracked":bool(retained.get("tracked", false)),
					"memoryAdmission":deferred}
			entry.memoryDeferred = true
			entry.memoryQueuedPhysicsFrame = Engine.get_physics_frames()
			entry.memoryQueuedProcessFrame = Engine.get_process_frames()
			entry.memoryBodyInstanceId = int(body.get_instance_id()) \
				if is_instance_valid(body) else 0
			_retired_memory_entries.append({"entry":entry,
				"token":String(entry.memoryToken),
				"ownerEpoch":_retirement_owner_epoch,
				"windowToken":_memory_window_token,
				"queuedPhysicsFrame":int(entry.memoryQueuedPhysicsFrame),
				"queuedProcessFrame":int(entry.memoryQueuedProcessFrame),
				"bodyInstanceIds":[int(entry.memoryBodyInstanceId)] \
					if int(entry.memoryBodyInstanceId) > 0 else []})
	entry.memoryDisposed = true
	if is_instance_valid(body) and body is StaticBody3D:
		body.collision_layer = 0
		if not body.is_queued_for_deletion(): body.queue_free()
	for shape in entry.get("shapes", []):
		if is_instance_valid(shape) and shape is CollisionShape3D \
				and not shape.is_queued_for_deletion():
			shape.queue_free()
	for shape in retired_shapes:
		if is_instance_valid(shape) and shape is CollisionShape3D \
				and not shape.is_queued_for_deletion():
			shape.queue_free()
	entry["shapes"] = []
	entry["retiredShapes"] = retired_shapes
	return {"status":"ready", "disposed":true}


func _retain_disposal_retry(entry: Dictionary) -> Dictionary:
	var token := String(entry.get("memoryToken", ""))
	if token.is_empty():
		_memory_accounting_failure = "collision_memory_dispose_retry_token_missing"
		_failed = true
		return {"tracked":false, "reason":_memory_accounting_failure}
	var body = entry.get("body")
	var body_id := int(body.get_instance_id()) if is_instance_valid(body) else 0
	if _disposal_retry_entries.has(token):
		var existing: Dictionary = _disposal_retry_entries[token]
		var existing_entry: Dictionary = existing.get("entry", {})
		var existing_body = existing_entry.get("body")
		var existing_body_id := int(existing_body.get_instance_id()) \
			if is_instance_valid(existing_body) else 0
		if existing_body_id == body_id and existing_entry.get("memoryToken") == token:
			return {"tracked":true, "alreadyTracked":true}
		var conflicts: Array = existing.get("conflicts", [])
		if not conflicts.has(entry): conflicts.append(entry)
		existing["conflicts"] = conflicts
		existing["conflict"] = true
		_disposal_retry_entries[token] = existing
		_memory_accounting_failure = "collision_memory_dispose_retry_token_collision"
		_failed = true
		return {"tracked":true, "conflict":true,
			"reason":_memory_accounting_failure}
	var limits: Dictionary = _memory_admission.get("_limits") \
		if _memory_admission != null else {}
	var max_retries := mini(MAX_AFFECTED, int(limits.get("maxReservations", 0)))
	if max_retries <= 0 or _disposal_retry_entries.size() >= max_retries:
		_memory_accounting_failure = "collision_memory_dispose_retry_capacity_exhausted"
		_failed = true
		return {"tracked":false, "reason":_memory_accounting_failure}
	_disposal_retry_entries[token] = {"entry":entry, "conflict":false,
		"conflicts":[]}
	return {"tracked":true}


func _advance_retired_memory_entries() -> Dictionary:
	if _memory_admission == null or _retired_memory_entries.is_empty():
		return {"status":"ready"}
	if not _drain_terminal_failure.is_empty():
		return {"status":"failed", "terminal":_drain_terminal_failure.duplicate(true)}
	var retained: Array[Dictionary] = []
	for index in range(_retired_memory_entries.size()):
		var record: Dictionary = _retired_memory_entries[index]
		var entry: Dictionary = record.get("entry", {})
		var nodes_absent := true
		var body = entry.get("body")
		if is_instance_valid(body): nodes_absent = false
		for shape in entry.get("shapes", []):
			if is_instance_valid(shape): nodes_absent = false
		for shape in entry.get("retiredShapes", []):
			if is_instance_valid(shape): nodes_absent = false
		if not nodes_absent \
				or Engine.get_physics_frames() <= int(record.queuedPhysicsFrame) \
				or Engine.get_process_frames() <= int(record.queuedProcessFrame):
			retained.append(record)
			continue
		entry["body"] = null
		entry["shapes"] = []
		entry["retiredShapes"] = []
		var ack := {"schema":"n5-collision-memory-release-ack/v2",
			"ledgerEpoch":_memory_admission.call("snapshot").get("ledgerEpoch", ""),
			"ledgerIdentity":_memory_admission.call("snapshot").get("ledgerIdentity", ""),
			"reservationToken":String(record.token),
			"ownerEpoch":String(record.ownerEpoch),
			"windowToken":String(record.windowToken),
			"queuedPhysicsFrame":int(record.queuedPhysicsFrame),
			"queuedProcessFrame":int(record.queuedProcessFrame),
			"physicsFrame":Engine.get_physics_frames(),
			"processFrame":Engine.get_process_frames(),
			"allBodiesAbsent":true, "deferredEntriesReleased":true,
			"absentBodyInstanceIds":record.bodyInstanceIds,
			"observedColliderInstanceIds":[]}
		var released: Dictionary = _memory_admission.call(
			"acknowledge_deferred_release", String(record.token),
			String(record.ownerEpoch), ack)
		if released.get("status") != "ready":
			_memory_accounting_failure = String(released.get("reason",
				"collision_memory_release_ack_rejected"))
			var terminal := _record_memory_release_rejection(
				String(record.token), "acknowledge_deferred_release",
				_memory_accounting_failure)
			retained.append(record)
			if terminal:
				for remaining_index in range(index + 1,
						_retired_memory_entries.size()):
					retained.append(_retired_memory_entries[remaining_index])
				break
		else:
			_memory_release_attempts.erase(String(record.token))
	_retired_memory_entries = retained
	return {"status":"failed" if not _drain_terminal_failure.is_empty() else "ready",
		"terminal":_drain_terminal_failure.duplicate(true)}


func _record_memory_release_rejection(token: String, phase: String,
		detail: String) -> bool:
	var token_attempts: Dictionary = _memory_release_attempts.get(token, {})
	var attempts := int(token_attempts.get(phase, 0)) + 1
	token_attempts[phase] = attempts
	_memory_release_attempts[token] = token_attempts
	if attempts < MEMORY_RELEASE_MAX_ATTEMPTS:
		return false
	var reason := "collision_memory_defer_retry_exhausted" \
		if phase == "defer_release" else "collision_memory_release_ack_retry_exhausted"
	_drain_terminal_failure = {"phase":phase, "reason":reason,
		"detail":detail, "token":token,
		"attempts":attempts}
	_failed = true
	return true


func _cancel_unconstructed_memory(tokens: Array,
		preserved_tokens: Array = []) -> void:
	if _memory_admission == null: return
	for token_value in tokens:
		var token := String(token_value)
		if token.is_empty(): continue
		if preserved_tokens.has(token): continue
		var cancelled: Dictionary = _memory_admission.call("cancel_unconstructed",
			token, _retirement_owner_epoch)
		if cancelled.get("status") != "ready":
			_memory_accounting_failure = String(cancelled.get("reason",
				"collision_memory_unconstructed_cancel_failed"))
		_unconstructed_memory_tokens.erase(token)


func _remove_live_shape(block: Vector3i, shape_index: int) -> bool:
	if _busy or _stopping or _stopped or not _live.has(block): return false
	var entry: Dictionary = _live[block]
	var shapes: Array = entry.get("shapes", [])
	if shape_index < 0 or shape_index >= shapes.size(): return false
	var shape = shapes[shape_index]
	if is_instance_valid(shape) and shape is CollisionShape3D:
		if shape.get_parent() == entry.get("body"):
			entry.body.remove_child(shape)
		if not shape.is_queued_for_deletion(): shape.queue_free()
	var retired_shapes: Array = entry.get("retiredShapes", [])
	retired_shapes.append(shape)
	entry["retiredShapes"] = retired_shapes
	shapes.remove_at(shape_index)
	entry["shapes"] = shapes
	_live[block] = entry
	_invalidate_physical_health()
	return true


func _dispose_candidates(candidates: Dictionary) -> Dictionary:
	var preserved_reservations: Array[String] = []
	var failures: Array[Dictionary] = []
	for entry in candidates.values():
		var token := String(entry.get("memoryToken", ""))
		if not token.is_empty(): preserved_reservations.append(token)
		var disposed: Dictionary = _dispose(entry)
		if disposed.get("status") != "ready": failures.append({
			"token":token, "dispose":disposed})
	_cancel_unconstructed_memory(_unconstructed_memory_tokens.duplicate(),
		preserved_reservations)
	return {"status":"failed" if not failures.is_empty() else "ready",
		"failures":failures, "retainedCount":failures.size()}


func _dispose_previous_live_entries(old_entries: Dictionary) -> Dictionary:
	var old_blocks: Array = old_entries.keys()
	for index in range(old_blocks.size()):
		var block = old_blocks[index]
		var old_disposal: Dictionary = _dispose(old_entries[block])
		if old_disposal.get("status") != "ready":
			var unattempted_retained: Array = []
			for remaining_index in range(index + 1, old_blocks.size()):
				var remaining_block = old_blocks[remaining_index]
				var retained: Dictionary = _retain_disposal_retry(
					old_entries[remaining_block])
				unattempted_retained.append({"block":remaining_block,
					"tracked":bool(retained.get("tracked", false)),
					"result":retained})
			return {"status":"failed", "reason":"previous_live_disposal_rejected",
				"block":block, "disposal":old_disposal,
				"unattemptedOldEntriesRetained":unattempted_retained,
				"disposalRetryCount":_disposal_retry_entries.size()}
	return {"status":"ready", "disposedCount":old_entries.size()}


func _finish_stopped_publish(candidates: Dictionary) -> Dictionary:
	var preserved_reservations: Array[String] = []
	for entry in candidates.values():
		var token := String(entry.get("memoryToken", ""))
		if not token.is_empty(): preserved_reservations.append(token)
	_cancel_unconstructed_memory(_unconstructed_memory_tokens.duplicate(),
		preserved_reservations)
	_pending_candidates = candidates
	_busy = false
	return {"status": "failed", "reason": "resident_owner_stopping",
		"candidatesRetainedForDrain": _pending_candidates.size()}


func _finish_stopped_committed_publish(old_entries: Dictionary) -> Dictionary:
	# Both post-commit stop exits in publish (health-await and post-loop) route
	# through this single ownership-transfer seam before returning to the caller.
	var retained: Array[Dictionary] = []
	for block in old_entries:
		var retention: Dictionary = _retain_disposal_retry(old_entries[block])
		retained.append({"block":block, "result":retention})
	_pending_candidates.clear()
	_pending_candidate_keys.clear()
	_busy = false
	return {"status":"failed", "reason":"resident_owner_stopping_after_commit",
		"committedLiveEntriesRetained":_live.size(),
		"oldEntriesRetainedForDrain":retained,
		"disposalRetryCount":_disposal_retry_entries.size()}


func _fail_candidate_construction(candidates: Dictionary, entry: Dictionary,
		construction_result: Dictionary) -> Dictionary:
	var token := String(entry.get("memoryToken", ""))
	var original_reason := String(construction_result.get("reason",
		"collision_memory_constructed_transition_failed"))
	_memory_accounting_failure = original_reason
	_failed = true
	var body = entry.get("body")
	var shapes: Array = entry.get("shapes", [])
	var body_expected := bool(entry.get("expectedHit", false))
	var body_state_valid := false
	if body_expected:
		body_state_valid = is_instance_valid(body) and body is StaticBody3D
	else:
		body_state_valid = body == null
	if _memory_admission != null and not token.is_empty() \
			and body_state_valid \
			and shapes.is_empty() and entry.get("retiredShapes", []).is_empty():
		var body_ids: Array = [body.get_instance_id()] if body_expected else []
		var abort_registration: Dictionary = _memory_admission.call(
			"register_candidate_abort_body", token, _retirement_owner_epoch,
			body_ids)
		if abort_registration.get("status") == "ready":
			entry["memoryAbortBodyRegistered"] = true
			_unconstructed_memory_tokens.erase(token)
			var disposed: Dictionary = _dispose(entry)
			request_stop()
			var stopped := _finish_stopped_publish(candidates)
			stopped["reason"] = "candidate_construction_transition_rejected_recovered"
			stopped["constructionFailure"] = construction_result
			stopped["abortBodyRegistration"] = abort_registration
			stopped["disposal"] = disposed
			stopped["abortBodyRegistered"] = true
			return stopped
		construction_result["abortBodyRegistration"] = abort_registration
		_memory_accounting_failure = String(abort_registration.get("reason",
			"collision_memory_abort_body_registration_failed"))
	else:
		construction_result["abortBodyRegistration"] = {"status":"failed",
			"reason":"candidate_abort_body_not_shape_less_or_valid"}
		_memory_accounting_failure = original_reason
	entry["memoryConstructionRejected"] = true
	request_stop()
	var blocked := _finish_stopped_publish(candidates)
	blocked["reason"] = "collision_memory_candidate_construction_unresolved"
	blocked["constructionFailure"] = construction_result
	blocked["retainedBodyInstanceId"] = body.get_instance_id() \
		if is_instance_valid(body) else 0
	return blocked


func _rollback(candidates: Dictionary, old: Dictionary) -> Dictionary:
	var candidate_disposal: Dictionary = _dispose_candidates(candidates)
	for entry in old.values():
		_set_enabled(entry, true)
	await get_tree().physics_frame
	if _stopping:
		return {"physicalReady": false, "physicsFrame": -1, "cancelled": true,
			"candidateDisposalReady":candidate_disposal.get("status") == "ready",
			"candidateDisposal":candidate_disposal}
	var restored := true
	for entry in old.values():
		if not _probe(entry):
			restored = false
	for block in candidates:
		if not old.has(block) and not _probe_clear(candidates[block]):
			restored = false
	_restored_old_frame = Engine.get_physics_frames() if restored else -1
	if not restored:
		_failed = true
	return {"physicalReady": restored, "physicsFrame": _restored_old_frame,
		"candidateDisposalReady":candidate_disposal.get("status") == "ready",
		"candidateDisposal":candidate_disposal}


func _probe_clear(entry: Dictionary) -> bool:
	var query := PhysicsRayQueryParameters3D.create(entry.probeFrom, entry.probeTo,
		COLLISION_LAYER)
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _source_current(identity: Dictionary) -> bool:
	if not _source_ticket.is_empty():
		return identity == _identity and _source != null and is_instance_valid(_source) \
			and _source.has_method("collision_source_ticket_current") \
			and bool(_source.call("collision_source_ticket_current", _source_ticket))
	if not _source_revision_current(identity, _source_identity):
		return false
	var current: Dictionary = _source.call("collision_source_snapshot")
	var blocks: Array = current.get("residentBlocks", [])
	var required: Array = current.get("requiredResidentBlocks", [])
	if blocks.size() != _resident_blocks.size() or required.size() != _resident_blocks.size() \
			or current.get("membershipProvenance") != _membership_provenance:
		return false
	var blocks_set: Dictionary = _block_membership_set(blocks)
	var required_set: Dictionary = _block_membership_set(required)
	if blocks_set.size() != _resident_blocks.size() \
			or required_set.size() != _resident_blocks.size():
		return false
	for block in _resident_blocks:
		if not blocks_set.has(block) or not required_set.has(block) or not _live.has(block) \
				or current.get("artifacts", {}).get(block) != _live[block].artifactKey:
			return false
	return true


func _block_membership_set(blocks: Array) -> Dictionary:
	var result := {}
	for block in blocks:
		if not block is Vector3i or result.has(block):
			return {}
		result[block] = true
	return result


func _source_revision_current(identity: Dictionary, source_identity: Dictionary) -> bool:
	if _source == null or not is_instance_valid(_source):
		return false
	if not _source_ticket.is_empty():
		return identity == _identity and source_identity == _source_identity \
			and _source.has_method("collision_source_ticket_current") \
			and bool(_source.call("collision_source_ticket_current", _source_ticket))
	var current: Dictionary = _source.call("collision_source_snapshot")
	return current.get("status") == "ready" and current.get("identity") == identity \
		and current.get("sourceIdentity") == source_identity


func _candidate_source_current(identity: Dictionary, checked: Dictionary) -> bool:
	if not String(checked.get("sourceTicket", "")).is_empty():
		return identity == checked.get("requestIdentity", {}) \
			and _source != null and _source.has_method("collision_source_ticket_current") \
			and bool(_source.call("collision_source_ticket_current",
				String(checked.sourceTicket)))
	if not _source_revision_current(identity, checked.sourceIdentity):
		return false
	var current: Dictionary = _source.call("collision_source_snapshot")
	return current.get("membershipProvenance") == checked.membership \
		and current.get("requiredResidentBlocks") == checked.resident \
		and current.get("residentBlocks") == checked.resident


func _source_row_current(block: Vector3i, identity: Dictionary, row: Dictionary) -> bool:
	if _source == null or not is_instance_valid(_source):
		return false
	if not _source.has_method("collision_artifact_row_snapshot"):
		return false
	var current: Dictionary = _source.call("collision_artifact_row_snapshot", block,
		identity)
	var canonical: Dictionary = current.get("row", {})
	if current.get("status") != "ready" or canonical.is_empty() \
			or not _row_metadata_matches(row, canonical) \
			or not row.get("vertices") is PackedVector3Array \
			or not canonical.get("vertices") is PackedVector3Array:
		return false
	var vertices: PackedVector3Array = row.vertices
	var canonical_vertices: PackedVector3Array = canonical.vertices
	if vertices.size() != canonical_vertices.size():
		return false
	var cursor := 0
	while cursor < vertices.size():
		var end := mini(cursor + PREPARE_VERTEX_BUDGET, vertices.size())
		for index in range(cursor, end):
			if vertices[index] != canonical_vertices[index]:
				return false
		var work_units := end - cursor
		_prepare_max_work_units = maxi(_prepare_max_work_units, work_units)
		_prepare_total_work_units += work_units
		cursor = end
		await get_tree().process_frame
		if _stopping:
			return false
	return true
