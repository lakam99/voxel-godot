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
var _request_queue: Array[Vector3i] = []
var _request_cursor := 0
var _windows: Dictionary = {}
var _closure: Dictionary = {"status":"pending", "reason":"not_started"}
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
	set_process(false)

func _process(_delta: float) -> void:
	if _state != "active" or _advancing: return
	_advance()

func _advance() -> void:
	_advancing = true
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
	if ticket != _ticket:
		var reset: Dictionary = await _reset_for_ticket(current)
		if reset.get("status") != "ready":
			_closure = reset
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
	if _request_cursor < _request_queue.size():
		_closure = {"status":"pending", "reason":"bounded_collision_artifact_demand",
			"requested":_request_cursor, "required":_request_queue.size()}
		_advancing = false
		return
	if not _layout_partition_exact(layout, demand.blocks):
		_closure = {"status":"pending", "reason":"collision_layout_membership_mismatch"}
		_advancing = false
		return
	for window: Dictionary in layout.windows:
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
	var unique := {}
	for block in blocks:
		if not block is Vector3i or unique.has(block):
			return {"status":"failed", "reason":"collision_ticket_demand_membership_invalid"}
		unique[block] = true
	_ticket = ticket
	_identity = identity.duplicate(true)
	_demand_closure_token = closure_token
	# The immutable layout ticket owns requiredBlocks. Keep its array by
	# reference and issue rows incrementally instead of duplicating/sorting it.
	_request_queue = blocks
	_request_cursor = 0
	_requested.clear()
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

func _layout_partition_exact(layout: Dictionary, demanded: Array) -> bool:
	var required: Array = layout.get("requiredBlocks", [])
	if required.size() != demanded.size(): return false
	var membership := {}
	for block in demanded:
		if not block is Vector3i or membership.has(block): return false
		membership[block] = true
	var partition := {}
	for window: Dictionary in layout.get("windows", []):
		var blocks: Array = window.get("blocks", [])
		if blocks.is_empty() or blocks.size() > ResidentOwnerScript.MAX_RESIDENT: return false
		for block in blocks:
			if not membership.has(block) or partition.has(block): return false
			partition[block] = true
	if partition.size() != membership.size(): return false
	for block in required:
		if not partition.has(block): return false
	return true

func _advance_window(ticket_result: Dictionary, window: Dictionary) -> Dictionary:
	var id: Vector3i = window.id
	var source_result: Dictionary = _runtime_owner.call("collision_window_source", id,
		String(ticket_result.get("layoutToken", "")))
	if source_result.get("status") != "ready":
		return {"status":"pending", "reason":source_result.get("reason", "window_source_pending"),
			"windowId":id}
	var source = source_result.get("source")
	var source_snapshot: Dictionary = source.call("collision_source_snapshot")
	if source_snapshot.get("status") != "ready":
		return {"status":"pending", "reason":source_snapshot.get("reason", "window_rows_pending"),
			"windowId":id}
	var rows: Array[Dictionary] = []
	var bounds := AABB()
	for block: Vector3i in window.blocks:
		var row_result: Dictionary = source.call("collision_artifact_row_snapshot", block,
			ticket_result.identity)
		if row_result.get("status") != "ready":
			return {"status":"pending", "reason":row_result.get("reason", "canonical_row_pending"),
				"windowId":id, "block":block}
		var row: Dictionary = row_result.get("row", {})
		if row.get("block") != block or not row.get("bounds") is AABB:
			return {"status":"failed", "reason":"canonical_collision_row_mismatch",
				"windowId":id, "block":block}
		rows.append(row)
		bounds = row.bounds if rows.size() == 1 else bounds.merge(row.bounds)
	var entry: Dictionary = _windows.get(id, {})
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
			"identity":ticket_result.identity.duplicate(true), "bounds":bounds,
			"source":source}
		_windows[id] = entry
		var held: Dictionary = _coordinator.begin_window_barrier(window, bounds,
			ticket_result.identity)
		if not held.has("barrier"):
			return {"status":"pending", "reason":held.get("reason", "actor_barrier_pending"),
				"windowId":id}
		entry["barrier"] = held.barrier
		_windows[id] = entry
		return await _publish_owner(physical, window, rows, held.barrier,
			ticket_result.identity)
	if String(entry.window.get("windowToken", "")) == String(window.get("windowToken", "")):
		if entry.window.get("identity") != window.get("identity") \
				or entry.window.get("blocks") != window.get("blocks"):
			return {"status":"pending", "reason":"same_window_token_membership_changed",
				"windowId":id}
		var receipt: Dictionary = entry.owner.physical_receipt_for_layout(
			window.get("identity", {}), window.get("localCurrentProof", {}),
			ticket_result.identity)
		if bool(receipt.get("ready", false)):
			entry.window = window.duplicate(true)
			entry.identity = ticket_result.identity.duplicate(true)
			entry.source = source
			_windows[id] = entry
			return {"status":"ready", "retainedPhysicalReceipt":receipt}
		return {"status":"pending", "reason":receipt.get("reason",
			"retained_window_physical_proof_pending"), "windowId":id,
			"receipt":receipt}
	return await _replace_owner(entry, window, source, rows, bounds,
		ticket_result.identity, ticket_result)

func _publish_owner(owner: Node3D, window: Dictionary, rows: Array[Dictionary],
		barrier: RefCounted, identity: Dictionary) -> Dictionary:
	var census: Dictionary = barrier.census_progress(identity)
	if census.get("status") != "ready":
		return {"status":"pending", "reason":"actor_census_in_progress", "census":census}
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
			"source":source, "staged":true}
		_retain_staged_candidate(window.id, entry, candidate)
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
