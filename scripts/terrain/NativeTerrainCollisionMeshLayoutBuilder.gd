extends RefCounted
class_name NativeTerrainCollisionMeshLayoutBuilder

## Incremental, cancellable replacement builder for the logical mesh-window
## partition. Input required-order is borrowed from the accepted plan; callers
## must keep that plan stable until the transaction reaches a terminal state.
const WINDOW_EDGE_BLOCKS := 16
const MAX_WINDOW_BLOCKS := 4096
const MAX_REQUIRED_MESH_BLOCKS := 32768
const MAX_WORK_OPS_PER_ADVANCE := 256

var _job: Dictionary = {}
var _retired_layout: Dictionary = {}
var _retired_work: Dictionary = {}
var _next_token := 1

func begin(required_order: Array, revision: int, closure_token: String, lease) -> Dictionary:
	return _begin(required_order, revision, closure_token, lease, "layout")

func begin_required_blocks(required_order: Array, revision: int,
		closure_token: String, lease) -> Dictionary:
	return _begin(required_order, revision, closure_token, lease, "requiredBlocks")

func _begin(required_order: Array, revision: int, closure_token: String,
		lease, kind: String) -> Dictionary:
	if revision <= 0:
		return {"status":"failed", "reason":"mesh_demand_unset"}
	if lease == null or not lease.has_method("is_valid_for") \
			or not lease.is_valid_for(required_order, revision, closure_token):
		return {"status":"failed", "reason":"mesh_layout_snapshot_lease_required"}
	if not _job.is_empty() and String(_job.get("state", "")) != "transferred":
		if int(_job.get("revision", -1)) == revision \
				and String(_job.get("state", "")) != "retiring":
			return {"status":"pending", "reason":"mesh_layout_already_pending",
				"token":int(_job.get("token", 0))}
		return {"status":"pending", "reason":"mesh_layout_transaction_active",
			"token":int(_job.get("token", 0))}
	var token := _next_token
	_next_token += 1
	_start(required_order, revision, closure_token, lease, token, kind)
	return {"status":"pending", "reason":"mesh_layout_started" if kind == "layout" \
		else "required_mesh_blocks_started", "token":token,
		"maxWorkOpsPerAdvance":MAX_WORK_OPS_PER_ADVANCE}

func cancel(token: int) -> Dictionary:
	if _job.is_empty() or int(_job.get("token", 0)) != token \
			or String(_job.get("state", "")) == "transferred":
		return {"status":"failed", "reason":"mesh_layout_token_stale"}
	if String(_job.get("state", "")) != "retiring":
		_job["state"] = "retiring"
		_job["terminal"] = {"status":"ready", "cancelled":true, "token":token}
		_job["retireWindowIndex"] = _job.get("windows", []).size() - 1
		_job["retireBucketIndex"] = _job.get("windowIds", []).size() - 1
	return {"status":"pending", "reason":"mesh_layout_cancel_drain_pending",
		"token":token, "acceptedLayoutRetained":true}

func is_active() -> bool:
	return not _job.is_empty() and String(_job.get("state", "")) != "transferred"

func current_token() -> int:
	return int(_job.get("token", 0)) if is_active() else 0

func current_kind() -> String:
	return String(_job.get("kind", "")) if is_active() else ""

func is_valid_for(required_order: Array, revision: int, closure_token: String) -> bool:
	return is_active() and is_same(_job.get("input", []), required_order) \
		and int(_job.get("revision", -1)) == revision \
		and String(_job.get("closureToken", "")) == closure_token \
		and _job.get("lease") != null \
		and _job.lease.is_valid_for(required_order, revision, closure_token)

func revoke_if_stale(required_order: Array, revision: int, closure_token: String) -> Dictionary:
	if not is_active() or is_valid_for(required_order, revision, closure_token):
		return {"status":"ready", "valid":true}
	if String(_job.get("state", "")) != "retiring":
		_job["state"] = "retiring"
		_job["terminal"] = {"status":"failed", "reason":"mesh_layout_snapshot_revoked",
			"token":int(_job.get("token", 0))}
		_job["retireWindowIndex"] = _job.get("windows", []).size() - 1
		_job["retireBucketIndex"] = _job.get("windowIds", []).size() - 1
	return {"status":"pending", "reason":"mesh_layout_snapshot_revoked",
		"token":int(_job.get("token", 0))}

func has_pending_retirement() -> bool:
	return not _retired_layout.is_empty() or not _retired_work.is_empty()

func set_retired_layout(layout: Dictionary) -> void:
	if _retired_layout.is_empty(): _retired_layout = layout

func advance() -> Dictionary:
	var work_ops := 0
	var counts := {"inputBlocks":0, "sortComparisons":0, "sortReads":0,
		"sortWrites":0, "hashUpdates":0, "retiredEntries":0}
	if (_job.is_empty() or String(_job.get("state", "")) == "transferred") \
			and _retired_layout.is_empty() and _retired_work.is_empty():
		return _result({"status":"idle"}, work_ops, counts)
	while work_ops < MAX_WORK_OPS_PER_ADVANCE:
		if not _retired_layout.is_empty():
			_retire_one(_retired_layout)
			work_ops += 1
			counts.retiredEntries += 1
			if _retire_complete(_retired_layout): _retired_layout = {}
			continue
		if not _retired_work.is_empty():
			_retire_work_one()
			work_ops += 1
			counts.retiredEntries += 1
			if _retired_work_complete(): _retired_work = {}
			continue
		if _job.is_empty() or String(_job.get("state", "")) == "transferred":
			break
		if String(_job.get("state", "")) == "retiring":
			_retire_one(_job)
			work_ops += 1
			counts.retiredEntries += 1
			if _retire_complete(_job):
				var terminal: Dictionary = _job.get("terminal", {"status":"ready", "cancelled":true})
				_job = {}
				return _result(terminal, work_ops, counts)
			continue
		var step: Dictionary = _step(_job)
		if step.get("work", false):
			work_ops += 1
			var bucket := String(step.get("bucket", "inputBlocks"))
			counts[bucket] = int(counts[bucket]) + 1
		if step.get("status") == "failed":
			_job["state"] = "retiring"
			_job["terminal"] = {"status":"failed",
				"reason":String(step.get("reason", "mesh_layout_failed"))}
			_job["retireWindowIndex"] = _job.get("windows", []).size() - 1
			_job["retireBucketIndex"] = _job.get("windowIds", []).size() - 1
			continue
		if step.get("status") == "ready":
			var token := int(_job.token)
			if String(_job.kind) == "requiredBlocks":
				var required: Dictionary = _take_required_blocks()
				return _result({"status":"ready", "token":token,
					"revision":int(required.revision),
					"closureToken":String(required.closureToken),
					"blocks":required.blocks}, work_ops, counts)
			var layout: Dictionary = _take_layout()
			return _result({"status":"ready", "token":token,
				"revision":int(layout.logicalDemandRevision),
				"closureToken":String(layout.logicalClosureToken),
				"layout":layout}, work_ops, counts)
	if _job.is_empty() or String(_job.get("state", "")) == "transferred":
		return _result({"status":"idle"}, work_ops, counts)
	return _result({"status":"pending", "reason":"mesh_layout_work_pending",
		"token":int(_job.get("token", 0))}, work_ops, counts)

func _start(required_order: Array, revision: int, closure_token: String, lease,
		token: int, kind: String) -> void:
	_job = {"state":"building", "phase":"copy", "kind":kind, "token":token,
		"input":required_order, "revision":revision, "closureToken":closure_token,
		"lease":lease,
		"inputCursor":0, "requiredBlocks":[], "windowIds":[], "buckets":{},
		"windows":[], "windowCursor":0, "windowHash":null,
		"windowHashStarted":false, "windowHashCursor":0,
		"sortTarget":"", "sortSrc":[], "sortDst":[], "sortWidth":1,
		"sortLeft":0, "sortMid":0, "sortRight":0, "sortI":0,
		"sortJ":0, "sortK":0, "sortRunReady":false,
		"sortPendingWrite":false, "sortPendingValue":Vector3i.ZERO,
		"retireWindowIndex":-1, "retireBucketIndex":-1}

func _step(job: Dictionary) -> Dictionary:
	match String(job.phase):
		"copy": return _copy_step(job)
		"sortRequired", "sortIds", "sortWindowBlocks", "sortClear":
			return _sort_step(job)
		"windowRecords": return _window_record_step(job)
		"ready": return {"status":"ready"}
	return {"status":"failed", "reason":"mesh_layout_phase_invalid"}

func _copy_step(job: Dictionary) -> Dictionary:
	var source: Array = job.input
	var cursor := int(job.inputCursor)
	if cursor >= source.size():
		_begin_sort(job, "required")
		return {"status":"pending", "work":false}
	if String(job.kind) == "requiredBlocks" \
			and int(job.requiredBlocks.size()) >= MAX_REQUIRED_MESH_BLOCKS:
		return {"status":"failed", "reason":"mesh_window_capacity_invalid", "work":false}
	var block: Vector3i = source[cursor]
	if String(job.kind) == "requiredBlocks":
		var output: Array = job.requiredBlocks
		output.append(block)
		job.requiredBlocks = output
		job.inputCursor = cursor + 1
		return {"status":"pending", "work":true, "bucket":"inputBlocks"}
	var window := Vector3i(floori(float(block.x) / WINDOW_EDGE_BLOCKS),
		floori(float(block.y) / WINDOW_EDGE_BLOCKS),
		floori(float(block.z) / WINDOW_EDGE_BLOCKS))
	var buckets: Dictionary = job.buckets
	if not buckets.has(window):
		buckets[window] = []
		job.windowIds.append(window)
	var bucket: Array = buckets[window]
	if int(job.requiredBlocks.size()) >= MAX_REQUIRED_MESH_BLOCKS \
			or bucket.size() >= MAX_WINDOW_BLOCKS:
		return {"status":"failed", "reason":"mesh_window_capacity_invalid", "work":false}
	bucket.append(block)
	buckets[window] = bucket
	job.buckets = buckets
	job.requiredBlocks.append(block)
	job.inputCursor = cursor + 1
	return {"status":"pending", "work":true, "bucket":"inputBlocks"}

func _begin_sort(job: Dictionary, target: String) -> void:
	# At a sort boundary the prior destination must have been drained one slot
	# per operation. Its source is retained by a published plan or its target map.
	assert(job.get("sortDst", []).is_empty() and not job.get("sortPendingWrite", false))
	job.sortTarget = target
	job.sortSrc = job.requiredBlocks if target == "required" \
		else job.windowIds if target == "ids" else job.buckets[job.activeWindow]
	job.sortWidth = 1
	job.sortLeft = 0
	job.sortRunReady = false
	job.sortPendingWrite = false
	job.phase = "sortRequired" if target == "required" \
		else "sortIds" if target == "ids" else "sortWindowBlocks"

func _sort_step(job: Dictionary) -> Dictionary:
	var src: Array = job.sortSrc
	var dst: Array = job.sortDst
	if String(job.phase) == "sortClear":
		if dst.is_empty():
			job.phase = "sortRequired" if job.sortTarget == "required" \
				else "sortIds" if job.sortTarget == "ids" else "sortWindowBlocks"
			return {"status":"pending", "work":false}
		dst.pop_back()
		job.sortDst = dst
		return {"status":"pending", "work":true, "bucket":"sortWrites"}
	if bool(job.sortPendingWrite):
		dst.append(job.sortPendingValue)
		job.sortDst = dst
		job.sortK = int(job.sortK) + 1
		job.sortPendingWrite = false
		return {"status":"pending", "work":true, "bucket":"sortWrites"}
	if src.size() <= 1 or int(job.sortWidth) >= src.size():
		_finish_sort(job, src)
		return {"status":"pending", "work":false}
	if bool(job.sortRunReady) and int(job.sortK) >= int(job.sortRight):
		job.sortLeft = int(job.sortRight)
		job.sortRunReady = false
		if int(job.sortLeft) >= src.size():
			job.sortSrc = dst
			job.sortDst = src
			job.sortWidth = int(job.sortWidth) * 2
			job.sortLeft = 0
			job.phase = "sortClear"
			return {"status":"pending", "work":false}
	if not bool(job.sortRunReady):
		job.sortMid = mini(int(job.sortLeft) + int(job.sortWidth), src.size())
		job.sortRight = mini(int(job.sortLeft) + 2 * int(job.sortWidth), src.size())
		job.sortI = int(job.sortLeft)
		job.sortJ = int(job.sortMid)
		job.sortK = int(job.sortLeft)
		job.sortRunReady = true
	var i := int(job.sortI)
	var j := int(job.sortJ)
	var value: Vector3i
	var compared := false
	if i < int(job.sortMid) and j < int(job.sortRight):
		compared = true
		if _block_before(src[i], src[j]):
			value = src[i]
			i += 1
		else:
			value = src[j]
			j += 1
	elif i < int(job.sortMid):
		value = src[i]
		i += 1
	else:
		value = src[j]
		j += 1
	job.sortPendingValue = value
	job.sortPendingWrite = true
	job.sortI = i
	job.sortJ = j
	return {"status":"pending", "work":true,
		"bucket":"sortComparisons" if compared else "sortReads"}

func _finish_sort(job: Dictionary, sorted: Array) -> void:
	match String(job.sortTarget):
		"required":
			job.requiredBlocks = sorted
			if String(job.kind) == "requiredBlocks":
				job.phase = "ready"
			else:
				_begin_sort(job, "ids")
		"ids":
			job.windowIds = sorted
			job.windowCursor = 0
			if sorted.is_empty():
				job.phase = "ready"
			else:
				job.activeWindow = sorted[0]
				_begin_sort(job, "windowBlocks")
		"windowBlocks":
			var buckets: Dictionary = job.buckets
			buckets[job.activeWindow] = sorted
			job.buckets = buckets
			job.phase = "windowRecords"

func _window_record_step(job: Dictionary) -> Dictionary:
	var ids: Array = job.windowIds
	var index := int(job.windowCursor)
	if index >= ids.size():
		job.phase = "ready"
		return {"status":"pending", "work":false}
	var window: Vector3i = ids[index]
	var buckets: Dictionary = job.buckets
	var blocks: Array = buckets[window]
	if not bool(job.windowHashStarted):
		var context := HashingContext.new()
		context.start(HashingContext.HASH_SHA256)
		context.update(("n3-spatial-window-v1:%d,%d,%d" %
			[window.x, window.y, window.z]).to_utf8_buffer())
		job.windowHash = context
		job.windowHashStarted = true
		job.windowHashCursor = 0
		return {"status":"pending", "work":true, "bucket":"hashUpdates"}
	var hash_cursor := int(job.windowHashCursor)
	if hash_cursor < blocks.size():
		var block: Vector3i = blocks[hash_cursor]
		var context: HashingContext = job.windowHash
		context.update((":%d,%d,%d" % [block.x, block.y, block.z]).to_utf8_buffer())
		job.windowHash = context
		job.windowHashCursor = hash_cursor + 1
		return {"status":"pending", "work":true, "bucket":"hashUpdates"}
	var context: HashingContext = job.windowHash
	var windows: Array = job.windows
	windows.append({"id":window, "blocks":blocks,
		"closureToken":context.finish().hex_encode()})
	job.windows = windows
	job.windowCursor = index + 1
	job.windowHash = null
	job.windowHashStarted = false
	job.windowHashCursor = 0
	if int(job.windowCursor) < ids.size():
		job.activeWindow = ids[int(job.windowCursor)]
		_begin_sort(job, "windowBlocks")
	return {"status":"pending", "work":true, "bucket":"hashUpdates"}

func _take_layout() -> Dictionary:
	var layout := {"status":"ready", "schema":"n3-mesh-window-layout/v1",
		"logicalDemandRevision":int(_job.revision),
		"logicalClosureToken":String(_job.closureToken),
		"requiredBlockCount":_job.requiredBlocks.size(),
		"requiredBlocks":_job.requiredBlocks,
		"windowEdgeBlocks":WINDOW_EDGE_BLOCKS,
		"maxWindowBlocks":MAX_WINDOW_BLOCKS,
		"windowCount":_job.windows.size(), "windows":_job.windows}
	var output_alias := String(_job.sortTarget) == "required" \
		or String(_job.sortTarget) == "ids" \
		or (String(_job.sortTarget) == "windowBlocks"
			and is_same(_job.sortSrc, _job.buckets.get(_job.get("activeWindow"), [])))
	_retired_work = {"buckets":_job.buckets, "windowIds":_job.windowIds,
		"retireBucketIndex":_job.windowIds.size() - 1,
		"sortSrc":[] if output_alias else _job.sortSrc,
		"sortDst":_job.sortDst}
	_job = {"state":"transferred"}
	return layout

func _take_required_blocks() -> Dictionary:
	var result := {"revision":int(_job.revision),
		"closureToken":String(_job.closureToken),
		"blocks":_job.requiredBlocks}
	_retired_work = {}
	_job = {"state":"transferred"}
	return result

func _retire_work_one() -> void:
	var buckets: Dictionary = _retired_work.get("buckets", {})
	var ids: Array = _retired_work.get("windowIds", [])
	var bucket_index := int(_retired_work.get("retireBucketIndex", ids.size() - 1))
	if bucket_index >= 0:
		buckets.erase(ids[bucket_index])
		_retired_work["buckets"] = buckets
		_retired_work["retireBucketIndex"] = bucket_index - 1
		return
	if not ids.is_empty():
		ids.pop_back()
		_retired_work["windowIds"] = ids
		return
	var scratch: Array = _retired_work.get("sortDst", [])
	if not scratch.is_empty():
		scratch.pop_back()
		_retired_work["sortDst"] = scratch
		return
	scratch = _retired_work.get("sortSrc", [])
	if not scratch.is_empty():
		scratch.pop_back()
		_retired_work["sortSrc"] = scratch

func _retired_work_complete() -> bool:
	return _retired_work.get("buckets", {}).is_empty() \
		and _retired_work.get("windowIds", []).is_empty() \
		and _retired_work.get("sortDst", []).is_empty() \
		and _retired_work.get("sortSrc", []).is_empty()

func _retire_one(plan: Dictionary) -> void:
	var blocks: Array = plan.get("requiredBlocks", [])
	if not blocks.is_empty():
		blocks.pop_back()
		plan.requiredBlocks = blocks
		return
	var windows: Array = plan.get("windows", [])
	if not windows.is_empty():
		var window_index := int(plan.get("retireWindowIndex", windows.size() - 1))
		var record: Dictionary = windows[window_index]
		var window_blocks: Array = record.get("blocks", [])
		if not window_blocks.is_empty():
			window_blocks.pop_back()
			record.blocks = window_blocks
			windows[window_index] = record
			plan.windows = windows
			return
		windows.pop_back()
		plan.windows = windows
		var buckets: Dictionary = plan.get("buckets", {})
		buckets.erase(record.get("id"))
		plan.buckets = buckets
		plan.retireWindowIndex = window_index - 1
		return
	var buckets: Dictionary = plan.get("buckets", {})
	var ids: Array = plan.get("windowIds", [])
	var bucket_index := int(plan.get("retireBucketIndex", ids.size() - 1))
	if bucket_index >= 0:
		var window: Vector3i = ids[bucket_index]
		var bucket: Array = buckets.get(window, [])
		if not bucket.is_empty():
			bucket.pop_back()
			buckets[window] = bucket
			plan.buckets = buckets
			return
		buckets.erase(window)
		plan.buckets = buckets
		plan.retireBucketIndex = bucket_index - 1
		return
	if not ids.is_empty():
		ids.pop_back()
		plan.windowIds = ids
		return
	var scratch: Array = plan.get("sortSrc", [])
	if not scratch.is_empty():
		scratch.pop_back()
		plan.sortSrc = scratch
		return
	scratch = plan.get("sortDst", [])
	if not scratch.is_empty():
		scratch.pop_back()
		plan.sortDst = scratch

func _retire_complete(plan: Dictionary) -> bool:
	return plan.get("requiredBlocks", []).is_empty() \
		and plan.get("windows", []).is_empty() \
		and plan.get("buckets", {}).is_empty() \
		and plan.get("windowIds", []).is_empty() \
		and plan.get("sortSrc", []).is_empty() \
		and plan.get("sortDst", []).is_empty()

func _result(value: Dictionary, work_ops: int, counts: Dictionary) -> Dictionary:
	var output := value.duplicate(false)
	output["workOps"] = work_ops
	output["maxWorkOps"] = MAX_WORK_OPS_PER_ADVANCE
	output["workBreakdown"] = counts.duplicate(false)
	return output

func _block_before(a: Vector3i, b: Vector3i) -> bool:
	return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x)))
