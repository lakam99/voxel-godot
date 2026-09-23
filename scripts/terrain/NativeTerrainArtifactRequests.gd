extends RefCounted
class_name NativeTerrainArtifactRequests

## Inert source-bound request queue. Physical installation and retirement belong
## to the resident collision owner; this class only produces current rows.
const Producer = preload("res://scripts/terrain/NativeTerrainTriangleArtifactProducer.gd")
const WindowSource = preload("res://scripts/terrain/NativeTerrainCollisionWindowSource.gd")
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
var _window_records := {}
var _active_window_tokens := {}
var _pending_retirement_tokens := {}
var _verified_edits := {}
var _last_verified_revision := -1
var _local_proof_cache := {}
var _proof_budget_frame := -1
var _proof_used_usec := 0

func setup(backend, pages, admission, planner, cell_meters: float,
		owner_generation: int, max_resident_blocks: int) -> Dictionary:
	if _backend != null or backend == null or pages == null or admission == null \
			or planner == null or cell_meters <= 0.0 or owner_generation <= 0 \
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
	var demand: Dictionary = _planner.required_collision_mesh_blocks()
	if demand.get("status") != "ready" or not (demand.blocks as Array).has(block):
		return {"status":"failed", "reason":"artifact_block_not_demanded"}
	for window: Dictionary in _window_layout.get("windows", []):
		if not (window.blocks as Array).has(block): continue
		var record: Dictionary = _window_records.get(window.windowToken, {})
		if record.get("identity") != _identity and record.get("rows", {}).has(block) \
				and _prove_local_window(record, _backend.status()).get("status") == "ready":
			return {"status":"ready", "reason":"locally_proven_artifact_retained",
				"block":block, "windowToken":window.windowToken}
	_requests[block] = true
	return {"status":"pending", "reason":"artifact_request_retained", "block":block}

func advance() -> Dictionary:
	if _stopping or _backend == null:
		return {"status":"failed", "reason":"artifact_requests_inactive"}
	var demand: Dictionary = _planner.required_collision_mesh_blocks()
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
	var required := {}
	for block: Vector3i in demand.blocks: required[block] = true
	var blocks: Array[Vector3i] = []
	for block: Vector3i in _requests:
		if required.has(block): blocks.append(block)
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
		var demand: Dictionary = _planner.required_collision_mesh_blocks()
		if demand.get("status") == "ready" \
				and (demand.blocks as Array).size() > _max_resident_blocks:
			return {"status":"pending", "reason":"partitioned_source_requires_window",
				"requiredBlocks":(demand.blocks as Array).size(),
				"windowLayout":collision_window_layout()}
	if _producer == null or _draining:
		return {"status":"pending", "reason":"artifact_producer_unavailable"}
	return _producer.collision_source_snapshot()

func collision_artifact_row(block: Vector3i, identity: Dictionary) -> Dictionary:
	if _producer == null or _draining:
		return {"status":"failed", "reason":"artifact_producer_unavailable"}
	return _producer.collision_artifact_row(block, identity)

func collision_window_layout() -> Dictionary:
	if _producer == null or _draining:
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
	var required: Array[Vector3i] = record.blocks
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
		"membershipProvenance":record.membershipProvenance.duplicate(true)}

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

func acknowledge_collision_window_retired(window_token: String,
		retirement_receipt: Dictionary) -> Dictionary:
	var record: Dictionary = _window_records.get(window_token, {})
	if record.is_empty() or (_active_window_tokens.has(window_token) \
			and not _pending_retirement_tokens.has(window_token)) \
			or not bool(retirement_receipt.get("drained", false)) \
			or int(retirement_receipt.get("remainingBodies", -1)) != 0 \
			or retirement_receipt.get("windowToken") != window_token:
		return {"status":"failed", "reason":"collision_window_retirement_not_proven"}
	var facade = record.get("facade")
	if facade != null: facade.detach()
	_window_records.erase(window_token)
	_active_window_tokens.erase(window_token)
	_pending_retirement_tokens.erase(window_token)
	return {"status":"ready", "retiredWindowToken":window_token}

func stop() -> Dictionary:
	_stopping = true
	var retired: Dictionary = _retire_producer()
	if retired.get("status") == "ready": _release_windows()
	return retired

func drain_step() -> Dictionary:
	if not _stopping: return {"status":"failed", "reason":"artifact_stop_required"}
	var retired: Dictionary = _retire_producer()
	if retired.get("status") == "ready": _release_windows()
	return retired

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

func _refresh_window_layout() -> Dictionary:
	# Once old physical owners exceed the retention budget, no subsequent
	# demand revision may allocate another window record before N5 drains one.
	if not _window_layout.is_empty():
		var held: Dictionary = _retention_status()
		if held.get("status") != "ready": return held
	var planned: Dictionary = _planner.collision_mesh_window_layout()
	if planned.get("status") != "ready": return planned
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
		var member := {"id":window.id, "blocks":window.blocks,
			"closureToken":window.closureToken, "windowToken":token,
			"windowIndex":index,
			"identity":proven_records[token].identity.duplicate(true) if proven_records.has(token)
				else _identity.duplicate(true),
			"localCurrentProof":{"kind":"verified_native_affected_mesh_exclusion/v1"
					if proven_records.has(token) else "native_current_revision",
				"throughGlobalRevision":int(_identity.sourceRevision),
				"digest":String(proof.get("digest", ""))}}
		windows.append(member)
		if not _window_records.has(token):
			new_records[token] = {"layoutToken":layout_token,
				"identity":_identity.duplicate(true), "blocks":window.blocks,
				"rows":{}, "facade":null,
				"sourceIdentity":_identity.sourceIdentity.duplicate(true),
				"shapingRevision":int(current_source.get("shapingRegistryRevision", -1)),
				"provenThroughRevision":int(_identity.sourceRevision),
				"proofDigest":("%s:%s:%d" % [String(window.closureToken),
					String(_identity.sourceIdentity.get("hex", "")),
					int(_identity.sourceRevision)]).sha256_text(),
				"membershipProvenance":{"authority":"pinned_demand",
					"demandRevision":0,
					"closureToken":String(window.closureToken),
					"windowToken":token}}
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
	_local_proof_cache.clear()
	return _retention_status()

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
		var stopped: Dictionary = _producer.stop()
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
	_window_layout.clear()

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
