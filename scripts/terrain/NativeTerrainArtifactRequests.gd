extends RefCounted
class_name NativeTerrainArtifactRequests

## Inert source-bound request queue. Physical installation and retirement belong
## to the resident collision owner; this class only produces current rows.
const Producer = preload("res://scripts/terrain/NativeTerrainTriangleArtifactProducer.gd")

var _backend
var _pages
var _admission
var _planner
var _cell_meters := 0.0
var _owner_generation := 0
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

func setup(backend, pages, admission, planner, cell_meters: float,
		owner_generation: int) -> Dictionary:
	if _backend != null or backend == null or pages == null or admission == null \
			or planner == null or cell_meters <= 0.0 or owner_generation <= 0:
		return {"status":"failed", "reason":"artifact_request_owner_invalid"}
	_backend = backend
	_pages = pages
	_admission = admission
	_planner = planner
	_cell_meters = cell_meters
	_owner_generation = owner_generation
	return {"status":"ready"}

func request_block(block: Vector3i) -> Dictionary:
	if _stopping or _backend == null:
		return {"status":"failed", "reason":"artifact_requests_inactive"}
	var demand: Dictionary = _planner.required_collision_mesh_blocks()
	if demand.get("status") != "ready" or not (demand.blocks as Array).has(block):
		return {"status":"failed", "reason":"artifact_block_not_demanded"}
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
	var changed: bool = _producer != null and (
			int(source.get("terrainDeltaRevision", -1)) != int(_identity.get("sourceRevision", -2))
			or source_identity != _identity.get("sourceIdentity", {})
			or int(demand.get("revision", -1)) != _demand_revision
			or String(demand.get("closureToken", "")) != _closure_token)
	if changed or _draining:
		var retired: Dictionary = _retire_producer()
		if retired.get("status") != "ready": return retired
	if _producer == null:
		var created: Dictionary = _create_producer(source, demand)
		if created.get("status") != "ready": return created
	var snapshot: Dictionary = _producer.collision_source_snapshot()
	for stale: Vector3i in snapshot.get("staleBlocks", []): _requests[stale] = true
	if _active_block != null:
		var result: Dictionary = _producer.advance()
		if result.get("status") == "ready":
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
	if blocks.is_empty(): return {"status":"ready", "queuedBlocks":0}
	_active_block = blocks[0]
	var accepted: Dictionary = _producer.request_block(_active_block)
	if accepted.get("status") == "failed":
		_active_block = null
		_draining = true
		return {"status":"pending", "reason":"artifact_retry_retained"}
	return accepted

func collision_source_snapshot() -> Dictionary:
	if _producer == null or _draining:
		return {"status":"pending", "reason":"artifact_producer_unavailable"}
	return _producer.collision_source_snapshot()

func collision_artifact_row(block: Vector3i, identity: Dictionary) -> Dictionary:
	if _producer == null or _draining:
		return {"status":"failed", "reason":"artifact_producer_unavailable"}
	return _producer.collision_artifact_row(block, identity)

func stop() -> Dictionary:
	_stopping = true
	return _retire_producer()

func drain_step() -> Dictionary:
	if not _stopping: return {"status":"failed", "reason":"artifact_stop_required"}
	return _retire_producer()

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
