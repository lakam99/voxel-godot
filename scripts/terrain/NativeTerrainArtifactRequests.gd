extends RefCounted
class_name NativeTerrainArtifactRequests

## Inert source-bound request queue. Physical installation and retirement belong
## to the resident collision owner; this class only produces current rows.
const Producer = preload("res://scripts/terrain/NativeTerrainTriangleArtifactProducer.gd")
const WindowSource = preload("res://scripts/terrain/NativeTerrainCollisionWindowSource.gd")
const RetirementReceipt = preload("res://scripts/terrain/NativeCollisionRetirementReceipt.gd")
const MAX_RETIRED_WINDOWS := 64
const MAX_RETIRED_VERTEX_BYTES := 268435456
const MAX_VERIFIED_EDIT_REVISIONS := 256
const MAX_LOCAL_PROOF_USEC_PER_FRAME := 2000

var _backend
var _pages
var _admission
var _planner
var _cell_meters := 0.0
var _owner_generation := 0
var _max_resident_blocks := 0
var _cancellation_epoch := 0
var _producer
var _identity := {}
var _demand_revision := -1
var _closure_token := ""
var _requests := {}
var _active_block: Variant = null
var _draining := false
var _stop_issued := false
var _stopping := false
var _window_layout := {}
var _window_layout_job := {}
var _window_layout_candidate := {}
var _window_records := {}
var _active_window_tokens := {}
var _pending_retirement_tokens := {}
var _retirement_leases := {}
var _retirement_lease_sequence := 0
var _verified_edits := {}
var _last_verified_revision := -1
var _local_proof_cache := {}
var _proof_budget_frame := -1
var _proof_used_usec := 0
var _async_stop_requested := false

func setup(backend, pages, admission, planner, cell_meters: float,
		owner_generation: int, max_resident_blocks: int) -> Dictionary:
	if _backend != null or backend == null or pages == null or admission == null \
			or planner == null or not planner.has_method("diagnostics") \
			or cell_meters <= 0.0 or owner_generation <= 0 \
			or max_resident_blocks <= 0:
		return {"status":"failed", "reason":"artifact_request_owner_invalid"}
	_backend = backend
	_pages = pages
	_admission = admission
	_planner = planner
	_cell_meters = cell_meters
	_owner_generation = owner_generation
	_max_resident_blocks = max_resident_blocks
	_last_verified_revision = int(backend.status().get("terrainDeltaRevision", -1))
	return {"status":"ready"}

## Called only by NativeTerrainRuntimeOwner after native receipt/plan parity.
## Missing revisions leave old windows stale; this journal never edits terrain.
func observe_verified_durable_edit(receipt: Dictionary,
		plan: Dictionary) -> Dictionary:
	var affected_mesh_blocks: Array = plan.get("affectedMeshBlocks", [])
	if _stopping or _backend == null or affected_mesh_blocks.is_empty() \
			or plan.get("status") != "ready":
		return {"status":"failed", "reason":"verified_edit_owner_invalid"}
	var source: Dictionary = _backend.status()
	var revision := int(receipt.get("revision", -1))
	if receipt.get("status") != "ready" or receipt.get("commitStatus") != "committed" \
			or source.get("status") != "ready" \
			or revision != _last_verified_revision + 1 \
			or int(source.get("terrainDeltaRevision", -1)) != revision \
			or source.get("sourceIdentity") != _identity.get("sourceIdentity", source.get("sourceIdentity")) \
			or not receipt.get("affectedSections") is Array:
		return {"status":"failed", "reason":"verified_edit_revision_or_source_invalid"}
	var sections := {}
	for section in receipt.affectedSections:
		if not section is Vector3i:
			return {"status":"failed", "reason":"verified_edit_section_invalid"}
		if sections.has(section):
			return {"status":"failed", "reason":"verified_edit_section_duplicate"}
		sections[section] = true
	if sections.size() != affected_mesh_blocks.size():
		return {"status":"failed", "reason":"verified_edit_receipt_plan_mismatch"}
	var affected := {}
	for block in affected_mesh_blocks:
		if not block is Vector3i or not sections.has(block) or affected.has(block):
			return {"status":"failed", "reason":"verified_edit_receipt_plan_mismatch"}
		affected[block] = true
	if int(plan.get("barrier", {}).get("nativeRevision", -1)) != revision:
		return {"status":"failed", "reason":"verified_edit_plan_revision_mismatch"}
	_verified_edits[revision] = {"affectedMeshBlocks":affected,
		"shapingRevision":int(source.get("shapingRegistryRevision", -1)),
		"receiptDigest":("%d:%s:%s" % [revision,
			String(receipt.get("transactionId", "")),
			str(affected_mesh_blocks)]).sha256_text()}
	_last_verified_revision = revision
	if _verified_edits.size() > MAX_VERIFIED_EDIT_REVISIONS:
		_verified_edits.clear()
	return {"status":"ready", "verifiedThroughRevision":revision,
		"affectedMeshBlocks":affected.size()}

func request_block(block: Vector3i) -> Dictionary:
	if _stopping or _backend == null:
		return {"status":"failed", "reason":"artifact_requests_inactive"}
	var membership := {"status":"pending", "reason":"artifact_demand_snapshot_pending"}
	if _producer != null:
		membership = _producer.is_block_demanded(block)
		if membership.get("status") == "ready" and not membership.get("demanded", false):
			return {"status":"failed", "reason":"artifact_block_not_demanded"}
	for window: Dictionary in _window_layout.get("windows", []):
		if not (window.blocks as Array).has(block): continue
		var record: Dictionary = _window_records.get(window.windowToken, {})
		if record.get("identity") != _identity and record.get("rows", {}).has(block) \
				and _prove_local_window(record, _backend.status()).get("status") == "ready":
			return {"status":"ready", "reason":"locally_proven_artifact_retained",
				"block":block, "windowToken":window.windowToken}
	_requests[block] = true
	return {"status":"pending", "reason":"artifact_request_retained", "block":block,
		"demandPending":_producer == null or membership.get("status") != "ready"}

func advance() -> Dictionary:
	if _stopping or _backend == null:
		return {"status":"failed", "reason":"artifact_requests_inactive"}
	var demand: Dictionary = _demand_identity()
	var source: Dictionary = _backend.status()
	if demand.get("status") != "ready" or source.get("status") != "ready":
		return {"status":"pending", "reason":"artifact_source_or_demand_pending"}
	var source_identity: Dictionary = source.get("sourceIdentity", {})
	var source_changed: bool = _producer != null and (
			int(source.get("terrainDeltaRevision", -1)) != int(_identity.get("sourceRevision", -2))
			or source_identity != _identity.get("sourceIdentity", {}))
	if source_changed or _draining:
		var retired: Dictionary = _retire_producer()
		if retired.get("status") != "ready": return retired
	if _producer != null and (int(demand.get("revision", -1)) != _demand_revision
			or String(demand.get("closureToken", "")) != _closure_token):
		var rebound: Dictionary = _producer.rebind_demand()
		if rebound.get("status") != "ready": return rebound
		_demand_revision = int(demand.revision)
		_closure_token = String(demand.closureToken)
		_active_block = null
	if _producer == null:
		var created: Dictionary = _create_producer(source, demand)
		if created.get("status") != "ready": return created
	var demand_snapshot: Dictionary = _producer.advance_demand_snapshot()
	if demand_snapshot.get("status") != "ready": return demand_snapshot
	var layout_ready: Dictionary = _refresh_window_layout()
	if layout_ready.get("status") != "ready": return layout_ready
	var snapshot: Dictionary = _producer.collision_source_snapshot()
	for stale: Vector3i in snapshot.get("staleBlocks", []): _requests[stale] = true
	if _active_block != null:
		var result: Dictionary = _producer.advance()
		if result.get("status") == "ready":
			_cache_retained_row(result.row)
			_requests.erase(_active_block)
			_active_block = null
			return result
		if result.get("status") == "failed":
			_active_block = null
			_draining = true
			return {"status":"pending", "reason":"artifact_retry_retained",
				"sourceFailure":result.get("reason", "")}
		return result
	var blocks: Array[Vector3i] = []
	for block: Vector3i in _requests:
		var membership: Dictionary = _producer.is_block_demanded(block)
		if membership.get("status") == "ready" and membership.get("demanded", false):
			blocks.append(block)
		else: _requests.erase(block)
	blocks.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x))))
	if blocks.is_empty():
		return {"status":"pending", "reason":"artifact_queue_idle",
			"queuedBlocks":0,
			"sourceComplete":_producer.collision_source_snapshot().get("status") == "ready"}
	_active_block = blocks[0]
	var accepted: Dictionary = _producer.request_block(_active_block)
	if accepted.get("status") == "failed":
		_active_block = null
		_draining = true
		return {"status":"pending", "reason":"artifact_retry_retained"}
	return accepted

func collision_source_snapshot() -> Dictionary:
	if _planner != null:
		var demand: Dictionary = _demand_identity()
		if demand.get("status") == "ready" \
				and int(demand.get("requiredMeshBlocks", 0)) > _max_resident_blocks:
			return {"status":"pending", "reason":"partitioned_source_requires_window",
				"requiredBlocks":int(demand.get("requiredMeshBlocks", 0)),
				"windowLayout":collision_window_layout()}
		if _producer == null or demand.get("status") != "ready" \
				or int(demand.get("revision", -1)) != _demand_revision \
				or String(demand.get("closureToken", "")) != _closure_token:
			return {"status":"pending", "reason":"artifact_demand_snapshot_pending"}
	if _producer == null or _draining:
		return {"status":"pending", "reason":"artifact_producer_unavailable"}
	return _producer.collision_source_snapshot()

func collision_artifact_row(block: Vector3i, identity: Dictionary) -> Dictionary:
	if _producer == null or _draining:
		return {"status":"failed", "reason":"artifact_producer_unavailable"}
	return _producer.collision_artifact_row(block, identity)

func collision_artifact_row_snapshot(block: Vector3i, identity: Dictionary) -> Dictionary:
	if _producer == null or _draining:
		return {"status":"failed", "reason":"artifact_producer_unavailable"}
	return _producer.collision_artifact_row_snapshot(block, identity)

func collision_window_layout() -> Dictionary:
	if _stopping or _producer == null or _draining:
		return {"status":"pending", "reason":"artifact_producer_unavailable"}
	return _refresh_window_layout()

func collision_window_source(window_id: Vector3i, layout_token: String) -> Dictionary:
	var layout: Dictionary = collision_window_layout()
	if layout.get("status") != "ready" or layout.get("layoutToken") != layout_token:
		return {"status":"pending", "reason":"collision_window_layout_changed"}
	for window: Dictionary in layout.windows:
		if window.id != window_id: continue
		var token := String(window.windowToken)
		var record: Dictionary = _window_records.get(token, {})
		if record.is_empty(): break
		if record.get("facade") == null:
			var facade = WindowSource.new()
			var bound: Dictionary = facade.setup(self, token)
			if bound.get("status") != "ready": return bound
			record.facade = facade
			_window_records[token] = record
		return {"status":"ready", "source":record.facade,
			"windowToken":token, "blocks":window.blocks}
	return {"status":"failed", "reason":"collision_window_not_in_layout"}

func collision_window_source_snapshot(window_token: String) -> Dictionary:
	var record: Dictionary = _window_records.get(window_token, {})
	if record.is_empty(): return {"status":"failed", "reason":"collision_window_retired"}
	if _producer == null or _draining or not _active_window_tokens.has(window_token):
		return {"status":"pending", "reason":"collision_window_source_superseded",
			"retainedRows":(record.rows as Dictionary).size()}
	if record.identity != _identity:
		var current: Dictionary = _backend.status()
		if int(record.get("provenThroughRevision", -1)) != int(_identity.sourceRevision) \
				or _prove_local_window(record, current).get("status") != "ready":
			return {"status":"pending", "reason":"collision_window_local_proof_stale"}
		var retained_artifacts := {}
		for block: Vector3i in record.blocks:
			retained_artifacts[block] = (record.rows[block] as Dictionary).artifactKey
		return {"status":"ready", "reason":"",
			"identity":record.identity.duplicate(true),
			"sourceIdentity":record.sourceIdentity.duplicate(true),
			"sourceEpoch":record.identity.sourceEpoch,
			"nativeRevision":int(record.identity.sourceRevision),
			"ownerGeneration":int(record.identity.ownerGeneration),
			"cancellationEpoch":int(record.identity.cancellationEpoch),
			"requiredResidentBlocks":(record.blocks as Array).duplicate(),
			"residentBlocks":(record.blocks as Array).duplicate(),
			"artifacts":retained_artifacts,
			"membershipProvenance":record.membershipProvenance.duplicate(true),
			"localCurrentProof":{"kind":"verified_native_affected_mesh_exclusion/v1",
				"throughGlobalRevision":int(_identity.sourceRevision),
				"digest":String(record.proofDigest)}}
	var source: Dictionary = _producer.collision_source_snapshot()
	if not source.has("identity") or source.get("identity") != record.identity:
		return {"status":"pending", "reason":"collision_window_source_changed"}
	var required: Array[Vector3i] = []
	for block: Vector3i in record.blocks: required.append(block)
	var produced: Array[Vector3i] = []
	var artifacts := {}
	var stale_set := {}
	for block: Vector3i in source.get("staleBlocks", []): stale_set[block] = true
	for block: Vector3i in required:
		if (source.get("artifacts", {}) as Dictionary).has(block) and not stale_set.has(block):
			produced.append(block)
			artifacts[block] = source.artifacts[block]
	var complete := produced.size() == required.size()
	return {"status":"ready" if complete else "pending",
		"reason":"" if complete else "collision_window_artifacts_incomplete",
		"identity":record.identity.duplicate(true),
		"sourceIdentity":source.sourceIdentity,
		"sourceEpoch":source.sourceEpoch,
		"nativeRevision":source.nativeRevision,
		"ownerGeneration":source.ownerGeneration,
		"cancellationEpoch":source.cancellationEpoch,
		"requiredResidentBlocks":required.duplicate(),
		"residentBlocks":produced, "artifacts":artifacts,
		"membershipProvenance":record.membershipProvenance.duplicate(true),
		"localCurrentProof":{"kind":"native_current_revision",
			"throughGlobalRevision":int(_identity.sourceRevision),
			"digest":String(record.proofDigest)}}

func collision_window_artifact_row(window_token: String, block: Vector3i,
		identity: Dictionary) -> Dictionary:
	var record: Dictionary = _window_records.get(window_token, {})
	if record.is_empty() or not (record.blocks as Array).has(block):
		return {"status":"failed", "reason":"collision_window_block_invalid"}
	if _producer == null or _draining or not _active_window_tokens.has(window_token) \
			or identity != record.identity:
		return {"status":"pending", "reason":"collision_window_source_superseded",
			"retainedRow":(record.rows as Dictionary).get(block, {}).duplicate(true)}
	if record.identity != _identity:
		var current: Dictionary = _backend.status()
		if int(record.get("provenThroughRevision", -1)) != int(_identity.sourceRevision) \
				or _prove_local_window(record, current).get("status") != "ready":
			return {"status":"pending", "reason":"collision_window_local_proof_stale"}
		return {"status":"ready", "row":(record.rows[block] as Dictionary).duplicate(true)}
	return _producer.collision_artifact_row(block, identity)

func collision_window_artifact_row_snapshot(window_token: String, block: Vector3i,
		identity: Dictionary) -> Dictionary:
	var record: Dictionary = _window_records.get(window_token, {})
	if record.is_empty() or not (record.blocks as Array).has(block):
		return {"status":"failed", "reason":"collision_window_block_invalid"}
	if _producer == null or _draining or not _active_window_tokens.has(window_token) \
			or identity != record.identity:
		return {"status":"pending", "reason":"collision_window_source_superseded",
			"retainedRow":(record.rows as Dictionary).get(block, {}).duplicate(false)}
	if record.identity != _identity:
		var current: Dictionary = _backend.status()
		if int(record.get("provenThroughRevision", -1)) != int(_identity.sourceRevision) \
				or _prove_local_window(record, current).get("status") != "ready":
			return {"status":"pending", "reason":"collision_window_local_proof_stale"}
		return {"status":"ready", "row":(record.rows[block] as Dictionary).duplicate(false)}
	return _producer.collision_artifact_row_snapshot(block, identity)

func acknowledge_collision_window_retired(window_token: String,
		retirement_receipt: Dictionary) -> Dictionary:
	var record: Dictionary = _window_records.get(window_token, {})
	var lease: Dictionary = _retirement_leases.get(window_token, {})
	if record.is_empty() or (_active_window_tokens.has(window_token) \
			and not _pending_retirement_tokens.has(window_token)) \
			or lease.is_empty() \
			or not RetirementReceipt.matches_record(window_token,
				retirement_receipt, record, lease):
		return {"status":"failed", "reason":"collision_window_retirement_not_proven"}
	var facade = record.get("facade")
	if facade != null: facade.detach()
	_window_records.erase(window_token)
	_active_window_tokens.erase(window_token)
	_pending_retirement_tokens.erase(window_token)
	_retirement_leases.erase(window_token)
	return {"status":"ready", "retiredWindowToken":window_token}

func claim_collision_window_retirement(window_token: String,
		expected_layout_token: String, physical_owner_epoch: String) -> Dictionary:
	if _stopping or _backend == null or not _window_records.has(window_token):
		return {"status":"failed", "reason":"collision_window_retirement_claim_invalid"}
	if physical_owner_epoch.is_empty():
		return {"status":"failed", "reason":"collision_window_owner_epoch_missing"}
	var existing: Dictionary = _retirement_leases.get(window_token, {})
	if not existing.is_empty():
		var retained: Dictionary = _window_records.get(window_token, {})
		if existing.get("expectedLayoutToken") == expected_layout_token \
				and existing.get("physicalOwnerEpoch") == physical_owner_epoch \
			and RetirementReceipt.lease_matches_record(window_token, retained, existing):
			return {"status":"ready", "leaseId":existing.leaseId,
				"windowToken":window_token,
				"physicalOwnerEpoch":physical_owner_epoch}
		if not RetirementReceipt.lease_matches_record(window_token, retained, existing):
			return {"status":"failed", "reason":"collision_window_retirement_record_stale"}
		return {"status":"pending", "reason":"collision_window_retirement_leased"}
	var layout: Dictionary = collision_window_layout()
	var telemetry: Dictionary = layout.get("retirementTelemetry", {})
	var retired_tokens: Array = layout.get("retiredWindowTokens",
		telemetry.get("retiredWindowTokens", []))
	if layout.get("layoutToken") != expected_layout_token \
			or not retired_tokens.has(window_token):
		return {"status":"pending", "reason":"collision_window_retirement_not_requested",
			"layoutStatus":layout.get("status", "")}
	_retirement_lease_sequence += 1
	var lease_id := ("%d:%d:%s:%s" % [_owner_generation,
		_retirement_lease_sequence, window_token, expected_layout_token]).sha256_text()
	var record: Dictionary = _window_records[window_token]
	record["physicalOwnerEpoch"] = physical_owner_epoch
	_window_records[window_token] = record
	_retirement_leases[window_token] = {"leaseId":lease_id,
		"windowToken":window_token,
		"expectedLayoutToken":expected_layout_token,
		"physicalOwnerEpoch":physical_owner_epoch,
		"recordIdentity":record.identity.duplicate(true),
		"sourceIdentity":record.sourceIdentity.duplicate(true),
		"membershipProvenance":record.membershipProvenance.duplicate(true),
		"residentBlocks":(record.blocks as Array).duplicate()}
	return {"status":"ready", "leaseId":lease_id, "windowToken":window_token,
		"physicalOwnerEpoch":physical_owner_epoch}

func validate_collision_window_retirement(window_token: String,
		lease_id: String, physical_owner_epoch: String) -> Dictionary:
	var lease: Dictionary = _retirement_leases.get(window_token, {})
	if lease.is_empty() or lease.get("leaseId") != lease_id \
			or lease.get("physicalOwnerEpoch") != physical_owner_epoch:
		return {"status":"failed", "reason":"collision_window_retirement_lease_stale"}
	var record: Dictionary = _window_records.get(window_token, {})
	if record.is_empty() or not RetirementReceipt.lease_matches_record(
		window_token, record, lease):
		return {"status":"failed", "reason":"collision_window_retirement_record_stale"}
	if _active_window_tokens.has(window_token):
		return {"status":"failed", "reason":"leased_collision_window_reactivated"}
	return {"status":"ready", "windowToken":window_token, "leaseId":lease_id,
		"physicalOwnerEpoch":physical_owner_epoch}

## A lease can be cancelled only before physical drain starts or when the
## owner proves its collision bodies remain installed and unchanged.
func abort_collision_window_retirement(window_token: String, lease_id: String,
		owner_unchanged: bool) -> Dictionary:
	var lease: Dictionary = _retirement_leases.get(window_token, {})
	if not owner_unchanged or lease.is_empty() or lease.get("leaseId") != lease_id:
		return {"status":"failed", "reason":"collision_window_retirement_abort_unproven"}
	_retirement_leases.erase(window_token)
	return {"status":"ready", "windowToken":window_token}

func stop() -> Dictionary:
	_stopping = true
	var planner_transaction: Dictionary = _planner.collision_mesh_snapshot_transaction_state() \
		if _planner != null else {"status":"idle", "hasPendingRetirement":false}
	var staged_transaction_pending: bool = planner_transaction.get("status") == "active" \
		or bool(planner_transaction.get("hasPendingRetirement", false))
	if not _window_layout_job.is_empty() or staged_transaction_pending:
		return request_stop()
	_window_layout_candidate.clear()
	var retired: Dictionary = _retire_producer()
	if retired.get("status") == "ready": _release_windows()
	return retired

## Cheap stop request. Producer cancellation, worker acknowledgement and
## window-source release are deliberately advanced by drain_step(), one unit at
## a time, so the composed owner does not hide an unbounded stop loop.
func request_stop() -> Dictionary:
	_stopping = true
	_async_stop_requested = true
	if not _window_layout_job.is_empty() \
			and not bool(_window_layout_job.get("cancelling", false)):
		var job: Dictionary = _window_layout_job
		var owner: Dictionary = _planner.collision_mesh_snapshot_transaction_state()
		if String(owner.get("kind", "")) == "layout" \
				and int(owner.get("token", 0)) == int(job.get("token", 0)):
			if String(owner.get("status", "")) == "active":
				_planner.cancel_collision_mesh_window_layout(int(job.get("token", 0)))
			job["cancelling"] = true
			_window_layout_job = job
	return {"status":"pending", "reason":"artifact_retirement_requested",
		"inflight":_producer != null, "windowRecords":_window_records.size()}

func drain_step() -> Dictionary:
	if not _async_stop_requested: return {"status":"failed", "reason":"artifact_stop_required"}
	var retired: Dictionary = _retire_producer()
	if retired.get("status") != "ready": return retired
	var layout_drain: Dictionary = _drain_staged_window_layout()
	if layout_drain.get("status") != "ready": return layout_drain
	var window_step := _release_one_window()
	if window_step.get("status") != "ready": return window_step
	if not _retirement_leases.is_empty():
		return {"status":"pending", "reason":"artifact_retirement_leases_active",
			"remainingLeases":_retirement_leases.size()}
	if not _window_records.is_empty() or not _active_window_tokens.is_empty():
		return {"status":"pending", "reason":"artifact_window_retirement_pending"}
	return {"status":"ready", "drained":true, "nativeWorkersDrained":true,
		"windowSourcesReleased":true, "leasesReleased":_retirement_leases.is_empty()}

func _drain_staged_window_layout() -> Dictionary:
	if _planner == null:
		_window_layout_job.clear()
		_window_layout_candidate.clear()
		return {"status":"ready", "drained":true}
	var owner: Dictionary = _planner.collision_mesh_snapshot_transaction_state()
	if _window_layout_job.is_empty():
		var owner_released: bool = owner.get("status") == "idle" \
			or (owner.get("status") == "transferred" \
				and not bool(owner.get("hasPendingRetirement", false)))
		if not owner_released or bool(owner.get("hasPendingRetirement", false)):
			return {"status":"pending", "reason":"artifact_layout_foreign_transaction_drain",
				"transaction":owner}
		_window_layout_candidate.clear()
		return {"status":"ready", "drained":true}
	var job: Dictionary = _window_layout_job
	var token := int(job.get("token", 0))
	var owner_matches := String(owner.get("kind", "")) == "layout" \
		and int(owner.get("token", 0)) == token
	if not owner_matches:
		_window_layout_job.clear()
		var owner_released: bool = owner.get("status") == "idle" \
			or (owner.get("status") == "transferred" \
				and not bool(owner.get("hasPendingRetirement", false)))
		if owner_released and not bool(owner.get("hasPendingRetirement", false)):
			_window_layout_candidate.clear()
			return {"status":"ready", "drained":true,
				"orphanReleased":true, "transaction":owner}
		return {"status":"pending", "reason":"artifact_layout_orphan_waiting",
			"transaction":owner}
	if not bool(job.get("cancelling", false)):
		if String(owner.get("status", "")) == "active":
			_planner.cancel_collision_mesh_window_layout(token)
		job["cancelling"] = true
		_window_layout_job = job
	var drain_step: Dictionary = {}
	if owner_matches:
		drain_step = _planner.advance_collision_mesh_window_layout(token)
		if not _valid_layout_step_budget(drain_step):
			return {"status":"failed", "reason":"mesh_layout_work_bound_violated",
				"step":drain_step}
		if not _window_layout_job.is_empty() and (drain_step.get("status") == "ready" \
				or drain_step.get("status") == "failed" or drain_step.get("status") == "idle"):
			_window_layout_job.clear()
		if not _window_layout_job.is_empty() \
				or bool(_planner.collision_mesh_snapshot_transaction_state().get(
					"hasPendingRetirement", false)):
			return {"status":"pending", "reason":"artifact_layout_drain_pending",
				"workOps":int(drain_step.get("workOps", 0)),
				"maxWorkOps":int(drain_step.get("maxWorkOps", 0))}
	_window_layout_candidate.clear()
	return {"status":"ready", "drained":true}

func snapshot() -> Dictionary:
	return {"stopping":_stopping, "producerActive":_producer != null,
		"activeBlock":_active_block, "windowRecords":_window_records.size(),
		"activeWindows":_active_window_tokens.size(),
		"retirementLeases":_retirement_leases.size(),
		"pendingRetirementTokens":_pending_retirement_tokens.size()}

func _release_one_window() -> Dictionary:
	var token_to_release := ""
	for token in _window_records:
		if _retirement_leases.has(token):
			return {"status":"pending", "reason":"artifact_window_lease_active",
				"windowToken":token}
		token_to_release = String(token)
		break
	if not token_to_release.is_empty():
		var record: Dictionary = _window_records[token_to_release]
		var facade = record.get("facade")
		if facade != null: facade.detach()
		_window_records.erase(token_to_release)
		_active_window_tokens.erase(token_to_release)
		_pending_retirement_tokens.erase(token_to_release)
		return {"status":"pending", "reason":"artifact_window_source_released",
			"windowToken":token_to_release, "remaining":_window_records.size()}
	if not _pending_retirement_tokens.is_empty():
		return {"status":"pending", "reason":"artifact_retirement_tokens_active",
			"remaining":_pending_retirement_tokens.size()}
	return {"status":"ready", "released":true}

func _create_producer(source: Dictionary, demand: Dictionary) -> Dictionary:
	if int(demand.get("revision", 0)) <= 0 or String(demand.get("closureToken", "")).is_empty():
		return {"status":"pending", "reason":"artifact_demand_unset"}
	_cancellation_epoch += 1
	var source_identity: Dictionary = source.get("sourceIdentity", {})
	_identity = {"ownerGeneration":_owner_generation,
		"sourceRevision":int(source.get("terrainDeltaRevision", -1)),
		"sourceEpoch":"%d:%s" % [_owner_generation, String(source_identity.get("hex", ""))],
		"cancellationEpoch":_cancellation_epoch,
		"sourceIdentity":source_identity.duplicate(true)}
	_demand_revision = int(demand.revision)
	_closure_token = String(demand.closureToken)
	_producer = Producer.new()
	var ready: Dictionary = _producer.setup(_backend, _pages, _admission, _planner,
		_cell_meters, _identity)
	if ready.get("status") != "ready":
		_producer = null
		return ready
	return {"status":"ready", "identity":_identity.duplicate(true)}

func _demand_identity() -> Dictionary:
	if _planner == null: return {"status":"pending", "reason":"artifact_demand_unavailable"}
	var snapshot: Dictionary = _planner.diagnostics()
	var revision := int(snapshot.get("demandRevision", -1))
	var closure_token := String(snapshot.get("closureToken", ""))
	if revision <= 0 or closure_token.is_empty():
		return {"status":"pending", "reason":"artifact_demand_unavailable"}
	return {"status":"ready", "revision":revision,
		"closureToken":closure_token,
		"requiredMeshBlocks":int(snapshot.get("requiredMeshBlocks", 0))}

func _refresh_window_layout() -> Dictionary:
	# Once old physical owners exceed the retention budget, no subsequent
	# demand revision may allocate another window record before N5 drains one.
	if not _window_layout.is_empty():
		var held: Dictionary = _retention_status()
		if held.get("status") != "ready": return held
	var layout_result: Dictionary = _advance_staged_window_layout()
	if layout_result.get("status") != "ready": return layout_result
	var planned: Dictionary = layout_result.get("layout", {})
	if planned.get("status") != "ready":
		return {"status":"failed", "reason":"mesh_layout_result_invalid"}
	var layout_token := ("%s:%s:%d:%d" % [String(planned.logicalClosureToken),
		String(_identity.sourceIdentity.get("hex", "")),
		int(_identity.sourceRevision), int(_identity.cancellationEpoch)]).sha256_text()
	if _window_layout.get("layoutToken") == layout_token:
		_pending_retirement_tokens.clear()
		return _retention_status()
	var windows: Array[Dictionary] = []
	var active := {}
	var new_records := {}
	var proven_records := {}
	var current_source: Dictionary = _backend.status()
	var frame := Engine.get_process_frames()
	if frame != _proof_budget_frame:
		_proof_budget_frame = frame
		_proof_used_usec = 0
	for index in range((planned.windows as Array).size()):
		var window: Dictionary = planned.windows[index]
		if (window.blocks as Array).size() > _max_resident_blocks:
			_window_layout_candidate.clear()
			return {"status":"failed", "reason":"collision_window_exceeds_owner_cap"}
		var token := ("%s:%s:%d:%d" % [String(window.closureToken),
			String(_identity.sourceIdentity.get("hex", "")),
			int(_identity.sourceRevision), int(_identity.cancellationEpoch)]).sha256_text()
		var proof := {"status":"new"}
		for old_token in _window_records:
			var candidate: Dictionary = _window_records[old_token]
			if candidate.get("membershipProvenance", {}).get("closureToken") \
					!= window.closureToken or candidate.get("blocks") != window.blocks:
				continue
			var cache_key := "%s:%d:%d" % [String(old_token),
				int(current_source.get("terrainDeltaRevision", -1)),
				int(current_source.get("shapingRegistryRevision", -1))]
			var checked: Dictionary = _local_proof_cache.get(cache_key, {})
			if checked.is_empty():
				if _proof_used_usec >= MAX_LOCAL_PROOF_USEC_PER_FRAME:
					return {"status":"pending", "reason":"collision_window_local_proof_budget",
						"verifiedWindows":proven_records.size(),
						"proofUsecThisFrame":_proof_used_usec,
						"maxProofUsecPerFrame":MAX_LOCAL_PROOF_USEC_PER_FRAME}
				var proof_started := Time.get_ticks_usec()
				checked = _prove_local_window(candidate, current_source)
				_proof_used_usec += Time.get_ticks_usec() - proof_started
				if checked.get("status") == "ready":
					_local_proof_cache[cache_key] = checked.duplicate(true)
			if checked.get("status") != "ready": continue
			token = String(old_token)
			proof = checked
			var retained: Dictionary = candidate.duplicate(true)
			retained.provenThroughRevision = int(_identity.sourceRevision)
			retained.proofDigest = String(checked.digest)
			proven_records[token] = retained
			break
		active[token] = true
		var new_proof_digest := ("%s:%s:%d" % [String(window.closureToken),
			String(_identity.sourceIdentity.get("hex", "")),
			int(_identity.sourceRevision)]).sha256_text()
		var member := {"id":window.id, "blocks":window.blocks,
			"closureToken":window.closureToken, "windowToken":token,
			"windowIndex":index,
			"identity":proven_records[token].identity.duplicate(true) if proven_records.has(token)
				else _identity.duplicate(true),
			"localCurrentProof":{"kind":"verified_native_affected_mesh_exclusion/v1"
					if proven_records.has(token) else "native_current_revision",
				"throughGlobalRevision":int(_identity.sourceRevision),
				"digest":String(proof.get("digest", new_proof_digest))}}
		windows.append(member)
		if not _window_records.has(token):
			new_records[token] = {"layoutToken":layout_token,
				"identity":_identity.duplicate(true), "blocks":window.blocks,
				"rows":{}, "facade":null,
				"sourceIdentity":_identity.sourceIdentity.duplicate(true),
				"shapingRevision":int(current_source.get("shapingRegistryRevision", -1)),
				"provenThroughRevision":int(_identity.sourceRevision),
				"proofDigest":new_proof_digest,
				"membershipProvenance":{"authority":"pinned_demand",
					"demandRevision":0,
					"closureToken":String(window.closureToken),
					"windowToken":token}}
	for leased_token in _retirement_leases:
		if active.has(leased_token):
			return {"status":"pending", "reason":"collision_window_retirement_leased",
				"retiredWindowTokens":[leased_token],
				"layoutToken":_window_layout.get("layoutToken", "")}
	var projected: Dictionary = _retention_status(active)
	if projected.get("status") != "ready":
		_pending_retirement_tokens.clear()
		for token in projected.retiredWindowTokens:
			_pending_retirement_tokens[token] = true
		return projected
	for token in new_records: _window_records[token] = new_records[token]
	for token in proven_records: _window_records[token] = proven_records[token]
	_active_window_tokens = active
	_pending_retirement_tokens.clear()
	_window_layout = planned.duplicate(true)
	_window_layout["layoutToken"] = layout_token
	_window_layout["sourceIdentity"] = _identity.sourceIdentity.duplicate(true)
	_window_layout["identity"] = _identity.duplicate(true)
	_window_layout["windows"] = windows
	_window_layout_candidate.clear()
	_local_proof_cache.clear()
	return _retention_status()

## Production consumers must never synchronously enumerate/sort the complete
## demanded mesh set. Keep the planner lease and exact source identity with the
## staged transaction until it publishes or its bounded cancellation drain ends.
func _advance_staged_window_layout() -> Dictionary:
	var demand: Dictionary = _demand_identity()
	if demand.get("status") != "ready": return demand
	var source: Dictionary = _backend.status()
	if source.get("status") != "ready":
		return {"status":"pending", "reason":"artifact_layout_source_pending"}
	var source_identity: Dictionary = source.get("sourceIdentity", {})
	var identity_matches: bool = _identity.get("sourceIdentity", {}) == source_identity \
		and int(_identity.get("sourceRevision", -1)) \
			== int(source.get("terrainDeltaRevision", -2))
	var expected_layout_token := ("%s:%s:%d:%d" % [String(demand.closureToken),
		String(_identity.get("sourceIdentity", {}).get("hex", "")),
		int(_identity.get("sourceRevision", -1)),
		int(_identity.get("cancellationEpoch", -1))]).sha256_text()
	if not _window_layout_candidate.is_empty():
		var candidate_current: bool = _identity == _window_layout_candidate.get("ownerIdentity", {}) \
			and int(demand.get("revision", -1)) \
				== int(_window_layout_candidate.get("demandRevision", -2)) \
			and String(demand.get("closureToken", "")) \
				== String(_window_layout_candidate.get("closureToken", "")) \
			and source_identity == _window_layout_candidate.get("sourceIdentity", {}) \
			and int(source.get("terrainDeltaRevision", -1)) \
				== int(_window_layout_candidate.get("sourceRevision", -2))
		if candidate_current:
			return {"status":"ready", "layout":_window_layout_candidate.layout}
		_window_layout_candidate.clear()
	if _window_layout_job.is_empty() and identity_matches \
			and _window_layout.get("layoutToken", "") == expected_layout_token:
		return {"status":"ready", "layout":_window_layout}
	if not _window_layout_job.is_empty():
		var job: Dictionary = _window_layout_job
		var current: bool = identity_matches \
			and _identity == job.get("ownerIdentity", {}) \
			and int(demand.get("revision", -1)) == int(job.get("demandRevision", -2)) \
			and String(demand.get("closureToken", "")) == String(job.get("closureToken", "")) \
			and source_identity == job.get("sourceIdentity", {}) \
			and int(source.get("terrainDeltaRevision", -1)) == int(job.get("sourceRevision", -2)) \
			and int(_identity.get("cancellationEpoch", -1)) == int(job.get("cancellationEpoch", -2))
		var token := int(job.get("token", 0))
		var owner: Dictionary = _planner.collision_mesh_snapshot_transaction_state()
		var owner_matches := String(owner.get("kind", "")) == "layout" \
			and int(owner.get("token", 0)) == token
		if not current and not bool(job.get("cancelling", false)):
			if not owner_matches:
				# The shared builder is idle or belongs to somebody else. This
				# broker token can no longer be cancelled/drained safely.
				_window_layout_job.clear()
				return {"status":"pending", "reason":"mesh_layout_orphan_released",
					"transaction":owner}
			if String(owner.get("status", "")) == "active":
				var cancelled: Dictionary = _planner.cancel_collision_mesh_window_layout(token)
				job["cancelReason"] = String(cancelled.get("reason", "source_or_demand_stale"))
			job.cancelling = true
			_window_layout_job = job
		if bool(job.get("cancelling", false)):
			owner = _planner.collision_mesh_snapshot_transaction_state()
			owner_matches = String(owner.get("kind", "")) == "layout" \
				and int(owner.get("token", 0)) == token
			if not owner_matches:
				_window_layout_job.clear()
				return {"status":"pending", "reason":"mesh_layout_orphan_released",
					"transaction":owner}
			# Cancellation may reach a transferred result; only this exact token
			# may advance and drain that transaction's retained scratch.
			var drained: Dictionary = _planner.advance_collision_mesh_window_layout(token)
			if not _valid_layout_step_budget(drained):
				return {"status":"failed", "reason":"mesh_layout_work_bound_violated",
					"step":drained}
			if drained.get("status") == "ready" or drained.get("status") == "failed" \
					or drained.get("status") == "idle":
				_window_layout_job.clear()
			return {"status":"pending", "reason":"mesh_layout_stale_drain",
				"workOps":int(drained.get("workOps", 0)),
				"maxWorkOps":int(drained.get("maxWorkOps", 0))}
		owner = _planner.collision_mesh_snapshot_transaction_state()
		owner_matches = String(owner.get("kind", "")) == "layout" \
			and int(owner.get("token", 0)) == token
		if not owner_matches:
			# A result can only be consumed from the matching transaction. If
			# its token disappeared, the broker missed ownership and must retry.
			_window_layout_job.clear()
			return {"status":"pending", "reason":"mesh_layout_orphan_released",
				"transaction":owner}
		if job.has("completed"):
			if bool(owner.get("hasPendingRetirement", false)):
				var retirement_step: Dictionary = _planner.advance_collision_mesh_window_layout(token)
				if not _valid_layout_step_budget(retirement_step):
					return {"status":"failed", "reason":"mesh_layout_work_bound_violated",
						"step":retirement_step}
				if _planner.has_pending_collision_mesh_window_retirement():
					return {"status":"pending", "reason":"mesh_layout_published_scratch_drain",
						"workOps":int(retirement_step.get("workOps", 0)),
						"maxWorkOps":int(retirement_step.get("maxWorkOps", 0)),
						"token":int(job.token)}
			var completed_step: Dictionary = job.completed
			var completed_job: Dictionary = job.duplicate(true)
			_window_layout_job.clear()
			return _consume_staged_layout_result(completed_step, completed_job)
		if String(owner.get("status", "")) != "active":
			# The token is still recognizable but its result was transferred by a
			# different caller. Drain only its own scratch; never adopt that result.
			if String(owner.get("status", "")) == "transferred" \
					and bool(owner.get("hasPendingRetirement", false)):
				var orphan_drain: Dictionary = _planner.advance_collision_mesh_window_layout(token)
				if not _valid_layout_step_budget(orphan_drain):
					return {"status":"failed", "reason":"mesh_layout_work_bound_violated",
						"step":orphan_drain}
				if bool(_planner.collision_mesh_snapshot_transaction_state().get(
						"hasPendingRetirement", false)):
					return {"status":"pending", "reason":"mesh_layout_orphan_scratch_drain",
						"workOps":int(orphan_drain.get("workOps", 0)),
						"maxWorkOps":int(orphan_drain.get("maxWorkOps", 0))}
			_window_layout_job.clear()
			return {"status":"pending", "reason":"mesh_layout_orphan_released",
				"transaction":_planner.collision_mesh_snapshot_transaction_state()}
		var advanced: Dictionary = _planner.advance_collision_mesh_window_layout(token)
		if not _valid_layout_step_budget(advanced):
			return {"status":"failed", "reason":"mesh_layout_work_bound_violated",
				"step":advanced}
		if advanced.get("status") == "failed":
			_window_layout_job.clear()
			return advanced
		if advanced.get("status") != "ready":
			return {"status":"pending", "reason":"mesh_layout_work_pending",
				"workOps":int(advanced.get("workOps", 0)),
				"maxWorkOps":int(advanced.get("maxWorkOps", 0)),
				"token":int(job.token)}
		job["completed"] = advanced
		_window_layout_job = job
		return {"status":"pending", "reason":"mesh_layout_published_scratch_drain",
			"workOps":int(advanced.get("workOps", 0)),
			"maxWorkOps":int(advanced.get("maxWorkOps", 0)),
			"token":int(job.token)}
	var started: Dictionary = _planner.begin_collision_mesh_window_layout()
	if started.get("status") != "pending": return started
	if String(started.get("reason", "")) != "mesh_layout_started" \
			or String(started.get("transactionKind", "")) != "layout" \
			or String(started.get("transactionStatus", "")) != "active":
		return {"status":"pending", "reason":"mesh_layout_transaction_busy",
			"transaction":started.get("transaction", {})}
	var token := int(started.get("token", 0))
	if token <= 0:
		return {"status":"failed", "reason":"mesh_layout_token_missing"}
	var started_owner: Dictionary = _planner.collision_mesh_snapshot_transaction_state()
	if String(started_owner.get("kind", "")) != "layout" \
			or int(started_owner.get("token", 0)) != token \
			or String(started_owner.get("status", "")) != "active":
		return {"status":"pending", "reason":"mesh_layout_begin_not_owned",
			"transaction":started_owner}
	_window_layout_job = {"token":token,
		"demandRevision":int(demand.revision),
		"closureToken":String(demand.closureToken),
		"sourceIdentity":source_identity.duplicate(true),
		"sourceRevision":int(source.get("terrainDeltaRevision", -1)),
		"cancellationEpoch":int(_identity.get("cancellationEpoch", -1)),
		"ownerIdentity":_identity.duplicate(true), "cancelling":false}
	var first_step: Dictionary = _planner.advance_collision_mesh_window_layout(token)
	if not _valid_layout_step_budget(first_step):
		return {"status":"failed", "reason":"mesh_layout_work_bound_violated",
			"step":first_step}
	if first_step.get("status") == "failed":
		_window_layout_job.clear()
		return first_step
	if first_step.get("status") == "ready":
		# Consume through the same identity validation on the next frame/call.
		_window_layout_job["completed"] = first_step
	return {"status":"pending", "reason":"mesh_layout_work_pending",
		"workOps":int(first_step.get("workOps", 0)),
		"maxWorkOps":int(first_step.get("maxWorkOps", 0)), "token":token}

func _consume_staged_layout_result(result: Dictionary, job: Dictionary) -> Dictionary:
	var completed: Dictionary = result.get("layout", {})
	var valid_result := int(result.get("token", -1)) == int(job.token) \
		and int(result.get("revision", -1)) == int(job.demandRevision) \
		and String(result.get("closureToken", "")) == String(job.closureToken) \
		and int(completed.get("logicalDemandRevision", -1)) == int(job.demandRevision) \
		and String(completed.get("logicalClosureToken", "")) == String(job.closureToken)
	if not valid_result:
		return {"status":"pending", "reason":"mesh_layout_result_identity_stale"}
	_window_layout_candidate = {"layout":completed.duplicate(true),
		"demandRevision":int(job.demandRevision),
		"closureToken":String(job.closureToken),
		"sourceIdentity":job.get("sourceIdentity", {}).duplicate(true),
		"sourceRevision":int(job.get("sourceRevision", -1)),
		"cancellationEpoch":int(job.get("cancellationEpoch", -1)),
		"ownerIdentity":job.get("ownerIdentity", {}).duplicate(true)}
	return {"status":"ready", "layout":completed}

func _valid_layout_step_budget(step: Dictionary) -> bool:
	var operations := int(step.get("workOps", -1))
	var maximum := int(step.get("maxWorkOps", -1))
	return operations >= 0 and maximum > 0 and operations <= maximum \
		and maximum <= 256

func _cache_retained_row(row: Dictionary) -> void:
	for window: Dictionary in _window_layout.get("windows", []):
		if not (window.blocks as Array).has(row.block): continue
		var token := String(window.windowToken)
		var record: Dictionary = _window_records[token]
		(record.rows as Dictionary)[row.block] = row.duplicate(true)
		_window_records[token] = record
		return

func _prove_local_window(record: Dictionary, current_source: Dictionary) -> Dictionary:
	if current_source.get("status") != "ready" \
			or current_source.get("sourceIdentity") != record.get("sourceIdentity") \
			or int(current_source.get("shapingRegistryRevision", -1)) \
			!= int(record.get("shapingRevision", -2)) \
			or (record.get("rows", {}) as Dictionary).size() != (record.blocks as Array).size():
		return {"status":"pending", "reason":"local_source_unproven"}
	var current_revision := int(current_source.get("terrainDeltaRevision", -1))
	var proven_revision := int(record.get("provenThroughRevision", -1))
	if current_revision < proven_revision: return {"status":"failed", "reason":"revision_reversed"}
	var digest := String(record.get("proofDigest", ""))
	for revision in range(proven_revision + 1, current_revision + 1):
		var edit: Dictionary = _verified_edits.get(revision, {})
		if edit.is_empty() or int(edit.get("shapingRevision", -1)) \
				!= int(record.shapingRevision):
			return {"status":"pending", "reason":"edit_revision_proof_missing"}
		for block: Vector3i in record.blocks:
			if (edit.affectedMeshBlocks as Dictionary).has(block):
				return {"status":"pending", "reason":"local_mesh_affected"}
		digest = ("%s:%s" % [digest, String(edit.receiptDigest)]).sha256_text()
	if current_revision > proven_revision and not _local_page_pins_match(record, current_source):
		return {"status":"pending", "reason":"local_page_pin_changed_or_unavailable"}
	return {"status":"ready", "digest":digest,
		"throughGlobalRevision":current_revision}

func _local_page_pins_match(record: Dictionary, current_source: Dictionary) -> bool:
	var expected := {}
	for block in record.rows:
		var row: Dictionary = record.rows[block]
		var pins: Dictionary = row.get("localPagePins", {})
		if pins.is_empty(): return false
		for page in pins:
			if expected.has(page) and expected[page] != pins[page]: return false
			expected[page] = pins[page]
	for page in expected:
		var current: Dictionary = _backend.pin_effective_page(page)
		var receipt: Dictionary = current.get("pageStatus", {})
		if current.get("status") != "ready" or receipt.get("status") != "ready" \
				or receipt.get("pinIdentity") != expected[page] \
				or receipt.get("sourceIdentity") != record.sourceIdentity \
				or int(receipt.get("terrainDeltaRevision", -1)) \
				!= int(current_source.get("terrainDeltaRevision", -2)):
			return false
	var after: Dictionary = _backend.status()
	return after.get("status") == "ready" \
		and after.get("sourceIdentity") == record.sourceIdentity \
		and int(after.get("terrainDeltaRevision", -1)) \
			== int(current_source.get("terrainDeltaRevision", -2)) \
		and int(after.get("shapingRegistryRevision", -1)) \
			== int(current_source.get("shapingRegistryRevision", -2))

func _retire_producer() -> Dictionary:
	if _producer == null:
		_draining = false
		_stop_issued = false
		_active_block = null
		return {"status":"ready", "drained":true}
	if not _stop_issued:
		_draining = true
		_stop_issued = true
		var stopped: Dictionary = _producer.request_stop() if _async_stop_requested \
			else _producer.stop()
		if stopped.get("status") != "ready": return stopped
	var drained: Dictionary = _producer.drain_step()
	if drained.get("status") != "ready": return drained
	_producer = null
	_draining = false
	_stop_issued = false
	_active_block = null
	return {"status":"ready", "drained":true}

func _release_windows() -> void:
	for token in _window_records:
		var facade = (_window_records[token] as Dictionary).get("facade")
		if facade != null: facade.detach()
	_window_records.clear()
	_active_window_tokens.clear()
	_pending_retirement_tokens.clear()
	_retirement_leases.clear()
	_window_layout.clear()
	_window_layout_candidate.clear()

func _retention_status(projected_active: Dictionary = {}) -> Dictionary:
	var active: Dictionary = projected_active if not projected_active.is_empty() else _active_window_tokens
	var retired_windows := 0
	var retained_rows := 0
	var retained_vertex_bytes := 0
	var retired_tokens: Array[String] = []
	for token in _window_records:
		if active.has(token): continue
		retired_windows += 1
		retired_tokens.append(String(token))
		var rows: Dictionary = (_window_records[token] as Dictionary).rows
		retained_rows += rows.size()
		for block in rows:
			var row: Dictionary = rows[block]
			retained_vertex_bytes += (row.get("vertices", PackedVector3Array()) as PackedVector3Array).size() * 12
	retired_tokens.sort()
	if retired_windows > MAX_RETIRED_WINDOWS \
			or retained_vertex_bytes > MAX_RETIRED_VERTEX_BYTES:
		return {"status":"pending", "reason":"collision_window_retirement_backpressure",
			"totalWindowRecords":_window_records.size(),
			"retiredWindows":retired_windows, "retainedRows":retained_rows,
			"retainedVertexBytes":retained_vertex_bytes,
			"maxRetiredWindows":MAX_RETIRED_WINDOWS,
			"maxRetiredVertexBytes":MAX_RETIRED_VERTEX_BYTES,
			"retiredWindowTokens":retired_tokens,
			"layoutToken":_window_layout.get("layoutToken", "")}
	var layout: Dictionary = _window_layout.duplicate(true)
	layout["retirementTelemetry"] = {"retiredWindows":retired_windows,
		"totalWindowRecords":_window_records.size(),
		"retainedRows":retained_rows,
		"retainedVertexBytes":retained_vertex_bytes,
		"retiredWindowTokens":retired_tokens}
	if _window_layout.is_empty():
		return {"status":"ready", "retirementTelemetry":{
			"retiredWindows":retired_windows,
			"totalWindowRecords":_window_records.size(),
			"retainedRows":retained_rows,
			"retainedVertexBytes":retained_vertex_bytes,
			"retiredWindowTokens":retired_tokens}}
	return layout
