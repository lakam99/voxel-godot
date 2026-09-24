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
const MAX_TRACKED_BLOCKS := 32768

var _backend
var _terrain: VoxelTerrain
var _pages
var _format: VoxelFormat
var _consumer_id := 0
var _priority := 0
var _blocks: Array[Vector3i] = []
var _desired_set: Dictionary = {}
var _waiting_source: Array[Vector3i] = []
var _requested: Dictionary = {}
var _inserted: Dictionary = {}
var _retiring: Dictionary = {}
var _orphaned: Dictionary = {}
var _meshed: Dictionary = {}
var _edit_blocked: Dictionary = {}
var _edit_probes: Dictionary = {}
var _sdf_bytes: Dictionary = {}
var _old_edit_sdf: Dictionary = {}
var _changed_sdf: Dictionary = {}
var _cursor := 0
var _reconcile_cursor := 0
var _shutdown_requested := false
var _async_shutdown_receipt: Dictionary = {}
var _active := false
var _stopping := false
var _last_failure := ""

func setup(backend, terrain: VoxelTerrain, page_admission, consumer_id: int, priority: int) -> Dictionary:
	if _active or backend == null or terrain == null or page_admission == null or consumer_id <= 0:
		return {"status":"failed", "reason":"invalid_publisher_owner"}
	if terrain.generator != null or terrain.automatic_loading_enabled:
		return {"status":"failed", "reason":"manual_terrain_required"}
	_async_shutdown_receipt.clear()
	_shutdown_requested = false
	_stopping = false
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
			if _requested.has(block) or _inserted.has(block) or _orphaned.has(block):
				_retiring[block] = true
			else:
				_retiring.erase(block)
	for block: Vector3i in blocks:
		_retiring.erase(block)
	_blocks = blocks
	_desired_set = wanted
	_waiting_source.clear()
	for block: Vector3i in blocks:
		if not _requested.has(block):
			_waiting_source.append(block)
	_cursor = 0
	return {"status":"ready", "dataBlocks":blocks.size(), "retiring":_retiring.size()}

## The production demand owner sends bounded deltas from its reference-counted
## viewer/chunk union. Unlike demand_mesh_blocks(), these calls do not replace
## the whole desired set; a normal viewer can need thousands of data blocks.
func apply_data_block_delta(add: Array[Vector3i], remove: Array[Vector3i]) -> Dictionary:
	if not _active or _stopping or not _last_failure.is_empty():
		return {"status":"failed", "reason":"publisher_not_accepting_demand"}
	if add.size() > MAX_DEMANDED_BLOCKS or remove.size() > MAX_DEMANDED_BLOCKS:
		return {"status":"failed", "reason":"data_block_batch_limit"}
	var adding := {}
	for block: Vector3i in add:
		adding[block] = true
	var removing := {}
	for block: Vector3i in remove:
		if adding.has(block):
			return {"status":"failed", "reason":"contradictory_data_block_delta"}
		removing[block] = true
	var next_count := _desired_set.size()
	for block: Vector3i in adding:
		if not _desired_set.has(block):
			next_count += 1
	for block: Vector3i in removing:
		if _desired_set.has(block):
			next_count -= 1
	if next_count > MAX_TRACKED_BLOCKS:
		return {"status":"failed", "reason":"tracked_data_block_limit"}
	for block: Vector3i in removing:
		if not _desired_set.has(block):
			continue
		_desired_set.erase(block)
		_blocks.erase(block)
		_waiting_source.erase(block)
		if _requested.has(block) or _inserted.has(block) or _orphaned.has(block):
			_retiring[block] = true
		else:
			_retiring.erase(block)
	for block: Vector3i in adding:
		if not _desired_set.has(block):
			_desired_set[block] = true
			_blocks.append(block)
			if not _requested.has(block):
				_waiting_source.append(block)
		_retiring.erase(block)
	_blocks.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x))))
	_waiting_source.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x))))
	_cursor = 0
	return {"status":"ready", "desiredDataBlocks":_blocks.size(),
		"retiring":_retiring.size()}

func observe_committed_edit(affected_blocks: Array[Vector3i], physical_probes: Dictionary = {}) -> Dictionary:
	# Call immediately after the native commit, before any actor/nav readiness
	# query. The caller passes the complete physical mesh-impact set; native
	# demand independently invalidates exact source pins for retained blocks.
	if not _active or _stopping or affected_blocks.is_empty():
		return {"status":"failed", "reason":"invalid_edit_observation"}
	var blocked := 0
	for block: Vector3i in affected_blocks:
		if not _requested.has(block):
			continue
		var old_generation := int((_inserted.get(block, {}) as Dictionary).get("generation", 0))
		_edit_blocked[block] = old_generation
		_old_edit_sdf[block] = _sdf_bytes.get(block, PackedByteArray())
		_changed_sdf.erase(block)
		_edit_probes.erase(block)
		if physical_probes.has(block):
			var proof: Dictionary = physical_probes[block]
			if proof.get("rayFrom") is Vector3 and proof.get("rayTo") is Vector3 \
					and proof.get("expectedMinimumY") is float \
					and proof.get("changedCells") is Array:
				var old_hit: Dictionary = _collision_probe(proof)
				if old_generation == 0:
					# No old engine block exists to compare. First publication is
					# proved by its own current generation and physical result.
					_edit_probes[block] = {"spec":proof.duplicate(true), "firstPublication":true}
				elif old_hit.get("collider") == _terrain:
					_edit_probes[block] = {"spec":proof.duplicate(true),
						"firstPublication":false, "oldY":float(old_hit.position.y)}
		_meshed.erase(block)
		blocked += 1
	return {"status":"ready", "blocked":blocked}

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
	if not _waiting_source.is_empty():
		var index := _cursor % _waiting_source.size()
		var block: Vector3i = _waiting_source[index]
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
				_waiting_source.remove_at(index)
				_cursor = index
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
	if not _requested.has(block) or not _desired_set.has(block) or key != _requested[block]:
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
		if _edit_blocked.has(block) and int(event.generation) <= int(_edit_blocked[block]):
			_last_failure = "edit_replacement_generation_not_advanced"
			_orphaned[block] = {"key":key, "generation":int(event.generation)}
			return {"status":"failed", "reason":_last_failure, "block":block}
		_inserted[block] = {"key":key, "generation":int(event.generation)}
		if _edit_blocked.has(block):
			_changed_sdf[block] = _old_edit_sdf.get(block, PackedByteArray()) != sdf
		_sdf_bytes[block] = sdf
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
		_edit_blocked.erase(block)
		_edit_probes.erase(block)
		_old_edit_sdf.erase(block)
		_changed_sdf.erase(block)
		_sdf_bytes.erase(block)
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
	if _edit_blocked.has(block):
		return {"status":"rejected", "reason":"generation_specific_edit_proof_required"}
	var installed: Dictionary = _inserted[block]
	return _backend.voxel_block_shadow_mesh_receipt(installed.key, int(installed.generation), true, true, true)

func acknowledge_physics_generation(block: Vector3i, generation: int) -> Dictionary:
	if not _last_failure.is_empty():
		return {"status":"failed", "reason":_last_failure}
	if not _inserted.has(block) or not _terrain.has_data_block(block):
		return {"status":"rejected", "reason":"current_data_block_required"}
	var installed: Dictionary = _inserted[block]
	if generation != int(installed.generation) or (_edit_blocked.has(block)
			and generation <= int(_edit_blocked[block])):
		return {"status":"rejected", "reason":"stale_physics_generation"}
	if not _edit_probes.has(block):
		return {"status":"pending", "reason":"collision_change_not_provable"}
	var probe: Dictionary = _edit_probes[block]
	var first_publication := bool(probe.get("firstPublication", false))
	if first_publication:
		if not _meshed.has(block):
			return {"status":"pending", "reason":"first_mesh_publication_pending"}
	elif not bool(_changed_sdf.get(block, false)):
		return {"status":"pending", "reason":"collision_change_not_provable"}
	var proof: Dictionary = probe.spec
	var mesh_area := AABB(Vector3(block * BLOCK_SIZE), Vector3.ONE * BLOCK_SIZE)
	if not _terrain.is_area_meshed(mesh_area):
		return {"status":"rejected", "reason":"current_mesh_area_missing"}
	var hit: Dictionary = _collision_probe(proof)
	if hit.get("collider") != _terrain or float(hit.position.y) < float(proof.expectedMinimumY) \
			or (not first_publication and float(hit.position.y) <= float(probe.oldY) + 0.5 * _terrain.scale.y):
		return {"status":"rejected", "reason":"current_collision_geometry_missing"}
	var local_hit: Vector3 = _terrain.to_local(hit.position)
	if floori(local_hit.x / BLOCK_SIZE) != block.x or floori(local_hit.z / BLOCK_SIZE) != block.z:
		return {"status":"rejected", "reason":"physics_proof_outside_block"}
	var probe_cell := Vector2i(floori(local_hit.x), floori(local_hit.z))
	var changed_column := false
	for cell in proof.changedCells:
		if cell is Vector3i and Vector2i(cell.x,cell.z) == probe_cell:
			changed_column = true
			break
	if not changed_column:
		return {"status":"pending", "reason":"proof_ray_not_in_changed_column"}
	var receipt: Dictionary = _backend.voxel_block_shadow_mesh_receipt(
		installed.key, generation, true, true, true)
	if receipt.get("status") == "ready":
		_edit_blocked.erase(block)
		_edit_probes.erase(block)
		_old_edit_sdf.erase(block)
		_changed_sdf.erase(block)
	return receipt

func _collision_probe(spec: Dictionary) -> Dictionary:
	var ray := PhysicsRayQueryParameters3D.create(spec.rayFrom, spec.rayTo)
	ray.collision_mask = _terrain.collision_layer
	return _terrain.get_world_3d().direct_space_state.intersect_ray(ray)

func stop() -> Dictionary:
	if not _active:
		return {"status":"ready"}
	_stopping = true
	for block: Vector3i in _blocks:
		_retiring[block] = true
	_blocks.clear()
	_desired_set.clear()
	_waiting_source.clear()
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
	_edit_blocked.clear()
	_edit_probes.clear()
	_old_edit_sdf.clear()
	_changed_sdf.clear()
	_sdf_bytes.clear()
	_active = false
	return {"status":"ready", "released":true}

## Starts retirement without walking the entire desired set. drain_step() takes
## at most one tracked block/native worker event per invocation.
func request_stop() -> Dictionary:
	if not _async_shutdown_receipt.is_empty():
		return _async_shutdown_receipt.duplicate(true)
	_stopping = true
	_shutdown_requested = true
	if not _active:
		return {"status":"pending", "reason":"native_publisher_retirement_requested",
			"alreadyInactive":true}
	return {"status":"pending", "reason":"native_publisher_retirement_requested",
		"remainingBlocks":_blocks.size(), "inserted":_inserted.size(),
		"orphaned":_orphaned.size()}

func drain_step() -> Dictionary:
	if not _async_shutdown_receipt.is_empty():
		return _async_shutdown_receipt.duplicate(true)
	if _shutdown_requested:
		return _shutdown_drain_step()
	if _active or _backend == null:
		return {"status":"failed", "reason":"stop_before_drain"}
	var event: Dictionary = _backend.pump_voxel_block_shadow()
	if event.get("status") == "failed":
		return event
	if event.get("status") == "pending" and event.get("reason") == "no_waiting_source":
		return {"status":"ready", "drained":true}
	return {"status":"pending", "drained":false, "reason":event.get("reason", "native_worker_draining")}

func _shutdown_drain_step() -> Dictionary:
	if _backend == null:
		return {"status":"failed", "reason":"native_shutdown_backend_missing"}
	if not _active:
		var inactive_event: Dictionary = _backend.pump_voxel_block_shadow()
		if inactive_event.get("status") == "failed": return inactive_event
		if inactive_event.get("status") != "pending" \
				or inactive_event.get("reason") != "no_waiting_source":
			return {"status":"pending", "reason":"native_worker_retirement_pending",
				"workerEvent":inactive_event}
		if not _shutdown_tracked_state_empty():
			return {"status":"failed", "reason":"native_shutdown_inactive_state_not_empty",
				"publisherState":snapshot()}
		_async_shutdown_receipt = {"status":"ready", "drained":true,
			"physicalBlocksUnloaded":true, "nativeWorkersDrained":true,
			"remainingDemanded":0, "remainingRequested":0,
			"remainingInserted":0, "remainingOrphaned":0,
			"terminalWorkerEvent":inactive_event}
		return _async_shutdown_receipt.duplicate(true)
	if not _blocks.is_empty():
		var block: Vector3i = _blocks.pop_back()
		_desired_set.erase(block)
		if _requested.has(block) or _inserted.has(block) or _orphaned.has(block):
			_retiring[block] = true
		return {"status":"pending", "reason":"native_block_retirement_queued",
			"block":block, "remainingBlocks":_blocks.size()}
	if not _waiting_source.is_empty():
		var waiting: Vector3i = _waiting_source.pop_back()
		return {"status":"pending", "reason":"native_waiting_source_released",
			"block":waiting, "remainingWaitingSources":_waiting_source.size()}
	if not _retiring.is_empty():
		var retiring_block: Vector3i
		for candidate in _retiring:
			retiring_block = candidate
			break
		if _inserted.has(retiring_block) or _orphaned.has(retiring_block):
			return _shutdown_reconcile_one(retiring_block)
		if _requested.has(retiring_block):
			var request_key := _request(retiring_block)
			var release: Dictionary = _backend.release_voxel_block_shadow(request_key, _consumer_id)
			if release.get("status") != "ready":
				return {"status":"pending", "reason":"native_shutdown_release_pending",
					"block":retiring_block, "receipt":release}
			_requested.erase(retiring_block)
		_retiring.erase(retiring_block)
		return {"status":"pending", "reason":"native_block_release_acknowledged",
			"block":retiring_block}
	if not _inserted.is_empty() or not _orphaned.is_empty():
		for candidate in _inserted:
			return _shutdown_reconcile_one(candidate)
		for candidate in _orphaned:
			return _shutdown_reconcile_one(candidate)
	if not _requested.is_empty():
		for block in _requested:
			_retiring[block] = true
			return {"status":"pending", "reason":"native_untracked_request_retirement_queued",
				"block":block}
	var event: Dictionary = _backend.pump_voxel_block_shadow()
	if event.get("status") == "failed": return event
	if event.get("status") != "pending" or event.get("reason") != "no_waiting_source":
		return {"status":"pending", "reason":"native_worker_retirement_pending",
			"workerEvent":event}
	if not _shutdown_tracked_state_empty():
		return {"status":"failed", "reason":"native_shutdown_state_not_empty",
			"publisherState":snapshot()}
	_terrain.mesh_block_entered.disconnect(_mesh_entered)
	_terrain.mesh_block_exited.disconnect(_mesh_exited)
	_active = false
	_async_shutdown_receipt = {"status":"ready", "drained":true, "physicalBlocksUnloaded":true,
		"nativeWorkersDrained":true, "remainingDemanded":0, "remainingRequested":0,
		"remainingInserted":0, "remainingOrphaned":0,
		"terminalWorkerEvent":event}
	return _async_shutdown_receipt.duplicate(true)

func _shutdown_tracked_state_empty() -> bool:
	return _blocks.is_empty() and _desired_set.is_empty() and _waiting_source.is_empty() \
		and _retiring.is_empty() and _requested.is_empty() and _inserted.is_empty() \
		and _orphaned.is_empty() and _meshed.is_empty() and _edit_blocked.is_empty() \
		and _edit_probes.is_empty() and _sdf_bytes.is_empty() \
		and _old_edit_sdf.is_empty() and _changed_sdf.is_empty()

func _shutdown_reconcile_one(block: Vector3i) -> Dictionary:
	if _terrain.has_data_block(block):
		return {"status":"pending", "reason":"viewer_detach_or_physical_unload_required",
			"block":block}
	var installed: Dictionary = _inserted.get(block, _orphaned.get(block, {}))
	var key: Dictionary = installed.get("key", {})
	if key.is_empty():
		return {"status":"failed", "reason":"native_shutdown_block_key_missing", "block":block}
	var receipt: Dictionary = _backend.voxel_block_shadow_unloaded(key)
	if receipt.get("status") != "ready":
		return {"status":"failed", "reason":"native_shutdown_unload_receipt_failed",
			"block":block, "receipt":receipt}
	var exited: Dictionary = _backend.voxel_block_shadow_mesh_exited(key)
	if exited.get("status") != "ready":
		return {"status":"failed", "reason":"native_shutdown_mesh_exit_receipt_failed",
			"block":block, "receipt":exited}
	_inserted.erase(block)
	_orphaned.erase(block)
	_meshed.erase(block)
	_retiring.erase(block)
	return {"status":"pending", "reason":"native_physical_unload_acknowledged",
		"block":block, "unloadReceipt":receipt, "meshExitReceipt":exited}

func snapshot() -> Dictionary:
	return {"active":_active, "demanded":_blocks.size(), "registered":_requested.size(),
		"waitingSource":_waiting_source.size(),
		"inserted":_inserted.size(), "retiring":_retiring.size(), "orphaned":_orphaned.size(),
		"meshEntered":_meshed.size(), "editBlocked":_edit_blocked.size(), "failure":_last_failure}

func installed_generation(block: Vector3i) -> int:
	return int((_inserted.get(block, {}) as Dictionary).get("generation", 0))

func has_native_request(block: Vector3i) -> bool:
	return _requested.has(block)

func _retire_one() -> Dictionary:
	for block: Vector3i in _retiring:
		if _inserted.has(block) or _orphaned.has(block):
			continue
		if _requested.has(block):
			var release: Dictionary = _backend.release_voxel_block_shadow(_request(block), _consumer_id)
			if release.get("status") != "ready":
				return {"status":"failed", "reason":"native_demand_release_failed", "block":block}
			_requested.erase(block)
			_edit_blocked.erase(block)
			_edit_probes.erase(block)
			_old_edit_sdf.erase(block)
			_changed_sdf.erase(block)
			_sdf_bytes.erase(block)
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
