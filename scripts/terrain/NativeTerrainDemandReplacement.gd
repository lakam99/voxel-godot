extends RefCounted
class_name NativeTerrainDemandReplacement

## Bounded candidate construction and retirement for NativeTerrainDemandPlanner.
## Every advance consumes fixed O(1) work units; the candidate never aliases an
## accepted plan and caller inputs are protected by a producer-issued lease.
const CELL := 1.35
const BLOCK_CELLS := 16
const GAME_CHUNK_CELLS := 28
const MAX_VIEW_DISTANCE := 128
const MAX_UNION_BLOCKS := 32768
const MAX_SOURCE_MEMBERSHIPS := 131072
const MAX_WORK_OPS_PER_ADVANCE := 256

var _consumer_id := 0
var _accepted_required: Dictionary = {}
var _accepted_revision := 0
var _accepted_closure_token := ""
var _job: Dictionary = {}
var _retired_plan: Dictionary = {}
var _next_token := 1

func setup(consumer_id: int) -> Dictionary:
	if consumer_id <= 0 or _consumer_id != 0:
		return {"status":"failed", "reason":"invalid_consumer_owner"}
	_consumer_id = consumer_id
	return {"status":"ready"}

func begin(primary: Dictionary, other_viewers: Array[Dictionary],
		retained_chunks: Array[Vector2i], foreground_chunks: Array[Vector2i],
		vertical_bounds: Vector2i, lease, request_revision: int) -> Dictionary:
	if _consumer_id <= 0: return {"status":"failed", "reason":"replacement_not_configured"}
	if lease == null or not lease.has_method("is_valid_for") \
			or not lease.is_valid_for(primary, other_viewers, retained_chunks,
				foreground_chunks, vertical_bounds, request_revision):
		return {"status":"failed", "reason":"demand_request_lease_required"}
	if vertical_bounds.x > vertical_bounds.y or vertical_bounds.y - vertical_bounds.x > 256:
		return {"status":"failed", "reason":"invalid_vertical_bounds"}
	if other_viewers.size() > 4096 or retained_chunks.size() > 4096 \
			or foreground_chunks.size() > 4096:
		return {"status":"failed", "reason":"demand_source_count_capacity"}
	var request := {"primary":primary, "otherViewers":other_viewers,
		"retainedChunks":retained_chunks, "foregroundChunks":foreground_chunks,
		"verticalBounds":vertical_bounds, "lease":lease,
		"requestRevision":request_revision}
	if String(_job.get("state", "")) == "transferred": _job = {}
	var was_active := not _job.is_empty()
	var superseded_token := int(_job.get("token", 0))
	if was_active:
		_job["state"] = "retiring"
		_job["terminal"] = {"status":"ready", "superseded":true,
			"token":superseded_token}
		_job["retirePhase"] = "dataMembers"
	var token := _next_token
	_next_token += 1
	_job["queuedRequest"] = request
	_job["queuedToken"] = token
	if not was_active:
		_activate_queued()
	return {"status":"pending",
		"reason":"replacement_supersede_drain_pending" if was_active else "replacement_started",
		"token":token, "supersededToken":superseded_token,
		"maxWorkOpsPerAdvance":MAX_WORK_OPS_PER_ADVANCE}

func cancel(token: int) -> Dictionary:
	if _job.is_empty(): return {"status":"failed", "reason":"replacement_token_stale"}
	if int(_job.get("queuedToken", 0)) == token and _job.has("queuedRequest"):
		_job.erase("queuedRequest")
		_job.erase("queuedToken")
		if String(_job.get("state", "")) == "retiring":
			_job["terminal"] = {"status":"ready", "cancelled":true, "token":token}
		return {"status":"ready", "cancelled":true, "token":token,
			"acceptedPlanRetained":true}
	if int(_job.get("token", 0)) != token:
		return {"status":"failed", "reason":"replacement_token_stale"}
	if String(_job.get("state", "")) != "retiring":
		_job["state"] = "retiring"
		_job["retirePhase"] = "dataMembers"
		_job["terminal"] = {"status":"ready", "cancelled":true, "token":token}
	return {"status":"pending", "reason":"replacement_cancel_drain_pending",
		"token":token, "acceptedPlanRetained":true}

func set_retirement_plan(plan: Dictionary) -> void:
	if _retired_plan.is_empty(): _retired_plan = plan

func has_pending_retirement() -> bool:
	return not _retired_plan.is_empty()

func advance() -> Dictionary:
	var work_ops := 0
	var counts := {"sourceSpecs":0, "footprintBlocks":0, "unionEntries":0,
		"meshFootprintBlocks":0, "meshUnionEntries":0, "setComparisons":0,
		"sortComparisons":0, "sortReads":0, "sortWrites":0, "hashEntries":0,
		"retiredEntries":0}
	if (_job.is_empty() or String(_job.get("state", "")) == "transferred") \
			and _retired_plan.is_empty():
		return _result({"status":"idle"}, work_ops, counts)
	while work_ops < MAX_WORK_OPS_PER_ADVANCE:
		if not _retired_plan.is_empty():
			_retire_one(_retired_plan)
			work_ops += 1
			counts.retiredEntries += 1
			if _retire_complete(_retired_plan): _retired_plan = {}
			continue
		if _job.is_empty() or String(_job.get("state", "")) == "transferred":
			break
		if String(_job.get("state", "")) == "retiring":
			_retire_one(_job)
			work_ops += 1
			counts.retiredEntries += 1
			if _retire_complete(_job):
				var terminal: Dictionary = _job.get("terminal", {"status":"ready", "cancelled":true})
				var queued: Dictionary = _job.get("queuedRequest", {})
				var queued_token := int(_job.get("queuedToken", 0))
				_job = {}
				if not queued.is_empty():
					_start_job(queued, queued_token)
					continue
				return _result(terminal, work_ops, counts)
			continue
		if String(_job.get("state", "")) == "capacity":
			return _capacity_result(work_ops, counts)
		if not _request_valid(_job):
			_job["state"] = "retiring"
			_job["retirePhase"] = "dataMembers"
			_job["terminal"] = {"status":"failed", "reason":"demand_request_lease_revoked"}
			continue
		var step: Dictionary = _step(_job)
		if step.get("work", false):
			work_ops += 1
			var bucket := String(step.get("bucket", "sourceSpecs"))
			counts[bucket] = int(counts[bucket]) + 1
		if step.get("status") == "failed":
			_job["state"] = "retiring"
			_job["retirePhase"] = "dataMembers"
			_job["terminal"] = {"status":"failed",
				"reason":String(step.get("reason", "demand_replacement_failed"))}
			continue
		if step.get("status") == "capacity":
			_job["state"] = "capacity"
			_job["capacityReason"] = String(step.get("reason", "desired_union_capacity"))
			return _capacity_result(work_ops, counts)
		if step.get("status") == "ready":
			var ready_token := int(_job.token)
			var plan: Dictionary = _take_candidate_plan()
			return _result({"status":"ready", "token":ready_token,
				"plan":plan, "demandRevision":int(plan.demandRevision),
				"closureToken":String(plan.closureToken)}, work_ops, counts)
	if _job.is_empty() or String(_job.get("state", "")) == "transferred":
		return _result({"status":"idle"}, work_ops, counts)
	return _result({"status":"pending", "reason":"replacement_work_pending",
		"token":int(_job.get("token", 0))}, work_ops, counts)

func accept_current_plan(required: Dictionary, revision: int, closure_token: String) -> void:
	_accepted_required = required
	_accepted_revision = revision
	_accepted_closure_token = closure_token

func retire_plan_step(plan: Dictionary) -> bool:
	_retire_one(plan)
	return _retire_complete(plan)

func _activate_queued() -> void:
	if _job.is_empty() or not _job.has("queuedRequest"): return
	var request: Dictionary = _job.queuedRequest
	var token := int(_job.queuedToken)
	_start_job(request, token)

func _start_job(request: Dictionary, token: int) -> void:
	_job = {"state":"building", "phase":"nextSource", "token":token,
		"request":request, "sourcePhase":0, "viewerIndex":0,
		"retainedIndex":0, "foregroundIndex":0,
		"sources":{}, "meshSources":{}, "desired":{}, "priority":{},
		"required":{}, "sourceOrder":[], "dataMembers":[], "meshMembers":[],
		"desiredOrder":[], "requiredOrder":[], "sourceMemberships":0,
		"unionCursor":0, "meshUnionCursor":0,
		"setCompareCursor":0, "setChanged":false,
		"sortSrc":[], "sortDst":[], "sortWidth":1, "sortLeft":0,
		"sortMid":0, "sortRight":0, "sortI":0, "sortJ":0,
		"sortK":0, "sortRunReady":false, "sortPendingWrite":false,
		"sortPendingValue":Vector3i.ZERO, "hashContext":null,
		"hashCursor":0, "newRevision":_accepted_revision,
		"newClosureToken":_accepted_closure_token,
		"terminal":{}}

func _request_valid(job: Dictionary) -> bool:
	var request: Dictionary = job.get("request", {})
	var lease = request.get("lease")
	return lease != null and lease.has_method("is_valid_for") \
		and lease.is_valid_for(request.get("primary", {}),
			request.get("otherViewers", []), request.get("retainedChunks", []),
			request.get("foregroundChunks", []),
			request.get("verticalBounds", Vector2i.ZERO),
			int(request.get("requestRevision", -1)))

func _step(job: Dictionary) -> Dictionary:
	match String(job.phase):
		"nextSource": return _next_source(job)
		"dataFootprint": return _footprint_step(job, false)
		"dataUnion": return _union_step(job, false)
		"meshFootprint": return _footprint_step(job, true)
		"meshUnion": return _union_step(job, true)
		"compareSet": return _compare_step(job)
		"sort", "sortClear": return _sort_step(job)
		"hash": return _hash_step(job)
		"ready": return {"status":"ready"}
	return {"status":"failed", "reason":"replacement_phase_invalid"}

func _next_source(job: Dictionary) -> Dictionary:
	var request: Dictionary = job.request
	var kind := ""
	var source_id := ""
	var key := ""
	var spec = null
	var is_chunk := false
	var phase := int(job.sourcePhase)
	while true:
		if phase == 0:
			job.sourcePhase = 1
			if not (request.primary as Dictionary).is_empty():
				kind = "primary"
				source_id = "primary"
				key = "viewer:primary:primary"
				spec = request.primary
				break
			phase = 1
		if phase == 1:
			var viewers: Array = request.otherViewers
			if int(job.viewerIndex) < viewers.size():
				spec = viewers[int(job.viewerIndex)]
				job.viewerIndex = int(job.viewerIndex) + 1
				kind = String(spec.get("kind", "")) if spec is Dictionary else ""
				source_id = String(spec.get("id", "")) if spec is Dictionary else ""
				if not ["startup", "secondary", "handoff", "retained"].has(kind):
					return {"status":"failed", "reason":"invalid_viewer_kind", "work":true}
				if source_id.is_empty():
					return {"status":"failed", "reason":"missing_viewer_id", "work":true}
				key = "viewer:%s:%s" % [kind, source_id]
				break
			phase = 2
		if phase == 2:
			var chunks: Array = request.retainedChunks
			if int(job.retainedIndex) < chunks.size():
				spec = chunks[int(job.retainedIndex)]
				job.retainedIndex = int(job.retainedIndex) + 1
				if not spec is Vector2i:
					return {"status":"failed", "reason":"invalid_retained_chunk", "work":true}
				kind = "retained"
				source_id = "%d:%d" % [spec.x, spec.y]
				key = "chunk:retained:%s" % source_id
				is_chunk = true
				break
			phase = 3
		if phase == 3:
			var chunks: Array = request.foregroundChunks
			if int(job.foregroundIndex) < chunks.size():
				spec = chunks[int(job.foregroundIndex)]
				job.foregroundIndex = int(job.foregroundIndex) + 1
				if not spec is Vector2i:
					return {"status":"failed", "reason":"invalid_foreground_chunk", "work":true}
				kind = "foreground"
				source_id = "%d:%d" % [spec.x, spec.y]
				key = "chunk:foreground:%s" % source_id
				is_chunk = true
				break
			phase = 4
		job.sourcePhase = 4
		job.phase = "compareSet"
		job.setChanged = job.required.size() != _accepted_required.size()
		if job.setChanged:
			_begin_sort(job)
		return {"status":"pending", "work":false}
	if job.sources.has(key):
		if is_chunk: return {"status":"pending", "work":true, "bucket":"sourceSpecs"}
		return {"status":"failed", "reason":"duplicate_source_id", "work":true}
	var ranges: Dictionary = _ranges(spec, is_chunk, request.verticalBounds)
	if ranges.get("status") != "ready":
		return {"status":"failed", "reason":String(ranges.get("reason", "demand_source_invalid")), "work":true}
	job.sources[key] = {}
	job.meshSources[key] = {}
	job.sourceOrder.append(key)
	job.currentSource = key
	job.currentPriority = _source_priority(key)
	job.ranges = ranges
	job.cursor = Vector3i(ranges.dataMinX, ranges.dataMinY, ranges.dataMinZ)
	job.dataMemberStart = job.dataMembers.size()
	job.phase = "dataFootprint"
	return {"status":"pending", "work":true, "bucket":"sourceSpecs"}

func _ranges(spec, is_chunk: bool, bounds: Vector2i) -> Dictionary:
	var min_x: int
	var max_x: int
	var min_z: int
	var max_z: int
	if is_chunk:
		var chunk: Vector2i = spec
		var first := chunk * GAME_CHUNK_CELLS
		var last := first + Vector2i.ONE * (GAME_CHUNK_CELLS - 1)
		min_x = first.x
		max_x = last.x
		min_z = first.y
		max_z = last.y
	else:
		if not spec is Dictionary or not spec.get("position") is Vector3:
			return {"status":"failed", "reason":"invalid_viewer_position"}
		var distance := int(spec.get("distance", -1))
		if distance < 0 or distance > MAX_VIEW_DISTANCE:
			return {"status":"failed", "reason":"invalid_view_distance"}
		var position: Vector3 = spec.position
		if not is_finite(position.x) or not is_finite(position.z):
			return {"status":"failed", "reason":"invalid_viewer_position"}
		var center := Vector2i(floori(position.x / CELL), floori(position.z / CELL))
		min_x = center.x - distance
		max_x = center.x + distance
		min_z = center.y - distance
		max_z = center.y + distance
	return {"status":"ready",
		"dataMinX":floori(float(min_x) / BLOCK_CELLS) - 1,
		"dataMaxX":floori(float(max_x) / BLOCK_CELLS) + 1,
		"dataMinY":floori(float(bounds.x) / BLOCK_CELLS) - 1,
		"dataMaxY":floori(float(bounds.y) / BLOCK_CELLS) + 1,
		"dataMinZ":floori(float(min_z) / BLOCK_CELLS) - 1,
		"dataMaxZ":floori(float(max_z) / BLOCK_CELLS) + 1,
		"meshMinX":floori(float(min_x) / BLOCK_CELLS),
		"meshMaxX":floori(float(max_x) / BLOCK_CELLS),
		"meshMinY":floori(float(bounds.x) / BLOCK_CELLS),
		"meshMaxY":floori(float(bounds.y) / BLOCK_CELLS),
		"meshMinZ":floori(float(min_z) / BLOCK_CELLS),
		"meshMaxZ":floori(float(max_z) / BLOCK_CELLS)}

func _footprint_step(job: Dictionary, mesh: bool) -> Dictionary:
	var prefix := "mesh" if mesh else "data"
	var ranges: Dictionary = job.ranges
	var cursor: Vector3i = job.cursor
	var max_x := int(ranges.get(prefix + "MaxX", -1))
	var max_y := int(ranges.get(prefix + "MaxY", -1))
	var max_z := int(ranges.get(prefix + "MaxZ", -1))
	if cursor.z > max_z:
		if mesh:
			job.meshUnionCursor = int(job.meshMemberStart)
			job.phase = "meshUnion"
		else:
			job.dataUnionCursor = int(job.dataMemberStart)
			job.dataUnionEnd = job.dataMembers.size()
			job.phase = "dataUnion"
		return {"status":"pending", "work":false}
	if cursor.x > max_x:
		cursor.x = int(ranges.get(prefix + "MinX", 0))
		if cursor.y < max_y:
			cursor.y += 1
		else:
			cursor.y = int(ranges.get(prefix + "MinY", 0))
			cursor.z += 1
		job.cursor = cursor
		return {"status":"pending", "work":true,
			"bucket":"meshFootprintBlocks" if mesh else "footprintBlocks"}
	var block := cursor
	var maps: Dictionary = job.meshSources if mesh else job.sources
	var members: Array = job.meshMembers if mesh else job.dataMembers
	if not maps[job.currentSource].has(block):
		if int(job.sourceMemberships) >= MAX_SOURCE_MEMBERSHIPS:
			return {"status":"capacity", "reason":"desired_source_membership_capacity", "work":false}
		maps[job.currentSource][block] = true
		members.append({"source":job.currentSource, "block":block})
		job.sourceMemberships = int(job.sourceMemberships) + 1
	cursor.x += 1
	job.cursor = cursor
	if mesh: job.meshSources = maps
	else: job.sources = maps
	return {"status":"pending", "work":true,
		"bucket":"meshFootprintBlocks" if mesh else "footprintBlocks"}

func _union_step(job: Dictionary, mesh: bool) -> Dictionary:
	var members: Array = job.meshMembers if mesh else job.dataMembers
	var cursor_name := "meshUnionCursor" if mesh else "dataUnionCursor"
	var end_name := "meshUnionEnd" if mesh else "dataUnionEnd"
	if not job.has(end_name): job[end_name] = members.size()
	var cursor := int(job.get(cursor_name, 0))
	if cursor >= int(job[end_name]):
		job.erase(end_name)
		if mesh:
			job.meshUnionCursor = job.meshMembers.size()
			job.phase = "nextSource"
		else:
			job.cursor = Vector3i(job.ranges.meshMinX, job.ranges.meshMinY, job.ranges.meshMinZ)
			job.meshMemberStart = job.meshMembers.size()
			job.phase = "meshFootprint"
		return {"status":"pending", "work":false}
	var record: Dictionary = members[cursor]
	var block: Vector3i = record.block
	if mesh:
		if not job.required.has(block):
			job.required[block] = true
			job.requiredOrder.append(block)
	else:
		if not job.desired.has(block):
			if job.desired.size() >= MAX_UNION_BLOCKS:
				return {"status":"capacity", "reason":"desired_union_capacity", "work":true,
					"bucket":"unionEntries"}
			job.desired[block] = true
			job.desiredOrder.append(block)
		job.priority[block] = maxi(int(job.priority.get(block, 0)),
			_source_priority(String(record.source)))
	cursor += 1
	job[cursor_name] = cursor
	return {"status":"pending", "work":true,
		"bucket":"meshUnionEntries" if mesh else "unionEntries"}

func _compare_step(job: Dictionary) -> Dictionary:
	if int(job.setCompareCursor) >= job.requiredOrder.size():
		job.newRevision = _accepted_revision
		job.newClosureToken = _accepted_closure_token
		job.phase = "ready"
		return {"status":"pending", "work":false}
	var block: Vector3i = job.requiredOrder[int(job.setCompareCursor)]
	if not _accepted_required.has(block):
		job.setChanged = true
		_begin_sort(job)
	else:
		job.setCompareCursor = int(job.setCompareCursor) + 1
	return {"status":"pending", "work":true, "bucket":"setComparisons"}

func _begin_sort(job: Dictionary) -> void:
	job.newRevision = _accepted_revision + 1
	job.sortSrc = job.requiredOrder
	job.sortDst = []
	job.sortWidth = 1
	job.sortLeft = 0
	job.sortRunReady = false
	job.sortPendingWrite = false
	job.phase = "sort"

func _sort_step(job: Dictionary) -> Dictionary:
	var src: Array = job.sortSrc
	var dst: Array = job.sortDst
	if String(job.phase) == "sortClear":
		if dst.is_empty():
			job.phase = "sort"
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
		job.requiredOrder = src
		var context := HashingContext.new()
		context.start(HashingContext.HASH_SHA256)
		context.update(("%d:%d" % [_consumer_id, int(job.newRevision)]).to_utf8_buffer())
		job.hashContext = context
		job.hashCursor = 0
		job.phase = "hash"
		return {"status":"pending", "work":true, "bucket":"sortWrites"}
	if bool(job.sortRunReady) and int(job.sortK) >= int(job.sortRight):
		job.sortLeft = int(job.sortRight)
		job.sortRunReady = false
		if int(job.sortLeft) >= src.size():
			job.sortSrc = dst
			job.requiredOrder = dst
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

func _hash_step(job: Dictionary) -> Dictionary:
	var blocks: Array = job.requiredOrder
	if int(job.hashCursor) >= blocks.size():
		var context: HashingContext = job.hashContext
		job.newClosureToken = context.finish().hex_encode()
		job.phase = "ready"
		return {"status":"pending", "work":true, "bucket":"hashEntries"}
	var block: Vector3i = blocks[int(job.hashCursor)]
	var context: HashingContext = job.hashContext
	context.update((":%d,%d,%d" % [block.x, block.y, block.z]).to_utf8_buffer())
	job.hashContext = context
	job.hashCursor = int(job.hashCursor) + 1
	return {"status":"pending", "work":true, "bucket":"hashEntries"}

func _take_candidate_plan() -> Dictionary:
	var plan := {"sources":_job.sources, "meshSources":_job.meshSources,
		"desired":_job.desired, "priority":_job.priority, "required":_job.required,
		"sourceOrder":_job.sourceOrder, "dataMembers":_job.dataMembers,
		"meshMembers":_job.meshMembers, "desiredOrder":_job.desiredOrder,
		"requiredOrder":_job.requiredOrder, "demandRevision":_job.newRevision,
		"closureToken":_job.newClosureToken}
	_job = {"state":"transferred"}
	return plan

func _retire_one(plan: Dictionary) -> void:
	var records: Array = plan.get("dataMembers", [])
	if not records.is_empty():
		var record: Dictionary = records.pop_back()
		var sources: Dictionary = plan.get("sources", {})
		if sources.has(record.source): sources[record.source].erase(record.block)
		plan.dataMembers = records
		return
	records = plan.get("meshMembers", [])
	if not records.is_empty():
		var record: Dictionary = records.pop_back()
		var sources: Dictionary = plan.get("meshSources", {})
		if sources.has(record.source): sources[record.source].erase(record.block)
		plan.meshMembers = records
		return
	var ordered: Array = plan.get("desiredOrder", [])
	if not ordered.is_empty():
		var block: Vector3i = ordered.pop_back()
		plan.get("desired", {}).erase(block)
		plan.get("priority", {}).erase(block)
		plan.desiredOrder = ordered
		return
	ordered = plan.get("requiredOrder", [])
	if not ordered.is_empty():
		var block: Vector3i = ordered.pop_back()
		plan.get("required", {}).erase(block)
		plan.requiredOrder = ordered
		return
	ordered = plan.get("sourceOrder", [])
	if not ordered.is_empty():
		var source_id := String(ordered.pop_back())
		plan.get("sources", {}).erase(source_id)
		plan.get("meshSources", {}).erase(source_id)
		plan.sourceOrder = ordered
		return
	ordered = plan.get("sortSrc", [])
	if not ordered.is_empty():
		ordered.pop_back()
		plan.sortSrc = ordered
		return
	ordered = plan.get("sortDst", [])
	if not ordered.is_empty():
		ordered.pop_back()
		plan.sortDst = ordered

func _retire_complete(plan: Dictionary) -> bool:
	return plan.get("dataMembers", []).is_empty() \
		and plan.get("meshMembers", []).is_empty() \
		and plan.get("desiredOrder", []).is_empty() \
		and plan.get("requiredOrder", []).is_empty() \
		and plan.get("sourceOrder", []).is_empty() \
		and plan.get("sortSrc", []).is_empty() \
		and plan.get("sortDst", []).is_empty()

func _capacity_result(work_ops: int, counts: Dictionary) -> Dictionary:
	return _result({"status":"pending",
		"reason":String(_job.get("capacityReason", "desired_union_capacity")),
		"retryable":true, "token":int(_job.get("token", 0)),
		"attemptedBlocks":int(_job.get("desired", {}).size()) + 1,
		"maxBlocks":MAX_UNION_BLOCKS, "acceptedPlanRetained":true}, work_ops, counts)

func _result(result: Dictionary, work_ops: int, counts: Dictionary) -> Dictionary:
	var output := result.duplicate(false)
	output["workOps"] = work_ops
	output["maxWorkOps"] = MAX_WORK_OPS_PER_ADVANCE
	output["workBreakdown"] = counts.duplicate(true)
	return output

func _source_priority(source_id: String) -> int:
	if source_id.begins_with("chunk:foreground:"): return 120
	if source_id == "viewer:primary:primary": return 100
	if source_id.begins_with("chunk:retained:"): return 80
	if source_id.begins_with("viewer:handoff:"): return 70
	if source_id.begins_with("viewer:startup:"): return 60
	if source_id.begins_with("viewer:retained:"): return 50
	return 40

static func _block_before(a: Vector3i, b: Vector3i) -> bool:
	return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x)))
