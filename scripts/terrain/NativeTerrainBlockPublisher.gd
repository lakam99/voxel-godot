extends RefCounted
class_name NativeTerrainBlockPublisher

## Composed N3 manual-data bridge. VoxelTerrain remains the temporary mesh and
## collision owner; NativeWorldBackend owns retained bytes and source revisions.
## The runtime must own this backend exclusively, call CitadelTerrainAdmission
## .advance() separately, and keep pumping drain_step() after stop() until idle.
const Footprint = preload("res://scripts/terrain/NativeVoxelBlockDemandFootprint.gd")
const BLOCK_SIZE := 16
const PAGE_CELLS := 280
const SCHEMA := "n3-effective-voxel-block-request/v1"
const MAX_DEMANDED_BLOCKS := 128

var _backend
var _terrain: VoxelTerrain
var _pages
var _format: VoxelFormat
var _consumer_id := 0
var _priority := 0
var _blocks: Array[Vector3i] = []
var _requested: Dictionary = {}
var _inserted: Dictionary = {}
var _retiring: Dictionary = {}
var _orphaned: Dictionary = {}
var _meshed: Dictionary = {}
var _cursor := 0
var _reconcile_cursor := 0
var _active := false
var _stopping := false
var _last_failure := ""

func setup(backend, terrain: VoxelTerrain, page_admission, consumer_id: int, priority: int) -> Dictionary:
	if _active or backend == null or terrain == null or page_admission == null or consumer_id <= 0:
		return {"status":"failed", "reason":"invalid_publisher_owner"}
	if terrain.generator != null or terrain.automatic_loading_enabled:
		return {"status":"failed", "reason":"manual_terrain_required"}
	_backend = backend
	_terrain = terrain
	_pages = page_admission
	_consumer_id = consumer_id
	_priority = priority
	_format = terrain.get_format()
	if _format == null:
		return {"status":"failed", "reason":"voxel_format_missing"}
	_terrain.mesh_block_entered.connect(_mesh_entered)
	_terrain.mesh_block_exited.connect(_mesh_exited)
	_active = true
	return {"status":"ready"}

func demand_mesh_blocks(mesh_blocks: Array[Vector3i]) -> Dictionary:
	if not _active:
		return {"status":"failed", "reason":"publisher_not_configured"}
	if not _last_failure.is_empty() or _stopping:
		return {"status":"failed", "reason":_last_failure if not _last_failure.is_empty() else "publisher_stopping"}
	var footprint: Dictionary = Footprint.data_blocks_for_mesh_blocks(mesh_blocks)
	if footprint.get("status") != "ready":
		return footprint
	var blocks: Array[Vector3i] = footprint.blocks
	if blocks.size() > MAX_DEMANDED_BLOCKS:
		return {"status":"failed", "reason":"native_queue_capacity"}
	var wanted := {}
	for block in blocks:
		wanted[block] = true
	for block: Vector3i in _blocks:
		if not wanted.has(block):
			_retiring[block] = true
	for block: Vector3i in blocks:
		_retiring.erase(block)
	_blocks = blocks
	_cursor = 0
	return {"status":"ready", "dataBlocks":blocks.size(), "retiring":_retiring.size()}

func pump() -> Dictionary:
	if not _active:
		return {"status":"failed", "reason":"publisher_not_configured"}
	if _stopping:
		return {"status":"pending", "reason":"publisher_stopping"}
	if _last_failure != "":
		return {"status":"failed", "reason":_last_failure}
	var retired: Dictionary = _retire_one()
	if retired.get("status") == "failed":
		return retired
	# Admission and request registration are each bounded to one block per pump.
	if not _blocks.is_empty():
		var block: Vector3i = _blocks[_cursor % _blocks.size()]
		_cursor += 1
		var source: Dictionary = _admit_pages(block)
		if source.get("status") == "failed":
			_last_failure = String(source.get("reason", "site_source_failed"))
			return {"status":"failed", "reason":_last_failure, "block":block}
		if source.get("status") == "ready" and not _requested.has(block):
			var request: Dictionary = _backend.request_voxel_block_shadow(_request(block), _consumer_id, _priority)
			if request.get("status") == "failed":
				_last_failure = String(request.get("reason", "native_demand_failed"))
				return {"status":"failed", "reason":_last_failure, "block":block}
			if request.has("key"):
				_requested[block] = request.key
	var event: Dictionary = _backend.pump_voxel_block_shadow()
	if event.get("status") == "failed":
		_last_failure = String(event.get("reason", "native_pump_failed"))
		return {"status":"failed", "reason":_last_failure}
	if event.get("status") != "ready" or event.get("state") != "prepared":
		return event
	var key: Dictionary = event.get("key", {})
	var origin: Vector3i = key.get("origin", Vector3i.ZERO)
	var block := Vector3i(floori(float(origin.x) / BLOCK_SIZE),
		floori(float(origin.y) / BLOCK_SIZE), floori(float(origin.z) / BLOCK_SIZE))
	if _retiring.has(block) and _requested.get(block, {}) == key:
		# A prepared old frontier is not permission to replace its physical data.
		# Its retained request is released only after the engine unloads it.
		return {"status":"pending", "reason":"prepared_retiring_block", "block":block}
	if not _requested.has(block) or not _blocks.has(block) or key != _requested[block]:
		_last_failure = "unexpected_shared_native_prepared_block"
		return {"status":"failed", "reason":_last_failure, "key":key}
	var buffer: VoxelBuffer = _format.create_buffer(Vector3i.ONE * BLOCK_SIZE)
	var sdf: PackedByteArray = event.get("sdf16Le", PackedByteArray())
	var indices: PackedByteArray = event.get("indices8", PackedByteArray())
	var data: PackedByteArray = event.get("data5_8", PackedByteArray())
	if sdf.size() != 8192 or indices.size() != 4096 or data.size() != 4096:
		_last_failure = "invalid_native_voxel_bytes"
		return {"status":"failed", "reason":_last_failure}
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_SDF, sdf)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_INDICES, indices)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_DATA5, data)
	var accepted: bool = _terrain.try_set_block_data(block, buffer)
	var receipt: Dictionary = _backend.voxel_block_shadow_insertion_receipt(key, int(event.generation), accepted)
	if accepted and receipt.get("status") != "ready":
		# Engine data was installed but its native generation was not accepted.
		# The caller must inhibit publication and retire/rebuild this terrain owner.
		_last_failure = "native_receipt_rejected_after_engine_insert"
		_orphaned[block] = {"key":key, "generation":int(event.generation)}
		return {"status":"failed", "reason":_last_failure, "block":block,
			"insertionReceipt":receipt}
	if not accepted and receipt.get("status") != "rejected":
		_last_failure = "native_rejection_receipt_missing"
		return {"status":"failed", "reason":_last_failure, "block":block,
			"insertionReceipt":receipt}
	if accepted and receipt.get("status") == "ready":
		_inserted[block] = {"key":key, "generation":int(event.generation)}
		_meshed.erase(block)
	return {"status":"ready" if accepted and receipt.get("status") == "ready" else "pending",
		"state":"inserted_waiting_mesh" if accepted else "prepared", "block":block,
		"generation":int(event.generation), "insertionReceipt":receipt.get("status")}

func reconcile_one() -> Dictionary:
	if not _active or (_inserted.is_empty() and _orphaned.is_empty()):
		return {"status":"pending", "reason":"no_inserted_blocks"}
	var keys: Array = _inserted.keys()
	for orphan_block in _orphaned.keys():
		if not keys.has(orphan_block):
			keys.append(orphan_block)
	var block: Vector3i = keys[_reconcile_cursor % keys.size()]
	_reconcile_cursor += 1
	if not _terrain.has_data_block(block):
		var installed: Dictionary = _inserted.get(block, _orphaned.get(block, {}))
		var key: Dictionary = installed.key
		var receipt: Dictionary = _backend.voxel_block_shadow_unloaded(key)
		if receipt.get("status") != "ready":
			return {"status":"failed", "reason":"native_unload_receipt_failed", "block":block}
		var mesh_exit: Dictionary = _backend.voxel_block_shadow_mesh_exited(key)
		if mesh_exit.get("status") != "ready":
			return {"status":"failed", "reason":"native_mesh_exit_receipt_failed", "block":block}
		_inserted.erase(block)
		_orphaned.erase(block)
		_meshed.erase(block)
		if _last_failure == "native_receipt_rejected_after_engine_insert" and _orphaned.is_empty():
			_last_failure = ""
		return {"status":"ready", "state":"unloaded", "block":block, "receipt":receipt.get("status")}
	return {"status":"pending", "reason":"resident"}

func acknowledge_physics(block: Vector3i, physical_proof: bool) -> Dictionary:
	# The caller must supply current collision-backed evidence. A mesh-entered
	# signal or resident data alone cannot establish actor-safe physics.
	if not _last_failure.is_empty():
		return {"status":"failed", "reason":_last_failure}
	if not physical_proof or not _meshed.has(block) or not _inserted.has(block):
		return {"status":"rejected", "reason":"current_physics_proof_required"}
	var installed: Dictionary = _inserted[block]
	return _backend.voxel_block_shadow_mesh_receipt(installed.key, int(installed.generation), true, true, true)

func stop() -> Dictionary:
	if not _active:
		return {"status":"ready"}
	_stopping = true
	for block: Vector3i in _blocks:
		_retiring[block] = true
	_blocks.clear()
	if not _inserted.is_empty() or not _orphaned.is_empty():
		return {"status":"pending", "reason":"physical_blocks_must_unload",
			"remaining":_inserted.size() + _orphaned.size()}
	while not _retiring.is_empty():
		var retired: Dictionary = _retire_one()
		if retired.get("status") == "failed":
			return retired
	_terrain.mesh_block_entered.disconnect(_mesh_entered)
	_terrain.mesh_block_exited.disconnect(_mesh_exited)
	_requested.clear()
	_meshed.clear()
	_active = false
	return {"status":"ready", "released":true}

func drain_step() -> Dictionary:
	if _active or _backend == null:
		return {"status":"failed", "reason":"stop_before_drain"}
	var event: Dictionary = _backend.pump_voxel_block_shadow()
	if event.get("status") == "failed":
		return event
	if event.get("status") == "pending" and event.get("reason") == "no_waiting_source":
		return {"status":"ready", "drained":true}
	return {"status":"pending", "drained":false, "reason":event.get("reason", "native_worker_draining")}

func snapshot() -> Dictionary:
	return {"active":_active, "demanded":_blocks.size(), "registered":_requested.size(),
		"inserted":_inserted.size(), "retiring":_retiring.size(), "orphaned":_orphaned.size(),
		"meshEntered":_meshed.size(), "failure":_last_failure}

func _retire_one() -> Dictionary:
	for block: Vector3i in _retiring.keys():
		if _inserted.has(block) or _orphaned.has(block):
			continue
		if _requested.has(block):
			var release: Dictionary = _backend.release_voxel_block_shadow(_request(block), _consumer_id)
			if release.get("status") != "ready":
				return {"status":"failed", "reason":"native_demand_release_failed", "block":block}
			_requested.erase(block)
		_retiring.erase(block)
		return {"status":"ready", "block":block}
	return {"status":"pending", "reason":"retiring_blocks_still_resident"}

func _admit_pages(block: Vector3i) -> Dictionary:
	var first := Vector2i(floori(float(block.x * BLOCK_SIZE) / PAGE_CELLS),
		floori(float(block.z * BLOCK_SIZE) / PAGE_CELLS))
	var last := Vector2i(floori(float(block.x * BLOCK_SIZE + BLOCK_SIZE - 1) / PAGE_CELLS),
		floori(float(block.z * BLOCK_SIZE + BLOCK_SIZE - 1) / PAGE_CELLS))
	for z in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var result: Dictionary = _pages.request_page(Vector2i(x, z))
			if result.get("status") != "ready":
				return result
	return {"status":"ready"}

func _request(block: Vector3i) -> Dictionary:
	return {"schema":SCHEMA, "origin":block * BLOCK_SIZE,
		"size":Vector3i.ONE * BLOCK_SIZE, "lod":0}

func _mesh_entered(block: Vector3i) -> void:
	if _inserted.has(block) and _terrain.has_data_block(block):
		_meshed[block] = true

func _mesh_exited(block: Vector3i) -> void:
	if _inserted.has(block):
		_backend.voxel_block_shadow_mesh_exited(_inserted[block].key)
	_meshed.erase(block)
