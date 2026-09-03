extends RefCounted
class_name CitadelPublicationService

## StructureSystem-owned preparation and scene-job lifecycle. Scene construction
## is distinct from gameplay activation: doors/access must be acknowledged by
## the ordinary owner before a constructed city can become playable.
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const SceneJob = preload("res://scripts/buildings/BuildingScenePublicationJob.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const MAX_REGIONS := 16
const PREPARATION_TIMEOUT_USEC := 60000000

var _admission
var _worker = Worker.new()
var _generation := 0
var _seed := ""
var _closing := false
var _desired: Dictionary = {}
var _prepared: Dictionary = {}
var _retired: Dictionary = {}
var _inflight: Dictionary = {}
var _failures: Dictionary = {}
var _retirement_serial := 0
var _last_worker_status: Dictionary = {}
var _max_advance_usec := 0
var _dispatch_count := 0
var _accepted_count := 0
var _scene_parent: WeakRef
var _tree_receiver: WeakRef
var _tree_method: StringName
var _tree_retire_receiver: WeakRef
var _tree_retire_method: StringName
var _door_lifecycle_configured := false
var _door_receiver: WeakRef
var _door_method: StringName
var _door_retire_receiver: WeakRef
var _door_retire_method: StringName
var _scenes: Dictionary = {}
var _retiring_scenes: Array = []
var _pending_scene_disposals: Dictionary = {}
var _submitted_scene_disposals: Dictionary = {}
var _scene_cursor := 0
var _prefer_retirement := true
var _scene_started_count := 0
var _scene_completed_count := 0
var _scene_max_step_usec := 0
var _advancing := false
var _configuration_serial := 0
var _world_reset_pending := false
var _world_reset_release_requested := false
var _worker_polled_configuration := -1

## Bind only after the owner can balance its ordinary scene/tree lifecycle.
## No strong owner/callback cycles; reject capturing/bound custom callables.
## A new root cannot inherit old nodes or lose their cleanup receiver.
func configure_scene_publication(parent: Node3D, tree_publish: Callable, tree_retire: Callable) -> bool:
	if _closing or not SceneJob._valid_parent(parent): return false
	if not _ordinary_callback(tree_publish) or not _ordinary_callback(tree_retire): return false
	var same: bool = _scene_parent!=null and _scene_parent.get_ref()==parent \
		and _tree_receiver!=null and _tree_receiver.get_ref()==tree_publish.get_object() and _tree_method==tree_publish.get_method() \
		and _tree_retire_receiver!=null and _tree_retire_receiver.get_ref()==tree_retire.get_object() and _tree_retire_method==tree_retire.get_method()
	if not same and (not _scenes.is_empty() or _has_scene_retirements()): return false
	_scene_parent=weakref(parent)
	_tree_receiver=weakref(tree_publish.get_object()); _tree_method=tree_publish.get_method()
	_tree_retire_receiver=weakref(tree_retire.get_object()); _tree_retire_method=tree_retire.get_method()
	return true

## Optional only for existing construction diagnostics. The ordinary runtime
## owner must bind this balanced pair before enabling scene publication.
## Once opted in, receiver loss is not permission to fall back to diagnostics.
## Jobs capture their own weak pair; neither paused nor retiring owners may
## inherit a replacement, even after their root nodes have disappeared.
func configure_door_publication(register_callback: Callable, unregister_callback: Callable) -> bool:
	if _closing: return false
	if not _ordinary_callback(register_callback) or not _ordinary_callback(unregister_callback): return false
	var same: bool = _door_lifecycle_configured \
		and _door_receiver!=null and is_same(_door_receiver.get_ref(),register_callback.get_object()) and _door_method==register_callback.get_method() \
		and _door_retire_receiver!=null and is_same(_door_retire_receiver.get_ref(),unregister_callback.get_object()) and _door_retire_method==unregister_callback.get_method()
	if same: return true
	if not _scenes.is_empty() or _has_scene_retirements(): return false
	_door_receiver=weakref(register_callback.get_object()); _door_method=register_callback.get_method()
	_door_retire_receiver=weakref(unregister_callback.get_object()); _door_retire_method=unregister_callback.get_method()
	_door_lifecycle_configured=true
	return true

func _ordinary_callback(callback: Callable) -> bool:
	return callback.is_valid() and not callback.is_custom() and callback.get_object()!=self

func _door_callbacks_ready() -> bool:
	return _door_lifecycle_configured \
		and _door_receiver!=null and is_instance_valid(_door_receiver.get_ref()) and Callable(_door_receiver.get_ref(),_door_method).is_valid() \
		and _door_retire_receiver!=null and is_instance_valid(_door_retire_receiver.get_ref()) and Callable(_door_retire_receiver.get_ref(),_door_retire_method).is_valid()

func _scene_callbacks_ready() -> bool:
	var parent: Node3D=_scene_parent.get_ref() as Node3D if _scene_parent!=null else null
	return is_instance_valid(parent) and parent.is_inside_tree() and not parent.is_queued_for_deletion() \
		and _tree_receiver!=null and is_instance_valid(_tree_receiver.get_ref()) and Callable(_tree_receiver.get_ref(),_tree_method).is_valid() \
		and _tree_retire_receiver!=null and is_instance_valid(_tree_retire_receiver.get_ref()) and Callable(_tree_retire_receiver.get_ref(),_tree_retire_method).is_valid() \
		and (not _door_lifecycle_configured or _door_callbacks_ready())

func configure(admission) -> void:
	_configuration_serial+=1
	# Configuration changes terrain identity, not permission to replace old
	# gameplay owners. Only an explicit post-registry-reset completion opens it.
	_world_reset_release_requested=false
	_worker_polled_configuration=-1
	_worker.reset()
	_retire_all_scenes()
	_retire_all()
	_desired = {}
	_inflight = {}
	_failures = {}
	_admission = admission
	var state: Dictionary = admission.stats()
	_generation = int(state.generation)
	_seed = String(state.worldSeed)

func advance(observer_bounds: Rect2i = Rect2i(), allow_dispatch := false, budget_usec := 2500) -> Dictionary:
	if budget_usec<1 or budget_usec>4000: return {"status":"rejected","reason":"invalid_slice_budget"}
	if _advancing: return {"status":"rejected","reason":"reentrant_advance"}
	_advancing=true
	var started := Time.get_ticks_usec()
	if _admission != null and int(_admission.stats().generation) != _generation:
		configure(_admission)
	var configuration:=_configuration_serial
	allow_dispatch = allow_dispatch and not _world_reset_pending
	# Draining is independent of native/current-generation readiness. Retired
	# payloads were relinquished by prior calls before the worker starts disposal.
	if _submitted_scene_disposals.is_empty() and not _retired.is_empty() and _worker.retire_external_payload(_retired):
		_retired = {}
		_submitted_scene_disposals=_pending_scene_disposals
		_pending_scene_disposals={}
	var ready: Dictionary = {}
	if allow_dispatch and not _closing and _admission != null:
		ready = _refresh_demand(observer_bounds)
		_prune_unwanted(ready)
	_prune_invalid_scenes()
	_last_worker_status = _worker.poll()
	_worker_polled_configuration = _configuration_serial
	# The exclusively owned external batch has been accepted; idle with no
	# pending retirement proves its worker disposal/join completed, not merely
	# that scene nodes disappeared. Failed thread starts retain pending claims.
	if not _submitted_scene_disposals.is_empty() and not _last_worker_status.get("busy",true) and not _last_worker_status.get("retirementPending",true):
		_submitted_scene_disposals={}
	_collect(ready, allow_dispatch and not _closing)
	if not _inflight.is_empty() and bool(_last_worker_status.get("workerRunning",false)) \
			and _last_worker_status.get("workerKind") == "preparation":
		var progress: Dictionary = _last_worker_status.get("progress",{})
		if int(progress.get("elapsedUsec",0)) > PREPARATION_TIMEOUT_USEC:
			_failures[_inflight.region] = {"binding":_inflight.binding,"reason":"building_preparation_timeout"}
			_worker.cancel(int(_inflight.token))
			_inflight = {}
	_pump_scenes(ready,allow_dispatch and not _closing,started,budget_usec)
	if _world_reset_release_requested and world_reset_ready():
		_world_reset_pending = false
		_world_reset_release_requested = false
	if allow_dispatch and not _closing and configuration==_configuration_serial and _retired.is_empty() and _inflight.is_empty():
		_dispatch(ready,observer_bounds.get_center())
	_max_advance_usec = maxi(_max_advance_usec,Time.get_ticks_usec()-started)
	_advancing=false
	return stats()

func _refresh_demand(bounds: Rect2i) -> Dictionary:
	var desired := {}
	var ready := {}
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		_desired = desired
		return ready
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	if (high.x-low.x+1)*(high.y-low.y+1) > MAX_REGIONS:
		_desired = desired
		return ready
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var candidate: Dictionary = Field.candidate_for_region(_seed,region)
			if candidate.is_empty() or not Admission.declared_influence(candidate).intersects(bounds): continue
			var source: Dictionary = _admission.source_state(region)
			if source.get("status") in ["ready","prepared"]:
				# Refine conservative discovery against the actual accepted footprint.
				if not source.reservationCells.intersects(bounds): continue
				if not _current_binding(source.binding): continue
				ready[region] = source
				if source.status == "prepared" and not _prepared.has(region) and not _scenes.has(region) and not _region_retiring(region) and not _failures.has(region) \
						and (_inflight.is_empty() or _inflight.region != region):
					# Only a NEW approach without either source or prepared ownership
					# requests deterministic reconstruction after cache eviction.
					_admission.request_source(region,true)
			desired[region] = true
	_desired = desired
	return ready

func _current_binding(binding: Dictionary) -> bool:
	return int(binding.get("generation",-1)) == _generation \
		and String(_admission.stats().worldSeed) == _seed

func _prune_unwanted(ready: Dictionary) -> void:
	for region: Vector2i in _scenes.keys():
		if not ready.has(region) or ready[region].binding != _scenes[region].binding:
			_retire_scene(region)
	for region: Vector2i in _prepared.keys():
		if not ready.has(region) or ready[region].binding != _prepared[region].binding:
			_retire(_prepared[region])
			_prepared.erase(region)
	for region: Vector2i in _failures.keys():
		if not _desired.has(region) or ready.has(region) and ready[region].binding != _failures[region].binding:
			_failures.erase(region)
	if not _inflight.is_empty() and (not ready.has(_inflight.region) \
			or ready[_inflight.region].binding != _inflight.binding):
		_worker.cancel(int(_inflight.token))
		_inflight = {}

func _collect(ready: Dictionary, allow_accept: bool) -> void:
	if _inflight.is_empty() or not allow_accept: return
	var token := int(_inflight.token)
	if int(_last_worker_status.get("completedToken",0)) != token: return
	var region: Vector2i = _inflight.region
	# Read Admission again after join. A stale profile/source must never be
	# accepted just because its token completed successfully.
	var current: Dictionary = _admission.source_state(region)
	if not ready.has(region) or current.get("status") not in ["ready","prepared"] \
			or current.binding != _inflight.binding or not _current_binding(current.binding):
		_worker.cancel(token)
		_inflight = {}
		return
	var completion: Dictionary = _worker.take_result(token,current.binding)
	if completion.get("status") != "consumed": return
	var result: Dictionary = completion.get("result",{})
	if result.get("ready",false) and result.get("profile",{}).get("siteId") == current.binding.siteId \
			and result.profile.get("sourceSignature") == current.sourceSignature:
		_prepared[region] = {"binding":current.binding.duplicate(),"prepared":result.prepared,"profile":result.profile}
		_accepted_count += 1
	else:
		_failures[region] = {"binding":current.binding.duplicate(),"reason":String(result.get("reason","building_preparation_failed"))}
		if result.get("ready",false):
			_failures[region].reason = "stale_prepared_profile"
			_retire(result)
	_inflight = {}

func _dispatch(ready: Dictionary, observer: Vector2i) -> void:
	var regions: Array = ready.keys()
	regions.sort_custom(func(a,b):
		var ac: Vector2i = ready[a].reservationCells.get_center()
		var bc: Vector2i = ready[b].reservationCells.get_center()
		var ad := ac.distance_squared_to(observer)
		var bd := bc.distance_squared_to(observer)
		return ad<bd or ad==bd and (a.x<b.x or a.x==b.x and a.y<b.y))
	for region: Vector2i in regions:
		if _prepared.has(region) or _scenes.has(region) or _region_retiring(region) or _failures.has(region) or ready[region].status != "ready": continue
		var source: Dictionary = ready[region]
		var receipt: Dictionary = _worker.dispatch(source.source,source.binding)
		if receipt.get("status") in ["started","queued"]:
			_inflight = {"region":region,"binding":source.binding.duplicate(),"token":int(receipt.token)}
			_dispatch_count += 1
		# Busy/start failure is retryable. The demand is never removed here.
		return

func _retire(value: Dictionary) -> void:
	_retirement_serial += 1
	_retired[_retirement_serial] = value

func _retire_all() -> void:
	if not _prepared.is_empty(): _retire(_prepared)
	_prepared = {}

## Drain old scene callbacks before the ordinary owner replaces NPC registries.
## Configuration alone never opens the fence; the owner explicitly completes
## it after replacing its registries, with a fresh worker poll required too.
func begin_world_reset() -> void:
	if _closing or _world_reset_pending: return
	configure(_admission)
	_world_reset_pending = true

func complete_world_reset() -> void:
	if _world_reset_pending: _world_reset_release_requested = true

func requires_scene_retirement() -> bool:
	return not _scenes.is_empty() or _has_scene_retirements()

func world_reset_ready() -> bool:
	return _world_reset_pending and not requires_scene_retirement() and _retired.is_empty() \
		and _worker_polled_configuration == _configuration_serial \
		and not bool(_last_worker_status.get("busy",true)) and not bool(_last_worker_status.get("retirementPending",true))

func request_shutdown() -> void:
	_closing = true
	_retire_all_scenes()
	_desired = {}
	_inflight = {}
	_retire_all()
	_worker.request_shutdown()

func stats() -> Dictionary:
	var constructed := 0
	for entry in _scenes.values():
		if entry.phase=="scene_ready": constructed+=1
	return {"generation":_generation,"worldSeed":_seed,"desiredSites":_desired.size(),
		"worldResetPending":_world_reset_pending,"worldResetReady":world_reset_ready(),
		"preparedSites":_prepared.size(),"pendingRetirements":_retired.size(),
		"activeToken":_inflight.get("token",0),"failures":_failures.duplicate(true),
		"dispatchCount":_dispatch_count,"acceptedCount":_accepted_count,"maxAdvanceUsec":_max_advance_usec,
		"publicationReady":false,"worker":_last_worker_status,
		"doorLifecycleConfigured":_door_lifecycle_configured,"doorLifecycleAvailable":_door_callbacks_ready(),
		"constructionStatus":"available" if _scene_callbacks_ready() else "pending",
		"constructionReason":"" if _scene_callbacks_ready() else "scene_lifecycle_capability_missing",
		"publishingScenes":_scenes.size()-constructed,"constructedScenes":constructed,
		"retiringScenes":_retiring_scenes.size()+_pending_scene_disposals.size()+_submitted_scene_disposals.size(),
		"retiringSceneNodes":_retiring_scenes.size(),"retiringScenePayloads":_pending_scene_disposals.size()+_submitted_scene_disposals.size(),
		"sceneStartedCount":_scene_started_count,"sceneCompletedCount":_scene_completed_count,"sceneMaxStepUsec":_scene_max_step_usec,
		"shutdownComplete":_closing and _scenes.is_empty() and not _has_scene_retirements() and _retired.is_empty() and bool(_last_worker_status.get("shutdownComplete",false))}

func _has_scene_retirements() -> bool:
	return not _retiring_scenes.is_empty() or not _pending_scene_disposals.is_empty() or not _submitted_scene_disposals.is_empty()

func _region_retiring(region: Vector2i) -> bool:
	for entry in _retiring_scenes:
		if entry.region==region: return true
	return _pending_scene_disposals.values().has(region) or _submitted_scene_disposals.values().has(region)

func _retire_scene(region: Vector2i) -> void:
	if not _scenes.has(region): return
	var entry: Dictionary=_scenes[region]
	entry.job.cancel()
	entry.phase="retiring"
	_retiring_scenes.append(entry)
	_scenes.erase(region)

func _retire_all_scenes() -> void:
	for region: Vector2i in _scenes.keys(): _retire_scene(region)

func _prune_invalid_scenes() -> void:
	# Reset, source revision and parent loss must invalidate even on drain-only
	# calls. Ordinary pause does not pretend a missing demand sample is departure.
	for region: Vector2i in _scenes.keys():
		var entry: Dictionary=_scenes[region]
		var source: Dictionary=_admission.source_state(region) if _admission!=null else {}
		if source.get("binding",{})!=entry.binding or not _current_binding(entry.binding) or not _scene_callbacks_ready():
			_retire_scene(region)
			continue
		if entry.job.status_count().phase!="building_begin":
			var site: Node3D=entry.job.own_node_root()
			var parent: Node3D=_scene_parent.get_ref() as Node3D
			if not is_instance_valid(site) or site.is_queued_for_deletion() or not site.is_inside_tree() or site.get_parent()!=parent \
					or not site.global_transform.is_equal_approx(Transform3D(Basis.IDENTITY,entry.profile.origin)):
				_failures[region]={"binding":entry.binding,"reason":"constructed_scene_owner_lost" if entry.phase=="scene_ready" else "publication_scene_owner_lost"}
				_retire_scene(region)

func _start_scene(region: Vector2i, source: Dictionary) -> bool:
	if not _scene_callbacks_ready() or _scenes.has(region) or _region_retiring(region): return false
	var prepared: Dictionary=_prepared[region]
	# Bind against a fresh non-enqueuing lookup immediately before consumption.
	var current: Dictionary=_admission.source_state(region)
	if current.get("binding",{})!=prepared.binding or source.binding!=prepared.binding or not _current_binding(prepared.binding): return false
	var parent: Node3D=_scene_parent.get_ref() as Node3D
	var job=SceneJob.new()
	if not job.set_tree_retire_callback(Callable(_tree_retire_receiver.get_ref(),_tree_retire_method)): return false
	if _door_lifecycle_configured and not job.set_door_callbacks(Callable(_door_receiver.get_ref(),_door_method),Callable(_door_retire_receiver.get_ref(),_door_retire_method)): return false
	var result: Dictionary=job.begin(prepared.prepared,prepared.profile,prepared.binding,parent,Callable(_tree_receiver.get_ref(),_tree_method))
	if result.get("status")!="pending_budget":
		_failures[region]={"binding":prepared.binding,"reason":String(result.get("reason","scene_begin_failed"))}
		_retire(prepared); _prepared.erase(region)
		return false
	_scenes[region]={"region":region,"binding":prepared.binding,"profile":prepared.profile,"job":job,"phase":"publishing"}
	_prepared.erase(region)
	_scene_started_count+=1
	return true

func _pump_scenes(ready: Dictionary, allow_build: bool, started: int, budget_usec: int) -> void:
	# One shared budget, fair across building and retirement. No per-site budget
	# multiplication. Job.advance itself packs cheap work into its remaining slice.
	var units := 0
	var configuration:=_configuration_serial
	while units==0 or Time.get_ticks_usec()-started<budget_usec:
		if _closing or configuration!=_configuration_serial: allow_build=false
		var work_started:=Time.get_ticks_usec()
		var remaining:=maxi(1,budget_usec-int(work_started-started))
		var progressed:=false
		if not _retiring_scenes.is_empty() and (_prefer_retirement or not allow_build or not _has_scene_work(ready)):
			# Keep this owner visible during callbacks, including reentrant reset
			# or attempted root rebinding, until its current unit returns.
			var entry: Dictionary=_retiring_scenes[0]
			entry.job.advance(remaining)
			_retiring_scenes.pop_front()
			if entry.job.status().retirementReady:
				var payload: Dictionary=entry.job.take_retirement_payload()
				_retire({"scenePayload":payload,"sceneEntry":entry})
				_pending_scene_disposals[_retirement_serial]=entry.region
			else: _retiring_scenes.append(entry)
			progressed=true; _prefer_retirement=false
		elif allow_build and _scene_callbacks_ready():
			for region: Vector2i in _prepared.keys():
				if ready.has(region) and not _region_retiring(region) and not _failures.has(region):
					progressed=_start_scene(region,ready[region])
					break
			if not progressed:
				var regions: Array=_scenes.keys()
				for offset in range(regions.size()):
					var index:=(_scene_cursor+offset)%regions.size()
					var region: Vector2i=regions[index]
					var entry: Dictionary=_scenes[region]
					if entry.phase!="publishing" or not ready.has(region): continue
					_scene_cursor=(index+1)%regions.size()
					var result: Dictionary=entry.job.advance(remaining)
					if not is_same(_scenes.get(region),entry):
						# A callback invalidated/moved this owner. It cannot publish
						# readiness or a failure into its replacement generation.
						progressed=true
						break
					if result.status in ["failed","cancelled"]:
						_failures[region]={"binding":entry.binding,"reason":String(result.reason)}
						_retire_scene(region)
					elif result.sceneReady:
						entry.phase="scene_ready"
						_scene_completed_count+=1
					progressed=true
					break
			_prefer_retirement=true
		if not progressed: break
		units+=1
		_scene_max_step_usec=maxi(_scene_max_step_usec,Time.get_ticks_usec()-work_started)

func _has_scene_work(ready: Dictionary) -> bool:
	if not _scene_callbacks_ready(): return false
	for region: Vector2i in _prepared:
		if ready.has(region) and not _region_retiring(region) and not _failures.has(region): return true
	for region: Vector2i in _scenes:
		if ready.has(region) and _scenes[region].phase=="publishing": return true
	return false

func scene_state(region: Vector2i) -> Dictionary:
	if _scenes.has(region):
		var entry: Dictionary=_scenes[region]
		return {"status":entry.phase,"reason":"door_activation_pending" if entry.phase=="scene_ready" else "scene_publication_pending","binding":entry.binding.duplicate(),"gameplayReady":false}
	if _region_retiring(region): return {"status":"retiring","reason":"scene_retirement_pending","gameplayReady":false}
	if _failures.has(region): return {"status":"failed","reason":_failures[region].reason,"gameplayReady":false}
	if _prepared.has(region) or _desired.has(region): return {"status":"pending","reason":"scene_owner_not_ready" if not _scene_callbacks_ready() else "scene_preparation_pending","gameplayReady":false}
	return {"status":"absent","reason":"","gameplayReady":false}

func scene_root(region: Vector2i) -> Node3D:
	return _scenes[region].job.own_node_root() if _scenes.has(region) else null
