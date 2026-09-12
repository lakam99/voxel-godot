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
	if not _valid_parent(parent): return {"status":"rejected", "reason":"invalid_parent"}
	if not tree_callback.is_valid() or tree_callback.is_custom() or tree_callback.get_object() == self:
		return {"status":"rejected", "reason":"tree_callback_requires_object_method"}
	_binding = binding.duplicate()
	_binding.make_read_only()
	_cpu = {"prepared":prepared, "profile":profile, "binding":_binding,
		"nodeMetadata":[], "treeBodies":_tree_bodies, "treeIds":_tree_ids,
		"registeredTreeIds":_registered_tree_ids, "treeVisualSeen":_tree_visual_seen,
		"treeRetirementClaims":_tree_retirement_claims, "treeClaimOrder":_tree_claim_order}
	_parent = weakref(parent)
	_tree_receiver = weakref(tree_callback.get_object())
	_tree_method = tree_callback.get_method()
	_phase = "building_begin"
	return status()


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
		"doorsRegistered":_door_registered_ids.size(), "doorClaims":_door_claims.size(), "doorsRetired":_doors_retired}


func advance(budget_usec: int = 2500) -> Dictionary:
	if _advancing: return {"status":"rejected", "reason":"reentrant_advance"}
	if budget_usec < 1 or budget_usec > 4000: return {"status":"rejected", "reason":"invalid_slice_budget"}
	if _phase in ["idle", "ready", "retired", "consumed"]: return status()
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
		if not progressed or _phase in ["ready", "retired", "consumed"]: break
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
		# Includes caller work, result snapshots and frame waits; not pure sleep.
		"betweenAdvanceUsec":_between_advance_usec,
		"phaseMetrics":_phase_metrics.duplicate(true)}

func _spatial_dependency_summary() -> Dictionary:
	var packet = _cpu.get("buildingBegin",{}).get("spatialDependencies")
	return packet.summary() if packet != null else {}

func source_dependency_requirements(bounds: Rect2i, expected_binding: Dictionary) -> Dictionary:
	if _cancelled or not _reason.is_empty() or _phase in ["idle", "retired", "consumed"] or expected_binding != _binding:
		return {"status":"pending","reason":"structure_source_owner_unavailable"}
	# This cutover retains full-site publication. Pending retries must not walk
	# the entire immutable part/crossing graph on every loading frame.
	if _phase != "ready": return {"status":"pending","reason":"structure_collision_publication_pending"}
	var packet = _cpu.get("buildingBegin",{}).get("spatialDependencies")
	if packet == null: return {"status":"pending","reason":"structure_source_dependencies_pending"}
	if packet.binding != _binding or packet.origin != _cpu.profile.origin:
		return {"status":"failed","reason":"structure_dependency_binding_mismatch"}
	# This is the obligation set, never scene/navigation readiness. The same
	# holder is retired by the existing one-shot CPU/resource retirement path.
	var result: Dictionary = packet.requirements(bounds)
	if result.get("status") != "described": return result
	# Resolve declared crossings through the same live owner used by tile source
	# publication. These are obligations and physical receipts, never nav acks.
	var artifacts := {}
	for source_id: String in result.requiredCrossings:
		var crossing: Dictionary = result.requiredCrossings[source_id]
		var tile_key := String(crossing.ownerTileKey)
		if tile_key.is_empty(): continue
		if not artifacts.has(tile_key): artifacts[tile_key] = navigation_tile_artifact(tile_key,expected_binding)
		var artifact: Dictionary = artifacts[tile_key]
		if artifact.get("status") != "ready":
			if result.status != "failed":
				result.status = String(artifact.get("status","pending"))
				result.reason = String(artifact.get("reason","structure_crossing_owner_pending"))
			continue
		if crossing.kind == "doors":
			var body_ref = artifact.doorBodies.get(String(crossing.sourcePartId))
			var body = body_ref.get_ref() if body_ref is WeakRef else null
			if not _door_body_valid(body):
				if result.status != "failed":
					result.status = "pending"
					result.reason = "structure_crossing_door_owner_pending"
				continue
			var portal_id := String(body.get_meta("door_portal_id",""))
			crossing["portalId"] = portal_id
			crossing.requiredLinkIds = ["door-link:%s:%s" % [portal_id,tile_key]]
			crossing.mappingStatus = "described"
		else:
			var found := false
			for link: Dictionary in artifact.tile.get("crossingLinks",[]):
				if String(link.get("id","")) == source_id: found = true; break
			if not found and not result.unresolvedCrossingIds.has(source_id): result.unresolvedCrossingIds.append(source_id)
	if not result.missingSourceIds.is_empty() or not result.unresolvedCrossingIds.is_empty():
		result.status = "failed"
		result.reason = "structure_source_dependencies_unresolved"
	result["physicalOwnerAcknowledgements"] = {"binding":_binding,"sceneReady":_phase=="ready",
		"sceneInstanceId":_root.get_instance_id() if is_instance_valid(_root) else 0,
		"registeredDoorCount":_door_registered_ids.size()}
	return result

func source_dependency_revision() -> Array:
	# Cheap cache identity; no manifest traversal or dependency recompilation.
	return [_binding,_phase,_cancelled,_reason,_door_registered_ids.size(),
		_root.get_instance_id() if is_instance_valid(_root) and not _root.is_queued_for_deletion() and _root.is_inside_tree() else 0,
		_root.global_transform if is_instance_valid(_root) and _root.is_inside_tree() else Transform3D.IDENTITY,
		_root.get_parent().get_instance_id() if is_instance_valid(_root) and _root.get_parent()!=null else 0]

func navigation_tile_artifact(tile_key: String, expected_binding: Dictionary) -> Dictionary:
	if _cancelled or not _reason.is_empty() or expected_binding!=_binding:
		return {"status":"pending","reason":"structure_navigation_owner_unavailable"}
	if _phase!="ready": return {"status":"pending","reason":"structure_collision_publication_pending"}
	var packet = _cpu.get("buildingBegin",{}).get("spatialDependencies")
	if packet==null or packet.binding!=_binding or packet.origin!=_cpu.profile.origin:
		return {"status":"failed","reason":"structure_navigation_source_mismatch"}
	var parent: Node3D = _parent.get_ref() as Node3D if _parent != null else null
	if not _valid_parent(parent) or not is_instance_valid(_root) or _root.is_queued_for_deletion() \
			or _root.get_parent()!=parent or not _root.is_inside_tree() or not _root.global_transform.is_equal_approx(Transform3D(Basis.IDENTITY,packet.origin)):
		return {"status":"pending","reason":"structure_navigation_scene_owner_lost"}
	var tile: Dictionary = packet.navigation_tiles.tiles.get(tile_key,{})
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
			var outcome: Dictionary = _building.begin_prepared_publication(_cpu.prepared, _root, _binding,
				{"batchStaticParts":true, "publicationSiteId":_binding.siteId, "resumableScenePublication":true})
			_cpu["buildingBegin"] = outcome
			if _cancelled: return false
			if not bool(outcome.get("ready", false)): return _fail(String(outcome.get("reason", "building_begin_failed")))
			_blueprint = outcome.blueprint
			_plan = outcome.furnishingPlan
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
			if result.get("status") == "ready": _phase = "building"
		"building":
			if _building.has_pending_static_flush():
				var flushed: Dictionary = _building.advance_static_flush(_root,clampi(remaining_usec,1,4000))
				if _cancelled: return false
				if flushed.status=="failed": return _fail(String(flushed.reason))
			elif _building_cursor >= _blueprint.parts.size():
				_phase = "building_finish"
			else:
				var next: int = _building.publish_part_batch(_blueprint, _root, _building_cursor, 1,clampi(remaining_usec,1,4000))
				if _cancelled: return false
				var result: Dictionary = _building.publication_status()
				if _cancelled: return false
				if result.get("status") == "failed": return _fail(String(result.get("reason", "building_failed")))
				if next <= _building_cursor:
					if result.get("status")=="pending_budget": return true
					return _fail("building_cursor_stalled")
				_building_cursor = next
		"building_finish":
			var result: Dictionary = _building.finish_scene_publication(_blueprint, _root,clampi(remaining_usec,1,4000))
			_cpu["buildingFinish"] = result
			if _cancelled: return false
			if result.get("status")=="pending_budget": return true
			if not bool(result.get("complete", false)): return _fail(String(result.get("reason", "building_incomplete")))
			_phase = "door_registration" if _door_receiver != null else "furniture_begin"
		"door_registration":
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
			if _furniture_cursor >= _plan.parts.size():
				_phase = "furniture_finish"
			else:
				var next: int = _furniture.publish_part_batch(_plan, _root, _furniture_cursor, 1)
				if _cancelled: return false
				if next <= _furniture_cursor: return _fail("furniture_cursor_stalled")
				_furniture_cursor = next
		"furniture_finish":
			_cpu["furnitureFinish"] = _furniture.finish_publication(_plan, _root)
			if _cancelled: return false
			_phase = "tree_registration"
		"tree_registration":
			return _register_tree()
		"tree_visuals":
			return _check_tree_visual()
	return true


func _register_door() -> bool:
	if _door_cursor >= _building.published_nodes.size():
		_phase = "furniture_begin"
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
	if _cancelled or _phase != "door_registration": return false
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
	if _tree_cursor >= _trees.size():
		_tree_receiver = null
		_tree_method = &""
		_phase = "tree_visuals"
		return true
	var record: Variant = _trees[_tree_cursor]
	if not record is Dictionary: return _fail("invalid_tree_record")
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
		"published":
			var body: Variant = result.get("body")
			if not body is StaticBody3D or not is_instance_valid(body) or not _root.is_ancestor_of(body):
				return _fail("invalid_published_tree_body")
			_tree_bodies.append(weakref(body))
			_tree_visual_seen.append(false)
		_: return _fail(String(result.get("reason", "tree_registration_failed")))
	_tree_ids[prop_id] = true
	_tree_cursor += 1
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
