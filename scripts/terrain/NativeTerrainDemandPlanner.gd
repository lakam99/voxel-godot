extends RefCounted
class_name NativeTerrainDemandPlanner

const REPLACEMENT := preload("res://scripts/terrain/NativeTerrainDemandReplacement.gd")
const MESH_LAYOUT_BUILDER := preload("res://scripts/terrain/NativeTerrainCollisionMeshLayoutBuilder.gd")
const MESH_LAYOUT_LEASE := preload("res://scripts/terrain/NativeTerrainMeshLayoutRequestLease.gd")

## Pure N3 demand planning. Sources reference-count one data-block union; only
## one publisher/native consumer owns that union. No engine or backend calls.
const CELL := 1.35
const BLOCK_CELLS := 16
const GAME_CHUNK_CELLS := 28
const MAX_VIEW_DISTANCE := 128
const MAX_UNION_BLOCKS := 32768
const MAX_DELTA_BLOCKS := 128
const MESH_WINDOW_EDGE_BLOCKS := 16
const MAX_MESH_WINDOW_BLOCKS := 4096

var _consumer_id := 0
var _sources: Dictionary = {}
var _mesh_sources: Dictionary = {}
var _desired: Dictionary = {}
var _required_mesh_blocks: Dictionary = {}
var _demand_revision := 0
var _closure_token := ""
var _mesh_window_layout := {}
var _mesh_window_layout_revision := -1
var _desired_priority: Dictionary = {}
var _applied: Dictionary = {}
var _issued: Dictionary = {}
var _next_ticket := 1
var _replacement
var _mesh_layout_builder
var _mesh_layout_lease
var _incremental_active := false
var _accepted_plan: Dictionary = {}

func setup(consumer_id: int) -> Dictionary:
	if consumer_id <= 0 or _consumer_id != 0:
		return {"status":"failed", "reason":"invalid_consumer_owner"}
	_consumer_id = consumer_id
	_replacement = REPLACEMENT.new()
	if _replacement.setup(consumer_id).get("status") != "ready":
		return {"status":"failed", "reason":"replacement_setup_failed"}
	_mesh_layout_builder = MESH_LAYOUT_BUILDER.new()
	_accepted_plan = _empty_plan()
	return {"status":"ready", "consumerId":_consumer_id}

## Frame-budgeted source replacement. Request data is borrowed under a
## producer-issued lease; the producer must invalidate before nested mutation.
func begin_replace_sources(primary: Dictionary, other_viewers: Array[Dictionary],
		retained_chunks: Array[Vector2i], foreground_chunks: Array[Vector2i],
		vertical_bounds: Vector2i, request_lease, request_revision: int) -> Dictionary:
	if _consumer_id <= 0:
		return {"status":"failed", "reason":"planner_not_configured"}
	if _mesh_layout_builder.is_active() or _mesh_layout_builder.has_pending_retirement():
		return {"status":"pending", "reason":"mesh_layout_transaction_active"}
	if not _issued.is_empty():
		return {"status":"pending", "reason":"delta_ack_pending", "ticket":_issued.ticket}
	var result: Dictionary = _replacement.begin(primary, other_viewers, retained_chunks,
		foreground_chunks, vertical_bounds, request_lease, request_revision)
	if result.get("status") == "pending": _incremental_active = true
	return result

func advance_replace_sources() -> Dictionary:
	if _replacement == null:
		return {"status":"failed", "reason":"planner_not_configured"}
	var result: Dictionary = _replacement.advance()
	if result.get("status") == "ready" and result.has("plan"):
		var plan: Dictionary = result.plan
		var previous := _accepted_plan
		_accepted_plan = plan
		_sources = plan.sources
		_mesh_sources = plan.meshSources
		_desired = plan.desired
		_desired_priority = plan.priority
		_required_mesh_blocks = plan.required
		_demand_revision = int(plan.demandRevision)
		_closure_token = String(plan.closureToken)
		_mesh_window_layout_revision = -1
		_replacement.accept_current_plan(_required_mesh_blocks, _demand_revision, _closure_token)
		_replacement.set_retirement_plan(previous)
		_incremental_active = false
		var published := result.duplicate(false)
		published.erase("plan")
		published["sourceCount"] = _sources.size()
		published["desiredDataBlocks"] = _desired.size()
		published["appliedDataBlocks"] = _applied.size()
		published["requiredMeshBlocks"] = _required_mesh_blocks.size()
		published["demandRevision"] = _demand_revision
		published["closureToken"] = _closure_token
		published["consumerId"] = _consumer_id
		return published
	if result.get("status") == "ready" or (result.get("status") == "failed"
			and not result.get("acceptedPlanRetained", false)):
		_incremental_active = false
	return result

func cancel_replace_sources(token: int) -> Dictionary:
	if _replacement == null:
		return {"status":"failed", "reason":"planner_not_configured"}
	return _replacement.cancel(token)

func _empty_plan() -> Dictionary:
	return {"sources":{}, "meshSources":{}, "desired":{}, "priority":{},
		"required":{}, "sourceOrder":[], "dataMembers":[], "meshMembers":[],
		"desiredOrder":[], "requiredOrder":[], "demandRevision":0,
		"closureToken":""}

func replace_sources(primary: Dictionary, other_viewers: Array[Dictionary],
		retained_chunks: Array[Vector2i], foreground_chunks: Array[Vector2i],
		vertical_bounds: Vector2i) -> Dictionary:
	if _consumer_id <= 0:
		return {"status":"failed", "reason":"planner_not_configured"}
	if _incremental_active or _replacement.has_pending_retirement() \
			or _mesh_layout_builder.is_active() or _mesh_layout_builder.has_pending_retirement():
		return {"status":"pending", "reason":"incremental_replacement_active"}
	if not _issued.is_empty():
		return {"status":"pending", "reason":"delta_ack_pending", "ticket":_issued.ticket}
	if vertical_bounds.x > vertical_bounds.y or vertical_bounds.y - vertical_bounds.x > 256:
		return {"status":"failed", "reason":"invalid_vertical_bounds"}
	var planned_sources := {}
	var planned_mesh_sources := {}
	if not primary.is_empty():
		var primary_result := _add_viewer(planned_sources, planned_mesh_sources,
			"primary", "primary", primary, vertical_bounds)
		if primary_result.status != "ready": return primary_result
	for spec in other_viewers:
		var kind := String(spec.get("kind", ""))
		if not ["startup", "secondary", "handoff", "retained"].has(kind):
			return {"status":"failed", "reason":"invalid_viewer_kind"}
		var source_id := String(spec.get("id", ""))
		if source_id.is_empty(): return {"status":"failed", "reason":"missing_viewer_id"}
		var viewer_result := _add_viewer(planned_sources, planned_mesh_sources,
			kind, source_id, spec, vertical_bounds)
		if viewer_result.status != "ready": return viewer_result
	for chunk in retained_chunks:
		var retained_result := _add_chunk(planned_sources, planned_mesh_sources,
			"retained", chunk, vertical_bounds)
		if retained_result.status != "ready": return retained_result
	for chunk in foreground_chunks:
		var foreground_result := _add_chunk(planned_sources, planned_mesh_sources,
			"foreground", chunk, vertical_bounds)
		if foreground_result.status != "ready": return foreground_result
	var union := {}
	var priorities := {}
	var source_order: Array[String] = []
	var data_members: Array[Dictionary] = []
	var desired_order: Array[Vector3i] = []
	for source_id in planned_sources:
		source_order.append(String(source_id))
		var priority := _source_priority(String(source_id))
		for block: Vector3i in planned_sources[source_id]:
			data_members.append({"source":String(source_id), "block":block})
			if not union.has(block): desired_order.append(block)
			union[block] = true
			priorities[block] = maxi(int(priorities.get(block, 0)), priority)
			if union.size() > MAX_UNION_BLOCKS:
				return {"status":"pending", "reason":"desired_union_capacity",
					"attemptedBlocks":union.size(), "maxBlocks":MAX_UNION_BLOCKS}
	var next_required := {}
	var mesh_members: Array[Dictionary] = []
	var required_order: Array[Vector3i] = []
	for source_id in planned_mesh_sources:
		for block: Vector3i in planned_mesh_sources[source_id]:
			mesh_members.append({"source":String(source_id), "block":block})
			if not next_required.has(block): required_order.append(block)
			next_required[block] = true
	if next_required != _required_mesh_blocks:
		_required_mesh_blocks = next_required
		_demand_revision += 1
		var closure: Array[Vector3i] = []
		for block: Vector3i in _required_mesh_blocks: closure.append(block)
		_sort_blocks(closure)
		var key_parts := PackedStringArray(["%d:%d" % [_consumer_id, _demand_revision]])
		for block in closure:
			key_parts.append("%d,%d,%d" % [block.x, block.y, block.z])
		_closure_token = ":".join(key_parts).sha256_text()
	_sources = planned_sources
	_mesh_sources = planned_mesh_sources
	_desired = union
	_desired_priority = priorities
	_accepted_plan = {"sources":_sources, "meshSources":_mesh_sources,
		"desired":_desired, "priority":_desired_priority,
		"required":_required_mesh_blocks, "sourceOrder":source_order,
		"dataMembers":data_members, "meshMembers":mesh_members,
		"desiredOrder":desired_order, "requiredOrder":required_order,
		"demandRevision":_demand_revision, "closureToken":_closure_token}
	_replacement.accept_current_plan(_required_mesh_blocks, _demand_revision, _closure_token)
	return {"status":"ready", "sourceCount":_sources.size(),
		"desiredDataBlocks":_desired.size(), "appliedDataBlocks":_applied.size(),
		"requiredMeshBlocks":_required_mesh_blocks.size(),
		"demandRevision":_demand_revision, "closureToken":_closure_token,
		"consumerId":_consumer_id}

func required_collision_mesh_blocks() -> Dictionary:
	if _consumer_id <= 0: return {"status":"failed", "reason":"planner_not_configured"}
	var blocks: Array[Vector3i] = []
	for block: Vector3i in _required_mesh_blocks: blocks.append(block)
	_sort_blocks(blocks)
	return {"status":"ready", "revision":_demand_revision,
		"closureToken":_closure_token, "blocks":blocks}

## Starts an incremental, revision-bound copy/sort of the accepted mesh demand.
## The returned blocks array is transferred to the caller; do not mutate it.
func begin_required_collision_mesh_blocks() -> Dictionary:
	if _consumer_id <= 0 or _demand_revision <= 0:
		return {"status":"pending", "reason":"mesh_demand_unset"}
	if _incremental_active:
		return {"status":"pending", "reason":"demand_replacement_active"}
	if _mesh_layout_builder.is_active() or _mesh_layout_builder.has_pending_retirement():
		return {"status":"pending", "reason":"mesh_snapshot_transaction_active",
			"token":_mesh_layout_builder.current_token()}
	_mesh_layout_lease = MESH_LAYOUT_LEASE.new()
	var required_order: Array = _accepted_plan.get("requiredOrder", [])
	if not _mesh_layout_lease.acquire(required_order, _demand_revision, _closure_token):
		_mesh_layout_lease = null
		return {"status":"failed", "reason":"mesh_snapshot_lease_failed"}
	var started: Dictionary = _mesh_layout_builder.begin_required_blocks(
		required_order, _demand_revision, _closure_token, _mesh_layout_lease)
	if started.get("status") != "pending":
		_mesh_layout_lease.release_after_drain()
		_mesh_layout_lease = null
	return started

func advance_required_collision_mesh_blocks() -> Dictionary:
	return _advance_mesh_snapshot("requiredBlocks")

func _advance_mesh_snapshot(expected_kind: String) -> Dictionary:
	if _mesh_layout_builder == null:
		return {"status":"failed", "reason":"planner_not_configured"}
	if _mesh_layout_builder.is_active() \
			and _mesh_layout_builder.current_kind() != expected_kind:
		return {"status":"failed", "reason":"mesh_snapshot_kind_mismatch"}
	_mesh_layout_builder.revoke_if_stale(
		_accepted_plan.get("requiredOrder", []), _demand_revision, _closure_token)
	var result: Dictionary = _mesh_layout_builder.advance()
	if result.get("status") == "ready" or result.get("status") == "failed":
		if _mesh_layout_lease != null:
			_mesh_layout_lease.release_after_drain()
		_mesh_layout_lease = null
	return result

func cancel_required_collision_mesh_blocks(token: int) -> Dictionary:
	if _mesh_layout_builder == null \
			or _mesh_layout_builder.current_kind() != "requiredBlocks":
		return {"status":"failed", "reason":"mesh_snapshot_token_stale"}
	var result: Dictionary = _mesh_layout_builder.cancel(token)
	if result.get("status") == "pending" and _mesh_layout_lease != null:
		_mesh_layout_lease.invalidate()
	return result

## Begins a bounded replacement transaction for the full logical mesh layout.
## The final `layout` value is transferred to the caller; do not mutate it.
func begin_collision_mesh_window_layout() -> Dictionary:
	if _consumer_id <= 0 or _demand_revision <= 0:
		return {"status":"pending", "reason":"mesh_demand_unset"}
	if _incremental_active:
		return {"status":"pending", "reason":"demand_replacement_active"}
	if _mesh_layout_builder.is_active() or _mesh_layout_builder.has_pending_retirement():
		return {"status":"pending", "reason":"mesh_layout_already_pending",
			"token":_mesh_layout_builder.current_token()}
	if not _mesh_window_layout.is_empty() \
			and _mesh_window_layout_revision != _demand_revision:
		_mesh_layout_builder.set_retired_layout(_mesh_window_layout)
		_mesh_window_layout = {}
		_mesh_window_layout_revision = -1
	_mesh_layout_lease = MESH_LAYOUT_LEASE.new()
	var required_order: Array = _accepted_plan.get("requiredOrder", [])
	if not _mesh_layout_lease.acquire(required_order, _demand_revision, _closure_token):
		_mesh_layout_lease = null
		return {"status":"failed", "reason":"mesh_layout_snapshot_lease_failed"}
	var started: Dictionary = _mesh_layout_builder.begin(required_order,
		_demand_revision, _closure_token, _mesh_layout_lease)
	if started.get("status") != "pending":
		_mesh_layout_lease.release_after_drain()
		_mesh_layout_lease = null
	return started

func advance_collision_mesh_window_layout() -> Dictionary:
	return _advance_mesh_snapshot("layout")

func cancel_collision_mesh_window_layout(token: int) -> Dictionary:
	if _mesh_layout_builder == null or _mesh_layout_builder.current_kind() != "layout":
		return {"status":"failed", "reason":"planner_not_configured"}
	var result: Dictionary = _mesh_layout_builder.cancel(token)
	if result.get("status") == "pending" and _mesh_layout_lease != null:
		_mesh_layout_lease.invalidate()
	return result

func collision_mesh_window_layout() -> Dictionary:
	if _consumer_id <= 0 or _demand_revision <= 0:
		return {"status":"pending", "reason":"mesh_demand_unset"}
	if _mesh_layout_builder.is_active() or _mesh_layout_builder.has_pending_retirement():
		return {"status":"pending", "reason":"mesh_layout_transaction_active"}
	if _mesh_window_layout_revision == _demand_revision:
		return _mesh_window_layout.duplicate(true)
	var buckets := {}
	for block: Vector3i in _required_mesh_blocks:
		var window := Vector3i(floori(float(block.x) / MESH_WINDOW_EDGE_BLOCKS),
			floori(float(block.y) / MESH_WINDOW_EDGE_BLOCKS),
			floori(float(block.z) / MESH_WINDOW_EDGE_BLOCKS))
		if not buckets.has(window): buckets[window] = []
		buckets[window].append(block)
	var ids: Array[Vector3i] = []
	for window: Vector3i in buckets: ids.append(window)
	_sort_blocks(ids)
	var windows: Array[Dictionary] = []
	for window: Vector3i in ids:
		var blocks: Array[Vector3i] = []
		for block: Vector3i in buckets[window]: blocks.append(block)
		_sort_blocks(blocks)
		if blocks.is_empty() or blocks.size() > MAX_MESH_WINDOW_BLOCKS:
			return {"status":"failed", "reason":"mesh_window_capacity_invalid"}
		var token_parts := PackedStringArray(["n3-spatial-window-v1",
			"%d,%d,%d" % [window.x, window.y, window.z]])
		for block: Vector3i in blocks:
			token_parts.append("%d,%d,%d" % [block.x, block.y, block.z])
		windows.append({"id":window, "blocks":blocks,
			"closureToken":":".join(token_parts).sha256_text()})
	_mesh_window_layout = {"status":"ready", "schema":"n3-mesh-window-layout/v1",
		"logicalDemandRevision":_demand_revision,
		"logicalClosureToken":_closure_token,
		"requiredBlockCount":_required_mesh_blocks.size(),
		"requiredBlocks":required_collision_mesh_blocks().blocks,
		"windowEdgeBlocks":MESH_WINDOW_EDGE_BLOCKS,
		"maxWindowBlocks":MAX_MESH_WINDOW_BLOCKS,
		"windowCount":windows.size(),
		"windows":windows}
	_mesh_window_layout_revision = _demand_revision
	return _mesh_window_layout.duplicate(true)

func next_delta() -> Dictionary:
	if _consumer_id <= 0:
		return {"status":"failed", "reason":"planner_not_configured"}
	if not _issued.is_empty():
		return _issued.duplicate(true)
	var additions: Array[Vector3i] = []
	var removals: Array[Vector3i] = []
	for block: Vector3i in _desired:
		if not _applied.has(block): additions.append(block)
	for block: Vector3i in _applied:
		if not _desired.has(block): removals.append(block)
	additions.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var a_priority := int(_desired_priority.get(a, 0))
		var b_priority := int(_desired_priority.get(b, 0))
		return a_priority > b_priority if a_priority != b_priority else _block_before(a, b))
	_sort_blocks(removals)
	if additions.is_empty() and removals.is_empty():
		return {"status":"idle", "desiredDataBlocks":_desired.size()}
	# Move both frontiers in one bounded operation. The publisher must accept
	# desired-set changes separately from physical unload/release completion.
	var add_limit := mini(additions.size(), MAX_DELTA_BLOCKS if removals.is_empty() else MAX_DELTA_BLOCKS / 2)
	var remove_limit := mini(removals.size(), MAX_DELTA_BLOCKS - add_limit)
	var add_batch: Array[Vector3i] = []
	var remove_batch: Array[Vector3i] = []
	for index in range(add_limit): add_batch.append(additions[index])
	for index in range(remove_limit): remove_batch.append(removals[index])
	_issued = {"status":"ready", "ticket":_next_ticket,
		"consumerId":_consumer_id, "addBlocks":add_batch, "removeBlocks":remove_batch}
	_next_ticket += 1
	return _issued.duplicate(true)

func acknowledge_delta(ticket: int, accepted: bool) -> Dictionary:
	if _issued.is_empty() or int(_issued.ticket) != ticket:
		return {"status":"failed", "reason":"stale_delta_ack"}
	if not accepted:
		return {"status":"pending", "reason":"delta_retry_retained", "ticket":ticket}
	for block: Vector3i in _issued.removeBlocks: _applied.erase(block)
	for block: Vector3i in _issued.addBlocks: _applied[block] = true
	_issued.clear()
	return {"status":"ready", "appliedDataBlocks":_applied.size()}

func diagnostics() -> Dictionary:
	return {"consumerId":_consumer_id, "sources":_sources.size(),
		"desiredDataBlocks":_desired.size(), "appliedDataBlocks":_applied.size(),
		"deltaAckPending":not _issued.is_empty(), "maxUnionBlocks":MAX_UNION_BLOCKS,
		"demandRevision":_demand_revision, "closureToken":_closure_token,
		"requiredMeshBlocks":_required_mesh_blocks.size()}

func source_ids() -> Array[String]:
	var ids: Array[String] = []
	for source_id in _sources: ids.append(String(source_id))
	ids.sort()
	return ids

func _add_viewer(target: Dictionary, mesh_target: Dictionary, kind: String, source_id: String,
		spec: Dictionary, bounds: Vector2i) -> Dictionary:
	var key := "viewer:%s:%s" % [kind, source_id]
	if target.has(key): return {"status":"failed", "reason":"duplicate_source_id"}
	var position_value = spec.get("position")
	if not position_value is Vector3: return {"status":"failed", "reason":"invalid_viewer_position"}
	var distance := int(spec.get("distance", -1))
	if distance < 0 or distance > MAX_VIEW_DISTANCE:
		return {"status":"failed", "reason":"invalid_view_distance"}
	var position: Vector3 = position_value
	var center := Vector2i(floori(position.x / CELL), floori(position.z / CELL))
	var blocks := _data_blocks_for_cell_box(center.x - distance, center.x + distance,
		center.y - distance, center.y + distance, bounds)
	target[key] = blocks
	mesh_target[key] = _data_blocks_for_cell_box(center.x - distance, center.x + distance,
		center.y - distance, center.y + distance, bounds, 0)
	return {"status":"ready"}

func _add_chunk(target: Dictionary, mesh_target: Dictionary, kind: String, chunk: Vector2i,
		bounds: Vector2i) -> Dictionary:
	var key := "chunk:%s:%d:%d" % [kind, chunk.x, chunk.y]
	if target.has(key): return {"status":"ready"}
	var first := chunk * GAME_CHUNK_CELLS
	var last := first + Vector2i.ONE * (GAME_CHUNK_CELLS - 1)
	target[key] = _data_blocks_for_cell_box(first.x, last.x, first.y, last.y, bounds)
	mesh_target[key] = _data_blocks_for_cell_box(first.x, last.x, first.y, last.y, bounds, 0)
	return {"status":"ready"}

func _data_blocks_for_cell_box(min_x: int, max_x: int, min_z: int, max_z: int,
		bounds: Vector2i, halo := 1) -> Dictionary:
	var blocks := {}
	for z in range(floori(float(min_z) / BLOCK_CELLS) - halo,
			floori(float(max_z) / BLOCK_CELLS) + halo + 1):
		for y in range(floori(float(bounds.x) / BLOCK_CELLS) - halo,
				floori(float(bounds.y) / BLOCK_CELLS) + halo + 1):
			for x in range(floori(float(min_x) / BLOCK_CELLS) - halo,
					floori(float(max_x) / BLOCK_CELLS) + halo + 1):
				blocks[Vector3i(x, y, z)] = true
	return blocks

static func _sort_blocks(blocks: Array[Vector3i]) -> void:
	blocks.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return _block_before(a, b))

static func _block_before(a: Vector3i, b: Vector3i) -> bool:
	return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x)))

static func _source_priority(source_id: String) -> int:
	if source_id.begins_with("chunk:foreground:"): return 120
	if source_id == "viewer:primary:primary": return 100
	if source_id.begins_with("chunk:retained:"): return 80
	if source_id.begins_with("viewer:handoff:"): return 70
	if source_id.begins_with("viewer:startup:"): return 60
	if source_id.begins_with("viewer:retained:"): return 50
	return 40
