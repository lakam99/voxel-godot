extends RefCounted
class_name BuildingScenePublicationJob

## Main-thread scene orchestration, not gameplay readiness. The owner keeps this
## job alive, calls advance even after cancellation, then hands the one-shot
## retirement payload to BuildingPublicationWorker before dropping its aliases.
## This payload is NOT CPU-only: it retains detached publishers and their Godot
## Resources (meshes/materials). All Nodes and callbacks are detached on MAIN
## first; only then may the worker release those exclusive remaining references.
## Budgets are checked BETWEEN atomic publisher operations, not hard deadlines.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const BuildingPublisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const FurniturePublisher = preload("res://scripts/buildings/FurnishingPublisher.gd")
const MAX_TRANSACTION_GROUPS := 64
const MAX_TRANSACTION_MEMBERS := 256
const MAX_TRANSACTION_ESTIMATED_BYTES := 8*1024*1024
const MAX_TRANSACTION_COLLISION_MEMBERS := 256
const MAX_TRANSACTION_REGISTRATIONS := 128
const PACKET_PARTITION_WORLD_SIZE := 16.0
const ESTIMATED_BUILDING_MEMBER_BYTES := 32768
const ESTIMATED_FURNITURE_MEMBER_BYTES := 8192
const ESTIMATED_TREE_MEMBER_BYTES := 24576
const ESTIMATED_COLLISION_PROOF_BYTES := 4096
const SELECTION_BUDGET_USEC := 1000
const MAX_PHYSICAL_REQUIREMENT_TILES := 512
const MAX_PHYSICAL_REQUIREMENT_VALUES := 131072
const PROOF_COUNTERS := ["groupRequests","groupChecks","groupCacheHits","memberRequests","memberChecks","memberCacheHits",
	"boundaryRequests","boundaryChecks","boundaryCacheHits","boundaryNodeChecks","memberNodeChecks","collisionShapeChecks","transactionGroups"]

var _phase := "idle"
var _reason := ""
var _cleanup_reason := ""
var _cancelled := false
var _taken := false
var _advancing := false
var _binding: Dictionary = {}
var _cpu: Dictionary = {} # Retained source AND detached publisher Resources.
var _parent: WeakRef
var _tree_receiver: WeakRef
var _tree_method: StringName
var _tree_retire_receiver: WeakRef
var _tree_retire_method: StringName
var _tree_retire_requires_acknowledgement := false
var _tree_retirement_claims: Dictionary = {}
var _tree_claim_order: Array[int] = []
var _tree_claim_cursor := 0
var _cancel_revision := 0
var _registered_tree_ids: Dictionary = {}
var _retiring_tree_instance := 0
var _door_receiver: WeakRef
var _door_method: StringName
var _door_retire_receiver: WeakRef
var _door_retire_method: StringName
var _door_cursor := 0
var _door_claims: Dictionary = {}
var _door_registered_ids: Dictionary = {}
var _doors_retired := 0
var _root: Node3D
var _cleanup_node: Node
var _building
var _furniture
var _blueprint
var _plan
var _trees: Array = []
var _tree_bodies: Array = []
var _tree_visual_seen: Array[bool] = []
var _tree_ids: Dictionary = {}
var _building_cursor := 0
var _furniture_cursor := 0
var _tree_cursor := 0
var _trees_skipped := 0
var _visual_cursor := 0
var _visuals_complete := 0
var _freed_nodes := 0
var _max_atomic_usec := 0
var _max_slice_usec := 0
var _overruns := 0
var _phase_metrics: Dictionary = {}
var _advance_calls := 0
var _advance_cpu_usec := 0
var _between_advance_usec := 0
var _last_advance_end_usec := 0
var _spatial
var _groups: Dictionary = {}
var _group_requests: Dictionary = {}
var _demand_owners: Dictionary = {}
var _request_heap: Array = []
var _request_sequence := 0
var _packet_partition_sequences: Dictionary = {}
var _packet_partition_sequence := 0
var _background_cursor := 0
var _selection_stack: Array = []
var _selection_groups: Array[String] = []
var _selection_members := 0
var _selection_estimated_bytes := 0
var _selection_collision_members := 0
var _selection_registrations := 0
var _selection_partition_key := ""
var _selection_has_demand := false
var _selection_set: Dictionary = {}
var _transaction: Dictionary = {}
var _transaction_serial := 0
var _transaction_building_cursor := 0
var _transaction_furniture_cursor := 0
var _transaction_tree_cursor := 0
var _transaction_visual_cursor := 0
var _occupied_transactions: Array[Dictionary] = []
var _occupied_group_ids: Dictionary = {}
var _occupied_blocked_requests: Array[Dictionary] = []
var _group_receipts: Dictionary = {}
var _member_witnesses: Dictionary = {}
var _boundary_witnesses: Dictionary = {}
var _proof_totals: Dictionary = {}
var _proof_maximum: Dictionary = {}
var _physical_requirement_memo: Dictionary = {"owner":{},"entries":{},"disabled":false,"retainedEntries":0,"retainedValues":0}
var _physical_requirement_metrics: Dictionary = {"lookups":0,"hits":0,"misses":0,"ownerChanges":0,
	"capacityFallbacks":0,"ownerFallbacks":0,"unfrozenFallbacks":0,"lookupUsec":0,"maxLookupUsec":0,"closureUsec":0,"maxClosureUsec":0}
var _active_member := ""
var _part_child_cursor := 0
var _part_collision_cursor := 0
var _tree_by_source_index: Dictionary = {}
var _skipped_tree_indices: Dictionary = {}
var _base_packet_mode := false
var _physical_packet_inbox: Dictionary = {}
var _packet_static_only_groups: Dictionary = {}
## Packet-mode publication is pull-only. The service supplies the exact
## foreground closure and explicitly records every remaining source group as
## deferred; packet jobs must never turn an empty foreground heap into a
## source-wide background scan.
var _packet_foreground_groups: Dictionary = {}
var _packet_deferred_groups: Dictionary = {}
var _packet_deferred_group_count := 0
var _packet_foreground_configured := false
var _packet_deferred_transactions := 0


## Ownership transfer only: no publisher/resource/node construction or holder
## consumption here. Profile arrays were validated off-frame by Admission.
## Use an ordinary object-method Callable (e.g. main.make_tree_from_runtime_request).
## Its receiver is weak: no service -> job -> bound-service reference cycle.
## Capturing/bound custom callables are rejected rather than retained invisibly.
func begin(prepared, profile: Dictionary, binding: Dictionary, parent: Node3D, tree_callback: Callable) -> Dictionary:
	if _phase != "idle": return {"status":"rejected", "reason":"job_already_started"}
	if not prepared is Preparation.PreparedSource or not Preparation.valid_binding(binding):
		return {"status":"rejected", "reason":"invalid_prepared_binding"}
	if not _valid_profile(profile, binding):
		return {"status":"rejected", "reason":"invalid_profile"}
	var description = prepared.describe(binding)
	if description == null or description.origin != profile.origin or not description.publication_groups.get("ready",false) \
			or not description.publication_groups.get("memberSources") is Dictionary:
		return {"status":"rejected", "reason":"publication_groups_required"}
	if not _valid_parent(parent): return {"status":"rejected", "reason":"invalid_parent"}
	if not tree_callback.is_valid() or tree_callback.is_custom() or tree_callback.get_object() == self:
		return {"status":"rejected", "reason":"tree_callback_requires_object_method"}
	_binding = binding.duplicate()
	_binding.make_read_only()
	_spatial = description
	_groups = description.publication_groups
	_cpu = {"prepared":prepared, "profile":profile, "binding":_binding,
		"nodeMetadata":[], "treeBodies":_tree_bodies, "treeIds":_tree_ids,
		"registeredTreeIds":_registered_tree_ids, "treeVisualSeen":_tree_visual_seen,
		"treeRetirementClaims":_tree_retirement_claims, "treeClaimOrder":_tree_claim_order,
		"spatialDescription":_spatial,"groupRequests":_group_requests,"groupReceipts":_group_receipts,
		"memberWitnesses":_member_witnesses,"boundaryWitnesses":_boundary_witnesses,
		"treeBySourceIndex":_tree_by_source_index,"skippedTreeIndices":_skipped_tree_indices,
		"requestHeap":_request_heap,"selectionStack":_selection_stack,"physicalRequirementMemo":_physical_requirement_memo,
		"occupiedTransactions":_occupied_transactions}
	_parent = weakref(parent)
	_tree_receiver = weakref(tree_callback.get_object())
	_tree_method = tree_callback.get_method()
	_phase = "building_begin"
	return status()


## Packet-mode admission only. It retains the same immutable source-owned
## topology and demand selection as begin(), but does not construct Nodes or
## consume a PreparedSource. A later scene-source/publisher adapter must own
## publication after an exact transaction packet is present.
func begin_prepared_base(base: Preparation.PreparedPublicationBase, profile: Dictionary, binding: Dictionary, parent: Node3D, tree_callback: Callable) -> Dictionary:
	if _phase != "idle": return {"status":"rejected","reason":"job_already_started"}
	if base == null or not base.matches(binding): return {"status":"rejected","reason":"invalid_prepared_base"}
	if not _valid_profile(profile,binding) or base.profile.get("origin",Vector3.ZERO) != profile.origin:
		return {"status":"rejected","reason":"invalid_base_profile"}
	var description = base.description
	if description == null or description.origin != profile.origin or not description.publication_groups.get("ready",false) \
			or not description.publication_groups.get("memberSources") is Dictionary:
		return {"status":"rejected","reason":"publication_groups_required"}
	if not _valid_parent(parent): return {"status":"rejected","reason":"invalid_parent"}
	if not tree_callback.is_valid() or tree_callback.is_custom() or tree_callback.get_object() == self:
		return {"status":"rejected","reason":"tree_callback_requires_object_method"}
	_binding = binding.duplicate()
	_binding.make_read_only()
	_spatial = description
	_groups = description.publication_groups
	_base_packet_mode = true
	_cpu = {"publicationBase":base,"profile":profile,"binding":_binding,
		"spatialDescription":_spatial,"groupRequests":_group_requests,"groupReceipts":_group_receipts,
		"requestHeap":_request_heap,"selectionStack":_selection_stack,"physicalPacketInbox":_physical_packet_inbox,
		"occupiedTransactions":_occupied_transactions,
		"packetStaticOnlyGroups":_packet_static_only_groups,
		"packetForegroundGroups":_packet_foreground_groups,"packetDeferredGroups":_packet_deferred_groups,
		"physicalRequirementMemo":_physical_requirement_memo,"nodeMetadata":[]}
	_parent = weakref(parent)
	_tree_receiver = weakref(tree_callback.get_object())
	_tree_method = tree_callback.get_method()
	_phase = "packet_wait"
	return status()


## Ownership transfer for one immutable, already dependency-closed packet.
## The exact ordered group scope is the key: individual groups cannot be
## substituted after the compiler has produced a multi-group packet.
func offer_physical_group_packet(packet: Preparation.PreparedPhysicalGroupPacket, expected_binding: Dictionary) -> Dictionary:
	if not _base_packet_mode or _phase in ["idle","teardown","detach_publishers","retired","consumed"]:
		return {"status":"rejected","reason":"physical_packet_mode_unavailable"}
	var base: Preparation.PreparedPublicationBase = _cpu.get("publicationBase")
	if packet == null or base == null or expected_binding != _binding or not packet.matches(base,packet.group_ids):
		return {"status":"rejected","reason":"invalid_physical_group_packet"}
	var seen: Dictionary = {}
	for id: String in packet.group_ids:
		if id.is_empty() or seen.has(id) or not _groups.groups.has(id): return {"status":"rejected","reason":"invalid_physical_packet_scope"}
		seen[id] = true
	var key := _physical_packet_key(packet.group_ids)
	if _physical_packet_inbox.has(key): return {"status":"rejected","reason":"physical_group_packet_already_retained"}
	_physical_packet_inbox[key] = packet
	return {"status":"retained","binding":_binding,"groupIds":packet.group_ids}


## Convert a ready packet transaction into the existing bounded member and
## boundary publication flow. This is the sole packet-mode path that creates a
## root or publisher. It restores the base on the main thread and never falls
## back to PreparedSource or whole-source geometry preparation.
func activate_physical_group_packet_scene(expected_transaction_id: int) -> Dictionary:
	if not _base_packet_mode or _phase != "packet_wait":
		return {"status":"rejected","reason":"physical_packet_scene_adapter_unavailable"}
	var transaction := pending_publication_transaction()
	if transaction.get("status") != "ready" or int(transaction.get("id",0)) != expected_transaction_id:
		return {"status":"rejected","reason":"physical_packet_transaction_changed"}
	var base: Preparation.PreparedPublicationBase = _cpu.get("publicationBase")
	var packet: Preparation.PreparedPhysicalGroupPacket = _physical_packet_inbox.get(String(transaction.get("physicalPacketKey","")))
	if base == null or packet == null or not packet.matches(base,transaction.groupIds):
		return {"status":"rejected","reason":"physical_packet_scene_source_missing"}
	# Doors are dynamic collision/portal owners. A packet may only create one
	# when its existing lifecycle pair is available up front, so group commit
	# cannot make a physical receipt before the portal has registered its exact
	# published body. This is deliberately an activation gate rather than a
	# worker/compiler fallback: callbacks are main-thread scene ownership.
	if _packet_transaction_has_doors(transaction) and not _packet_door_lifecycle_available():
		return {"status":"rejected","reason":"physical_packet_door_lifecycle_required"}
	_cpu["activePhysicalPacket"] = packet
	var packet_options := {"batchStaticParts":true, "publicationSiteId":_binding.siteId, "resumableScenePublication":true}
	if _building == null:
		var restored := Preparation.restore_publication_scene_source(base,_binding)
		if not restored.get("ready",false): return {"status":"rejected","reason":String(restored.get("reason","physical_packet_scene_restore_failed"))}
		_cpu["packetSceneSource"] = restored
	_packet_static_only_groups = _packet_static_only_groups_for(packet)
	_cpu["packetStaticOnlyGroups"] = _packet_static_only_groups
	if _building == null:
		_phase = "building_begin"
	else:
		# A prior transaction can finish its group receipt while a late static
		# metadata/batch boundary is still owned by the resident publisher.  That
		# boundary is retryable work, not a source/session mismatch. Drain it before
		# attaching the next immutable packet; the transaction and inbox stay pinned.
		if _building.has_pending_static_flush() or not _building._pending_publication_boundary.is_empty():
			_phase = "packet_attach_boundary"
			return {"status":"pending_budget","reason":"physical_packet_prior_boundary_pending",
				"binding":_binding,"publicationTransactionId":expected_transaction_id}
		# Subsequent closures stay in the exact same root and publisher session.
		# The initial restored source is the immutable witness for every later
		# packet, so no later worker result can replace earlier physical owners.
		var attached: Dictionary = _building.attach_static_only_group_packet_scene(base,packet,_blueprint,_root,_binding,packet_options) \
			if not _packet_static_only_groups.is_empty() and _packet_static_only_groups.size()==packet.group_ids.size() \
			else _building.attach_physical_group_packet_scene(base,packet,_blueprint,_root,_binding,packet_options)
		_cpu["packetAttach"] = attached
		if not attached.get("ready",false):
			var rejection := attached.duplicate(true)
			rejection["status"] = "rejected"
			rejection["transactionId"] = expected_transaction_id
			rejection["phase"] = _phase
			return rejection
		_phase = "building_finish" if transaction.groupIds.is_empty() else "building"
	return {"status":"pending_budget","binding":_binding,"publicationTransactionId":expected_transaction_id}


## Optional ordinary object method: callback(prop_id: String, body: StaticBody3D).
## Owner balances its existing tree-created hook here, BEFORE body.free(). It
## must not harvest, record durable removal, or free the node/subtree itself.
## Required mode accepts only {status:unregistered|absent, objectId:prop:<id>}.
## A recovery callback must reach the SAME registry; absence in a new registry
## is not proof. Once required, acknowledgement cannot be downgraded to void.
func set_tree_retire_callback(callback: Callable, require_acknowledgement := false) -> bool:
	if _phase in ["detach_publishers", "retired", "consumed"]: return false
	if _advancing and (_tree_retire_requires_acknowledgement or require_acknowledgement): return false
	if _tree_retire_requires_acknowledgement and not require_acknowledgement: return false
	if not callback.is_valid() or callback.is_custom() or callback.get_object() == self: return false
	_tree_retire_requires_acknowledgement = require_acknowledgement
	_tree_retire_receiver = weakref(callback.get_object())
	_tree_retire_method = callback.get_method()
	_cleanup_reason = ""
	return true


func own_node_root() -> Node3D:
	return _root if is_instance_valid(_root) else null


## Optional for construction-only diagnostics; an ordinary owner must bind both.
## register(body) acknowledges {status:registered, portalId:<exact source ID>}.
## pending_budget may retry only with sideEffects:false. retire(body) returns
## the shared unregister receipt; only unregistered/absent authorizes freeing.
func set_door_callbacks(register_callback: Callable, retire_callback: Callable) -> bool:
	if _phase != "idle": return false
	for callback in [register_callback, retire_callback]:
		if not callback.is_valid() or callback.is_custom() or callback.get_object() == self: return false
	_door_receiver = weakref(register_callback.get_object())
	_door_method = register_callback.get_method()
	_door_retire_receiver = weakref(retire_callback.get_object())
	_door_retire_method = retire_callback.get_method()
	return true


## Repair a lost cleanup receiver without resuming registration or changing
## claimed leaf identities. The replacement still must acknowledge each leaf.
func set_door_retire_callback(callback: Callable) -> bool:
	if _phase != "teardown" or not callback.is_valid() or callback.is_custom() or callback.get_object() == self: return false
	_door_retire_receiver = weakref(callback.get_object())
	_door_retire_method = callback.get_method()
	_cleanup_reason = ""
	return true


func status_count() -> Dictionary:
	return {"phase":_phase, "buildingParts":_building_cursor,
		"buildingTotal":_blueprint.parts.size() if _blueprint != null else 0,
		"furnitureParts":_furniture_cursor, "furnitureTotal":_plan.parts.size() if _plan != null else 0,
		"treesRegistered":_registered_tree_ids.size(), "treesSkipped":_trees_skipped,
		"treesTotal":_trees.size(), "treeVisualsComplete":_visuals_complete, "freedNodes":_freed_nodes,
		"doorsRegistered":_door_registered_ids.size(), "doorClaims":_door_claims.size(), "doorsRetired":_doors_retired,
		"physicalGroupsComplete":_group_receipts.size(), "physicalGroupsTotal":_groups.get("groups",{}).size(),
		"retainedGroupRequests":_group_requests.size(), "packetForegroundGroups":_packet_foreground_groups.size(),
		"occupiedTransactions":_occupied_transactions.size(),"publicationTransactionId":int(_transaction.get("transactionId",0)),
		"transactionEstimatedCost":_transaction.get("estimatedCost",{})}


func advance(budget_usec: int = 2500, expected_transaction_id: int = -1) -> Dictionary:
	if _advancing: return {"status":"rejected", "reason":"reentrant_advance"}
	if budget_usec < 1 or budget_usec > 4000: return {"status":"rejected", "reason":"invalid_slice_budget"}
	if _phase in ["idle", "ready", "retired", "consumed"]: return status()
	if _base_packet_mode and _phase == "packet_wait":
		var packet_state := pending_publication_transaction()
		return {"status":packet_state.get("status","pending"),"reason":packet_state.get("reason","physical_group_packet_scene_adapter_pending"),
			"binding":_binding,"publicationTransactionId":packet_state.get("id",0)}
	if _phase not in ["teardown","detach_publishers"]:
		if expected_transaction_id < 0 and _transaction.is_empty():
			if pending_publication_transaction().get("status") != "ready": return status()
		if _transaction.is_empty() or (expected_transaction_id >= 0 and int(_transaction.id) != expected_transaction_id):
			return {"status":"rejected","reason":"publication_transaction_changed"}
	var transaction_before: int = int(_transaction.get("id",0))
	_advancing = true
	var started := Time.get_ticks_usec()
	if _last_advance_end_usec>0: _between_advance_usec+=started-_last_advance_end_usec
	_advance_calls+=1
	var slice_phases: Dictionary = {}
	var units := 0
	while units == 0 or Time.get_ticks_usec() - started < budget_usec:
		var phase := _phase
		var atomic_started := Time.get_ticks_usec()
		var progressed := _step(maxi(1, budget_usec - int(atomic_started - started)))
		var elapsed := Time.get_ticks_usec() - atomic_started
		_record_atomic(phase, elapsed, budget_usec)
		units += 1
		slice_phases[phase] = int(slice_phases.get(phase, 0)) + elapsed
		if not progressed or _phase in ["ready", "retired", "consumed"] \
				or transaction_before != int(_transaction.get("id",0)): break
	var elapsed := Time.get_ticks_usec() - started
	_max_slice_usec = maxi(_max_slice_usec, elapsed)
	if elapsed > budget_usec: _overruns += 1
	for phase: String in slice_phases:
		var metric: Dictionary = _phase_metrics[phase]
		metric.maxSliceUsec = maxi(int(metric.maxSliceUsec), int(slice_phases[phase]))
	_advancing = false
	_last_advance_end_usec=Time.get_ticks_usec()
	_advance_cpu_usec+=_last_advance_end_usec-started
	return status()


## Invalidates immediately; no scene traversal or source destruction here.
func cancel() -> void:
	if _phase in ["idle", "retired", "consumed"]: return
	_cancelled = true
	_cancel_revision += 1
	# Stop a roof helper already inside an external publication callback; retain
	# its allocations for the existing owned retirement path.
	if _building!=null and _building._pending_roof!=null: _building._pending_roof.cancel()
	if _reason.is_empty(): _reason = "cancelled"
	_tree_receiver = null
	_tree_method = &""
	_phase = "teardown"


## Only after all scene nodes AND publisher node references have gone. Do not
## clear these containers: the returned payload owns their last large references.
## Includes Godot Resources owned by the detached publishers, not just CPU data.
func take_retirement_payload() -> Dictionary:
	if _phase != "retired" or _taken: return {}
	_taken = true
	var result := _cpu
	_cpu = {}
	_blueprint = null
	_plan = null
	_building = null
	_furniture = null
	_trees = []
	_tree_bodies = []
	_tree_visual_seen = []
	_tree_ids = {}
	_registered_tree_ids = {}
	_tree_retirement_claims = {}
	_tree_claim_order = []
	_spatial = null
	_groups = {}
	_group_requests = {}
	_demand_owners = {}
	_request_heap = []
	_packet_partition_sequences = {}
	_packet_partition_sequence = 0
	_selection_stack = []
	_selection_groups = []
	_selection_members = 0
	_selection_estimated_bytes = 0
	_selection_collision_members = 0
	_selection_registrations = 0
	_selection_partition_key = ""
	_selection_set = {}
	_transaction = {}
	_occupied_transactions = []
	_occupied_group_ids = {}
	_occupied_blocked_requests = []
	_group_receipts = {}
	_member_witnesses = {}
	_boundary_witnesses = {}
	_physical_requirement_memo = {"owner":{},"entries":{},"disabled":false,"retainedEntries":0,"retainedValues":0}
	_tree_by_source_index = {}
	_skipped_tree_indices = {}
	_base_packet_mode = false
	_physical_packet_inbox = {}
	_packet_static_only_groups = {}
	_packet_foreground_groups = {}
	_packet_deferred_groups = {}
	_packet_deferred_group_count = 0
	_packet_foreground_configured = false
	_binding = {}
	_phase = "consumed"
	return result


func status() -> Dictionary:
	var state := "pending_budget"
	if _phase == "idle": state = "idle"
	elif _phase == "ready": state = "ready"
	elif _phase == "consumed": state = "consumed"
	elif _cancelled: state = "cancelled"
	elif not _reason.is_empty(): state = "failed"
	return {"status":state, "reason":_reason, "cleanupReason":_cleanup_reason, "phase":_phase, "binding":_binding,
		"spatialDependencies":_spatial_dependency_summary(),
		"sceneReady":_phase == "ready", "gameplayReady":false,
		"doorLifecycleConfigured":_door_retire_receiver != null,
		"retirementReady":_phase == "retired", "buildingCursor":_building_cursor,
		"furnitureCursor":_furniture_cursor, "treeCursor":_tree_cursor,
		"treeVisualsComplete":_visuals_complete, "treeVisualsRequired":_tree_bodies.size(),
		"counts":status_count(),
		"freedNodes":_freed_nodes, "maxAtomicUsec":_max_atomic_usec,
		"maxSliceUsec":_max_slice_usec, "overruns":_overruns,
		"advanceCalls":_advance_calls,"advanceCpuUsec":_advance_cpu_usec,
		"publicationTransactionId":_transaction.get("id",0),"physicalGroupsComplete":_group_receipts.size(),
		"physicalGroupsTotal":_groups.get("groups",{}).size(),"retainedGroupRequests":_group_requests.size(),
		"packetForegroundGroups":_packet_foreground_groups.size(),"packetDeferredGroups":_packet_deferred_group_count,
		"packetDeferredTransactions":_packet_deferred_transactions,
		# Includes caller work, result snapshots and frame waits; not pure sleep.
		"betweenAdvanceUsec":_between_advance_usec,
		"phaseMetrics":_phase_metrics.duplicate(true),
		"physicalProof":{"byKind":_proof_totals.duplicate(true),"maximum":_proof_maximum.duplicate(),
			"immutableRequirements":_physical_requirement_summary()}}

func _spatial_dependency_summary() -> Dictionary:
	var packet = _cpu.get("buildingBegin",{}).get("spatialDependencies")
	return packet.summary() if packet != null else (_spatial.summary() if _spatial != null else {})


## Borrow the immutable scheduling description without entering scene, member
## or collision proof. The service uses this only after the earlier description
## registry has transferred ownership into the live scene job.
func source_dependency_description(expected_binding: Dictionary):
	if _cancelled or not _reason.is_empty() or expected_binding!=_binding or _spatial==null \
			or _spatial.binding!=_binding or _spatial.origin!=_cpu.get("profile",{}).get("origin",Vector3.INF):
		return null
	return _spatial

func source_dependency_requirements(bounds: Rect2i, expected_binding: Dictionary) -> Dictionary:
	if not _group_owner_available(expected_binding):
		return {"status":"pending","reason":"structure_source_owner_unavailable"}
	# Spatial indexes are sealed immutable worker output. Runtime acceptance adds
	# current door portal/link receipts, so take an owned deep copy before
	# decorating either the result or its nested crossing records.
	var result: Dictionary = _spatial.regional_group_requirements(bounds).duplicate(true)
	if result.get("status") != "described": return result
	var proof: Dictionary = _begin_physical_proof("source_requirements",expected_binding)
	var receipts: Dictionary = {}
	for id: String in result.groupIds: receipts[id] = _physical_group_receipt_with_context(id,proof)
	for source_id: String in result.requiredCrossings:
		var crossing: Dictionary = result.requiredCrossings[source_id]
		if crossing.kind == "doors":
			var key: String = "building:"+String(crossing.sourcePartId)
			if not _member_live_with_context(key,proof): continue
			var body: Node = _member_witnesses[key].body.get_ref() as Node
			var portal_id: String = String(body.get_meta("door_portal_id",""))
			crossing["portalId"] = portal_id
			crossing.requiredLinkIds = ["door-link:%s:%s" % [portal_id,String(crossing.ownerTileKey)]]
			crossing.mappingStatus = "described"
	result["physicalOwnerAcknowledgements"] = {"binding":_binding,"sceneReady":_phase=="ready",
		"sceneInstanceId":_root.get_instance_id() if is_instance_valid(_root) else 0,
		"registeredDoorCount":_door_registered_ids.size(),"groups":receipts}
	_finish_physical_proof(proof)
	return result

func source_dependency_revision() -> Array:
	# Dependency descriptions include live door mappings and group receipts.
	# Keep their invalidation until those facts have a separate owned contract.
	return [_binding,_phase,_cancelled,_reason,_door_registered_ids.size(),_group_receipts.size(),
		_root.get_instance_id() if is_instance_valid(_root) and not _root.is_queued_for_deletion() and _root.is_inside_tree() else 0,
		_root.global_transform if is_instance_valid(_root) and _root.is_inside_tree() else Transform3D.IDENTITY,
		_root.get_parent().get_instance_id() if is_instance_valid(_root) and _root.get_parent()!=null else 0]

func navigation_tile_artifact(tile_key: String, expected_binding: Dictionary, tile_override: Variant = null) -> Dictionary:
	if _cancelled or not _reason.is_empty() or expected_binding!=_binding:
		return {"status":"pending","reason":"structure_navigation_owner_unavailable"}
	var packet = _spatial
	if packet==null or packet.binding!=_binding or packet.origin!=_cpu.profile.origin:
		return {"status":"failed","reason":"structure_navigation_source_mismatch"}
	var parent: Node3D = _parent.get_ref() as Node3D if _parent != null else null
	if not _valid_parent(parent) or not is_instance_valid(_root) or _root.is_queued_for_deletion() \
			or _root.get_parent()!=parent or not _root.is_inside_tree() or not _root.global_transform.is_equal_approx(Transform3D(Basis.IDENTITY,packet.origin)):
		return {"status":"pending","reason":"structure_navigation_scene_owner_lost"}
	var coordinates: PackedStringArray = tile_key.split(",")
	if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int(): return {"status":"failed","reason":"invalid_navigation_tile_key"}
	var bounds: Rect2i = Rect2i(Vector2i(int(coordinates[0]),int(coordinates[1]))*packet.NAV_TILE_CELLS,Vector2i.ONE*packet.NAV_TILE_CELLS)
	var required: Dictionary = _navigation_physical_requirements(packet,tile_key,bounds)
	if required.get("status") != "described": return required.duplicate(true)
	var proof: Dictionary = _begin_physical_proof("navigation_tile",expected_binding)
	var physical_ready := true
	for id: String in required.groupIds:
		if _physical_group_receipt_with_context(id,proof).get("status") != "ready":
			physical_ready = false
			break
	_finish_physical_proof(proof)
	if not physical_ready: return {"status":"pending","reason":"structure_collision_publication_pending"}
	var tile: Dictionary = {}
	if tile_override != null:
		if not tile_override is Dictionary or tile_override.get("status") != "ready" or tile_override.get("binding") != expected_binding \
				or tile_override.get("tileKey") != tile_key or not tile_override.get("tile") is Dictionary or not tile_override.tile.is_read_only():
			return {"status":"failed","reason":"structure_navigation_receipt_mismatch"}
		tile = tile_override.tile
	else:
		if not packet.navigation_tiles.get("ready",false): return {"status":"pending","reason":"structure_navigation_artifact_pending"}
		tile = packet.navigation_tiles.get("tiles",{}).get(tile_key,{})
	var door_bodies := {}
	for fact: Dictionary in tile.get("doors",[]):
		for id in _door_registered_ids:
			var claim: Dictionary = _door_claims.get(id,{})
			var body = claim.body.get_ref() if claim.has("body") else null
			if not _door_body_valid(body): return {"status":"pending","reason":"structure_navigation_door_owner_lost"}
			if String(body.get_meta("building_part_id","")) == String(fact.sourcePartId):
				if String(body.get_meta("door_portal_id","")) != String(claim.portalId):
					return {"status":"failed","reason":"structure_navigation_door_identity_changed"}
				door_bodies[String(fact.sourcePartId)] = claim.body
				break
		if not door_bodies.has(String(fact.sourcePartId)):
			return {"status":"pending","reason":"structure_navigation_door_registration_pending"}
	return {"status":"ready","binding":_binding,"tile":tile,"doorBodies":door_bodies}


## Only immutable source obligations are memoized. Every artifact call still
## runs the live owner, member, collision, boundary and door checks above.
func _navigation_physical_requirements(packet, tile_key: String, bounds: Rect2i) -> Dictionary:
	var started: int = Time.get_ticks_usec()
	_physical_requirement_metrics.lookups += 1
	var owner: Dictionary = _physical_requirement_memo.owner
	var same_owner: bool = not owner.is_empty() and owner.packet == packet \
		and is_same(owner.parts,packet.parts) and is_same(owner.cells,packet.cells) \
		and is_same(owner.groups,packet.publication_groups) and is_same(owner.binding,packet.binding) and owner.origin == packet.origin
	if owner.is_empty():
		_physical_requirement_memo.owner = {"packet":packet,"parts":packet.parts,"cells":packet.cells,
			"groups":packet.publication_groups,"binding":packet.binding,"origin":packet.origin}
	elif not same_owner and not _physical_requirement_memo.disabled:
		# A Job owns one immutable source. Keep only its original memo for worker
		# retirement; never retain an unbounded history of replacement sources.
		_physical_requirement_memo.disabled = true
		_physical_requirement_metrics.ownerChanges += 1
	var entries: Dictionary = _physical_requirement_memo.entries
	if not _physical_requirement_memo.disabled and entries.has(tile_key):
		_physical_requirement_metrics.hits += 1
		_record_physical_requirement_lookup(started)
		return entries[tile_key]
	_physical_requirement_metrics.misses += 1
	var closure_started: int = Time.get_ticks_usec()
	var base: Preparation.PreparedPublicationBase = _cpu.get("publicationBase")
	var compact_plan = base.publication_plan if base!=null and base.matches(_binding) else null
	# The compact plan conservatively contains the authoritative physical-member
	# closure while excluding navigation-domain regions that have no collider in
	# this tile. Topology/crossing output remains owned by `packet` below.
	var result: Dictionary = compact_plan.physical_group_requirements(bounds) if compact_plan!=null \
		else packet.physical_group_requirements(bounds)
	var closure_usec: int = Time.get_ticks_usec()-closure_started
	_physical_requirement_metrics.closureUsec += closure_usec
	_physical_requirement_metrics.maxClosureUsec = maxi(_physical_requirement_metrics.maxClosureUsec,closure_usec)
	var frozen_owner: bool = packet.parts.is_read_only() and packet.cells.is_read_only() \
		and packet.publication_groups.is_read_only() and packet.binding.is_read_only()
	if _physical_requirement_memo.disabled:
		_physical_requirement_metrics.ownerFallbacks += 1
	elif not frozen_owner:
		_physical_requirement_metrics.unfrozenFallbacks += 1
	elif int(_physical_requirement_memo.retainedEntries) >= MAX_PHYSICAL_REQUIREMENT_TILES:
		_physical_requirement_metrics.capacityFallbacks += 1
	else:
		var remaining: int = MAX_PHYSICAL_REQUIREMENT_VALUES-int(_physical_requirement_memo.retainedValues)
		var values: int = _physical_requirement_value_count(result,remaining)
		if values > remaining:
			_physical_requirement_metrics.capacityFallbacks += 1
		else:
			Preparation.SpatialDependencies._freeze(result,Callable())
			entries[tile_key] = result
			_physical_requirement_memo.retainedEntries += 1
			_physical_requirement_memo.retainedValues += values
	_record_physical_requirement_lookup(started)
	return result


static func _physical_requirement_value_count(value: Variant, limit: int) -> int:
	# Count references/values with an early bound; never serialize source data.
	if limit < 1: return 1
	var count: int = 1
	if value is Dictionary:
		for key: Variant in value:
			count += 1+_physical_requirement_value_count(value[key],limit-count-1)
			if count > limit: return count
	elif value is Array:
		for item: Variant in value:
			count += _physical_requirement_value_count(item,limit-count)
			if count > limit: return count
	return count


func _record_physical_requirement_lookup(started: int) -> void:
	var elapsed: int = Time.get_ticks_usec()-started
	_physical_requirement_metrics.lookupUsec += elapsed
	_physical_requirement_metrics.maxLookupUsec = maxi(_physical_requirement_metrics.maxLookupUsec,elapsed)


func _physical_requirement_summary() -> Dictionary:
	var result: Dictionary = _physical_requirement_metrics.duplicate()
	result["activeEntries"] = _physical_requirement_memo.entries.size()
	result["retainedEntries"] = _physical_requirement_memo.retainedEntries
	result["retainedValues"] = _physical_requirement_memo.retainedValues
	result["disabled"] = _physical_requirement_memo.disabled
	return result


## Submission retains intent. Dependency traversal and background selection are
## cooperative; submitting demand never constructs or acknowledges geometry.
func request_publication_groups(group_ids: Array, expected_binding: Dictionary, priority: int = 0) -> Dictionary:
	if not _group_owner_available(expected_binding): return {"status":"pending","reason":"structure_source_owner_unavailable"}
	for id in group_ids:
		if not id is String or not _groups.groups.has(id): return {"status":"failed","reason":"unknown_publication_group"}
	var direct: Dictionary = _demand_owners.get("scene-job:direct",{})
	for id: String in group_ids:
		direct[id] = mini(int(direct.get(id,priority)),priority)
		_enqueue_group(id,priority)
	_demand_owners["scene-job:direct"] = direct
	return {"status":"retained","binding":_binding,"requestedGroups":group_ids.size()}


func replace_publication_group_demands(requests: Array, expected_binding: Dictionary) -> Dictionary:
	if not _group_owner_available(expected_binding): return {"status":"pending","reason":"structure_source_owner_unavailable"}
	var owners: Dictionary = {}
	var desired: Dictionary = {}
	for request in requests:
		if not request is Dictionary or not request.get("ownerId") is String or String(request.ownerId).is_empty() \
				or request.ownerId == "scene-job:direct" or owners.has(request.ownerId) or not request.get("groupIds") is Array \
				or not request.get("priority") is int:
			return {"status":"failed","reason":"invalid_publication_group_demand"}
		var groups: Dictionary = {}
		for id in request.groupIds:
			if not id is String or not _groups.groups.has(id): return {"status":"failed","reason":"unknown_publication_group"}
			groups[id] = int(request.priority)
			if not desired.has(id) or int(desired[id]) > int(request.priority): desired[id] = int(request.priority)
		owners[request.ownerId] = groups
	var direct: Dictionary = _demand_owners.get("scene-job:direct",{})
	if not direct.is_empty():
		owners["scene-job:direct"] = direct
		for id: String in direct: desired[id] = mini(int(desired.get(id,direct[id])),int(direct[id]))
	# Demand refreshes are expected on every owner frame.  Rebuilding the heap
	# here for an equivalent ownership map would discard the cooperative
	# selection stack before it can ever pin a physical packet.  Keep the
	# in-progress selection until an owner, priority, or group actually changes.
	# The packet still receives a fresh physical validation after compilation and
	# again at scene installation; this only preserves scheduling progress.
	if _demand_owners == owners:
		return {"status":"retained","binding":_binding,"demandOwners":requests.size()}
	var previous: Dictionary = _group_requests
	_demand_owners = owners
	_group_requests = {}
	_request_heap.clear()
	_occupied_blocked_requests.clear()
	# A foreground closure is normally emitted in view/readiness order, while
	# source IDs inside it are semantic. Retain the first occurrence of each
	# spatial packet partition, then keep its peers adjacent in the heap. Without
	# this packet-local rank an interleaved Citadel closure pins one tiny worker
	# packet whenever the next semantic ID happens to live in another block.
	_packet_partition_sequences = {}
	_packet_partition_sequence = 0
	for id: String in desired:
		if _group_receipts.has(id): continue
		# Preserve original age when priority/owner changes without removing the
		# group. Heap records are new, so obsolete promoted entries cannot win.
		if previous.has(id): _group_requests[id] = {"id":id,"priority":2147483647,"sequence":previous[id].sequence}
		_enqueue_group(id,int(desired[id]))
	_cpu["groupRequests"] = _group_requests
	_cpu["demandOwners"] = _demand_owners
	_selection_stack.clear()
	_selection_groups = []
	_selection_set = {}
	_selection_members = 0
	_selection_estimated_bytes = 0
	_selection_collision_members = 0
	_selection_registrations = 0
	_selection_partition_key = ""
	_selection_has_demand = false
	# Reset only the cheap background iterator. Already committed groups are
	# skipped; pinned groups remain owned by their original immutable transaction.
	_background_cursor = 0
	return {"status":"retained","binding":_binding,"demandOwners":requests.size()}


## Packet-mode foreground admission. `requests` is the complete currently
## publishable closure; `deferred_group_ids` explicitly accounts for every
## still-unpublished group outside that closure. Keeping the two sets complete
## makes an empty foreground an intentional wait, never permission to resume
## the legacy source-wide background iterator.
##
## A pending packet has not mutated the scene. If a later demand update moves
## its exact scope to deferred before the worker packet arrives, discard only
## that pin. Existing root, committed receipts, and retained worker artifacts
## stay owned by this resident job.
func replace_packet_foreground_group_demands(requests: Array, deferred_group_ids: Array, expected_binding: Dictionary) -> Dictionary:
	if not _base_packet_mode: return {"status":"failed","reason":"packet_foreground_requires_packet_mode"}
	if not _group_owner_available(expected_binding): return {"status":"pending","reason":"structure_source_owner_unavailable"}
	var foreground: Dictionary = {}
	for request in requests:
		if not request is Dictionary or not request.get("groupIds") is Array:
			return {"status":"failed","reason":"invalid_packet_foreground_demand"}
		for id in request.groupIds:
			if not id is String or not _groups.groups.has(id): return {"status":"failed","reason":"unknown_publication_group"}
			foreground[id] = true
	var deferred: Dictionary = {}
	for id in deferred_group_ids:
		if not id is String or not _groups.groups.has(id): return {"status":"failed","reason":"unknown_publication_group"}
		if foreground.has(id): return {"status":"failed","reason":"packet_foreground_deferred_overlap"}
		deferred[id] = true
	for id: String in _groups.groups:
		if _group_receipts.has(id): continue
		if not foreground.has(id) and not deferred.has(id):
			return {"status":"failed","reason":"packet_group_scope_incomplete"}
	for id: String in foreground:
		for dependency: String in _groups.groups[id].dependencies:
			if not _group_receipts.has(dependency) and not foreground.has(dependency):
				return {"status":"failed","reason":"packet_foreground_dependency_deferred"}
	var retained: Dictionary = replace_publication_group_demands(requests,expected_binding)
	if retained.get("status") != "retained": return retained
	_packet_foreground_groups = foreground
	_packet_deferred_groups = deferred
	_packet_deferred_group_count = deferred.size()
	_packet_foreground_configured = true
	_cpu["packetForegroundGroups"] = _packet_foreground_groups
	_cpu["packetDeferredGroups"] = _packet_deferred_groups
	_defer_unoffered_packet_transaction()
	return {"status":"retained","binding":_binding,"foregroundGroups":foreground.size(),"deferredGroups":deferred.size(),
		"deferredTransactionCount":_packet_deferred_transactions}


## Compact equivalent for a worker-built complete publication plan. Every
## unfinished group not named by foreground is deferred by definition, so no
## source-wide complement is copied on a camera-only revision.
func replace_packet_foreground_group_demands_compact(requests: Array, explicit_deferred_group_ids: Array,
		expected_binding: Dictionary) -> Dictionary:
	if not _base_packet_mode: return {"status":"failed","reason":"packet_foreground_requires_packet_mode"}
	if not _group_owner_available(expected_binding): return {"status":"pending","reason":"structure_source_owner_unavailable"}
	var foreground: Dictionary = {}
	for request in requests:
		if not request is Dictionary or not request.get("groupIds") is Array:
			return {"status":"failed","reason":"invalid_packet_foreground_demand"}
		for id in request.groupIds:
			if not id is String or not _groups.groups.has(id): return {"status":"failed","reason":"unknown_publication_group"}
			foreground[id] = true
	for id: String in foreground:
		for dependency: String in _groups.groups[id].dependencies:
			if not _group_receipts.has(dependency) and not foreground.has(dependency):
				return {"status":"failed","reason":"packet_foreground_dependency_deferred"}
	var explicit_deferred: Dictionary = {}
	for id in explicit_deferred_group_ids:
		if not id is String or not _groups.groups.has(id) or foreground.has(id):
			return {"status":"failed","reason":"invalid_packet_explicit_deferred_group"}
		explicit_deferred[id] = true
	var retained: Dictionary = replace_publication_group_demands(requests,expected_binding)
	if retained.get("status") != "retained": return retained
	_packet_foreground_groups = foreground
	_packet_deferred_groups = explicit_deferred
	var unfinished_foreground := foreground.size()
	for id: String in foreground:
		if _group_receipts.has(id): unfinished_foreground -= 1
	_packet_deferred_group_count = maxi(0,_groups.groups.size()-_group_receipts.size()-unfinished_foreground)
	_packet_foreground_configured = true
	_cpu["packetForegroundGroups"] = _packet_foreground_groups
	_cpu["packetDeferredGroups"] = _packet_deferred_group_count
	_defer_unoffered_packet_transaction()
	return {"status":"retained","binding":_binding,"foregroundGroups":foreground.size(),
		"deferredGroups":_packet_deferred_group_count,"deferredTransactionCount":_packet_deferred_transactions}


## Replace dependency-complete navigation collision demand without rebuilding
## the unchanged view owners. Old approach tiles may be demoted or released,
## so a reversal cannot leave every previously foreground tile at priority 0.
func retain_packet_supplemental_group_demands(requests: Array, expected_binding: Dictionary) -> Dictionary:
	if not _base_packet_mode: return {"status":"failed","reason":"packet_foreground_requires_packet_mode"}
	if not _group_owner_available(expected_binding): return {"status":"pending","reason":"structure_source_owner_unavailable"}
	var additions: Dictionary = {}
	for request in requests:
		if not request is Dictionary or not request.get("groupIds") is Array or not request.get("priority") is int:
			return {"status":"failed","reason":"invalid_packet_supplemental_demand"}
		var priority: int = int(request.priority)
		if priority<0 or priority>4: return {"status":"failed","reason":"invalid_packet_supplemental_priority"}
		for id in request.groupIds:
			if not id is String or not _groups.groups.has(id): return {"status":"failed","reason":"unknown_publication_group"}
			additions[id]=mini(int(additions.get(id,priority)),priority)
	for id: String in additions:
		for dependency: String in _groups.groups[id].dependencies:
			if not _group_receipts.has(dependency) and not _packet_foreground_groups.has(dependency) and not additions.has(dependency):
				return {"status":"failed","reason":"packet_supplemental_dependency_missing"}
	var navigation_owner: Dictionary={}
	for id: String in additions: navigation_owner[id]=int(additions[id])
	_demand_owners["scene-job:navigation"]=navigation_owner
	var desired: Dictionary={}
	for owner: Dictionary in _demand_owners.values():
		for id: String in owner:
			desired[id]=mini(int(desired.get(id,owner[id])),int(owner[id]))
	var previous: Dictionary=_group_requests
	for id: String in previous:
		if not desired.has(id): _group_requests.erase(id)
	for id: String in desired:
		if _group_receipts.has(id): continue
		if previous.has(id) and int(previous[id].priority)!=int(desired[id]):
			_group_requests[id]={"id":id,"priority":2147483647,"sequence":previous[id].sequence}
		_enqueue_group(id,int(desired[id]))
	_packet_foreground_groups={}
	for id: String in desired:
		if not _group_receipts.has(id): _packet_foreground_groups[id]=true
		_packet_deferred_groups.erase(id)
	# A not-yet-pinned selection is scheduling state only. Rebuild it from the
	# latest owner priorities; an immutable pinned/offered transaction is retained.
	_selection_stack.clear()
	_selection_groups=[]
	_selection_set={}
	_selection_members=0
	_selection_estimated_bytes=0
	_selection_collision_members=0
	_selection_registrations=0
	_selection_partition_key=""
	_selection_has_demand=false
	_cpu["groupRequests"]=_group_requests
	_cpu["demandOwners"]=_demand_owners
	_cpu["packetForegroundGroups"]=_packet_foreground_groups
	var unfinished_foreground := _packet_foreground_groups.size()
	for id: String in _packet_foreground_groups:
		if _group_receipts.has(id): unfinished_foreground-=1
	_packet_deferred_group_count=maxi(0,_groups.groups.size()-_group_receipts.size()-unfinished_foreground)
	_cpu["packetDeferredGroups"]=_packet_deferred_group_count
	return {"status":"retained","binding":_binding,"supplementalGroups":additions.size(),
		"foregroundGroups":_packet_foreground_groups.size(),"deferredGroups":_packet_deferred_group_count}


func _defer_unoffered_packet_transaction() -> void:
	if not _base_packet_mode or _transaction.is_empty() or _phase != "packet_wait": return
	if _transaction.get("status") != "pending" or _transaction.get("reason") != "physical_group_packet_pending": return
	var key := String(_transaction.get("physicalPacketKey",""))
	# An offered immutable packet is already owned by the job. Do not withdraw it
	# underneath the service; a later foreground update can still select it.
	if _physical_packet_inbox.has(key): return
	for id: String in _transaction.get("groupIds",[]):
		if _packet_foreground_groups.has(id): return
	_transaction = {}
	_cpu["activePublicationTransaction"] = {}
	_packet_deferred_transactions += 1


func _enqueue_group(id: String, priority: int) -> void:
	# A parked occupancy transaction still owns its exact uncommitted groups.
	# Demand refresh may rebuild the heap while that actor remains in place, but
	# it must not compile a second packet for the same physical members.
	if _group_receipts.has(id) or _occupied_group_ids.has(id): return
	var previous: Dictionary = _group_requests.get(id,{})
	if not previous.is_empty() and int(previous.priority) <= priority: return
	if previous.is_empty(): _request_sequence += 1
	var partition_sequence := 0
	if _base_packet_mode:
		var partition := _packet_partition_key(id)
		if not _packet_partition_sequences.has(partition):
			_packet_partition_sequence += 1
			_packet_partition_sequences[partition] = _packet_partition_sequence
		partition_sequence = int(_packet_partition_sequences[partition])
	var entry: Dictionary = {"id":id,"priority":priority,"sequence":previous.get("sequence",_request_sequence),
		"packetPartitionSequence":partition_sequence}
	_group_requests[id] = entry
	_request_heap.append(entry)
	var index: int = _request_heap.size()-1
	while index > 0:
		var parent_index: int = (index-1)/2
		if not _request_precedes(_request_heap[index],_request_heap[parent_index]): break
		var swap: Dictionary = _request_heap[parent_index]
		_request_heap[parent_index] = _request_heap[index]
		_request_heap[index] = swap
		index = parent_index


func _group_closure_reserved_by_occupancy(group_id: String) -> bool:
	if _occupied_group_ids.is_empty(): return false
	var pending: Array[String] = [group_id]
	var visited: Dictionary = {}
	while not pending.is_empty():
		var id: String = pending.pop_back()
		if visited.has(id): continue
		visited[id] = true
		if _occupied_group_ids.has(id): return true
		for dependency: String in _groups.groups.get(id,{}).get("dependencies",[]): pending.append(dependency)
	return false


func _release_occupancy_blocked_requests() -> void:
	if _occupied_blocked_requests.is_empty(): return
	var retained: Array[Dictionary] = []
	for entry: Dictionary in _occupied_blocked_requests:
		var id := String(entry.get("id",""))
		if id.is_empty() or _group_receipts.has(id) or not _group_requests.has(id): continue
		if _group_closure_reserved_by_occupancy(id):
			retained.append(entry)
			continue
		# Reuse the original request age. The sentinel makes the normal heap
		# insertion path replace this still-owned request without inventing a new
		# demand or allowing a duplicate scope.
		_group_requests[id] = {"id":id,"priority":2147483647,"sequence":entry.get("sequence",_request_sequence)}
		_enqueue_group(id,int(entry.get("priority",2147483647)))
	_occupied_blocked_requests = retained


func _request_precedes(a: Dictionary, b: Dictionary) -> bool:
	if int(a.priority)!=int(b.priority): return int(a.priority)<int(b.priority)
	if _base_packet_mode and int(a.get("packetPartitionSequence",0))!=int(b.get("packetPartitionSequence",0)):
		return int(a.get("packetPartitionSequence",0))<int(b.get("packetPartitionSequence",0))
	return int(a.sequence)<int(b.sequence)


func _pop_request() -> Dictionary:
	if _request_heap.is_empty(): return {}
	var result: Dictionary = _request_heap[0]
	var last: Dictionary = _request_heap.pop_back()
	if not _request_heap.is_empty():
		_request_heap[0] = last
		var index: int = 0
		while index*2+1 < _request_heap.size():
			var child: int = index*2+1
			if child+1 < _request_heap.size() and _request_precedes(_request_heap[child+1],_request_heap[child]): child += 1
			if not _request_precedes(_request_heap[child],_request_heap[index]): break
			var swap: Dictionary = _request_heap[index]
			_request_heap[index] = _request_heap[child]
			_request_heap[child] = swap
			index = child
	return result


## Pin one transaction before the owner's occupancy guard. This may spend a
## bounded selection slice and return pending_budget, with NO scene mutation.
## Once pinned, priority promotion cannot widen its collision envelope.
func pending_publication_transaction() -> Dictionary:
	if _cancelled: return {"status":"cancelled","reason":_reason,"binding":_binding}
	if not _reason.is_empty(): return {"status":"failed","reason":_reason,"binding":_binding}
	if not _group_owner_available(_binding): return {"status":"pending","reason":"structure_source_owner_unavailable"}
	if _phase == "ready": return {"status":"complete","binding":_binding}
	if not _transaction.is_empty():
		if _base_packet_mode and _transaction.get("status") == "pending" \
				and _transaction.get("reason") == "physical_group_packet_pending" \
				and _physical_packet_inbox.has(String(_transaction.get("physicalPacketKey",""))):
			var ready_transaction: Dictionary = _transaction.duplicate(true)
			ready_transaction["status"] = "ready"
			ready_transaction["reason"] = ""
			ready_transaction.make_read_only()
			_transaction = ready_transaction
			_cpu["activePublicationTransaction"] = _transaction
		return _transaction
	var started: int = Time.get_ticks_usec()
	while Time.get_ticks_usec()-started < SELECTION_BUDGET_USEC:
		if _selection_stack.is_empty():
			if _base_packet_mode and not _selection_groups.is_empty():
				var next_entry := _peek_request()
				if next_entry.is_empty() or _selection_soft_limit_reached() \
						or _packet_partition_key(String(next_entry.id)) != _selection_partition_key:
					return _pin_transaction()
			var entry: Dictionary = _pop_request()
			if not entry.is_empty():
				if not is_same(_group_requests.get(entry.id),entry) or _group_receipts.has(entry.id) or _selection_set.has(entry.id): continue
				if _group_closure_reserved_by_occupancy(String(entry.id)):
					_occupied_blocked_requests.append(entry)
					continue
				_selection_has_demand = _selection_has_demand or int(entry.priority)<2147483647
				if _base_packet_mode and _selection_groups.is_empty():
					_selection_partition_key = _packet_partition_key(String(entry.id))
				_selection_stack.append({"id":entry.id,"priority":entry.priority,"cursor":0})
			elif not _selection_groups.is_empty():
				return _pin_transaction()
			elif _base_packet_mode:
				# Packet publication has no implicit background work. The caller must
				# retain an explicit foreground closure before another transaction can
				# be selected; deferred source groups stay resident at the service.
				if not _occupied_transactions.is_empty(): return _restore_occupied_transaction()
				return {"status":"pending","reason":"physical_packet_foreground_demand_pending","binding":_binding,
					"foregroundGroups":_packet_foreground_groups.size(),"deferredGroups":_packet_deferred_group_count}
			elif _background_cursor < _groups.order.size():
				var id: String = _groups.order[_background_cursor]
				_background_cursor += 1
				if _group_receipts.has(id): continue
				_selection_stack.append({"id":id,"priority":2147483647,"cursor":0})
			else:
				if _group_receipts.size() != _groups.groups.size():
					if not _occupied_transactions.is_empty(): return _restore_occupied_transaction()
					_fail("publication_group_selection_incomplete")
					return {"status":"failed","reason":_reason}
				return _pin_transaction()
		var frame: Dictionary = _selection_stack[-1]
		var group: Dictionary = _groups.groups[frame.id]
		if _group_receipts.has(frame.id) or _selection_set.has(frame.id):
			_selection_stack.pop_back()
			continue
		if int(frame.cursor) < group.dependencies.size():
			var dependency: String = group.dependencies[int(frame.cursor)]
			frame.cursor += 1
			if not _group_receipts.has(dependency) and not _selection_set.has(dependency):
				_enqueue_group(dependency,int(frame.priority))
				_selection_stack.append({"id":dependency,"priority":frame.priority,"cursor":0})
			continue
		var members: int = group.members.size()
		var group_collisions: int = group.collisionMemberBounds.size()
		var group_registrations: int = group.furnitureIndices.size()+group.treeIndices.size()
		var group_bytes: int = group.buildingIndices.size()*ESTIMATED_BUILDING_MEMBER_BYTES \
			+group.furnitureIndices.size()*ESTIMATED_FURNITURE_MEMBER_BYTES \
			+group.treeIndices.size()*ESTIMATED_TREE_MEMBER_BYTES+group_collisions*ESTIMATED_COLLISION_PROOF_BYTES
		# Never split one dependency root from the support groups already selected
		# beneath it. Soft caps are checked above only after the DFS stack empties,
		# before another independent root is admitted. A closure may therefore
		# exceed a soft packet target, but cannot publish a child ahead of an
		# occupancy-deferred support transaction.
		_selection_stack.pop_back()
		_selection_groups.append(String(frame.id))
		_selection_set[frame.id] = true
		_selection_members += members
		_selection_estimated_bytes += group_bytes
		_selection_collision_members += group_collisions
		_selection_registrations += group_registrations
		if _base_packet_mode and _selection_stack.is_empty() and _request_heap.is_empty():
			return _pin_transaction()
		# Coalesce background peers too. A queued demand is selected first on the
		# next iteration; completed groups are never pulled into a new guard.
		if _selection_stack.is_empty() and _request_heap.is_empty() and _selection_has_demand: return _pin_transaction()
		if _selection_stack.is_empty() and _request_heap.is_empty() and _background_cursor < _groups.order.size():
			var id: String = _groups.order[_background_cursor]
			_background_cursor += 1
			if not _group_receipts.has(id) and not _selection_set.has(id):
				_selection_stack.append({"id":id,"priority":2147483647,"cursor":0})
	return {"status":"pending_budget","reason":"publication_group_selection_pending","binding":_binding}


func _selection_soft_limit_reached() -> bool:
	return _selection_groups.size()>=MAX_TRANSACTION_GROUPS or _selection_members>=MAX_TRANSACTION_MEMBERS \
		or _selection_estimated_bytes>=MAX_TRANSACTION_ESTIMATED_BYTES \
		or _selection_collision_members>=MAX_TRANSACTION_COLLISION_MEMBERS \
		or _selection_registrations>=MAX_TRANSACTION_REGISTRATIONS


## Rotate an occupancy-blocked, still immutable transaction behind other
## retained work. No member is reselected, rebuilt or acknowledged while it
## waits; its exact source binding and transaction id survive every yield.
func defer_occupied_publication_transaction(expected_transaction_id: int, reason := "actor_occupancy") -> Dictionary:
	if _transaction.is_empty() or int(_transaction.get("transactionId",0))!=expected_transaction_id \
			or _phase in ["teardown","detach_publishers","retired","consumed"]:
		return {"status":"rejected","reason":"publication_transaction_changed"}
	# Rotation is a pre-activation scheduling operation. Once a packet has
	# attached members or begun a publication boundary, its cursors and witnesses
	# must remain pinned; the service pauses that transaction in place instead.
	if _base_packet_mode and _phase!="packet_wait":
		return {"status":"rejected","reason":"occupied_packet_rotation_after_scene_mutation"}
	var retained: Dictionary = _transaction.duplicate(true)
	retained["occupancyWaitReason"] = reason
	retained["occupancyWaitStartedUsec"] = int(retained.get("occupancyWaitStartedUsec",Time.get_ticks_usec()))
	retained["occupancyWaitCount"] = int(retained.get("occupancyWaitCount",0))+1
	retained["resumePhase"] = _phase
	retained.make_read_only()
	_occupied_transactions.append(retained)
	for id: String in retained.get("groupIds",[]): _occupied_group_ids[id] = true
	_transaction = {}
	_cpu["activePublicationTransaction"] = {}
	_cpu.erase("activePhysicalPacket")
	_packet_static_only_groups = {}
	_transaction_building_cursor = 0
	_transaction_furniture_cursor = 0
	_transaction_tree_cursor = 0
	_transaction_visual_cursor = 0
	_phase = "packet_wait" if _base_packet_mode else "transaction_select"
	return {"status":"retained","transactionId":expected_transaction_id,"reason":reason}


func _restore_occupied_transaction() -> Dictionary:
	var retained: Dictionary = _occupied_transactions.pop_front()
	for id: String in retained.get("groupIds",[]): _occupied_group_ids.erase(id)
	_transaction = retained
	_cpu["activePublicationTransaction"] = retained
	if _base_packet_mode:
		var packet = _physical_packet_inbox.get(String(retained.get("physicalPacketKey","")))
		if packet != null:
			_cpu["activePhysicalPacket"] = packet
			_packet_static_only_groups = _packet_static_only_groups_for(packet)
		_phase = String(retained.get("resumePhase","packet_wait"))
	else:
		_phase = String(retained.get("resumePhase","building"))
	return _transaction


func _pin_transaction() -> Dictionary:
	_transaction_serial += 1
	# Physical packets are immutable value artifacts keyed by their complete
	# group scope. The normal scene path preserves dependency-first selection
	# order, but packet compilation deliberately accepts only canonical IDs.
	# Normalize before both the transaction key and the packet worker see this
	# scope; sorting later in the service would break packet/transaction identity.
	if _base_packet_mode: _selection_groups.sort()
	var building_indices: Array[int] = []
	var furniture_indices: Array[int] = []
	var tree_indices: Array[int] = []
	var collision_bounds: Array[AABB] = []
	for id: String in _selection_groups:
		var group: Dictionary = _groups.groups[id]
		building_indices.append_array(group.buildingIndices)
		furniture_indices.append_array(group.furnitureIndices)
		tree_indices.append_array(group.treeIndices)
		collision_bounds.append_array(group.collisionMemberBounds)
	for indices: Array in [building_indices,furniture_indices,tree_indices]: indices.sort(); indices.make_read_only()
	_selection_groups.make_read_only()
	collision_bounds.make_read_only()
	var group_key := _physical_packet_key(_selection_groups)
	var estimated_bytes := building_indices.size()*ESTIMATED_BUILDING_MEMBER_BYTES \
		+furniture_indices.size()*ESTIMATED_FURNITURE_MEMBER_BYTES \
		+tree_indices.size()*ESTIMATED_TREE_MEMBER_BYTES \
		+collision_bounds.size()*ESTIMATED_COLLISION_PROOF_BYTES
	var estimated_cost := {"bytes":estimated_bytes,"geometryMembers":building_indices.size(),
		"collisionMembers":collision_bounds.size(),"registrations":furniture_indices.size()+tree_indices.size(),
		"byteLimit":MAX_TRANSACTION_ESTIMATED_BYTES,"collisionLimit":MAX_TRANSACTION_COLLISION_MEMBERS,
		"registrationLimit":MAX_TRANSACTION_REGISTRATIONS}
	estimated_cost.make_read_only()
	var transaction_status := "ready"
	var transaction_reason := ""
	if _base_packet_mode and not _physical_packet_inbox.has(group_key):
		transaction_status = "pending"
		transaction_reason = "physical_group_packet_pending"
	_transaction = {"status":transaction_status,"reason":transaction_reason,"binding":_binding,"id":_transaction_serial,"transactionId":_transaction_serial,
		"groupIds":_selection_groups,"buildingIndices":building_indices,"furnitureIndices":furniture_indices,
		"treeIndices":tree_indices,"collisionMemberBounds":collision_bounds,"physicalPacketKey":group_key,
		"estimatedCost":estimated_cost,"pinnedUsec":Time.get_ticks_usec(),"cancelRevision":_cancel_revision}
	_transaction.make_read_only()
	_cpu["activePublicationTransaction"] = _transaction
	_selection_groups = []
	_selection_set = {}
	_selection_members = 0
	_selection_estimated_bytes = 0
	_selection_collision_members = 0
	_selection_registrations = 0
	_selection_partition_key = ""
	_selection_has_demand = false
	_transaction_building_cursor = 0
	_transaction_furniture_cursor = 0
	_transaction_tree_cursor = 0
	_transaction_visual_cursor = 0
	if _base_packet_mode:
		# Every packet, including a resident-session append, waits for the
		# service-owned immutable artifact before any Node mutation begins.
		_phase = "packet_wait"
	elif _phase == "transaction_select":
		_phase = "building_finish" if _transaction.groupIds.is_empty() else "building"
	return _transaction


static func _physical_packet_key(group_ids: Array[String]) -> String:
	return var_to_bytes(group_ids).hex_encode()


## Packet roots may share one worker/installation transaction only inside a
## small deterministic spatial partition. Door roots remain isolated because
## their portal lifecycle is independently acknowledged. An actor occupying a
## different room/house therefore cannot hold the rest of the Citadel while
## nearby collision-bearing peers avoid one worker round trip per group.
func _packet_partition_key(group_id: String) -> String:
	var group: Dictionary = _groups.get("groups",{}).get(group_id,{})
	if group.is_empty() or not group.get("doorPartIds",[]).is_empty():
		return "isolated:"+group_id
	var bounds: Variant = group.get("collisionBounds",group.get("bounds"))
	if not bounds is AABB or not bounds.position.is_finite() or not bounds.size.is_finite():
		return "isolated:"+group_id
	var center: Vector3 = bounds.get_center()
	return "%d,%d,%d" % [floori(center.x/PACKET_PARTITION_WORLD_SIZE),
		floori(center.y/PACKET_PARTITION_WORLD_SIZE),floori(center.z/PACKET_PARTITION_WORLD_SIZE)]


## Discard stale heap heads without consuming the next live request. This is
## the same identity test as _pop_request and does not change FIFO age.
func _peek_request() -> Dictionary:
	while not _request_heap.is_empty():
		var entry: Dictionary = _request_heap[0]
		if is_same(_group_requests.get(entry.id),entry) and not _group_receipts.has(entry.id) \
				and not _selection_set.has(entry.id):
			return entry
		_pop_request()
	return {}


## Classify directly from the immutable packet entries and this exact pinned
## transaction scope. A group is static-only only when every one of its source
## building members has an admitted empty family map. This never infers the
## fact from kind/material or from a later restored scene graph.
func _packet_static_only_groups_for(packet: Preparation.PreparedPhysicalGroupPacket) -> Dictionary:
	var result: Dictionary = {}
	if packet == null or packet.group_ids != _transaction.get("groupIds",[]): return result
	for group_id: String in packet.group_ids:
		var group: Variant = _groups.groups.get(group_id)
		if not group is Dictionary: return {}
		var has_member := false
		var static_only := true
		for raw_index: int in group.buildingIndices:
			if _cpu.get("packetSceneSource",{}).get("blueprint")==null or raw_index<0 or raw_index>=_cpu.packetSceneSource.blueprint.parts.size(): return {}
			var part_id := String(_cpu.packetSceneSource.blueprint.parts[raw_index].id)
			var entry: Variant = packet.building_entries.get(part_id)
			if not entry is Dictionary or not entry.get("families") is Dictionary: return {}
			has_member = true
			if not entry.families.is_empty(): static_only=false
		if has_member and static_only: result[group_id] = true
	result.make_read_only()
	return result


func _group_owner_available(expected_binding: Dictionary) -> bool:
	return not _cancelled and _reason.is_empty() and _phase not in ["idle","teardown","detach_publishers","retired","consumed"] \
		and expected_binding == _binding and _spatial != null and _spatial.binding == _binding \
		and _spatial.origin == _cpu.profile.origin and is_same(_spatial.publication_groups,_groups)


func _scene_owner_live() -> bool:
	var parent: Node3D = _parent.get_ref() as Node3D if _parent != null else null
	return _valid_parent(parent) and is_instance_valid(_root) and not _root.is_queued_for_deletion() \
		and _root.is_inside_tree() and _root.get_parent() == parent \
		and _root.global_transform.is_equal_approx(Transform3D(Basis.IDENTITY,_spatial.origin))


## Live physical acknowledgement, distinct from obligations or navigation acks.
## A root/leaf/batch loss, source replacement or cancellation revokes it even
## after a previous caller observed ready. No historical counter is authority.
func physical_group_receipt(group_id: String, expected_binding: Dictionary) -> Dictionary:
	var proof: Dictionary = _begin_physical_proof("single_receipt",expected_binding)
	var result: Dictionary = _physical_group_receipt_with_context(group_id,proof)
	_finish_physical_proof(proof)
	return result


## Exact multi-group readiness with one live proof context. This has identical
## authority to calling `physical_group_receipt` for every ID, but shared
## member/boundary witnesses are checked once instead of once per dependency.
func physical_groups_receipt(group_ids: Array, expected_binding: Dictionary) -> Dictionary:
	var proof: Dictionary = _begin_physical_proof("group_set_receipt",expected_binding)
	var pending: Array[String] = []
	for raw_id in group_ids:
		if not raw_id is String or raw_id.is_empty() or not _groups.get("groups",{}).has(raw_id):
			_finish_physical_proof(proof)
			return {"status":"failed","reason":"unknown_publication_group"}
		if _physical_group_receipt_with_context(raw_id,proof).get("status")!="ready": pending.append(raw_id)
	_finish_physical_proof(proof)
	return {"status":"ready","reason":"","groupCount":group_ids.size()} if pending.is_empty() \
		else {"status":"pending","reason":"physical_group_publication_pending","pendingGroupIds":pending}

func completed_physical_group_ids(expected_binding: Dictionary) -> Dictionary:
	if not _group_owner_available(expected_binding): return {}
	var result: Dictionary = {}
	for id: String in _group_receipts: result[id]=true
	return result


## Scheduling observation only. It does not validate live nodes/collision and
## must never be used as a gameplay-readiness receipt.
func physical_group_packet_completed_for_scheduling(group_id: String, expected_binding: Dictionary) -> bool:
	return _group_owner_available(expected_binding) and _group_receipts.has(group_id)


## A packet-static receipt is a live physical receipt with the exact immutable
## static/collision member scope retained. It is deliberately not a prediction:
## root, collision, batch, binding, and cancellation validation still happen in
## physical_group_receipt before service or tile code can observe ready.
func static_only_group_receipt(group_id: String, expected_binding: Dictionary) -> Dictionary:
	var receipt := physical_group_receipt(group_id,expected_binding)
	if receipt.get("status")!="ready": return receipt
	if receipt.get("publicationKind")!="packet_static_only":
		return {"status":"pending","reason":"structure_static_packet_receipt_pending"}
	return receipt


## A proof context exists for one nonyielding call only. No callbacks, frame
## cache or historical ready flag can substitute for the next live validation.
func _begin_physical_proof(kind: String, expected_binding: Dictionary) -> Dictionary:
	var counters: Dictionary = {}
	for key: String in PROOF_COUNTERS: counters[key] = 0
	return {"kind":kind,"started":Time.get_ticks_usec(),"counters":counters,
		"ownerLive":_group_owner_available(expected_binding) and _scene_owner_live(),
		"groups":{},"members":{},"boundaries":{}}


func _finish_physical_proof(proof: Dictionary) -> void:
	var elapsed: int = Time.get_ticks_usec()-int(proof.started)
	var kind: String = proof.kind
	if not _proof_totals.has(kind):
		_proof_totals[kind] = {"calls":0,"totalUsec":0,"maxUsec":0}
		for key: String in PROOF_COUNTERS: _proof_totals[kind][key] = 0
	var totals: Dictionary = _proof_totals[kind]
	totals.calls += 1
	totals.totalUsec += elapsed
	totals.maxUsec = maxi(int(totals.maxUsec),elapsed)
	for key: String in PROOF_COUNTERS: totals[key] += int(proof.counters[key])
	if elapsed > int(_proof_maximum.get("elapsedUsec",-1)):
		_proof_maximum = proof.counters.duplicate()
		_proof_maximum["kind"] = kind
		_proof_maximum["elapsedUsec"] = elapsed


func _physical_group_receipt_with_context(group_id: String, proof: Dictionary) -> Dictionary:
	if not proof.ownerLive: return {"status":"pending","reason":"structure_physical_owner_unavailable"}
	if not _groups.groups.has(group_id): return {"status":"failed","reason":"unknown_publication_group"}
	if not _group_receipts.has(group_id): return {"status":"pending","reason":"structure_collision_publication_pending"}
	# Enter members before dependencies; descend in the original stack's reverse
	# dependency order. Completed closures may be shared by another root query.
	var stack: Array[Dictionary] = [{"id":group_id,"entered":false,"cursor":-1}]
	var seen: Dictionary = {}
	while not stack.is_empty():
		var frame: Dictionary = stack.back()
		var id: String = frame.id
		if not frame.entered:
			proof.counters.groupRequests += 1
			if proof.groups.has(id):
				proof.counters.groupCacheHits += 1
				var cached: Dictionary = proof.groups[id]
				if cached.status != "ready": return _group_proof_failure(proof,stack,cached)
				stack.pop_back()
				continue
			if seen.has(id):
				stack.pop_back()
				continue
			seen[id] = true
			proof.counters.groupChecks += 1
			if not _group_receipts.has(id): return _group_proof_failure(proof,stack,{"status":"pending","reason":"structure_support_group_pending"})
			var receipt: Dictionary = _group_receipts[id]
			if int(receipt.cancelRevision) != _cancel_revision: return _group_proof_failure(proof,stack,{"status":"pending","reason":"structure_physical_receipt_revoked"})
			for member: String in _groups.groups[id].members:
				if not _member_live_with_context(member,proof): return _group_proof_failure(proof,stack,{"status":"pending","reason":"structure_physical_member_lost","memberId":member})
			frame.entered = true
			frame.cursor = _groups.groups[id].dependencies.size()-1
		if int(frame.cursor) >= 0:
			var dependency: String = _groups.groups[id].dependencies[int(frame.cursor)]
			frame.cursor -= 1
			stack.append({"id":dependency,"entered":false,"cursor":-1})
		else:
			proof.groups[id] = _group_receipts[id]
			stack.pop_back()
	return proof.groups[group_id]


func _group_proof_failure(proof: Dictionary, stack: Array[Dictionary], failure: Dictionary) -> Dictionary:
	for frame: Dictionary in stack: proof.groups[frame.id] = failure
	return failure


func _boundary_live_with_context(epoch: int, proof: Dictionary) -> bool:
	proof.counters.boundaryRequests += 1
	if proof.boundaries.has(epoch):
		proof.counters.boundaryCacheHits += 1
		return proof.boundaries[epoch]
	proof.counters.boundaryChecks += 1
	var live: bool = _weak_nodes_live(_boundary_witnesses.get(epoch,[]),proof,true)
	proof.boundaries[epoch] = live
	return live


func _member_live_with_context(key: String, proof: Dictionary) -> bool:
	proof.counters.memberRequests += 1
	if proof.members.has(key):
		proof.counters.memberCacheHits += 1
		return proof.members[key]
	proof.counters.memberChecks += 1
	var live: bool = bool(proof.ownerLive) and _member_live_uncached(key,proof)
	proof.members[key] = live
	return live


func _building_geometry(part) -> Array:
	return [String(part.id),String(part.kind),part.position,part.rotation,part.size,bool(part.collision_enabled),bool(part.recipe.get("visual",true))]


func _furniture_geometry(part) -> Array:
	return [String(part.id),String(part.archetype),part.position,part.rotation,part.occupied_size,bool(part.collision_enabled)]


func _collision_witnesses(body: Node) -> Array:
	var result: Array = []
	for child: Node in body.get_children():
		if child is CollisionShape3D:
			result.append({"node":weakref(child),"parent":weakref(child.get_parent()),"shape":weakref(child.shape) if child.shape != null else null,"transform":child.transform,
				"geometry":_shape_geometry(child.shape)})
	return result


func _shape_geometry(shape: Shape3D) -> Array:
	if shape is BoxShape3D: return ["box",shape.size]
	if shape is CylinderShape3D: return ["cylinder",shape.radius,shape.height]
	if shape is CapsuleShape3D: return ["capsule",shape.radius,shape.height]
	return []


func _node_witness(node: Node) -> Dictionary:
	var resource: Resource = (node as MultiMeshInstance3D).multimesh if node is MultiMeshInstance3D else ((node as MeshInstance3D).mesh if node is MeshInstance3D else null)
	return {"node":weakref(node),"resource":weakref(resource) if resource != null else null,
		"renderOwner":node is MultiMeshInstance3D or node is MeshInstance3D,
		"parent":weakref(node.get_parent()),"transform":(node as Node3D).transform if node is Node3D else Transform3D.IDENTITY}


func _begin_member(index: int) -> bool:
	if index < 0 or index >= _blueprint.parts.size(): return _fail("publication_source_index_changed")
	var part = _blueprint.parts[index]
	var key: String = "building:"+String(part.id)
	if not _source_member_matches(key,index,_building_geometry(part)): return _fail("publication_source_geometry_changed:"+key)
	if not _active_member.is_empty():
		return true if _active_member == key else _fail("publication_member_resume_changed")
	if _member_witnesses.has(key): return _fail("publication_member_repeated")
	_active_member = key
	_part_child_cursor = _root.get_child_count()
	_part_collision_cursor = _building.static_collision_body.get_child_count() if is_instance_valid(_building.static_collision_body) else 0
	_member_witnesses[key] = {"source":part,"sourceIndex":index,"geometry":_groups.memberSources[key].geometry,
		"nodes":[],"collisions":[],"body":null,"publicationEpoch":0}
	return true


func _source_member_matches(key: String, index: int, geometry: Array) -> bool:
	var source: Dictionary = _groups.memberSources.get(key,{})
	return not source.is_empty() and int(source.index) == index and source.geometry == geometry


## Only the new children produced by this atomic operation are inspected.
## Shared batches are recorded separately by epoch, never scanned per member.
func _capture_member_nodes(index: int) -> void:
	if not is_instance_valid(_root) or _active_member.is_empty(): return
	var witness: Dictionary = _member_witnesses[_active_member]
	for child_index: int in range(_part_child_cursor,_root.get_child_count()):
		var child: Node = _root.get_child(child_index)
		if child == _building.static_collision_body: continue
		witness.nodes.append(_node_witness(child))
		if child is StaticBody3D and String(child.get_meta("building_part_id","")) == String(_blueprint.parts[index].id):
			witness.body = weakref(child)
			witness.collisions.append_array(_collision_witnesses(child))
	_part_child_cursor = _root.get_child_count()
	var collider: StaticBody3D = _building.static_collision_body
	if is_instance_valid(collider):
		for child_index: int in range(_part_collision_cursor,collider.get_child_count()):
			var child: Node = collider.get_child(child_index)
			if child is CollisionShape3D:
				witness.collisions.append({"node":weakref(child),"parent":weakref(child.get_parent()),"shape":weakref(child.shape) if child.shape != null else null,"transform":child.transform,
					"geometry":_shape_geometry(child.shape)})
		_part_collision_cursor = collider.get_child_count()


func _capture_boundary_nodes(epoch: int, start_index: int) -> void:
	if epoch <= 0 or not is_instance_valid(_root): return
	if not _boundary_witnesses.has(epoch): _boundary_witnesses[epoch] = []
	var nodes: Array = _boundary_witnesses[epoch]
	for index: int in range(start_index,_root.get_child_count()): nodes.append(_node_witness(_root.get_child(index)))


func _weak_nodes_live(nodes: Array, proof: Dictionary, boundary := false) -> bool:
	for witness: Dictionary in nodes:
		proof.counters["boundaryNodeChecks" if boundary else "memberNodeChecks"] += 1
		var node: Node = witness.node.get_ref() as Node
		if not _tree_body_valid(node): return false
		if witness.renderOwner:
			var resource: Resource = (node as MultiMeshInstance3D).multimesh if node is MultiMeshInstance3D else (node as MeshInstance3D).mesh
			if witness.resource == null or resource == null or resource != witness.resource.get_ref() \
					or node.get_parent() != witness.parent.get_ref() or (node as Node3D).transform != witness.transform: return false
	return true


func _collisions_live(collisions: Array, proof: Dictionary, moving_door: bool = false) -> bool:
	for witness: Dictionary in collisions:
		proof.counters.collisionShapeChecks += 1
		var node: CollisionShape3D = witness.node.get_ref() as CollisionShape3D
		if not _tree_body_valid(node) or witness.shape == null or node.shape != witness.shape.get_ref() \
				or not witness.get("parent") is WeakRef or node.get_parent() != witness.parent.get_ref(): return false
		if not moving_door:
			var owner: CollisionObject3D = node.get_parent() as CollisionObject3D
			if node.disabled or owner == null or owner.collision_layer == 0 \
					or node.transform != witness.transform or _shape_geometry(node.shape) != witness.geometry: return false
	return true


func _member_live(key: String) -> bool:
	var proof: Dictionary = _begin_physical_proof("single_receipt",_binding)
	var live: bool = _member_live_with_context(key,proof)
	_finish_physical_proof(proof)
	return live


func _member_live_uncached(key: String, proof: Dictionary) -> bool:
	if key.begins_with("tree:"):
		var source_index: int = _groups.treeMembers[key].index
		if _skipped_tree_indices.has(source_index): return true # Authoritative removed_prop callback receipt.
		if not _tree_by_source_index.has(source_index): return false
		var body: Node3D = _tree_bodies[int(_tree_by_source_index[source_index])].get_ref() as Node3D
		return _tree_body_valid(body) and String(body.get_meta("tree_visual_state","")) == "published" \
			and body.get_node_or_null("GeneratedTreeVisual") != null \
			and _tree_source_pose_matches(body,source_index) and _member_witnesses.has(key) \
			and _tree_collision_matches_source(_member_witnesses[key].collisions,source_index) \
			and _collisions_live(_member_witnesses[key].collisions,proof)
	var witness: Dictionary = _member_witnesses.get(key,{})
	if witness.is_empty() or not _weak_nodes_live(witness.nodes,proof): return false
	if key.begins_with("furnishing:"):
		var body: Node3D = witness.body.get_ref() as Node3D
		return _door_body_valid(body) and body.get_parent() == _root and String(body.get_meta("furnishing_part_id","")) == key.trim_prefix("furnishing:") \
			and int(witness.sourceIndex)<_plan.parts.size() and _plan.parts[int(witness.sourceIndex)]==witness.source \
			and body.transform == Transform3D(Basis.from_euler(witness.source.rotation),witness.source.position) \
			and _furniture_geometry(witness.source) == witness.geometry and _collisions_live(witness.collisions,proof) \
			and (not bool(witness.source.collision_enabled) or not witness.collisions.is_empty())
	var part = witness.source
	if int(witness.sourceIndex) >= _blueprint.parts.size() or _blueprint.parts[int(witness.sourceIndex)] != part \
			or _building_geometry(part) != witness.geometry: return false
	var epoch: int = _building.source_part_publication_epoch(String(part.id))
	if epoch <= 0 or epoch != int(witness.publicationEpoch) or not _boundary_live_with_context(epoch,proof): return false
	if bool(part.collision_enabled) and witness.collisions.is_empty(): return false
	if not _collisions_live(witness.collisions,proof,String(part.kind)=="door"): return false
	if String(part.kind) == "door":
		var body: Node = witness.body.get_ref() as Node if witness.body is WeakRef else null
		if not _door_body_valid(body): return false
		var instance_id: int = body.get_instance_id()
		if not _door_registered_ids.has(instance_id): return false
		var claim: Dictionary = _door_claims.get(instance_id,{})
		return not claim.is_empty() and claim.body.get_ref() == body and String(body.get_meta("door_portal_id","")) == String(claim.portalId)
	if bool(part.collision_enabled):
		var collider: StaticBody3D = _building.static_collision_body
		if not _door_body_valid(collider) or collider.get_parent() != _root or collider.transform != Transform3D.IDENTITY: return false
		var records: Dictionary = collider.get_meta("building_part_records",{})
		if not records.has(String(part.id)): return false
	return true


func _tree_source_pose_matches(body: Node3D, source_index: int) -> bool:
	var record: Dictionary = _groups.treeRecords[source_index]
	var expected: Transform3D = Transform3D(Basis(Vector3.UP,float(record.rotationY)),record.position)
	var prop_id: String = "site-tree:%d:%s:%d:%s" % [String(_binding.siteId).length(),_binding.siteId,String(record.id).length(),record.id]
	return body.get_parent() == _root and body.transform.is_equal_approx(expected) \
		and String(body.get_meta("prop_id","")) == prop_id and _registered_tree_ids.get(body.get_instance_id(),"") == prop_id


func _tree_collision_matches_source(collisions: Array, source_index: int) -> bool:
	if collisions.size()!=1: return false
	var request: Dictionary = _groups.treeRecords[source_index].treeRequest
	# CylinderShape3D stores these scalar properties as C++ float. Compare the
	# exact representable source values, not Variant doubles or a tolerance.
	var dimensions: PackedFloat32Array = PackedFloat32Array([request.trunkRadius,request.collisionHeight])
	# The runtime collider offset is constructed from the original request.
	var height: float = float(request.collisionHeight)
	return collisions[0].geometry == ["cylinder",dimensions[0],dimensions[1]] \
		and collisions[0].transform == Transform3D(Basis.IDENTITY,Vector3(0,height*0.5,0))


func _check_transaction_tree_visual() -> bool:
	if _transaction_visual_cursor >= _transaction.treeIndices.size(): _phase = "group_commit"; return true
	var source_index: int = _transaction.treeIndices[_transaction_visual_cursor]
	if _skipped_tree_indices.has(source_index): _transaction_visual_cursor += 1; return true
	if not _tree_by_source_index.has(source_index): return _fail("tree_source_index_unpublished")
	var body_index: int = _tree_by_source_index[source_index]
	var body: Node3D = _tree_bodies[body_index].get_ref() as Node3D
	if not _tree_body_valid(body): return _fail("tree_body_lost_before_visual")
	if not _tree_source_pose_matches(body,source_index): return _fail("tree_source_pose_changed")
	var state: String = String(body.get_meta("tree_visual_state",""))
	if state == "failed": return _fail("tree_visual_failed")
	if state not in ["queued","recipe_cached","recipe_lod_derivation_queued","building","assembling","published"]: return _fail("tree_visual_invalid_state")
	if state != "published": return false
	if body.get_node_or_null("GeneratedTreeVisual") == null: return _fail("tree_visual_missing_node")
	if not _tree_visual_seen[body_index]: _tree_visual_seen[body_index] = true; _visuals_complete += 1
	var key: String = "tree:"+String(_trees[source_index].id)
	_member_witnesses[key] = {"body":weakref(body),"collisions":_collision_witnesses(body)}
	if not _tree_collision_matches_source(_member_witnesses[key].collisions,source_index): return _fail("tree_collision_source_mismatch")
	_transaction_visual_cursor += 1
	return true


func _commit_transaction() -> bool:
	var proof: Dictionary = _begin_physical_proof("commit",_binding)
	if not proof.ownerLive: return _commit_proof_failure(proof,"publication_group_scene_owner_lost")
	var transaction_groups: Dictionary = {}
	for id: String in _transaction.groupIds: transaction_groups[id] = true
	for index: int in _transaction.buildingIndices:
		var key: String = "building:"+str(_blueprint.parts[index].id)
		if not _member_witnesses.has(key):
			return _commit_proof_failure(proof,"publication_transaction_building_witness_missing:%s:%d:%d:%s" % [
				key,_transaction_building_cursor,_transaction.buildingIndices.size(),str(_transaction.get("transactionId",0))])
		_member_witnesses[key].publicationEpoch = _building.source_part_publication_epoch(str(_blueprint.parts[index].id))
	for id: String in _transaction.groupIds:
		proof.counters.transactionGroups += 1
		for dependency: String in _groups.groups[id].dependencies:
			if not transaction_groups.has(dependency):
				var support_receipt:=_physical_group_receipt_with_context(dependency,proof)
				if support_receipt.get("status") != "ready":
					return _commit_proof_failure(proof,"publication_support_unavailable:%s:%s:%s" % [
						String(support_receipt.get("reason","unknown")),id,dependency])
		for member: String in _groups.groups[id].members:
			if not _member_live_with_context(member,proof): return _commit_proof_failure(proof,"publication_group_member_incomplete:"+member)
	for id: String in _transaction.groupIds:
		var receipt: Dictionary = {"status":"ready","binding":_binding,"groupId":id,
			"transactionId":_transaction.id,"publicationEpoch":_transaction.id,"cancelRevision":_cancel_revision,
			"sceneInstanceId":_root.get_instance_id(),"sourceMemberIds":_groups.groups[id].members}
		if _base_packet_mode:
			var packet: Preparation.PreparedPhysicalGroupPacket = _cpu.get("activePhysicalPacket")
			receipt["publicationKind"] = "packet_physical"
			receipt["packetSourceId"] = packet.source_id if packet != null else ""
			receipt["physicalPacketKey"] = String(_transaction.get("physicalPacketKey",""))
		if _packet_static_only_groups.has(id):
			var static_record_ids: Array[String] = []
			var packet: Preparation.PreparedPhysicalGroupPacket = _cpu.get("activePhysicalPacket")
			for raw_index: int in _groups.groups[id].buildingIndices:
				var part_id := String(_blueprint.parts[raw_index].id)
				if packet != null and packet.static_records.has(part_id): static_record_ids.append(part_id)
			static_record_ids.sort()
			static_record_ids.make_read_only()
			receipt["publicationKind"] = "packet_static_only"
			receipt["packetSourceId"] = packet.source_id if packet != null else ""
			receipt["staticRecordIds"] = static_record_ids
		receipt.make_read_only()
		_group_receipts[id] = receipt
	_finish_physical_proof(proof)
	_release_occupancy_blocked_requests()
	_transaction = {}
	_cpu["activePublicationTransaction"] = {}
	_phase = "packet_wait" if _base_packet_mode else "transaction_select"
	return true


func _commit_proof_failure(proof: Dictionary, reason: String) -> bool:
	_finish_physical_proof(proof)
	return _fail(reason)


func _step(remaining_usec: int) -> bool:
	if _phase == "teardown": return _teardown_step()
	if _phase == "detach_publishers": return _detach_step()
	var parent: Node3D = _parent.get_ref() as Node3D if _parent != null else null
	if not _valid_parent(parent): return _fail("publication_parent_lost")
	if _phase != "building_begin" and (not is_instance_valid(_root) or _root.is_queued_for_deletion()):
		return _fail("publication_root_lost")
	if _phase != "building_begin" and (_root.get_parent() != parent \
			or not _root.global_transform.is_equal_approx(Transform3D(Basis.IDENTITY, _cpu.profile.origin))):
		return _fail("publication_root_moved")
	match _phase:
		"packet_attach_boundary":
			var boundary_result: Dictionary = _building.advance_publication_boundary(_root,clampi(remaining_usec,1,4000))
			if _cancelled: return false
			if boundary_result.status=="failed": return _fail(String(boundary_result.reason))
			if boundary_result.status=="ready":
				_phase="packet_wait"
				return false
		"building_begin":
			_root = Node3D.new()
			_root.name = "PreparedBuildingScene"
			# Profile origin is WORLD space; avoid applying a translated parent's
			# origin twice. Child building/furniture/tree records remain local.
			_root.transform = parent.global_transform.affine_inverse() * Transform3D(Basis.IDENTITY, _cpu.profile.origin)
			parent.add_child(_root)
			if _cancelled: return false
			_building = BuildingPublisher.new()
			_cpu["buildingPublisher"] = _building
			if _cancelled: return false
			var outcome: Dictionary
			if _base_packet_mode:
				var packet_source: Dictionary = _cpu.get("packetSceneSource",{})
				var packet: Preparation.PreparedPhysicalGroupPacket = _cpu.get("activePhysicalPacket")
				var base: Preparation.PreparedPublicationBase = _cpu.get("publicationBase")
				if not packet_source.get("ready",false) or packet == null or base == null:
					return _fail("physical_packet_scene_source_missing")
				var packet_options := {"batchStaticParts":true, "publicationSiteId":_binding.siteId, "resumableScenePublication":true}
				if not _packet_static_only_groups.is_empty() and _packet_static_only_groups.size()==packet.group_ids.size():
					outcome = _building.begin_static_only_group_packet_scene(base,packet,packet_source.blueprint,_root,_binding,packet_options)
				else:
					outcome = _building.begin_physical_group_packet_scene(base,packet,packet_source.blueprint,_root,_binding,packet_options)
			else:
				outcome = _building.begin_prepared_publication(_cpu.prepared, _root, _binding,
					{"batchStaticParts":true, "publicationSiteId":_binding.siteId, "resumableScenePublication":true})
			_cpu["buildingBegin"] = outcome
			if _cancelled: return false
			if not bool(outcome.get("ready", false)): return _fail(String(outcome.get("reason", "building_begin_failed")))
			if _base_packet_mode:
				var restored_scene: Dictionary = _cpu.get("packetSceneSource",{})
				_blueprint = restored_scene.get("blueprint")
				_plan = restored_scene.get("furnishingPlan")
			else:
				_blueprint = outcome.blueprint
				_plan = outcome.furnishingPlan
			if _blueprint == null or _plan == null: return _fail("physical_packet_scene_source_missing")
			if not _base_packet_mode and outcome.get("spatialDependencies") != _spatial: return _fail("publication_description_owner_changed")
			if _base_packet_mode:
				_phase = "building_finish" if _transaction.groupIds.is_empty() else "building"
				return true
			var records: Variant = _blueprint.recipe.get("landscapeTrees", null)
			if records == null:
				var urban: Variant = _blueprint.recipe.get("urbanPoc", {})
				if not urban is Dictionary: return _fail("invalid_tree_collection")
				records = urban.get("treePlacements", [])
			if not records is Array: return _fail("invalid_tree_collection")
			_trees = records
			_cpu["treeRecords"] = _trees
			_phase = "masonry"
		"masonry":
			var result: Dictionary = _building.advance_scene_preparation(clampi(remaining_usec, 1, 4000))
			if _cancelled: return false
			if result.get("status") == "failed": return _fail(String(result.get("reason", "masonry_failed")))
			if result.get("status") == "ready": _phase = "building_finish" if _transaction.groupIds.is_empty() else "building"
		"building":
			if _building.has_pending_static_flush():
				var epoch: int = int(_building._pending_publication_boundary.get("epoch",0))
				var child_cursor: int = _root.get_child_count()
				var flushed: Dictionary = _building.advance_static_flush(_root,clampi(remaining_usec,1,4000))
				_capture_boundary_nodes(epoch,child_cursor)
				if _cancelled: return false
				if flushed.status=="failed": return _fail(String(flushed.reason))
			elif _transaction_building_cursor >= _transaction.buildingIndices.size():
				_phase = "publication_boundary"
			else:
				var source_index: int = _transaction.buildingIndices[_transaction_building_cursor]
				if not _begin_member(source_index): return false
				var next: int = _building.publish_part_batch(_blueprint, _root, source_index, 1,clampi(remaining_usec,1,4000))
				_capture_member_nodes(source_index)
				if _cancelled: return false
				var result: Dictionary = _building.publication_status()
				if _cancelled: return false
				if result.get("status") == "failed": return _fail(String(result.get("reason", "building_failed")))
				if next <= source_index:
					if result.get("status")=="pending_budget": return true
					return _fail("building_cursor_stalled")
				if next != source_index+1: return _fail("building_source_index_changed")
				_building_cursor += 1
				_transaction_building_cursor += 1
				_active_member = ""
		"publication_boundary":
			var epoch: int = int(_building._pending_publication_boundary.get("epoch",0))
			var child_cursor: int = _root.get_child_count()
			var result: Dictionary = _building.advance_publication_boundary(_root,clampi(remaining_usec,1,4000))
			_capture_boundary_nodes(epoch,child_cursor)
			if _cancelled: return false
			if result.status == "failed": return _fail(String(result.reason))
			if result.status == "ready":
				# A physical packet may now contain frozen furnishing records. The
				# resident session still owns the only FurnishingPublisher; later
				# packets append their selected records without clearing prior bodies.
				if _base_packet_mode:
					# Packet receipts with door members must cross the same registration
					# phase as ordinary scene publication. _member_live then binds the
					# receipt to the exact body/portal claim rather than mere geometry.
					_phase = "packet_door_registration" if _packet_transaction_has_doors(_transaction) else (("furniture_begin" if _furniture == null else "furniture") if not _transaction.furnitureIndices.is_empty() else "group_commit")
				else:
					_phase = "door_registration" if _door_receiver != null else ("furniture_begin" if _furniture == null else "furniture")
		"building_finish":
			var result: Dictionary = _building.finish_scene_publication(_blueprint, _root,clampi(remaining_usec,1,4000))
			_cpu["buildingFinish"] = result
			if _cancelled: return false
			if result.get("status")=="pending_budget": return true
			if not bool(result.get("complete", false)): return _fail(String(result.get("reason", "building_incomplete")))
			_phase = "furniture_finish"
		"door_registration":
			return _register_door()
		"packet_door_registration":
			return _register_door()
		"furniture_begin":
			_furniture = FurniturePublisher.new()
			_cpu["furniturePublisher"] = _furniture
			if _cancelled: return false
			var begun: bool = _furniture.begin_publication(_plan, _root)
			if _cancelled: return false
			if not begun: return _fail("furniture_begin_failed")
			_phase = "furniture"
		"furniture":
			if _transaction_furniture_cursor >= _transaction.furnitureIndices.size():
				_phase = "group_commit" if _base_packet_mode else "tree_registration"
			else:
				var source_index: int = _transaction.furnitureIndices[_transaction_furniture_cursor]
				if source_index < 0 or source_index >= _plan.parts.size(): return _fail("furniture_source_index_changed")
				var source = _plan.parts[source_index]
				var key: String = "furnishing:"+String(source.id)
				if not _source_member_matches(key,source_index,_furniture_geometry(source)): return _fail("publication_source_geometry_changed:"+key)
				if _base_packet_mode and not _packet_furnishing_source_matches(source): return _fail("physical_packet_furnishing_source_mismatch:"+key)
				if _member_witnesses.has(key): return _fail("publication_member_repeated")
				var body: StaticBody3D = _furniture.publish_part(source,_root)
				if _cancelled: return false
				if not _door_body_valid(body): return _fail("furniture_owner_lost")
				_member_witnesses[key] = {"source":source,"sourceIndex":source_index,"geometry":_groups.memberSources[key].geometry,
					"body":weakref(body),"collisions":_collision_witnesses(body),"nodes":[_node_witness(body)]}
				_furniture_cursor += 1
				_transaction_furniture_cursor += 1
		"furniture_finish":
			if _furniture != null: _cpu["furnitureFinish"] = _furniture.finish_publication(_plan, _root)
			if _cancelled: return false
			_tree_receiver = null
			_tree_method = &""
			_phase = "tree_visuals"
		"tree_registration":
			return _register_tree()
		"group_tree_visuals":
			return _check_transaction_tree_visual()
		"group_commit":
			return _commit_transaction()
		"tree_visuals":
			return _check_tree_visual()
	return true


## The packet owns an immutable typed record for each furnishing index in the
## pinned transaction. The scene source is independently restored from the
## same frozen base, so both the source geometry and the exact record binding
## must agree before FurnishingPublisher creates a body.
func _packet_furnishing_source_matches(source) -> bool:
	var packet: Preparation.PreparedPhysicalGroupPacket = _cpu.get("activePhysicalPacket")
	if packet == null or source == null: return false
	var id := String(source.id)
	var entry: Variant = packet.furnishing_entries.get(id)
	if not entry is Dictionary or String(entry.get("id","")) != id or not entry.get("record") is Dictionary:
		return false
	var source_binding := Preparation.static_record_binding(source.snapshot())
	var entry_binding := Preparation.static_record_binding(entry.record)
	return not source_binding.is_empty() and source_binding == String(entry.get("binding","")) and entry_binding == source_binding


## Door membership comes from the immutable publication group description;
## never infer it from a restored scene graph after node creation.
func _packet_transaction_has_doors(transaction: Dictionary) -> bool:
	for raw_id in transaction.get("groupIds",[]):
		var group: Variant = _groups.groups.get(String(raw_id))
		if not group is Dictionary or not group.get("doorPartIds",[]) is Array:
			return false
		if not group.doorPartIds.is_empty(): return true
	return false


func _packet_door_lifecycle_available() -> bool:
	var register_owner: Object = _door_receiver.get_ref() if _door_receiver != null else null
	var retire_owner: Object = _door_retire_receiver.get_ref() if _door_retire_receiver != null else null
	return is_instance_valid(register_owner) and is_instance_valid(retire_owner) \
		and not _door_method.is_empty() and not _door_retire_method.is_empty() \
		and Callable(register_owner,_door_method).is_valid() and Callable(retire_owner,_door_retire_method).is_valid()


func _register_door() -> bool:
	if _door_cursor >= _building.published_nodes.size():
		if _base_packet_mode:
			_phase = ("furniture_begin" if _furniture == null else "furniture") if not _transaction.furnitureIndices.is_empty() else "group_commit"
		else:
			_phase = "furniture_begin" if _furniture == null else "furniture"
		return true
	var body = _building.published_nodes[_door_cursor]
	if not is_instance_valid(body): return _fail("published_door_scan_node_lost")
	if String(body.get_meta("building_part_kind", "")) != "door":
		_door_cursor += 1
		return true
	if not body is StaticBody3D or not _door_body_valid(body): return _fail("invalid_published_door")
	var id: int = body.get_instance_id()
	if _door_registered_ids.has(id):
		_door_cursor += 1
		return true
	var portal_id := String(body.get_meta("door_portal_id", ""))
	if portal_id.is_empty(): return _fail("missing_published_door_id")
	if _door_claims.has(id) and _door_claims[id].portalId != portal_id: return _fail("published_door_id_changed")
	var receiver: Object = _door_receiver.get_ref() if _door_receiver != null else null
	if not is_instance_valid(receiver): return _fail("door_callback_lost")
	var callback := Callable(receiver, _door_method)
	if not callback.is_valid(): return _fail("door_callback_lost")
	# Claim before external code: side effects followed by failure/cancellation
	# must still take the same acknowledged cleanup path.
	_door_claims[id] = {"body":weakref(body), "portalId":portal_id}
	var result: Variant = callback.call(body)
	# Packet transactions use the same callback/claim path before their group
	# receipt. Do not discard a successful registration merely because it was
	# reached through the packet-owned phase.
	if _cancelled or _phase not in ["door_registration","packet_door_registration"]: return false
	if not _door_body_valid(body) or String(body.get_meta("door_portal_id", "")) != portal_id: return _fail("registered_door_owner_changed")
	if not result is Dictionary: return _fail("invalid_door_registration_ack")
	if result.get("status") == "pending_budget" and result.get("sideEffects") == false: return false
	if result.get("status") != "registered" or result.get("portalId") != portal_id: return _fail("door_registration_failed")
	_door_registered_ids[id] = true
	_door_cursor += 1
	return true


func _door_body_valid(body) -> bool:
	var parent: Node3D = _parent.get_ref() as Node3D if _parent != null else null
	return _valid_parent(parent) and is_instance_valid(_root) and not _root.is_queued_for_deletion() \
		and _root.get_parent() == parent and _root.global_transform.is_equal_approx(Transform3D(Basis.IDENTITY, _cpu.profile.origin)) \
		and is_instance_valid(body) and not body.is_queued_for_deletion() and body.is_inside_tree() and _root.is_ancestor_of(body)


func _register_tree() -> bool:
	if _transaction_tree_cursor >= _transaction.treeIndices.size():
		_phase = "group_tree_visuals"
		return true
	var source_index: int = _transaction.treeIndices[_transaction_tree_cursor]
	if source_index < 0 or source_index >= _trees.size(): return _fail("tree_source_index_changed")
	var record: Variant = _trees[source_index]
	if not record is Dictionary: return _fail("invalid_tree_record")
	if record != _groups.treeRecords[source_index]: return _fail("tree_source_record_changed")
	var request: Variant = record.get("treeRequest")
	var position: Variant = record.get("position")
	var yaw: Variant = record.get("rotationY")
	var id: Variant = record.get("id")
	if not id is String or id.is_empty() or not request is Dictionary or request.is_empty() \
			or not position is Vector3 or not position.is_finite() \
			or not (yaw is float or yaw is int) or not is_finite(float(yaw)):
		return _fail("invalid_tree_record")
	# Site identity prevents equal recipe-local IDs at different sites aliasing
	# durable removed_props. Delimit with lengths to avoid ambiguous concatenation.
	var prop_id := "site-tree:%d:%s:%d:%s" % [String(_binding.siteId).length(), _binding.siteId, id.length(), id]
	if _tree_ids.has(prop_id): return _fail("duplicate_tree_id")
	var receiver: Object = _tree_receiver.get_ref() if _tree_receiver != null else null
	if not is_instance_valid(receiver): return _fail("tree_callback_lost")
	var callback := Callable(receiver, _tree_method)
	if not callback.is_valid(): return _fail("tree_callback_lost")
	var result: Variant = callback.call(_root, prop_id, position, String(request.get("biome", "town")), request, float(yaw))
	# Retain retirement identity even if the callback reentrantly cancelled after
	# creating/registering its body. Never retain the result's strong Node field.
	if result is Dictionary and result.get("status") == "published":
		var registered_body: Variant = result.get("body")
		if registered_body is StaticBody3D and is_instance_valid(registered_body) and _root.is_ancestor_of(registered_body):
			_registered_tree_ids[registered_body.get_instance_id()] = prop_id
			if not _tree_retirement_claims.has(registered_body.get_instance_id()): _tree_claim_order.append(registered_body.get_instance_id())
			_tree_retirement_claims[registered_body.get_instance_id()] = {"body":weakref(registered_body), "propId":prop_id}
	# A callback may cancel the job. Never restore its phase or call another one.
	if _cancelled or _phase == "teardown": return false
	if not result is Dictionary: return _fail("invalid_tree_callback_result")
	match String(result.get("status", "")):
		"deferred": return false
		"skipped":
			if result.get("reason") != "removed_prop": return _fail("unexpected_tree_skip")
			_trees_skipped += 1
			_skipped_tree_indices[source_index] = prop_id
		"published":
			var body: Variant = result.get("body")
			if not body is StaticBody3D or not is_instance_valid(body) or not _root.is_ancestor_of(body):
				return _fail("invalid_published_tree_body")
			_tree_bodies.append(weakref(body))
			_tree_visual_seen.append(false)
			_tree_by_source_index[source_index] = _tree_bodies.size()-1
		_: return _fail(String(result.get("reason", "tree_registration_failed")))
	_tree_ids[prop_id] = true
	_tree_cursor += 1
	_transaction_tree_cursor += 1
	return true


func _check_tree_visual() -> bool:
	# Keep EVERY weak reference, including already published bodies. The seen
	# array counts observations, never substitutes for liveness of the whole site.
	if _visual_cursor >= _tree_bodies.size():
		_visual_cursor = 0
		if _visuals_complete == _tree_bodies.size():
			# A budgeted pass can span frames: an earlier body might disappear
			# after its unit. Recheck all bodies in this final, measured atomic
			# commit unit (no callbacks/yields), before claiming scene readiness.
			for final_reference: WeakRef in _tree_bodies:
				var final_body: Node = final_reference.get_ref() as Node
				if not _tree_body_valid(final_body): return _fail("tree_body_lost_before_visual")
				if String(final_body.get_meta("tree_visual_state", "")) != "published" \
						or final_body.get_node_or_null("GeneratedTreeVisual") == null:
					return _fail("tree_visual_lost_before_ready")
			_phase = "ready"
			return true
		return false
	var reference: WeakRef = _tree_bodies[_visual_cursor]
	if reference != null:
		var body: Node = reference.get_ref() as Node
		if not _tree_body_valid(body): return _fail("tree_body_lost_before_visual")
		var state := String(body.get_meta("tree_visual_state", ""))
		if state == "failed": return _fail("tree_visual_failed")
		# These are the queue's actual nonterminal states. A fallback visual or
		# missing marker is not a queued procedural visual: fail, do not wait forever.
		if state not in ["queued", "recipe_cached", "recipe_lod_derivation_queued", "building", "assembling", "published"]:
			return _fail("tree_visual_invalid_state")
		if state == "published":
			if body.get_node_or_null("GeneratedTreeVisual") == null: return _fail("tree_visual_missing_node")
			if not _tree_visual_seen[_visual_cursor]:
				_tree_visual_seen[_visual_cursor] = true
				_visuals_complete += 1
		elif _tree_visual_seen[_visual_cursor]:
			_tree_visual_seen[_visual_cursor] = false
			_visuals_complete -= 1
	_visual_cursor += 1
	return true


func _tree_body_valid(body: Node) -> bool:
	return is_instance_valid(body) and not body.is_queued_for_deletion() \
		and body.is_inside_tree() and _root.is_ancestor_of(body)


func _teardown_step() -> bool:
	if not is_instance_valid(_root):
		if _tree_retire_requires_acknowledgement and not _tree_retirement_claims.is_empty():
			return _retire_unvisited_tree_claim()
		if not _door_claims.is_empty():
			_cleanup_reason = "door_retirement_root_lost"
			return false
		_root = null
		_cleanup_node = null
		_phase = "detach_publishers"
		return true
	if not is_instance_valid(_cleanup_node): _cleanup_node = _root
	var node := _cleanup_node
	var next := node.get_parent()
	var instance_id := node.get_instance_id()
	# Registry cleanup needs intact geometry, not an already stripped body.
	if _door_claims.has(instance_id):
		var receiver: Object = _door_retire_receiver.get_ref() if _door_retire_receiver != null else null
		if not is_instance_valid(receiver):
			_cleanup_reason = "door_retire_callback_lost"
			return false
		var callback := Callable(receiver, _door_retire_method)
		if not callback.is_valid():
			_cleanup_reason = "door_retire_callback_lost"
			return false
		var result: Variant = callback.call(node)
		# The callback may fail after removing a registration; a subsequent
		# authoritative absent receipt is safe. Never infer success from no error.
		if not is_instance_valid(node) or not is_instance_valid(_root) or node.get_parent() != next or not _root.is_ancestor_of(node):
			_cleanup_reason = "door_retirement_owner_lost"
			return false
		if not result is Dictionary or not result.get("status") in ["unregistered", "absent"] \
				or (result.get("status") == "unregistered" and result.get("portalId") != _door_claims[instance_id].portalId):
			_cleanup_reason = "door_retirement_not_acknowledged"
			return false
		_door_claims.erase(instance_id)
		_doors_retired += 1
		_cleanup_reason = ""
		return true
	if _registered_tree_ids.has(instance_id) and _retiring_tree_instance != instance_id:
		if _tree_retire_requires_acknowledgement and (not _tree_retirement_claims.has(instance_id) \
				or _tree_retirement_claims[instance_id].body.get_ref() != node \
				or _tree_retirement_claims[instance_id].propId != _registered_tree_ids[instance_id] or not _door_body_valid(node)):
			_cleanup_reason = "tree_retirement_owner_lost"
			return false
		var receiver: Object = _tree_retire_receiver.get_ref() if _tree_retire_receiver != null else null
		if _tree_retire_receiver != null or _tree_retire_requires_acknowledgement:
			if not is_instance_valid(receiver):
				_cleanup_reason = "tree_retire_callback_lost"
				return false
			var callback := Callable(receiver, _tree_retire_method)
			if not callback.is_valid():
				_cleanup_reason = "tree_retire_callback_lost"
				return false
			var cancellation_before := _cancel_revision
			var prop_id: String = _registered_tree_ids[instance_id]
			var result: Variant = callback.call(prop_id, node)
			if _tree_retire_requires_acknowledgement:
				if not is_instance_valid(node) or not _door_body_valid(node) or node.get_parent() != next:
					_cleanup_reason = "tree_retirement_owner_lost"
					return false
				if _cancel_revision != cancellation_before or _phase != "teardown":
					_cleanup_reason = "tree_retirement_reentered"
					return false
				if not result is Dictionary or result.get("status") not in ["unregistered", "absent"] \
						or result.get("objectId") != "prop:" + prop_id:
					_cleanup_reason = "tree_retirement_not_acknowledged"
					return false
				_tree_retirement_claims.erase(instance_id)
				_cleanup_reason = ""
		_retiring_tree_instance = instance_id
		return true # Callback is its own measured atomic operation, before free.
	if node.get_child_count(true) > 0:
		_cleanup_node = node.get_child(node.get_child_count(true) - 1, true)
		return true
	if node == _root and not _door_claims.is_empty():
		_cleanup_reason = "door_retirement_claims_unresolved"
		return false
	if node == _root and _tree_retire_requires_acknowledgement and not _tree_retirement_claims.is_empty():
		return _retire_unvisited_tree_claim()
	# These exact publisher metadata containers can dwarf the scene node itself.
	# Keep their last CPU references for retirement rather than freeing on main.
	for key: StringName in [&"building_part_record", &"building_part_records", &"furnishing_part_record"]:
		if node.has_meta(key): _cpu.nodeMetadata.append(node.get_meta(key))
	if node == _root:
		_root = null
		_cleanup_node = null
	else:
		_cleanup_node = next
	if next != null: next.remove_child(node)
	node.free() # Exactly one leaf; never queue_free a large subtree.
	_freed_nodes += 1
	return true


## One ordered claim per unit, only after normal node traversal (or root loss).
## A missing body is NOT success. The runtime owner may acknowledge null only
## from durable removal authority with no live same-ID replacement registration.
func _retire_unvisited_tree_claim() -> bool:
	if _tree_claim_cursor >= _tree_claim_order.size():
		_cleanup_reason = "tree_retirement_claims_unresolved"
		return false
	var id: int = _tree_claim_order[_tree_claim_cursor]
	if not _tree_retirement_claims.has(id):
		_tree_claim_cursor += 1
		return true
	var claim: Dictionary = _tree_retirement_claims[id]
	if is_instance_valid(claim.body.get_ref()):
		_cleanup_reason = "tree_retirement_owner_lost"
		return false
	var receiver: Object = _tree_retire_receiver.get_ref() if _tree_retire_receiver != null else null
	var callback := Callable(receiver, _tree_retire_method) if is_instance_valid(receiver) else Callable()
	if not callback.is_valid():
		_cleanup_reason = "tree_retire_callback_lost"
		return false
	var cancellation_before := _cancel_revision
	var root_before: int = _root.get_instance_id() if is_instance_valid(_root) else 0
	var root_parent: Node = _root.get_parent() if root_before != 0 else null
	var result: Variant = callback.call(claim.propId, null)
	if (root_before != 0 and (not is_instance_valid(_root) or _root.get_instance_id() != root_before or _root.get_parent() != root_parent)) \
			or (root_before == 0 and is_instance_valid(_root)):
		_cleanup_reason = "tree_retirement_owner_lost"
		return false
	if cancellation_before != _cancel_revision or _phase != "teardown":
		_cleanup_reason = "tree_retirement_reentered"
		return false
	if not result is Dictionary or result.get("status") not in ["unregistered", "absent"] or result.get("objectId") != "prop:" + String(claim.propId):
		_cleanup_reason = "tree_retirement_not_acknowledged"
		return false
	_tree_retirement_claims.erase(id)
	_tree_claim_cursor += 1
	_cleanup_reason = ""
	return true


func _detach_step() -> bool:
	if _tree_retire_requires_acknowledgement and not _tree_retirement_claims.is_empty():
		_cleanup_reason = "tree_retirement_claims_unresolved"
		return false
	if not _door_claims.is_empty():
		_cleanup_reason = "door_retirement_claims_unresolved"
		return false
	# All nodes are already gone. Drain dangling Node slots incrementally; retain
	# every CPU/resource field on the publishers, with no bulk clear_published().
	if _building != null and not _building.published_nodes.is_empty():
		_building.published_nodes.pop_back()
		return true
	if _furniture != null and not _furniture.published_parts.is_empty():
		_furniture.published_parts.pop_back()
		return true
	if _building != null:
		_building.static_collision_body = null
		_building.incremental_progress_callback = Callable()
	_parent = null
	_tree_receiver = null
	_tree_method = &""
	_tree_retire_receiver = null
	_tree_retire_method = &""
	_door_receiver = null
	_door_retire_receiver = null
	_phase = "retired"
	return true


func _fail(reason: String) -> bool:
	if _reason.is_empty(): _reason = reason if not reason.is_empty() else "scene_publication_failed"
	_tree_receiver = null
	_tree_method = &""
	_phase = "teardown"
	return false


func _record_atomic(phase: String, elapsed: int, budget: int) -> void:
	if not _phase_metrics.has(phase):
		_phase_metrics[phase] = {"units":0, "maxAtomicUsec":0, "maxSliceUsec":0, "overruns":0}
	var metric: Dictionary = _phase_metrics[phase]
	metric.units += 1
	metric.maxAtomicUsec = maxi(int(metric.maxAtomicUsec), elapsed)
	if elapsed > budget: metric.overruns += 1
	_max_atomic_usec = maxi(_max_atomic_usec, elapsed)


static func _valid_parent(parent: Node3D) -> bool:
	if not is_instance_valid(parent) or parent.is_queued_for_deletion() or not parent.is_inside_tree(): return false
	var basis := parent.global_basis
	return parent.global_position.is_finite() and basis.is_equal_approx(basis.orthonormalized()) \
		and basis.y.is_equal_approx(Vector3.UP) and is_equal_approx(basis.determinant(), 1.0)


static func _valid_profile(profile: Dictionary, binding: Dictionary) -> bool:
	if not profile.is_read_only() or profile.get("siteId") != binding.siteId: return false
	var origin: Variant = profile.get("origin")
	if not origin is Vector3 or not origin.is_finite(): return false
	if not profile.get("sourceSignature") is String or String(profile.sourceSignature).is_empty(): return false
	if not profile.get("worldSeed") is String or String(profile.worldSeed).is_empty(): return false
	for key: String in ["supportMask", "distanceCells", "groundRootPoints"]:
		if not profile.get(key) is Array or not profile[key].is_read_only(): return false
	var envelope: Variant = profile.get("envelopeCells")
	return envelope is Rect2i and envelope.size.x > 0 and envelope.size.y > 0 \
		and profile.supportMask.size() == envelope.size.x * envelope.size.y \
		and profile.distanceCells.size() == profile.supportMask.size()
