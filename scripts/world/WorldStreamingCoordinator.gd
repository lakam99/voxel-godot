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
const MAX_RETAINED_NAVIGATION_TILES := 512
const MAX_SOURCE_BINDINGS := 16
const MAX_SOURCE_GROUPS := 30000
const RELEASE_HYSTERESIS_MS := 10000
const MAX_EXPIRY_TRANSACTIONS_PER_FRAME := 1
const SOURCE_SNAPSHOT_SLICE_USEC := 750
const SOURCE_SNAPSHOT_UNIT_CAP := 96
const FOREGROUND_PRIORITY := 0
const REQUIRED_DOMAINS := ["terrain", "structures", "navigation"]
const RETAINED_DOMAINS := ["terrain", "render", "navigation", "discovery"]
const DemandSet = preload("res://scripts/world/RegionDemandSet.gd")
const ViewPriority = preload("res://scripts/world/GeneratedContentViewPriority.gd")

var _seed := ""
var _next_id := 1
var _configuration := 0
var _requests: Dictionary = {}
var _providers: Dictionary = {}
var _bounds: Array[Rect2i] = []
var _chunks: Dictionary = {}
var _revision := 0
var _view_revision := 0
var last_rejection := ""
var _refresh_cursor := 0
var _expiry_cursor := 0
var _last_advance_frame := -1
var max_advance_usec := 0
var _navigation_turn := false
var _source_compile_generation := 0
var _source_manifest_revision := 0
var _source_snapshot_dirty := true
var _source_compile_job: Dictionary = {}
var _retained_source_snapshot: Array[Dictionary] = []
var _retained_source_snapshot_identity := PackedByteArray()
var _source_compile_metrics := {"ownerUnits":0,"admissionUnits":0,"navigationUnits":0,
	"bindingUnits":0,"groupUnits":0,"phase":"idle","restarts":0}

func configure(seed_text: String, providers: Dictionary = {}) -> void:
	# IDs never restart: a release from an old world cannot release its successor.
	for request in _requests.values(): _release_provider_requests(request)
	_configuration += 1
	_seed = seed_text
	_requests.clear()
	_providers.clear()
	for domain in REQUIRED_DOMAINS:
		var provider = providers.get(domain)
		if provider is Object and is_instance_valid(provider):
			_providers[domain] = weakref(provider)
	_refresh_cursor = 0
	_expiry_cursor = 0
	_last_advance_frame = -1
	_navigation_turn = false
	_source_compile_generation += 1
	_source_snapshot_dirty = true
	_source_compile_job = {}
	var had_source_snapshot:=not _retained_source_snapshot.is_empty()
	_retained_source_snapshot = []
	var empty_hasher:=HashingContext.new()
	empty_hasher.start(HashingContext.HASH_SHA256)
	_retained_source_snapshot_identity=empty_hasher.finish()
	if had_source_snapshot: _source_manifest_revision += 1
	_view_revision += 1
	_rebuild()

## `foreground_navigation_tiles` is the immediate player-safety capsule. It
## remains a subset of retained navigation demand, while structure publication
## receives it separately from the wider background retention.
func request_region(bounds: Rect2i, priority: int, reason: String, foreground_navigation_tiles: Array = [],
		foreground_bounds := Rect2i(), member_hysteresis_ms := RELEASE_HYSTERESIS_MS,
		peripheral_margin_cells := RENDER_CELL_SIZE) -> int:
	last_rejection = ""
	if not _valid_intent(bounds,priority,reason) or member_hysteresis_ms<0 or member_hysteresis_ms>RELEASE_HYSTERESIS_MS \
			or peripheral_margin_cells<0 or peripheral_margin_cells>RENDER_CELL_SIZE:
		last_rejection = "invalid_region_request"
		return 0
	if _requests.size() >= MAX_REQUESTS:
		last_rejection = "region_request_capacity"
		return 0
	var base: Dictionary = _compile_sets({},bounds,peripheral_margin_cells)
	if base.status != "ready":
		last_rejection = "region_resident_capacity"
		return 0
	var foreground: Dictionary = _foreground_navigation_tiles(foreground_navigation_tiles,base.sets.navigation.keys)
	if foreground.status != "ready":
		last_rejection = foreground.reason
		return 0
	var request: Dictionary = {"id":_next_id,"configuration":_configuration,
		"sequence":1,"admittedSequence":0,"bounds":bounds,"closedBounds":bounds,
		"priority":priority,"reason":reason,"releaseAt":-1,"requirements":{},
		"dependencyRevision":null,"sets":base.sets,"members":{},"sourceMembers":{},
		"providerRequests":{},"foregroundNavigationTiles":foreground.keys,"foregroundBounds":foreground_bounds,"viewIntent":{},
		"memberHysteresisMs":member_hysteresis_ms,
		"peripheralMarginCells":peripheral_margin_cells,
		"closureStatus":"pending","closureReason":"dependencies_pending"}
	request = _stage_members(request,base.sets,{},Time.get_ticks_msec())
	if not _retention_fits(0,request):
		last_rejection = "region_resident_capacity"
		return 0
	var id: int = _next_id
	_next_id += 1
	# Initial base demand is pending even if another consumer already owns ready
	# geometry. Its own asynchronous closure must acquire its provider handle.
	_requests[id] = request
	_rebuild()
	return id

func replace_region(id: int, bounds: Rect2i, priority: int, reason: String, foreground_navigation_tiles: Array = [],
		foreground_bounds := Rect2i(), member_hysteresis_ms := RELEASE_HYSTERESIS_MS,
		peripheral_margin_cells := RENDER_CELL_SIZE) -> bool:
	last_rejection = ""
	if not _requests.has(id) or not _valid_intent(bounds,priority,reason) \
			or member_hysteresis_ms<0 or member_hysteresis_ms>RELEASE_HYSTERESIS_MS \
			or peripheral_margin_cells<0 or peripheral_margin_cells>RENDER_CELL_SIZE:
		last_rejection = "invalid_region_request"
		return false
	var request: Dictionary = _requests[id]
	var base: Dictionary = _compile_sets({},bounds,peripheral_margin_cells)
	if base.status != "ready":
		last_rejection = "region_resident_capacity"
		return false
	# A same-bounds replacement may choose any current dependency tile, including
	# a retained structure-navigation tile outside the raw player rectangle.
	# Do not admit a historical tile: `sets` is the current compiled closure.
	var retained_navigation: Dictionary = request.get("sets",{}).get("navigation",{}).get("keys",{}) if request.bounds==bounds else base.sets.navigation.keys
	var foreground: Dictionary = _foreground_navigation_tiles(foreground_navigation_tiles,retained_navigation)
	if foreground.status != "ready":
		last_rejection = foreground.reason
		return false
	if request.bounds==bounds and request.priority==priority and request.reason==reason \
			and request.get("foregroundNavigationTiles",{})==foreground.keys and request.get("foregroundBounds",Rect2i())==foreground_bounds and int(request.releaseAt)<0:
		if int(request.get("peripheralMarginCells",RENDER_CELL_SIZE))==peripheral_margin_cells: return true
	var candidate: Dictionary = request.duplicate()
	candidate.bounds = bounds
	candidate.priority = priority
	candidate.reason = reason
	candidate.releaseAt = -1
	candidate.sequence = int(request.sequence)+1
	candidate.closedBounds = bounds
	candidate.requirements = {}
	candidate.dependencyRevision = null
	candidate.closureStatus = "pending"
	candidate.closureReason = "dependencies_pending"
	candidate.foregroundNavigationTiles = foreground.keys
	candidate.foregroundBounds = foreground_bounds
	candidate.memberHysteresisMs = member_hysteresis_ms
	candidate.peripheralMarginCells = peripheral_margin_cells
	candidate.erase("pendingCandidate")
	candidate = _stage_members(candidate,base.sets,{},Time.get_ticks_msec())
	if not _retention_fits(id,candidate):
		last_rejection = "region_resident_capacity"
		return false
	# The provider changes the existing handle before local state commits. A
	# rejected replacement leaves current bounds, deadlines and readiness intact.
	if not _admit_navigation(candidate):
		last_rejection = "regional_provider_demand_pending"
		return false
	_commit_request(request,candidate)
	return true

func _valid_intent(bounds: Rect2i, priority: int, reason: String) -> bool:
	return not _seed.is_empty() and valid_bounds(bounds) and not reason.strip_edges().is_empty() and priority>=0 and priority<=4

static func _foreground_navigation_tiles(values: Variant, retained: Dictionary) -> Dictionary:
	if not values is Array: return {"status":"failed","reason":"invalid_foreground_navigation_tiles"}
	var keys: Dictionary = {}
	for value in values:
		if not value is Vector2i or not retained.has(value):
			return {"status":"failed","reason":"foreground_navigation_tile_not_retained"}
		keys[value] = true
	return {"status":"ready","keys":keys}

func release_region(request_id: int) -> void:
	if not _requests.has(request_id) or int(_requests[request_id].releaseAt) >= 0:
		return
	_requests[request_id].releaseAt = Time.get_ticks_msec() + RELEASE_HYSTERESIS_MS
	_rebuild(false)

func advance(now_ms := -1, budget_usec := 4000) -> void:
	var started := Time.get_ticks_usec()
	var structures = _provider("structures")
	var monitor = structures.performance_monitor() if is_instance_valid(structures) and structures.has_method("performance_monitor") else null
	var now: int = Time.get_ticks_msec() if now_ms < 0 else now_ms
	var changed := false
	var source_manifest_changed := false
	var expiry_ids: Array = _requests.keys()
	expiry_ids.sort()
	if not expiry_ids.is_empty(): _expiry_cursor %= expiry_ids.size()
	var expiry_attempts := 0
	for offset in range(expiry_ids.size()):
		if expiry_attempts>=MAX_EXPIRY_TRANSACTIONS_PER_FRAME: break
		var index: int = (_expiry_cursor+offset)%expiry_ids.size()
		var id: int = expiry_ids[index]
		if not _requests.has(id): continue
		var request: Dictionary = _requests[id]
		var deadline: int = int(request.releaseAt)
		if deadline >= 0 and now >= deadline:
			expiry_attempts += 1
			_expiry_cursor = index+1
			var release_started := Time.get_ticks_usec()
			_release_provider_requests(request)
			if monitor != null: monitor.observe_duration("streaming_expiry_release",float(Time.get_ticks_usec()-release_started)/1000.0)
			_requests.erase(id)
			changed = true
			source_manifest_changed = true
			break
		var expiry_started := Time.get_ticks_usec()
		var candidate: Dictionary = _expire_members(request,now)
		if monitor != null: monitor.observe_duration("streaming_expiry_members",float(Time.get_ticks_usec()-expiry_started)/1000.0)
		if candidate.is_empty(): continue
		expiry_attempts += 1
		_expiry_cursor = index+1
		# Even expiry is a provider transaction. Failed pruning keeps the exact
		# old retention and original deadlines so the next advance retries.
		# Source-group and terrain/render history commonly expire without changing
		# navigation ownership. Preserve the existing provider handles in that case;
		# replacing the same tile set would perform a full priority/capacity pass for
		# no publication change.
		var navigation_changed := _held_keys(request,"navigation")!=_held_keys(candidate,"navigation")
		if navigation_changed:
			var expiry_admission_started := Time.get_ticks_usec()
			var expiry_admitted := _admit_navigation(candidate)
			if monitor != null: monitor.observe_duration("streaming_expiry_navigation_admission",float(Time.get_ticks_usec()-expiry_admission_started)/1000.0)
			if not expiry_admitted: break
		source_manifest_changed = bool(candidate.get("_sourceManifestChanged",false))
		candidate.erase("_sourceManifestChanged")
		request.clear()
		request.merge(candidate)
		changed = true
		break
	if changed: _rebuild(source_manifest_changed)
	var frame := Engine.get_process_frames()
	if _last_advance_frame == frame: return
	_last_advance_frame = frame
	var navigation = _provider("navigation")
	var frame_budget_usec := maxi(0, budget_usec)
	# A newly forecast player capsule must acquire its provider handles before
	# the player reaches it. The ordinary audit cursor can contain dozens of
	# retained actor requests, so service one pending foreground admission ahead
	# of that backlog. Physical publication remains asynchronous and is still
	# validated by region_readiness at the movement boundary.
	var foreground_pending := _pending_foreground_request()
	if not foreground_pending.is_empty():
		_refresh_request(foreground_pending)
		if frame_budget_usec > Time.get_ticks_usec()-started and is_instance_valid(navigation) and navigation.has_method("advance"):
			navigation.advance(maxi(0,frame_budget_usec-(Time.get_ticks_usec()-started)))
		max_advance_usec = maxi(max_advance_usec,Time.get_ticks_usec()-started)
		return
	_navigation_turn = not _navigation_turn
	if _navigation_turn and frame_budget_usec > Time.get_ticks_usec()-started and is_instance_valid(navigation) and navigation.has_method("advance"):
		navigation.advance(maxi(0,frame_budget_usec-(Time.get_ticks_usec()-started)))
		max_advance_usec = maxi(max_advance_usec,Time.get_ticks_usec()-started)
		return
	var ids: Array = _requests.keys()
	if not ids.is_empty():
		_refresh_cursor %= ids.size()
		var request: Dictionary = _requests[ids[_refresh_cursor]]
		if int(request.releaseAt)<0: _refresh_request(request)
		_refresh_cursor += 1
	if frame_budget_usec > Time.get_ticks_usec()-started and is_instance_valid(navigation) and navigation.has_method("advance"):
		navigation.advance(maxi(0,frame_budget_usec-(Time.get_ticks_usec()-started)))
	max_advance_usec = maxi(max_advance_usec,Time.get_ticks_usec()-started)

func _pending_foreground_request() -> Dictionary:
	var ids: Array = _requests.keys()
	ids.sort()
	for id: int in ids:
		var request: Dictionary = _requests[id]
		if int(request.get("releaseAt",-1))>=0 or int(request.get("priority",-1))!=FOREGROUND_PRIORITY:
			continue
		if String(request.get("closureStatus","pending"))=="failed":
			continue
		if int(request.get("admittedSequence",0))==int(request.get("sequence",0)) \
				and String(request.get("closureStatus","pending"))=="ready":
			continue
		return request
	return {}

func _provider(domain: String):
	return _providers[domain].get_ref() if _providers.has(domain) else null

func _release_provider_requests(request: Dictionary) -> void:
	for domain in request.get("providerRequests",{}):
		var provider = _provider("navigation" if domain=="navigationBackground" else domain)
		if is_instance_valid(provider) and provider.has_method("release_region"):
			provider.release_region(int(request.providerRequests[domain].id))
	request.get("providerRequests",{}).clear()

func _request_current(request: Dictionary) -> bool:
	return int(request.get("configuration",-1))==_configuration and _requests.has(request.get("id",0)) \
		and is_same(_requests[request.id],request) and int(request.releaseAt)<0

func _source_revision(structures, bounds: Rect2i) -> Variant:
	if not structures.has_method("region_dependency_revision"): return null
	var value: Variant = structures.region_dependency_revision(bounds)
	return value.duplicate(true) if value is Array or value is Dictionary else value

func _scheduling_source_revision(structures, bounds: Rect2i) -> Variant:
	var method := "region_dependency_scheduling_revision" if structures.has_method("region_dependency_scheduling_revision") else "region_dependency_revision"
	if not structures.has_method(method): return null
	var value: Variant = structures.call(method,bounds)
	return value.duplicate(true) if value is Array or value is Dictionary else value

func _candidate_identity(request: Dictionary, revision: Variant, foreground_revision: Variant = null) -> Dictionary:
	return {"configuration":_configuration,"sequence":request.sequence,"bounds":request.bounds,
		"priority":request.priority,"foregroundBounds":request.get("foregroundBounds",Rect2i()),
		"foregroundNavigationTileKeys":_string_keys(request.get("foregroundNavigationTiles",{})),
		"revision":revision,"foregroundRevision":foreground_revision}

func _refresh_request(request: Dictionary) -> void:
	if not _request_current(request): return
	var structures = _provider("structures")
	if not is_instance_valid(structures) or not structures.has_method("region_dependency_requirements"):
		request.closureStatus = "pending"
		request.closureReason = "structure_dependency_owner_unavailable"
		return
	var monitor = structures.performance_monitor() if structures.has_method("performance_monitor") else null
	# Only the original query discovers sources. Closure geometry is retained in
	# domain sets, never fed back into exploration or source admission.
	var revision_started := Time.get_ticks_usec()
	var revision: Variant = _scheduling_source_revision(structures,request.bounds)
	if monitor != null: monitor.observe_duration("streaming_refresh_revision",float(Time.get_ticks_usec()-revision_started)/1000.0)
	if revision != null and revision==request.dependencyRevision and request.closureStatus=="ready" \
			and int(request.admittedSequence)==int(request.sequence): return
	var foreground_bounds: Rect2i = request.get("foregroundBounds",Rect2i())
	var foreground_revision: Variant = _scheduling_source_revision(structures,foreground_bounds) if foreground_bounds.has_area() else null
	var identity: Dictionary = _candidate_identity(request,revision,foreground_revision)
	var pending: Dictionary = request.get("pendingCandidate",{})
	if revision==null or (foreground_bounds.has_area() and foreground_revision==null) or pending.get("identity",{})!=identity:
		request.erase("pendingCandidate")
		var requirements_started := Time.get_ticks_usec()
		var described: Dictionary = structures.region_dependency_requirements(request.bounds)
		var foreground_described: Dictionary = structures.region_dependency_requirements(foreground_bounds) if foreground_bounds.has_area() else {}
		if monitor != null: monitor.observe_duration("streaming_refresh_requirements",float(Time.get_ticks_usec()-requirements_started)/1000.0)
		if not _request_current(request) or identity!=_candidate_identity(request,_scheduling_source_revision(structures,request.bounds),
				_scheduling_source_revision(structures,foreground_bounds) if foreground_bounds.has_area() else null): return
		if described.get("status") != "described":
			request.closureStatus = "failed" if described.get("status")=="failed" else "pending"
			request.closureReason = described.get("reason","structure_dependencies_pending")
			return
		if not described.get("missingSourceIds",[]).is_empty() or not described.get("unresolvedCrossingIds",[]).is_empty():
			request.closureStatus = "failed"
			request.closureReason = "structure_dependencies_unresolved"
			return
		var compile_started := Time.get_ticks_usec()
		var built: Dictionary = _compile_sets(described,request.bounds,int(request.get("peripheralMarginCells",RENDER_CELL_SIZE)))
		if monitor != null: monitor.observe_duration("streaming_refresh_compile",float(Time.get_ticks_usec()-compile_started)/1000.0)
		if built.status != "ready":
			request.closureStatus = built.status
			request.closureReason = built.reason
			return
		var foreground: Dictionary = _foreground_navigation_tiles(request.get("foregroundNavigationTiles",{}).keys(),built.sets.navigation.keys)
		if foreground.status != "ready":
			request.closureStatus = "failed"
			request.closureReason = foreground.reason
			return
		var foreground_sets: Dictionary = built.sets
		if foreground_bounds.has_area():
			if foreground_described.get("status") != "described":
				request.closureStatus = "failed" if foreground_described.get("status")=="failed" else "pending"
				request.closureReason = foreground_described.get("reason","foreground_structure_dependencies_pending")
				return
			if not foreground_described.get("missingSourceIds",[]).is_empty() or not foreground_described.get("unresolvedCrossingIds",[]).is_empty():
				request.closureStatus = "failed"
				request.closureReason = "foreground_structure_dependencies_unresolved"
				return
			var foreground_built: Dictionary = _compile_sets(foreground_described,foreground_bounds,int(request.get("peripheralMarginCells",RENDER_CELL_SIZE)))
			if foreground_built.status != "ready":
				request.closureStatus = foreground_built.status
				request.closureReason = foreground_built.reason
				return
			foreground_sets = foreground_built.sets
			if not DemandSet.contains(built.sets.navigation.keys,foreground_sets.navigation.keys):
				request.closureStatus = "failed"
				request.closureReason = "foreground_navigation_not_retained"
				return
		var sites: Dictionary = _source_members(described.get("sites",[]))
		if sites.status != "ready":
			request.closureStatus = sites.status
			request.closureReason = sites.reason
			return
		var foreground_sites: Dictionary = {"status":"ready","members":{}}
		if foreground_bounds.has_area():
			foreground_sites = _source_members(foreground_described.get("sites",[]))
			if foreground_sites.status != "ready":
				request.closureStatus = foreground_sites.status
				request.closureReason = foreground_sites.reason
				return
		pending = {"identity":identity,"requirements":described,"compiled":built,"foregroundSets":foreground_sets,
			"sites":sites.members,"foregroundSites":foreground_sites.members}
		request.pendingCandidate = pending
	var stage_started := Time.get_ticks_usec()
	var candidate: Dictionary = _stage_members(request,pending.compiled.sets,pending.sites,Time.get_ticks_msec())
	if monitor != null: monitor.observe_duration("streaming_refresh_stage",float(Time.get_ticks_usec()-stage_started)/1000.0)
	# A foreground request is the capsule's complete declared dependency closure,
	# not merely its raw tile footprint.  Set it before provider admission so the
	# urgent handle and Citadel packet demand share exactly this work set.
	if foreground_bounds.has_area(): candidate.foregroundNavigationTiles = pending.foregroundSets.navigation.keys
	candidate.foregroundSourceMembers = pending.foregroundSites
	if not _source_members_fit(candidate.sourceMembers) or not _retention_fits(int(request.id),candidate):
		request.closureStatus = "pending"
		request.closureReason = "region_dependency_capacity"
		return
	var admission_started := Time.get_ticks_usec()
	var navigation_admitted := _admit_navigation(candidate)
	if monitor != null: monitor.observe_duration("streaming_refresh_navigation_admission",float(Time.get_ticks_usec()-admission_started)/1000.0)
	if not navigation_admitted:
		request.closureStatus = "pending"
		request.closureReason = "regional_provider_demand_pending"
		return
	candidate.requirements = pending.requirements
	candidate.dependencyRevision = revision
	candidate.admittedSequence = request.sequence
	candidate.closedBounds = _envelope(candidate.sets.terrain.regions,request.bounds) # Presentation only.
	candidate.closureStatus = "ready"
	candidate.closureReason = ""
	candidate.erase("pendingCandidate")
	_commit_request(request,candidate)

func _commit_request(request: Dictionary, candidate: Dictionary) -> void:
	request.clear()
	request.merge(candidate)
	_rebuild()

func _stage_members(request: Dictionary, current_sets: Dictionary, current_sites: Dictionary, now: int) -> Dictionary:
	var candidate: Dictionary = request.duplicate()
	var hysteresis_ms: int = int(candidate.get("memberHysteresisMs",RELEASE_HYSTERESIS_MS))
	candidate.sets = current_sets
	candidate.members = {}
	for domain: String in RETAINED_DOMAINS:
		var current: Dictionary = {}
		if domain=="discovery":
			# Source discovery keeps its established perimeter for landmark
			# admission. It is ownership metadata, not a request to load terrain
			# collision or prop presentation around every actor.
			for key: Vector2i in chunks_for_bounds(candidate.bounds.grow(RENDER_CELL_SIZE)):
				current[key] = true
		else: current = current_sets[domain].keys
		candidate.members[domain] = _transition_members(request.get("members",{}).get(domain,{}),current,now,hysteresis_ms)
	candidate.sourceMembers = _transition_sources(request.get("sourceMembers",{}),current_sites,now,hysteresis_ms)
	candidate.nextExpiryAt = _earliest_expiry(candidate)
	candidate.providerRequests = request.get("providerRequests",{}).duplicate()
	return candidate

static func _transition_members(previous: Dictionary, current: Dictionary, now: int,
		hysteresis_ms := RELEASE_HYSTERESIS_MS) -> Dictionary:
	var result: Dictionary = previous.duplicate()
	for key in previous:
		if int(previous[key])<0 and not current.has(key):
			if hysteresis_ms<=0: result.erase(key)
			else: result[key] = now+hysteresis_ms
	for key in current: result[key] = -1
	return result

static func _held_keys(request: Dictionary, domain: String) -> Dictionary:
	var result: Dictionary = {}
	for key: Vector2i in request.get("members",{}).get(domain,{}): result[key] = true
	return result

func _admit_navigation(candidate: Dictionary) -> bool:
	var provider = _provider("navigation")
	if not is_instance_valid(provider) or not provider.has_method("request_tiles") or not provider.has_method("replace_tiles"): return false
	var selected: Dictionary = _held_keys(candidate,"navigation")
	var foreground: Dictionary = candidate.get("foregroundNavigationTiles",{}).duplicate()
	if not DemandSet.contains(selected,foreground): return false
	# The foreground handle is intentionally separate. Regional publication takes
	# the minimum priority of every retained request for a tile, so retaining the
	# wider closure on this handle would quietly promote all background tiles.
	var background: Dictionary = {}
	if not foreground.is_empty():
		background = selected.duplicate()
		for key: Vector2i in foreground: background.erase(key)
	var foreground_priority: int = candidate.priority
	var background_priority: int = maxi(candidate.priority,2)
	var primary_keys: Dictionary = foreground if not foreground.is_empty() else selected
	var primary_priority: int = foreground_priority if not foreground.is_empty() else candidate.priority
	var existing: Dictionary = candidate.providerRequests.get("navigation",{})
	var existing_background: Dictionary = candidate.providerRequests.get("navigationBackground",{})
	# Acquire a new background handle before narrowing the primary handle. A
	# rejected provider capacity admission therefore preserves the live urgent
	# request rather than leaving the capsule without its current ownership.
	if not background.is_empty() and int(existing_background.get("id",0))<=0:
		var background_id: int = int(provider.request_tiles(_string_keys(background),background_priority,candidate.reason+":background"))
		if background_id<=0: return false
		existing_background = {"id":background_id,"keys":background,"priority":background_priority,"reason":candidate.reason+":background"}
	if existing.get("keys",{})!=primary_keys or existing.get("priority",-1)!=primary_priority \
			or existing.get("reason","")!=candidate.reason:
		var id: int = int(existing.get("id",0))
		if id>0:
			if not provider.replace_tiles(id,_string_keys(primary_keys),primary_priority,candidate.reason):
				if int(existing_background.get("id",0))>0 and not candidate.providerRequests.has("navigationBackground"):
					provider.release_region(int(existing_background.id))
				return false
		else:
			id = int(provider.request_tiles(_string_keys(primary_keys),primary_priority,candidate.reason))
			if id<=0:
				if int(existing_background.get("id",0))>0 and not candidate.providerRequests.has("navigationBackground"):
					provider.release_region(int(existing_background.id))
				return false
		existing = {"id":id,"keys":primary_keys,"priority":primary_priority,"reason":candidate.reason}
	if background.is_empty():
		if int(existing_background.get("id",0))>0: provider.release_region(int(existing_background.id))
		candidate.providerRequests.erase("navigationBackground")
	else:
		if existing_background.get("keys",{})!=background or existing_background.get("priority",-1)!=background_priority \
				or existing_background.get("reason","")!=candidate.reason+":background":
			if not provider.replace_tiles(int(existing_background.id),_string_keys(background),background_priority,candidate.reason+":background"): return false
			existing_background = {"id":int(existing_background.id),"keys":background,"priority":background_priority,"reason":candidate.reason+":background"}
		candidate.providerRequests.navigationBackground = existing_background
	candidate.providerRequests.navigation = existing
	return true

func _retention_fits(replaced_id: int, candidate: Dictionary) -> bool:
	var chunks: Dictionary = {}
	var tiles: Dictionary = {}
	var requests: Array = _requests.values()
	if replaced_id==0: requests.append(candidate)
	for request: Dictionary in requests:
		var selected: Dictionary = candidate if int(request.id)==replaced_id else request
		for domain: String in ["terrain","render","discovery"]:
			for key: Vector2i in selected.members[domain]:
				chunks[key] = true
				if chunks.size()>MAX_RETAINED_CHUNKS: return false
		for key: Vector2i in selected.members.navigation:
			tiles[key] = true
			if tiles.size()>MAX_RETAINED_NAVIGATION_TILES: return false
	return true

static func _source_members(sites: Variant) -> Dictionary:
	if not sites is Array: return {"status":"failed","reason":"invalid_source_retention"}
	var result: Dictionary = {}
	for site in sites:
		if not site is Dictionary: return {"status":"failed","reason":"invalid_source_retention"}
		if not site.has("groupIds"): continue
		if not site.get("binding") is Dictionary or not site.get("groupIds") is Array:
			return {"status":"failed","reason":"invalid_source_retention"}
		var binding: Dictionary = site.binding
		if binding.size()!=3 or not binding.get("siteId") is String or binding.siteId.is_empty() \
				or not binding.get("sourceKey") is String or binding.sourceKey.is_empty() \
				or not binding.get("generation") is int or int(binding.generation)<=0:
			return {"status":"failed","reason":"invalid_source_retention"}
		# An encoded tuple keeps revisions distinct without hash collisions or
		# ambiguous separators in source IDs.
		var key: String = var_to_str([binding.siteId,binding.sourceKey,binding.generation])
		if not result.has(key): result[key] = {"binding":binding.duplicate(),"expiresAt":-1,"groups":{},"groupIds":[]}
		for id in site.groupIds:
			if not id is String or id.is_empty(): return {"status":"failed","reason":"invalid_source_retention"}
			if not result[key].groups.has(id): result[key].groupIds.append(id)
			result[key].groups[id] = -1
	if not _source_members_fit(result): return {"status":"pending","reason":"region_source_capacity"}
	return {"status":"ready","members":result}

static func _source_members_fit(members: Dictionary) -> bool:
	if members.size()>MAX_SOURCE_BINDINGS: return false
	var count: int = 0
	for site: Dictionary in members.values():
		count += site.groups.size()
		if count>MAX_SOURCE_GROUPS: return false
	return true

static func _transition_sources(previous: Dictionary, current: Dictionary, now: int,
		hysteresis_ms := RELEASE_HYSTERESIS_MS) -> Dictionary:
	var result: Dictionary = {}
	for key: String in previous:
		var old: Dictionary = previous[key]
		var next: Dictionary = current.get(key,{})
		var deadline: int = int(old.expiresAt)
		if not next.is_empty(): deadline = -1
		elif deadline<0: deadline = now+hysteresis_ms if hysteresis_ms>0 else now
		var groups: Dictionary=_transition_members(old.groups,next.get("groups",{}),now,hysteresis_ms)
		var ordered: Array[String]=[]
		var ordered_seen: Dictionary={}
		var old_order: Array=old.groupIds if old.has("groupIds") else old.groups.keys()
		for id: String in old_order:
			if groups.has(id): ordered.append(id); ordered_seen[id]=true
		var next_order: Array=next.groupIds if next.has("groupIds") else next.get("groups",{}).keys()
		for id: String in next_order:
			if groups.has(id) and not ordered_seen.has(id): ordered.append(id); ordered_seen[id]=true
		result[key] = {"binding":old.binding,"expiresAt":deadline,"groups":groups,"groupIds":ordered}
	for key: String in current:
		if not result.has(key):
			var current_order: Array=current[key].groupIds if current[key].has("groupIds") else current[key].groups.keys()
			result[key] = {"binding":current[key].binding,"expiresAt":-1,"groups":current[key].groups.duplicate(),
				"groupIds":current_order.duplicate()}
	return result

static func _earliest_expiry(request: Dictionary) -> int:
	var earliest: int = -1
	for members: Dictionary in request.members.values():
		for deadline: int in members.values():
			if deadline>=0 and (earliest<0 or deadline<earliest): earliest = deadline
	for site: Dictionary in request.sourceMembers.values():
		var deadline: int = int(site.expiresAt)
		if deadline>=0 and (earliest<0 or deadline<earliest): earliest = deadline
		for group_deadline: int in site.groups.values():
			if group_deadline>=0 and (earliest<0 or group_deadline<earliest): earliest = group_deadline
	return earliest

func _expire_members(request: Dictionary, now: int) -> Dictionary:
	if int(request.get("nextExpiryAt",-1))<0 or now<int(request.nextExpiryAt): return {}
	var candidate: Dictionary = request.duplicate()
	candidate.members = {}
	var changed: bool = false
	var source_manifest_changed := false
	for domain: String in RETAINED_DOMAINS:
		var retained: Dictionary = request.members[domain].duplicate()
		for key in retained.keys():
			if int(retained[key])>=0 and now>=int(retained[key]):
				retained.erase(key)
				changed = true
				if domain=="discovery" or domain=="navigation": source_manifest_changed = true
		candidate.members[domain] = retained
	candidate.sourceMembers = {}
	for key: String in request.sourceMembers:
		var site: Dictionary = request.sourceMembers[key]
		var groups: Dictionary = site.groups.duplicate()
		for id: String in groups.keys():
			if int(groups[id])>=0 and now>=int(groups[id]):
				groups.erase(id)
				changed = true
				source_manifest_changed = true
		if int(site.expiresAt)>=0 and now>=int(site.expiresAt) and groups.is_empty():
			changed = true
			source_manifest_changed = true
			continue
		var ordered_groups: Array[String]=[]
		var site_order: Array=site.groupIds if site.has("groupIds") else groups.keys()
		for id: String in site_order:
			if groups.has(id): ordered_groups.append(id)
		candidate.sourceMembers[key] = {"binding":site.binding,"expiresAt":site.expiresAt,
			"groups":groups,"groupIds":ordered_groups}
	if not changed: return {}
	candidate.nextExpiryAt = _earliest_expiry(candidate)
	candidate.providerRequests = request.providerRequests.duplicate()
	candidate["_sourceManifestChanged"] = source_manifest_changed
	return candidate

func _compile_sets(requirements: Dictionary, bounds: Rect2i, peripheral_margin_cells := RENDER_CELL_SIZE) -> Dictionary:
	var domains: Dictionary = requirements.get("domainBounds",{})
	var result: Dictionary = {}
	for domain: String in ["terrain","render","navigation"]:
		var regions: Array = domains.get(domain,requirements.get("dependencyBounds",[])).duplicate()
		regions.append(bounds)
		if domain=="navigation":
			# Declared crossings are indivisible publication obligations. A local
			# owner tile may name an adjacent endpoint outside the query capsule;
			# retain that exact sparse peer without expanding source discovery or
			# filling the envelope between them.
			var crossings: Variant=requirements.get("requiredCrossings",{})
			if not crossings is Dictionary:
				return {"status":"failed","reason":"invalid_navigation_crossing_closure"}
			var crossing_tiles: Dictionary={}
			for crossing_id: String in crossings:
				var crossing: Variant=crossings[crossing_id]
				if not crossing is Dictionary or crossing.get("sourceId")!=crossing_id \
						or not crossing.get("tileKeys") is Array:
					return {"status":"failed","reason":"invalid_navigation_crossing_closure"}
				for tile_key_value: Variant in crossing.tileKeys:
					if not tile_key_value is String:
						return {"status":"failed","reason":"invalid_navigation_crossing_tile"}
					var tile_key: String=tile_key_value
					var coordinates:=tile_key.split(",")
					if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int():
						return {"status":"failed","reason":"invalid_navigation_crossing_tile"}
					var tile:=Vector2i(int(coordinates[0]),int(coordinates[1]))
					if tile_key!="%d,%d" % [tile.x,tile.y]:
						return {"status":"failed","reason":"invalid_navigation_crossing_tile"}
					crossing_tiles[tile]=true
			var ordered_crossing_tiles: Array=crossing_tiles.keys()
			ordered_crossing_tiles.sort_custom(func(a: Vector2i,b: Vector2i):return a.y<b.y if a.y!=b.y else a.x<b.x)
			for tile: Vector2i in ordered_crossing_tiles:
				regions.append(Rect2i(tile*16,Vector2i.ONE*16))
		var step: int = 16 if domain=="navigation" else GAME_CHUNK_SIZE
		var limit: int = 512 if domain=="navigation" else MAX_RETAINED_CHUNKS
		var compiled: Dictionary = DemandSet.from_regions(regions,step,limit,peripheral_margin_cells if domain=="render" else 0)
		if compiled.status != "ready": return compiled
		result[domain] = compiled
	return {"status":"ready","sets":result}

static func _string_keys(keys: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for key: Vector2i in keys: result.append("%d,%d" % [key.x,key.y])
	result.sort()
	return result

static func _envelope(regions: Array, initial: Rect2i) -> Rect2i:
	var result: Rect2i = initial
	for bounds: Rect2i in regions: result = result.merge(bounds)
	return result

func retained_cell_bounds() -> Array[Rect2i]:
	return _bounds.duplicate()

func source_manifest_revision() -> int:
	return _source_manifest_revision

func source_snapshot_ready() -> bool:
	return not _source_snapshot_dirty

func source_snapshot_compile_metrics() -> Dictionary:
	return _source_compile_metrics.duplicate(true)

## Internal immutable borrow. The coordinator never mutates a completed array;
## callers that retain it see that revision even after a later atomic swap.
func borrow_retained_source_snapshot() -> Array[Dictionary]:
	return _retained_source_snapshot

func retained_source_requests() -> Array[Dictionary]:
	while not advance_retained_source_snapshot(1000000,2147483647): pass
	return _retained_source_snapshot.duplicate(true)

func advance_retained_source_snapshot(budget_usec := SOURCE_SNAPSHOT_SLICE_USEC,
		unit_cap := SOURCE_SNAPSHOT_UNIT_CAP) -> bool:
	if not _source_snapshot_dirty: return true
	if _source_compile_job.is_empty() or int(_source_compile_job.get("generation",-1))!=_source_compile_generation:
		if not _source_compile_job.is_empty(): _source_compile_metrics.restarts += 1
		var ids: Array = _requests.keys()
		ids.sort()
		var hasher:=HashingContext.new()
		hasher.start(HashingContext.HASH_SHA256)
		_source_compile_job = {"generation":_source_compile_generation,"ids":ids,"ownerIndex":0,
			"phase":"owner","result":[],"current":{},"keys":[],"index":0,"siteKeys":[],"siteIndex":0,
			"groupKeys":[],"groupHeapIndex":-1,"foregroundGroupKeys":[],"foregroundGroupHeapIndex":-1,
			"hasher":hasher}
	var started := Time.get_ticks_usec()
	var units := 0
	while units<maxi(1,unit_cap) and Time.get_ticks_usec()-started<maxi(1,budget_usec):
		if int(_source_compile_job.generation)!=_source_compile_generation: return false
		if _advance_source_snapshot_unit():
			var completed: Array[Dictionary] = []
			completed.assign(_source_compile_job.result)
			completed.make_read_only()
			var identity: PackedByteArray = _source_compile_job.hasher.finish()
			if identity!=_retained_source_snapshot_identity:
				_retained_source_snapshot = completed
				_retained_source_snapshot_identity = identity
				_source_manifest_revision += 1
			_source_compile_job = {}
			_source_snapshot_dirty = false
			_source_compile_metrics.phase = "ready"
			return true
		units += 1
	return false

func _advance_source_snapshot_unit() -> bool:
	var job := _source_compile_job
	_source_compile_metrics.phase = job.phase
	if job.phase=="owner":
		if int(job.ownerIndex)>=job.ids.size(): return true
		var id: int = int(job.ids[job.ownerIndex])
		var request: Dictionary = _requests.get(id,{})
		if request.is_empty():
			_source_compile_generation += 1
			return false
		job.current = {"ownerId":id,"bounds":request.bounds,"priority":request.priority,
			"admissionKeys":[],"navigationTileKeys":[],"navigationTilePriorities":{},"sites":[]}
		_source_snapshot_hash(job,["owner",id,request.bounds,request.priority])
		job.keys = request.members.discovery.keys()
		job.keys.sort_custom(func(a: Vector2i,b: Vector2i): return a.y<b.y if a.y!=b.y else a.x<b.x)
		job.index = 0
		job.phase = "admission"
		_source_compile_metrics.ownerUnits += 1
		return false
	if job.phase=="admission":
		if int(job.index)<job.keys.size():
			job.current.admissionKeys.append(job.keys[job.index]); job.index += 1
			_source_snapshot_hash(job,["admission",job.current.admissionKeys.back()])
			_source_compile_metrics.admissionUnits += 1
			return false
		var request: Dictionary = _requests[int(job.ids[job.ownerIndex])]
		job.keys = _held_keys(request,"navigation").keys()
		job.keys.sort_custom(func(a: Vector2i,b: Vector2i): return a.y<b.y if a.y!=b.y else a.x<b.x)
		job.index = 0; job.phase = "navigation"
		return false
	if job.phase=="navigation":
		if int(job.index)<job.keys.size():
			var request: Dictionary = _requests[int(job.ids[job.ownerIndex])]
			var key: Vector2i = job.keys[job.index]
			var text := "%d,%d" % [key.x,key.y]
			var background: Dictionary = request.get("providerRequests",{}).get("navigationBackground",{})
			var priority := int(background.get("priority",request.priority)) if background.get("keys",{}).has(key) else int(request.priority)
			job.current.navigationTileKeys.append(text)
			job.current.navigationTilePriorities[text] = priority
			job.index += 1; _source_compile_metrics.navigationUnits += 1
			return false
		job.current.navigationTileKeys.sort()
		job.index=0; job.phase="navigation_hash"
		return false
	if job.phase=="navigation_hash":
		if int(job.index)<job.current.navigationTileKeys.size():
			var text: String=job.current.navigationTileKeys[job.index]
			_source_snapshot_hash(job,["navigation",text,job.current.navigationTilePriorities[text]])
			job.index+=1; return false
		var request: Dictionary = _requests[int(job.ids[job.ownerIndex])]
		job.siteKeys = request.sourceMembers.keys()
		job.siteKeys.sort()
		job.siteIndex = 0; job.phase = "site"
		return false
	if job.phase=="site":
		if int(job.siteIndex)>=job.siteKeys.size():
			job.current.admissionKeys.make_read_only()
			job.current.navigationTileKeys.make_read_only()
			job.current.navigationTilePriorities.make_read_only()
			job.current.sites.make_read_only()
			job.current.make_read_only()
			job.result.append(job.current)
			job.ownerIndex += 1; job.phase = "owner"
			return false
		var request: Dictionary = _requests[int(job.ids[job.ownerIndex])]
		var site: Dictionary = request.sourceMembers[job.siteKeys[job.siteIndex]]
		job.currentSite = {"binding":site.binding.duplicate(),"groupIds":[]}
		_source_snapshot_hash(job,["binding",job.currentSite.binding])
		job.groupKeys = site.groupIds
		job.groupIndex = 0
		var foreground_key: String = var_to_str([site.binding.siteId,site.binding.sourceKey,site.binding.generation])
		var foreground_site: Dictionary = request.get("foregroundSourceMembers",{}).get(foreground_key,{})
		job.foregroundGroupKeys = foreground_site.get("groupIds",[])
		job.foregroundGroupIndex = 0
		if not foreground_site.is_empty(): job.currentSite["foregroundGroupIds"] = []
		var foreground: Array[String] = _string_keys(request.get("foregroundNavigationTiles",{}))
		if not foreground.is_empty(): job.currentSite["foregroundNavigationTileKeys"] = foreground
		_source_snapshot_hash(job,["foregroundNavigation",foreground,"hasForeground",not foreground_site.is_empty()])
		job.phase = "groups"; _source_compile_metrics.bindingUnits += 1
		return false
	if job.phase=="groups":
		if int(job.groupIndex)<job.groupKeys.size():
			job.currentSite.groupIds.append(job.groupKeys[job.groupIndex])
			job.groupIndex+=1
			_source_snapshot_hash(job,["group",job.currentSite.groupIds.back()])
			_source_compile_metrics.groupUnits += 1
			return false
		job.phase="foreground_groups"
		return false
	if job.phase=="foreground_groups":
		if int(job.foregroundGroupIndex)<job.foregroundGroupKeys.size():
			job.currentSite.foregroundGroupIds.append(job.foregroundGroupKeys[job.foregroundGroupIndex])
			job.foregroundGroupIndex+=1
			_source_snapshot_hash(job,["foregroundGroup",job.currentSite.foregroundGroupIds.back()])
			_source_compile_metrics.groupUnits += 1
			return false
		job.currentSite.binding.make_read_only()
		job.currentSite.groupIds.make_read_only()
		if job.currentSite.has("foregroundGroupIds"): job.currentSite.foregroundGroupIds.make_read_only()
		if job.currentSite.has("foregroundNavigationTileKeys"): job.currentSite.foregroundNavigationTileKeys.make_read_only()
		job.currentSite.make_read_only()
		job.current.sites.append(job.currentSite)
		job.siteIndex += 1; job.phase = "site"
	return false

static func _string_heap_sift_down(values: Array, start: int, end: int) -> void:
	var root:=start
	while root*2+1<end:
		var child:=root*2+1
		if child+1<end and String(values[child+1])<String(values[child]): child+=1
		if String(values[root])<=String(values[child]): return
		var swap_value=values[root]; values[root]=values[child]; values[child]=swap_value
		root=child

static func _string_heap_push(values: Array, value: String) -> void:
	values.append(value)
	var child:=values.size()-1
	while child>0:
		var parent: int=(child-1)/2
		if String(values[parent])<=String(values[child]): return
		var swap_value=values[parent]; values[parent]=values[child]; values[child]=swap_value
		child=parent

static func _string_heap_pop(values: Array) -> String:
	var result:=String(values[0])
	var tail=values.pop_back()
	if not values.is_empty():
		values[0]=tail
		_string_heap_sift_down(values,0,values.size())
	return result

static func _source_snapshot_hash(job: Dictionary, value: Variant) -> void:
	job.hasher.update(var_to_bytes(value))

## View intent changes scheduling only.  It never replaces the retained region,
## reacquires a provider handle, or invalidates an acknowledged source closure.
func set_request_view_intent(request_id: int, value: Variant) -> bool:
	if not _requests.has(request_id):
		last_rejection = "unknown_region_request"
		return false
	var request: Dictionary = _requests[request_id]
	if int(request.get("releaseAt",0))>=0:
		last_rejection = "released_region_request"
		return false
	if value != null and not value is Dictionary:
		last_rejection = "invalid_view_intent"
		return false
	var normalized: Dictionary = ViewPriority.normalize(value)
	if value is Dictionary and not value.is_empty() and normalized.is_empty():
		last_rejection = "invalid_view_intent"
		return false
	if request.get("viewIntent",{})==normalized:
		last_rejection = ""
		return true
	request["viewIntent"] = normalized
	_view_revision += 1
	last_rejection = ""
	return true

func view_revision() -> int:
	return _view_revision

func retained_view_intents() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var ids: Array = _requests.keys()
	ids.sort()
	for id: int in ids:
		var request: Dictionary = _requests[id]
		if int(request.get("releaseAt",-1)) >= 0: continue
		result.append({"ownerId":id,"viewIntent":request.get("viewIntent",{}).duplicate(true)})
	return result

func retained_gameplay_chunks() -> Dictionary:
	return _chunks.duplicate()

## Cheap scheduling identity only. Physical readiness remains a fresh provider
## check at the acceptance boundary.
func request_has_current_sources(request_id: int) -> bool:
	if not _requests.has(request_id): return false
	var request: Dictionary = _requests[request_id]
	if int(request.get("releaseAt",0))>=0 or int(request.get("admittedSequence",0))!=int(request.get("sequence",-1)):
		return false
	for source: Dictionary in request.get("sourceMembers",{}).values():
		if int(source.get("expiresAt",0))>=0: continue
		for deadline: int in source.get("groups",{}).values():
			if deadline<0: return true
	return false

func revision() -> int:
	return _revision

func region_readiness(bounds: Rect2i, request_id: int = 0) -> Dictionary:
	return _region_readiness(bounds,request_id,REQUIRED_DOMAINS,["terrain","render","navigation"],"gameplay")

## Ordinary locomotion requires the authoritative terrain mesh only. Generated
## structures remain retained and their live construction guard prevents late
## collision from appearing through the player.
func player_traversal_readiness(bounds: Rect2i, request_id: int = 0) -> Dictionary:
	return _region_readiness(bounds,request_id,["terrain"],["terrain","render"],"player_traversal")

## Startup and explicit relocation are atomic transitions and keep their
## stronger physical-world gate.
func initial_physical_readiness(bounds: Rect2i, request_id: int = 0) -> Dictionary:
	return _region_readiness(bounds,request_id,["terrain","structures"],["terrain","render"],"initial_physical")

func _region_readiness(bounds: Rect2i, request_id: int, required_domains: Array,
		retained_domains: Array, readiness_scope: String) -> Dictionary:
	if request_id<0 or not valid_bounds(bounds):
		return {"status":"failed", "reason":"invalid_region_bounds", "missing":[], "sourceRevisions":{}}
	var result := {"status":"ready", "reason":"", "missing":[], "sourceRevisions":{}, "domains":{},
		"readinessScope":readiness_scope,"requiredDomains":required_domains.duplicate()}
	var ready_request := {}
	var pending_request := {}
	for id: int in _requests:
		if request_id>0 and id!=request_id: continue
		var candidate: Dictionary = _requests[id]
		# Historical members retain publication work, never current-query authority.
		if int(candidate.releaseAt)>=0 or not candidate.bounds.encloses(bounds): continue
		# A previously admitted broad owner can retain a clean smaller foreground
		# window while another part of its wider closure fails. Do not let that
		# unrelated failure revoke the local query before this function verifies the
		# local source closure, retained membership and live owner receipts below.
		# Same-size and broader queries still observe the stored failure directly.
		var retained_local_query: bool = candidate.bounds.get_area()>bounds.get_area()
		var admitted: bool = int(candidate.admittedSequence)>0 and int(candidate.admittedSequence)==int(candidate.sequence) \
			and (candidate.closureStatus!="failed" or retained_local_query)
		if admitted:
			if ready_request.is_empty() or candidate.bounds.get_area()<ready_request.bounds.get_area():
				ready_request = candidate
		elif pending_request.is_empty() or candidate.bounds.get_area()<pending_request.bounds.get_area():
			pending_request = candidate
	var request: Dictionary = ready_request if not ready_request.is_empty() else pending_request
	result["bounds"] = bounds
	result["closedBounds"] = bounds
	if request.is_empty():
		result.status = "pending"; result.reason = "region_not_requested"
		result.missing.append({"domain":"demand","reason":result.reason})
		return result
	var admitted_current: bool = int(request.admittedSequence)>0 and int(request.admittedSequence)==int(request.sequence)
	var retained_local_query: bool = request.bounds.get_area()>bounds.get_area()
	if not admitted_current or (request.closureStatus=="failed" and not retained_local_query):
		result.status = "failed" if request.closureStatus=="failed" else "pending"
		result.reason = request.closureReason
		result.missing.append({"domain":"dependencies","reason":result.reason})
		return result
	var structures = _provider("structures")
	if not is_instance_valid(structures) or not structures.has_method("region_dependency_requirements"):
		result.status = "pending"; result.reason = "structure_dependency_owner_unavailable"
		return result
	var acceptance_sequence := int(request.sequence)
	# Admission retains work; it is not a physical readiness certificate.
	# A broad refresh may be pending while this query's exact closure is still
	# actively owned. Validate that closure and its current receipts below.
	var revision: Variant = _source_revision(structures,bounds)
	var requirements: Dictionary = structures.region_dependency_requirements(bounds)
	result["requirements"] = requirements
	if requirements.get("status") != "described":
		result.status = "failed" if requirements.get("status")=="failed" else "pending"
		result.reason = requirements.get("reason","structure_dependencies_pending")
		result.missing.append({"domain":"dependencies","reason":result.reason})
		return result
	if not requirements.get("missingSourceIds",[]).is_empty() or not requirements.get("unresolvedCrossingIds",[]).is_empty():
		result.status = "failed"; result.reason = "structure_dependencies_unresolved"
		return result
	var compiled: Dictionary = _compile_sets(requirements,bounds,int(request.get("peripheralMarginCells",RENDER_CELL_SIZE)))
	if compiled.status != "ready":
		result.status = compiled.status; result.reason = compiled.reason
		return result
	var sources: Dictionary = _source_members(requirements.get("sites",[]))
	if sources.status!="ready":
		result.status = sources.status; result.reason = sources.reason
		return result
	var retained_sources: Dictionary = request.get("sourceMembers",{})
	for key: String in sources.members:
		var needed_source: Dictionary = sources.members[key]
		var retained_source: Dictionary = retained_sources.get(key,{})
		if retained_source.get("binding",{})!=needed_source.binding or int(retained_source.get("expiresAt",0))>=0:
			result.status = "pending"; result.reason = "local_source_demand_pending"
			return result
		for group: String in needed_source.groups:
			if int(retained_source.get("groups",{}).get(group,0))>=0:
				result.status = "pending"; result.reason = "local_source_demand_pending"
				return result
	var sets: Dictionary = compiled.sets
	result["closedBounds"] = _envelope(sets.terrain.regions,bounds) # Diagnostic only.
	result["domainRegions"] = {"terrain":sets.terrain.regions,"navigation":sets.navigation.regions}
	for domain: String in retained_domains:
		var held: Dictionary = request.get("sets",{}).get(domain,{}).get("keys",{})
		if not DemandSet.contains(held,sets[domain].keys):
			result.status = "pending"
			result.missing.append({"domain":domain,"reason":"local_dependency_demand_pending"})
	for domain: String in required_domains:
		var provider = _provider(domain)
		var state: Dictionary = {"status":"pending","reason":"regional_owner_acknowledgement_unavailable"}
		var admitted: Dictionary = request.get("providerRequests",{}).get(domain,{})
		var needed: Dictionary = sets.navigation if domain=="navigation" else sets.terrain
		var admitted_navigation: Dictionary = admitted.get("keys",{}).duplicate() if domain=="navigation" else {}
		var navigation_request_ids: Array[int] = []
		if domain=="navigation":
			if int(admitted.get("id",0))>0: navigation_request_ids.append(int(admitted.id))
			var background: Dictionary = request.get("providerRequests",{}).get("navigationBackground",{})
			for key: Vector2i in background.get("keys",{}): admitted_navigation[key] = true
			if int(background.get("id",0))>0: navigation_request_ids.append(int(background.id))
		if domain=="navigation" and not DemandSet.contains(admitted_navigation,needed.keys):
			state.reason = "regional_provider_demand_pending"
		elif domain=="navigation" and is_instance_valid(provider) and provider.has_method("tiles_publication_readiness"):
			state = provider.tiles_publication_readiness(_string_keys(needed.keys),bounds,0,navigation_request_ids) \
				if _navigation_readiness_accepts_collective_handles(provider) else provider.tiles_publication_readiness(_string_keys(needed.keys),bounds,int(admitted.get("id",0)))
		elif domain=="structures" and is_instance_valid(provider) and provider.has_method("region_publication_readiness"):
			# The source query already contains its exact group/support closure.
			# Never rediscover structures across its enclosing geometry envelope.
			state = provider.region_publication_readiness(bounds)
		elif is_instance_valid(provider) and provider.has_method("region_publication_readiness"):
			state = {"status":"ready","reason":"","regions":[],"sourceRevisions":[]}
			for rectangle: Rect2i in needed.regions:
				var receipt: Dictionary = provider.region_publication_readiness(rectangle)
				state.regions.append(receipt)
				state.sourceRevisions.append(receipt.get("sourceRevisions",receipt.get("sourceRevision","")))
				if receipt.get("status")!="ready":
					if state.status!="failed":
						state.status = "failed" if receipt.get("status")=="failed" else "pending"
						state.reason = receipt.get("reason","regional_owner_pending")
		result.domains[domain] = state
		result.sourceRevisions[domain] = state.get("sourceRevisions",state.get("sourceRevision",""))
		if state.get("status")!="ready":
			result.missing.append({"domain":domain,"reason":state.get("reason","invalid_owner_result")})
			if state.get("status")=="failed": result.status = "failed"
			elif result.status!="failed": result.status = "pending"
	if not _request_current(request) or int(request.sequence)!=acceptance_sequence \
			or int(request.admittedSequence)!=acceptance_sequence or not is_instance_valid(structures) \
			or (revision!=null and _source_revision(structures,bounds)!=revision):
		if result.status!="failed": result.status = "pending"
		result.missing.append({"domain":"dependencies","reason":"structure_dependency_revision_changed"})
	if not result.missing.is_empty(): result.reason = "regional_dependencies_incomplete"
	return result

static func _navigation_readiness_accepts_collective_handles(provider) -> bool:
	for method in provider.get_method_list():
		if method.get("name","") == "tiles_publication_readiness": return method.get("args",[]).size() >= 4
	return false

func _rebuild(source_may_have_changed := true) -> void:
	if source_may_have_changed:
		if not _source_compile_job.is_empty(): _source_compile_metrics.restarts += 1
		_source_compile_generation += 1
		_source_snapshot_dirty = true
		_source_compile_job = {}
	_bounds.clear()
	_chunks.clear()
	var ids := _requests.keys()
	ids.sort_custom(func(a: int, b: int):
		return _requests[a].priority < _requests[b].priority if _requests[a].priority != _requests[b].priority else a < b)
	for id: int in ids:
		# Discovery keys feed CitadelPublicationService through
		# retained_source_requests(). Loading them as gameplay chunks multiplied
		# every actor's small physical request into a visual/collision neighborhood.
		for domain: String in ["terrain","render"]:
			for key: Vector2i in _requests[id].members[domain]: _chunks[key] = true
	_bounds = DemandSet.rectangles(_chunks,GAME_CHUNK_SIZE)
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
