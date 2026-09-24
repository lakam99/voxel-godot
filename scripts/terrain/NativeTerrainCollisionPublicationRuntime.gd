extends Node
class_name NativeTerrainCollisionPublicationRuntime

## Incremental production composition from the N3 runtime-owner boundary to
## exact N5 physical windows. This node intentionally does not disable
## VoxelTools collision; its aggregate receipt is a prerequisite for a later,
## separately reviewed authority cutover.
const CoordinatorScript := preload("res://scripts/terrain/NativeWindowedCollisionCoordinator.gd")
const ResidentOwnerScript := preload("res://scripts/terrain/NativeResidentCollisionOwner.gd")
const AdmissionRouterScript := preload("res://scripts/terrain/NativeCollisionAdmissionRouter.gd")
const MAX_ARTIFACT_REQUESTS_PER_FRAME := 64
const MAX_LAYOUT_CHECKS_PER_FRAME := 64
const MAX_ROW_SNAPSHOTS_PER_FRAME := 64
const MAX_WINDOWS_PER_FRAME := 4

var _runtime_owner: RefCounted
var _actor_root: Node
var _memory_admission: Object
var _coordinator: Node3D
var _router: RefCounted
var _state := "new"
var _failure := ""
var _advancing := false
var _ticket := ""
var _identity: Dictionary = {}
var _demand_closure_token := ""
var _requested := {}
var _request_queue: Array = []
var _request_cursor := 0
var _partition_job: Dictionary = {}
var _row_job: Dictionary = {}
var _row_snapshot_frame := -1
var _row_snapshots_in_frame := 0
var _window_cursor := 0
var _windows: Dictionary = {}
var _closure: Dictionary = {"status":"pending", "reason":"not_started"}
var _step_stats: Dictionary = {}
var _bound_main_core: Node
var _admission_owner: Node

func setup(runtime_owner: RefCounted, actor_root: Node,
		memory_admission: Object) -> Dictionary:
	if _state != "new" or runtime_owner == null or actor_root == null \
			or memory_admission == null or not runtime_owner.has_method("collision_window_layout_ticket") \
			or not runtime_owner.has_method("request_collision_artifact") \
			or not runtime_owner.has_method("advance_collision_artifacts") \
			or not runtime_owner.has_method("collision_window_source"):
		return _fail("physical_publication_runtime_inputs_invalid")
	_runtime_owner = runtime_owner
	_actor_root = actor_root
	_memory_admission = memory_admission
	_coordinator = CoordinatorScript.new()
	_coordinator.name = "NativeWindowedCollisionCoordinator"
	add_child(_coordinator)
	var bound: Dictionary = _coordinator.setup(runtime_owner, actor_root, memory_admission)
	if bound.get("status") != "ready": return _fail(String(bound.get("reason", "coordinator_setup_failed")))
	_state = "active"
	_closure = {"status":"pending", "reason":"native_physical_closure_in_progress"}
	set_process(true)
	return {"status":"ready", "state":_state}

func _ready() -> void:
	# setup may run before or after this node enters the tree.
	set_process(_state == "active")

func _process(_delta: float) -> void:
	if _state != "active" or _advancing: return
	_advance()

func _advance() -> void:
	_advancing = true
	var row_calls_this_frame := _row_snapshots_in_frame \
		if _row_snapshot_frame == Engine.get_process_frames() else 0
	_step_stats = {"layoutChecks":0, "rowSnapshots":row_calls_this_frame,
		"rowSnapshotFrame":_row_snapshot_frame,
		"windowsAdvanced":0, "artifactRequests":0}
	var advanced: Dictionary = _runtime_owner.call("advance_collision_artifacts")
	if advanced.get("status") == "failed":
		_closure = {"status":"pending", "reason":advanced.get("reason", "source_advance_pending")}
		_advancing = false
		return
	var current: Dictionary = _runtime_owner.call("collision_window_layout_ticket")
	if current.get("status") != "ready":
		_closure = {"status":"pending", "reason":current.get("reason", "collision_layout_pending")}
		_advancing = false
		return
	var layout: Dictionary = current.get("layout", {})
	var identity: Dictionary = current.get("identity", {})
	var ticket := String(current.get("ticket", ""))
	if ticket.is_empty() or identity.is_empty() or layout.get("identity") != identity:
		_closure = {"status":"pending", "reason":"immutable_collision_ticket_invalid"}
		_advancing = false
		return
	if ticket == _ticket and _closure.get("status") == "ready" \
			and _router != null and _router.is_admission_ready():
		_advancing = false
		return
	if ticket != _ticket:
		var reset: Dictionary = await _reset_for_ticket(current)
		if reset.get("status") != "ready":
			_closure = reset
			_advancing = false
			return
		if not _ticket_is_current(ticket, identity,
				_runtime_owner.call("collision_window_layout_ticket")):
			_closure = {"status":"pending", "reason":"layout_ticket_changed_during_reset"}
			_advancing = false
			return
	if _request_queue.is_empty():
		_closure = {"status":"pending", "reason":"collision_demand_pending"}
		_advancing = false
		return
	if _demand_closure_token != String(layout.get("logicalClosureToken", "")):
		_closure = {"status":"pending", "reason":"collision_demand_layout_mismatch"}
		_advancing = false
		return
	var demand := {"status":"ready", "blocks":_request_queue,
		"closureToken":String(layout.get("logicalClosureToken", ""))}
	var partition: Dictionary = _advance_layout_partition(layout, demand.blocks, ticket)
	if partition.get("status") != "ready":
		_closure = partition
		_advancing = false
		return
	var issued := 0
	while _request_cursor < _request_queue.size() and issued < MAX_ARTIFACT_REQUESTS_PER_FRAME:
		var block: Vector3i = _request_queue[_request_cursor]
		var request: Dictionary = _runtime_owner.call("request_collision_artifact", block)
		if request.get("status") == "failed":
			_closure = {"status":"pending", "reason":request.get("reason", "artifact_request_rejected"),
				"block":block, "retryable":bool(request.get("retryable", false))}
			_advancing = false
			return
		_requested[block] = true
		_request_cursor += 1
		issued += 1
		_step_stats.artifactRequests = issued
	if _request_cursor < _request_queue.size():
		_closure = {"status":"pending", "reason":"bounded_collision_artifact_demand",
			"requested":_request_cursor, "required":_request_queue.size()}
		_advancing = false
		return
	var window_steps := 0
	while _window_cursor < (layout.windows as Array).size() \
			and window_steps < MAX_WINDOWS_PER_FRAME:
		var window: Dictionary = layout.windows[_window_cursor]
		var result: Dictionary = await _advance_window(current, window)
		var after_window: Dictionary = _runtime_owner.call("collision_window_layout_ticket")
		if not _ticket_is_current(ticket, identity, after_window):
			_closure = {"status":"pending", "reason":"layout_ticket_changed_during_window_publication"}
			_advancing = false
			return
		if result.get("status") != "ready":
			_closure = result
			_advancing = false
			return
		_window_cursor += 1
		window_steps += 1
		_step_stats.windowsAdvanced = window_steps
	if _window_cursor < (layout.windows as Array).size():
		_closure = {"status":"pending", "reason":"bounded_collision_window_publication",
			"windowCursor":_window_cursor, "windowCount":layout.windows.size(),
			"operationBudget":MAX_WINDOWS_PER_FRAME}
		_advancing = false
		return
	var removals: Array[Vector3i] = []
	for key in _windows.keys():
		var id: Vector3i = key
		var still_present := false
		for window: Dictionary in layout.windows:
			if window.get("id") == id: still_present = true
		if not still_present: removals.append(id)
	for id in removals:
		var removal: Dictionary = await _retire_removed_window(id, identity)
		var after_retirement: Dictionary = _runtime_owner.call("collision_window_layout_ticket")
		if not _ticket_is_current(ticket, identity, after_retirement):
			_closure = {"status":"pending", "reason":"layout_ticket_changed_during_window_retirement"}
			_advancing = false
			return
		if removal.get("status") != "ready":
			_closure = removal
			_advancing = false
			return
	var aggregate: Dictionary = _coordinator.aggregate_readiness(identity)
	if aggregate.get("status") != "ready":
		_closure = {"status":"pending", "reason":aggregate.get("reason", "aggregate_receipt_pending"),
			"aggregate":aggregate}
		_advancing = false
		return
	for id in _windows.keys():
		if _coordinator.has_displaced_window(id):
			var retired: Dictionary = await _coordinator.retire_displaced_window(id)
			var after_drain: Dictionary = _runtime_owner.call("collision_window_layout_ticket")
			if not _ticket_is_current(ticket, identity, after_drain):
				_closure = {"status":"pending", "reason":"layout_ticket_changed_during_displaced_drain"}
				_advancing = false
				return
			if retired.get("status") != "ready":
				_closure = {"status":"pending", "reason":retired.get("reason", "displaced_owner_drain_pending"),
					"retirement":retired}
				_advancing = false
				return
	var released: Dictionary = _coordinator.release_barriers(identity)
	if released.get("status") != "ready":
		_closure = {"status":"pending", "reason":released.get("reason", "barrier_release_pending"),
			"release":released}
		_advancing = false
		return
	if _router == null or not _router.matches_identity(identity):
		_router = AdmissionRouterScript.new()
		var routed: Dictionary = _router.setup(_coordinator, identity)
		if routed.get("status") != "ready" or not _router.is_admission_ready():
			_router = null
			_closure = {"status":"pending", "reason":"aggregate_router_receipt_pending"}
			_advancing = false
			return
	if _bound_main_core != null and is_instance_valid(_bound_main_core) \
			and _admission_owner != null and is_instance_valid(_admission_owner) \
			and not bool(_bound_main_core.call("refresh_native_collision_admission",
				_admission_owner, _router)):
		_closure = {"status":"pending", "reason":"main_core_aggregate_router_refresh_pending"}
		_advancing = false
		return
	_closure = {"status":"ready", "identity":identity.duplicate(true),
		"layoutTicket":ticket, "requiredBlockCount":demand.blocks.size(),
		"windowCount":layout.windows.size(), "windowBlockCounts":_window_block_counts(layout),
		"physicalReceipt":_router.physical_receipt()}
	_advancing = false

func _reset_for_ticket(ticket_result: Dictionary) -> Dictionary:
	var layout: Dictionary = ticket_result.get("layout", {})
	if not _ticket.is_empty() and not _windows.is_empty():
		for key in _windows.keys():
			var entry: Dictionary = _windows[key]
			var candidate: Dictionary = entry.get("candidate", {})
			if candidate.is_empty(): continue
			var candidate_owner: Node3D = candidate.get("owner")
			if not is_instance_valid(candidate_owner):
				return {"status":"failed", "reason":"staged_candidate_owner_lost",
					"windowId":key}
			var candidate_epoch := String(candidate_owner.call("retirement_owner_epoch"))
			if candidate_epoch.is_empty():
				return {"status":"failed", "reason":"staged_candidate_epoch_missing",
					"windowId":key}
			var cancelled: Dictionary = await _coordinator.cancel_staged_replacement(
				key, candidate_epoch)
			if cancelled.get("status") != "ready":
				return {"status":"pending", "reason":cancelled.get("reason",
					"obsolete_candidate_drain_pending"), "cancellation":cancelled}
			entry.erase("candidate")
			_windows[key] = entry
		var adopted_replacement: Dictionary = _adopt_ticket_demand(ticket_result,
			layout.get("requiredBlocks", []),
			String(layout.get("logicalClosureToken", "")))
		if adopted_replacement.get("status") != "ready": return adopted_replacement
		_router = null
		var live: Dictionary = _runtime_owner.call("collision_window_layout_ticket")
		if not _ticket_is_current(_ticket, _identity, live):
			return {"status":"pending", "reason":"layout_ticket_changed_during_candidate_cancel"}
		return {"status":"ready", "reason":"replacement_ticket_adopted",
			"requiredBlockCount":_request_queue.size()}
	var adopted_initial: Dictionary = _adopt_ticket_demand(ticket_result,
		layout.get("requiredBlocks", []),
		String(layout.get("logicalClosureToken", "")))
	if adopted_initial.get("status") != "ready": return adopted_initial
	_router = null
	return {"status":"ready", "layoutWindowCount":layout.get("windows", []).size(),
		"requiredBlockCount":_request_queue.size()}

func _adopt_ticket_demand(ticket_result: Dictionary, blocks: Array,
		closure_token: String) -> Dictionary:
	var ticket := String(ticket_result.get("ticket", ""))
	var identity: Dictionary = ticket_result.get("identity", {})
	if ticket.is_empty() or identity.is_empty() or blocks.is_empty() \
			or closure_token.is_empty() \
			or closure_token != String(ticket_result.get("layout", {}).get(
				"logicalClosureToken", "")):
		return {"status":"failed", "reason":"collision_ticket_demand_invalid"}
	_ticket = ticket
	_identity = identity.duplicate(true)
	_demand_closure_token = closure_token
	# The immutable layout ticket owns requiredBlocks. Keep its array by
	# reference and issue rows incrementally instead of duplicating/sorting it.
	_request_queue = blocks
	_request_cursor = 0
	_window_cursor = 0
	_requested.clear()
	_partition_job.clear()
	_row_job.clear()
	return {"status":"ready", "ticket":_ticket, "identity":_identity.duplicate(true),
		"requiredBlockCount":_request_queue.size(), "requestCursor":_request_cursor}

## Candidate strong references must be entered before acquiring a retryable
## barrier. This also makes stop_and_drain the single cleanup owner on failure.
func _retain_staged_candidate(id: Vector3i, entry: Dictionary,
		candidate: Dictionary) -> Dictionary:
	if candidate.is_empty() or candidate.get("owner") == null:
		return {"status":"failed", "reason":"staged_candidate_invalid"}
	entry["candidate"] = candidate
	_windows[id] = entry
	return {"status":"ready", "windowId":id}

func _ticket_is_current(expected_ticket: String, expected_identity: Dictionary,
		live_ticket: Dictionary) -> bool:
	return live_ticket.get("status") == "ready" \
		and String(live_ticket.get("ticket", "")) == expected_ticket \
		and live_ticket.get("identity") == expected_identity \
		and live_ticket.get("layout", {}).get("identity") == expected_identity

func _advance_layout_partition(layout: Dictionary, demanded: Array,
		ticket: String) -> Dictionary:
	var required: Array = layout.get("requiredBlocks", [])
	if required.size() != demanded.size():
		return {"status":"failed", "reason":"collision_layout_membership_mismatch"}
	if _partition_job.get("ticket") != ticket:
		_partition_job = {"ticket":ticket, "phase":"required", "cursor":0,
			"windowCursor":0, "blockCursor":0, "membership":{}, "partition":{}}
	if _partition_job.get("phase") == "done": return {"status":"ready"}
	var operations := 0
	while operations < MAX_LAYOUT_CHECKS_PER_FRAME:
		var phase: String = _partition_job.phase
		if phase == "required":
			if int(_partition_job.cursor) == required.size():
				_partition_job.phase = "windows"
				continue
			var required_block = required[int(_partition_job.cursor)]
			if not required_block is Vector3i or required_block != demanded[int(_partition_job.cursor)] \
					or (_partition_job.membership as Dictionary).has(required_block):
				return {"status":"failed", "reason":"collision_layout_membership_mismatch"}
			(_partition_job.membership as Dictionary)[required_block] = true
			_partition_job.cursor = int(_partition_job.cursor) + 1
		elif phase == "windows":
			var windows: Array = layout.get("windows", [])
			if int(_partition_job.windowCursor) == windows.size():
				if (_partition_job.partition as Dictionary).size() != required.size():
					return {"status":"failed", "reason":"collision_layout_membership_mismatch"}
				_partition_job.phase = "done"
				return {"status":"ready"}
			var window: Dictionary = windows[int(_partition_job.windowCursor)]
			var blocks: Array = window.get("blocks", [])
			if blocks.is_empty() or blocks.size() > ResidentOwnerScript.MAX_RESIDENT:
				return {"status":"failed", "reason":"collision_layout_membership_mismatch"}
			if int(_partition_job.blockCursor) == blocks.size():
				_partition_job.windowCursor = int(_partition_job.windowCursor) + 1
				_partition_job.blockCursor = 0
				continue
			var block = blocks[int(_partition_job.blockCursor)]
			if not block is Vector3i or not (_partition_job.membership as Dictionary).has(block) \
					or (_partition_job.partition as Dictionary).has(block):
				return {"status":"failed", "reason":"collision_layout_membership_mismatch"}
			(_partition_job.partition as Dictionary)[block] = true
			_partition_job.blockCursor = int(_partition_job.blockCursor) + 1
		else:
			return {"status":"failed", "reason":"collision_layout_partition_state_invalid"}
		operations += 1
		_step_stats.layoutChecks = operations
	return {"status":"pending", "reason":"bounded_collision_layout_validation",
		"checked":(_partition_job.membership as Dictionary).size() \
			+ (_partition_job.partition as Dictionary).size(),
		"required":required.size(), "operationBudget":MAX_LAYOUT_CHECKS_PER_FRAME}

func _advance_window(ticket_result: Dictionary, window: Dictionary) -> Dictionary:
	var id: Vector3i = window.id
	var identity: Dictionary = ticket_result.get("identity", {})
	var entry: Dictionary = _windows.get(id, {})
	if not entry.is_empty() and String(entry.window.get("windowToken", "")) \
			== String(window.get("windowToken", "")):
		if entry.window.get("identity") != window.get("identity") \
				or entry.window.get("blocks") != window.get("blocks"):
			return {"status":"pending", "reason":"same_window_token_membership_changed",
				"windowId":id}
		var receipt: Dictionary = entry.owner.physical_receipt_for_layout(
			window.get("identity", {}), window.get("localCurrentProof", {}), identity)
		if bool(receipt.get("ready", false)):
			if entry.get("identity", {}) != identity:
				var prior_barrier: RefCounted = entry.get("barrier")
				if prior_barrier != null and prior_barrier.is_active():
					var rebound: Dictionary = _coordinator.begin_window_barrier(
						window, entry.bounds, identity)
					if not rebound.has("barrier"):
						return {"status":"pending", "reason":rebound.get("reason",
							"retained_barrier_rebind_pending"), "windowId":id}
					entry["barrier"] = rebound.barrier
			entry.window = window.duplicate(true)
			entry.identity = identity.duplicate(true)
			_windows[id] = entry
			var current_barrier: RefCounted = entry.get("barrier")
			if current_barrier != null and current_barrier.is_active():
				var census: Dictionary = current_barrier.census_progress(identity)
				if census.get("status") != "ready":
					return {"status":"pending", "reason":"retained_actor_census_in_progress",
						"windowId":id, "census":census}
			return {"status":"ready", "retainedPhysicalReceipt":receipt}
		# A registered initial owner is not yet a published owner. Resume the
		# barrier and the retained rows instead of waiting for a receipt it
		# cannot produce. Once published, only advance receipt health/rebind.
		if bool(entry.get("published", false)):
			return {"status":"pending", "reason":receipt.get("reason",
				"retained_window_physical_proof_pending"), "windowId":id,
				"receipt":receipt}
		var pending_rows: Array[Dictionary] = entry.get("rows", [])
		var resumed: Dictionary = await _republish_current(entry, window,
			entry.source, pending_rows, entry.bounds,
			window.get("identity", {}))
		if resumed.get("status") == "ready":
			entry = _windows.get(id, entry)
			entry["published"] = true
			entry.erase("rows")
			_windows[id] = entry
			return {"status":"pending", "reason":"initial_publication_receipt_pending",
				"windowId":id}
		return resumed
	var pending_candidate: Dictionary = entry.get("candidate", {})
	if not pending_candidate.is_empty() \
			and String(pending_candidate.get("window", {}).get("windowToken", "")) \
			== String(window.get("windowToken", "")):
		return await _replace_owner(entry, window, pending_candidate.source,
			pending_candidate.rows, pending_candidate.bounds, identity, ticket_result)
	var source_result: Dictionary = _runtime_owner.call("collision_window_source", id,
		String(ticket_result.get("layoutToken", "")))
	if source_result.get("status") != "ready":
		return {"status":"pending", "reason":source_result.get("reason", "window_source_pending"),
			"windowId":id}
	var source = source_result.get("source")
	var row_key := "%s:%s" % [String(ticket_result.get("ticket", "")),
		String(window.get("windowToken", ""))]
	if _row_job.get("key") != row_key:
		var source_snapshot: Dictionary = source.call("collision_source_snapshot")
		if source_snapshot.get("status") != "ready":
			return {"status":"pending", "reason":source_snapshot.get("reason",
				"window_rows_pending"), "windowId":id}
	var assembled: Dictionary = _advance_window_rows(ticket_result, window, source)
	if assembled.get("status") != "ready": return assembled
	var rows: Array[Dictionary] = assembled.rows
	var bounds: AABB = assembled.bounds
	if entry.is_empty():
		var physical = ResidentOwnerScript.new()
		physical.name = "NativeCollisionWindow_%s" % str(id)
		_coordinator.add_child(physical)
		if not bool(physical.bind_source(source)):
			physical.queue_free()
			return {"status":"failed", "reason":"physical_window_source_bind_failed", "windowId":id}
		var registered: Dictionary = _coordinator.register_window(window, physical)
		if registered.get("status") != "ready":
			physical.queue_free()
			return {"status":"pending", "reason":registered.get("reason", "physical_window_registration_pending"),
				"windowId":id}
		entry = {"owner":physical, "window":window.duplicate(true),
			"identity":identity.duplicate(true), "bounds":bounds,
			"source":source, "rows":rows, "published":false}
		_windows[id] = entry
		_row_job.clear()
		var held: Dictionary = _coordinator.begin_window_barrier(window, bounds,
			ticket_result.identity)
		if not held.has("barrier"):
			return {"status":"pending", "reason":held.get("reason", "actor_barrier_pending"),
				"windowId":id}
		entry["barrier"] = held.barrier
		_windows[id] = entry
		var published: Dictionary = await _publish_owner(physical, window, rows,
			held.barrier, identity)
		if published.get("status") == "ready":
			entry = _windows.get(id, entry)
			entry["published"] = true
			entry.erase("rows")
			_windows[id] = entry
			return {"status":"pending", "reason":"initial_publication_receipt_pending",
				"windowId":id}
		return published
	return await _replace_owner(entry, window, source, rows, bounds,
		identity, ticket_result)

func _advance_window_rows(ticket_result: Dictionary, window: Dictionary,
		source: Object) -> Dictionary:
	var key := "%s:%s" % [String(ticket_result.get("ticket", "")),
		String(window.get("windowToken", ""))]
	if _row_job.get("key") != key:
		var fresh_rows: Array[Dictionary] = []
		_row_job = {"key":key, "cursor":0, "rows":fresh_rows, "bounds":AABB()}
	if _row_job.get("status") == "ready":
		return {"status":"ready", "rows":_row_job.rows, "bounds":_row_job.bounds}
	var rows: Array[Dictionary] = _row_job.rows
	var cursor := int(_row_job.cursor)
	var frame := Engine.get_process_frames()
	if frame != _row_snapshot_frame:
		_row_snapshot_frame = frame
		_row_snapshots_in_frame = 0
	_step_stats.rowSnapshots = _row_snapshots_in_frame
	_step_stats.rowSnapshotFrame = frame
	while cursor < (window.blocks as Array).size() \
			and _row_snapshots_in_frame < MAX_ROW_SNAPSHOTS_PER_FRAME:
		var block: Vector3i = window.blocks[cursor]
		# An unresolved row is still a source call and consumes this frame's
		# allowance. The cursor remains retryable on the next frame.
		_row_snapshots_in_frame += 1
		_step_stats.rowSnapshots = _row_snapshots_in_frame
		var row_result: Dictionary = source.call("collision_artifact_row_snapshot",
			block, window.get("identity", {}))
		if row_result.get("status") != "ready":
			return {"status":"pending", "reason":row_result.get("reason",
				"canonical_row_pending"), "windowId":window.id, "block":block,
				"rowCursor":cursor}
		var row: Dictionary = row_result.get("row", {})
		if row.get("block") != block or not row.get("bounds") is AABB:
			return {"status":"failed", "reason":"canonical_collision_row_mismatch",
				"windowId":window.id, "block":block}
		rows.append(row)
		_row_job.bounds = row.bounds if cursor == 0 \
			else (_row_job.bounds as AABB).merge(row.bounds)
		cursor += 1
	_row_job.cursor = cursor
	if cursor < (window.blocks as Array).size():
		return {"status":"pending", "reason":"bounded_collision_row_assembly",
			"windowId":window.id, "rowCursor":cursor,
			"required":(window.blocks as Array).size(),
			"operationBudget":MAX_ROW_SNAPSHOTS_PER_FRAME}
	_row_job.status = "ready"
	return {"status":"ready", "rows":rows, "bounds":_row_job.bounds}

func _publish_owner(owner: Node3D, window: Dictionary, rows: Array[Dictionary],
		barrier: RefCounted, identity: Dictionary) -> Dictionary:
	var census: Dictionary = barrier.census_progress(identity)
	if census.get("status") != "ready":
		return {"status":"pending", "reason":"actor_census_in_progress", "census":census}
	_closure = {"status":"pending", "reason":"physical_publication_pending",
		"windowId":window.id, "windowToken":window.get("windowToken", "")}
	var publication: Dictionary = await owner.publish({
		"schema":"n5-resident-collision-publication/v1", "identity":identity,
		"residentBlocks":window.blocks, "affectedBlocks":window.blocks, "rows":rows}, barrier)
	return {"status":"ready", "physicalReceipt":publication} \
		if publication.get("status") == "ready" else {"status":"pending",
		"reason":publication.get("reason", "physical_publication_pending"),
		"publication":publication}

func _republish_current(entry: Dictionary, window: Dictionary, source,
		rows: Array[Dictionary], bounds: AABB, identity: Dictionary) -> Dictionary:
	var barrier: RefCounted = entry.get("barrier")
	if barrier == null or not barrier.is_active():
		var held: Dictionary = _coordinator.begin_window_barrier(window, bounds, identity)
		if not held.has("barrier"):
			return {"status":"pending", "reason":held.get("reason", "actor_barrier_pending")}
		barrier = held.barrier
		entry["barrier"] = barrier
		_windows[window.id] = entry
	return await _publish_owner(entry.owner, window, rows, barrier, identity)

func _replace_owner(entry: Dictionary, window: Dictionary, source,
		rows: Array[Dictionary], bounds: AABB, identity: Dictionary,
		ticket_result: Dictionary) -> Dictionary:
	var candidate: Dictionary = entry.get("candidate", {})
	if candidate.is_empty():
		var owner = ResidentOwnerScript.new()
		owner.name = "NativeCollisionWindowCandidate_%s" % str(window.id)
		_coordinator.add_child(owner)
		if not bool(owner.bind_source(source)):
			owner.queue_free()
			return {"status":"failed", "reason":"candidate_source_bind_failed"}
		var staged: Dictionary = _coordinator.stage_window_replacement(window, owner)
		if staged.get("status") != "ready":
			if bool(staged.get("candidateRetainedForDrain", false)):
				candidate = {"owner":owner, "window":window.duplicate(true),
					"source":source, "staged":true, "stageResult":staged}
				_retain_staged_candidate(window.id, entry, candidate)
				_state = "failed"
				_failure = String(staged.get("reason", "candidate_stage_retained_failure"))
				set_process(false)
			else:
				owner.queue_free()
			return {"status":"failed" if bool(staged.get("candidateRetainedForDrain", false)) \
				else "pending", "reason":staged.get("reason", "candidate_stage_pending"),
				"stage":staged}
		candidate = {"owner":owner, "window":window.duplicate(true),
			"source":source, "rows":rows, "bounds":bounds, "staged":true}
		_retain_staged_candidate(window.id, entry, candidate)
		_row_job.clear()
	if not candidate.has("oldBarrier"):
		var old_held: Dictionary = _coordinator.begin_window_barrier(entry.window,
			entry.bounds, entry.identity)
		if not old_held.has("barrier"):
			return {"status":"pending", "reason":old_held.get("reason", "old_barrier_pending")}
		candidate["oldBarrier"] = old_held.barrier
	if not candidate.has("barrier"):
		var new_union := bounds.merge(entry.bounds)
		var new_held: Dictionary = _coordinator.begin_window_barrier(window,
			new_union, identity)
		if not new_held.has("barrier"):
			entry["candidate"] = candidate
			_windows[window.id] = entry
			return {"status":"pending", "reason":new_held.get("reason", "replacement_barrier_pending")}
		candidate["barrier"] = new_held.barrier
		candidate["bounds"] = new_union
	candidate["window"] = window.duplicate(true)
	candidate["source"] = source
	candidate["rows"] = rows
	entry["candidate"] = candidate
	_windows[window.id] = entry
	var old_census: Dictionary = candidate.oldBarrier.census_progress(entry.identity)
	var new_census: Dictionary = candidate.barrier.census_progress(identity)
	if old_census.get("status") != "ready" or new_census.get("status") != "ready":
		return {"status":"pending", "reason":"replacement_actor_census_in_progress",
			"oldCensus":old_census, "newCensus":new_census}
	var published: Dictionary = await candidate.owner.publish({
		"schema":"n5-resident-collision-publication/v1", "identity":identity,
		"residentBlocks":window.blocks, "affectedBlocks":window.blocks, "rows":rows},
		candidate.barrier)
	if published.get("status") != "ready":
		return {"status":"pending", "reason":published.get("reason", "candidate_publication_pending"),
			"publication":published}
	var live_ticket: Dictionary = _runtime_owner.call("collision_window_layout_ticket")
	if not _ticket_is_current(String(ticket_result.get("ticket", "")),
			identity, live_ticket):
		return {"status":"pending", "reason":"layout_ticket_changed_during_candidate_publication"}
	var committed: Dictionary = _coordinator.commit_staged_replacement(window,
		candidate.owner, candidate.barrier)
	if committed.get("status") != "ready":
		return {"status":"pending", "reason":committed.get("reason", "candidate_commit_pending"),
			"commit":committed}
	entry["owner"] = candidate.owner
	entry["window"] = window.duplicate(true)
	entry["identity"] = identity.duplicate(true)
	entry["bounds"] = candidate.bounds
	entry["source"] = source
	entry["barrier"] = candidate.barrier
	entry.erase("candidate")
	_windows[window.id] = entry
	return {"status":"ready", "replacement":committed}

func _retire_removed_window(id: Vector3i, identity: Dictionary) -> Dictionary:
	var entry: Dictionary = _windows.get(id, {})
	if entry.is_empty(): return {"status":"ready"}
	var barrier: RefCounted = entry.get("barrier")
	if barrier == null or not barrier.is_active():
		var held: Dictionary = _coordinator.begin_window_barrier(entry.window,
			entry.bounds, identity)
		if not held.has("barrier"):
			return {"status":"pending", "reason":held.get("reason", "retirement_barrier_pending")}
		barrier = held.barrier
		entry["barrier"] = barrier
		_windows[id] = entry
	if barrier.census_progress(identity).get("status") != "ready":
		return {"status":"pending", "reason":"retirement_actor_census_in_progress"}
	var retired: Dictionary = await _coordinator.retire_window(id)
	if retired.get("status") == "ready": _windows.erase(id)
	return retired

func bind_main_core(main_core: Node, admission_owner: Node) -> bool:
	if main_core == null or not is_instance_valid(main_core) or admission_owner == null \
			or not is_instance_valid(admission_owner) or not _closure_is_current():
		return false
	if bool(main_core.call("native_collision_admission_bound")):
		if not bool(main_core.call("refresh_native_collision_admission", admission_owner, _router)):
			return false
	else:
		if not bool(main_core.call("bind_native_collision_admission", admission_owner, _router)):
			return false
	_bound_main_core = main_core
	_admission_owner = admission_owner
	return true

func _closure_is_current() -> bool:
	if _state != "active" or _router == null or _closure.get("status") != "ready":
		return false
	var live: Dictionary = _runtime_owner.call("collision_window_layout_ticket")
	return _ticket_is_current(_ticket, _identity, live) \
		and _router.is_admission_ready()

func closure_snapshot() -> Dictionary:
	return _closure.duplicate(true)

func work_step_snapshot() -> Dictionary:
	# A caller may sample after the frame's work; include the frame token so
	# the last observed count is never misread as current-frame work.
	return _step_stats.duplicate(true)

func admission_router() -> RefCounted:
	return _router if _closure_is_current() else null

func stop_and_drain() -> Dictionary:
	if _coordinator == null:
		_state = "stopped"
		return {"status":"ready", "drained":true}
	_state = "stopping"
	set_process(false)
	var drained: Dictionary = await _coordinator.stop_and_drain()
	if drained.get("status") == "ready" and bool(drained.get("drained", false)):
		if _bound_main_core != null and is_instance_valid(_bound_main_core):
			if _admission_owner == null or not is_instance_valid(_admission_owner) \
					or not bool(_bound_main_core.call("unbind_native_collision_admission",
						_admission_owner)):
				return {"status":"pending", "reason":"main_core_admission_unbind_pending",
					"coordinatorDrain":drained}
		_state = "stopped"
		_router = null
		_windows.clear()
		_bound_main_core = null
		_admission_owner = null
	return drained

func _window_block_counts(layout: Dictionary) -> Array[Dictionary]:
	var counts: Array[Dictionary] = []
	for window: Dictionary in layout.get("windows", []):
		counts.append({"windowId":window.get("id"), "blockCount":window.get("blocks", []).size()})
	return counts

func _fail(reason: String) -> Dictionary:
	_failure = reason
	_state = "failed"
	return {"status":"failed", "reason":reason}
