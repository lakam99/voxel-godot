extends RefCounted
class_name VoxelTerrainVisualManifest

## Incrementally describes the native terrain mesh blocks intersecting the
## configured 3D viewer sphere. Empty blocks count only after is_area_meshed.
const NATIVE_BLOCK_CELLS := 16

var _runtime_ref: WeakRef
var _readiness: Object
var _request_id := 0
var _seed := ""
var _world_revision := ""
var _view_revision := 0
var _bounds := Rect2i()
var _near_bounds := Rect2i()
var _center_cells := Vector3.ZERO
var _radius_cells := 0.0
var _source_identity := ""
var _source_world_revision := ""
var _blocks: Array[Vector3i] = []
var _block_indices: Dictionary = {}
var _cursor := 0
var _completed_blocks: Dictionary = {}
var _revisit_blocks: Array[Vector3i] = []
var _previous_ledgers: Array = []
var _pending_block := Vector3i(-2147483648, -2147483648, -2147483648)
var _represented_blocks := 0
var _empty_blocks := 0
var _transferred_blocks := 0
var _active := false
var _bound_runtime_instance_id := 0


func begin(runtime: Object, readiness: Object, request_id: int, seed: String,
		world_revision: String, view_revision: int, bounds: Rect2i, near_bounds: Rect2i,
		center_cells: Vector3, radius_cells: float, previous_ledgers: Array = []) -> Dictionary:
	if not is_instance_valid(runtime) or not is_instance_valid(readiness) \
			or not runtime.has_method("visible_mesh_source_identity") \
			or not runtime.has_method("visible_mesh_world_revision") \
			or not runtime.has_method("visible_mesh_source_revision") \
			or not runtime.has_method("visible_mesh_vertical_bounds") \
			or not runtime.has_method("visible_mesh_area_complete") \
			or not runtime.has_method("visible_mesh_block_has_geometry") \
			or not runtime.has_method("visible_mesh_receipt_is_current") \
			or not is_finite(radius_cells) or radius_cells <= 0.0 \
			or request_id <= 0 or seed.strip_edges().is_empty() or world_revision.strip_edges().is_empty() \
			or view_revision <= 0 or bounds.size.x <= 0 or bounds.size.y <= 0 \
			or not bounds.encloses(near_bounds) or not center_cells.is_finite():
		return {"status": "failed", "reason": "invalid_native_terrain_visual_demand"}
	var identity := {"requestId": request_id, "seed": seed, "worldRevision": world_revision,
		"viewRevision": view_revision, "bounds": bounds, "nearBounds": near_bounds,
		"center": center_cells, "radius": radius_cells, "runtime": runtime.get_instance_id()}
	var same := _active and _request_id == request_id and _seed == seed \
		and _world_revision == world_revision and _view_revision == view_revision \
		and _bounds == bounds and _near_bounds == near_bounds and _center_cells == center_cells \
		and is_equal_approx(_radius_cells, radius_cells) \
		and _source_identity == String(runtime.call("visible_mesh_source_identity")) \
		and _source_world_revision == String(runtime.call("visible_mesh_world_revision"))
	if same:
		return {"status": "ready", "viewRevision": _view_revision, "blockCount": _blocks.size()}
	_bind_runtime_mesh_revision_signal(runtime)
	_runtime_ref = weakref(runtime)
	_readiness = readiness
	_request_id = request_id
	_seed = seed
	_world_revision = world_revision
	_view_revision = view_revision
	_bounds = bounds
	_near_bounds = near_bounds
	_center_cells = center_cells
	_radius_cells = radius_cells
	_source_identity = String(runtime.call("visible_mesh_source_identity"))
	_source_world_revision = String(runtime.call("visible_mesh_world_revision"))
	if _source_identity.is_empty() or _source_world_revision != world_revision:
		_active = false
		return {"status": "pending", "reason": "native_terrain_source_revision_changed"}
	_blocks = _required_blocks(runtime, center_cells, radius_cells)
	if _blocks.is_empty():
		_active = false
		return {"status": "pending", "reason": "native_terrain_mesh_source_set_empty"}
	var terrain_footprints: Dictionary = {}
	for block: Vector3i in _blocks:
		terrain_footprints["terrain-mesh:%d,%d,%d" % [block.x, block.y, block.z]] = \
			Rect2i(Vector2i(block.x, block.z) * NATIVE_BLOCK_CELLS,
				Vector2i.ONE * NATIVE_BLOCK_CELLS)
	var admitted: Dictionary = readiness.call("declare_terrain_mesh_source_set",
		terrain_footprints, view_revision)
	if admitted.get("status") != "ready":
		_active = false
		return admitted
	_blocks.sort_custom(func(a: Vector3i, b: Vector3i):
		var da := _distance_squared_to_block(center_cells, a)
		var db := _distance_squared_to_block(center_cells, b)
		if not is_equal_approx(da, db): return da < db
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z
	)
	_block_indices.clear()
	for index in range(_blocks.size()): _block_indices[_blocks[index]] = index
	_cursor = 0
	_completed_blocks.clear()
	_revisit_blocks.clear()
	_previous_ledgers.clear()
	for previous_value in previous_ledgers:
		if previous_value is Object and is_instance_valid(previous_value):
			_previous_ledgers.append(weakref(previous_value))
	_pending_block = Vector3i(-2147483648, -2147483648, -2147483648)
	_represented_blocks = 0
	_empty_blocks = 0
	_transferred_blocks = 0
	_active = true
	return {"status": "ready", "viewRevision": _view_revision, "blockCount": _blocks.size(),
		"sourceIdentity": _source_identity, "sourceRevision": _source_world_revision}


func advance(block_budget: int = 24) -> Dictionary:
	var runtime: Object = _runtime_ref.get_ref() if _runtime_ref != null else null
	if not _active or not is_instance_valid(runtime) or not is_instance_valid(_readiness):
		return {"status": "pending", "reason": "native_terrain_visual_manifest_not_started"}
	if String(runtime.call("visible_mesh_source_identity")) != _source_identity \
			or String(runtime.call("visible_mesh_world_revision")) != _source_world_revision:
		return _progress("pending", "native_terrain_source_revision_changed")
	var processed := 0
	var examined := 0
	var attempted_revisits: Dictionary = {}
	var first_pending_reason := "native_terrain_visual_coverage_pending"
	_pending_block = Vector3i(-2147483648, -2147483648, -2147483648)
	# A missing frontier mesh must not prevent already installed blocks later in
	# the source list from being described. Visit a bounded slice, then resume
	# at the next block on the following frame.
	while examined < _blocks.size() and processed < maxi(1, block_budget) \
			and _completed_blocks.size() < _blocks.size():
		var block: Vector3i = _blocks[_cursor]
		var revisit_found := false
		for _queued_index in range(_revisit_blocks.size()):
			var queued: Vector3i = _revisit_blocks.pop_front()
			_revisit_blocks.append(queued)
			if not attempted_revisits.has(queued):
				block = queued
				attempted_revisits[queued] = true
				revisit_found = true
				break
		if not revisit_found:
			_cursor = (_cursor + 1) % _blocks.size()
		examined += 1
		if _completed_blocks.has(block):
			_revisit_blocks.erase(block)
			continue
		processed += 1
		var source_id := "terrain-mesh:%d,%d,%d" % [block.x, block.y, block.z]
		var source_revision := String(runtime.call("visible_mesh_source_revision", block))
		var source_bounds := Rect2i(Vector2i(block.x, block.z) * NATIVE_BLOCK_CELLS,
			Vector2i.ONE * NATIVE_BLOCK_CELLS)
		if not bool(runtime.call("visible_mesh_area_complete", block)):
			# A changed native revision must retire its old receipt even while
			# the replacement mesh is still pending.
			var invalidated: Dictionary = _readiness.call("expect_source", source_id,
				"terrain", _source_identity, source_revision, source_bounds, _view_revision)
			if invalidated.get("status") == "failed":
				return _progress("failed", String(invalidated.get("reason", "native_terrain_source_declaration_failed")), block)
			if _pending_block.x == -2147483648:
				_pending_block = block
				first_pending_reason = "native_terrain_mesh_block_pending"
			continue
		var has_geometry := bool(runtime.call("visible_mesh_block_has_geometry", block))
		if _transfer_complete_block(block, source_id, source_revision, has_geometry):
			_completed_blocks[block] = "represented" if has_geometry else "empty"
			_revisit_blocks.erase(block)
			_transferred_blocks += 1
			if has_geometry: _represented_blocks += 1
			else: _empty_blocks += 1
			continue
		var declared: Dictionary = _readiness.call("expect_source", source_id, "terrain",
			_source_identity, source_revision, source_bounds, _view_revision)
		if declared.get("status") != "ready":
			if declared.get("status") == "failed":
				return _progress("failed", String(declared.get("reason", "native_terrain_source_declaration_failed")), block)
			if _pending_block.x == -2147483648:
				_pending_block = block
				first_pending_reason = String(declared.get("reason", "native_terrain_source_declaration_pending"))
			continue
		if has_geometry:
			var candidate_id := "terrain:%d,%d,%d" % [block.x, block.y, block.z]
			var position_xz := _representative_position(block)
			var tier := "near" if _near_bounds.has_point(Vector2i(floori(position_xz.x), floori(position_xz.y))) else "horizon"
			if not bool(_readiness.call("has_candidate", source_id, candidate_id)):
				var described: Dictionary = _readiness.call("describe_candidate", source_id,
					candidate_id, tier, {"positionXZ": position_xz, "nativeBlock": block})
				if described.get("status") != "ready":
					if described.get("status") == "failed":
						return _progress("failed", String(described.get("reason", "native_terrain_candidate_failed")), block)
					if _pending_block.x == -2147483648:
						_pending_block = block
						first_pending_reason = String(described.get("reason", "native_terrain_candidate_pending"))
					continue
			var receipt: Dictionary = _readiness.call("accept_publisher_receipt", source_id,
				candidate_id, candidate_id + ":native_mesh", tier, _source_identity,
				source_revision, _view_revision, runtime, &"visible_mesh_receipt_is_current")
			if receipt.get("status") != "ready":
				if receipt.get("status") == "failed":
					return _progress("failed", String(receipt.get("reason", "native_terrain_receipt_failed")), block)
				if _pending_block.x == -2147483648:
					_pending_block = block
					first_pending_reason = String(receipt.get("reason", "native_terrain_receipt_pending"))
				continue
		var finished: Dictionary = _readiness.call("finish_source", source_id,
			_source_identity, source_revision, _view_revision)
		if finished.get("status") != "ready":
			if finished.get("status") == "failed":
				return _progress("failed", String(finished.get("reason", "native_terrain_source_finish_failed")), block)
			if _pending_block.x == -2147483648:
				_pending_block = block
				first_pending_reason = String(finished.get("reason", "native_terrain_source_finish_pending"))
			continue
		_completed_blocks[block] = "represented" if has_geometry else "empty"
		_revisit_blocks.erase(block)
		if has_geometry: _represented_blocks += 1
		else: _empty_blocks += 1
	var complete := _completed_blocks.size() == _blocks.size()
	return _progress("ready" if complete else "pending", "" if complete else first_pending_reason,
		_pending_block)


func _transfer_complete_block(block: Vector3i, source_id: String, source_revision: String,
		has_geometry: bool) -> bool:
	for previous_value in _previous_ledgers:
		var previous_ref: WeakRef = previous_value as WeakRef
		var previous: Object = previous_ref.get_ref() if previous_ref != null else null
		if not is_instance_valid(previous) or previous == _readiness \
				or not previous.has_method("complete_source_candidate_count") \
				or not previous.has_method("complete_source_candidate_position"): continue
		var candidate_count: int = int(previous.call("complete_source_candidate_count",
			source_id, _source_identity, source_revision))
		if candidate_count != (1 if has_geometry else 0): continue
		if has_geometry:
			var candidate_id := "terrain:%d,%d,%d" % [block.x, block.y, block.z]
			var prior_position: Vector2 = previous.call("complete_source_candidate_position",
				source_id, candidate_id, _source_identity, source_revision)
			# The terrain candidate's representative position is selected from
			# the view center. Re-describe it when that changes; the old tier and
			# metadata do not prove the new view's requirement.
			if not prior_position.is_finite() \
					or not prior_position.is_equal_approx(_representative_position(block)):
				continue
		var transferred: Dictionary = _readiness.call("transfer_complete_overlap_source",
			previous, source_id, _source_identity, source_revision, _view_revision, 1)
		if transferred.get("status") == "ready": return true
	return false


func pending_block_diagnostics(runtime: Object) -> Dictionary:
	if _completed_blocks.size() == _blocks.size() or not is_instance_valid(runtime): return {}
	var block := _pending_block
	if block.x == -2147483648:
		for offset in range(_blocks.size()):
			var candidate: Vector3i = _blocks[(_cursor + offset) % _blocks.size()]
			if not _completed_blocks.has(candidate):
				block = candidate
				break
	return runtime.call("visible_mesh_area_diagnostics", block) \
		if runtime.has_method("visible_mesh_area_diagnostics") else {"block": block}


func needs_advance() -> bool:
	return _active and _completed_blocks.size() < _blocks.size()


func _progress(status: String, reason: String, pending_block := Vector3i(-2147483648, -2147483648, -2147483648)) -> Dictionary:
	return {"status": status, "reason": reason, "requestId": _request_id,
		"viewRevision": _view_revision, "sourceIdentity": _source_identity,
		"sourceRevision": _source_world_revision, "requiredBlocks": _blocks.size(),
		"processedBlocks": _completed_blocks.size(), "pendingBlocks": _blocks.size() - _completed_blocks.size(),
		"representedMeshBlocks": _represented_blocks, "completedEmptyBlocks": _empty_blocks,
		"transferredBlocks": _transferred_blocks,
		"pendingBlock": pending_block if pending_block.x != -2147483648 else null}


func _representative_position(block: Vector3i) -> Vector2:
	var low := Vector2(float(block.x * NATIVE_BLOCK_CELLS), float(block.z * NATIVE_BLOCK_CELLS))
	var high := low + Vector2.ONE * float(NATIVE_BLOCK_CELLS)
	var selected := Vector2(clampf(_center_cells.x, low.x + 0.001, high.x - 0.001),
		clampf(_center_cells.z, low.y + 0.001, high.y - 0.001))
	if selected.distance_to(Vector2(_center_cells.x, _center_cells.z)) > _radius_cells:
		var ray := selected - Vector2(_center_cells.x, _center_cells.z)
		selected = Vector2(_center_cells.x, _center_cells.z) + ray.normalized() * (_radius_cells - 0.01)
	return selected


func _bind_runtime_mesh_revision_signal(runtime: Object) -> void:
	if not runtime.has_signal("visible_mesh_block_revision_changed"): return
	var prior: Object = _runtime_ref.get_ref() if _runtime_ref != null else null
	var callback := Callable(self, "_on_mesh_block_revision_changed")
	if is_instance_valid(prior) and _bound_runtime_instance_id != runtime.get_instance_id() \
			and prior.is_connected("visible_mesh_block_revision_changed", callback):
		prior.disconnect("visible_mesh_block_revision_changed", callback)
	if not runtime.is_connected("visible_mesh_block_revision_changed", callback):
		runtime.connect("visible_mesh_block_revision_changed", callback)
	_bound_runtime_instance_id = runtime.get_instance_id()


func _on_mesh_block_revision_changed(block_position: Vector3i, _revision: int) -> void:
	# Revisit only the changed block. The old receipt remains in the ledger but
	# its source revision fails validation until expect_source replaces it.
	revisit_block(block_position)


func revisit_candidate(source_id: String, candidate_id: String) -> bool:
	if not source_id.begins_with("terrain-mesh:") \
			or not candidate_id.begins_with("terrain:") \
			or source_id.trim_prefix("terrain-mesh:") != candidate_id.trim_prefix("terrain:"):
		return false
	var components := candidate_id.trim_prefix("terrain:").split(",")
	if components.size() != 3 or not components[0].is_valid_int() \
			or not components[1].is_valid_int() or not components[2].is_valid_int():
		return false
	return revisit_block(Vector3i(int(components[0]), int(components[1]),
		int(components[2])))


func revisit_block(block_position: Vector3i) -> bool:
	if not _active or not _block_indices.has(block_position): return false
	if _completed_blocks.has(block_position):
		if String(_completed_blocks[block_position]) == "represented": _represented_blocks -= 1
		else: _empty_blocks -= 1
		_completed_blocks.erase(block_position)
	if not _revisit_blocks.has(block_position): _revisit_blocks.append(block_position)
	return true


func _required_blocks(runtime: Object, center: Vector3, radius: float) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var vertical: Vector2i = runtime.call("visible_mesh_vertical_bounds")
	if vertical.y < vertical.x: return result
	var min_x := floori((center.x - radius) / NATIVE_BLOCK_CELLS)
	var max_x := floori((center.x + radius) / NATIVE_BLOCK_CELLS)
	var min_y := maxi(floori((center.y - radius) / NATIVE_BLOCK_CELLS), floori(float(vertical.x) / NATIVE_BLOCK_CELLS))
	var max_y := mini(floori((center.y + radius) / NATIVE_BLOCK_CELLS), floori(float(vertical.y) / NATIVE_BLOCK_CELLS))
	var min_z := floori((center.z - radius) / NATIVE_BLOCK_CELLS)
	var max_z := floori((center.z + radius) / NATIVE_BLOCK_CELLS)
	for y in range(min_y, max_y + 1):
		for z in range(min_z, max_z + 1):
			for x in range(min_x, max_x + 1):
				var block := Vector3i(x, y, z)
				if _distance_squared_to_block(center, block) <= radius * radius:
					result.append(block)
	return result


static func _distance_squared_to_block(point: Vector3, block: Vector3i) -> float:
	var low := Vector3(block * NATIVE_BLOCK_CELLS)
	var high := low + Vector3.ONE * NATIVE_BLOCK_CELLS
	# Native VoxelTerrain streams whole mesh blocks using their centers. A
	# closest-point test admits corner blocks whose centers lie outside the
	# viewer range, leaving permanently unmeshed obligations at the view edge.
	var center := (low + high) * 0.5
	return center.distance_squared_to(point)
