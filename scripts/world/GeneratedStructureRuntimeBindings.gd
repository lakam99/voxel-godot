extends RefCounted
class_name GeneratedStructureRuntimeBindings

## Ordinary generated-scene callbacks, not a second prop/door authority. Main
## retains this adapter while any capturing scene jobs or retirements remain.
## Successful configuration is identity-pinned; use a new adapter only after
## the old owner's jobs retire. No strong Main/registry reference is retained.
var _main: WeakRef
var _npc: WeakRef
var _autonomy: WeakRef
var _smart: WeakRef
var _portals: WeakRef
const MAX_CONSTRUCTION_ACTOR_QUERY_RESULTS := 64

func configure(main) -> bool:
	if _main != null:
		return is_same(_main.get_ref(), main) and available()
	var owners := _current_owners(main)
	if owners.is_empty(): return false
	_main = weakref(main)
	_npc = weakref(owners.npc)
	_autonomy = weakref(owners.autonomy)
	_smart = weakref(owners.smart)
	_portals = weakref(owners.portals)
	return true

func available() -> bool:
	if _main == null: return false
	var owners := _current_owners(_main.get_ref())
	return not owners.is_empty() \
		and is_same(_npc.get_ref(), owners.npc) \
		and is_same(_autonomy.get_ref(), owners.autonomy) \
		and is_same(_smart.get_ref(), owners.smart) \
		and is_same(_portals.get_ref(), owners.portals)

## Pause construction while the active capsule overlaps the admitted footprint.
## Loading may build under a physics-disabled player; Main must separately
## establish final capsule clearance before it resumes gameplay.
func construction_allowed(reservation_cells: Rect2i) -> bool:
	if not available() or reservation_cells.size.x <= 0 or reservation_cells.size.y <= 0: return false
	var state: Dictionary = _construction_player_state()
	if state.is_empty(): return false
	return bool(state.loadingExempt) or not reservation_cells.intersects(state.playerCells)

## One actor/registry read for a batch, without enclosing the empty space
## between disjoint members. The input remains source collision obligations.
func construction_members_allowed(member_bounds: Array) -> bool:
	if not available(): return false
	var state: Dictionary = _construction_player_state()
	if state.is_empty(): return false
	var main = _main.get_ref()
	var player = main.get("player")
	for value: Variant in member_bounds:
		if not value is AABB: return false
		var bounds: AABB = value
		if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() \
				or bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0: return false
		# The active player is checked from its current capsule even before a newly
		# added fixture/body has synchronized into PhysicsServer. Loading exempts
		# only that deliberately physics-disabled player, never other live actors.
		if not state.loadingExempt and bounds.intersects(state.playerBounds): return false
		if _construction_actor_overlaps(bounds,player): return false
	return true

## Fresh broad-phase evidence for every collision-bearing installation member.
## This is deliberately queried at the final job boundary rather than cached:
## actor movement, replacement, collision disablement and vertical separation
## are all observed by the physics owner. Static NPC/hostile/wildlife bodies are
## included by their production identity, while terrain/structure bodies are not.
func _construction_actor_overlaps(bounds: AABB, player) -> bool:
	var main = _main.get_ref()
	if not _usable(main) or not main is Node3D or main.get_world_3d()==null: return true
	var shape := BoxShape3D.new()
	shape.size = bounds.size
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY,bounds.get_center())
	query.collision_mask = 0xFFFFFFFF
	query.collide_with_bodies = true
	query.collide_with_areas = false
	if _usable(player) and player is CollisionObject3D: query.exclude = [player.get_rid()]
	var hits: Array[Dictionary] = main.get_world_3d().direct_space_state.intersect_shape(query,MAX_CONSTRUCTION_ACTOR_QUERY_RESULTS)
	for hit: Dictionary in hits:
		var collider = hit.get("collider")
		if not _usable(collider) or not collider is CollisionObject3D: continue
		var kind := String(collider.get_meta("kind",""))
		if collider is CharacterBody3D or kind in ["npc","hostile","wildlife"] \
				or String(collider.get_meta("material",""))=="wildlife":
			return true
	return false

## Caller has already checked the identity-pinned runtime owners. No yielding,
## movement, collider mutation or registration occurs while using this snapshot.
func _construction_player_state() -> Dictionary:
	var main = _main.get_ref()
	var player = main.get("player")
	if not _usable(player) or not player is CharacterBody3D or not player.is_inside_tree(): return {}
	var collider = player.get_node_or_null("PlayerCollider")
	if not _usable(collider) or not collider is CollisionShape3D or not collider.shape is CapsuleShape3D: return {}
	var capsule: CapsuleShape3D = collider.shape
	var cell_value: Variant = main.CELL
	if not (cell_value is float or cell_value is int): return {}
	var cell_size := float(cell_value)
	var center: Vector3 = collider.global_position
	var basis: Basis = collider.global_basis
	if not is_finite(cell_size) or cell_size <= 0.0 or not is_finite(capsule.radius) or capsule.radius <= 0.0 \
			or not center.is_finite() or not basis.x.is_finite() or not basis.y.is_finite() or not basis.z.is_finite(): return {}
	# Upright capsule support is the actual PlayerCollider contract. A tilted or
	# collapsed transform cannot be approximated by a guessed horizontal radius.
	if basis.y.length_squared() <= 0.0 or not is_zero_approx(basis.y.x) or not is_zero_approx(basis.y.z): return {}
	var radius_x := capsule.radius * Vector2(basis.x.x, basis.z.x).length()
	var radius_z := capsule.radius * Vector2(basis.x.z, basis.z.z).length()
	var radius_y := maxf(capsule.height*0.5,capsule.radius)*basis.y.length()
	if not is_finite(radius_x) or not is_finite(radius_z) or not is_finite(radius_y) \
			or radius_x <= 0.0 or radius_z <= 0.0 or radius_y <= 0.0: return {}
	if not player.is_physics_processing() and (main.get("startup_loading_active") == true or main.get("runtime_loading_active") == true):
		return {"loadingExempt":true,"cellSize":cell_size}
	# Same sample-node bounds convention as BuildingSiteManifestBuilder:
	# floor(min/CELL) through ceil(max/CELL), inclusive, in a half-open Rect2i.
	var minimum := Vector2i(floori((center.x-radius_x)/cell_size), floori((center.z-radius_z)/cell_size))
	var maximum := Vector2i(ceili((center.x+radius_x)/cell_size)+1, ceili((center.z+radius_z)/cell_size)+1)
	var player_bounds := AABB(center-Vector3(radius_x,radius_y,radius_z),Vector3(radius_x*2.0,radius_y*2.0,radius_z*2.0))
	return {"loadingExempt":false,"cellSize":cell_size,"playerCells":Rect2i(minimum,maximum-minimum),"playerBounds":player_bounds}

func publish_tree(parent: Node3D, prop_id: String, position: Vector3, biome: String, tree_request: Dictionary, rotation_y: float) -> Dictionary:
	if not available(): return _unavailable()
	# Preserve ordinary deferred/harvested/published receipts and their body.
	# In particular, never drop a created body by replacing its receipt: the job
	# must capture and retire it even if its owner cancels during publication.
	return _main.get_ref().make_tree_from_runtime_request(parent, prop_id, position, biome, tree_request, rotation_y)

func retire_tree(prop_id: String, body) -> Dictionary:
	if not available(): return _unavailable()
	if prop_id.is_empty(): return {"status":"failed", "reason":"invalid_tree"}
	var registration = _smart.get_ref().registrations.get("prop:"+prop_id)
	if not is_instance_valid(body):
		# Ordinary harvest may have freed the body's weak reference after scene
		# readiness. Only Main's existing durable delta authorizes this absence;
		# a live same-ID replacement must never inherit that cleanup receipt.
		var removed: Variant = _main.get_ref().get("removed_props")
		if removed is Dictionary and removed.has(prop_id) \
				and (registration == null or not is_instance_valid(registration.node)):
			return {"status":"absent", "objectId":"prop:"+prop_id}
		return {"status":"failed", "reason":"missing_tree_not_durably_removed", "objectId":"prop:"+prop_id}
	if not _usable(body) or not body is StaticBody3D or String(body.get_meta("prop_id", "")) != prop_id:
		return {"status":"failed", "reason":"invalid_tree"}
	if registration != null and is_instance_valid(registration.node) and not is_same(registration.node, body):
		return {"status":"failed", "reason":"object_binding_mismatch", "objectId":"prop:"+prop_id}
	var queue = _main.get_ref().get("tree_publication_queue")
	if queue == null:
		# Explicitly unqueued synthetic/ordinary bodies need no publication drain.
		# Published trees also require cancellation: the shared queue may own LOD
		# or proxy work after the initial visual has completed.
		if body.has_meta("tree_visual_state") or body.has_meta("tree_publication_cancelled"):
			return {"status":"failed", "reason":"tree_publication_queue_missing"}
	else:
		if not _usable(queue) or not queue.has_method("cancel_body_publication"):
			return {"status":"failed", "reason":"tree_publication_queue_unavailable"}
		var instance_id: int = body.get_instance_id()
		var cancelled: Variant = queue.cancel_body_publication(body)
		if not cancelled is Dictionary or cancelled.get("status") != "cancelled" or cancelled.get("bodyInstanceId") != instance_id:
			return {"status":"failed", "reason":"tree_publication_cancel_not_acknowledged"}
		if not available() or not is_same(queue, _main.get_ref().get("tree_publication_queue")):
			return {"status":"failed", "reason":"runtime_registry_changed"}
		if not _usable(body) or String(body.get_meta("prop_id", "")) != prop_id:
			return {"status":"failed", "reason":"tree_retirement_owner_lost"}
	# Streaming unbind only: no harvest/durable removal and no Node destruction.
	var result: Dictionary = _npc.get_ref().notify_navigation_prop_unloaded(prop_id, body)
	if not available(): return {"status":"failed", "reason":"runtime_registry_changed"}
	return result

func register_door(body) -> Dictionary:
	if not available(): return _unavailable()
	if not _usable(body) or not body is Node or not body.is_inside_tree():
		return {"status":"failed", "reason":"invalid_door"}
	var portals = _portals.get_ref()
	# Repeated acknowledgement must not re-register/reset the smart object.
	# Existing partial/mismatched registrations fail closed instead of repair.
	if not portals.door_to_portal.has(body.get_instance_id()):
		_npc.get_ref().notify_navigation_door_registered(body)
	if not available(): return {"status":"failed", "reason":"runtime_registry_changed"}
	if not _usable(body): return {"status":"failed", "reason":"registered_door_lost"}
	var portal = portals.portal_for_door(body)
	if not _usable(portal): return {"status":"failed", "reason":"door_registration_not_acknowledged"}
	var portal_id := String(portal.portal_id)
	if portal_id.is_empty() or portals.door_to_portal.get(body.get_instance_id()) != portal_id \
			or not portal.leaf_nodes.has(body):
		return {"status":"failed", "reason":"door_registration_identity_mismatch"}
	var registration = _smart.get_ref().registrations.get(portal_id)
	if not _usable(registration) or registration.kind != "door" \
			or not _usable(registration.node) or not portal.leaf_nodes.has(registration.node):
		return {"status":"failed", "reason":"door_smart_registration_missing"}
	return {"status":"registered", "portalId":portal_id}

func retire_door(body) -> Dictionary:
	if not available(): return _unavailable()
	if not _usable(body) or not body is Node:
		return {"status":"failed", "reason":"invalid_door"}
	var result: Dictionary = _npc.get_ref().notify_navigation_door_unregistered(body)
	if not available(): return {"status":"failed", "reason":"runtime_registry_changed"}
	return result

static func _usable(value) -> bool:
	return is_instance_valid(value) and (not value is Node or not value.is_queued_for_deletion())

static func _current_owners(main) -> Dictionary:
	if not _usable(main) or not main is Node or not main.has_method("make_tree_from_runtime_request"):
		return {}
	var npc = main.get("npc_system")
	if not _usable(npc): return {}
	for method: String in ["notify_navigation_prop_unloaded", "notify_navigation_door_registered", "notify_navigation_door_unregistered"]:
		if not npc.has_method(method): return {}
	var autonomy = npc.get("autonomy_system")
	if not _usable(autonomy): return {}
	var smart = autonomy.get("smart_objects")
	var portals = autonomy.get("door_portals")
	if not _usable(smart) or not _usable(portals) or not portals.has_method("portal_for_door"):
		return {}
	if not is_same(smart.get("door_portals"), portals): return {}
	return {"npc":npc, "autonomy":autonomy, "smart":smart, "portals":portals}

static func _unavailable() -> Dictionary:
	return {"status":"failed", "reason":"runtime_bindings_unavailable", "sideEffects":false}
