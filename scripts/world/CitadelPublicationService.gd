extends RefCounted
class_name CitadelPublicationService

## StructureSystem-owned ordinary streaming preparation. Scene publication is
## not enabled yet: a prepared holder is not a generated/ready city marker.
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
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

func configure(admission) -> void:
	_worker.reset()
	_retire_all()
	_desired = {}
	_inflight = {}
	_failures = {}
	_admission = admission
	var state: Dictionary = admission.stats()
	_generation = int(state.generation)
	_seed = String(state.worldSeed)

func advance(observer_bounds: Rect2i = Rect2i(), allow_dispatch := false) -> Dictionary:
	var started := Time.get_ticks_usec()
	if _admission != null and int(_admission.stats().generation) != _generation:
		configure(_admission)
	# Draining is independent of native/current-generation readiness. Retired
	# payloads were relinquished by prior calls before the worker starts disposal.
	if not _retired.is_empty() and _worker.retire_external_payload(_retired):
		_retired = {}
	var ready: Dictionary = {}
	if allow_dispatch and not _closing and _admission != null:
		ready = _refresh_demand(observer_bounds)
		_prune_unwanted(ready)
	_last_worker_status = _worker.poll()
	_collect(ready, allow_dispatch and not _closing)
	if not _inflight.is_empty() and bool(_last_worker_status.get("workerRunning",false)) \
			and _last_worker_status.get("workerKind") == "preparation":
		var progress: Dictionary = _last_worker_status.get("progress",{})
		if int(progress.get("elapsedUsec",0)) > PREPARATION_TIMEOUT_USEC:
			_failures[_inflight.region] = {"binding":_inflight.binding,"reason":"building_preparation_timeout"}
			_worker.cancel(int(_inflight.token))
			_inflight = {}
	if allow_dispatch and not _closing and _retired.is_empty() and _inflight.is_empty():
		_dispatch(ready,observer_bounds.get_center())
	_max_advance_usec = maxi(_max_advance_usec,Time.get_ticks_usec()-started)
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
				if source.status == "prepared" and not _prepared.has(region) and not _failures.has(region) \
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
		if _prepared.has(region) or _failures.has(region) or ready[region].status != "ready": continue
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

func request_shutdown() -> void:
	_closing = true
	_desired = {}
	_inflight = {}
	_retire_all()
	_worker.request_shutdown()

func stats() -> Dictionary:
	return {"generation":_generation,"worldSeed":_seed,"desiredSites":_desired.size(),
		"preparedSites":_prepared.size(),"pendingRetirements":_retired.size(),
		"activeToken":_inflight.get("token",0),"failures":_failures.duplicate(true),
		"dispatchCount":_dispatch_count,"acceptedCount":_accepted_count,"maxAdvanceUsec":_max_advance_usec,
		"publicationReady":false,"worker":_last_worker_status,
		"shutdownComplete":_closing and _retired.is_empty() and bool(_last_worker_status.get("shutdownComplete",false))}
