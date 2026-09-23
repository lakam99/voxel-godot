extends Node3D
class_name NativeWindowedCollisionCoordinator

signal window_retirement_drain_started(window_id: Vector3i,
	window_token: String, retirement_lease_id: String)

const Aggregate = preload("res://scripts/terrain/NativeWindowedCollisionReadiness.gd")
const AdmissionBarrier = preload("res://scripts/terrain/NativeCollisionAdmissionBarrier.gd")
const MAX_RETIRED_BARRIERS := 64
const MAX_ACTIVE_BARRIERS := 128

## Composes current N3 logical windows with N5 physical owners and owns the
## actor admission barriers. A window owner cannot release a global gate.
var _broker: Object
var _actor_root: Node
var _owners := {}
var _window_tokens := {}
var _retirement_leases := {}
var _barriers := {}
var _barrier_identities := {}
var _barrier_bounds := {}
var _retired_barriers: Array[Dictionary] = []
var _stopping := false

func setup(broker: Object, actor_root: Node) -> Dictionary:
	if _broker != null or broker == null or actor_root == null \
			or not broker.has_method("collision_window_layout") \
			or not broker.has_method("acknowledge_collision_window_retired") \
			or not broker.has_method("claim_collision_window_retirement") \
			or not broker.has_method("validate_collision_window_retirement") \
			or not broker.has_method("abort_collision_window_retirement"):
		return {"status":"failed", "reason":"window_coordinator_source_invalid"}
	_broker = broker
	_actor_root = actor_root
	return {"status":"ready"}

## Admission target contract consumed by MainCore. It may bind during startup,
## but ingress stays closed until every demanded physical window is current.
func is_active() -> bool:
	return not _stopping and _broker != null and _actor_root != null

func can_unbind() -> bool:
	return _stopping and _owners.is_empty() and active_barrier_count() == 0

func _physical_admission_ready() -> bool:
	if not is_active(): return false
	var layout: Dictionary = _broker.collision_window_layout()
	if layout.get("status") != "ready" or not layout.get("identity") is Dictionary:
		return false
	return bool(physical_receipt(layout.identity).get("ready", false))

func register_window(window: Dictionary, owner: Node3D) -> Dictionary:
	if _stopping or owner == null or not owner.is_inside_tree() \
			or not owner.has_method("physical_receipt") \
			or not window.get("id") is Vector3i \
			or String(window.get("windowToken", "")).is_empty():
		return {"status":"failed", "reason":"physical_window_registration_invalid"}
	var layout: Dictionary = _broker.collision_window_layout()
	if layout.get("status") != "ready" or not (layout.windows as Array).has(window):
		return {"status":"pending", "reason":"physical_window_layout_changed"}
	if _owners.has(window.id) and _owners[window.id] != owner:
		return {"status":"pending", "reason":"old_physical_window_not_retired"}
	_owners[window.id] = owner
	_window_tokens[window.id] = window.windowToken
	return {"status":"ready", "windowId":window.id,
		"windowToken":window.windowToken}

func begin_window_barrier(window: Dictionary, bounds: AABB,
		identity: Dictionary) -> Dictionary:
	if _stopping or _actor_root == null or not is_inside_tree() \
			or not window.get("id") is Vector3i:
		return {"status":"failed", "reason":"window_barrier_owner_invalid"}
	if active_barrier_count() >= MAX_ACTIVE_BARRIERS:
		return {"status":"pending", "reason":"window_barrier_retention_backpressure",
			"activeBarrierCount":active_barrier_count()}
	if _barriers.has(window.id) and _barriers[window.id].is_active() \
			and _retired_barriers.size() >= MAX_RETIRED_BARRIERS:
		return {"status":"pending", "reason":"window_barrier_retention_backpressure",
			"retiredBarrierCount":_retired_barriers.size()}
	var barrier = AdmissionBarrier.new()
	var begun: Dictionary = barrier.begin(_actor_root, self, identity, bounds)
	if begun.get("status") == "failed": return begun
	if _barriers.has(window.id) and _barriers[window.id].is_active():
		_retired_barriers.append({"barrier":_barriers[window.id],
			"identity":_barrier_identities[window.id], "windowId":window.id,
			"bounds":_barrier_bounds[window.id]})
	_barriers[window.id] = barrier
	_barrier_identities[window.id] = identity.duplicate(true)
	_barrier_bounds[window.id] = bounds
	return {"status":begun.status, "windowId":window.id,
		"barrier":barrier, "census":begun}

func window_barrier(id: Vector3i) -> RefCounted:
	return _barriers.get(id)

func active_barrier_count() -> int:
	var count := 0
	for barrier in _barriers.values():
		if barrier.is_active(): count += 1
	for record in _retired_barriers:
		var barrier: RefCounted = record.barrier
		if barrier.is_active(): count += 1
	return count

func aggregate_readiness(identity: Dictionary) -> Dictionary:
	if _stopping or _broker == null:
		return {"status":"pending", "reason":"window_coordinator_stopping"}
	var layout: Dictionary = _broker.collision_window_layout()
	if layout.get("status") != "ready":
		return {"status":"pending", "reason":layout.get("reason",
			"logical_collision_layout_pending")}
	if layout.get("identity") != identity:
		return {"status":"pending", "reason":"logical_collision_identity_changed"}
	var current_tokens := {}
	for window in layout.windows:
		current_tokens[window.id] = window.windowToken
	for id in _owners:
		if current_tokens.get(id) != _window_tokens.get(id):
			return {"status":"pending",
				"reason":"obsolete_physical_window_retirement_pending",
				"windowId":id}
	var receipts := {}
	for window in layout.windows:
		if not _owners.has(window.id) \
				or _window_tokens.get(window.id) != window.windowToken:
			continue
		var owner: Node3D = _owners[window.id]
		if is_instance_valid(owner):
			receipts[window.id] = owner.physical_receipt(
				window.get("identity", {}))
	return Aggregate.evaluate(layout, receipts)

func physical_receipt(identity: Dictionary) -> Dictionary:
	var aggregate: Dictionary = aggregate_readiness(identity)
	if aggregate.get("status") != "ready":
		return {"ready":false, "reason":aggregate.get("reason", "")}
	return {"ready":true, "physicsFrame":Engine.get_physics_frames(),
		"provenance":{"requestIdentity":identity.duplicate(true),
			"logicalClosureToken":aggregate.logicalClosureToken,
			"layoutToken":aggregate.layoutToken},
		"aggregate":aggregate}

func release_barriers(identity: Dictionary) -> Dictionary:
	if not bool(physical_receipt(identity).get("ready", false)):
		return {"status":"pending", "reason":"aggregate_collision_not_physical"}
	var pending: Array[Vector3i] = []
	for record in _retired_barriers:
		var barrier: RefCounted = record.barrier
		var replacement: RefCounted = _barriers.get(record.windowId)
		if replacement == null or not replacement.is_active() \
				or not replacement.covers_bounds(identity, record.bounds) \
				or not bool(replacement.clearance(identity).get("clear", false)) \
				or barrier.is_active() and not barrier.release_after_replacement(
					record.identity, identity):
			pending.append(record.windowId)
	if not pending.is_empty():
		return {"status":"pending", "reason":"window_actor_clearance_pending",
			"pendingWindowIds":pending}
	for id in _barriers:
		var barrier: RefCounted = _barriers[id]
		if barrier.is_active() and not barrier.release(identity):
			pending.append(id)
	if not pending.is_empty():
		return {"status":"pending", "reason":"window_actor_clearance_pending",
			"pendingWindowIds":pending}
	_barriers.clear()
	_barrier_identities.clear()
	_barrier_bounds.clear()
	_retired_barriers.clear()
	return {"status":"ready", "aggregate":aggregate_readiness(identity)}

func admit_motion(actor: PhysicsBody3D, motion: Vector3) -> bool:
	if _stopping: return false
	if not _physical_admission_ready(): return false
	for barrier in _barriers.values():
		if barrier.is_active() and not barrier.admit_motion(actor, motion):
			return false
	for record in _retired_barriers:
		var barrier: RefCounted = record.barrier
		if barrier.is_active() and not barrier.admit_motion(actor, motion):
			return false
	return true

func admit_placement(actor: PhysicsBody3D, transform: Transform3D) -> bool:
	if _stopping: return false
	if not _physical_admission_ready(): return false
	for barrier in _barriers.values():
		if barrier.is_active() and not barrier.admit_placement(actor, transform):
			return false
	for record in _retired_barriers:
		var barrier: RefCounted = record.barrier
		if barrier.is_active() and not barrier.admit_placement(actor, transform):
			return false
	return true

func register_moving_actor(actor: PhysicsBody3D) -> bool:
	if _stopping: return false
	if not _physical_admission_ready(): return false
	for barrier in _barriers.values():
		if barrier.is_active() and not barrier.register_moving_actor(actor):
			return false
	for record in _retired_barriers:
		var barrier: RefCounted = record.barrier
		if barrier.is_active() and not barrier.register_moving_actor(actor):
			return false
	return true

func retire_window(id: Vector3i) -> Dictionary:
	if _stopping or not _owners.has(id):
		return {"status":"failed", "reason":"physical_window_not_registered"}
	var token: String = _window_tokens[id]
	var layout: Dictionary = _broker.collision_window_layout()
	var lease: Dictionary = _retirement_leases.get(id, {})
	if lease.is_empty():
		if layout.get("status") == "ready":
			for window in layout.windows:
				if window.get("windowToken") == token:
					return {"status":"pending", "reason":"physical_window_still_demanded"}
		elif layout.get("reason") != "collision_window_retirement_backpressure":
			return {"status":"pending", "reason":"physical_window_retirement_not_requested"}
	if not _barriers.has(id) or not _barriers[id].is_active():
		return {"status":"pending", "reason":"window_actor_barrier_required"}
	var barrier: RefCounted = _barriers[id]
	var identity: Dictionary = _barrier_identities[id]
	if not bool(barrier.clearance(identity).get("clear", false)):
		return {"status":"pending", "reason":"window_actor_clearance_pending"}
	if lease.is_empty():
		var layout_token := String(layout.get("layoutToken", ""))
		var claim: Dictionary = _broker.claim_collision_window_retirement(token,
			layout_token)
		if claim.get("status") != "ready":
			return {"status":"pending", "reason":claim.get("reason",
				"window_retirement_lease_pending"), "lease":claim}
		lease = {"leaseId":String(claim.get("leaseId", "")),
			"layoutToken":layout_token}
		if String(lease.leaseId).is_empty():
			return {"status":"pending", "reason":"window_retirement_lease_invalid"}
		_retirement_leases[id] = lease
	else:
		var valid_lease: Dictionary = _broker.validate_collision_window_retirement(
			token, String(lease.leaseId))
		if valid_lease.get("status") != "ready":
			return {"status":"pending", "reason":"window_retirement_lease_stale",
				"lease":valid_lease}
	var owner: Node3D = _owners[id]
	window_retirement_drain_started.emit(id, token, String(lease.leaseId))
	var drained: Dictionary = await owner.stop_and_drain()
	if drained.get("status") != "ready" or not bool(drained.get("drained", false)) \
			or int(drained.get("remainingBodies", -1)) != 0 \
			or drained.get("windowToken") != token:
		if bool(drained.get("ownerUnchanged", false)) \
				and _broker.abort_collision_window_retirement(token,
					String(lease.leaseId), true).get("status") == "ready":
			_retirement_leases.erase(id)
			return {"status":"pending", "reason":"physical_window_drain_retry",
				"drain":drained}
		if drained.get("status") == "pending":
			return {"status":"pending", "reason":"physical_window_drain_pending",
				"drain":drained}
		return {"status":"failed", "reason":"physical_window_drain_unproven_terminal_hold",
			"drain":drained}
	var lease_valid: Dictionary = _broker.validate_collision_window_retirement(
		token, String(lease.leaseId))
	if lease_valid.get("status") != "ready":
		return {"status":"pending", "reason":"window_retirement_lease_stale",
			"drain":drained, "lease":lease_valid}
	drained["retirementLeaseId"] = lease.leaseId
	var acknowledged: Dictionary = _broker.acknowledge_collision_window_retired(
		token, drained)
	if acknowledged.get("status") != "ready":
		return {"status":"pending", "reason":"window_retirement_ack_pending",
			"drain":drained, "acknowledgement":acknowledged}
	_owners.erase(id)
	_window_tokens.erase(id)
	_retirement_leases.erase(id)
	owner.queue_free()
	return {"status":"ready", "windowId":id, "windowToken":token,
		"drain":drained, "acknowledgement":acknowledged}

func stop_and_drain() -> Dictionary:
	_stopping = true
	for barrier in _barriers.values():
		if barrier.is_active(): barrier.owner_stopped(self)
	for record in _retired_barriers:
		var barrier: RefCounted = record.barrier
		if barrier.is_active(): barrier.owner_stopped(self)
	var incomplete: Array[Vector3i] = []
	for id in _owners.keys():
		var owner: Node3D = _owners[id]
		if not is_instance_valid(owner):
			incomplete.append(id)
			continue
		var drained: Dictionary = await owner.stop_and_drain()
		if drained.get("status") != "ready" \
				or not bool(drained.get("drained", false)) \
				or int(drained.get("remainingBodies", -1)) != 0:
			incomplete.append(id)
			continue
		owner.queue_free()
		_owners.erase(id)
		_window_tokens.erase(id)
	if not incomplete.is_empty():
		return {"status":"pending", "reason":"physical_window_drain_pending",
			"incompleteWindowIds":incomplete,
			"remainingOwners":_owners.size(),
			"activeBarriers":active_barrier_count()}
	await get_tree().process_frame
	if get_child_count() != 0:
		return {"status":"pending", "reason":"physical_window_children_draining",
			"remainingChildren":get_child_count(),
			"activeBarriers":active_barrier_count()}
	_barriers.clear()
	_barrier_identities.clear()
	_barrier_bounds.clear()
	_retired_barriers.clear()
	_retirement_leases.clear()
	return {"status":"ready", "drained":true,
		"remainingChildren":get_child_count(),
		"activeBarriers":active_barrier_count()}
