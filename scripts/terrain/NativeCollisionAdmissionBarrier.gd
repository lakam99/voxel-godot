class_name NativeCollisionAdmissionBarrier
extends RefCounted

const ActorGuard = preload("res://scripts/terrain/NativeCollisionActorGuard.gd")
const MAX_SCENE_NODES := 8192
const MAX_ACTORS := 512
const FORECAST_SECONDS := 1.0 / 30.0

var _root: Node
var _collision_owner: Node
var _identity := {}
var _bounds := AABB()
var _active := false
var _admitted_actor_ids := {}


func begin(root: Node, collision_owner: Node, identity: Dictionary, bounds: AABB) -> Dictionary:
	if _active or root == null or not root.is_inside_tree() or collision_owner == null \
			or not collision_owner.has_method("physical_receipt") or identity.is_empty():
		return {"status": "failed", "reason": "barrier_identity_or_root_invalid"}
	var validity: Dictionary = ActorGuard.inspect([], bounds, FORECAST_SECONDS)
	if not bool(validity.get("clear", false)):
		return {"status": "failed", "reason": "barrier_region_invalid"}
	_root = root
	_collision_owner = collision_owner
	_identity = identity.duplicate(true)
	_bounds = bounds
	_active = true
	var census := _census()
	if census.get("status") != "ready":
		_active = false
		return census
	for actor: CharacterBody3D in census.actors:
		_admitted_actor_ids[actor.get_instance_id()] = true
	return {"status": "ready", "actorCount": census.actors.size(),
		"identity": _identity.duplicate(true)}


## Actor controllers must call this before applying a motion while the barrier
## is active. An unregistered actor is held until the next clearance census.
func admit_motion(actor: CharacterBody3D, motion: Vector3) -> bool:
	if not _active:
		return true
	if actor == null or not is_instance_valid(actor) or not _admitted_actor_ids.has(actor.get_instance_id()) \
			or _root == null or not _root.is_ancestor_of(actor) or not motion.is_finite():
		return false
	return not ActorGuard.motion_intersects(actor, _bounds, motion)


func clearance(identity: Dictionary) -> Dictionary:
	if not _active or identity != _identity:
		return {"clear": false, "reason": "barrier_revision_mismatch"}
	var census := _census()
	if census.get("status") != "ready":
		return {"clear": false, "reason": census.get("reason", "actor_census_failed")}
	for actor: CharacterBody3D in census.actors:
		_admitted_actor_ids[actor.get_instance_id()] = true
	return ActorGuard.inspect(census.actors, _bounds, FORECAST_SECONDS)


func release(identity: Dictionary) -> bool:
	if not _active or identity != _identity:
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
	if not _active or identity != _identity or _collision_owner == null \
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
	if not _active or identity != _identity or _collision_owner == null \
			or bool(_collision_owner.get("_installing")) \
			or not (_collision_owner.get("installed_shapes") as Array).is_empty():
		return false
	var census := _census()
	if census.get("status") != "ready" or not (census.get("actors", []) as Array).is_empty():
		return false
	_clear()
	return true


func _clear() -> void:
	_active = false
	_root = null
	_collision_owner = null
	_identity.clear()
	_admitted_actor_ids.clear()


func _census() -> Dictionary:
	if _root == null or not is_instance_valid(_root) or not _root.is_inside_tree():
		return {"status": "failed", "reason": "actor_census_root_lost"}
	var pending: Array[Node] = [_root]
	var visited := 0
	var actors: Array[CharacterBody3D] = []
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		visited += 1
		if visited > MAX_SCENE_NODES:
			return {"status": "failed", "reason": "actor_census_node_cap", "visitedNodes": visited}
		if node is CharacterBody3D:
			actors.append(node)
			if actors.size() > MAX_ACTORS:
				return {"status": "failed", "reason": "actor_census_actor_cap"}
		for child in node.get_children():
			if child is Node:
				pending.append(child)
	return {"status": "ready", "actors": actors, "visitedNodes": visited}
