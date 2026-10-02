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
var _represented_blocks := 0
var _empty_blocks := 0
var _active := false
var _source_stale := false
var _bound_runtime_instance_id := 0


func begin(runtime: Object, readiness: Object, request_id: int, seed: String,
		world_revision: String, view_revision: int, bounds: Rect2i, near_bounds: Rect2i,
		center_cells: Vector3, radius_cells: float) -> Dictionary:
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
	var same := _active and not _source_stale and _request_id == request_id and _seed == seed \
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
	_represented_blocks = 0
	_empty_blocks = 0
	_active = true
	_source_stale = false
	return {"status": "ready", "viewRevision": _view_revision, "blockCount": _blocks.size(),
		"sourceIdentity": _source_identity, "sourceRevision": _source_world_revision}


func advance(block_budget: int = 24) -> Dictionary:
	var runtime: Object = _runtime_ref.get_ref() if _runtime_ref != null else null
	if not _active or not is_instance_valid(runtime) or not is_instance_valid(_readiness):
		return {"status": "pending", "reason": "native_terrain_visual_manifest_not_started"}
	if _source_stale:
		# Recheck the bounded source list after a previously accepted block changes.
		# expect_source replaces only changed revisions; its old receipt cannot pass
		# the publisher validator while the replacement is absent.
		_cursor = 0
		_represented_blocks = 0
		_empty_blocks = 0
		_source_stale = false
	if String(runtime.call("visible_mesh_source_identity")) != _source_identity \
			or String(runtime.call("visible_mesh_world_revision")) != _source_world_revision:
		return _progress("pending", "native_terrain_source_revision_changed")
	var processed := 0
	while _cursor < _blocks.size() and processed < maxi(1, block_budget):
		var block: Vector3i = _blocks[_cursor]
		var source_id := "terrain-mesh:%d,%d,%d" % [block.x, block.y, block.z]
		var source_revision := String(runtime.call("visible_mesh_source_revision", block))
		var source_bounds := Rect2i(Vector2i(block.x, block.z) * NATIVE_BLOCK_CELLS,
			Vector2i.ONE * NATIVE_BLOCK_CELLS)
		var declared: Dictionary = _readiness.call("expect_source", source_id, "terrain",
			_source_identity, source_revision, source_bounds, _view_revision)
		if declared.get("status") != "ready":
			return _progress(String(declared.get("status", "pending")),
				String(declared.get("reason", "native_terrain_source_declaration_pending")), block)
		if not bool(runtime.call("visible_mesh_area_complete", block)):
			return _progress("pending", "native_terrain_mesh_block_pending", block)
		if bool(runtime.call("visible_mesh_block_has_geometry", block)):
			var candidate_id := "terrain:%d,%d,%d" % [block.x, block.y, block.z]
			var position_xz := _representative_position(block)
			var tier := "near" if _near_bounds.has_point(Vector2i(floori(position_xz.x), floori(position_xz.y))) else "horizon"
			if not bool(_readiness.call("has_candidate", source_id, candidate_id)):
				var described: Dictionary = _readiness.call("describe_candidate", source_id,
					candidate_id, tier, {"positionXZ": position_xz, "nativeBlock": block})
				if described.get("status") != "ready":
					return _progress(String(described.get("status", "pending")),
						String(described.get("reason", "native_terrain_candidate_pending")), block)
			var receipt: Dictionary = _readiness.call("accept_publisher_receipt", source_id,
				candidate_id, candidate_id + ":native_mesh", tier, _source_identity,
				source_revision, _view_revision, runtime, &"visible_mesh_receipt_is_current")
			if receipt.get("status") != "ready":
				return _progress(String(receipt.get("status", "pending")),
					String(receipt.get("reason", "native_terrain_receipt_pending")), block)
			_represented_blocks += 1
		else:
			_empty_blocks += 1
		var finished: Dictionary = _readiness.call("finish_source", source_id,
			_source_identity, source_revision, _view_revision)
		if finished.get("status") != "ready":
			return _progress(String(finished.get("status", "pending")),
				String(finished.get("reason", "native_terrain_source_finish_pending")), block)
		_cursor += 1
		processed += 1
	return _progress("ready" if _cursor >= _blocks.size() else "pending",
		"" if _cursor >= _blocks.size() else "native_terrain_visual_coverage_pending")


func pending_block_diagnostics(runtime: Object) -> Dictionary:
	if _cursor >= _blocks.size() or not is_instance_valid(runtime): return {}
	var block: Vector3i = _blocks[_cursor]
	return runtime.call("visible_mesh_area_diagnostics", block) \
		if runtime.has_method("visible_mesh_area_diagnostics") else {"block": block}


func _progress(status: String, reason: String, pending_block := Vector3i(-2147483648, -2147483648, -2147483648)) -> Dictionary:
	return {"status": status, "reason": reason, "requestId": _request_id,
		"viewRevision": _view_revision, "sourceIdentity": _source_identity,
		"sourceRevision": _source_world_revision, "requiredBlocks": _blocks.size(),
		"processedBlocks": _cursor, "pendingBlocks": _blocks.size() - _cursor,
		"representedMeshBlocks": _represented_blocks, "completedEmptyBlocks": _empty_blocks,
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
	# The current pending block can publish while this scan is waiting for it.
	# A changed block already acknowledged by the scan invalidates that proof.
	if _block_indices.has(block_position) and int(_block_indices[block_position]) < _cursor:
		_source_stale = true


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
