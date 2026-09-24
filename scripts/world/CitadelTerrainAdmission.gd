extends RefCounted
class_name CitadelTerrainAdmission

## StructureSystem-owned source preparation and terrain admission. No scene or
## route authority. Every requested footprint is ready, pending, or failed;
## invalid generated sites are never converted into ordinary empty terrain.
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Site = preload("res://scripts/world/CitadelSitePreparation.gd")
const Queue = preload("res://scripts/world/CitadelSiteBuildQueue.gd")
const Store = preload("res://scripts/world/GeneratedSiteProfileStore.gd")
const MAX_REQUEST_REGIONS := 16
const MAX_RETAINED_SOURCES := 16
const MAX_PREFETCH_REGIONS := 2

var profile_store
var world_seed := ""
var _queue = Queue.new()
var _towns: Dictionary = {}
var _town_inputs_finalized := false
var _policy: Dictionary = {}
var _decisions: Dictionary = {}
var _candidates: Dictionary = {}
var _requests: Dictionary = {}
var _source_leases: Dictionary = {}
var _next_source_lease_id := 1
var _prefetch_regions: Array[Vector2i] = []
var _sources: Dictionary = {}
var _retired: Dictionary = {}
var _generation := 0
var _closing := false
var _fatal := ""
var _last_queue_status: Dictionary = {}
var _max_advance_usec := 0

func configure(seed_text: String, towns: Dictionary, ordinary_policy: Dictionary) -> void:
	for lease: Dictionary in _source_leases.values():
		if lease.state == "pending":
			lease.state = "draining" if int(lease.get("token", 0)) > 0 else "drained"
			lease.reason = "admission_generation_replaced"
		elif lease.state not in ["draining", "drained"]:
			lease.state = "invalidated"
			lease.reason = "admission_generation_replaced"
	_queue.reset()
	_update_draining_source_leases()
	if not _sources.is_empty(): _retired[_generation] = _sources
	_sources = {}
	_requests.clear()
	_prefetch_regions.clear()
	_decisions.clear()
	_candidates.clear()
	_generation += 1
	world_seed = seed_text
	_towns = towns.duplicate(true)
	_town_inputs_finalized = false
	_policy = ordinary_policy.duplicate(true)
	profile_store = Store.new(world_seed)
	_fatal = "" if not world_seed.is_empty() else "missing_world_seed"

func finalize_town_inputs(towns: Dictionary) -> Dictionary:
	# Scenario setup/restore may change town geometry after StructureSystem.setup.
	# Bind once at native generation construction, before any source request.
	if _town_inputs_finalized: return {"status":"ready","towns":_towns}
	if not _requests.is_empty() or not _decisions.is_empty():
		_fatal = "citadel_town_inputs_already_used"
		return _result("failed",_fatal)
	var canonical := Queue._canonical_request(world_seed,Vector2i.ZERO,towns,_policy)
	if canonical.is_empty():
		_fatal = "invalid_citadel_generation_town_inputs"
		return _result("failed",_fatal)
	_towns = canonical.towns
	_town_inputs_finalized = true
	return {"status":"ready","towns":_towns}

func finalized_town_inputs_snapshot() -> Dictionary:
	if not _town_inputs_finalized:
		return {"status":"failed", "reason":"citadel_town_inputs_unfinalized"}
	return {"status":"ready", "towns":_towns.duplicate(true),
		"generation":_generation, "worldSeed":world_seed}

func source_policy_snapshot() -> Dictionary:
	return _policy.duplicate(true)

static func declared_influence(candidate: Dictionary) -> Rect2i:
	return Rect2i(candidate.centerCell - Vector2i.ONE * Site.MAX_INFLUENCE_RADIUS_CELLS,
		Vector2i.ONE * (Site.MAX_INFLUENCE_RADIUS_CELLS * 2 + 1))

func request_bounds(bounds: Rect2i, priority := true) -> Dictionary:
	if _closing: return _result("failed", "shutting_down")
	if not _fatal.is_empty(): return _result("failed", _fatal)
	if not _town_inputs_finalized: return _result("failed", "citadel_town_inputs_unfinalized")
	if not _valid_bounds(bounds): return _result("failed", "unsupported_admission_bounds")
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end - Vector2i.ONE)
	if (high.x-low.x+1)*(high.y-low.y+1) > MAX_REQUEST_REGIONS:
		return _result("failed", "admission_region_limit")
	var waiting := false
	for z in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var region := Vector2i(x,z)
			if not _candidates.has(region): _candidates[region] = Field.candidate_for_region(world_seed,region)
			var candidate: Dictionary = _candidates[region]
			if candidate.is_empty() or not bounds.intersects(declared_influence(candidate)): continue
			var decision: Dictionary = _decisions.get(region, {})
			if decision.get("status") == "failed": return _result("failed", decision.reason)
			if decision.get("status") in ["prepared", "absent"]: continue
			waiting = true
			if not _requests.has(region):
				_requests[region] = _new_request(priority, true)
			else:
				_requests[region].prefetch = false
				_requests[region].drainingPrefetch = false
				_requests[region].legacyDemand = true
				if priority: _requests[region].priority = true
	return _result("pending" if waiting else "ready", "preparing_citadel_terrain" if waiting else "")

func request_source(region: Vector2i, priority := true) -> Dictionary:
	return _request_source(region, priority, true)

## Create a scoped consumer interest in one region. Unlike a bare source request,
## this lease may be released independently without shutting down shared admission.
func acquire_source_lease(region: Vector2i, priority := true) -> Dictionary:
	if _closing or not _fatal.is_empty() or not _town_inputs_finalized:
		return _result("failed", "admission_unavailable")
	if not Field._valid_region(region): return _result("failed", "invalid_source_region")
	var lease_id := _next_source_lease_id
	_next_source_lease_id += 1
	var lease := {"leaseId":lease_id, "generation":_generation, "region":region, "priority":priority,
		"state":"pending", "token":0, "reason":""}
	_source_leases[lease_id] = lease
	var existing: Dictionary = source_state(region)
	if existing.get("status") == "ready" or existing.get("status") == "prepared":
		lease.state = "ready"
	elif existing.get("status") == "failed" or (existing.get("status") == "absent"
			and existing.get("reason") != "source_not_requested"):
		lease.state = String(existing.status)
		lease.reason = String(existing.get("reason", ""))
	else:
		var request: Dictionary = _requests.get(region, {})
		if request.is_empty():
			request = _new_request(priority, false)
			_requests[region] = request
		else:
			request.priority = bool(request.priority) or priority
			request.prefetch = false
			request.drainingPrefetch = false
			if not request.has("legacyDemand"): request.legacyDemand = false
			if not request.has("leaseIds"): request.leaseIds = []
		request.leaseIds.append(lease_id)
		# A lease can attach after a legacy consumer already dispatched this
		# region. Preserve that exact token so generation replacement cannot
		# misclassify an active shared worker as a tokenless request.
		lease.token = int(request.get("receipt", {}).get("token", 0))
	return {"status":"ready", "leaseId":lease_id, "generation":_generation, "region":region,
		"state":lease.state}

func request_source_with_lease(lease_id: int) -> Dictionary:
	var lease: Dictionary = _source_leases.get(lease_id, {})
	if lease.is_empty(): return _result("failed", "source_lease_unknown")
	if lease.state in ["draining", "drained", "invalidated"]: return _result("failed", "source_lease_released")
	if lease.state in ["ready", "prepared", "absent", "failed", "invalidated"]:
		return source_state(lease.region)
	return _request_source(lease.region, bool(lease.priority), false)

## Releases only this consumer. Last-lease cancellation is cooperative: the lease
## remains draining until its queue token and any worker-owned retirement clear.
func release_source_lease(lease_id: int) -> Dictionary:
	var lease: Dictionary = _source_leases.get(lease_id, {})
	if lease.is_empty(): return _result("failed", "source_lease_unknown")
	if lease.state == "drained": return {"status":"ready", "state":"drained", "leaseId":lease_id}
	if int(lease.get("generation", -1)) != _generation:
		if lease.state == "draining" and _queue.source_request_state(int(lease.token)) != "absent":
			return {"status":"pending", "state":"draining", "leaseId":lease_id,
				"token":lease.token, "reason":lease.reason}
		lease.state = "drained"
		return {"status":"ready", "state":"drained", "leaseId":lease_id,
			"reason":lease.reason}
	if lease.state == "invalidated":
		lease.state = "drained"
		return {"status":"ready", "state":"drained", "leaseId":lease_id,
			"reason":lease.reason}
	if lease.state in ["ready", "prepared", "absent", "failed"]:
		# The lease owns demand, not the immutable decision/result payload. Once
		# terminal, admission owns any pending receipt retirement independently;
		# this consumer may drain without waiting on shared admission cleanup.
		lease.state = "drained"
		return {"status":"ready", "state":"drained", "leaseId":lease_id}
	var region: Vector2i = lease.region
	var request: Dictionary = _requests.get(region, {})
	if not request.is_empty():
		request.leaseIds.erase(lease_id)
		if not request.legacyDemand and request.leaseIds.is_empty():
			_requests.erase(region)
			var token := int(request.get("receipt", {}).get("token", 0))
			if token <= 0:
				lease.state = "drained"
				return {"status":"ready", "state":"drained", "leaseId":lease_id}
			var before := _queue.source_request_state(token)
			if before == "pending":
				var cancelled: Dictionary = _queue.cancel_with_status(token)
				lease.state = "drained" if cancelled.get("accepted", false) else "draining"
			elif before == "active":
				_queue.cancel_with_status(token)
				lease.state = "draining"
			elif before in ["completed", "retirement_pending"]:
				_queue.cancel_with_status(token)
				lease.state = "draining"
			else:
				lease.state = "drained"
			lease.token = token
			return {"status":"pending" if lease.state == "draining" else "ready",
				"state":lease.state, "leaseId":lease_id, "token":token,
				"workerState":before}
	lease.state = "drained"
	return {"status":"ready", "state":"drained", "leaseId":lease_id}

func source_lease_state(lease_id: int) -> Dictionary:
	var lease: Dictionary = _source_leases.get(lease_id, {})
	if lease.is_empty(): return _result("failed", "source_lease_unknown")
	if lease.state == "draining" and _queue.source_request_state(int(lease.token)) == "absent":
		lease.state = "drained"
	return {"status":"pending" if lease.state in ["pending", "draining"] else "ready",
		"state":lease.state, "leaseId":lease_id, "generation":lease.generation, "region":lease.region,
		"token":lease.token, "reason":lease.reason}

func forget_source_lease(lease_id: int) -> bool:
	var lease: Dictionary = _source_leases.get(lease_id, {})
	if lease.is_empty() or lease.state != "drained": return false
	_source_leases.erase(lease_id)
	return true

func _request_source(region: Vector2i, priority: bool, legacy: bool) -> Dictionary:
	if _closing: return _result("failed","shutting_down")
	if not _fatal.is_empty(): return _result("failed",_fatal)
	if not _town_inputs_finalized: return _result("failed","citadel_town_inputs_unfinalized")
	if _sources.has(region):
		return source_state(region)
	var decision: Dictionary = _decisions.get(region,{})
	if decision.get("status") in ["failed","absent"]: return decision.duplicate()
	if not _requests.has(region): _requests[region] = _new_request(priority, legacy)
	else:
		_requests[region].prefetch = false
		_requests[region].drainingPrefetch = false
		_requests[region].legacyDemand = bool(_requests[region].get("legacyDemand", false)) or legacy
		if priority: _requests[region].priority = true
	return _result("pending","preparing_citadel_source")


## Scheduling-only lookahead. A real bounds/source request atomically promotes
## the same region and can no longer be cancelled by a camera reversal.
func set_prefetch_regions(regions: Array[Vector2i]) -> bool:
	if _closing or not _fatal.is_empty() or not _town_inputs_finalized \
			or regions.size()>MAX_PREFETCH_REGIONS: return false
	var ordered: Array[Vector2i] = []
	for region: Vector2i in regions:
		if not Field._valid_region(region) or ordered.has(region): return false
		ordered.append(region)
	ordered.sort_custom(func(a: Vector2i,b: Vector2i): return a.y<b.y if a.y!=b.y else a.x<b.x)
	for region: Vector2i in _prefetch_regions:
		if ordered.has(region): continue
		var request: Dictionary = _requests.get(region,{})
		if request.get("prefetch",false):
			var token := int(request.get("receipt",{}).get("token",0))
			# Once an immutable source is running, preserve it across a view reversal.
			# Cancelling then resubmitting the same multi-second build turns camera
			# priority churn into CPU contention and gameplay frame spikes. Pending
			# (not yet running) prefetch remains disposable, so a new urgent source is
			# never queued behind obsolete work that has not begun.
			if token>0 and _queue.is_active_token(token):
				request.drainingPrefetch = true
				continue
			_requests.erase(region)
			if token>0: _queue.cancel(token)
	for region: Vector2i in ordered:
		if _decisions.get(region,{}).get("status") in ["prepared","absent","failed"]: continue
		if not _requests.has(region):
			_requests[region]=_new_request(false, false)
			_requests[region].prefetch = true
		else: _requests[region].drainingPrefetch = false
	_prefetch_regions=ordered
	return true

func source_state(region: Vector2i) -> Dictionary:
	# Non-enqueuing identity lookup: an existing prepared consumer must not
	# rebuild the recipe just because the reconstructible source cache evicted it.
	if _closing: return _result("failed","shutting_down")
	if not _fatal.is_empty(): return _result("failed",_fatal)
	if not _town_inputs_finalized: return _result("failed","citadel_town_inputs_unfinalized")
	var decision: Dictionary = _decisions.get(region,{})
	if decision.is_empty(): return _result("absent","source_not_requested")
	if decision.get("status") != "prepared": return decision.duplicate()
	var result := {"status":"prepared", "binding":{"siteId":decision.siteId,
		"sourceKey":decision.sourceKey, "generation":_generation},
		"sourceSignature":decision.sourceSignature, "reservationCells":decision.reservationCells}
	if _sources.has(region):
		result.status = "ready"
		result["source"] = _sources[region]
	return result

func advance() -> Dictionary:
	var started := Time.get_ticks_usec()
	# Do not dispatch new sources until old generation payloads can be disposed
	# by the queue's existing worker-owned retirement path.
	if not _retired.is_empty():
		var retirement_tokens: Array[int] = []
		for key: Variant in _retired:
			var text := str(key)
			if text.begins_with("stale:") or text.begins_with("result:"):
				var parsed := text.get_slice(":", 1).to_int()
				if parsed > 0: retirement_tokens.append(parsed)
		if _queue.retire_external_payload(_retired, retirement_tokens): _retired = {}
	_last_queue_status = _queue.poll()
	var token := int(_last_queue_status.get("completedToken",0))
	if token != 0:
		var receipt: Dictionary = _queue.take_result(token)
		_accept(receipt)
	# The existing source watchdog allows 450 s. Runtime has the same per-worker
	# ceiling, separate from terrain collision's existing 120 s readiness timer.
	var progress: Dictionary = _last_queue_status.get("progress",{})
	if _last_queue_status.get("workerKind") == "source" and int(progress.get("elapsedUsec",0)) > 450000000:
		_fatal = "citadel_source_preparation_timeout"
		_queue.cancel(int(_last_queue_status.get("activeToken",0)))
	if not _closing and _town_inputs_finalized and _fatal.is_empty() and _retired.is_empty():
		var regions: Array = _requests.keys()
		regions.sort_custom(func(a,b):return a.x<b.x or a.x==b.x and a.y<b.y)
		for region: Vector2i in regions:
			var request: Dictionary = _requests[region]
			if not request.receipt.is_empty(): continue
			var receipt: Dictionary = _queue.submit(world_seed,region,_towns,_policy,request.priority)
			if receipt.get("reason") == "queue_full": break # Retain the demand.
			if receipt.get("status") not in ["queued","duplicate"]:
				_fail(region, String(receipt.get("reason","site_dispatch_failed")))
				continue
			request.receipt = receipt
			for lease_id: int in request.get("leaseIds", []):
				if _source_leases.has(lease_id): _source_leases[lease_id].token = int(receipt.get("token", 0))
	_update_draining_source_leases()
	_max_advance_usec = maxi(_max_advance_usec,Time.get_ticks_usec()-started)
	return stats()

## Passive worker-side source timing. Readiness and source queries never use it.
func source_timing() -> Dictionary:
	return _queue.source_timing()

func _accept(receipt: Dictionary) -> void:
	if receipt.get("status") != "consumed": return
	var matched: Variant = null
	for region: Vector2i in _requests:
		var expected: Dictionary = _requests[region].receipt
		if expected.get("token") == receipt.get("token") and expected.get("epoch") == receipt.get("epoch") and expected.get("sourceKey") == receipt.get("sourceKey"):
			matched = region
			break
	if matched == null:
		# Receipts from a retired generation cannot affect its successor.
		_retired["stale:%s" % receipt.get("token",0)] = receipt
		return
	var region: Vector2i = matched
	var source: Dictionary = receipt.get("result", {})
	var state := String(source.get("status", "failed"))
	if state == "prepared":
		var expected := Field.candidate_for_region(world_seed, region)
		var profile: Dictionary = source.get("profile",{})
		var manifest: Dictionary = source.get("manifest",{})
		if not source.is_read_only() or source.get("candidate") != expected or not manifest.get("ready",false) \
				or profile.get("worldSeed") != world_seed or profile.get("siteId") != expected.get("siteId") \
				or profile.get("sourceSignature") != manifest.get("sourceSignature") \
				or not source.get("reservationCells") is Rect2i \
				or not declared_influence(expected).encloses(source.reservationCells) \
				or not Field.reservation_fits_region(region,source.reservationCells):
			_fail(region,"invalid_prepared_site_receipt")
		elif not _admit_or_reuse_profile(region,receipt,profile):
			_fail(region,"generated_site_profile_admission_failed")
		else:
			if _sources.size() >= MAX_RETAINED_SOURCES:
				# Geometry is reconstructible; terrain facts remain admitted for the
				# session. A later approach requests the identical source again.
				var oldest: Vector2i = _sources.keys()[0]
				_retired["evicted:%s" % oldest] = _sources[oldest]
				_sources.erase(oldest)
			_sources[region] = source
			_decisions[region] = {"status":"prepared","reason":"","sourceKey":receipt.sourceKey,
				"sourceSignature":profile.sourceSignature,"siteId":profile.siteId,"reservationCells":source.reservationCells,
				"level":profile.level,"envelopeCells":profile.envelopeCells,"apronCells":profile.apronCells}
			_resolve_source_leases(region, "ready", "", int(receipt.get("token", 0)))
			_requests.erase(region)
			return
	elif state == "absent":
		if _decisions.get(region,{}).get("status") == "prepared":
			# Eviction only discards reconstructible geometry, never admitted terrain.
			# A contradictory rebuild must stop publication, not erase the site.
			_fail(region,"prepared_site_rebuild_became_absent")
		else:
			_decisions[region] = {"status":"absent","reason":source.get("reason",""),"sourceKey":receipt.sourceKey}
			_resolve_source_leases(region, "absent", String(source.get("reason", "")), int(receipt.get("token", 0)))
			_requests.erase(region)
	else:
		_fail(region,String(source.get("reason","site_preparation_failed")), int(receipt.get("token", 0)))
	_retired["result:%s" % receipt.token] = receipt

func _admit_or_reuse_profile(region: Vector2i, receipt: Dictionary, profile: Dictionary) -> bool:
	var previous: Dictionary = _decisions.get(region,{})
	if previous.get("status") == "prepared":
		# A rebuild uses the exact canonical seed/town/policy source key. Its
		# deterministic mask still derives from the same signed geometry and apron.
		return previous.sourceKey == receipt.sourceKey and previous.sourceSignature == profile.sourceSignature \
			and previous.level == profile.level and previous.envelopeCells == profile.envelopeCells and previous.apronCells == profile.apronCells
	return profile_store.append_prepared_profile(profile)

func _fail(region: Vector2i, reason: String, token := 0) -> void:
	_decisions[region] = {"status":"failed","reason":reason}
	_resolve_source_leases(region, "failed", reason, token)
	_requests.erase(region)

func _resolve_source_leases(region: Vector2i, state: String, reason: String, token: int) -> void:
	var request: Dictionary = _requests.get(region, {})
	for lease_id: int in request.get("leaseIds", []):
		if not _source_leases.has(lease_id): continue
		var lease: Dictionary = _source_leases[lease_id]
		if lease.state != "draining":
			lease.state = state
			lease.reason = reason
			lease.token = token

func _update_draining_source_leases() -> void:
	for lease: Dictionary in _source_leases.values():
		if lease.state == "draining" and _queue.source_request_state(int(lease.token)) == "absent":
			lease.state = "drained"

func _new_request(priority: bool, legacy: bool) -> Dictionary:
	return {"priority":priority,"receipt":{},"prefetch":false,"drainingPrefetch":false,
		"legacyDemand":legacy,"leaseIds":[]}

func prepared_sources() -> Dictionary:
	# Immutable worker values; only the small registry shell is copied.
	return _sources.duplicate()

func request_shutdown() -> void:
	_closing = true
	_queue.request_shutdown()
	_requests.clear()
	_prefetch_regions.clear()
	if not _sources.is_empty(): _retired[_generation] = _sources
	_sources = {}

func stats() -> Dictionary:
	return {"generation":_generation,"worldSeed":world_seed,"pendingRegions":_requests.size(),
		"prefetchRegions":_prefetch_regions.duplicate(),"prefetchPending":_prefetch_pending_count(),
		"drainingPrefetch":_draining_prefetch_count(),
		"preparedSites":_sources.size(),"decidedRegions":_decisions.size(),"failure":_fatal,
		"retiredGenerations":_retired.size(),"maxAdvanceUsec":_max_advance_usec,
		"shutdownComplete":_closing and _retired.is_empty() and bool(_last_queue_status.get("shutdownComplete",false)),
		"queue":_last_queue_status}

static func _valid_bounds(bounds: Rect2i) -> bool:
	return bounds.size.x > 0 and bounds.size.y > 0 and absi(bounds.position.x)<=1000000 and absi(bounds.position.y)<=1000000 \
		and int(bounds.position.x)+int(bounds.size.x)<=1000000 and int(bounds.position.y)+int(bounds.size.y)<=1000000


func _prefetch_pending_count() -> int:
	var count := 0
	for request: Dictionary in _requests.values():
		if bool(request.get("prefetch",false)): count += 1
	return count

func _draining_prefetch_count() -> int:
	var count := 0
	for request: Dictionary in _requests.values():
		if bool(request.get("drainingPrefetch",false)): count += 1
	return count

static func _result(state: String, reason: String) -> Dictionary:
	return {"status":state,"reason":reason}
