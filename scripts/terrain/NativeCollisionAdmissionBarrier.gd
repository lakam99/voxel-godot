class_name NativeCollisionAdmissionBarrier
extends RefCounted

const ActorGuard = preload("res://scripts/terrain/NativeCollisionActorGuard.gd")
const CENSUS_NODES_PER_STEP := 256
const CENSUS_STEP_BUDGET_USEC := 3000
const MAX_ACTORS := 512
const FORECAST_SECONDS := 1.0 / 30.0
const MOVING_STATIC_GROUP := &"world_moving_physics_actor"

var _root: Node
var _tree: SceneTree
var _collision_owner: Node
var _identity := {}
var _bounds := AABB()
var _active := false
var _admitted_actor_ids := {}
var _actors := {}
var _scan_pending: Array[Node] = []
var _scan_complete := false
var _membership_dirty := false
var _terminal_hold := false


func is_active() -> bool:
	return _active


func begin(root: Node, collision_owner: Node, identity: Dictionary, bounds: AABB) -> Dictionary:
	if _active or root == null or not root.is_inside_tree() or collision_owner == null \
			or not collision_owner.has_method("physical_receipt") or identity.is_empty():
		return {"status": "failed", "reason": "barrier_identity_or_root_invalid"}
	var validity: Dictionary = ActorGuard.inspect([], bounds, FORECAST_SECONDS)
	if not bool(validity.get("clear", false)):
		return {"status": "failed", "reason": "barrier_region_invalid"}
	_root = root
	_tree = root.get_tree()
	_collision_owner = collision_owner
	_identity = identity.duplicate(true)
	_bounds = bounds
	_active = true
	_scan_pending = [_root]
	_scan_complete = false
	_membership_dirty = false
	_tree.node_added.connect(_on_node_added)
	_tree.node_removed.connect(_on_node_removed)
	_tree.process_frame.connect(_on_process_frame)
	return advance_census(identity)


func advance_census(identity: Dictionary) -> Dictionary:
	if not _active or _terminal_hold or identity != _identity:
		return {"status": "failed", "reason": "barrier_revision_mismatch"}
	if _root == null or not is_instance_valid(_root) or not _root.is_inside_tree():
		return {"status": "failed", "reason": "actor_census_root_lost"}
	var started_usec := Time.get_ticks_usec()
	var visited := 0
	while not _scan_pending.is_empty() and visited < CENSUS_NODES_PER_STEP \
			and Time.get_ticks_usec() - started_usec < CENSUS_STEP_BUDGET_USEC:
		var node: Node = _scan_pending.pop_back()
		visited += 1
		if not is_instance_valid(node) or node.is_queued_for_deletion():
			continue
		_register_if_moving(node)
		for child in node.get_children():
			if child is Node:
				_scan_pending.append(child)
	_scan_complete = _scan_pending.is_empty()
	if _actors.size() > MAX_ACTORS:
		return {"status": "failed", "reason": "actor_census_actor_cap"}
	return {"status": "ready" if _scan_complete else "pending",
		"actorCount": _actors.size(), "visitedNodes": visited,
		"elapsedUsec": Time.get_ticks_usec() - started_usec,
		"remainingNodes": _scan_pending.size(), "identity": _identity.duplicate(true)}


func census_progress(identity: Dictionary) -> Dictionary:
	if not _active or _terminal_hold or identity != _identity:
		return {"status": "failed", "reason": "barrier_revision_mismatch"}
	return {"status": "ready" if _scan_complete else "pending",
		"actorCount": _actors.size(), "remainingNodes": _scan_pending.size()}


func covers_bounds(identity: Dictionary, bounds: AABB) -> bool:
	return _active and not _terminal_hold and identity == _identity \
		and _bounds.encloses(bounds)


func register_moving_actor(actor: PhysicsBody3D) -> bool:
	if not _active:
		return true
	if actor == null or not is_instance_valid(actor) \
			or not actor.is_inside_tree() or not _root.is_ancestor_of(actor) \
			or not (actor is CharacterBody3D or actor is StaticBody3D \
			and actor.is_in_group(MOVING_STATIC_GROUP)):
		return false
	_register_if_moving(actor)
	_membership_dirty = true
	return _actors.size() <= MAX_ACTORS


## Actor controllers must call this before motion. A not-yet-censused actor may
## move only when its complete current shape and swept motion miss the region;
## installation remains pending until the full actor census is complete.
func admit_motion(actor: PhysicsBody3D, motion: Vector3) -> bool:
	if not _active:
		return true
	if _terminal_hold:
		return false
	if actor == null or not is_instance_valid(actor) or _root == null \
			or not is_instance_valid(_root) or not _root.is_inside_tree() \
			or not _root.is_ancestor_of(actor) or not motion.is_finite():
		return false
	if not _admitted_actor_ids.has(actor.get_instance_id()):
		_register_if_moving(actor)
		if not _actors.has(actor.get_instance_id()):
			return false
	return not ActorGuard.motion_intersects(actor, _bounds, motion)


func admit_placement(actor: PhysicsBody3D, proposed_transform: Transform3D) -> bool:
	if not _active:
		return true
	if _terminal_hold:
		return false
	if actor == null or not is_instance_valid(actor) or _root == null \
			or not is_instance_valid(_root) or not _root.is_inside_tree() \
			or not _root.is_ancestor_of(actor):
		return false
	_register_if_moving(actor)
	if not _actors.has(actor.get_instance_id()):
		return false
	return not ActorGuard.placement_intersects(actor, _bounds, proposed_transform)


func clearance(identity: Dictionary) -> Dictionary:
	if not _active or _terminal_hold or identity != _identity:
		return {"clear": false, "reason": "barrier_revision_mismatch"}
	if _root == null or not is_instance_valid(_root) or not _root.is_inside_tree():
		return {"clear": false, "reason": "actor_census_root_lost"}
	if not _scan_complete:
		return {"clear": false, "reason": "actor_census_pending"}
	if _actors.size() > MAX_ACTORS:
		return {"clear": false, "reason": "actor_census_actor_cap"}
	var actors: Array[PhysicsBody3D] = []
	for actor in _actors.values():
		if not actor is PhysicsBody3D or not is_instance_valid(actor) \
				or not actor.is_inside_tree() or not _root.is_ancestor_of(actor):
			return {"clear": false, "reason": "actor_registry_invalid"}
		actors.append(actor)
		_admitted_actor_ids[actor.get_instance_id()] = true
	var proof: Dictionary = ActorGuard.inspect(actors, _bounds, FORECAST_SECONDS)
	if bool(proof.get("clear", false)):
		_membership_dirty = false
	return proof


func release(identity: Dictionary) -> bool:
	if not _active or _terminal_hold or identity != _identity:
		return false
	if not bool(clearance(identity).get("clear", false)):
		return false
	var receipt: Dictionary = _collision_owner.call("physical_receipt", identity)
	if not bool(receipt.get("ready", false)) or int(receipt.get("physicsFrame", -1)) < 0 \
			or receipt.get("provenance", {}).get("requestIdentity") != identity:
		return false
	_clear()
	return true


## Only a pre-install rejection with the previous live physical shapes intact
## may abandon admission. A rollback after shape mutation needs new proof.
func abort(identity: Dictionary) -> bool:
	if not _active or _terminal_hold or identity != _identity or _collision_owner == null \
			or not _collision_owner.has_method("preinstall_rejection_receipt"):
		return false
	var receipt: Dictionary = _collision_owner.call("preinstall_rejection_receipt", identity)
	if not bool(receipt.get("safe", false)) \
			or receipt.get("rejectedIdentity") != identity \
			or receipt.get("retainedProvenance", {}).get("requestIdentity") == identity \
			or int(receipt.get("oldPhysicsFrame", -1)) < 0:
		return false
	_clear()
	return true


## Startup-only cancellation, before any physical owner or admitted actor.
func cancel_empty_startup(identity: Dictionary) -> bool:
	if not _active or _terminal_hold or identity != _identity or _collision_owner == null:
		return false
	if _collision_owner.has_method("startup_empty_receipt"):
		var receipt: Dictionary = _collision_owner.call("startup_empty_receipt", identity)
		if not bool(receipt.get("empty", false)):
			return false
	elif bool(_collision_owner.get("_installing")) \
			or not (_collision_owner.get("installed_shapes") as Array).is_empty():
		return false
	if not bool(clearance(identity).get("clear", false)) or not _actors.is_empty():
		return false
	_clear()
	return true


func owner_stopped(owner: Node) -> bool:
	if not _active or owner == null or owner != _collision_owner:
		return false
	_terminal_hold = true
	_disconnect_signals()
	return true


func _disconnect_signals() -> void:
	if _tree != null:
		if _tree.process_frame.is_connected(_on_process_frame):
			_tree.process_frame.disconnect(_on_process_frame)
		if _tree.node_added.is_connected(_on_node_added):
			_tree.node_added.disconnect(_on_node_added)
		if _tree.node_removed.is_connected(_on_node_removed):
			_tree.node_removed.disconnect(_on_node_removed)


func _clear() -> void:
	_disconnect_signals()
	_active = false
	_terminal_hold = false
	_root = null
	_tree = null
	_collision_owner = null
	_identity.clear()
	_admitted_actor_ids.clear()
	_actors.clear()
	_scan_pending.clear()
	_scan_complete = false
	_membership_dirty = false


func _on_process_frame() -> void:
	if _active and not _scan_complete:
		advance_census(_identity)


func _register_if_moving(node: Node) -> void:
	if node is CharacterBody3D or node is StaticBody3D and node.is_in_group(MOVING_STATIC_GROUP):
		_actors[node.get_instance_id()] = node


func _on_node_added(node: Node) -> void:
	if not _active or node == null or not _root.is_ancestor_of(node):
		return
	if node is PhysicsBody3D or node is CollisionShape3D:
		_register_if_moving(node)
		_membership_dirty = true


func _on_node_removed(node: Node) -> void:
	if not _active or node == null:
		return
	if _actors.erase(node.get_instance_id()):
		_admitted_actor_ids.erase(node.get_instance_id())
		_membership_dirty = true
