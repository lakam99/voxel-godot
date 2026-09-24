extends RefCounted
class_name NativeTerrainTriangleArtifactProducer

## Bounded source-to-triangle bridge for one native mesh block at a time.
## The backend captures a 19-cell padded source snapshot on its own worker;
## VoxelMesherTransvoxel consumes only those bytes, never a script generator.
const SCHEMA := "n3-effective-voxel-block-request/v1"
const BLOCK_CELLS := 16
const MAX_VERTICES := 65536
const MAX_DEMAND_SNAPSHOT_WORK_OPS := 257

var _backend
var _admission
var _pages
var _planner
var _format: VoxelFormat
var _mesher: VoxelMesherTransvoxel
var _cell_meters := 0.0
var _identity := {}
var _source_identity := {}
var _pending_block: Variant = null
var _ticket := 0
var _draining_failed_ticket := false
var _failure_reason := ""
var _build_thread: Thread
var _build_context := {}
var _draining_failed_build := false
var _artifacts := {}
var _artifact_rows := {}
var _validated_local_pins := {}
var _demand_revision := -1
var _closure_token := ""
var _required_demand_blocks: Array = []
var _required_demand_snapshot_ready := false
var _demand_snapshot_token := 0
var _demand_snapshot_target_revision := -1
var _demand_snapshot_target_token := ""
var _demand_snapshot_cancel_requested := false
var _candidate_demand_blocks: Array = []
var _candidate_demand_revision := -1
var _candidate_closure_token := ""
var _candidate_demand_pending := false
var _demand_prune_cursor := -1
var _stopped := false

func setup(backend, page_admission, admission, planner, cell_meters: float,
		identity: Dictionary) -> Dictionary:
	if _backend != null or backend == null or page_admission == null or admission == null \
			or planner == null \
			or not planner.has_method("begin_required_collision_mesh_blocks") \
			or not planner.has_method("advance_required_collision_mesh_blocks") \
			or not planner.has_method("diagnostics") or cell_meters <= 0.0 \
			or not _identity_valid(identity):
		return {"status":"failed", "reason":"triangle_producer_owner_invalid"}
	var status: Dictionary = backend.status()
	if status.get("status") != "ready" or not status.get("sourceIdentity") is Dictionary:
		return {"status":"failed", "reason":"triangle_source_unavailable"}
	var demanded: Dictionary = planner.diagnostics()
	if int(demanded.get("demandRevision", 0)) <= 0 \
			or String(demanded.get("closureToken", "")).is_empty():
		return {"status":"failed", "reason":"triangle_demand_unavailable"}
	_backend = backend
	_source_identity = (status.sourceIdentity as Dictionary).duplicate(true)
	_pages = page_admission
	_admission = admission
	_planner = planner
	_demand_revision = int(demanded.demandRevision)
	_closure_token = String(demanded.closureToken)
	_cell_meters = cell_meters
	_identity = identity.duplicate(true)
	_format = VoxelFormat.new()
	_format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	_format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	_format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	_mesher = VoxelMesherTransvoxel.new()
	_mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	_mesher.transitions_enabled = false
	_mesher.mesh_optimization_enabled = false
	if _mesher.get_minimum_padding() != 1 or _mesher.get_maximum_padding() != 2:
		return {"status":"failed", "reason":"transvoxel_padding_contract_changed"}
	var snapshot_started: Dictionary = _begin_demand_snapshot(
		_demand_revision, _closure_token)
	if snapshot_started.get("status") != "pending":
		return {"status":"failed", "reason":"triangle_demand_snapshot_start_failed",
			"cause":snapshot_started}
	return {"status":"ready", "sourceIdentity":status.sourceIdentity,
		"identity":_identity.duplicate(true), "demandSnapshotPending":true}

func advance_demand_snapshot() -> Dictionary:
	return _advance_demand_snapshot()

func demand_snapshot() -> Dictionary:
	return _required_blocks()

func is_block_demanded(block: Vector3i) -> Dictionary:
	var required: Dictionary = _required_blocks()
	if required.get("status") != "ready": return required
	return {"status":"ready", "demanded":_contains_block(required.blocks, block),
		"revision":_demand_revision, "closureToken":_closure_token}

func _begin_demand_snapshot(revision: int, closure_token: String) -> Dictionary:
	var started: Dictionary = _planner.begin_required_collision_mesh_blocks()
	if started.get("status") != "pending": return started
	if String(started.get("reason", "")) != "required_mesh_blocks_started" \
			or String(started.get("transactionKind", "")) != "requiredBlocks" \
			or String(started.get("transactionStatus", "")) != "active":
		return {"status":"pending", "reason":"triangle_demand_snapshot_transaction_busy",
			"cause":started}
	var token := int(started.get("token", 0))
	var owner: Dictionary = _planner.collision_mesh_snapshot_transaction_state()
	if token <= 0 or String(owner.get("kind", "")) != "requiredBlocks" \
			or int(owner.get("token", 0)) != token \
			or String(owner.get("status", "")) != "active":
		return {"status":"pending", "reason":"triangle_demand_snapshot_begin_not_owned",
			"cause":owner}
	_demand_snapshot_token = token
	_demand_snapshot_target_revision = revision
	_demand_snapshot_target_token = closure_token
	_demand_snapshot_cancel_requested = false
	return started

func _advance_demand_snapshot() -> Dictionary:
	if _planner == null: return {"status":"failed", "reason":"triangle_planner_unavailable"}
	var identity: Dictionary = _planner.diagnostics()
	var target_revision := int(identity.get("demandRevision", -1))
	var target_token := String(identity.get("closureToken", ""))
	if _candidate_demand_pending:
		if target_revision != _candidate_demand_revision \
				or target_token != _candidate_closure_token:
			if not _candidate_demand_blocks.is_empty():
				_candidate_demand_blocks.pop_back()
				return {"status":"pending", "reason":"triangle_demand_candidate_retiring",
					"workOps":1, "maxWorkOps":MAX_DEMAND_SNAPSHOT_WORK_OPS}
			_candidate_demand_pending = false
			return _begin_demand_snapshot(target_revision, target_token)
		if _demand_prune_cursor >= 0:
			var stale_block: Vector3i = _required_demand_blocks[_demand_prune_cursor]
			_demand_prune_cursor -= 1
			if not _contains_block(_candidate_demand_blocks, stale_block):
				_artifacts.erase(stale_block)
				_artifact_rows.erase(stale_block)
				_validated_local_pins.erase(stale_block)
			if _demand_prune_cursor >= 0:
				return {"status":"pending", "reason":"triangle_demand_artifact_prune_pending",
					"remaining":_demand_prune_cursor + 1,
					"workOps":1, "maxWorkOps":MAX_DEMAND_SNAPSHOT_WORK_OPS}
		_required_demand_blocks = _candidate_demand_blocks
		_required_demand_blocks.make_read_only()
		_candidate_demand_blocks = []
		_demand_revision = _candidate_demand_revision
		_closure_token = _candidate_closure_token
		_candidate_demand_revision = -1
		_candidate_closure_token = ""
		_candidate_demand_pending = false
		_required_demand_snapshot_ready = true
		return {"status":"pending", "reason":"triangle_demand_snapshot_published",
			"workOps":1, "maxWorkOps":MAX_DEMAND_SNAPSHOT_WORK_OPS}
	if _demand_snapshot_token == 0:
		if _required_demand_snapshot_ready and _demand_revision == target_revision \
				and _closure_token == target_token \
				and not _candidate_demand_pending:
			return {"status":"ready", "revision":_demand_revision,
				"closureToken":_closure_token}
		var started := _begin_demand_snapshot(target_revision, target_token)
		if started.get("status") == "failed": return started
		return {"status":"pending", "reason":"triangle_demand_snapshot_started",
			"cause":started, "workOps":0,
			"maxWorkOps":MAX_DEMAND_SNAPSHOT_WORK_OPS}
	if target_revision != _demand_snapshot_target_revision \
			or target_token != _demand_snapshot_target_token:
		if not _demand_snapshot_cancel_requested:
			_planner.cancel_required_collision_mesh_blocks(_demand_snapshot_token)
			_demand_snapshot_cancel_requested = true
		var cancelled: Dictionary = _planner.advance_required_collision_mesh_blocks(
			_demand_snapshot_token)
		if cancelled.get("reason") == "mesh_snapshot_owner_mismatch":
			var foreign: Dictionary = cancelled.get("transaction", {})
			if String(foreign.get("kind", "")) == "requiredBlocks" \
					and int(foreign.get("token", 0)) == _demand_snapshot_token:
				return {"status":"failed", "reason":"triangle_demand_snapshot_owner_inconsistent",
					"transaction":foreign}
			if String(foreign.get("status", "")) == "idle" \
					or (String(foreign.get("status", "")) == "transferred" \
						and not bool(foreign.get("hasPendingRetirement", false))):
				_demand_snapshot_token = 0
				_demand_snapshot_cancel_requested = false
				return _begin_demand_snapshot(target_revision, target_token)
			return {"status":"pending", "reason":"triangle_demand_snapshot_orphan_waiting",
				"transaction":foreign, "workOps":0,
				"maxWorkOps":MAX_DEMAND_SNAPSHOT_WORK_OPS}
		if cancelled.get("status") == "pending":
			return {"status":"pending", "reason":"triangle_demand_snapshot_cancel_draining",
				"workOps":int(cancelled.get("workOps", 0)),
				"maxWorkOps":MAX_DEMAND_SNAPSHOT_WORK_OPS}
		_demand_snapshot_token = 0
		_demand_snapshot_cancel_requested = false
		return _begin_demand_snapshot(target_revision, target_token)
	var advanced: Dictionary = _planner.advance_required_collision_mesh_blocks(
		_demand_snapshot_token)
	if advanced.get("reason") == "mesh_snapshot_owner_mismatch":
		var foreign: Dictionary = advanced.get("transaction", {})
		if String(foreign.get("kind", "")) == "requiredBlocks" \
				and int(foreign.get("token", 0)) == _demand_snapshot_token:
			return {"status":"failed", "reason":"triangle_demand_snapshot_owner_inconsistent",
				"transaction":foreign}
		if String(foreign.get("status", "")) == "idle" \
				or (String(foreign.get("status", "")) == "transferred" \
					and not bool(foreign.get("hasPendingRetirement", false))):
			_demand_snapshot_token = 0
			_demand_snapshot_cancel_requested = false
			return {"status":"pending", "reason":"triangle_demand_snapshot_orphan_released",
				"transaction":foreign, "workOps":0,
				"maxWorkOps":MAX_DEMAND_SNAPSHOT_WORK_OPS}
		return {"status":"pending", "reason":"triangle_demand_snapshot_orphan_waiting",
			"transaction":foreign, "workOps":0,
			"maxWorkOps":MAX_DEMAND_SNAPSHOT_WORK_OPS}
	if advanced.get("status") == "pending":
		return {"status":"pending", "reason":"triangle_demand_snapshot_building",
			"workOps":advanced.get("workOps", 0),
			"maxWorkOps":advanced.get("maxWorkOps", 0)}
	_demand_snapshot_token = 0
	_demand_snapshot_cancel_requested = false
	if advanced.get("status") != "ready":
		return advanced
	if int(advanced.get("revision", -1)) != target_revision \
			or String(advanced.get("closureToken", "")) != target_token:
		return {"status":"pending", "reason":"triangle_demand_snapshot_stale",
			"workOps":int(advanced.get("workOps", 0)),
			"maxWorkOps":MAX_DEMAND_SNAPSHOT_WORK_OPS}
	_candidate_demand_blocks = advanced.get("blocks", [])
	_candidate_demand_revision = target_revision
	_candidate_closure_token = target_token
	_candidate_demand_pending = true
	_demand_prune_cursor = _required_demand_blocks.size() - 1
	return {"status":"pending", "reason":"triangle_demand_snapshot_candidate_ready",
		"workOps":int(advanced.get("workOps", 0)),
		"maxWorkOps":MAX_DEMAND_SNAPSHOT_WORK_OPS}

func _contains_block(blocks: Array, sought: Vector3i) -> bool:
	# The staged planner builder publishes the exact canonical z/y/x ordering
	# also used by its synchronous compatibility API; do not pass arbitrary arrays.
	var low := 0
	var high := blocks.size() - 1
	while low <= high:
		var mid := (low + high) >> 1
		var candidate: Vector3i = blocks[mid]
		if candidate == sought: return true
		if _block_before(candidate, sought): low = mid + 1
		else: high = mid - 1
	return false

func _block_before(a: Vector3i, b: Vector3i) -> bool:
	return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x)))

func request_block(block: Vector3i) -> Dictionary:
	if _stopped or _backend == null: return {"status":"failed", "reason":"triangle_producer_inactive"}
	if _draining_failed_ticket or not _failure_reason.is_empty():
		return {"status":"failed", "reason":"triangle_producer_failed_or_draining"}
	if _pending_block != null: return {"status":"pending", "reason":"triangle_block_in_flight"}
	var required: Dictionary = _required_blocks()
	if required.get("status") != "ready":
		if required.get("status") == "pending":
			_pending_block = block
			return {"status":"pending", "reason":"triangle_demand_snapshot_pending",
				"block":block}
		return {"status":"failed", "reason":"triangle_block_not_in_pinned_demand"}
	if not _contains_block(required.blocks, block):
		return {"status":"failed", "reason":"triangle_block_not_in_pinned_demand"}
	_pending_block = block
	return {"status":"pending", "reason":"triangle_block_requested", "block":block}

func rebind_demand() -> Dictionary:
	if _stopped or _backend == null or not _failure_reason.is_empty():
		return {"status":"failed", "reason":"triangle_producer_inactive"}
	var source: Dictionary = _backend.status()
	if source.get("status") != "ready" or source.get("sourceIdentity") != _source_identity \
			or int(source.get("terrainDeltaRevision", -1)) != int(_identity.sourceRevision):
		return {"status":"failed", "reason":"triangle_source_revision_changed"}
	if _ticket != 0:
		_backend.cancel_voxel_block_shadow_async(_ticket)
		var drained: Dictionary = _backend.poll_voxel_block_shadow_async(_ticket)
		if drained.get("status") != "ready":
			return {"status":"pending", "reason":"triangle_demand_worker_draining"}
		_ticket = 0
	if _build_thread != null:
		if _build_thread.is_alive():
			return {"status":"pending", "reason":"triangle_demand_mesh_worker_draining"}
		_build_thread.wait_to_finish()
		_build_thread = null
		_build_context.clear()
	_pending_block = null
	var demanded: Dictionary = _advance_demand_snapshot()
	if demanded.get("status") != "ready": return demanded
	return {"status":"ready", "demandRevision":_demand_revision,
		"closureToken":_closure_token, "retainedArtifacts":_artifacts.size()}

func advance() -> Dictionary:
	if _stopped or _backend == null: return {"status":"failed", "reason":"triangle_producer_inactive"}
	if _draining_failed_build:
		if _build_thread != null and _build_thread.is_alive():
			return {"status":"pending", "reason":"triangle_mesh_worker_draining"}
		if _build_thread != null:
			_build_thread.wait_to_finish()
			_build_thread = null
		_build_context.clear()
		_draining_failed_build = false
		_pending_block = null
		return {"status":"failed", "reason":_failure_reason}
	if _draining_failed_ticket:
		var drained: Dictionary = _backend.poll_voxel_block_shadow_async(_ticket)
		if drained.get("status") != "ready":
			return {"status":"pending", "reason":"triangle_worker_draining"}
		_ticket = 0
		_draining_failed_ticket = false
		_pending_block = null
		return {"status":"failed", "reason":_failure_reason}
	if not _failure_reason.is_empty(): return {"status":"failed", "reason":_failure_reason}
	var demand_progress: Dictionary = _advance_demand_snapshot()
	if demand_progress.get("status") != "ready": return demand_progress
	if _pending_block == null: return {"status":"pending", "reason":"triangle_block_not_requested"}
	var required: Dictionary = _required_blocks()
	if required.get("status") != "ready": return _failure("triangle_demand_changed")
	if not _contains_block(required.blocks, _pending_block):
		_pending_block = null
		return {"status":"failed", "reason":"triangle_block_not_in_pinned_demand"}
	var source: Dictionary = _backend.status()
	if source.get("status") != "ready" or source.get("sourceIdentity") != _source_identity \
			or int(source.get("terrainDeltaRevision", -1)) \
			!= int(_identity.get("sourceRevision", -2)):
		return _failure("triangle_source_revision_changed")
	if _build_thread != null:
		if _build_thread.is_alive():
			return {"status":"pending", "reason":"triangle_mesh_in_flight"}
		var extracted: Dictionary = _build_thread.wait_to_finish()
		_build_thread = null
		var context: Dictionary = _build_context
		_build_context = {}
		var built: Dictionary = _finish_artifact(context.encoded,
			extracted.get("local", PackedVector3Array()), context.bufferUsec,
			context.meshUsec, int(extracted.get("facesUsec", -1)))
		if built.get("status") != "ready":
			return _failure(String(built.get("reason", "triangle_mesh_failed")))
		_artifacts[_pending_block] = built.row.artifactKey
		_artifact_rows[_pending_block] = built.row.duplicate(true)
		_validated_local_pins.erase(_pending_block)
		_pending_block = null
		return built
	var site: Dictionary = _admission.advance()
	if not String(site.get("failure", "")).is_empty():
		return _failure(String(site.failure))
	if _ticket == 0:
		var block: Vector3i = _pending_block
		var admitted: Dictionary = _admit_pages(block)
		if admitted.get("status") != "ready": return admitted
		var began: Dictionary = _backend.begin_voxel_block_shadow_async({"schema":SCHEMA,
			"origin":block * BLOCK_CELLS - Vector3i.ONE,
			"size":Vector3i.ONE * (BLOCK_CELLS + 3), "lod":0})
		if began.get("status") == "failed": return _failure(String(began.get("reason", "triangle_encode_failed")))
		if began.get("status") != "pending" or not began.has("ticket"):
			return {"status":"pending", "reason":began.get("reason", "triangle_source_pending")}
		_ticket = int(began.ticket)
		return {"status":"pending", "reason":"triangle_encode_in_flight"}
	var encoded: Dictionary = _backend.poll_voxel_block_shadow_async(_ticket)
	if encoded.get("status") == "failed": return _failure(String(encoded.get("reason", "triangle_encode_failed")))
	if encoded.get("status") != "ready": return encoded
	_ticket = 0
	if bool(encoded.get("cancelled", false)):
		return _failure("triangle_encode_cancelled")
	var requested_block: Vector3i = _pending_block
	if encoded.get("sourceIdentity") != _source_identity \
			or int(encoded.get("terrainDeltaRevision", -1)) != int(_identity.sourceRevision) \
			or encoded.get("origin") != requested_block * BLOCK_CELLS - Vector3i.ONE \
			or encoded.get("size") != Vector3i.ONE * (BLOCK_CELLS + 3):
		return _failure("triangle_source_receipt_mismatch")
	var build_started: Dictionary = _begin_artifact_build(encoded)
	if build_started.get("status") == "failed":
		return _failure(String(build_started.get("reason", "triangle_mesh_failed")))
	return build_started

func _admit_pages(block: Vector3i) -> Dictionary:
	var first_cell := block * BLOCK_CELLS - Vector3i.ONE
	var last_cell := first_cell + Vector3i.ONE * (BLOCK_CELLS + 2)
	for z in range(floori(float(first_cell.z) / 280.0),
			floori(float(last_cell.z) / 280.0) + 1):
		for x in range(floori(float(first_cell.x) / 280.0),
				floori(float(last_cell.x) / 280.0) + 1):
			var page: Dictionary = _pages.request_page(Vector2i(x, z))
			if page.get("status") != "ready": return page
	return {"status":"ready"}

func _begin_artifact_build(encoded: Dictionary) -> Dictionary:
	var size := BLOCK_CELLS + 3
	var cells := size * size * size
	var sdf: PackedByteArray = encoded.get("sdf16Le", PackedByteArray())
	var indices: PackedByteArray = encoded.get("indices8", PackedByteArray())
	var data: PackedByteArray = encoded.get("data5_8", PackedByteArray())
	if sdf.size() != cells * 2 or indices.size() != cells or data.size() != cells:
		return {"status":"failed", "reason":"triangle_native_bytes_invalid"}
	var buffer_started := Time.get_ticks_usec()
	var buffer: VoxelBuffer = _format.create_buffer(Vector3i.ONE * size)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_SDF, sdf)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_INDICES, indices)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_DATA5, data)
	var mesh_started := Time.get_ticks_usec()
	var mesh: Mesh = _mesher.build_mesh(buffer, [])
	var faces_started := Time.get_ticks_usec()
	_build_context = {"encoded":encoded, "bufferUsec":mesh_started - buffer_started,
		"meshUsec":faces_started - mesh_started}
	_build_thread = Thread.new()
	var started: Error = _build_thread.start(
		Callable(self, "_extract_faces_worker").bind(mesh))
	if started != OK:
		_build_thread = null
		_build_context.clear()
		return {"status":"failed", "reason":"triangle_mesh_worker_start_failed"}
	return {"status":"pending", "reason":"triangle_mesh_in_flight"}

func _extract_faces_worker(mesh: Mesh) -> Dictionary:
	var started := Time.get_ticks_usec()
	var local := PackedVector3Array() if mesh == null else mesh.get_faces()
	return {"local":local, "facesUsec":Time.get_ticks_usec() - started}

func _finish_artifact(encoded: Dictionary, local: PackedVector3Array,
		buffer_usec: int, mesh_usec: int, faces_usec: int) -> Dictionary:
	var translate_started := Time.get_ticks_usec()
	var sdf: PackedByteArray = encoded.sdf16Le
	var indices: PackedByteArray = encoded.indices8
	var data: PackedByteArray = encoded.data5_8
	if local.size() > MAX_VERTICES or local.size() % 3 != 0:
		return {"status":"failed", "reason":"triangle_vertex_capacity_or_topology"}
	var block: Vector3i = _pending_block
	var world_origin := Vector3(block * BLOCK_CELLS) * _cell_meters
	var bounds := AABB(world_origin, Vector3.ONE * BLOCK_CELLS * _cell_meters)
	var vertices := PackedVector3Array()
	vertices.resize(local.size())
	for index in range(local.size()):
		var vertex := world_origin + local[index] * _cell_meters
		if not vertex.is_finite() or not _inside_bounds(vertex, bounds):
			return {"status":"failed", "reason":"triangle_vertex_outside_block"}
		vertices[index] = vertex
	var copied_usec := Time.get_ticks_usec() - translate_started
	var content: Dictionary = encoded.get("blockContentIdentity", {})
	var pin: Dictionary = encoded.get("pinIdentity", {})
	if not content.get("hex") is String or not pin.get("hex") is String:
		return {"status":"failed", "reason":"triangle_content_identity_missing"}
	var local_pins: Dictionary = _current_local_page_pins(block)
	if local_pins.get("status") != "ready" \
			or int(local_pins.get("shapingRegistryRevision", -1)) \
			!= int(encoded.shapingRegistryRevision):
		return {"status":"failed", "reason":"triangle_local_pin_capture_stale"}
	var hasher := HashingContext.new()
	if hasher.start(HashingContext.HASH_SHA256) != OK:
		return {"status":"failed", "reason":"triangle_artifact_hash_failed"}
	hasher.update(("transvoxel-collision/v2:%s:%d,%d,%d:%s" % [
		String(encoded.sourceIdentity.hex), block.x, block.y, block.z,
		str(_cell_meters)]).to_utf8_buffer())
	hasher.update(sdf)
	hasher.update(indices)
	hasher.update(data)
	var key := hasher.finish().hex_encode()
	var probes: Dictionary = _probe_segment(vertices, bounds)
	if not vertices.is_empty() and probes.is_empty():
		return {"status":"failed", "reason":"triangle_probe_unavailable"}
	if vertices.is_empty():
		probes = {"from":bounds.get_center() + Vector3.UP * _cell_meters * 0.2,
			"to":bounds.get_center() - Vector3.UP * _cell_meters * 0.2}
	var row := {"block":block, "artifactKey":key, "vertices":vertices,
		"bounds":bounds, "probeFrom":probes.from,
		"probeTo":probes.to,
		"expectedHit":not vertices.is_empty(),
		"sourceIdentity":encoded.sourceIdentity, "pinIdentity":pin,
		"blockContentIdentity":content,
		"localPagePins":local_pins.pins,
		"nativeRevision":int(encoded.terrainDeltaRevision),
		"shapingRegistryRevision":int(encoded.shapingRegistryRevision),
		"sourceEpoch":_identity.get("sourceEpoch", ""),
		"ownerGeneration":int(_identity.ownerGeneration),
		"cancellationEpoch":int(_identity.cancellationEpoch),
		"mesherBuildUsec":mesh_usec,
		"vertexCopyUsec":copied_usec,
		"coordinateFrame":"world", "empty":vertices.is_empty()}
	return {"status":"ready", "row":row,
		"captureUsec":encoded.get("captureUsec", 0),
		"workerEncodeUsec":encoded.get("workerEncodeUsec", 0),
		"bufferUsec":buffer_usec,
		"meshUsec":mesh_usec,
		"facesUsec":faces_usec,
		"vertexCopyUsec":copied_usec,
		"finalizeUsec":Time.get_ticks_usec() - translate_started - copied_usec}

func _probe_segment(vertices: PackedVector3Array, bounds: AABB) -> Dictionary:
	var distance := _cell_meters * 0.15
	for index in range(0, vertices.size(), 3):
		var a := vertices[index]
		var b := vertices[index + 1]
		var c := vertices[index + 2]
		var normal := (b - a).cross(c - a).normalized()
		if normal.length_squared() < 0.5: continue
		var center := (a + b + c) / 3.0
		var ray_from := center + normal * distance
		var ray_to := center - normal * distance
		if _inside_bounds(ray_from, bounds) and _inside_bounds(ray_to, bounds):
			return {"from":ray_from, "to":ray_to}
	return {}

func _inside_bounds(point: Vector3, bounds: AABB) -> bool:
	var end := bounds.end
	var epsilon := _cell_meters * 0.0001
	return point.x >= bounds.position.x - epsilon and point.x <= end.x + epsilon \
		and point.y >= bounds.position.y - epsilon and point.y <= end.y + epsilon \
		and point.z >= bounds.position.z - epsilon and point.z <= end.z + epsilon

func collision_source_snapshot() -> Dictionary:
	if _stopped or _backend == null: return {"status":"failed", "reason":"triangle_producer_inactive"}
	if _draining_failed_ticket or not _failure_reason.is_empty():
		return {"status":"failed", "reason":"triangle_producer_failed_or_draining"}
	var required: Dictionary = _required_blocks()
	if required.get("status") != "ready": return required
	var status: Dictionary = _backend.status()
	if status.get("status") != "ready" or status.get("sourceIdentity") != _source_identity \
			or int(status.get("terrainDeltaRevision", -1)) \
			!= int(_identity.sourceRevision):
		return {"status":"pending", "reason":"triangle_source_revision_changed"}
	var produced: Array[Vector3i] = []
	for block: Vector3i in _artifacts: produced.append(block)
	produced.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x))))
	var stale_blocks: Array[Vector3i] = []
	for block: Vector3i in produced:
		if not _local_pins_current(block, status):
			stale_blocks.append(block)
	var complete: bool = produced == required.blocks and stale_blocks.is_empty()
	return {"status":"ready" if complete else "pending",
		"reason":"triangle_local_source_changed" if not stale_blocks.is_empty() \
			else ("triangle_artifacts_incomplete" if not complete else ""),
		"identity":_identity.duplicate(true),
		"sourceIdentity":_source_identity.duplicate(true),
		"sourceEpoch":_identity.sourceEpoch,
		"nativeRevision":int(_identity.sourceRevision),
		"ownerGeneration":int(_identity.ownerGeneration),
		"cancellationEpoch":int(_identity.cancellationEpoch),
		"requiredResidentBlocks":required.blocks,
		"residentBlocks":produced, "artifacts":_artifacts.duplicate(true),
		"staleBlocks":stale_blocks,
		"membershipProvenance":{"authority":"pinned_demand",
			"demandRevision":_demand_revision, "closureToken":_closure_token}}

func collision_artifact_row(block: Vector3i, identity: Dictionary) -> Dictionary:
	if _stopped or _backend == null or identity != _identity \
			or _required_blocks().get("status") != "ready" \
			or not _artifact_rows.has(block):
		return {"status":"failed", "reason":"triangle_artifact_not_current"}
	var source: Dictionary = _backend.status()
	if source.get("status") != "ready" or source.get("sourceIdentity") != _source_identity \
			or int(source.get("terrainDeltaRevision", -1)) \
			!= int(_identity.sourceRevision):
		return {"status":"failed", "reason":"triangle_artifact_source_stale"}
	if not _local_pins_current(block, source):
		return {"status":"failed", "reason":"triangle_artifact_local_source_stale"}
	return {"status":"ready", "row":(_artifact_rows[block] as Dictionary).duplicate(true)}


## Borrowed immutable row for staged consumers. The producer retains the packed
## vertex buffer for the lifetime of this source revision; callers must not
## mutate it. The shallow dictionary copy keeps descriptor isolation without
## cloning the potentially large PackedVector3Array on the main thread.
func collision_artifact_row_snapshot(block: Vector3i, identity: Dictionary) -> Dictionary:
	if _stopped or _backend == null or identity != _identity \
			or _required_blocks().get("status") != "ready" \
			or not _artifact_rows.has(block):
		return {"status":"failed", "reason":"triangle_artifact_not_current"}
	var source: Dictionary = _backend.status()
	if source.get("status") != "ready" or source.get("sourceIdentity") != _source_identity \
			or int(source.get("terrainDeltaRevision", -1)) \
			!= int(_identity.sourceRevision):
		return {"status":"failed", "reason":"triangle_artifact_source_stale"}
	if not _local_pins_current(block, source):
		return {"status":"failed", "reason":"triangle_artifact_local_source_stale"}
	return {"status":"ready", "row":(_artifact_rows[block] as Dictionary).duplicate(false)}

func _current_local_page_pins(block: Vector3i) -> Dictionary:
	var before: Dictionary = _backend.status()
	if before.get("status") != "ready": return {"status":"pending"}
	var first := block * BLOCK_CELLS - Vector3i.ONE
	var last := first + Vector3i.ONE * (BLOCK_CELLS + 2)
	var pins := {}
	for z in range(floori(float(first.z) / 280.0), floori(float(last.z) / 280.0) + 1):
		for x in range(floori(float(first.x) / 280.0), floori(float(last.x) / 280.0) + 1):
			var page := Vector2i(x, z)
			var pinned: Dictionary = _backend.pin_effective_page(page)
			var receipt: Dictionary = pinned.get("pageStatus", {})
			if pinned.get("status") != "ready" or receipt.get("status") != "ready" \
					or receipt.get("sourceIdentity") != _source_identity \
					or int(receipt.get("terrainDeltaRevision", -1)) \
					!= int(_identity.sourceRevision):
				return {"status":"pending", "reason":"triangle_local_page_unavailable"}
			pins[page] = (receipt.pinIdentity as Dictionary).duplicate(true)
	var after: Dictionary = _backend.status()
	if after.get("status") != "ready" or after.get("sourceIdentity") != _source_identity \
			or int(after.get("terrainDeltaRevision", -1)) != int(_identity.sourceRevision) \
			or int(after.get("shapingRegistryRevision", -1)) \
			!= int(before.get("shapingRegistryRevision", -2)):
		return {"status":"pending", "reason":"triangle_local_pin_capture_raced"}
	return {"status":"ready", "pins":pins,
		"shapingRegistryRevision":int(after.shapingRegistryRevision)}

func _local_pins_current(block: Vector3i, source: Dictionary) -> bool:
	var revision := int(source.get("shapingRegistryRevision", -1))
	var row: Dictionary = _artifact_rows[block]
	if revision == int(row.get("shapingRegistryRevision", -2)): return true
	var cached: Dictionary = _validated_local_pins.get(block, {})
	if int(cached.get("revision", -2)) == revision: return bool(cached.get("valid", false))
	var current: Dictionary = _current_local_page_pins(block)
	var valid: bool = current.get("status") == "ready" \
		and int(current.get("shapingRegistryRevision", -2)) == revision \
		and current.get("pins", {}) == row.get("localPagePins", {})
	_validated_local_pins[block] = {"revision":revision, "valid":valid}
	return valid

func _required_blocks() -> Dictionary:
	if _planner == null or not _required_demand_snapshot_ready \
			or _demand_snapshot_token != 0 or _candidate_demand_pending:
		return {"status":"pending", "reason":"triangle_demand_snapshot_pending"}
	var current: Dictionary = _planner.diagnostics()
	if int(current.get("demandRevision", -1)) != _demand_revision \
			or String(current.get("closureToken", "")) != _closure_token:
		return {"status":"pending", "reason":"triangle_demand_changed"}
	return {"status":"ready", "revision":_demand_revision,
		"closureToken":_closure_token, "blocks":_required_demand_blocks}

func stop() -> Dictionary:
	_stopped = true
	if _candidate_demand_pending:
		return {"status":"pending", "reason":"triangle_demand_candidate_draining"}
	if _demand_snapshot_token != 0:
		if not _demand_snapshot_cancel_requested:
			_planner.cancel_required_collision_mesh_blocks(_demand_snapshot_token)
			_demand_snapshot_cancel_requested = true
		return {"status":"pending", "reason":"triangle_demand_snapshot_draining"}
	if _ticket != 0:
		_backend.cancel_voxel_block_shadow_async(_ticket)
		return {"status":"pending", "reason":"triangle_worker_draining"}
	if _build_thread != null:
		return {"status":"pending", "reason":"triangle_mesh_worker_draining"}
	_backend = null
	_pages = null
	_admission = null
	_planner = null
	return {"status":"ready", "drained":true}

## Non-blocking cancellation entrypoint used by the owner drain path. It only
## requests cancellation; worker/ticket completion remains in drain_step().
func request_stop() -> Dictionary:
	_stopped = true
	if _candidate_demand_pending:
		return {"status":"pending", "reason":"triangle_demand_candidate_cancel_requested"}
	if _demand_snapshot_token != 0:
		if not _demand_snapshot_cancel_requested:
			_planner.cancel_required_collision_mesh_blocks(_demand_snapshot_token)
			_demand_snapshot_cancel_requested = true
		return {"status":"pending", "reason":"triangle_demand_snapshot_cancel_requested",
			"token":_demand_snapshot_token}
	if _ticket != 0:
		_backend.cancel_voxel_block_shadow_async(_ticket)
		return {"status":"pending", "reason":"triangle_worker_cancel_requested",
			"ticket":_ticket}
	if _build_thread != null:
		return {"status":"pending", "reason":"triangle_mesh_worker_join_pending"}
	_backend = null
	_pages = null
	_admission = null
	_planner = null
	return {"status":"ready", "drained":true}

func drain_step() -> Dictionary:
	if not _stopped: return {"status":"failed", "reason":"triangle_stop_required"}
	if _candidate_demand_pending:
		if not _candidate_demand_blocks.is_empty():
			_candidate_demand_blocks.pop_back()
			return {"status":"pending", "reason":"triangle_demand_candidate_draining",
				"remaining":_candidate_demand_blocks.size()}
		_candidate_demand_pending = false
		_candidate_demand_revision = -1
		_candidate_closure_token = ""
		_demand_prune_cursor = -1
	if _demand_snapshot_token != 0:
		var demand_drain: Dictionary = _planner.advance_required_collision_mesh_blocks(
			_demand_snapshot_token)
		if demand_drain.get("status") == "pending":
			return {"status":"pending", "reason":"triangle_demand_snapshot_draining",
				"workOps":demand_drain.get("workOps", 0),
				"maxWorkOps":demand_drain.get("maxWorkOps", 0)}
		_demand_snapshot_token = 0
		_demand_snapshot_cancel_requested = false
	if _ticket != 0:
		var result: Dictionary = _backend.poll_voxel_block_shadow_async(_ticket)
		if result.get("status") != "ready": return result
		_ticket = 0
	if _build_thread != null:
		if _build_thread.is_alive():
			return {"status":"pending", "reason":"triangle_mesh_worker_draining"}
		_build_thread.wait_to_finish()
		_build_thread = null
		_build_context.clear()
	_backend = null
	_pages = null
	_admission = null
	_planner = null
	return {"status":"ready", "drained":true}

func _failure(reason: String) -> Dictionary:
	_failure_reason = reason
	if _build_thread != null:
		_draining_failed_build = true
		return {"status":"pending", "reason":"triangle_mesh_worker_draining"}
	if _ticket != 0:
		_backend.cancel_voxel_block_shadow_async(_ticket)
		_draining_failed_ticket = true
		return {"status":"pending", "reason":"triangle_worker_draining"}
	_pending_block = null
	return {"status":"failed", "reason":reason}

func _identity_valid(identity: Dictionary) -> bool:
	return int(identity.get("ownerGeneration", 0)) > 0 \
		and int(identity.get("sourceRevision", -1)) >= 0 \
		and int(identity.get("cancellationEpoch", 0)) > 0 \
		and String(identity.get("sourceEpoch", "")).length() > 0
