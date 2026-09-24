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
const DRAIN_WORK_BUDGET := 64
const DRAIN_BODY_BUDGET := 16
const MAX_ACK_FRAMES := 6

var _source: Object
var _live := {}
var _identity := {}
var _source_identity := {}
var _membership_provenance := {}
var _resident_blocks: Array[Vector3i] = []
var _startup_staging := false
var _busy := false
var _failed := false
var _stopping := false
var _stopped := false
var _pending_candidates := {}
var _pending_candidate_keys: Array[Vector3i] = []
var _admission_barrier: RefCounted
var _restored_old_frame := -1
var _last_probe_hit := {}
var _drain_receipt := {}
var _prepare_max_work_units := 0
var _prepare_total_work_units := 0
var _drain_last_queued_physics_frame := -1
var _drain_window_token := ""
var _drain_expected_resident_count := 0
var _drain_retired_candidate_count := 0
var _drain_retired_live_count := 0


func bind_source(source: Object) -> bool:
	if _source != null or source == null \
			or not source.has_method("collision_source_snapshot") \
			or not source.has_method("collision_artifact_row"):
		return false
	_source = source
	return true


func physical_receipt(identity: Dictionary) -> Dictionary:
	if _busy or _failed or _stopping or _stopped or identity != _identity \
			or _live.size() != _resident_blocks.size() \
			or not _source_current(identity):
		return {"ready": false}
	for block in _resident_blocks:
		var entry: Dictionary = _live.get(block, {})
		if entry.is_empty() or int(entry.get("physicsFrame", -1)) < 0 \
				or not _entry_live(entry):
			return {"ready": false}
	return {"ready": true, "physicsFrame": Engine.get_physics_frames(),
		"provenance": {"requestIdentity": _identity.duplicate(true),
			"sourceIdentity": _source_identity.duplicate(true),
			"membershipProvenance": _membership_provenance.duplicate(true)},
		"residentBlockCount": _resident_blocks.size(),
		"residentBlocks": _resident_blocks.duplicate()}


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
	if _busy or _failed or _stopping or _stopped or _source == null or not is_inside_tree():
		return {"status": "failed", "reason": "resident_owner_unavailable"}
	var checked: Dictionary = _validate_request(request)
	if checked.get("status") != "ready":
		return checked
	var identity: Dictionary = request.identity
	var affected: Array[Vector3i] = checked.affected
	if not barrier is AdmissionBarrier or not barrier.is_active():
		return {"status": "pending", "reason": "actor_admission_required"}
	var affected_bounds: AABB = request.rows[0].bounds
	for row in request.rows:
		affected_bounds = affected_bounds.merge(row.bounds)
	if not barrier.covers_bounds(identity, affected_bounds):
		return {"status": "failed", "reason": "actor_barrier_bounds_incomplete"}
	var clearance: Dictionary = barrier.clearance(identity)
	if not bool(clearance.get("clear", false)):
		return {"status": "pending", "reason": "actor_clearance_pending",
			"guardReason": clearance.get("reason", "")}
	_busy = true
	_admission_barrier = barrier
	var candidates := {}
	var rows_by_block := {}
	var max_prepare_usec := 0
	var total_prepare_usec := 0
	var max_ack_frames := 0
	_prepare_max_work_units = 0
	_prepare_total_work_units = 0
	for row in request.rows:
		var candidate_entry: Dictionary = _new_candidate_entry(row)
		candidates[row.block] = candidate_entry
		_pending_candidate_keys.append(row.block)
		_pending_candidates = candidates
		var canonical_row: Dictionary = checked.canonicalRows[row.block]
		var prepared: Dictionary = await _prepare_row_bounded(row,
			canonical_row, candidate_entry)
		if _stopping:
			return _finish_stopped_publish(candidates)
		max_prepare_usec = maxi(max_prepare_usec,
			int(prepared.get("maxStepCpuUsec", 0)))
		total_prepare_usec += int(prepared.get("totalCpuUsec", 0))
		if prepared.get("status") != "ready":
			_dispose_candidates(candidates)
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
			_dispose_candidates(candidates)
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
				_pending_candidates.clear()
				_pending_candidate_keys.clear()
				_busy = false
				return {"status": "pending" if bool(restored_drift.get("physicalReady", false)) else "failed",
					"reason": "candidate_source_row_drift",
					"oldPhysicalRestored": restored_drift.get("physicalReady", false),
					"oldPhysicsFrame": restored_drift.get("physicsFrame", -1)}
			_dispose_candidates(candidates)
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
	var final_source: Dictionary = _validate_request(request)
	if final_source.get("status") != "ready":
		var restored_stale: Dictionary = await _rollback(candidates, old)
		if _stopping or bool(restored_stale.get("cancelled", false)):
			return _finish_stopped_publish(candidates)
		_pending_candidates.clear()
		_pending_candidate_keys.clear()
		_busy = false
		return {"status": "pending", "reason": "candidate_source_changed_before_commit",
			"oldPhysicalRestored": restored_stale.get("physicalReady", false)}
	var previous_live := _live.duplicate()
	var previous_identity := _identity.duplicate(true)
	var previous_source_identity := _source_identity.duplicate(true)
	var previous_membership := _membership_provenance.duplicate(true)
	var previous_resident := _resident_blocks.duplicate()
	var previous_staging := _startup_staging
	for block in affected:
		_live[block] = candidates[block]
	_identity = identity.duplicate(true)
	_source_identity = checked.sourceIdentity.duplicate(true)
	_membership_provenance = checked.membership.duplicate(true)
	_resident_blocks = checked.resident
	_startup_staging = _live.size() < _resident_blocks.size()
	_restored_old_frame = -1
	_busy = false
	var receipt: Dictionary = physical_receipt(identity)
	if not _startup_staging and not bool(receipt.get("ready", false)):
		_busy = true
		_live = previous_live
		_identity = previous_identity
		_source_identity = previous_source_identity
		_membership_provenance = previous_membership
		_resident_blocks = previous_resident
		_startup_staging = previous_staging
		var restored_unready: Dictionary = await _rollback(candidates, old)
		if _stopping or bool(restored_unready.get("cancelled", false)):
			return _finish_stopped_publish(candidates)
		_pending_candidates.clear()
		_pending_candidate_keys.clear()
		_busy = false
		return {"status": "pending", "reason": "physical_receipt_not_complete",
			"oldPhysicalRestored": restored_unready.get("physicalReady", false)}
	for block in affected:
		if old.has(block):
			_dispose(old[block])
	_pending_candidates.clear()
	_pending_candidate_keys.clear()
	return {"status": "pending" if _startup_staging else "ready",
		"reason": "resident_startup_incomplete" if _startup_staging else "",
		"physicalReceipt": receipt,
		"affectedBlocks": affected.size(), "residentBlocks": _resident_blocks.size(),
		"maxPrepareUsec": max_prepare_usec,
		"totalPrepareUsec": total_prepare_usec,
		"prepareMaxWorkUnits": _prepare_max_work_units,
		"prepareTotalWorkUnits": _prepare_total_work_units,
		"prepareVertexBudget": PREPARE_VERTEX_BUDGET,
		"maxAckFrames": max_ack_frames}


func restored_old_physics_frame() -> int:
	return _restored_old_frame


func startup_empty_receipt(identity: Dictionary) -> Dictionary:
	return {"empty": not _busy and not _stopping and not _stopped \
		and identity.get("ownerGeneration") is int \
		and _live.is_empty() and _pending_candidates.is_empty()}


func request_stop() -> Dictionary:
	if _stopped:
		return _drain_receipt.duplicate(false)
	if not _stopping:
		_stopping = true
		_drain_last_queued_physics_frame = -1
		_drain_window_token = String(_membership_provenance.get("windowToken", ""))
		_drain_expected_resident_count = _resident_blocks.size()
		_drain_retired_candidate_count = 0
		_drain_retired_live_count = 0
		if _admission_barrier is AdmissionBarrier:
			_admission_barrier.owner_stopped(self)
	return {"status": "pending", "stopRequested": true,
		"inFlightPublish": _busy,
		"pendingEntries": _pending_candidates.size(),
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
	if _busy:
		return _drain_progress("publish_in_flight", 0, 0, 0)
	var work_used := 0
	var visited := 0
	var retired_bodies := 0
	while work_used < DRAIN_WORK_BUDGET and retired_bodies < DRAIN_BODY_BUDGET \
			and not _pending_candidate_keys.is_empty():
		var candidate_block: Vector3i = _pending_candidate_keys.back()
		visited += 1
		if not _pending_candidates.has(candidate_block):
			_pending_candidate_keys.pop_back()
			work_used += 1
			continue
		var candidate_entry: Dictionary = _pending_candidates[candidate_block]
		var candidate_step: Dictionary = _advance_entry_drain(candidate_entry,
			DRAIN_WORK_BUDGET - work_used - 1)
		work_used += int(candidate_step.workUnits)
		if bool(candidate_step.bodyQueued): retired_bodies += 1
		if bool(candidate_step.done):
			_pending_candidates.erase(candidate_block)
			_pending_candidate_keys.pop_back()
			_drain_retired_candidate_count += 1
			work_used += 1
		if int(candidate_step.workUnits) <= 0 or not bool(candidate_step.done):
			break
	while work_used < DRAIN_WORK_BUDGET and retired_bodies < DRAIN_BODY_BUDGET \
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
			_live.erase(live_block)
			_resident_blocks.pop_back()
			_drain_retired_live_count += 1
			work_used += 1
		if int(live_step.workUnits) <= 0 or not bool(live_step.done):
			break
	if _pending_candidates.is_empty() and _live.is_empty() \
			and _pending_candidate_keys.is_empty() and _resident_blocks.is_empty() \
			and get_child_count() == 0 \
		and (_drain_last_queued_physics_frame < 0 \
				or Engine.get_physics_frames() > _drain_last_queued_physics_frame):
		_identity.make_read_only()
		_source_identity.make_read_only()
		_membership_provenance.make_read_only()
		var receipt := {"status": "ready", "drained": true,
			"remainingBodies": 0, "remainingPendingEntries": 0,
			"remainingLiveEntries": 0, "sourceReleased": true,
			"barrierOwnershipReleased": true,
			"windowToken": _drain_window_token,
			"residentBlockCount": _drain_expected_resident_count,
			"retiredCandidateEntryCount": _drain_retired_candidate_count,
			"retiredLiveEntryCount": _drain_retired_live_count,
			"identity": _identity,
			"sourceIdentity": _source_identity,
			"membershipProvenance": _membership_provenance,
			"drainWorkBudget": DRAIN_WORK_BUDGET,
			"drainBodyBudget": DRAIN_BODY_BUDGET}
		_source = null
		_admission_barrier = null
		_identity = {}
		_source_identity = {}
		_membership_provenance = {}
		_stopped = true
		_drain_receipt = receipt
		return _drain_receipt.duplicate(false)
	return _drain_progress("draining", work_used, visited, retired_bodies)


func stop_and_drain() -> Dictionary:
	request_stop()
	while true:
		var result: Dictionary = drain_step()
		if result.get("status") == "ready":
			return result
		await get_tree().process_frame
	return {"status": "pending", "reason": "resident_owner_drain_interrupted"}


func _advance_entry_drain(entry: Dictionary, work_budget: int) -> Dictionary:
	var work_used := 0
	if work_budget <= 0:
		return {"done": false, "bodyQueued": false, "workUnits": 0}
	var body = entry.get("body")
	if is_instance_valid(body) and body is StaticBody3D:
		body.collision_layer = 0
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
				shape.queue_free()
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
		"remainingBodies": get_child_count(),
		"inFlightPublish": _busy, "sourceRetained": _source != null,
		"barrierRetained": _admission_barrier != null,
		"windowToken": _drain_window_token}


func _validate_request(request: Dictionary) -> Dictionary:
	if request.get("schema") != SCHEMA or not request.get("identity") is Dictionary \
			or not request.get("rows") is Array or not request.get("affectedBlocks") is Array:
		return {"status": "failed", "reason": "resident_request_schema_invalid"}
	var identity: Dictionary = request.identity
	for field in ["ownerGeneration", "sourceRevision", "cancellationEpoch"]:
		if not identity.get(field) is int:
			return {"status": "failed", "reason": "resident_identity_invalid"}
	if not identity.get("sourceEpoch") is String \
			or String(identity.sourceEpoch).is_empty():
		return {"status": "failed", "reason": "resident_identity_invalid"}
	var source_snapshot: Dictionary = _source.call("collision_source_snapshot")
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
			or not source_snapshot.get("residentBlocks") is Array \
			or not source_snapshot.get("artifacts") is Dictionary \
			or not source_snapshot.get("membershipProvenance") is Dictionary:
		return {"status": "failed", "reason": "resident_source_revision_mismatch"}
	var membership: Dictionary = source_snapshot.membershipProvenance
	if membership.get("authority") != "pinned_demand" \
			or int(membership.get("demandRevision", -1)) < 0 \
			or String(membership.get("closureToken", "")).is_empty():
		return {"status": "failed", "reason": "resident_membership_provenance_missing"}
	var resident: Array[Vector3i] = []
	var resident_set := {}
	for block in source_snapshot.requiredResidentBlocks:
		if not block is Vector3i or resident_set.has(block):
			return {"status": "failed", "reason": "resident_membership_invalid"}
		resident.append(block)
		resident_set[block] = true
	if resident.is_empty() or resident.size() > MAX_RESIDENT:
		return {"status": "failed", "reason": "resident_capacity_invalid"}
	var produced: Array = source_snapshot.residentBlocks
	var artifacts: Dictionary = source_snapshot.artifacts
	if produced.size() != resident.size() or artifacts.size() != resident.size():
		return {"status": "pending", "reason": "required_resident_artifacts_incomplete"}
	var produced_set: Dictionary = _block_membership_set(produced)
	if produced_set.size() != resident.size():
		return {"status": "pending", "reason": "required_resident_artifacts_incomplete"}
	for block in resident:
		if not produced_set.has(block) or not artifacts.has(block) \
				or String(artifacts[block]).is_empty():
			return {"status": "pending", "reason": "required_resident_artifacts_incomplete"}
	var requested: Array = request.get("residentBlocks", [])
	if requested.size() != resident.size():
		return {"status": "failed", "reason": "request_resident_membership_mismatch"}
	var requested_set: Dictionary = _block_membership_set(requested)
	if requested_set.size() != resident.size():
		return {"status": "failed", "reason": "request_resident_membership_mismatch"}
	for block in resident:
		if not requested_set.has(block):
			return {"status": "failed", "reason": "request_resident_membership_mismatch"}
	var affected: Array[Vector3i] = []
	var affected_set := {}
	for block in request.affectedBlocks:
		if not block is Vector3i or not resident_set.has(block) or affected_set.has(block):
			return {"status": "failed", "reason": "affected_membership_invalid"}
		affected.append(block)
		affected_set[block] = true
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
	for row in request.rows:
		if not row is Dictionary or not row.get("block") is Vector3i \
				or not affected_set.has(row.block) or rows_seen.has(row.block) \
				or row.get("artifactKey") != source_snapshot.artifacts.get(row.block):
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
	if rows_seen.size() != affected.size():
		return {"status": "failed", "reason": "candidate_affected_set_incomplete"}
	for block in resident:
		if not affected_set.has(block):
			var old: Dictionary = _live.get(block, {})
			if _startup_staging and old.is_empty() or _live.is_empty():
				continue
			if old.get("artifactKey") != source_snapshot.artifacts.get(block) or not _entry_live(old):
				return {"status": "failed", "reason": "unchanged_resident_artifact_invalid"}
	return {"status": "ready", "affected": affected, "resident": resident,
		"sourceIdentity": source_snapshot.sourceIdentity,
		"membership": membership, "canonicalRows": canonical_rows}


func _new_candidate_entry(row: Dictionary) -> Dictionary:
	var body: StaticBody3D = null
	if bool(row.expectedHit):
		body = StaticBody3D.new()
		body.name = "NativeCollision_%s" % str(row.block)
		body.collision_layer = 0
		body.collision_mask = 0
		add_child(body)
	return {"body": body, "shapes": [], "artifactKey": row.artifactKey,
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
		_dispose(entry)
		return {"status": "failed", "reason": "candidate_geometry_or_probe_invalid"}
	var cursor := 0
	var total_cpu_usec := 0
	var max_step_cpu_usec := 0
	while cursor < vertices.size():
		var step_started_usec := Time.get_ticks_usec()
		var end := mini(cursor + PREPARE_VERTEX_BUDGET, vertices.size())
		for index in range(cursor, end):
			var vertex: Vector3 = vertices[index]
			if vertex != canonical_vertices[index]:
				_dispose(entry)
				return {"status": "failed", "reason": "candidate_source_row_mismatch"}
			if not vertex.is_finite() or not bounds.has_point(vertex):
				_dispose(entry)
				return {"status": "failed", "reason": "candidate_vertex_invalid"}
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
			_dispose(entry)
			return {"status": "failed", "reason": "resident_owner_stopping"}
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
	if not bool(entry.get("expectedHit", false)):
		return entry.get("body") == null
	if not is_instance_valid(entry.get("body")) or not entry.body is StaticBody3D \
			or not entry.body.is_inside_tree() \
			or entry.body.collision_layer != COLLISION_LAYER \
			or not entry.get("shapes") is Array or (entry.shapes as Array).is_empty():
		return false
	for shape in entry.shapes:
		if not is_instance_valid(shape) or not shape is CollisionShape3D \
				or shape.disabled or shape.shape == null:
			return false
	return true


func _set_enabled(entry: Dictionary, enabled: bool) -> void:
	if is_instance_valid(entry.get("body")) and entry.get("body") is StaticBody3D:
		entry.body.collision_layer = COLLISION_LAYER if enabled else 0


func _dispose(entry: Dictionary) -> void:
	if is_instance_valid(entry.get("body")) and entry.get("body") is StaticBody3D:
		entry.body.collision_layer = 0
		if not entry.body.is_queued_for_deletion():
			entry.body.queue_free()


func _dispose_candidates(candidates: Dictionary) -> void:
	for entry in candidates.values():
		_dispose(entry)


func _finish_stopped_publish(candidates: Dictionary) -> Dictionary:
	_pending_candidates = candidates
	_busy = false
	return {"status": "failed", "reason": "resident_owner_stopping",
		"candidatesRetainedForDrain": _pending_candidates.size()}


func _rollback(candidates: Dictionary, old: Dictionary) -> Dictionary:
	_dispose_candidates(candidates)
	for entry in old.values():
		_set_enabled(entry, true)
	await get_tree().physics_frame
	if _stopping:
		return {"physicalReady": false, "physicsFrame": -1, "cancelled": true}
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
	return {"physicalReady": restored, "physicsFrame": _restored_old_frame}


func _probe_clear(entry: Dictionary) -> bool:
	var query := PhysicsRayQueryParameters3D.create(entry.probeFrom, entry.probeTo,
		COLLISION_LAYER)
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _source_current(identity: Dictionary) -> bool:
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
	var current: Dictionary = _source.call("collision_source_snapshot")
	return current.get("status") == "ready" and current.get("identity") == identity \
		and current.get("sourceIdentity") == source_identity


func _candidate_source_current(identity: Dictionary, checked: Dictionary) -> bool:
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
