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

func configure(seed_text: String, providers: Dictionary = {}) -> void:
	# IDs never restart: a release from an old world cannot release its successor.
	_seed = seed_text
	_requests.clear()
	_providers.clear()
	for domain in REQUIRED_DOMAINS:
		var provider = providers.get(domain)
		if provider is Object and is_instance_valid(provider):
			_providers[domain] = weakref(provider)
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
	_requests[id] = {"bounds":bounds, "priority":priority, "reason":reason, "releaseAt":-1}
	_rebuild()
	return id

func release_region(request_id: int) -> void:
	if not _requests.has(request_id) or int(_requests[request_id].releaseAt) >= 0:
		return
	_requests[request_id].releaseAt = Time.get_ticks_msec() + RELEASE_HYSTERESIS_MS

func advance(now_ms := -1) -> void:
	var now := Time.get_ticks_msec() if now_ms < 0 else now_ms
	var changed := false
	for id in _requests.keys():
		var deadline := int(_requests[id].releaseAt)
		if deadline >= 0 and now >= deadline:
			_requests.erase(id)
			changed = true
	if changed: _rebuild()

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
	for domain in REQUIRED_DOMAINS:
		var provider = _providers[domain].get_ref() if _providers.has(domain) else null
		var state: Dictionary = {"status":"pending", "reason":"regional_owner_acknowledgement_unavailable"}
		if is_instance_valid(provider) and provider.has_method("region_publication_readiness"):
			state = provider.region_publication_readiness(bounds)
		result.domains[domain] = state
		result.sourceRevisions[domain] = state.get("sourceRevision", "")
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
		var bounds: Rect2i = _requests[id].bounds.grow(RENDER_CELL_SIZE)
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
