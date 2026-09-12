extends RefCounted
class_name WorldStreamingCoordinator

## Retained demand only. Geometry, collision and readiness remain at their owners.
## Bounds use half-open XZ terrain cells (1.35 metres each), not render/nav tiles.
const CELL := 1.35
const RENDER_CELL_SIZE := 32
const GAME_CHUNK_SIZE := 28
const PLAYABLE_RADIUS_METRES := 64.0
const MAX_REQUESTS := 64
const MAX_RETAINED_CHUNKS := 256
const RELEASE_HYSTERESIS_MS := 10000
const REQUIRED_DOMAINS := ["terrain", "structures", "navigation"]

var _seed := ""
var _next_id := 1
var _requests: Dictionary = {}
var _providers: Dictionary = {}
var _bounds: Array[Rect2i] = []
var _chunks: Dictionary = {}
var _revision := 0
var last_rejection := ""
var _refresh_cursor := 0
var _last_advance_frame := -1
var max_advance_usec := 0
var _navigation_turn := false

func configure(seed_text: String, providers: Dictionary = {}) -> void:
	# IDs never restart: a release from an old world cannot release its successor.
	for request in _requests.values(): _release_provider_requests(request)
	_seed = seed_text
	_requests.clear()
	_providers.clear()
	for domain in REQUIRED_DOMAINS:
		var provider = providers.get(domain)
		if provider is Object and is_instance_valid(provider):
			_providers[domain] = weakref(provider)
	_refresh_cursor = 0
	_last_advance_frame = -1
	_navigation_turn = false
	_rebuild()

func request_region(bounds: Rect2i, priority: int, reason: String) -> int:
	advance()
	last_rejection = ""
	if _seed.is_empty() or not valid_bounds(bounds) or reason.strip_edges().is_empty() or priority < 0 or priority > 4:
		last_rejection = "invalid_region_request"
		return 0
	if _requests.size() >= MAX_REQUESTS:
		last_rejection = "region_request_capacity"
		return 0
	var candidate := _chunks.duplicate()
	for key in chunks_for_bounds(bounds.grow(RENDER_CELL_SIZE)):
		candidate[key] = true
	if candidate.size() > MAX_RETAINED_CHUNKS:
		last_rejection = "region_resident_capacity"
		return 0
	var id := _next_id
	_next_id += 1
	_requests[id] = {"bounds":bounds, "closedBounds":bounds, "priority":priority,
		"reason":reason, "releaseAt":-1, "requirements":{}, "dependencyRevision":"",
		"providerRequests":{}, "closureStatus":"pending", "closureReason":"dependencies_pending"}
	_rebuild()
	return id

func release_region(request_id: int) -> void:
	if not _requests.has(request_id) or int(_requests[request_id].releaseAt) >= 0:
		return
	_requests[request_id].releaseAt = Time.get_ticks_msec() + RELEASE_HYSTERESIS_MS

func advance(now_ms := -1) -> void:
	var started := Time.get_ticks_usec()
	var now := Time.get_ticks_msec() if now_ms < 0 else now_ms
	var changed := false
	for id in _requests.keys():
		var deadline := int(_requests[id].releaseAt)
		if deadline >= 0 and now >= deadline:
			_release_provider_requests(_requests[id])
			_requests.erase(id)
			changed = true
	if changed: _rebuild()
	var frame := Engine.get_process_frames()
	if _last_advance_frame == frame: return
	_last_advance_frame = frame
	var navigation = _provider("navigation")
	_navigation_turn = not _navigation_turn
	if _navigation_turn and is_instance_valid(navigation) and navigation.has_method("advance"):
		# A source closure may exhaust the cooperative slice. Reserve alternating
		# frames for retained navigation so it cannot starve behind that work.
		navigation.advance(4000)
		max_advance_usec = maxi(max_advance_usec,Time.get_ticks_usec()-started)
		return
	# Resolve at most one source closure per frame. Providers advance their own
	# existing publication queues; they remain the only readiness authorities.
	var ids := _requests.keys()
	if not ids.is_empty():
		_refresh_cursor %= ids.size()
		_refresh_request(_requests[ids[_refresh_cursor]])
		_refresh_cursor += 1
	if is_instance_valid(navigation) and navigation.has_method("advance"):
		navigation.advance(maxi(0, 4000-(Time.get_ticks_usec()-started)))
	max_advance_usec = maxi(max_advance_usec,Time.get_ticks_usec()-started)

func _provider(domain: String):
	return _providers[domain].get_ref() if _providers.has(domain) else null

func _release_provider_requests(request: Dictionary) -> void:
	for domain in request.get("providerRequests",{}):
		var provider = _provider(domain)
		if is_instance_valid(provider) and provider.has_method("release_region"):
			provider.release_region(int(request.providerRequests[domain].id))
	request.get("providerRequests",{}).clear()

func _refresh_request(request: Dictionary) -> void:
	var structures = _provider("structures")
	if not is_instance_valid(structures) or not structures.has_method("region_dependency_requirements"):
		request.closureStatus = "pending"
		request.closureReason = "structure_dependency_owner_unavailable"
		return
	var revision := String(structures.region_dependency_revision(request.closedBounds)) if structures.has_method("region_dependency_revision") else ""
	if revision.is_empty() or revision != request.dependencyRevision or request.closureStatus != "ready":
		var requirements: Dictionary = structures.region_dependency_requirements(request.closedBounds)
		request.requirements = requirements
		request.dependencyRevision = revision
		if requirements.get("status") != "described":
			request.closureStatus = "failed" if requirements.get("status") == "failed" else "pending"
			request.closureReason = requirements.get("reason","structure_dependencies_pending")
			return
		if not requirements.get("missingSourceIds",[]).is_empty() or not requirements.get("unresolvedCrossingIds",[]).is_empty():
			request.closureStatus = "failed"
			request.closureReason = "structure_dependencies_unresolved"
			return
		var closed: Rect2i = request.closedBounds
		for bounds in requirements.get("dependencyBounds",[]):
			if not bounds is Rect2i or not valid_bounds(bounds):
				request.closureStatus = "failed"
				request.closureReason = "invalid_structure_dependency_bounds"
				return
			closed = closed.merge(bounds)
		if not valid_bounds(closed) or not _closure_fits(request,closed):
			request.closureStatus = "pending"
			request.closureReason = "region_dependency_capacity"
			return # Keep both the original demand and its last admitted closure.
		if closed != request.closedBounds:
			request.closedBounds = closed
			request.closureStatus = "pending"
			request.closureReason = "structure_dependency_closure_expanding"
			_rebuild()
			return # Recheck newly included sources next frame before acknowledging closure.
		request.closureStatus = "ready"
		request.closureReason = ""
	# Retry provider admission without dropping a previous retained request.
	for domain in REQUIRED_DOMAINS:
		var provider = _provider(domain)
		if not is_instance_valid(provider) or not provider.has_method("request_region"): continue
		var existing: Dictionary = request.providerRequests.get(domain,{})
		if existing.get("bounds") == request.closedBounds: continue
		var id := int(provider.request_region(request.closedBounds,request.priority,request.reason))
		if id <= 0: continue
		if not existing.is_empty(): provider.release_region(int(existing.id))
		request.providerRequests[domain] = {"id":id,"bounds":request.closedBounds}

func _closure_fits(request: Dictionary, bounds: Rect2i) -> bool:
	var keys := {}
	for other in _requests.values():
		var held: Rect2i = bounds if is_same(request,other) else other.closedBounds
		for key in chunks_for_bounds(held.grow(RENDER_CELL_SIZE)):
			keys[key] = true
			if keys.size() > MAX_RETAINED_CHUNKS: return false
	return true

func retained_cell_bounds() -> Array[Rect2i]:
	return _bounds.duplicate()

func retained_gameplay_chunks() -> Dictionary:
	return _chunks.duplicate()

func revision() -> int:
	return _revision

func region_readiness(bounds: Rect2i) -> Dictionary:
	if not valid_bounds(bounds):
		return {"status":"failed", "reason":"invalid_region_bounds", "missing":[], "sourceRevisions":{}}
	var result := {"status":"ready", "reason":"", "missing":[], "sourceRevisions":{}, "domains":{}}
	var request := {}
	for candidate in _requests.values():
		# Hysteresis retains real provider demand and its current receipts. Use a
		# completed overlapping closure during a camera/player demand transition.
		if candidate.bounds.encloses(bounds):
			if request.is_empty() or (candidate.closureStatus == "ready" and request.closureStatus != "ready") \
					or (candidate.closureStatus == request.closureStatus and candidate.bounds.get_area() < request.bounds.get_area()):
				request = candidate
	var closed: Rect2i = bounds if request.is_empty() else request.closedBounds
	if request.is_empty():
		result.status = "pending"
		result.missing.append({"domain":"demand","reason":"region_not_requested"})
	elif request.bounds != bounds:
		# Retained demand may be larger than a motion/readiness query. Close the
		# query over its own authoritative obligations, without making safe local
		# movement wait for unrelated pending tiles in the prediction ring.
		var structures = _provider("structures")
		var requirements: Dictionary = structures.region_dependency_requirements(bounds) \
			if is_instance_valid(structures) and structures.has_method("region_dependency_requirements") else {"status":"pending","reason":"structure_dependency_owner_unavailable"}
		closed = bounds
		result["requirements"] = requirements
		if requirements.get("status") != "described":
			result.status = "failed" if requirements.get("status") == "failed" else "pending"
			result.missing.append({"domain":"dependencies","reason":requirements.get("reason","structure_dependencies_pending")})
		else:
			for dependency in requirements.get("dependencyBounds",[]):
				if not dependency is Rect2i or not valid_bounds(dependency):
					result.status = "failed"
					result.missing.append({"domain":"dependencies","reason":"invalid_structure_dependency_bounds"})
					break
				closed = closed.merge(dependency)
			if not requirements.get("missingSourceIds",[]).is_empty() or not requirements.get("unresolvedCrossingIds",[]).is_empty():
				result.status = "failed"
				result.missing.append({"domain":"dependencies","reason":"structure_dependencies_unresolved"})
			if not request.closedBounds.encloses(closed):
				result.status = "pending" if result.status != "failed" else "failed"
				result.missing.append({"domain":"dependencies","reason":"local_dependency_demand_pending"})
	elif request.closureStatus != "ready":
		result.status = request.closureStatus
		result.missing.append({"domain":"dependencies","reason":request.closureReason})
	else:
		var structures = _provider("structures")
		if is_instance_valid(structures) and structures.has_method("region_dependency_revision") \
				and String(structures.region_dependency_revision(request.closedBounds)) != request.dependencyRevision:
			request.closureStatus = "pending"
			request.closureReason = "structure_dependency_revision_changed"
			result.status = "pending"
			result.missing.append({"domain":"dependencies","reason":request.closureReason})
		closed = request.closedBounds
		result["requirements"] = request.requirements
	result["bounds"] = bounds
	result["closedBounds"] = closed
	for domain in REQUIRED_DOMAINS:
		var provider = _provider(domain)
		var state: Dictionary = {"status":"pending", "reason":"regional_owner_acknowledgement_unavailable"}
		var admitted_bounds: Rect2i = request.get("providerRequests",{}).get(domain,{}).get("bounds",Rect2i())
		if is_instance_valid(provider) and provider.has_method("request_region") \
				and not admitted_bounds.encloses(closed):
			state.reason = "regional_provider_demand_pending"
		elif is_instance_valid(provider) and provider.has_method("region_publication_readiness"):
			state = provider.region_publication_readiness(closed)
		result.domains[domain] = state
		result.sourceRevisions[domain] = state.get("sourceRevisions",state.get("sourceRevision", ""))
		if state.get("status") != "ready":
			result.missing.append({"domain":domain,"reason":state.get("reason", "invalid_owner_result")})
			if state.get("status") == "failed": result.status = "failed"
			elif result.status != "failed": result.status = "pending"
	if not result.missing.is_empty(): result.reason = "regional_dependencies_incomplete"
	return result

func _rebuild() -> void:
	_bounds.clear()
	_chunks.clear()
	var ids := _requests.keys()
	ids.sort_custom(func(a: int, b: int):
		return _requests[a].priority < _requests[b].priority if _requests[a].priority != _requests[b].priority else a < b)
	for id in ids:
		var bounds: Rect2i = _requests[id].closedBounds.grow(RENDER_CELL_SIZE)
		if not _bounds.has(bounds): _bounds.append(bounds)
		for key in chunks_for_bounds(bounds): _chunks[key] = true
	_revision += 1

static func playable_bounds(position: Vector3) -> Rect2i:
	var low := Vector2i(floori((position.x-PLAYABLE_RADIUS_METRES)/CELL), floori((position.z-PLAYABLE_RADIUS_METRES)/CELL))
	var high := Vector2i(ceili((position.x+PLAYABLE_RADIUS_METRES)/CELL), ceili((position.z+PLAYABLE_RADIUS_METRES)/CELL))
	return Rect2i(low, high-low)

static func valid_bounds(bounds: Rect2i) -> bool:
	return bounds.size.x > 0 and bounds.size.y > 0 and bounds.size.x <= 512 and bounds.size.y <= 512 \
		and bounds.position.x >= -1000000+RENDER_CELL_SIZE and bounds.position.y >= -1000000+RENDER_CELL_SIZE \
		and bounds.position.x <= 1000000-bounds.size.x-RENDER_CELL_SIZE and bounds.position.y <= 1000000-bounds.size.y-RENDER_CELL_SIZE

static func chunks_for_bounds(bounds: Rect2i) -> Array[Vector2i]:
	var keys: Array[Vector2i] = []
	if bounds.size.x <= 0 or bounds.size.y <= 0: return keys
	var low := Vector2i(floori(float(bounds.position.x)/GAME_CHUNK_SIZE), floori(float(bounds.position.y)/GAME_CHUNK_SIZE))
	var high := Vector2i(floori(float(bounds.end.x-1)/GAME_CHUNK_SIZE), floori(float(bounds.end.y-1)/GAME_CHUNK_SIZE))
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1): keys.append(Vector2i(x,z))
	return keys
