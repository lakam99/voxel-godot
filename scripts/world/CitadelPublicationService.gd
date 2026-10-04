extends RefCounted
class_name CitadelPublicationService

## StructureSystem-owned preparation and scene-job lifecycle. Scene construction
## is distinct from gameplay activation: doors/access must be acknowledged by
## the ordinary owner before a constructed city can become playable.
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const SceneJob = preload("res://scripts/buildings/BuildingScenePublicationJob.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const SitePreparation = preload("res://scripts/world/CitadelSitePreparation.gd")
const DemandSet = preload("res://scripts/world/RegionDemandSet.gd")
const ViewPriority = preload("res://scripts/world/GeneratedContentViewPriority.gd")
const SectionGrid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const MAX_REGIONS := 16
const MAX_RETAINED_BOUNDS := 64
const MAX_DISCOVERY_CHUNKS := 256
const DISCOVERY_CHUNK_SIZE := 28
const PREPARATION_TIMEOUT_USEC := 60000000
const NAVIGATION_TILE_CELLS := preload("res://scripts/buildings/layout/BuildingLayoutConstants.gd").NAV_TILE_CELL_SIZE
# Admission confines source geometry to one candidate region. The producer
# adds one output-neighbour tile on each side; this bounds INVENTORY, not the
# independent limit on simultaneously retained navigation requests.
const MAX_NAVIGATION_DOMAIN_AXIS := ceili(float(Field.REGION_CELLS)/float(NAVIGATION_TILE_CELLS))+2
const MAX_NAVIGATION_DOMAIN_KEYS := MAX_NAVIGATION_DOMAIN_AXIS*MAX_NAVIGATION_DOMAIN_AXIS
const MAX_PENDING_NAVIGATION_TILES := 512
# Scheduling policy, not a measured latency target. An eligible waiter gains
# one priority class per four successful worker dispatches, never per query.
const PRIORITY_AGING_DISPATCH_TURNS := 4
# Optional view breadth is a scheduling quota. An exact player/nav safety
# closure may legitimately be wider (the gatehouse joins many collision-bearing
# parts), but remains finite and is split below by the job's measured byte,
# member, collision, registration and time budgets.
const MAX_REQUIRED_FOREGROUND_GROUPS := 1024
const MAX_INCREMENTAL_FOREGROUND_GROUPS := 256
const MAX_ACTIVE_NAVIGATION_PHYSICAL_GROUPS := 256
# Navigation can retain a much wider source closure than the facing physical
# packet. Merge at most this many supplemental groups alongside the source
# window so one tile cannot turn hundreds of tiny battlement groups into a
# single long-lived scene backlog. The combined window remains subject to the
# hard required-foreground ceiling.
const MAX_NAVIGATION_MERGED_FOREGROUND_GROUPS := 128
# Ahead-of-player presentation may warm a substantial, view-ranked working set,
# but it must settle instead of draining the entire source while the camera is
# unchanged. Exact owner and navigation closures can still exceed this count.
const MAX_RESIDENT_PRESENTATION_GROUPS := 1024
const VIEW_WINDOW_PROGRESS_TARGET_GROUPS := 64
const SCENE_UNIT_SAMPLE_CAPACITY := 4096
# Leave headroom for the scene job's final bounded atomic unit and scheduler
# jitter inside the public 4 ms gameplay-thread ceiling.
const SCENE_JOB_SLICE_USEC := 1500
const RETAINED_SOURCE_SLICE_USEC := 750
const RETAINED_SOURCE_UNIT_CAP := 96
const FIRST_USEFUL_HOME_COUNT := 2
const FIRST_USEFUL_HOME_ARCHETYPES: Array[String] = ["bed","chair","hearth","table"]
const FIRST_USEFUL_STRUCTURAL_SEMANTICS: Array[String] = [
	"castle_gatehouse_wall_stair_exit",
	"castle_gatehouse_wall_stair_landing",
	"castle_keep_stair_exit",
	"castle_keep_stair_landing",
]
# G2 measured a 57 s source p95 and representative sprint speed of 15.4 m/s.
# Add twelve seconds for a reversal plus the 180 m visible range. This is a
# scheduling envelope only; it does not retain terrain or certify a source.
const SOURCE_PREFETCH_LOOKAHEAD_METERS := 15.4 * (57.0 + 12.0) + 180.0
const SOURCE_PREFETCH_LATERAL_METERS := float(SitePreparation.MAX_INFLUENCE_RADIUS_CELLS) * SitePreparation.CELL + 180.0

var _admission
var _worker = Worker.new()
var _generation := 0
var _seed := ""
var _closing := false
var _desired: Dictionary = {}
var _retained_region_bounds: Array[Rect2i] = []
var _retained_consumers: Array[Dictionary] = []
var _retained_navigation_priorities: Dictionary = {}
var _retained_binding_priorities: Dictionary = {}
var _retained_discovery_priorities: Dictionary = {}
var _retained_source_compile_job: Dictionary = {}
var _retained_source_committed_revision := -1
var _retained_source_request_serial := -1
var _retained_source_identity := PackedByteArray()
var _retained_source_rejection: Dictionary = {}
var _retained_source_compile_metrics := {"ownerUnits":0,"admissionUnits":0,"navigationUnits":0,
	"bindingUnits":0,"groupUnits":0,"phase":"idle","restarts":0,"rejections":0}
var _observer_region_bounds := Rect2i()
var _observer_bounds_rejected := false
var _prefetch_regions: Array[Vector2i] = []
var _prefetch_rejected := false
var _prefetch_started_usec: Dictionary = {}
var _demand_started_usec: Dictionary = {}
var _demand_revision := 0
var _view_revision := 0
var _prepared: Dictionary = {}
var _navigation: Dictionary = {}
var _pending_packet_navigation: Dictionary = {}
# A retained source query starts before its description has supplied a precise
# physical closure.  Keep its immutable base outside the scene lifecycle so
# the next retained request can promote that same source revision into packet
# navigation.  This is intentionally separate from ordinary retained bounds:
# those callers retain the established whole-source preparation behavior.
var _packet_bootstrap_bases: Dictionary = {}
var _described: Dictionary = {}
var _description_serial := 0
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
var _require_tree_retirement_ack := false
var _construction_guard_receiver: WeakRef
var _construction_guard_method: StringName
var _construction_guard_accepts_members := false
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
var _scene_unit_metrics: Dictionary = {}
var _advancing := false
var _configuration_serial := 0
var _world_reset_pending := false
var _world_reset_release_requested := false
var _worker_polled_configuration := -1
var _dispatch_turn := 0
var _dispatch_sequence := 0
var _preparation_schedule: Dictionary = {}
var _dispatch_metrics := {"navigationDispatches":0,"preparationDispatches":0,"agedDispatches":0,
	"maxFirstDemandUsecByPriority":[0,0,0,0,0],"maxWaitTurnsByPriority":[0,0,0,0,0],"last":{}}

## Bind only after the owner can balance its ordinary scene/tree lifecycle.
## No strong owner/callback cycles; reject capturing/bound custom callables.
## A new root cannot inherit old nodes or lose their cleanup receiver.
func configure_scene_publication(parent: Node3D, tree_publish: Callable, tree_retire: Callable, require_tree_retirement_ack := false) -> bool:
	if _closing or not SceneJob._valid_parent(parent): return false
	if not _ordinary_callback(tree_publish) or not _ordinary_callback(tree_retire): return false
	var same: bool = _scene_parent!=null and _scene_parent.get_ref()==parent \
		and _tree_receiver!=null and _tree_receiver.get_ref()==tree_publish.get_object() and _tree_method==tree_publish.get_method() \
		and _tree_retire_receiver!=null and _tree_retire_receiver.get_ref()==tree_retire.get_object() and _tree_retire_method==tree_retire.get_method()
	same = same and _require_tree_retirement_ack == require_tree_retirement_ack
	if not same and (not _scenes.is_empty() or _has_scene_retirements()): return false
	_scene_parent=weakref(parent)
	_tree_receiver=weakref(tree_publish.get_object()); _tree_method=tree_publish.get_method()
	_tree_retire_receiver=weakref(tree_retire.get_object()); _tree_retire_method=tree_retire.get_method()
	_require_tree_retirement_ack=require_tree_retirement_ack
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

func configure_construction_guard(callback: Callable, accepts_member_bounds := false) -> bool:
	if _closing or not _ordinary_callback(callback): return false
	var same: bool = _construction_guard_receiver != null and _construction_guard_receiver.get_ref() == callback.get_object() and _construction_guard_method == callback.get_method() and _construction_guard_accepts_members==accepts_member_bounds
	if not same and (not _scenes.is_empty() or _has_scene_retirements()): return false
	_construction_guard_receiver=weakref(callback.get_object())
	_construction_guard_method=callback.get_method()
	_construction_guard_accepts_members=accepts_member_bounds
	return true

func _construction_transaction_allowed(transaction: Dictionary) -> bool:
	if transaction.get("status")!="ready" or not transaction.get("collisionMemberBounds") is Array: return false
	if _construction_guard_receiver==null: return not _require_tree_retirement_ack
	var receiver = _construction_guard_receiver.get_ref()
	if not is_instance_valid(receiver): return false
	var callback: Callable = Callable(receiver,_construction_guard_method)
	if not callback.is_valid(): return false
	var configuration: int = _configuration_serial
	var demand: int = _demand_revision
	if _construction_guard_accepts_members:
		var allowed: Variant = callback.call(transaction.collisionMemberBounds)
		return allowed==true and configuration==_configuration_serial and demand==_demand_revision and not _closing and not _world_reset_pending
	# Existing diagnostic callbacks consume one rectangle. Production binds the
	# batched ordinary capsule owner, retaining exactly the same member envelopes.
	for value in transaction.collisionMemberBounds:
		if not value is AABB or not value.position.is_finite() or not value.end.is_finite(): return false
		var low: Vector2i = Vector2i(floori(value.position.x/1.35),floori(value.position.z/1.35))
		var high: Vector2i = Vector2i(ceili(value.end.x/1.35)+1,ceili(value.end.z/1.35)+1)
		if callback.call(Rect2i(low,high-low))!=true: return false
		if configuration!=_configuration_serial or demand!=_demand_revision or _closing or _world_reset_pending: return false
	return true

func _construction_allowed(source: Dictionary) -> bool:
	if _construction_guard_receiver == null: return not _require_tree_retirement_ack
	var receiver = _construction_guard_receiver.get_ref()
	if not is_instance_valid(receiver): return false
	var callback := Callable(receiver,_construction_guard_method)
	if not callback.is_valid(): return false
	var configuration := _configuration_serial
	var demand_revision := _demand_revision
	var allowed: Variant = callback.call(source.reservationCells)
	return allowed == true and configuration == _configuration_serial and demand_revision == _demand_revision and not _closing and not _world_reset_pending

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
	_retained_region_bounds = []
	_retained_consumers = []
	_retained_source_compile_job = {}
	_retained_source_committed_revision = -1
	_retained_source_request_serial = -1
	_retained_source_identity = PackedByteArray()
	_retained_source_rejection = {}
	_clear_retained_priorities()
	_observer_region_bounds = Rect2i()
	_prefetch_regions.clear()
	_prefetch_started_usec.clear()
	_demand_started_usec.clear()
	_observer_bounds_rejected = false
	_prefetch_rejected = false
	_demand_revision += 1
	_view_revision += 1
	_inflight = {}
	_failures = {}
	_scene_unit_metrics = {}
	_scene_max_step_usec = 0
	_admission = admission
	var state: Dictionary = admission.stats()
	_generation = int(state.generation)
	_seed = String(state.worldSeed)

## The coordinator owns tokens, priorities and release hysteresis. Replacement
## is atomic and privately copied; this service owns only publication demand.
func set_retained_region_bounds(bounds: Array) -> bool:
	if _closing or bounds.size() > MAX_RETAINED_BOUNDS: return false
	_retained_source_compile_job = {}
	var owned: Array[Rect2i] = []
	for rectangle in bounds:
		if not rectangle is Rect2i or not _bounded_region_rectangle(rectangle): return false
		owned.append(rectangle)
	if bounds == _retained_region_bounds and _retained_consumers.is_empty(): return true
	_retained_region_bounds = owned
	_retained_consumers = []
	_retained_source_identity = PackedByteArray()
	_retained_source_committed_revision = -1
	_retained_source_rejection = {}
	_clear_retained_priorities()
	_demand_revision += 1
	return true

## One logical consumer owns its current query and trailing source pins.
## Discovery keys come only from original queries, never dependency envelopes.
func set_retained_source_requests(requests: Array) -> bool:
	_retained_source_request_serial=maxi(_retained_source_request_serial,_retained_source_committed_revision)+1
	var revision := _retained_source_request_serial
	if not request_retained_source_requests(revision,requests,true): return false
	while true:
		var state := advance_retained_source_requests(1000000,2147483647)
		if state.status=="ready": return true
		if state.status=="failed": return false
	return false

func request_retained_source_requests(source_revision: int, requests: Array,
		allow_synchronous_mutable_input := false) -> bool:
	_retained_source_request_serial=maxi(_retained_source_request_serial,source_revision)
	var active_revision:=int(_retained_source_compile_job.get("revision",-1))
	if source_revision<_retained_source_committed_revision or (active_revision>=0 and source_revision<active_revision):
		return false
	if not allow_synchronous_mutable_input and not requests.is_read_only():
		_retained_source_rejection={"status":"failed","reason":"mutable_retained_source_manifest","revision":source_revision}
		return false
	if int(_retained_source_rejection.get("revision",-1))==source_revision: return false
	if int(_retained_source_compile_job.get("revision",-1))==source_revision \
			or (_retained_source_committed_revision==source_revision and _retained_source_compile_job.is_empty()): return true
	if not _retained_source_compile_job.is_empty(): _retained_source_compile_metrics.restarts += 1
	_retained_source_rejection = {}
	var hasher:=HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	_retained_source_compile_job = {"revision":source_revision,"requests":requests,"phase":"owner","ownerIndex":0,
		"owned":[],"discovery":{},"navigationPriorities":{},"bindingPriorities":{},"discoveryPriorities":{},
		"ids":{},"current":{},"index":0,"siteIndex":0,"totalGroups":0,"failed":"","hasher":hasher,
		"requireImmutable":not allow_synchronous_mutable_input}
	return true

func cancel_retained_source_request_compile() -> void:
	_retained_source_compile_job = {}
	_retained_source_rejection = {}

func retained_source_request_compile_metrics() -> Dictionary:
	return _retained_source_compile_metrics.duplicate(true)

func retained_source_committed_revision() -> int:
	return _retained_source_committed_revision

func advance_retained_source_requests(budget_usec := RETAINED_SOURCE_SLICE_USEC,
		unit_cap := RETAINED_SOURCE_UNIT_CAP) -> Dictionary:
	if _closing: return {"status":"failed","reason":"service_closing"}
	if _retained_source_compile_job.is_empty():
		if not _retained_source_rejection.is_empty(): return _retained_source_rejection.duplicate(true)
		return {"status":"ready","revision":_retained_source_committed_revision}
	var started := Time.get_ticks_usec()
	var units := 0
	while units<maxi(1,unit_cap) and Time.get_ticks_usec()-started<maxi(1,budget_usec):
		var status := _advance_retained_source_request_unit()
		if status!="pending":
			if status=="failed":
				var reason: String = _retained_source_compile_job.get("failed","invalid_retained_source_manifest")
				var rejected_revision:=int(_retained_source_compile_job.get("revision",-1))
				_retained_source_compile_job = {}
				_retained_source_compile_metrics.rejections += 1
				_retained_source_rejection = {"status":"failed","reason":reason,"revision":rejected_revision}
				return _retained_source_rejection.duplicate(true)
			var job := _retained_source_compile_job
			var bounds: Array[Rect2i] = []
			var world_bounds := Rect2i(-1000000,-1000000,2000000,2000000)
			for rectangle: Rect2i in DemandSet.rectangles(job.discovery,DISCOVERY_CHUNK_SIZE):
				var clipped := rectangle.intersection(world_bounds)
				if not _bounded_region_rectangle(clipped):
					var rejected_revision:=int(job.revision)
					_retained_source_compile_job = {}
					_retained_source_compile_metrics.rejections += 1
					_retained_source_rejection={"status":"failed","reason":"invalid_retained_bounds","revision":rejected_revision}
					return _retained_source_rejection.duplicate(true)
				bounds.append(clipped)
			var identity: PackedByteArray=job.hasher.finish()
			if identity!=_retained_source_identity:
				var completed_consumers: Array[Dictionary] = []
				completed_consumers.assign(job.owned)
				_retained_consumers = completed_consumers
				_retained_region_bounds = bounds
				_retained_navigation_priorities = job.navigationPriorities
				_retained_binding_priorities = job.bindingPriorities
				_retained_discovery_priorities = job.discoveryPriorities
				_retained_source_identity = identity
				_demand_revision += 1
			_retained_source_committed_revision = int(job.revision)
			_retained_source_compile_job = {}
			_retained_source_compile_metrics.phase = "ready"
			return {"status":"ready","revision":_retained_source_committed_revision}
		units += 1
	return {"status":"pending","revision":int(_retained_source_compile_job.revision)}

func _retained_compile_fail(reason: String) -> String:
	_retained_source_compile_job.failed = reason
	return "failed"

static func _retained_consumer_hash(job: Dictionary, value: Variant) -> void:
	job.hasher.update(var_to_bytes(value))

func _advance_retained_source_request_unit() -> String:
	var job := _retained_source_compile_job
	_retained_source_compile_metrics.phase = job.phase
	var requests: Array = job.requests
	if job.phase=="owner":
		if requests.size()>MAX_RETAINED_BOUNDS: return _retained_compile_fail("retained_consumer_capacity")
		if int(job.ownerIndex)>=requests.size(): return "ready"
		var value = requests[job.ownerIndex]
		if not value is Dictionary or not value.get("ownerId") is int or int(value.ownerId)<=0 or job.ids.has(value.ownerId): return _retained_compile_fail("invalid_owner")
		if not value.get("bounds") is Rect2i or not DemandSet.valid_bounds(value.bounds): return _retained_compile_fail("invalid_bounds")
		if not value.get("priority") is int or int(value.priority)<0 or int(value.priority)>4: return _retained_compile_fail("invalid_priority")
		if not value.get("sites",[]) is Array or value.sites.size()>MAX_REGIONS: return _retained_compile_fail("invalid_sites")
		if not value.get("admissionKeys") is Array or value.admissionKeys.is_empty() or value.admissionKeys.size()>MAX_DISCOVERY_CHUNKS: return _retained_compile_fail("invalid_admission_keys")
		if not value.get("navigationTileKeys") is Array or value.navigationTileKeys.is_empty() or value.navigationTileKeys.size()>MAX_PENDING_NAVIGATION_TILES: return _retained_compile_fail("invalid_navigation_keys")
		if value.has("navigationTilePriorities") and not value.navigationTilePriorities is Dictionary: return _retained_compile_fail("invalid_navigation_priorities")
		if bool(job.requireImmutable) and (not value.is_read_only() or not value.admissionKeys.is_read_only()
				or not value.navigationTileKeys.is_read_only() or not value.sites.is_read_only()
				or (value.has("navigationTilePriorities") and not value.navigationTilePriorities.is_read_only())):
			return _retained_compile_fail("mutable_retained_source_manifest")
		job.ids[value.ownerId] = true
		job.current = {"value":value,"consumerKeys":{},"navigationMembers":{},"navigationKeys":[],"navigationDeclaredPriorities":{},
			"admissionKeys":[],"sites":[],"siteBindings":[],"totalGroups":0,"retainedTilePriorities":{}}
		job.index=0; job.phase="admission"; _retained_source_compile_metrics.ownerUnits += 1
		_retained_consumer_hash(job,["owner",value.ownerId,value.bounds,value.priority])
		return "pending"
	var current: Dictionary = job.current
	var value: Dictionary = current.value
	if job.phase=="admission":
		if int(job.index)<value.admissionKeys.size():
			var key = value.admissionKeys[job.index]
			if not key is Vector2i or key.x < -35715 or key.x > 35714 or key.y < -35715 or key.y > 35714: return _retained_compile_fail("invalid_admission_key")
			current.consumerKeys[key]=true; job.discovery[key]=true
			if job.discovery.size()>MAX_DISCOVERY_CHUNKS: return _retained_compile_fail("discovery_capacity")
			job.index+=1; _retained_source_compile_metrics.admissionUnits += 1
			return "pending"
		var required := DemandSet.from_regions([value.bounds],DISCOVERY_CHUNK_SIZE,MAX_DISCOVERY_CHUNKS,32)
		if required.status!="ready" or not DemandSet.contains(current.consumerKeys,required.keys): return _retained_compile_fail("incomplete_admission_keys")
		job.index=0; job.phase="navigation"; return "pending"
	if job.phase=="navigation":
		if int(job.index)<value.navigationTileKeys.size():
			var raw_key = value.navigationTileKeys[job.index]
			if not raw_key is String or raw_key.length()>23: return _retained_compile_fail("invalid_navigation_key")
			var coordinates: PackedStringArray = raw_key.split(",",true)
			if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int(): return _retained_compile_fail("invalid_navigation_key")
			var x:=int(coordinates[0]); var z:=int(coordinates[1])
			if x < -62500 or x > 62499 or z < -62500 or z > 62499 or raw_key!="%d,%d" % [x,z]: return _retained_compile_fail("invalid_navigation_key")
			var tile:=Vector2i(x,z)
			var first_tile: bool=not current.navigationMembers.has(tile)
			if first_tile: current.navigationKeys.append(raw_key)
			current.navigationMembers[tile]=true
			var declared: Dictionary=value.get("navigationTilePriorities",{})
			var priority:=int(declared.get(raw_key,value.priority))
			if priority<0 or priority>4: return _retained_compile_fail("invalid_navigation_priority")
			current.navigationDeclaredPriorities[raw_key]=priority
			job.navigationPriorities[raw_key]=mini(int(job.navigationPriorities.get(raw_key,4)),priority)
			if job.navigationPriorities.size()>MAX_PENDING_NAVIGATION_TILES: return _retained_compile_fail("navigation_capacity")
			job.index+=1; _retained_source_compile_metrics.navigationUnits += 1
			return "pending"
		var required_nav:=DemandSet.from_regions([value.bounds],NAVIGATION_TILE_CELLS,MAX_PENDING_NAVIGATION_TILES)
		if required_nav.status!="ready" or not DemandSet.contains(current.navigationMembers,required_nav.keys): return _retained_compile_fail("incomplete_navigation_keys")
		current.navigationKeys.sort()
		job.index=0; job.phase="navigation_hash"; return "pending"
	if job.phase=="navigation_hash":
		if int(job.index)<current.navigationKeys.size():
			var key: String=current.navigationKeys[job.index]
			_retained_consumer_hash(job,["navigation",key,current.navigationDeclaredPriorities[key]])
			job.index+=1; return "pending"
		job.index=0; job.phase="discovery_priority"; return "pending"
	if job.phase=="discovery_priority":
		var keys: Array=current.consumerKeys.keys()
		if int(job.index)<keys.size():
			var key: Vector2i=keys[job.index]
			current.admissionKeys.append(key)
			var chunk_bounds:=Rect2i(key*DISCOVERY_CHUNK_SIZE,Vector2i.ONE*DISCOVERY_CHUNK_SIZE)
			var low:=Field.region_for_cell(chunk_bounds.position); var high:=Field.region_for_cell(chunk_bounds.end-Vector2i.ONE)
			for z in range(low.y,high.y+1):
				for x in range(low.x,high.x+1):
					var region:=Vector2i(x,z)
					if not job.discoveryPriorities.has(region): job.discoveryPriorities[region]={}
					job.discoveryPriorities[region][key]=mini(int(job.discoveryPriorities[region].get(key,4)),int(value.priority))
			job.index+=1; _retained_source_compile_metrics.admissionUnits += 1
			return "pending"
		current.admissionKeys.sort_custom(func(a:Vector2i,b:Vector2i):return a.y<b.y if a.y!=b.y else a.x<b.x)
		job.index=0; job.phase="admission_hash"; return "pending"
	if job.phase=="admission_hash":
		if int(job.index)<current.admissionKeys.size():
			_retained_consumer_hash(job,["admission",current.admissionKeys[job.index]])
			job.index+=1; return "pending"
		job.siteIndex=0; job.phase="site"; return "pending"
	if job.phase=="site":
		if int(job.siteIndex)>=value.sites.size():
			for key: String in current.navigationKeys: current.retainedTilePriorities[key]=int(value.get("navigationTilePriorities",{}).get(key,value.priority))
			var retained := {"ownerId":value.ownerId,"bounds":value.bounds,"priority":value.priority,
				"admissionKeys":current.admissionKeys,"navigationTileKeys":current.navigationKeys,
				"navigationTilePriorities":current.retainedTilePriorities,"sites":current.sites}
			job.owned.append(retained); job.ownerIndex+=1; job.phase="owner"
			return "pending"
		var site=value.sites[job.siteIndex]
		if not site is Dictionary: return _retained_compile_fail("invalid_site")
		if bool(job.requireImmutable) and not site.is_read_only(): return _retained_compile_fail("mutable_retained_source_manifest")
		if not site.has("groupIds"): job.siteIndex+=1; return "pending"
		if not site.get("binding") is Dictionary or not site.groupIds is Array or site.groupIds.size()>30000: return _retained_compile_fail("invalid_binding")
		if bool(job.requireImmutable) and (not site.binding.is_read_only() or not site.groupIds.is_read_only()
				or (site.has("foregroundGroupIds") and not site.foregroundGroupIds.is_read_only())
				or (site.has("foregroundNavigationTileKeys") and not site.foregroundNavigationTileKeys.is_read_only())):
			return _retained_compile_fail("mutable_retained_source_manifest")
		var binding:Dictionary=site.binding
		if binding.size()!=3 or not binding.get("siteId") is String or binding.siteId.is_empty() or not binding.get("sourceKey") is String or binding.sourceKey.is_empty() or not binding.get("generation") is int or int(binding.generation)<=0: return _retained_compile_fail("invalid_binding")
		if current.siteBindings.has(binding): return _retained_compile_fail("duplicate_binding")
		current.siteBindings.append(binding.duplicate())
		_retained_consumer_hash(job,["binding",binding])
		# Presence is semantic: an explicitly empty foreground group closure says
		# dependency discovery completed with no urgent groups, while omission says
		# the source is still on the legacy/tile-derived path.
		_retained_consumer_hash(job,["sitePresence",site.has("foregroundGroupIds")])
		job.currentSite={"raw":site,"binding":binding.duplicate(),"groupIds":[],"seen":{},"foregroundNavigationTileKeys":[],"foregroundSeen":{},"foregroundGroupIds":[],"foregroundGroupSeen":{}}
		job.index=0; job.phase="groups"; _retained_source_compile_metrics.bindingUnits += 1
		return "pending"
	var current_site:Dictionary=job.currentSite
	var raw_site:Dictionary=current_site.raw
	if job.phase=="groups":
		if int(job.index)<raw_site.groupIds.size():
			var id=raw_site.groupIds[job.index]
			if not id is String or id.is_empty(): return _retained_compile_fail("invalid_group")
			if not current_site.seen.has(id):
				current_site.seen[id]=true; current_site.groupIds.append(id); current.totalGroups+=1
				_retained_consumer_hash(job,["group",id])
			if int(current.totalGroups)>30000: return _retained_compile_fail("group_capacity")
			job.index+=1; _retained_source_compile_metrics.groupUnits += 1
			return "pending"
		job.index=0; job.phase="foreground_navigation"; return "pending"
	if job.phase=="foreground_navigation":
		if raw_site.has("foregroundNavigationTileKeys"):
			if not raw_site.foregroundNavigationTileKeys is Array or raw_site.foregroundNavigationTileKeys.size()>MAX_PENDING_NAVIGATION_TILES: return _retained_compile_fail("invalid_foreground_navigation")
			if int(job.index)<raw_site.foregroundNavigationTileKeys.size():
				var raw_key=raw_site.foregroundNavigationTileKeys[job.index]
				if not raw_key is String or not value.navigationTileKeys.has(raw_key): return _retained_compile_fail("invalid_foreground_navigation")
				if not current_site.foregroundSeen.has(raw_key):
					current_site.foregroundSeen[raw_key]=true; current_site.foregroundNavigationTileKeys.append(raw_key)
				job.index+=1; _retained_source_compile_metrics.navigationUnits += 1; return "pending"
		current_site.foregroundNavigationTileKeys.sort(); job.index=0; job.phase="foreground_navigation_hash"; return "pending"
	if job.phase=="foreground_navigation_hash":
		if int(job.index)<current_site.foregroundNavigationTileKeys.size():
			_retained_consumer_hash(job,["foregroundNavigation",current_site.foregroundNavigationTileKeys[job.index]])
			job.index+=1; return "pending"
		job.index=0; job.phase="foreground_groups"; return "pending"
	if job.phase=="foreground_groups":
		if raw_site.has("foregroundGroupIds"):
			if not raw_site.foregroundGroupIds is Array or raw_site.foregroundGroupIds.size()>30000: return _retained_compile_fail("invalid_foreground_groups")
			if int(job.index)<raw_site.foregroundGroupIds.size():
				var id=raw_site.foregroundGroupIds[job.index]
				if not id is String or id.is_empty() or not current_site.seen.has(id): return _retained_compile_fail("invalid_foreground_group")
				if not current_site.foregroundGroupSeen.has(id):
					current_site.foregroundGroupSeen[id]=true; current_site.foregroundGroupIds.append(id)
				job.index+=1; _retained_source_compile_metrics.groupUnits += 1; return "pending"
		job.foregroundHeap=current_site.foregroundGroupIds
		current_site.foregroundGroupIds=[]
		job.heapIndex=floori(float(job.foregroundHeap.size())/2.0)-1
		job.phase="foreground_group_heap"
		return "pending"
	if job.phase=="foreground_group_heap":
		if int(job.heapIndex)>=0:
			_retained_string_heap_sift_down(job.foregroundHeap,int(job.heapIndex),job.foregroundHeap.size())
			job.heapIndex-=1
			return "pending"
		job.phase="foreground_group_order"; return "pending"
	if job.phase=="foreground_group_order":
		if not job.foregroundHeap.is_empty():
			var id:=_retained_string_heap_pop(job.foregroundHeap)
			current_site.foregroundGroupIds.append(id)
			_retained_consumer_hash(job,["foregroundGroup",id])
			_retained_source_compile_metrics.groupUnits += 1
			return "pending"
		job.sourcePlan=_publication_plan_for_binding(current_site.binding) if raw_site.has("foregroundGroupIds") else null
		job.planEligible=job.sourcePlan!=null
		job.eligibilityIndex=0
		job.phase="foreground_eligibility"
		return "pending"
	if job.phase=="foreground_eligibility":
		if bool(job.planEligible) and int(job.eligibilityIndex)<current_site.foregroundGroupIds.size():
			if not job.sourcePlan.eligible_group_ids.has(current_site.foregroundGroupIds[job.eligibilityIndex]): job.planEligible=false
			job.eligibilityIndex+=1
			_retained_source_compile_metrics.groupUnits += 1
			return "pending"
		var retained_site:={"binding":current_site.binding,"groupIds":current_site.groupIds,
			"foregroundNavigationTileKeys":current_site.foregroundNavigationTileKeys}
		if raw_site.has("foregroundGroupIds"):
			retained_site["foregroundGroupIds"]=current_site.foregroundGroupIds
			if bool(job.planEligible): retained_site["foregroundPlanSignature"]=job.sourcePlan.output_signature
		_retained_consumer_hash(job,["siteEnd",retained_site.get("foregroundPlanSignature","")])
		current.sites.append(retained_site)
		var binding_key:=_priority_binding_key(current_site.binding)
		job.bindingPriorities[binding_key]=mini(int(job.bindingPriorities.get(binding_key,4)),int(value.priority))
		job.siteIndex+=1; job.phase="site"; return "pending"
	return _retained_compile_fail("invalid_compile_phase")

static func _retained_string_heap_sift_down(values: Array, start: int, end: int) -> void:
	var root:=start
	while root*2+1<end:
		var child:=root*2+1
		if child+1<end and String(values[child+1])<String(values[child]): child+=1
		if String(values[root])<=String(values[child]): return
		var swap_value=values[root]; values[root]=values[child]; values[child]=swap_value
		root=child

static func _retained_string_heap_pop(values: Array) -> String:
	var result:=String(values[0])
	var tail=values.pop_back()
	if not values.is_empty():
		values[0]=tail
		_retained_string_heap_sift_down(values,0,values.size())
	return result

func _publication_plan_for_binding(binding: Dictionary):
	for region: Vector2i in _scenes:
		var entry: Dictionary = _scenes[region]
		if entry.get("binding",{})!=binding: continue
		var job = entry.get("job",null)
		var base = job._cpu.get("publicationBase",null) if job!=null else null
		if base!=null and base.publication_plan!=null and base.publication_plan.matches(binding,base.description.publication_groups.groups):
			return base.publication_plan
	for region: Vector2i in _packet_bootstrap_bases:
		var bootstrap: Dictionary = _packet_bootstrap_bases[region]
		var base = bootstrap.get("base",null)
		if bootstrap.get("binding",{}) == binding and base != null \
				and base.publication_plan != null and base.publication_plan.matches(binding,base.description.publication_groups.groups):
			return base.publication_plan
	for region: Vector2i in _prepared:
		var prepared: Dictionary = _prepared[region]
		var base = prepared.get("base",null)
		if prepared.get("binding",{}) == binding and base != null \
				and base.publication_plan != null and base.publication_plan.matches(binding,base.description.publication_groups.groups):
			return base.publication_plan
	return null


## Blueprint buildings are one provider in the section census, not proof that
## the other static domains are empty. This query uses the immutable plan and
## admission decisions only; scene Nodes and publication readiness are excluded.
func capture_static_section_sources(world_id: String, section_keys: Array) -> Dictionary:
	if _admission == null or _closing or _world_reset_pending \
			or world_id != "seed:%s:%d" % [_seed,_seed_hash(_seed)] or section_keys.is_empty():
		return {"status":"pending","reason":"citadel_section_source_authority_unavailable","retryable":true}
	var unique_sections: Dictionary = {}
	var sections: Array[Vector3i] = []
	for value in section_keys:
		if not value is Vector3i or unique_sections.has(value):
			return {"status":"failed","reason":"invalid_citadel_section_source_query"}
		unique_sections[value] = true
		sections.append(value)
	sections.sort_custom(func(a: Vector3i,b: Vector3i) -> bool:
			if a.x != b.x: return a.x < b.x
			if a.y != b.y: return a.y < b.y
			return a.z < b.z)
	var section_rows: Dictionary = {}
	var source_revisions: Dictionary = {}
	for section_key: Vector3i in sections:
		var origin := SectionGrid.origin_for_key(section_key)
		var section_bounds := AABB(origin,Vector3.ONE*SectionGrid.SECTION_SIZE_METERS)
		# request_bounds operates on terrain cells and is deliberately conservative
		# at the section edge; exact provider membership is filtered in 3D below.
		var low := Vector2i(floori(origin.x/CitadelPublicationPlan.CELL)-2,
			floori(origin.z/CitadelPublicationPlan.CELL)-2)
		var high := Vector2i(ceili(section_bounds.end.x/CitadelPublicationPlan.CELL)+2,
			ceili(section_bounds.end.z/CitadelPublicationPlan.CELL)+2)
		var admission_bounds := Rect2i(low,high-low)
		var admitted: Dictionary = _admission.request_bounds(admission_bounds)
		if admitted.get("status") == "pending":
			return {"status":"pending","reason":"citadel_section_admission_pending",
				"section":section_key,"retryable":true}
		if admitted.get("status") != "ready":
			return {"status":"failed","reason":String(admitted.get("reason","citadel_section_admission_failed")),
				"section":section_key}
		var low_region := Field.region_for_cell(admission_bounds.position)
		var high_region := Field.region_for_cell(admission_bounds.end-Vector2i.ONE)
		var ids: Array[String] = []
		var rows: Array = []
		for rz in range(low_region.y,high_region.y+1):
			for rx in range(low_region.x,high_region.x+1):
				var region := Vector2i(rx,rz)
				var source: Dictionary = _admission.source_state(region)
				if source.get("status") == "absent":
					# request_bounds proved any unprepared region does not intersect
					# the admitted query, so source_not_requested is also safe here.
					continue
				if source.get("status") == "failed":
					return {"status":"failed","reason":String(source.get("reason","citadel_section_source_failed")),
						"section":section_key,"region":region}
				if source.get("status") not in ["ready","prepared"]:
					return {"status":"pending","reason":"citadel_section_source_decision_pending",
						"section":section_key,"region":region,"retryable":true}
				if not source.get("reservationCells") is Rect2i:
					return {"status":"failed","reason":"citadel_section_reservation_missing","region":region}
				if not source.reservationCells.intersects(admission_bounds): continue
				if _failures.has(region):
					return {"status":"failed","reason":String(_failures[region].reason),"region":region}
				var binding: Dictionary = source.get("binding",{})
				var plan = _publication_plan_for_binding(binding)
				if plan == null or not plan.matches(binding,plan.groups):
					return {"status":"pending","reason":"citadel_section_plan_pending",
						"section":section_key,"region":region,"retryable":true}
				var description: Dictionary = plan.visual_members_intersecting_bounds(section_bounds)
				if description.get("status") != "described":
					return {"status":"failed","reason":String(description.get("reason","citadel_section_membership_failed")),
						"region":region}
				for member: Dictionary in description.members:
					var member_id := String(member.memberId)
					var source_id := "citadel:%s:member:%s:section:%d,%d,%d" % [
						String(binding.siteId),member_id,section_key.x,section_key.y,section_key.z]
					var revision_bytes := var_to_bytes(["citadel-section-source/v1",binding.siteId,
						binding.sourceKey,int(binding.get("generation",-1)),plan.output_signature,
						member_id,member.groupId,member.bounds,section_key])
					var source_digest := HashingContext.new()
					if source_digest.start(HashingContext.HASH_SHA256) != OK:
						return {"status":"failed","reason":"citadel_section_revision_hash_failed"}
					source_digest.update(revision_bytes)
					var revision := source_digest.finish().hex_encode()
					if source_revisions.has(source_id) and source_revisions[source_id] != revision:
						return {"status":"failed","reason":"citadel_section_source_revision_conflict"}
					source_revisions[source_id] = revision
					ids.append(source_id)
					rows.append([source_id,revision])
		ids.sort()
		rows.sort_custom(func(a: Array,b: Array) -> bool: return String(a[0]) < String(b[0]))
		var coverage_hash := HashingContext.new()
		coverage_hash.start(HashingContext.HASH_SHA256)
		coverage_hash.update(var_to_bytes([world_id,section_key,rows]))
		section_rows[section_key] = {"status":"complete" if not ids.is_empty() else "empty",
			"coverageRevision":coverage_hash.finish().hex_encode(),"sourcePartIds":ids}
	var admission_state: Dictionary = _admission.stats()
	var authority_hash := HashingContext.new()
	authority_hash.start(HashingContext.HASH_SHA256)
	authority_hash.update(var_to_bytes(["citadel-section-authority/v1",world_id,_generation,
		int(admission_state.get("generation",-1))]))
	return {"status":"complete","worldId":world_id,
		"authorityRevision":authority_hash.finish().hex_encode(),
		"sourceRevisions":source_revisions,"sections":section_rows}


static func _seed_hash(value: String) -> int:
	var result := 2166136261
	for index in value.length():
		result = int((result ^ value.unicode_at(index)) * 16777619) & 0xffffffff
	return result

## Camera intent is scheduling state, not spatial/source ownership. Applying it
## must not replay the immutable source manifest or invalidate the currently
## retained packet transaction. The newest view is consumed when that bounded
## window completes and the job asks for its next window.
func set_retained_view_intents(values: Array) -> bool:
	if _closing or values.size()>MAX_RETAINED_BOUNDS: return false
	var by_owner: Dictionary = {}
	for value in values:
		if not value is Dictionary or not value.get("ownerId") is int or int(value.ownerId)<=0 \
				or by_owner.has(int(value.ownerId)) or not value.get("viewIntent",{}) is Dictionary:
			return false
		var raw: Dictionary = value.get("viewIntent",{})
		var normalized: Dictionary = ViewPriority.normalize(raw)
		if not raw.is_empty() and normalized.is_empty(): return false
		by_owner[int(value.ownerId)] = normalized
	var changed := false
	for consumer: Dictionary in _retained_consumers:
		var owner_id := int(consumer.ownerId)
		if not by_owner.has(owner_id): continue
		var next: Dictionary = by_owner[owner_id]
		if consumer.get("viewIntent",{}) == next: continue
		if next.is_empty(): consumer.erase("viewIntent")
		else: consumer["viewIntent"] = next
		changed = true
	if changed: _view_revision += 1
	return true

func _clear_retained_priorities() -> void:
	_retained_navigation_priorities = {}
	_retained_binding_priorities = {}
	_retained_discovery_priorities = {}

static func _priority_binding_key(binding: Dictionary) -> String:
	return JSON.stringify([binding.get("siteId",""),binding.get("sourceKey",""),binding.get("generation",0)])

func _navigation_priority(key: String) -> int:
	return int(_retained_navigation_priorities.get(key,4))

func _preparation_priority(region: Vector2i, source: Dictionary) -> int:
	var priority: int = int(_retained_binding_priorities.get(_priority_binding_key(source.binding),4))
	for key: Vector2i in _retained_discovery_priorities.get(region,{}):
		if source.reservationCells.intersects(Rect2i(key*DISCOVERY_CHUNK_SIZE,Vector2i.ONE*DISCOVERY_CHUNK_SIZE)):
			priority = mini(priority,int(_retained_discovery_priorities[region][key]))
	return priority

static func _bounded_region_rectangle(bounds: Rect2i) -> bool:
	# Use Admission's cell domain before computing end (Vector2i can overflow).
	if not Admission._valid_bounds(bounds): return false
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end - Vector2i.ONE)
	return (high.x-low.x+1)*(high.y-low.y+1) <= MAX_REGIONS

func advance(observer_bounds: Rect2i = Rect2i(), allow_dispatch := false, budget_usec := 2500) -> Dictionary:
	if budget_usec<1 or budget_usec>4000: return {"status":"rejected","reason":"invalid_slice_budget"}
	if _advancing: return {"status":"rejected","reason":"reentrant_advance"}
	_advancing=true
	var started := Time.get_ticks_usec()
	if _admission != null and int(_admission.stats().generation) != _generation:
		configure(_admission)
	var configuration:=_configuration_serial
	var demand_revision := _demand_revision
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
		# `_refresh_demand` may advance the observer's closure revision.  That
		# revised demand is already fully owned by this call, so it may dispatch
		# immediately; only later reentrant changes must invalidate this slice.
		demand_revision = _demand_revision
	_prune_invalid_scenes()
	_last_worker_status = _worker.poll()
	_worker_polled_configuration = _configuration_serial
	_prune_invalid_descriptions()
	_collect_description(ready,allow_dispatch and not _closing)
	# A tile can become physically ready while a lower-priority packet owns the
	# only worker. Give its immutable navigation source the next idle slot before
	# scene publication selects another retained background packet.
	if allow_dispatch and _inflight.is_empty(): _dispatch_pending_packet_navigation()
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
			_retire_description(_inflight.region)
			_inflight = {}
	_pump_scenes(ready,allow_dispatch and not _closing,started,budget_usec)
	if _world_reset_release_requested and world_reset_ready():
		_world_reset_pending = false
		_world_reset_release_requested = false
	if allow_dispatch and not _closing and configuration==_configuration_serial and demand_revision==_demand_revision and _retired.is_empty() and _inflight.is_empty():
		# Dispatch has now transferred the mutable producer out of the service
		# entry. Start that queued worker on this same owner advance instead of
		# leaving a known-safe batch idle until a later frame.
		if _dispatch(ready,observer_bounds.get_center()):
			_last_worker_status = _worker.poll()
			_worker_polled_configuration = _configuration_serial
	_max_advance_usec = maxi(_max_advance_usec,Time.get_ticks_usec()-started)
	_advancing=false
	return stats()

func _refresh_demand(bounds: Rect2i) -> Dictionary:
	var desired := {}
	var ready := {}
	_observer_bounds_rejected = bounds != Rect2i() and not _bounded_region_rectangle(bounds)
	# Rejected samples are not departure. Empty explicitly releases the observer.
	if not _observer_bounds_rejected and _observer_region_bounds != bounds:
		_observer_region_bounds = bounds
		# A foreground observer move can change the exact physical closure even
		# when its retained source set is unchanged.  Re-evaluate packet demand on
		# the next owner slice; do not strand a resident packet scene on the old
		# empty closure.
		_demand_revision += 1
	_prefetch_regions = _prefetch_regions_for_views()
	var now_usec := Time.get_ticks_usec()
	for region: Vector2i in _prefetch_regions:
		if not _prefetch_started_usec.has(region): _prefetch_started_usec[region]=now_usec
	_prefetch_rejected = _admission==null or not _admission.set_prefetch_regions(_prefetch_regions)
	var rectangles: Array[Rect2i] = _retained_region_bounds.duplicate()
	if _observer_region_bounds != Rect2i(): rectangles.append(_observer_region_bounds)
	# Original consumer discovery is an exact union of at most256 chunks; the
	# older explicit rectangle API remains bounded at64 rectangles. Never fill
	# gaps or truncate to the resident cap: pending sources remain retained.
	var region_bounds := {}
	for rectangle: Rect2i in rectangles:
		var low := Field.region_for_cell(rectangle.position)
		var high := Field.region_for_cell(rectangle.end-Vector2i.ONE)
		for z in range(low.y,high.y+1):
			for x in range(low.x,high.x+1):
				var region := Vector2i(x,z)
				if not region_bounds.has(region): region_bounds[region] = []
				if not region_bounds[region].has(rectangle): region_bounds[region].append(rectangle)
	for region: Vector2i in region_bounds:
		var candidate: Dictionary = Field.candidate_for_region(_seed,region)
		if candidate.is_empty(): continue
		var influence: Rect2i = Admission.declared_influence(candidate)
		var matching: Array[Rect2i] = []
		for rectangle: Rect2i in region_bounds[region]:
			if influence.intersects(rectangle): matching.append(rectangle)
		if matching.is_empty(): continue
		var source: Dictionary = _admission.source_state(region)
		# A retained gameplay window is durable physical demand.  Camera prefetch
		# may prepare a different, view-ranked region, but it must never be the
		# sole path that starts the exact region whose declared influence the
		# player now occupies.  Promotion happens through the existing admission
		# owner and is retained across later view reversals.
		if source.get("status") not in ["ready", "prepared"]:
			_admission.request_bounds(matching.front(), true)
			desired[region] = true
			continue
		if source.get("status") in ["ready","prepared"]:
			var intersects := false
			for rectangle: Rect2i in matching:
				if source.reservationCells.intersects(rectangle):
					intersects = true
					break
			if not intersects or not _current_binding(source.binding): continue
			# Conservative influence overlap starts/reuses source preparation.  The
			# player-facing demand clock begins only when the exact accepted
			# reservation enters an ordinary retained window.  Keeping these clocks
			# separate makes prefetch lead measurable instead of charging speculative
			# recipe time to visible publication latency.
			if not _demand_started_usec.has(region): _demand_started_usec[region]=now_usec
			ready[region] = source
			if source.status == "prepared" and not _prepared.has(region) and not _scenes.has(region) and not _region_retiring(region) and not _failures.has(region) \
					and (_inflight.is_empty() or _inflight.region != region):
				_admission.request_source(region,true)
		desired[region] = true
	# A completed speculative source can also prepare its compact publication
	# base while it is still ahead of the player.  It is deliberately not added
	# to desired: reversing the view removes it from ready on the next slice and
	# retires/cancels only this speculative publication work.  Exact observer or
	# retained-site overlap remains the sole start of player-facing demand time.
	for region: Vector2i in _prefetch_regions:
		if ready.has(region): continue
		var source: Dictionary = _admission.source_state(region)
		if source.get("status") == "ready" and _current_binding(source.binding):
			ready[region] = source
	_desired = desired
	return ready

func _current_binding(binding: Dictionary) -> bool:
	return int(binding.get("generation",-1)) == _generation \
		and String(_admission.stats().worldSeed) == _seed


## Select at most two deterministic candidate regions intersecting the current
## view corridor. Reversing before real demand cancels only speculative work;
## a promoted physical request remains owned by ordinary admission.
func _prefetch_regions_for_views() -> Array[Vector2i]:
	var rows: Array[Dictionary] = []
	var seen: Dictionary = {}
	for consumer: Dictionary in _retained_consumers:
		var view: Dictionary = ViewPriority.normalize(consumer.get("viewIntent",{}))
		if view.is_empty(): continue
		var origin: Vector3 = view.origin
		var forward: Vector3 = view.forward
		var finish := origin+forward*SOURCE_PREFETCH_LOOKAHEAD_METERS
		var low_cell := Vector2i(floori(minf(origin.x,finish.x)/SitePreparation.CELL),
			floori(minf(origin.z,finish.z)/SitePreparation.CELL))-Vector2i.ONE*SitePreparation.MAX_INFLUENCE_RADIUS_CELLS
		var high_cell := Vector2i(ceili(maxf(origin.x,finish.x)/SitePreparation.CELL),
			ceili(maxf(origin.z,finish.z)/SitePreparation.CELL))+Vector2i.ONE*SitePreparation.MAX_INFLUENCE_RADIUS_CELLS
		var low_region := Field.region_for_cell(low_cell)
		var high_region := Field.region_for_cell(high_cell)
		if (high_region.x-low_region.x+1)*(high_region.y-low_region.y+1)>16: continue
		for z: int in range(low_region.y,high_region.y+1):
			for x: int in range(low_region.x,high_region.x+1):
				var region := Vector2i(x,z)
				if seen.has(region): continue
				var candidate: Dictionary = Field.candidate_for_region(_seed,region)
				if candidate.is_empty(): continue
				var center_cell: Vector2i = candidate.centerCell
				var center := Vector3(float(center_cell.x)*SitePreparation.CELL,origin.y,float(center_cell.y)*SitePreparation.CELL)
				var delta := center-origin
				var depth := Vector3(delta.x,0.0,delta.z).dot(forward)
				if depth < -SOURCE_PREFETCH_LATERAL_METERS or depth > SOURCE_PREFETCH_LOOKAHEAD_METERS+SOURCE_PREFETCH_LATERAL_METERS: continue
				var closest := origin+forward*clampf(depth,0.0,SOURCE_PREFETCH_LOOKAHEAD_METERS)
				var lateral := Vector2(center.x-closest.x,center.z-closest.z).length()
				if lateral>SOURCE_PREFETCH_LATERAL_METERS: continue
				seen[region]=true
				rows.append({"region":region,"depth":maxf(0.0,depth),"lateral":lateral,"siteId":String(candidate.siteId)})
	rows.sort_custom(func(a: Dictionary,b: Dictionary):
		if not is_equal_approx(float(a.depth),float(b.depth)): return float(a.depth)<float(b.depth)
		if not is_equal_approx(float(a.lateral),float(b.lateral)): return float(a.lateral)<float(b.lateral)
		return String(a.siteId)<String(b.siteId))
	var result: Array[Vector2i] = []
	for row: Dictionary in rows:
		result.append(row.region)
		if result.size()>=Admission.MAX_PREFETCH_REGIONS: break
	return result

func _prune_unwanted(ready: Dictionary) -> void:
	for region: Vector2i in _navigation.keys():
		if not ready.has(region) or ready[region].binding != _navigation[region].binding:
			_retire(_navigation[region])
			_navigation.erase(region)
	for region: Vector2i in _packet_bootstrap_bases.keys():
		if not ready.has(region) or ready[region].binding != _packet_bootstrap_bases[region].binding:
			_retire(_packet_bootstrap_bases[region])
			_packet_bootstrap_bases.erase(region)
	for region: Vector2i in _described.keys():
		if not ready.has(region) or ready[region].binding != _described[region].binding:
			_retire_description(region)
	for region: Vector2i in _scenes.keys():
		# Ahead prefetch may retain the compact immutable description/base, but it
		# cannot pin live nodes, colliders, doors or interaction registrations once
		# exact retained demand expires. `_desired` includes coordinator hysteresis,
		# so ordinary reversals still keep the accepted scene for the grace window.
		if not _desired.has(region) or not ready.has(region) or ready[region].binding != _scenes[region].binding:
			_retire_scene(region)
	for region: Vector2i in _prepared.keys():
		# A scene-ready payload is heavier than the reusable speculative base and
		# owns callbacks that only exact demand may activate.
		if not _desired.has(region) or not ready.has(region) or ready[region].binding != _prepared[region].binding:
			_retire(_prepared[region])
			_prepared.erase(region)
	for region: Vector2i in _failures.keys():
		if not _desired.has(region) or ready.has(region) and ready[region].binding != _failures[region].binding:
			_failures.erase(region)
	if not _inflight.is_empty() and (not ready.has(_inflight.region) \
			or ready[_inflight.region].binding != _inflight.binding):
		_worker.cancel(int(_inflight.token))
		_inflight = {}

func _retire_description(region: Vector2i) -> void:
	if not _described.has(region): return
	_retire(_described[region])
	_described.erase(region)
	_description_serial += 1

func _prune_invalid_descriptions() -> void:
	for region: Vector2i in _described.keys():
		var entry: Dictionary = _described[region]
		var current: Dictionary = _admission.source_state(region) if _admission != null else {}
		if _closing or _world_reset_pending or _failures.has(region) or entry.configuration != _configuration_serial \
				or current.get("status") not in ["ready","prepared"] or current.get("binding",{}) != entry.binding \
				or not _current_binding(entry.binding):
			_retire_description(region)

func _collect_description(ready: Dictionary, allow_accept: bool) -> void:
	if _inflight.is_empty() or not allow_accept or _world_reset_pending: return
	var region: Vector2i = _inflight.region
	if _described.has(region): return
	var current: Dictionary = _admission.source_state(region)
	if not ready.has(region) or current.get("status") not in ["ready","prepared"] \
			or current.get("binding",{}) != _inflight.binding or not _current_binding(_inflight.binding): return
	var transfer: Dictionary = _worker.take_description(int(_inflight.token),current.binding)
	if transfer.get("status") != "described": return
	var profile: Dictionary = transfer.get("profile",{})
	var description = transfer.get("description")
	if description == null or description.binding != current.binding or profile.get("siteId") != current.binding.siteId \
			or profile.get("sourceSignature") != current.sourceSignature or profile.get("origin") != description.origin:
		_retire(transfer)
		return
	_description_serial += 1
	_described[region] = {"binding":current.binding,"profile":profile,"description":description,
		"configuration":_configuration_serial,"serial":_description_serial}

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
		_retire_description(region)
		_inflight = {}
		return
	var completion: Dictionary = _worker.take_result(token,current.binding)
	if completion.get("status") != "consumed": return
	var result: Dictionary = completion.get("result",{})
	if _inflight.get("kind")=="publication_base":
		_collect_publication_base(region,current,result)
		return
	if _inflight.get("kind")=="publication_base_navigation":
		_collect_publication_base_navigation(region,current,result)
		return
	if _inflight.get("kind")=="physical_group_packet":
		_collect_physical_group_packet(region,current,result,_inflight.get("transactionId",0))
		return
	if _inflight.get("kind", "preparation") == "navigation":
		_collect_navigation(region,current.binding,result,_inflight.get("tileKeys",[]),_inflight.get("tileOrder",[]))
		_inflight = {}
		return
	var prepared_description = result.prepared.describe(current.binding) if result.get("prepared")!=null else null
	var navigation_source: Dictionary = result.get("navigationSource",{})
	var navigation_matches: bool = navigation_source.is_read_only() and navigation_source.get("binding") is Dictionary \
		and navigation_source.binding.is_read_only() and navigation_source.binding==current.binding \
		and navigation_source.get("producer")!=null
	var domain_matches: bool = navigation_matches and _valid_navigation_domain(navigation_source.get("domain"))
	# Legacy preparation deliberately transfers the compact source description
	# before compiling dense navigation.  The completed PreparedSource therefore
	# owns a distinct descriptor object which shares the compact descriptor's
	# immutable source containers.  Require that provenance rather than object
	# identity, then replace the provisional descriptor below so scene startup
	# consumes the exact dense descriptor held by PreparedSource.
	var early_matches := true
	if _described.has(region):
		var early: Dictionary = _described[region]
		var early_description = early.get("description")
		early_matches = prepared_description!=null and early.get("binding",{})==current.binding and early.get("configuration",-1)==_configuration_serial \
			and early.get("profile",{}).get("sourceSignature","")==current.sourceSignature and early_description!=null \
			and early_description.binding==current.binding and early_description.origin==prepared_description.origin \
			and early_description.source_identity_digest.length()==64 \
			and early_description.source_identity_digest==prepared_description.source_identity_digest
	var description_matches: bool = prepared_description!=null and prepared_description.binding==current.binding \
		and prepared_description.origin==result.get("profile",{}).get("origin") \
		and prepared_description.source_identity_digest.length()==64 and early_matches
	if result.get("ready",false) and description_matches and navigation_matches and domain_matches and result.get("profile",{}).get("siteId") == current.binding.siteId \
			and result.profile.get("sourceSignature") == current.sourceSignature:
		_prepared[region] = {"binding":current.binding.duplicate(),"prepared":result.prepared,"profile":result.profile}
		_navigation[region] = {"binding":navigation_source.binding,"domain":navigation_source.domain,
			"navigationSource":navigation_source,"requested":{},"receipts":{},"activeTileKey":"","producerProgress":{}}
		if not _described.has(region):
			_description_serial += 1
			_described[region] = {"binding":current.binding,"profile":result.profile,"description":prepared_description,
				"configuration":_configuration_serial,"serial":_description_serial}
		else:
			# Keep the early descriptor's serial: its source revision has not changed.
			# Only its completed navigation representation is promoted.
			_described[region].profile = result.profile
			_described[region].description = prepared_description
		_accepted_count += 1
	else:
		_retire_description(region)
		_failures[region] = {"binding":current.binding.duplicate(),"reason":String(result.get("reason","building_preparation_failed"))}
		if result.get("ready",false):
			_failures[region].reason = "stale_prepared_description" if not description_matches else ("navigation_source_missing" if not navigation_matches else ("invalid_navigation_source_domain" if not domain_matches else "stale_prepared_profile"))
			_retire(result)
	_inflight = {}

func _packet_group_ids(binding: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for consumer: Dictionary in _retained_consumers:
		for site: Dictionary in consumer.sites:
			if site.binding!=binding: continue
			for id_value in site.groupIds:
				var id := String(id_value)
				if not id.is_empty() and not ids.has(id): ids.append(id)
	ids.sort()
	return ids

func _packet_requested_for_source(region: Vector2i, binding: Dictionary) -> bool:
	for consumer: Dictionary in _retained_consumers:
		for site: Dictionary in consumer.sites:
			if site.binding==binding and (not site.groupIds.is_empty() or not site.get("foregroundNavigationTileKeys",[]).is_empty()): return true
	return false

## A no-site retained source consumer is the coordinator's first pass before
## it has a description from which to derive group membership.  A view-prefetch
## source uses the same compact-base path, including the narrow frame where the
## ordinary observer has reached its reservation but retained membership has
## not caught up.  Legacy observer-only demand keeps its established lifecycle.
func _packet_bootstrap_requested_for_source(region: Vector2i, source: Dictionary) -> bool:
	var has_view_owner := false
	for consumer: Dictionary in _retained_consumers:
		if not ViewPriority.normalize(consumer.get("viewIntent",{})).is_empty():
			has_view_owner = true
			break
	if has_view_owner and (_prefetch_regions.has(region) or (_prefetch_started_usec.has(region) \
			and _observer_region_bounds.has_area() and source.get("reservationCells") is Rect2i \
			and source.reservationCells.intersects(_observer_region_bounds))): return true
	for consumer: Dictionary in _retained_consumers:
		if not consumer.sites.is_empty(): continue
		if source.reservationCells.intersects(consumer.bounds): return true
	return false

func _retain_packet_bootstrap_base(region: Vector2i, current: Dictionary, base, profile: Dictionary) -> void:
	# Keep the worker's original frozen profile.  The base's internal deep copy
	# deliberately owns only source reconstruction data and does not retain the
	# nested frozen-array contract required by scene admission.
	var immutable_profile: Dictionary = profile
	if not immutable_profile.is_read_only(): return
	_packet_bootstrap_bases[region] = {"binding":current.binding.duplicate(),"base":base,"profile":immutable_profile,
		"configuration":_configuration_serial}
	var description = base.description
	if description==null or description.binding!=current.binding or description.origin!=immutable_profile.get("origin"):
		_retire(_packet_bootstrap_bases[region])
		_packet_bootstrap_bases.erase(region)
		return
	if not _described.has(region):
		_description_serial += 1
		_described[region] = {"binding":current.binding.duplicate(),"profile":immutable_profile,"description":description,
			"configuration":_configuration_serial,"serial":_description_serial}

func _packet_foreground_plan(region: Vector2i, binding: Dictionary, description, base = null,
		completed: Dictionary = {}, include_view_progress := true) -> Dictionary:
	if description==null or description.binding!=binding or not description.publication_groups.get("ready",false):
		return {"status":"pending","reason":"packet_foreground_description_pending"}
	var foreground: Dictionary = {}
	var blocked: Dictionary = {}
	var requests: Array[Dictionary] = []
	var boundary_groups: Dictionary = {}
	var census: Dictionary = base.packet_eligibility if base!=null else {}
	var compact_plan = base.publication_plan if base!=null else null
	if base!=null and census.is_empty():
		census=Preparation.classify_physical_group_packet_eligibility(description.publication_groups,base.building_source,base.furnishing_source)
	var consumers: Array = _retained_consumers.duplicate()
	# The foreground observer is a real owner of immediate loading work, even
	# before the streaming coordinator has rebuilt a retained source-members
	# record after admission.  Describe its exact source closure here; this is
	# scheduling input only.  Packet compilation, scene installation and fresh
	# collision validation remain below this boundary.
	var observer_owned_by_consumer := false
	for retained_consumer: Dictionary in consumers:
		if not retained_consumer.get("bounds") is Rect2i or not retained_consumer.bounds.encloses(_observer_region_bounds): continue
		for retained_site: Dictionary in retained_consumer.sites:
			if retained_site.get("binding",{})==binding and retained_site.has("foregroundGroupIds"):
				observer_owned_by_consumer=true
				break
		if observer_owned_by_consumer: break
	var observer_source: Dictionary = _admission.source_state(region) if _admission!=null else {}
	if not observer_owned_by_consumer and _observer_region_bounds.has_area() and observer_source.get("binding",{})==binding \
			and observer_source.get("reservationCells") is Rect2i and observer_source.reservationCells.intersects(_observer_region_bounds):
		var observer_requirements: Dictionary = compact_plan.physical_group_requirements(_observer_region_bounds) \
			if compact_plan!=null else description.physical_group_requirements(_observer_region_bounds)
		if observer_requirements.get("status")!="described":
			return {"status":observer_requirements.get("status","pending"),"reason":observer_requirements.get("reason","packet_observer_description_pending")}
		consumers.append({"ownerId":"observer:%d,%d,%d,%d" % [_observer_region_bounds.position.x,_observer_region_bounds.position.y,
			_observer_region_bounds.size.x,_observer_region_bounds.size.y],"bounds":_observer_region_bounds,"priority":0,
			"sites":[{"binding":binding,"groupIds":observer_requirements.get("groupIds",[]),
			"foregroundGroupIds":observer_requirements.get("groupIds",[])}]})
	var owner_closure_started := Time.get_ticks_usec()
	var owner_group_ids := 0
	var door_lifecycle_available := _door_callbacks_ready()
	var owner_identity := _packet_owner_demand_identity(consumers,binding,door_lifecycle_available)
	var scene_entry: Dictionary = _scenes.get(region,{})
	var owner_cache: Dictionary = scene_entry.get("packetOwnerPlanCache",{})
	if owner_cache.get("binding",{})==binding and owner_cache.get("identity",[])==owner_identity:
		requests=owner_cache.requests
		blocked=owner_cache.blocked
		boundary_groups=owner_cache.boundaryGroups
		owner_group_ids=int(owner_cache.groupCount)
	else:
		var owner_result: Dictionary = _build_packet_owner_demand(region,binding,description,base,census,
			compact_plan,consumers,door_lifecycle_available)
		if owner_result.get("status")!="ready": return owner_result
		requests=owner_result.requests
		blocked=owner_result.blocked
		boundary_groups=owner_result.boundaryGroups
		owner_group_ids=int(owner_result.groupCount)
		if not scene_entry.is_empty():
			scene_entry["packetOwnerPlanCache"]={"binding":binding,"identity":owner_identity,
				"requests":requests,"blocked":blocked,"boundaryGroups":boundary_groups,"groupCount":owner_group_ids}
	_record_scene_unit("demand_owner_closure",owner_closure_started,owner_group_ids)
	var view_window_started := Time.get_ticks_usec()
	var window: Dictionary = _bounded_packet_view_window(description,base,census,consumers,requests,completed,include_view_progress)
	_record_scene_unit("demand_view_window_total",view_window_started,description.publication_groups.groups.size())
	if window.get("status")!="ready": return window
	var blocked_ids: Array[String] = []
	for id: String in blocked:
		blocked_ids.append(id)
	blocked_ids.sort()
	var boundary_ids: Array = boundary_groups.keys()
	boundary_ids.sort()
	for id: String in window.get("blockedGroupIds",[]):
		if not blocked_ids.has(id): blocked_ids.append(id)
	blocked_ids.sort()
	var explicit_deferred: Array[String] = []
	for id: String in window.deferredGroupIds: explicit_deferred.append(id)
	for id: String in blocked_ids:
		if not explicit_deferred.has(id): explicit_deferred.append(id)
	explicit_deferred.sort()
	return {"status":"ready","requests":window.requests,"deferredGroupIds":explicit_deferred,
		"foregroundGroupIds":window.foregroundGroupIds,"readinessGroupIds":window.readinessGroupIds,
		"viewPrioritizedGroupIds":window.viewPrioritizedGroupIds,
		"portalGroupIds":window.portalGroupIds,"blockedGroupIds":blocked_ids,"boundaryGroupIds":boundary_ids,
		"firstUsefulGroupIds":window.get("firstUsefulGroupIds",[]),
		"firstUsefulHomeIds":window.get("firstUsefulHomeIds",[]),
		"firstUsefulDoorGroupId":window.get("firstUsefulDoorGroupId",""),
		"firstUsefulStructuralGroupIds":window.get("firstUsefulStructuralGroupIds",[]),
		"courtyardGroupIds":window.get("courtyardGroupIds",[]),
		"deferredGroupCount":window.get("deferredGroupCount",window.deferredGroupIds.size()),
		"implicitDeferred":window.get("implicitDeferred",false),
		"candidateCount":window.get("candidateCount",description.publication_groups.groups.size()),
		"censusReady":census.get("ready",base==null),"rollingWindow":true}


static func _packet_owner_demand_identity(consumers: Array, binding: Dictionary,
		door_lifecycle_available: bool) -> Array:
	var result: Array = [binding,door_lifecycle_available]
	for consumer: Dictionary in consumers:
		for site: Dictionary in consumer.sites:
			if site.get("binding",{})!=binding: continue
			result.append([consumer.get("ownerId"),consumer.get("priority"),consumer.get("bounds"),
				site.get("groupIds",[]),site.get("foregroundGroupIds",null),
				site.get("foregroundNavigationTileKeys",[])])
	return result


func _build_packet_owner_demand(region: Vector2i, binding: Dictionary, description, base,
		census: Dictionary, compact_plan, consumers: Array, door_lifecycle_available: bool) -> Dictionary:
	var requests: Array[Dictionary] = []
	var blocked: Dictionary = {}
	var boundary_groups: Dictionary = {}
	var owner_group_ids := 0
	for consumer: Dictionary in consumers:
		for site: Dictionary in consumer.sites:
			if site.binding!=binding: continue
			var ids: Dictionary = {}
			var dependency_complete := site.has("foregroundGroupIds")
			var trusted_foreground: bool = compact_plan!=null and door_lifecycle_available \
				and String(site.get("foregroundPlanSignature",""))==String(compact_plan.output_signature) \
				and site.get("foregroundGroupIds",[]).size()>0
			if trusted_foreground:
				requests.append({"ownerId":"region:%s" % str(consumer.ownerId),
					"groupIds":site.foregroundGroupIds,"priority":consumer.priority,"dependencyComplete":true})
				owner_group_ids+=site.foregroundGroupIds.size()
				continue
			if site.has("foregroundGroupIds"):
				if site.foregroundGroupIds.is_empty():
					var boundary: Dictionary = _packet_exterior_boundary_requirements(region,binding,description,consumer,census,compact_plan)
					if boundary.get("status") not in ["described","pending"]:
						return {"status":boundary.get("status","failed"),"reason":boundary.get("reason","packet_exterior_boundary_failed")}
					if boundary.get("status")=="described":
						for id: String in boundary.get("groupIds",[]): ids[id]=true
						if not String(boundary.get("boundaryGroupId","")).is_empty(): boundary_groups[String(boundary.boundaryGroupId)]=true
			else:
				var foreground_tiles: Array = site.get("foregroundNavigationTileKeys",[])
				if foreground_tiles.is_empty():
					for id: String in site.groupIds: ids[id]=true
				else:
					dependency_complete=true
					for key: String in foreground_tiles:
						var coordinates: PackedStringArray = key.split(",",true)
						if coordinates.size()!=2: return {"status":"failed","reason":"invalid_packet_foreground_tile"}
						var tile := Vector2i(int(coordinates[0]),int(coordinates[1]))
						var tile_bounds := Rect2i(tile*NAVIGATION_TILE_CELLS,Vector2i.ONE*NAVIGATION_TILE_CELLS)
						var requirements: Dictionary = compact_plan.physical_group_requirements(tile_bounds) \
							if compact_plan!=null else description.physical_group_requirements(tile_bounds)
						if requirements.get("status")!="described":
							return {"status":requirements.get("status","pending"),"reason":requirements.get("reason","packet_foreground_description_pending")}
						for id: String in requirements.get("groupIds",[]): ids[id]=true
					if ids.is_empty():
						var boundary: Dictionary = _packet_exterior_boundary_requirements(region,binding,description,consumer,census,compact_plan)
						if boundary.get("status") not in ["described","pending"]:
							return {"status":boundary.get("status","failed"),"reason":boundary.get("reason","packet_exterior_boundary_failed")}
						if boundary.get("status")=="described":
							for id: String in boundary.get("groupIds",[]): ids[id]=true
							if not String(boundary.get("boundaryGroupId","")).is_empty(): boundary_groups[String(boundary.boundaryGroupId)]=true
			var ordered: Array[String] = []
			if site.has("foregroundGroupIds") and not site.foregroundGroupIds.is_empty():
				for id: String in site.foregroundGroupIds: ordered.append(id)
			if ordered.is_empty():
				for id: String in ids: ordered.append(id)
				ordered.sort()
			var publishable: Array[String] = []
			for id: String in ordered:
				if not description.publication_groups.groups.has(id):
					return {"status":"failed","reason":"packet_foreground_group_unknown","groupId":id}
				var eligible := false
				if base!=null and census.get("ready",false):
					if compact_plan!=null:
						eligible=compact_plan.eligible_group_ids.has(id) \
							and (description.publication_groups.groups[id].get("doorPartIds",[]).is_empty() or door_lifecycle_available)
					else: eligible=_packet_group_publishable(description,census,id)
				if base==null or eligible: publishable.append(id)
				else: blocked[id]=true
			if not publishable.is_empty():
				requests.append({"ownerId":"region:%s" % str(consumer.ownerId),"groupIds":publishable,
					"priority":consumer.priority,"dependencyComplete":dependency_complete})
			owner_group_ids+=publishable.size()
	return {"status":"ready","requests":requests,"blocked":blocked,
		"boundaryGroups":boundary_groups,"groupCount":owner_group_ids}

## Select one bounded, dependency-complete publication window. Completed groups
## make room for the next window, so a retained city eventually finishes while
## the current view controls which unfinished work advances first.
func _bounded_packet_view_window(description, base, census: Dictionary, consumers: Array,
		base_requests: Array, completed: Dictionary, include_view_progress := true) -> Dictionary:
	var groups: Dictionary = description.publication_groups.groups
	var compact_plan = base.publication_plan if base!=null else null
	var candidates: Dictionary = {}
	var readiness: Dictionary = {}
	for request: Dictionary in base_requests:
		for id: String in request.groupIds:
			# A retained exact closure describes everything the consumer still
			# owns, including groups whose revision-matched physical receipts are
			# already installed.  Completed groups must remain acknowledged but do
			# not consume the next packet's bounded foreground capacity.  Counting
			# them here made dense civic tiles eventually reject their own progress
			# as an oversized request after hundreds of groups had completed.
			if completed.has(id): continue
			candidates[id] = {"id":id,"priority":int(request.priority),"distanceSquared":0.0,"portal":false,"throughPortal":false}
			# Exact member/tile queries already return a complete immutable
			# dependency closure. Do not traverse all of those same closures again
			# merely to label the gameplay-readiness subset.
			if bool(request.get("dependencyComplete",false)): readiness[id]=true
	var first_useful_started := Time.get_ticks_usec()
	var has_view_intent := include_view_progress \
		and consumers.any(func(consumer: Dictionary): return not consumer.get("viewIntent",{}).is_empty())
	var useful: Dictionary = _first_useful_packet_groups(description,base,census,completed,compact_plan) if has_view_intent \
		else {"status":"ready","groupIds":[],"homeIds":[],"doorGroupId":"","structuralGroupIds":[]}
	_record_scene_unit("demand_first_useful",first_useful_started,groups.size())
	if useful.get("status")!="ready": return useful
	for id: String in useful.get("groupIds",[]):
		if not candidates.has(id):
			candidates[id]={"id":id,"priority":0,"distanceSquared":0.0,"portal":false,"throughPortal":false}
	# Only explicit spatial/tile owners gate gameplay readiness. Camera-ranked
	# neighbours remain background presentation work and cannot hold the player
	# until a rolling city window (or the whole source) is installed.
	var readiness_started := Time.get_ticks_usec()
	for id: String in candidates:
		if readiness.has(id): continue
		var readiness_closure: Dictionary = _packet_dependency_window_for_plan(compact_plan,groups,id,completed)
		if readiness_closure.get("status")!="ready": return readiness_closure
		for required_id: String in readiness_closure.groupIds: readiness[required_id]=true
	_record_scene_unit("demand_readiness_closure",readiness_started,candidates.size())
	var view_rank_started := Time.get_ticks_usec()
	var ranked_group_rows := 0
	var ranked_view_keys: Dictionary = {}
	for consumer: Dictionary in consumers:
		if not include_view_progress: break
		var view: Dictionary = ViewPriority.normalize(consumer.get("viewIntent",{}))
		if view.is_empty(): continue
		var view_key := JSON.stringify([view.origin,view.forward,view.predictedOrigin,
			view.horizontalFovDegrees,view.farDistance])
		if ranked_view_keys.has(view_key): continue
		ranked_view_keys[view_key]=true
		var ranked_result: Dictionary = compact_plan.ranked_groups(view,completed) if compact_plan!=null \
			else {"status":"ready","rows":ViewPriority.ranked_groups(groups,view),"candidateCount":groups.size()}
		if ranked_result.get("status")!="ready": return ranked_result
		var ranked: Array[Dictionary] = ranked_result.rows
		ranked_group_rows += ranked.size()
		for row: Dictionary in ranked:
			var id := String(row.id)
			var current: Dictionary = candidates.get(id,{})
			if current.is_empty() or int(row.priority)<int(current.priority) \
					or int(row.priority)==int(current.priority) and float(row.distanceSquared)<float(current.distanceSquared):
				candidates[id]=row.duplicate(true)
	_record_scene_unit("demand_view_rank_and_merge",view_rank_started,ranked_group_rows)
	# Legacy/direct owners without a camera retain their exact source request.
	# A rolling city window exists only when a gameplay consumer supplies view
	# intent; this keeps background tools and navigation-only requests narrow.
	var ordered: Array[Dictionary] = []
	for row: Dictionary in candidates.values():
		# Exact member/semantic readiness is already seeded below in stable ID
		# order.  Sorting those rows again made the first cold view refresh scale
		# with its full dependency closure; only optional ranked rows need ranking.
		if not completed.has(String(row.id)) and not readiness.has(String(row.id)): ordered.append(row)
	var candidate_sort_started := Time.get_ticks_usec()
	ordered.sort_custom(func(a: Dictionary,b: Dictionary):
		if int(a.priority)!=int(b.priority): return int(a.priority)<int(b.priority)
		if not is_equal_approx(float(a.distanceSquared),float(b.distanceSquared)):
			return float(a.distanceSquared)<float(b.distanceSquared)
		return String(a.id)<String(b.id))
	_record_scene_unit("demand_candidate_sort",candidate_sort_started,ordered.size())
	# Exact spatial/semantic readiness is mandatory, not part of the optional
	# presentation-window quota. Seed its complete dependency closure first;
	# ranked view rows then fill only the remaining bounded capacity.
	if readiness.size()>MAX_REQUIRED_FOREGROUND_GROUPS:
		return {"status":"failed","reason":"packet_required_foreground_scope_too_large","groupCount":readiness.size()}
	var selected: Dictionary = readiness.duplicate()
	var selected_priority: Dictionary = {}
	var selected_order: Array[String] = []
	for id: String in selected: selected_order.append(id)
	selected_order.sort()
	for id: String in selected_order: selected_priority[id]=0
	var view_ids: Array[String] = []
	var portal_ids: Array[String] = []
	var blocked: Dictionary = {}
	var selection_started := Time.get_ticks_usec()
	var selection_rows := 0
	for row: Dictionary in ordered:
		selection_rows += 1
		var id := String(row.id)
		if not groups.has(id): return {"status":"failed","reason":"packet_foreground_group_unknown","groupId":id}
		var closure: Dictionary = _packet_dependency_window_for_plan(compact_plan,groups,id,completed)
		if closure.get("status")!="ready": return closure
		var eligible: bool = base==null or compact_plan!=null and compact_plan.publication_closure_eligible(id,_door_callbacks_ready())
		if base!=null and compact_plan==null:
			eligible=true
			for required_id: String in closure.groupIds:
				if not _packet_group_publishable(description,census,required_id): eligible=false
		if not eligible:
			for required_id: String in closure.groupIds:
				if not _packet_group_publishable_from_plan(description,census,required_id,compact_plan): blocked[required_id]=true
		if not eligible: continue
		var additions := 0
		for required_id: String in closure.groupIds:
			if not selected.has(required_id): additions+=1
		if selected.size()+additions>maxi(MAX_INCREMENTAL_FOREGROUND_GROUPS,readiness.size()): continue
		for required_id: String in closure.groupIds:
			if not selected.has(required_id): selected_order.append(required_id)
			selected[required_id]=true
			selected_priority[required_id]=mini(int(selected_priority.get(required_id,row.priority)),int(row.priority))
		if int(row.priority)<4: view_ids.append(id)
		if bool(row.get("portal",false)) or bool(row.get("throughPortal",false)): portal_ids.append(id)
		# Do not scan thousands of lower-ranked closures trying to fill the final
		# few slots. This still publishes a substantial bounded window and the
		# retained job selects another window after acknowledgement.
		if selected.size()>=maxi(readiness.size(),VIEW_WINDOW_PROGRESS_TARGET_GROUPS): break
	_record_scene_unit("demand_selection_closure",selection_started,selection_rows)
	var result_started := Time.get_ticks_usec()
	var by_priority: Dictionary = {}
	for id: String in selected_order:
		var priority := int(selected_priority[id])
		if not by_priority.has(priority): by_priority[priority]=[]
		by_priority[priority].append(id)
	var requests: Array[Dictionary] = []
	for priority: int in range(5):
		if by_priority.has(priority):
			requests.append({"ownerId":"view-window:%d" % priority,"groupIds":by_priority[priority],"priority":priority})
	var deferred: Array[String] = []
	var deferred_count := groups.size()-completed.size()-selected.size()
	if compact_plan==null:
		for id: String in groups:
			if not completed.has(id) and not selected.has(id): deferred.append(id)
		deferred.sort()
		deferred_count=deferred.size()
	view_ids = _unique_sorted_strings(view_ids)
	portal_ids = _unique_sorted_strings(portal_ids)
	var blocked_ids: Array = blocked.keys()
	blocked_ids.sort()
	if compact_plan!=null:
		deferred.clear()
		for id: String in blocked_ids: deferred.append(id)
	var readiness_ids: Array[String] = []
	for id: String in readiness: readiness_ids.append(id)
	readiness_ids.sort()
	_record_scene_unit("demand_result_assembly",result_started,ranked_group_rows)
	return {"status":"ready","requests":requests,"foregroundGroupIds":selected_order,
		"readinessGroupIds":readiness_ids,
		"firstUsefulGroupIds":useful.get("groupIds",[]),
		"firstUsefulHomeIds":useful.get("homeIds",[]),"firstUsefulDoorGroupId":useful.get("doorGroupId",""),
		"firstUsefulStructuralGroupIds":useful.get("structuralGroupIds",[]),
		"courtyardGroupIds":useful.get("courtyardGroupIds",[]),
		"deferredGroupIds":deferred,"deferredGroupCount":deferred_count,"implicitDeferred":compact_plan!=null,
		"candidateCount":ranked_group_rows,"viewPrioritizedGroupIds":view_ids,"portalGroupIds":portal_ids,"blockedGroupIds":blocked_ids}

## Choose semantic first-content anchors from immutable generated source data.
## This is not seed/name choreography: every qualifying Citadel contributes the
## first two complete home furnishing sets, one publishable door closure and a
## real stair/landing support.  The latter keeps first-useful readiness honest:
## a visually useful packet must also expose a live player-capsule clearance
## witness rather than declaring readiness from furniture and one door alone.
func _first_useful_packet_groups(description, base, census: Dictionary, completed: Dictionary, compact_plan = null) -> Dictionary:
	if base==null: return {"status":"ready","groupIds":[],"homeIds":[],"doorGroupId":"","structuralGroupIds":[]}
	if compact_plan==null: compact_plan=base.publication_plan
	if compact_plan!=null:
		if compact_plan.selected_first_useful_structural_group_ids.is_empty():
			return {"status":"failed","reason":"first_useful_structural_group_missing"}
		var roots: Array[String] = []
		for group_id: String in compact_plan.selected_first_useful_home_group_ids: roots.append(group_id)
		for group_id: String in compact_plan.selected_first_useful_structural_group_ids:
			if not roots.has(group_id): roots.append(group_id)
		for group_id: String in compact_plan.selected_courtyard_group_ids:
			if not roots.has(group_id): roots.append(group_id)
		var door_group_id: String = compact_plan.selected_first_useful_door_group_id if _door_callbacks_ready() else ""
		if not door_group_id.is_empty() and not roots.has(door_group_id): roots.append(door_group_id)
		roots.sort()
		return {"status":"ready","groupIds":roots,
			"homeIds":compact_plan.selected_first_useful_home_ids,
			"doorGroupId":door_group_id,
			"structuralGroupIds":compact_plan.selected_first_useful_structural_group_ids,
			"courtyardGroupIds":compact_plan.selected_courtyard_group_ids}
	var groups: Dictionary = description.publication_groups.get("groups",{})
	var by_part: Dictionary = description.publication_groups.get("groupByPart",{})
	var homes: Dictionary = {}
	if compact_plan!=null:
		homes=compact_plan.first_useful_homes
	else:
		var furnishing_source: Dictionary = base.furnishing_source
		var furnishing_parts: Variant = furnishing_source.get("parts",[])
		if not furnishing_parts is Array: return {"status":"failed","reason":"invalid_first_useful_furnishing_source"}
		for raw_part in furnishing_parts:
			if not raw_part is Dictionary: continue
			var part: Dictionary = raw_part
			var recipe: Variant = part.get("recipe",{})
			if not recipe is Dictionary: continue
			var home_id := String(recipe.get("citadelUrbanHomeId",""))
			var archetype := String(part.get("archetype",""))
			var member_id := "furnishing:"+String(part.get("id",""))
			if home_id.is_empty() or archetype not in FIRST_USEFUL_HOME_ARCHETYPES or not by_part.has(member_id): continue
			var group_id := String(by_part[member_id])
			if not _packet_group_closure_publishable(description,census,group_id,completed,compact_plan): continue
			if not homes.has(home_id): homes[home_id]={}
			if not homes[home_id].has(archetype): homes[home_id][archetype]=group_id
	var selected: Dictionary = {}
	var selected_homes: Array[String] = []
	var home_ids: Array = compact_plan.first_useful_home_ids if compact_plan!=null else homes.keys()
	if compact_plan==null: home_ids.sort()
	for home_id_value in home_ids:
		var home_id := String(home_id_value)
		var archetypes: Dictionary = homes[home_id]
		if not FIRST_USEFUL_HOME_ARCHETYPES.all(func(value: String): return archetypes.has(value)): continue
		var home_publishable := true
		for archetype: String in FIRST_USEFUL_HOME_ARCHETYPES:
			if not _packet_group_closure_publishable(description,census,String(archetypes[archetype]),completed,compact_plan): home_publishable=false
		if not home_publishable: continue
		for archetype: String in FIRST_USEFUL_HOME_ARCHETYPES: selected[String(archetypes[archetype])]=true
		selected_homes.append(home_id)
		if selected_homes.size()>=FIRST_USEFUL_HOME_COUNT: break
	var door_group_id := ""
	var ordered_group_ids: Array = compact_plan.door_group_ids if compact_plan!=null else groups.keys()
	if compact_plan==null: ordered_group_ids.sort()
	for group_id_value in ordered_group_ids:
		var group_id := String(group_id_value)
		if groups[group_id].get("doorPartIds",[]).is_empty(): continue
		if _packet_group_closure_publishable(description,census,group_id,completed,compact_plan):
			door_group_id=group_id
			selected[group_id]=true
			break
	var structural_candidates: Dictionary = {}
	if compact_plan!=null:
		for group_id: String in compact_plan.first_useful_structural_group_ids:
			if _packet_group_closure_publishable(description,census,group_id,completed,compact_plan): structural_candidates[group_id]=true
	else:
		var building_parts: Variant = base.building_source.get("parts",[])
		if not building_parts is Array: return {"status":"failed","reason":"invalid_first_useful_building_source"}
		for raw_part in building_parts:
			if not raw_part is Dictionary: continue
			var part: Dictionary = raw_part
			if String(part.get("semantic","")) not in FIRST_USEFUL_STRUCTURAL_SEMANTICS: continue
			var member_id := "building:"+String(part.get("id",""))
			if not by_part.has(member_id): continue
			var group_id := String(by_part[member_id])
			if not _packet_group_closure_publishable(description,census,group_id,completed,compact_plan): continue
			structural_candidates[group_id]=true
	if structural_candidates.is_empty():
		return {"status":"failed","reason":"first_useful_structural_group_missing"}
	var structural_candidate_ids: Array = structural_candidates.keys()
	structural_candidate_ids.sort()
	var structural_group_id := String(structural_candidate_ids[0])
	selected[structural_group_id]=true
	var selected_ids: Array[String] = []
	for group_id: String in selected: selected_ids.append(group_id)
	selected_ids.sort()
	return {"status":"ready","groupIds":selected_ids,"homeIds":selected_homes,"doorGroupId":door_group_id,
		"structuralGroupIds":[structural_group_id]}

func _packet_group_closure_publishable(description, census: Dictionary, group_id: String, completed: Dictionary, compact_plan = null) -> bool:
	if compact_plan!=null: return compact_plan.publication_closure_eligible(group_id,_door_callbacks_ready())
	var closure: Dictionary = _packet_dependency_window_for_plan(compact_plan,description.publication_groups.groups,group_id,completed)
	if closure.get("status")!="ready": return false
	for required_id: String in closure.groupIds:
		if not _packet_group_publishable_from_plan(description,census,required_id,compact_plan): return false
	return true

static func _unique_sorted_strings(values: Array[String]) -> Array[String]:
	var seen: Dictionary = {}
	for value: String in values: seen[value]=true
	var result: Array[String] = []
	for value: String in seen: result.append(value)
	result.sort()
	return result

static func _packet_dependency_window(groups: Dictionary, first_id: String, completed: Dictionary) -> Dictionary:
	var visiting: Dictionary = {}
	var ordered: Array[String] = []
	var stack: Array = [[first_id,false]]
	while not stack.is_empty():
		var frame: Array = stack.pop_back()
		var id := String(frame[0])
		if completed.has(id): continue
		if not groups.has(id): return {"status":"failed","reason":"publication_group_dependency_missing","groupId":id}
		if bool(frame[1]):
			visiting[id]=2
			if not ordered.has(id): ordered.append(id)
			continue
		if int(visiting.get(id,0))==2: continue
		if int(visiting.get(id,0))==1: return {"status":"failed","reason":"publication_group_dependency_cycle","groupId":id}
		visiting[id]=1
		stack.append([id,true])
		var dependencies: Array = groups[id].get("dependencies",[]).duplicate()
		dependencies.sort()
		dependencies.reverse()
		for dependency in dependencies: stack.append([String(dependency),false])
	return {"status":"ready","groupIds":ordered}


static func _packet_dependency_window_for_plan(compact_plan, groups: Dictionary, first_id: String, completed: Dictionary) -> Dictionary:
	return compact_plan.dependency_window(first_id,completed) if compact_plan!=null \
		else _packet_dependency_window(groups,first_id,completed)

func _packet_group_publishable(description, census: Dictionary, group_id: String) -> bool:
	if not bool(census.get("groups",{}).get(group_id,{}).get("eligible",false)):
		return false
	var group: Dictionary = description.publication_groups.get("groups",{}).get(group_id,{})
	# The frozen compiler can describe a door, but it cannot create the ordinary
	# portal lifecycle.  Keep that packet demand retained until the scene owner
	# has supplied both callbacks instead of dispatching work that must fail at
	# installation.
	return group.get("doorPartIds",[]).is_empty() or _door_callbacks_ready()


func _packet_group_publishable_from_plan(description, census: Dictionary, group_id: String, compact_plan = null) -> bool:
	if compact_plan==null: return _packet_group_publishable(description,census,group_id)
	if not compact_plan.eligible_group_ids.has(group_id): return false
	var group: Dictionary = description.publication_groups.get("groups",{}).get(group_id,{})
	return group.get("doorPartIds",[]).is_empty() or _door_callbacks_ready()

## The source reservation is a conservative physical-safety envelope.  When a
## retained consumer already intersects it but has no tile-owned group, request
## the nearest declared structural closure rather than asking the player to
## enter an unpublished collision area.  This only selects immutable source
## membership; `BuildingScenePublicationJob` still validates and acknowledges
## the physical packet when it is installed.
func _packet_exterior_boundary_requirements(region: Vector2i, binding: Dictionary, description, consumer: Dictionary,
		census: Dictionary, compact_plan = null) -> Dictionary:
	if _admission==null or not consumer.get("bounds") is Rect2i:
		return {"status":"pending","reason":"packet_exterior_source_pending"}
	var source: Dictionary = _admission.source_state(region)
	if source.get("binding",{})!=binding or not source.get("reservationCells") is Rect2i:
		return {"status":"pending","reason":"packet_exterior_source_pending"}
	var reservation: Rect2i = source.reservationCells
	if not reservation.intersects(consumer.bounds):
		return {"status":"described","groupIds":[]}
	if compact_plan!=null:
		var indexed: Dictionary = compact_plan.exterior_structural_group_requirements(consumer.bounds)
		if indexed.get("status")=="described":
			for group_id: String in indexed.get("groupIds",[]):
				if not _packet_group_publishable_from_plan(description,census,group_id,compact_plan):
					return {"status":"pending","reason":"exterior_structural_group_unavailable"}
		return indexed
	var eligible: Dictionary = {}
	if census.get("ready",false):
		for group_id: String in census.get("groups",{}):
			if _packet_group_publishable(description,census,group_id): eligible[group_id] = true
	return description.exterior_structural_group_requirements(consumer.bounds,eligible)

func _base_packet_eligible(base, binding: Dictionary, region: Vector2i) -> Dictionary:
	if base==null or not base.matches(binding): return {"status":"failed","reason":"packet_publication_base_stale"}
	var plan: Dictionary = _packet_foreground_plan(region,binding,base.description,base)
	if plan.get("status")!="ready": return plan
	if not plan.get("censusReady",false): return {"status":"failed","reason":"packet_foreground_census_missing"}
	if plan.get("readinessGroupIds",[]).size()>MAX_REQUIRED_FOREGROUND_GROUPS:
		return {"status":"failed","reason":"packet_required_foreground_scope_too_large","groupCount":plan.readinessGroupIds.size()}
	return plan

func _collect_publication_base(region: Vector2i, current: Dictionary, result: Dictionary) -> void:
	var base = result.get("base")
	if result.get("ready",false) and base!=null and _packet_bootstrap_requested_for_source(region,current):
		_retain_packet_bootstrap_base(region,current,base,result.get("profile",{}))
		if _packet_bootstrap_bases.has(region):
			_accepted_count += 1
			_inflight = {}
			return
	var packet_plan: Dictionary = _base_packet_eligible(base,current.binding,region) if result.get("ready",false) and base!=null else {}
	if not result.get("ready",false) or base==null or packet_plan.get("status")!="ready":
		if base!=null:
			_retain_packet_bootstrap_base(region,current,base,result.get("profile",{}))
		if packet_plan.get("status")=="failed":
			_failures[region]={"binding":current.binding.duplicate(),"reason":String(packet_plan.get("reason","packet_publication_plan_failed"))}
		_inflight={}
		return
	# A packet base is sufficient to start the foreground physical scene.  Do
	# not construct its dense navigation producer here: that previously let a
	# retained 64m navigation closure consume the only worker before the player
	# could receive the physical collision packet at their capsule.
	_prepared[region]={"binding":current.binding.duplicate(),"base":base,"profile":result.get("profile",{}),"packetMode":true}
	_packet_bootstrap_bases.erase(region)
	_accepted_count+=1
	_inflight={}

func _collect_publication_base_navigation(region: Vector2i, current: Dictionary, result: Dictionary) -> void:
	var base = _inflight.get("base")
	var source: Dictionary = result.get("navigationSource",{})
	if base==null or not result.get("ready",false) or not source.is_read_only() or source.get("binding",{})!=current.binding:
		_retire({"base":base,"navigation":source}); _inflight={}; return
	_navigation[region]={"binding":current.binding,"domain":source.get("domain"),"navigationSource":source,"requested":{},"receipts":{},"activeTileKey":"","producerProgress":{}}
	_prepared[region]={"binding":current.binding.duplicate(),"base":base,"profile":_inflight.get("profile",{}),"packetMode":true}
	_packet_bootstrap_bases.erase(region)
	_accepted_count+=1
	_inflight={}

func _collect_physical_group_packet(region: Vector2i, current: Dictionary, result: Dictionary, transaction_id: int) -> void:
	_inflight={}
	if not _scenes.has(region) or _scenes[region].binding!=current.binding or not result.get("ready",false):
		_retire(result); return
	var entry: Dictionary = _scenes[region]
	var packet = result.get("packet")
	var offered: Dictionary = entry.job.offer_physical_group_packet(packet,current.binding)
	if offered.get("status")!="retained":
		_failures[region]={"binding":current.binding,"reason":String(offered.get("reason","physical_packet_offer_failed"))}; _retire_scene(region); return
	# Activation is deliberately left to the next main-thread pump. The exact
	# actor-volume guard is re-read there, after worker latency and immediately
	# before any scene/collider publication can advance.

func _dispatch(ready: Dictionary, observer: Vector2i) -> bool:
	var candidates: Array[Dictionary] = _dispatch_candidates(ready,observer,true)
	if candidates.is_empty(): return false
	_dispatch_candidate(candidates[0],ready)
	return not _inflight.is_empty()

## Existing direct-service callers select navigation through the same ranking
## and transfer path. Production _dispatch arbitrates BOTH worker job kinds.
func _dispatch_navigation(ready: Dictionary) -> bool:
	var candidates: Array[Dictionary] = _dispatch_candidates(ready,Vector2i.ZERO,false)
	if candidates.is_empty(): return false
	_dispatch_candidate(candidates[0],ready)
	return true

func _new_dispatch_schedule() -> Dictionary:
	_dispatch_sequence += 1
	return {"firstSequence":_dispatch_sequence,"firstPendingUsec":Time.get_ticks_usec(),
		"lastDispatchTurn":_dispatch_turn,"lastDispatchUsec":0}

func _request_navigation_tile(entry: Dictionary, key: String) -> bool:
	if entry.receipts.has(key): return true
	if entry.requested.has(key): return true
	if entry.requested.size()>=MAX_PENDING_NAVIGATION_TILES: return false
	var schedule: Dictionary = _new_dispatch_schedule()
	# Selection is not execution: an active output may consume the whole worker
	# turn. Waiting outputs retain their first admission age until completion.
	schedule.firstPendingTurn = _dispatch_turn
	entry.requested[key] = schedule
	if not entry.has("schedule"): entry.schedule = _new_dispatch_schedule()
	return true

func _aged_priority(priority: int, schedule: Dictionary) -> int:
	var age: int = maxi(0,_dispatch_turn-int(schedule.lastDispatchTurn))
	return maxi(0,priority-floori(float(age)/float(PRIORITY_AGING_DISPATCH_TURNS)))

func _schedule_before(priority_a: int, a: Dictionary, priority_b: int, b: Dictionary) -> bool:
	var rank_a: int = _aged_priority(priority_a,a)
	var rank_b: int = _aged_priority(priority_b,b)
	if rank_a!=rank_b: return rank_a<rank_b
	if a.lastDispatchTurn!=b.lastDispatchTurn: return a.lastDispatchTurn<b.lastDispatchTurn
	return a.firstSequence<b.firstSequence

func _navigation_tile_before(priority_a: int, a: Dictionary, priority_b: int, b: Dictionary) -> bool:
	var age_a: int = maxi(0,_dispatch_turn-int(a.firstPendingTurn))
	var age_b: int = maxi(0,_dispatch_turn-int(b.firstPendingTurn))
	var rank_a: int = maxi(0,priority_a-floori(float(age_a)/float(PRIORITY_AGING_DISPATCH_TURNS)))
	var rank_b: int = maxi(0,priority_b-floori(float(age_b)/float(PRIORITY_AGING_DISPATCH_TURNS)))
	if rank_a!=rank_b: return rank_a<rank_b
	if a.firstPendingTurn!=b.firstPendingTurn: return a.firstPendingTurn<b.firstPendingTurn
	return a.firstSequence<b.firstSequence

## Explicit diagnostic read. It neither requests a tile nor polls its worker.
## Rank describes the current active-first selection, not a completion deadline.
func navigation_request_observation(region: Vector2i, key: String, binding: Dictionary) -> Dictionary:
	var observed := {"schema":"citadel-navigation-request-observation/v1","observedUsec":Time.get_ticks_usec(),
		"region":region,"tileKey":key.left(23),"dispatchTurn":_dispatch_turn,"status":"absent"}
	if key.is_empty() or key.length()>23: observed.status="invalid_query"; return observed
	if not _navigation.has(region): return observed
	var entry: Dictionary = _navigation[region]
	observed["binding"] = entry.binding.duplicate()
	if entry.binding!=binding: observed.status="stale_binding"; return observed
	observed["pendingCount"] = entry.requested.size()
	observed["completedCount"] = entry.receipts.size()
	observed["activeTileKey"] = entry.get("activeTileKey","")
	observed["selected"] = _inflight.get("kind")=="navigation" and _inflight.get("region")==region \
		and _inflight.get("tileKeys",[]).has(key)
	if entry.receipts.has(key): observed.status="completed"; return observed
	if not entry.requested.has(key): observed.status="unrequested"; return observed
	var request: Dictionary = entry.requested[key]
	var priority: int = _navigation_priority(key)
	var age: int = maxi(0,_dispatch_turn-int(request.firstPendingTurn))
	var ahead := 0
	if observed.activeTileKey!=key:
		for other: String in entry.requested:
			if other!=key and (other==observed.activeTileKey or \
				_navigation_tile_before(_navigation_priority(other),entry.requested[other],priority,request)): ahead+=1
	observed.merge({"status":"pending","firstPendingTurn":int(request.firstPendingTurn),
		"firstSequence":int(request.firstSequence),"queuedUsec":int(request.firstPendingUsec),
		"pendingWaitTurns":age,"basePriority":priority,
		"effectivePriority":maxi(0,priority-floori(float(age)/float(PRIORITY_AGING_DISPATCH_TURNS))),
		"outputsAhead":ahead,"selectionRank":ahead+1},true)
	return observed

func _dispatch_candidates(ready: Dictionary, observer: Vector2i, include_preparation: bool) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	for region: Vector2i in _navigation:
		var entry: Dictionary = _navigation[region]
		if not ready.has(region) or ready[region].binding!=entry.binding or _failures.has(region) \
			or entry.get("navigationSource",{}).is_empty() or entry.requested.is_empty(): continue
		var priority := 4
		for key: String in entry.requested: priority = mini(priority,_navigation_priority(key))
		candidates.append({"kind":"navigation","region":region,"priority":priority,"schedule":entry.schedule})
	# A ready source remains a waiter while its payload is temporarily evicted;
	# only departure, binding replacement or a completed owner removes its age.
	for region: Vector2i in _preparation_schedule.keys():
		if not ready.has(region) or ready[region].binding!=_preparation_schedule[region].binding \
			or _prepared.has(region) or _scenes.has(region) or _region_retiring(region) or _failures.has(region):
			_preparation_schedule.erase(region)
	var can_prepare: bool = include_preparation and _resident_region_count()<MAX_REGIONS
	var regions: Array = ready.keys() if can_prepare else []
	regions.sort_custom(func(a,b):
		var ac: Vector2i = ready[a].reservationCells.get_center()
		var bc: Vector2i = ready[b].reservationCells.get_center()
		var ad := ac.distance_squared_to(observer)
		var bd := bc.distance_squared_to(observer)
		return ad<bd or ad==bd and (a.x<b.x or a.x==b.x and a.y<b.y))
	for region: Vector2i in regions:
		if not can_prepare: break
		if _prepared.has(region) or _scenes.has(region) or _region_retiring(region) or _failures.has(region) or ready[region].status != "ready": continue
		if _packet_bootstrap_bases.has(region) and not _packet_requested_for_source(region,ready[region].binding): continue
		if not _preparation_schedule.has(region):
			_preparation_schedule[region] = {"binding":ready[region].binding.duplicate(),"schedule":_new_dispatch_schedule()}
		candidates.append({"kind":"preparation","region":region,"priority":_preparation_priority(region,ready[region]),
			"schedule":_preparation_schedule[region].schedule})
	candidates.sort_custom(func(a: Dictionary,b: Dictionary): return _schedule_before(a.priority,a.schedule,b.priority,b.schedule))
	return candidates


func _has_dispatchable_navigation(ready: Dictionary) -> bool:
	for region: Vector2i in _navigation:
		var entry: Dictionary = _navigation[region]
		if ready.has(region) and ready[region].binding==entry.binding and not _failures.has(region) \
				and not entry.get("navigationSource",{}).is_empty() and not entry.requested.is_empty():
			return true
	return false


func _navigation_physical_packet_pending(entry: Dictionary) -> bool:
	for group_id: String in entry.get("navigationPhysicalGroups",{}):
		if not entry.job.physical_group_packet_completed_for_scheduling(group_id,entry.binding): return true
	return false

func _dispatch_candidate(candidate: Dictionary, ready: Dictionary) -> void:
	var region: Vector2i = candidate.region
	var keys: Array[String] = []
	var order: Array[String] = []
	var receipt: Dictionary
	if candidate.kind=="navigation":
		var entry: Dictionary = _navigation[region]
		var pending: Array = entry.requested.keys()
		pending.sort_custom(func(a: String,b: String):
			return _navigation_tile_before(_navigation_priority(a),entry.requested[a],_navigation_priority(b),entry.requested[b]))
		var active: String = entry.get("activeTileKey","")
		if not active.is_empty():
			if not entry.requested.has(active):
				_failures[region] = {"binding":entry.binding,"reason":"navigation_active_request_missing"}
				return
			order.append(active)
		for key: String in pending:
			if not order.has(key): order.append(key)
			if order.size()>=Worker.MAX_NAVIGATION_BATCH_TILES: break
		keys.assign(order)
		keys.sort()
		receipt = _worker.dispatch_navigation(entry.navigationSource,keys,entry.binding,order)
		if receipt.get("status") not in ["started","queued"]: return
		if receipt.get("duplicate",false): return
		entry.erase("navigationSource") # Transfer before any subsequent poll.
		_inflight = {"kind":"navigation","region":region,"binding":entry.binding,"token":int(receipt.token),
			"tileKeys":keys,"tileOrder":order}
	else:
		var source: Dictionary = ready[region]
		# The retained-source API is the explicit opt-in for demand-bound packet
		# publication.  Ordinary observer/legacy retention keeps the established
		# source preparation lifecycle, including its early-description transfer
		# and cancellation behavior.  Do not add a base turn to that path: it
		# changes both its worker boundary and its observable dispatch contract.
		var packet_requested: bool = _packet_requested_for_source(region,source.binding)
		var bootstrap_requested: bool = _packet_bootstrap_requested_for_source(region,source)
		if _packet_bootstrap_bases.has(region):
			var bootstrap: Dictionary = _packet_bootstrap_bases[region]
			var base = bootstrap.get("base")
			if packet_requested and _base_packet_eligible(base,source.binding,region).get("status")=="ready":
				receipt = _worker.dispatch_publication_base_navigation(base,source.binding)
				if receipt.get("status") not in ["started","queued"] or receipt.get("duplicate",false): return
				_inflight={"kind":"publication_base_navigation","region":region,"binding":source.binding.duplicate(),
					"token":int(receipt.token),"base":base,"profile":bootstrap.get("profile",{})}
				_dispatch_count += 1
				_record_successful_dispatch(candidate,order)
				return
			if bootstrap_requested and not packet_requested: return
			var packet_state: Dictionary = _base_packet_eligible(base,source.binding,region) if packet_requested else {"status":"pending"}
			if packet_state.get("status")=="failed":
				_failures[region]={"binding":source.binding.duplicate(),"reason":String(packet_state.get("reason","packet_publication_plan_failed"))}
			return
		receipt = _worker.dispatch_publication_base(source.source,source.binding) if packet_requested or bootstrap_requested \
			else _worker.dispatch_scene_source(source.source,source.binding)
		if receipt.get("status") not in ["started","queued"]: return
		if receipt.get("duplicate",false): return
		_inflight = {"kind":"publication_base" if packet_requested or bootstrap_requested else "preparation","region":region,
			"binding":source.binding.duplicate(),"token":int(receipt.token)}
		_dispatch_count += 1
	# A duplicate still belongs to the existing worker turn. Repeated queries,
	# capacity rejection and failed admission cannot reset any waiter's age.
	_record_successful_dispatch(candidate,order)

func _record_successful_dispatch(candidate: Dictionary, order: Array[String]) -> void:
	var schedule: Dictionary = candidate.schedule
	var priority: int = candidate.priority
	var effective: int = _aged_priority(priority,schedule)
	var wait_turns: int = _dispatch_turn-int(schedule.lastDispatchTurn)
	var now: int = Time.get_ticks_usec()
	var first_age: int = maxi(0,now-int(schedule.firstPendingUsec))
	_dispatch_metrics.maxFirstDemandUsecByPriority[priority] = maxi(_dispatch_metrics.maxFirstDemandUsecByPriority[priority],first_age)
	_dispatch_metrics.maxWaitTurnsByPriority[priority] = maxi(_dispatch_metrics.maxWaitTurnsByPriority[priority],wait_turns)
	if effective<priority: _dispatch_metrics.agedDispatches += 1
	_dispatch_turn += 1
	schedule.lastDispatchTurn = _dispatch_turn
	schedule.lastDispatchUsec = now
	var selected: Array[Dictionary] = []
	if candidate.kind=="navigation":
		_dispatch_metrics.navigationDispatches += 1
		for key: String in order:
			var tile: Dictionary = _navigation[candidate.region].requested[key]
			var pending_turns: int = _dispatch_turn-1-int(tile.firstPendingTurn)
			selected.append({"tileKey":key,"priority":_navigation_priority(key),
				"firstDemandUsec":maxi(0,now-int(tile.firstPendingUsec)),"waitTurns":_dispatch_turn-1-int(tile.lastDispatchTurn),
				"firstPendingTurn":int(tile.firstPendingTurn),"pendingWaitTurns":pending_turns,
				"effectivePriority":maxi(0,_navigation_priority(key)-floori(float(pending_turns)/float(PRIORITY_AGING_DISPATCH_TURNS)))})
			tile.lastDispatchTurn = _dispatch_turn
			tile.lastDispatchUsec = now
	else: _dispatch_metrics.preparationDispatches += 1
	_dispatch_metrics.last = {"kind":candidate.kind,"region":candidate.region,"priority":priority,"effectivePriority":effective,
		"waitTurns":wait_turns,"firstDemandUsec":first_age,"dispatchTurn":_dispatch_turn,"selected":selected,
		"scope":"accepted dispatch selection; not proof that selected outputs progressed"}

func _collect_navigation(region: Vector2i, binding: Dictionary, result: Dictionary, requested_keys: Array, requested_order: Array) -> void:
	var source: Dictionary = result.get("navigationSource",{})
	if not _navigation.has(region) or _navigation[region].binding!=binding:
		_retire(result)
		return
	var valid: bool = result.get("ready",false) and result.get("kind")=="navigation_batch" and source.get("binding",{})==binding \
		and result.get("requestedTileKeys",[])==requested_keys and result.get("requestedTileOrder",[])==requested_order \
		and result.get("tileReceipts") is Dictionary and result.get("producerStatus") is Dictionary \
		and is_same(source.get("domain"),_navigation[region].domain)
	var raw_status: Variant = result.get("producerStatus",{})
	var producer_status: Dictionary = raw_status if raw_status is Dictionary else {}
	var active: Variant = producer_status.get("activeTileKey","")
	valid = valid and active is String and (active.is_empty() or requested_keys.has(active))
	if valid:
		for key in result.tileReceipts:
			var receipt: Variant = result.tileReceipts[key]
			if not key is String or not requested_keys.has(key) or not receipt is Dictionary \
					or receipt.get("status")!="ready" or receipt.get("tileKey")!=key \
					or not receipt.get("tile") is Dictionary or not receipt.tile.is_read_only():
				valid = false
				break
		if result.get("batchComplete",false) and result.tileReceipts.size()!=requested_keys.size(): valid = false
		if not active.is_empty() and result.tileReceipts.has(active): valid = false
	if not valid:
		_failures[region] = {"binding":binding,"reason":result.get("reason","navigation_producer_result_invalid")}
		_retire(result)
		return
	var entry: Dictionary = _navigation[region]
	entry.navigationSource = source
	entry.activeTileKey = active
	# Copy bounded scalar progress only. Never query the returned producer here
	# or expose it to diagnostics while the next worker owns its mutable state.
	entry.producerProgress = {}
	for field: String in ["phase","activeTileKey","pendingRequestCount","completedTileCount","compiledProducerCount",
		"producerCount","sampleCount","surfaceCount","preparationUsec"]:
		var value: Variant = producer_status.get(field)
		if value is String or value is int: entry.producerProgress[field] = value
	for key: String in result.get("tileReceipts",{}):
		var receipt: Dictionary = result.tileReceipts[key]
		var bound_receipt := {"status":"ready","binding":source.binding,"tileKey":key,"tile":receipt.get("tile",{}),
			"outputPresent":receipt.get("outputPresent",false)}
		bound_receipt.make_read_only()
		entry.receipts[key] = bound_receipt
		entry.requested.erase(key)
	if entry.requested.is_empty(): entry.erase("schedule")

func _resident_region_count() -> int:
	var regions := {}
	for region: Vector2i in _described: regions[region] = true
	for region: Vector2i in _prepared: regions[region] = true
	for region: Vector2i in _packet_bootstrap_bases: regions[region] = true
	for region: Vector2i in _scenes: regions[region] = true
	if not _inflight.is_empty(): regions[_inflight.region] = true
	for entry: Dictionary in _retiring_scenes: regions[entry.region] = true
	for region: Vector2i in _pending_scene_disposals.values(): regions[region] = true
	for region: Vector2i in _submitted_scene_disposals.values(): regions[region] = true
	return regions.size()

func _retire(value: Dictionary) -> void:
	_retirement_serial += 1
	_retired[_retirement_serial] = value

func _retire_all() -> void:
	_preparation_schedule = {}
	_dispatch_metrics.last = {}
	_pending_packet_navigation = {}
	if not _navigation.is_empty(): _retire(_navigation)
	_navigation = {}
	if not _described.is_empty(): _retire(_described)
	_described = {}
	_description_serial += 1
	if not _prepared.is_empty(): _retire(_prepared)
	_prepared = {}
	if not _packet_bootstrap_bases.is_empty(): _retire(_packet_bootstrap_bases)
	_packet_bootstrap_bases = {}

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
	_retained_source_compile_job = {}
	_retained_region_bounds = []
	_retained_consumers = []
	_clear_retained_priorities()
	_observer_region_bounds = Rect2i()
	_prefetch_regions.clear()
	_prefetch_started_usec.clear()
	_demand_started_usec.clear()
	_demand_revision += 1
	_view_revision += 1
	_retire_all_scenes()
	_desired = {}
	_inflight = {}
	_retire_all()
	_worker.request_shutdown()

func stats() -> Dictionary:
	var constructed := 0
	var scenes: Array[Dictionary] = []
	for entry in _scenes.values():
		if entry.phase=="scene_ready": constructed+=1
		var job = entry.get("job",null)
		var job_status: Dictionary = job.status_count() if job!=null else {}
		var demand: Dictionary = entry.get("packetDemandStatus",{})
		scenes.append({"region":entry.get("region",Vector2i()),"phase":entry.get("phase",""),
			"jobPhase":job_status.get("phase",""),"packetMode":bool(entry.get("packetMode",false)),
			"demandRevision":int(entry.get("demandRevision",-1)),"packetDemandStatus":String(demand.get("status","")),
			"packetDemandReason":String(demand.get("reason","")),"packetDemandRequests":demand.get("requests",[]).size(),
			"packetForegroundGroups":demand.get("foregroundGroupIds",[]).size(),
			"packetDeferredGroups":int(demand.get("deferredGroupCount",demand.get("deferredGroupIds",[]).size())),
			"packetReadinessGroups":demand.get("readinessGroupIds",[]).size(),
			"physicalGroupsComplete":int(job_status.get("physicalGroupsComplete",0)),"physicalGroupsTotal":int(job_status.get("physicalGroupsTotal",0)),
			"retainedGroupRequests":int(job_status.get("retainedGroupRequests",0)),"publicationTransactionId":int(job_status.get("publicationTransactionId",0)),
			"occupiedTransactions":int(job_status.get("occupiedTransactions",0)),"occupancyWaitReason":String(entry.get("occupancyWaitReason","")),
			"occupancyWaitCount":int(entry.get("occupancyWaitCount",0)),
			"occupancyWaitUsec":Time.get_ticks_usec()-int(entry.get("occupancyWaitStartedUsec",Time.get_ticks_usec())) if entry.has("occupancyWaitStartedUsec") else 0,
			"navigationPhysicalGroups":entry.get("navigationPhysicalGroups",{}).size(),
			"navigationPhysicalPending":entry.get("navigationPhysicalPending",{}).duplicate(),
			"publicationMilestones":entry.get("publicationMilestones",{}).duplicate(true)})
	scenes.sort_custom(func(a: Dictionary,b: Dictionary) -> bool:
		var left: Vector2i = a.region
		var right: Vector2i = b.region
		return left.y<right.y if left.y!=right.y else left.x<right.x)
	var scheduling: Dictionary = _dispatch_metrics.duplicate(true)
	scheduling["dispatchTurn"] = _dispatch_turn
	scheduling["priorityAgingDispatchTurns"] = PRIORITY_AGING_DISPATCH_TURNS
	scheduling["sources"] = []
	for region: Vector2i in _navigation:
		var entry: Dictionary = _navigation[region]
		scheduling.sources.append({"region":region,"pendingTiles":entry.requested.size(),"completedTiles":entry.receipts.size(),
			"progress":entry.get("producerProgress",{}).duplicate(),
			"preparationUsecScope":"cumulative wall time inside producer begin/advance calls; excludes time between calls"})
	return {"generation":_generation,"worldSeed":_seed,"desiredSites":_desired.size(),
		"retainedBounds":_retained_region_bounds.size(),"observerBoundsRejected":_observer_bounds_rejected,
		"prefetchRegions":_prefetch_regions.duplicate(),"prefetchRejected":_prefetch_rejected,
		"residentSites":_resident_region_count(),"residentLimit":MAX_REGIONS,
		"worldResetPending":_world_reset_pending,"worldResetReady":world_reset_ready(),
		"preparedSites":_prepared.size(),"bootstrapBases":_packet_bootstrap_bases.size(),"describedSites":_described.size(),"pendingRetirements":_retired.size(),
		"activeToken":_inflight.get("token",0),"failures":_failures.duplicate(true),
		"dispatchCount":_dispatch_count,"acceptedCount":_accepted_count,"maxAdvanceUsec":_max_advance_usec,
		"publicationReady":false,"worker":_last_worker_status,"sourceScheduling":scheduling,
		"sceneDiagnostics":scenes,"sceneUnitMetrics":_scene_unit_metrics_compact(),"demandRevision":_demand_revision,"viewRevision":_view_revision,
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
	_pending_packet_navigation.erase(region)
	if not _scenes.has(region): return
	if _navigation.has(region):
		_retire(_navigation[region])
		_navigation.erase(region)
	if not _inflight.is_empty() and _inflight.get("kind")=="navigation" and _inflight.region==region:
		_worker.cancel(int(_inflight.token))
		_inflight = {}
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
		var phase: String = entry.job.status_count().phase
		# Packet mode deliberately has no root while its immutable physical
		# packet is still being compiled.  The adapter creates the root only after
		# it receives that exact packet and moves into building_begin.
		if phase!="building_begin" and not (bool(entry.get("packetMode",false)) and phase=="packet_wait"):
			var site: Node3D=entry.job.own_node_root()
			var parent: Node3D=_scene_parent.get_ref() as Node3D
			if not is_instance_valid(site) or site.is_queued_for_deletion() or not site.is_inside_tree() or site.get_parent()!=parent \
					or not site.global_transform.is_equal_approx(Transform3D(Basis.IDENTITY,entry.profile.origin)):
				_failures[region]={"binding":entry.binding,"reason":"constructed_scene_owner_lost" if entry.phase=="scene_ready" else "publication_scene_owner_lost"}
				_retire_scene(region)

func _description_revision_matches(region: Vector2i, binding: Dictionary, profile: Dictionary, description) -> bool:
	if not _described.has(region): return true
	var retained: Dictionary = _described[region]
	var prior = retained.get("description")
	return retained.get("binding",{})==binding and retained.get("configuration",-1)==_configuration_serial \
		and retained.get("profile",{}).get("sourceSignature","")==profile.get("sourceSignature","") \
		and prior!=null and description!=null and prior.binding==binding and description.binding==binding \
		and prior.origin==description.origin and prior.source_identity_digest.length()==64 \
		and prior.source_identity_digest==description.source_identity_digest

func _start_scene(region: Vector2i, source: Dictionary) -> bool:
	if not _scene_callbacks_ready() or _scenes.has(region) or _region_retiring(region): return false
	if not _prepared.has(region) or _scenes.has(region) or _region_retiring(region) or not _scene_callbacks_ready(): return false
	var prepared: Dictionary=_prepared[region]
	# Bind against a fresh non-enqueuing lookup immediately before consumption.
	var current: Dictionary=_admission.source_state(region)
	if current.get("binding",{})!=prepared.binding or source.binding!=prepared.binding or not _current_binding(prepared.binding): return false
	var packet_mode: bool = bool(prepared.get("packetMode",false))
	var description = prepared.base.description if packet_mode else prepared.prepared.describe(prepared.binding)
	if description==null or description.binding!=prepared.binding or description.origin!=prepared.profile.origin \
			or not _description_revision_matches(region,prepared.binding,prepared.profile,description):
		_failures[region] = {"binding":prepared.binding,"reason":"scene_description_identity_mismatch"}
		_retire(prepared)
		_prepared.erase(region)
		return false
	if _described.has(region) and _described[region].description!=description:
		# Revisit reconstruction creates a new immutable descriptor object for the
		# same source revision. Promote that exact owner while preserving the
		# revision serial; object identity is a lifetime fact, not world identity.
		_described[region].profile=prepared.profile
		_described[region].description=description
	var parent: Node3D=_scene_parent.get_ref() as Node3D
	var job=SceneJob.new()
	if not job.set_tree_retire_callback(Callable(_tree_retire_receiver.get_ref(),_tree_retire_method),_require_tree_retirement_ack): return false
	if _door_lifecycle_configured and not job.set_door_callbacks(Callable(_door_receiver.get_ref(),_door_method),Callable(_door_retire_receiver.get_ref(),_door_retire_method)): return false
	var result: Dictionary = job.begin_prepared_base(prepared.base,prepared.profile,prepared.binding,parent,Callable(_tree_receiver.get_ref(),_tree_method)) if packet_mode \
		else job.begin(prepared.prepared,prepared.profile,prepared.binding,parent,Callable(_tree_receiver.get_ref(),_tree_method))
	if result.get("status")!="pending_budget":
		_failures[region]={"binding":prepared.binding,"reason":String(result.get("reason","scene_begin_failed"))}
		_retire(prepared); _prepared.erase(region)
		return false
	var demand_started := int(_demand_started_usec.get(region,Time.get_ticks_usec()))
	var prefetch_started := int(_prefetch_started_usec.get(region,demand_started))
	_scenes[region]={"region":region,"binding":prepared.binding,"profile":prepared.profile,"job":job,"phase":"publishing","packetMode":packet_mode,
		"publicationMilestones":{"sourceDemandStartedUsec":demand_started,
			"prefetchStartedUsec":prefetch_started,"prefetchLeadUsec":maxi(0,demand_started-prefetch_started),
			"sceneStartedAfterDemandUsec":maxi(0,Time.get_ticks_usec()-demand_started),
			"firstSilhouetteUsec":-1,"usableGatePathUsec":-1,"visibleCourtyardUsec":-1,
			"accessibleHomeUsec":-1,"completeDemandedUsec":-1,"fullSourceUsec":-1}}
	_prepared.erase(region)
	_scene_started_count+=1
	return true

func _refresh_scene_group_demand(entry: Dictionary) -> bool:
	if entry.get("demandRevision",-1)==_demand_revision: return true
	if bool(entry.get("packetMode",false)):
		# Camera/bounds revisions may arrive several times while one immutable
		# foreground packet window is still publishing. If that window already
		# contains every new immediate physical and navigation group, retain it and
		# let the latest view select the *next* window. This makes view motion a
		# priority input without withdrawing accepted work or rebuilding closures.
		if _packet_window_covers_current_immediate_demand(entry):
			if not _retain_navigation_physical_demand(entry): return false
			entry["demandRevision"]=_demand_revision
			return true
		var base: Preparation.PreparedPublicationBase = entry.job._cpu.get("publicationBase")
		var completed: Dictionary = entry.job.completed_physical_group_ids(entry.binding)
		_record_publication_milestones(entry,completed,base.description.publication_groups.groups.size() if base!=null else 0)
		var plan_started := Time.get_ticks_usec()
		# View-ranked detail advances once for each distinct camera revision. A
		# navigation/tile refresh with an unchanged camera must publish only its
		# exact physical closure; otherwise every navigation acknowledgement also
		# installs another unrelated presentation window while the player is still.
		var prior_demand: Dictionary=entry.get("packetDemandStatus",{})
		var include_view_progress := _presentation_progress_due(entry,_view_revision,completed.size(),
			int(prior_demand.get("deferredGroupCount",0)),not prior_demand.get("requests",[]).is_empty())
		var plan: Dictionary = _packet_foreground_plan(entry.region,entry.binding,
			base.description if base!=null else null,base,completed,include_view_progress)
		_record_scene_unit("demand_plan_total",plan_started,base.description.publication_groups.groups.size() if base!=null else 0)
		if plan.get("status")!="ready":
			entry["packetDemandStatus"] = plan.duplicate(true)
			return false
		if plan.get("readinessGroupIds",[]).size()>MAX_REQUIRED_FOREGROUND_GROUPS:
			entry["packetDemandStatus"]={"status":"failed","reason":"packet_required_foreground_scope_too_large",
				"groupCount":plan.readinessGroupIds.size()}
			return false
		# Keep the source/view window separate from the rolling navigation
		# supplements. Completed supplements must leave the active slot census;
		# otherwise one full batch permanently consumes the 128-group window and
		# later tile collision closures can never enter after a revisit.
		var source_foreground_group_ids: Array=plan.foregroundGroupIds.duplicate()
		var source_readiness_group_ids: Array=plan.readinessGroupIds.duplicate()
		var navigation_supplemental_group_ids: Array=[]
		var navigation_merge_started := Time.get_ticks_usec()
		var navigation_groups: Dictionary = entry.get("navigationPhysicalGroups",{})
		if not navigation_groups.is_empty():
			# Navigation publication can ask for tiles from both the capsule and the
			# retained background ring.  They share a packet scene, but they must not
			# share foreground priority: otherwise every background physical closure
			# is promoted into the startup gate before the capsule tile can receive a
			# receipt. Preserve the per-tile request priority all the way to group
			# selection. A group shared by tiles keeps its most urgent owner.
			var navigation_ids: Dictionary = {}
			for group_id: String in navigation_groups:
				var priority: int = int(navigation_groups[group_id])
				if priority<0 or priority>4:
					entry["packetDemandStatus"] = {"status":"failed","reason":"invalid_navigation_physical_priority"}
					return false
				navigation_ids[group_id] = true
			var navigation_slots := _navigation_supplement_slots(plan.foregroundGroupIds.size(),0)
			var navigation_selection := _bounded_navigation_group_requests(entry,navigation_groups,
			plan.foregroundGroupIds,navigation_slots,"navigation:%d,%d" % [entry.region.x,entry.region.y],true)
			if navigation_selection.get("status")!="ready":
				entry["packetDemandStatus"] = navigation_selection.duplicate(true)
				return false
			for request: Dictionary in navigation_selection.requests:
				plan.requests.append(request)
				for group_id: String in request.groupIds:
					if not plan.foregroundGroupIds.has(group_id):
						plan.foregroundGroupIds.append(group_id)
						navigation_supplemental_group_ids.append(group_id)
					if int(request.priority)==0 and not plan.readinessGroupIds.has(group_id): plan.readinessGroupIds.append(group_id)
			plan.foregroundGroupIds.sort()
			plan.readinessGroupIds.sort()
			if not bool(plan.get("implicitDeferred",false)):
				var deferred: Array[String] = []
				for group_id: String in plan.deferredGroupIds:
					if not navigation_ids.has(group_id): deferred.append(group_id)
				plan.deferredGroupIds = deferred
		_record_scene_unit("demand_navigation_merge",navigation_merge_started,navigation_groups.size())
		var handoff_started := Time.get_ticks_usec()
		var packet_result: Dictionary = entry.job.replace_packet_foreground_group_demands_compact(plan.requests,plan.deferredGroupIds,entry.binding) \
			if bool(plan.get("implicitDeferred",false)) else entry.job.replace_packet_foreground_group_demands(plan.requests,plan.deferredGroupIds,entry.binding)
		_record_scene_unit("demand_job_handoff",handoff_started,plan.foregroundGroupIds.size()+plan.get("deferredGroupCount",plan.deferredGroupIds.size()))
		if packet_result.get("status")!="retained":
			entry["packetDemandStatus"] = packet_result.duplicate(true)
			return false
		# Gameplay readiness is the semantic first-content closure assembled by the
		# plan (spatial safety, two complete homes and a door). The wider ranked
		# window remains non-blocking presentation work before and after readiness.
		var readiness_group_ids: Array = plan.readinessGroupIds
		var status_copy_started := Time.get_ticks_usec()
		entry["packetDemandStatus"] = {"status":"retained","reason":"packet_foreground_groups_deferred" if not plan.blockedGroupIds.is_empty() and plan.requests.is_empty() else "",
			"requests":plan.requests.duplicate(true),
			"foregroundGroupIds":plan.foregroundGroupIds.duplicate(),"readinessGroupIds":readiness_group_ids.duplicate(),
			"sourceForegroundGroupIds":source_foreground_group_ids,
			"sourceReadinessGroupIds":source_readiness_group_ids,
			"navigationSupplementalGroupIds":navigation_supplemental_group_ids,
			"deferredGroupIds":plan.deferredGroupIds.duplicate(),"deferredGroupCount":packet_result.get("deferredGroups",plan.get("deferredGroupCount",0)),
			"implicitDeferred":plan.get("implicitDeferred",false),"candidateCount":plan.get("candidateCount",0),
			"viewPrioritizedGroupIds":plan.get("viewPrioritizedGroupIds",[]).duplicate(),
			"portalGroupIds":plan.get("portalGroupIds",[]).duplicate(),
			"firstUsefulGroupIds":plan.get("firstUsefulGroupIds",[]).duplicate(),
			"firstUsefulHomeIds":plan.get("firstUsefulHomeIds",[]).duplicate(),
			"firstUsefulDoorGroupId":plan.get("firstUsefulDoorGroupId",""),
			"firstUsefulStructuralGroupIds":plan.get("firstUsefulStructuralGroupIds",[]).duplicate(),
			"courtyardGroupIds":plan.get("courtyardGroupIds",[]).duplicate(),
			"blockedGroupIds":plan.blockedGroupIds.duplicate(),"boundaryGroupIds":plan.boundaryGroupIds.duplicate(),
			"viewProgressIncluded":include_view_progress}
		_record_scene_unit("demand_status_copy",status_copy_started,plan.foregroundGroupIds.size()+plan.deferredGroupIds.size())
		entry["demandRevision"] = _demand_revision
		if include_view_progress: entry["viewRevision"] = _view_revision
		# A previously acknowledged packet scene stays available for its committed
		# closure, but a new foreground demand must not inherit that acknowledgement.
		# Its exact receipt is checked again before the service reports readiness.
		if entry.phase=="scene_ready" and not _packet_foreground_physical_ready(entry.region,entry.binding):
			entry.phase="publishing"
		return true
	var requests: Array[Dictionary] = []
	for consumer: Dictionary in _retained_consumers:
		for site: Dictionary in consumer.sites:
			if site.binding==entry.binding:
				requests.append({"ownerId":"region:%d" % consumer.ownerId,"groupIds":site.groupIds,"priority":consumer.priority})
	var result: Dictionary = entry.job.replace_publication_group_demands(requests,entry.binding)
	if result.get("status") != "retained": return false
	entry["demandRevision"] = _demand_revision
	return true


static func _view_progress_due(entry: Dictionary, current_view_revision: int) -> bool:
	return int(entry.get("viewRevision",-1))!=current_view_revision


static func _presentation_progress_due(entry: Dictionary, current_view_revision: int,
		completed_group_count: int, deferred_group_count: int, has_requests: bool) -> bool:
	return _view_progress_due(entry,current_view_revision) \
		or has_requests and deferred_group_count>0 and completed_group_count<MAX_RESIDENT_PRESENTATION_GROUPS


func _packet_window_covers_current_immediate_demand(entry: Dictionary) -> bool:
	var demand: Dictionary = entry.get("packetDemandStatus",{})
	if demand.get("status")!="retained" or demand.get("foregroundGroupIds",[]).is_empty(): return false
	var retained: Dictionary = {}
	var incomplete := false
	for group_id: String in demand.foregroundGroupIds:
		retained[group_id]=true
		if not entry.job.physical_group_packet_completed_for_scheduling(group_id,entry.binding): incomplete=true
	if not incomplete: return false
	var observer_covered := not _observer_region_bounds.has_area()
	var matched_site := false
	for consumer: Dictionary in _retained_consumers:
		if consumer.get("bounds") is Rect2i and consumer.bounds.encloses(_observer_region_bounds): observer_covered=true
		for site: Dictionary in consumer.sites:
			if site.binding!=entry.binding: continue
			matched_site=true
			if not site.has("foregroundGroupIds"): return false
			for group_id: String in site.foregroundGroupIds:
				if not retained.has(group_id) and not entry.job.physical_group_packet_completed_for_scheduling(group_id,entry.binding): return false
	if not matched_site or not observer_covered: return false
	return true


func _retain_navigation_physical_demand(entry: Dictionary) -> bool:
	var demand: Dictionary=entry.get("packetDemandStatus",{})
	var completed: Dictionary=entry.job.completed_physical_group_ids(entry.binding)
	var source_foreground: Array=demand.get("sourceForegroundGroupIds",demand.get("foregroundGroupIds",[])).duplicate()
	var source_readiness: Array=demand.get("sourceReadinessGroupIds",demand.get("readinessGroupIds",[])).duplicate()
	var supplemental: Array=[]
	for group_id: String in demand.get("navigationSupplementalGroupIds",[]):
		if not completed.has(group_id): supplemental.append(group_id)
	var foreground: Array=source_foreground.duplicate()
	for group_id: String in supplemental:
		if not foreground.has(group_id): foreground.append(group_id)
	var readiness: Array=source_readiness.duplicate()
	var navigation_slots:=_navigation_supplement_slots(source_foreground.size(),supplemental.size())
	var navigation: Dictionary = entry.get("navigationPhysicalGroups",{})
	var selection := _bounded_navigation_group_requests(entry,navigation,foreground,navigation_slots,"navigation-supplement",true)
	if selection.get("status")!="ready":
		entry["packetDemandStatus"]=selection.duplicate(true)
		return false
	var requests: Array=selection.requests
	if requests.is_empty():
		foreground.sort()
		readiness.sort()
		supplemental.sort()
		demand.foregroundGroupIds=foreground
		demand.readinessGroupIds=readiness
		demand.navigationSupplementalGroupIds=supplemental
		entry["packetDemandStatus"]=demand
		return true
	var retained: Dictionary=entry.job.retain_packet_supplemental_group_demands(requests,entry.binding)
	if retained.get("status")!="retained":
		entry["packetDemandStatus"]=retained
		return false
	for request: Dictionary in requests:
		for group_id: String in request.groupIds:
			if not foreground.has(group_id): foreground.append(group_id)
			if not supplemental.has(group_id): supplemental.append(group_id)
			if int(request.priority)==0 and not readiness.has(group_id): readiness.append(group_id)
	foreground.sort()
	readiness.sort()
	supplemental.sort()
	demand.foregroundGroupIds=foreground
	demand.readinessGroupIds=readiness
	demand.navigationSupplementalGroupIds=supplemental
	demand["deferredGroupCount"]=retained.get("deferredGroups",demand.get("deferredGroupCount",0))
	entry["packetDemandStatus"]=demand
	return true


static func _navigation_supplement_slots(source_group_count: int, active_supplement_count: int) -> int:
	return mini(maxi(0,MAX_NAVIGATION_MERGED_FOREGROUND_GROUPS-active_supplement_count),
		maxi(0,MAX_REQUIRED_FOREGROUND_GROUPS-source_group_count-active_supplement_count))


## Navigation owns complete collision closures, but its retained set may be
## wider than the rolling physical window. Apply the cap to whole dependency
## closures rather than individual alphabetic IDs; otherwise the admitted
## subset can strand a requested group behind an intentionally deferred parent.
func _bounded_navigation_group_requests(entry: Dictionary, navigation: Dictionary,
		foreground: Array, slot_limit: int, owner_prefix: String, allow_exact_closure_overflow := false) -> Dictionary:
	if slot_limit<=0: return {"status":"ready","requests":[]}
	var base: Preparation.PreparedPublicationBase = entry.job._cpu.get("publicationBase")
	if base==null or base.description==null: return {"status":"pending","reason":"packet_publication_base_pending"}
	var completed: Dictionary=entry.job.completed_physical_group_ids(entry.binding)
	var compact_plan=base.publication_plan
	var groups: Dictionary=base.description.publication_groups.groups
	var retained: Dictionary={}
	for group_id: String in foreground: retained[group_id]=true
	var selected: Dictionary={}
	var selected_priority: Dictionary={}
	var by_priority: Dictionary={}
	for group_id: String in navigation:
		var priority:=int(navigation[group_id])
		if priority<0 or priority>4: return {"status":"failed","reason":"invalid_navigation_physical_priority"}
		if not by_priority.has(priority): by_priority[priority]=[]
		by_priority[priority].append(group_id)
	var remaining:=slot_limit
	var hard_remaining:=maxi(0,MAX_REQUIRED_FOREGROUND_GROUPS-foreground.size())
	for priority: int in range(5):
		if not by_priority.has(priority): continue
		by_priority[priority].sort()
		for group_id: String in by_priority[priority]:
			if completed.has(group_id) or retained.has(group_id) or selected.has(group_id): continue
			var closure: Dictionary=_packet_dependency_window_for_plan(compact_plan,groups,group_id,completed)
			if closure.get("status")!="ready": return closure
			var additions: Array[String]=[]
			for required_id: String in closure.groupIds:
				if completed.has(required_id) or retained.has(required_id) or selected.has(required_id): continue
				additions.append(required_id)
			if additions.size()>remaining:
				# A physical navigation receipt is an exact collision closure, not
				# optional city presentation.  Its dependencies must either arrive
				# together or remain absent.  Let the first such closure use the
				# reserved hard foreground headroom; otherwise a 129-member civic
				# eave can be deferred forever behind the 128-member rolling window.
				if not allow_exact_closure_overflow or not selected.is_empty() or additions.size()>hard_remaining:
					continue
			for required_id: String in additions:
				selected[required_id]=true
				selected_priority[required_id]=priority
				remaining-=1
				hard_remaining-=1
	var requests: Array[Dictionary]=[]
	for priority: int in range(5):
		var ids: Array[String]=[]
		for group_id: String in selected:
			if int(selected_priority[group_id])==priority: ids.append(group_id)
		ids.sort()
		if not ids.is_empty(): requests.append({"ownerId":"%s:%d" % [owner_prefix,priority],"groupIds":ids,"priority":priority})
	return {"status":"ready","requests":requests,"admittedGroups":selected.size(),"remainingSlots":remaining}

func _record_scene_unit(label: String, started_usec: int, work_units := -1) -> void:
	var elapsed := Time.get_ticks_usec()-started_usec
	var metric: Dictionary = _scene_unit_metrics.get(label,{"calls":0,"totalUsec":0,"maxUsec":0,"lastUsec":0,
		"samples":[],"sampleCursor":0,"workUnitsTotal":0,"workUnitsMax":0,"workUnitsLast":0})
	metric.calls += 1
	metric.totalUsec += elapsed
	metric.maxUsec = maxi(int(metric.maxUsec),elapsed)
	metric.lastUsec = elapsed
	var samples: Array = metric.samples
	if samples.size()<SCENE_UNIT_SAMPLE_CAPACITY:
		samples.append(elapsed)
	else:
		var cursor := int(metric.sampleCursor)%SCENE_UNIT_SAMPLE_CAPACITY
		samples[cursor]=elapsed
		metric.sampleCursor=(cursor+1)%SCENE_UNIT_SAMPLE_CAPACITY
	metric.samples=samples
	if work_units>=0:
		metric.workUnitsTotal += work_units
		metric.workUnitsMax = maxi(int(metric.workUnitsMax),work_units)
		metric.workUnitsLast = work_units
	_scene_unit_metrics[label] = metric


static func _milestone_targets_complete(targets: Array, completed: Dictionary) -> bool:
	if targets.is_empty(): return false
	for raw_id in targets:
		if not raw_id is String or not completed.has(raw_id): return false
	return true


func _record_publication_milestones(entry: Dictionary, completed: Dictionary, total_groups: int) -> void:
	var milestones: Dictionary = entry.get("publicationMilestones",{})
	if milestones.is_empty(): return
	var elapsed := maxi(0,Time.get_ticks_usec()-int(milestones.sourceDemandStartedUsec))
	if int(milestones.firstSilhouetteUsec)<0 and not completed.is_empty(): milestones.firstSilhouetteUsec=elapsed
	var demand: Dictionary = entry.get("packetDemandStatus",{})
	var gate_targets: Array = demand.get("firstUsefulStructuralGroupIds",[]).duplicate()
	var door_id := String(demand.get("firstUsefulDoorGroupId",""))
	if not door_id.is_empty() and not gate_targets.has(door_id): gate_targets.append(door_id)
	if int(milestones.usableGatePathUsec)<0 and _milestone_targets_complete(gate_targets,completed):
		milestones.usableGatePathUsec=elapsed
	if int(milestones.visibleCourtyardUsec)<0 and _milestone_targets_complete(demand.get("courtyardGroupIds",[]),completed):
		milestones.visibleCourtyardUsec=elapsed
	if int(milestones.accessibleHomeUsec)<0 and _milestone_targets_complete(demand.get("firstUsefulGroupIds",[]),completed):
		milestones.accessibleHomeUsec=elapsed
	if int(milestones.completeDemandedUsec)<0 and _milestone_targets_complete(demand.get("foregroundGroupIds",[]),completed):
		milestones.completeDemandedUsec=elapsed
	if int(milestones.fullSourceUsec)<0 and total_groups>0 and completed.size()>=total_groups:
		milestones.fullSourceUsec=elapsed
	entry.publicationMilestones=milestones

func _scene_unit_metrics_snapshot() -> Dictionary:
	var result: Dictionary = {}
	for label: String in _scene_unit_metrics:
		var metric: Dictionary = _scene_unit_metrics[label].duplicate(true)
		var samples: Array = metric.get("samples",[])
		var ordered: Array = samples.duplicate()
		ordered.sort()
		metric.erase("samples")
		metric.erase("sampleCursor")
		metric["sampleCount"] = ordered.size()
		metric["sampleCapacity"] = SCENE_UNIT_SAMPLE_CAPACITY
		metric["sampleScope"] = "bounded_all_calls" if int(metric.calls)<=SCENE_UNIT_SAMPLE_CAPACITY else "bounded_recent_calls"
		metric["p50Usec"] = _scene_unit_percentile(ordered,0.50)
		metric["p95Usec"] = _scene_unit_percentile(ordered,0.95)
		metric["p99Usec"] = _scene_unit_percentile(ordered,0.99)
		result[label]=metric
	return result

## Explicit, bounded diagnostic snapshot. Ordinary stats deliberately omit the
## retained samples so polling cannot sort/copy the profiler's ring every frame.
func profile_scene_unit_metrics() -> Dictionary:
	return _scene_unit_metrics_snapshot()

func _scene_unit_metrics_compact() -> Dictionary:
	var result: Dictionary = {}
	for label: String in _scene_unit_metrics:
		var source: Dictionary = _scene_unit_metrics[label]
		result[label]={"calls":source.calls,"totalUsec":source.totalUsec,"maxUsec":source.maxUsec,"lastUsec":source.lastUsec,
			"workUnitsTotal":source.workUnitsTotal,"workUnitsMax":source.workUnitsMax,"workUnitsLast":source.workUnitsLast}
	return result

static func _scene_unit_percentile(ordered: Array, percentile: float) -> int:
	if ordered.is_empty(): return 0
	var index := clampi(ceili(percentile*float(ordered.size()))-1,0,ordered.size()-1)
	return int(ordered[index])

func _pump_scenes(ready: Dictionary, allow_build: bool, started: int, budget_usec: int) -> void:
	# One shared budget, fair across building and retirement. No per-site budget
	# multiplication. Job.advance itself packs cheap work into its remaining slice.
	var units := 0
	var configuration:=_configuration_serial
	var demand_revision := _demand_revision
	while units==0 or Time.get_ticks_usec()-started<budget_usec:
		if _closing or configuration!=_configuration_serial or demand_revision!=_demand_revision: allow_build=false
		var work_started:=Time.get_ticks_usec()
		var remaining:=maxi(1,budget_usec-int(work_started-started))
		var progressed:=false
		if not _retiring_scenes.is_empty() and (_prefer_retirement or not allow_build or not _has_scene_work(ready)):
			# Keep this owner visible during callbacks, including reentrant reset
			# or attempted root rebinding, until its current unit returns.
			var entry: Dictionary=_retiring_scenes[0]
			var retirement_started := Time.get_ticks_usec()
			entry.job.advance(mini(remaining,SCENE_JOB_SLICE_USEC))
			_record_scene_unit("retirement_advance",retirement_started)
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
					var start_scene_started := Time.get_ticks_usec()
					progressed=_start_scene(region,ready[region])
					_record_scene_unit("scene_start",start_scene_started)
					if progressed or configuration!=_configuration_serial or demand_revision!=_demand_revision or _closing: break
			if not progressed and configuration==_configuration_serial and demand_revision==_demand_revision and not _closing:
				var regions: Array=_scenes.keys()
				for offset in range(regions.size()):
					var index:=(_scene_cursor+offset)%regions.size()
					var region: Vector2i=regions[index]
					if not _scenes.has(region): continue
					var entry: Dictionary=_scenes[region]
					# A packet scene may already satisfy its current foreground physical
					# closure while retaining deferred groups for later streaming or
					# navigation demand.  Keep serving that resident owner after its first
					# readiness acknowledgement; a later demand revision can demote it
					# before it publishes another packet.
					if entry.phase not in ["publishing","scene_ready"] or not ready.has(region): continue
					var replay_started:=Time.get_ticks_usec()
					var replay: Dictionary=entry.job.advance_chunk_static_packet_replay(mini(remaining,SCENE_JOB_SLICE_USEC))
					_record_scene_unit("static_packet_replay",replay_started)
					if replay.get("status")=="failed":
						_failures[region]={"binding":entry.binding,"reason":String(replay.get("reason","static_packet_replay_failed")),
							"sourceId":String(replay.get("sourceId",""))}
						_retire_scene(region)
						progressed=true
						break
					if replay.get("status")=="pending_budget":
						# A replay may be waiting for its owner chunk or native packet
						# backpressure. Rotate immediately so it cannot consume this
						# frame's whole service budget by retrying the same scene.
						_scene_cursor=(index+1)%regions.size()
						_prefer_retirement=true
						return
					if replay.get("status")=="completed":
						_scene_cursor=(index+1)%regions.size()
						progressed=true
						break
					var demand_started := Time.get_ticks_usec()
					var demand_ready := _refresh_scene_group_demand(entry)
					_record_scene_unit("demand_refresh",demand_started)
					if not demand_ready: continue
					# The exact spatial safety closure is sufficient to resume gameplay.
					# This resident owner continues view-ranked/background publication.
					var packet_foreground_ready := bool(entry.get("packetMode",false)) \
							and _packet_foreground_physical_ready(region,entry.binding)
					if packet_foreground_ready:
						var milestone_base: Preparation.PreparedPublicationBase = entry.job._cpu.get("publicationBase")
						_record_publication_milestones(entry,entry.job.completed_physical_group_ids(entry.binding),
							milestone_base.description.publication_groups.groups.size() if milestone_base!=null else 0)
					if entry.phase=="publishing" and packet_foreground_ready:
						entry["firstUsefulWindowReady"]=true
						entry.phase="scene_ready"
						_scene_completed_count+=1
						progressed=true
						break
					var selection_started := Time.get_ticks_usec()
					var transaction: Dictionary = entry.job.pending_publication_transaction()
					_record_scene_unit("transaction_selection",selection_started)
					if transaction.get("status") in ["failed","cancelled"]:
						_failures[region] = {"binding":entry.binding,"reason":transaction.get("reason","publication_transaction_failed")}
						_retire_scene(region)
						progressed = true
						break
					var phase: String = entry.job.status_count().phase
					if bool(entry.get("packetMode",false)) and phase=="packet_wait":
						# A packet-mode transaction intentionally pins as pending until
						# this service submits its immutable packet.  Treat only that
						# precise pending reason as dispatchable; ordinary selection and
						# owner pending states remain retryable without worker work.
						if transaction.get("status")=="pending" and transaction.get("reason")=="physical_packet_foreground_demand_pending" \
								and packet_foreground_ready:
							var demand: Dictionary=entry.get("packetDemandStatus",{})
							var completed_count:=int(entry.job.status_count().get("physicalGroupsComplete",0))
							if _presentation_progress_due(entry,_view_revision,completed_count,
									int(demand.get("deferredGroupCount",0)),not demand.get("requests",[]).is_empty()):
								# Consume one bounded presentation window for the newest view.
								# An unchanged camera may warm only the capped resident working set;
								# exact owner/navigation revisions still refresh beyond that cap.
								entry["demandRevision"]=-1
								progressed=true
								break
							if entry.phase!="scene_ready":
								entry.phase="scene_ready"
								_scene_completed_count+=1
							progressed=true
							break
						if transaction.get("status")=="ready":
							var packet_guard_started := Time.get_ticks_usec()
							var packet_guard_allowed := _construction_transaction_allowed(transaction)
							_record_scene_unit("occupancy_guard",packet_guard_started)
							if not packet_guard_allowed:
								var deferred_occupancy: Dictionary = entry.job.defer_occupied_publication_transaction(int(transaction.transactionId))
								if deferred_occupancy.get("status")!="retained":
									_failures[region]={"binding":entry.binding,"reason":String(deferred_occupancy.get("reason","occupancy_defer_failed"))}
									_retire_scene(region)
								else:
									entry["occupancyWaitReason"]="actor_occupancy"
									entry["occupancyWaitCount"]=int(entry.get("occupancyWaitCount",0))+1
									entry["occupancyWaitStartedUsec"]=int(entry.get("occupancyWaitStartedUsec",Time.get_ticks_usec()))
								_scene_cursor=(index+1)%regions.size()
								progressed=true
								break
							var activated: Dictionary = entry.job.activate_physical_group_packet_scene(int(transaction.transactionId))
							if activated.get("status")!="pending_budget":
								_failures[region]={"binding":entry.binding,"reason":String(activated.get("reason","physical_packet_activate_failed")),
									"diagnostics":activated.duplicate(true),"transaction":transaction.duplicate(true)}
								_retire_scene(region)
							else:
								entry.erase("occupancyWaitReason")
								entry.erase("occupancyWaitStartedUsec")
							progressed=true
							break
						if transaction.get("status") not in ["ready","pending"] \
								or transaction.get("status")=="pending" and transaction.get("reason")!="physical_group_packet_pending": continue
						if not _inflight.is_empty(): continue
						# Navigation already has a prepared immutable source and live gameplay
						# requests. Let the outer shared-worker arbiter claim this idle turn
						# before another view-only physical packet.
						if not _navigation_physical_packet_pending(entry) and _has_dispatchable_navigation(ready): break
						var base: Preparation.PreparedPublicationBase = entry.job._cpu.get("publicationBase")
						var census: Dictionary = base.packet_eligibility
						if census.is_empty(): census=Preparation.classify_physical_group_packet_eligibility(base.description.publication_groups,base.building_source,base.furnishing_source)
						var allowed: bool = bool(census.get("ready",false))
						for group_id: String in transaction.groupIds:
							allowed = allowed and _packet_group_publishable(base.description,census,group_id)
						if not allowed:
							# A source revision can only narrow packet work.  Retain the
							# unsupported closure as deferred and leave the resident packet
							# scene intact; never replay the whole source through a legacy
							# path merely because one foreground tile needs a later family.
							var blocked: Dictionary = entry.get("packetDemandStatus",{}).duplicate(true)
							var ids: Array = blocked.get("blockedGroupIds",[])
							var deferred: Array = blocked.get("deferredGroupIds",[])
							var transaction_ids: Dictionary = {}
							for group_id: String in transaction.groupIds:
								transaction_ids[group_id] = true
								if not _packet_group_publishable(base.description,census,group_id) and not ids.has(group_id): ids.append(group_id)
								if not deferred.has(group_id): deferred.append(group_id)
							var remaining_requests: Array = []
							var remaining_group_ids: Dictionary={}
							for raw_request in blocked.get("requests",[]):
								if not raw_request is Dictionary: continue
								var remaining_ids: Array[String] = []
								for group_id: String in raw_request.get("groupIds",[]):
									if not transaction_ids.has(group_id):
										remaining_ids.append(group_id)
										remaining_group_ids[group_id]=true
								if not remaining_ids.is_empty():
									remaining_requests.append({"ownerId":raw_request.ownerId,"groupIds":remaining_ids,"priority":raw_request.priority})
							# A group previously recorded as explicitly blocked can become part
							# of another retained owner on a later merged navigation revision.
							# Foreground wins; keeping the stale diagnostic copy in both sets
							# would reject an otherwise dependency-complete compact plan.
							if bool(blocked.get("implicitDeferred",false)):
								var normalized_deferred: Array=[]
								for group_id: String in deferred:
									if not remaining_group_ids.has(group_id): normalized_deferred.append(group_id)
								deferred=normalized_deferred
							# Compact packet plans intentionally do not materialize the full
							# source-wide deferred complement.  Preserve that contract when a
							# selected transaction is later found to contain an ineligible
							# member; widening this update through the complete-scope API makes
							# an otherwise valid camera revision fail merely because unrelated
							# groups were implicit.
							var deferred_result: Dictionary = entry.job.replace_packet_foreground_group_demands_compact(
								remaining_requests,deferred,entry.binding) if bool(blocked.get("implicitDeferred",false)) \
								else entry.job.replace_packet_foreground_group_demands(remaining_requests,deferred,entry.binding)
							if deferred_result.get("status")!="retained":
								_failures[region] = {"binding":entry.binding,"reason":String(deferred_result.get("reason","packet_deferred_transaction_rejected"))}
								_retire_scene(region); progressed=true; break
							ids.sort()
							deferred.sort()
							blocked["blockedGroupIds"] = ids
							blocked["deferredGroupIds"] = deferred
							blocked["requests"] = remaining_requests
							blocked["status"] = "retained"
							blocked["reason"] = "packet_foreground_groups_deferred"
							entry["packetDemandStatus"] = blocked
							progressed=true; break
						var dispatch_started := Time.get_ticks_usec()
						var receipt := _worker.dispatch_physical_group_packet(base,transaction.groupIds,entry.binding)
						_record_scene_unit("packet_dispatch",dispatch_started)
						if receipt.get("status") in ["started","queued"] and not receipt.get("duplicate",false):
							_inflight={"kind":"physical_group_packet","region":region,"binding":entry.binding,"token":int(receipt.token),"transactionId":int(transaction.transactionId)}
							progressed=true
						break
					if transaction.get("status")!="ready": continue
					var guard_started := Time.get_ticks_usec()
					var guard_allowed := _construction_transaction_allowed(transaction)
					_record_scene_unit("occupancy_guard",guard_started)
					if not guard_allowed:
						if configuration!=_configuration_serial or demand_revision!=_demand_revision or _closing: break
						if bool(entry.get("packetMode",false)):
							# This packet already owns scene-side cursors/witnesses. Rotating it
							# would replay partial publication. Keep its exact phase pinned and
							# simply stop before the next mutation until the actor clears.
							entry["occupancyWaitReason"]="actor_occupancy_active_transaction"
							entry["occupancyWaitCount"]=int(entry.get("occupancyWaitCount",0))+1
							entry["occupancyWaitStartedUsec"]=int(entry.get("occupancyWaitStartedUsec",Time.get_ticks_usec()))
						else:
							var deferred_occupancy: Dictionary = entry.job.defer_occupied_publication_transaction(int(transaction.transactionId))
							if deferred_occupancy.get("status")!="retained":
								_failures[region]={"binding":entry.binding,"reason":String(deferred_occupancy.get("reason","occupancy_defer_failed"))}
								_retire_scene(region)
							else:
								entry["occupancyWaitReason"]="actor_occupancy"
								entry["occupancyWaitCount"]=int(entry.get("occupancyWaitCount",0))+1
								entry["occupancyWaitStartedUsec"]=int(entry.get("occupancyWaitStartedUsec",Time.get_ticks_usec()))
						_scene_cursor=(index+1)%regions.size()
						progressed=true
						break
					entry.erase("occupancyWaitReason")
					entry.erase("occupancyWaitStartedUsec")
					# Guard callbacks are external owners too: recapture no mutable
					# job from a generation/entry cancelled during the callback.
					# A packet scene remains a live publisher after its first gameplay
					# acknowledgement. Later rolling transactions must advance on that
					# same resident owner instead of being stranded in `building`.
					if not is_same(_scenes.get(region),entry) or entry.phase not in ["publishing","scene_ready"] \
							or entry.job.status_count().phase!=phase: continue
					if _admission.source_state(region).get("binding",{}) != entry.binding or not _scene_callbacks_ready(): continue
					_scene_cursor=(index+1)%regions.size()
					var job_started := Time.get_ticks_usec()
					var result: Dictionary=entry.job.advance(mini(remaining,SCENE_JOB_SLICE_USEC),int(transaction.transactionId))
					_record_scene_unit("job_advance",job_started)
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
		if not progressed:
			if not _retiring_scenes.is_empty():
				_prefer_retirement=true
				units+=1
				continue
			break
		units+=1
		_scene_max_step_usec=maxi(_scene_max_step_usec,Time.get_ticks_usec()-work_started)

func _has_scene_work(ready: Dictionary) -> bool:
	if not _scene_callbacks_ready(): return false
	for region: Vector2i in _prepared:
		if ready.has(region) and not _region_retiring(region) and not _failures.has(region): return true
	for region: Vector2i in _scenes:
		if ready.has(region) and _scenes[region].phase in ["publishing","scene_ready"]: return true
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


## Visual-only description of exact immutable source members. The scene job is
## retained as the receipt publisher; no collision, door or navigation proof is
## consulted here. An absent scene cannot turn a described site into an empty
## source, and a replacement scene cannot inherit its predecessor's receipts.
func visual_source_state(bounds: Rect2i) -> Dictionary:
	if _admission == null or not _bounded_region_rectangle(bounds):
		return {"status":"failed","reason":"invalid_citadel_visual_request"}
	var admitted: Dictionary = _admission.request_bounds(bounds)
	if admitted.get("status") != "ready": return admitted
	if _closing or _world_reset_pending:
		return {"status":"pending","reason":"citadel_visual_world_reset_pending"}
	var candidates: Array[Dictionary] = []
	var source_rows: Array = []
	var cell_world_bounds := Rect2(Vector2(bounds.position)*CitadelPublicationPlan.CELL,
		Vector2(bounds.size)*CitadelPublicationPlan.CELL)
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			# request_bounds returns ready only when every intersecting candidate
			# has a prepared or authoritative absent decision. Unknown states are
			# never interpreted as an empty visual source.
			if source.get("status") == "absent": continue
			if source.get("status") not in ["ready","prepared"]:
				return {"status":"pending","reason":"citadel_visual_source_decision_pending","region":region}
			if not source.get("reservationCells") is Rect2i:
				return {"status":"failed","reason":"citadel_visual_reservation_missing","region":region}
			if not source.reservationCells.intersects(bounds): continue
			if _failures.has(region):
				return {"status":"failed","reason":String(_failures[region].reason),"region":region}
			var binding: Dictionary = source.binding
			var plan = _publication_plan_for_binding(binding)
			if plan == null and _packet_bootstrap_bases.has(region):
				var bootstrap: Dictionary = _packet_bootstrap_bases[region]
				var base = bootstrap.get("base",null)
				if bootstrap.get("binding",{}) == binding and base != null:
					plan = base.publication_plan
			if plan == null and _prepared.has(region):
				var prepared: Dictionary = _prepared[region]
				var base = prepared.get("base",null)
				if prepared.get("binding",{}) == binding and base != null:
					plan = base.publication_plan
			if plan == null or not plan.matches(binding,plan.groups):
				return {"status":"pending","reason":"citadel_visual_description_pending","region":region}
			var described: Dictionary = plan.visual_member_requirements(bounds)
			if described.get("status") != "described": return described
			var job = _scenes[region].job if _scenes.has(region) and _scenes[region].binding == binding \
				and not _region_retiring(region) else null
			var site_id := String(binding.siteId)
			var omitted_members: Array[String] = []
			for record: Dictionary in described.members:
				var member_id := String(record.memberId)
				if job != null and job.visual_member_omitted(member_id,binding):
					omitted_members.append(member_id)
					continue
				if candidates.size() >= 16384:
					return {"status":"pending","reason":"citadel_visual_candidate_capacity","retryable":true}
				var member_bounds: AABB = record.bounds
				var member_world_bounds := Rect2(
					Vector2(member_bounds.position.x,member_bounds.position.z),
					Vector2(member_bounds.size.x,member_bounds.size.z))
				var clipped := member_world_bounds.intersection(cell_world_bounds)
				var world_position := clipped.get_center() if clipped.has_area() \
					else member_world_bounds.get_center()
				candidates.append({"candidateId":"citadel:%s:%s" % [site_id,member_id],
					"memberId":member_id,"positionXZ":world_position/CitadelPublicationPlan.CELL,
					"bounds":member_bounds,"binding":binding,"sourceSignature":plan.output_signature,
					"publisher":job})
			source_rows.append([site_id,binding,plan.output_signature,
				job.get_instance_id() if job != null else 0,omitted_members])
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(var_to_bytes([_seed,_generation,source_rows]))
	return {"status":"described","reason":"","descriptionComplete":true,
		"sourceRevision":digest.finish().hex_encode(),"candidates":candidates,
		"siteCount":source_rows.size(),"candidateCount":candidates.size()}

func _source_description_requirements(region: Vector2i, bounds: Rect2i, binding: Dictionary) -> Dictionary:
	if _closing or _world_reset_pending or _region_retiring(region):
		return {"status":"pending","reason":"structure_dependency_source_pending"}
	var description = null
	var profile: Dictionary = {}
	if _described.has(region):
		var entry: Dictionary = _described[region]
		if entry.configuration==_configuration_serial and entry.binding==binding:
			description=entry.description
			profile=entry.profile
	if description==null and _scenes.has(region) and _scenes[region].binding==binding:
		var job = _scenes[region].get("job",null)
		if job!=null and job.has_method("source_dependency_description"):
			description=job.source_dependency_description(binding)
			profile=_scenes[region].get("profile",{})
	if description==null or description.binding!=binding or description.origin!=profile.get("origin",Vector3.INF):
		return {"status":"pending","reason":"structure_dependency_source_stale"}
	# No scene receipt is invented at this earlier source boundary. Ordinary
	# physical/navigation gates still decide whether these obligations are ready.
	if description.has_method("regional_scheduling_requirements"):
		return description.regional_scheduling_requirements(bounds)
	return description.regional_group_requirements(bounds)

## A reservation can cover a navigation tile without contributing any physical
## member or crossing to it.  Such a described source has no scene-owned fact
## to publish for this query; retaining its bootstrap base is sufficient.
static func _requires_scene_publication(requirements: Dictionary) -> bool:
	return not requirements.get("groupIds",[]).is_empty() or not requirements.get("requiredCrossings",{}).is_empty()

func region_dependency_requirements(bounds: Rect2i) -> Dictionary:
	var result := {"status":"described","reason":"","dependencyBounds":[],"sourceRevisions":{},
		"missingSourceIds":[],"unresolvedCrossingIds":[],"requiredCrossings":{},"sites":[],
		"domainBounds":{"terrain":[bounds],"render":[bounds],"navigation":[bounds]},
		"physicalOwnerAcknowledgements":{},"publicationAcknowledged":false}
	if _admission == null or not _bounded_region_rectangle(bounds):
		result.merge({"status":"failed","reason":"invalid_structure_dependency_request"},true)
		return result
	var admitted: Dictionary = _admission.request_bounds(bounds)
	if admitted.get("status") != "ready":
		result.merge({"status":String(admitted.get("status","pending")),"reason":String(admitted.get("reason","structure_source_pending"))},true)
		return result
	if _world_reset_pending or _closing:
		result.merge({"status":"pending","reason":"structure_world_reset_pending"},true)
		return result
	# Preserve first-seen output order while keeping union membership constant
	# time. A Citadel query can contain thousands of dependency rectangles; using
	# Array.has for every insertion made this scheduling-only aggregation
	# quadratic on the gameplay thread.
	var dependency_bounds_seen := {}
	var terrain_bounds_seen := {bounds:true}
	var render_bounds_seen := {bounds:true}
	var navigation_bounds_seen := {bounds:true}
	var missing_source_ids_seen := {}
	var unresolved_crossing_ids_seen := {}
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			if source.get("status") not in ["ready","prepared"] or not source.reservationCells.intersects(bounds): continue
			var site_id := String(source.binding.siteId)
			result.sourceRevisions[site_id] = source.binding.duplicate(true)
			if _failures.has(region):
				result.status = "failed"; result.reason = String(_failures[region].reason)
				continue
			# Scheduling consumes immutable source membership regardless of scene
			# state. Live collision proof belongs to physical_publication_state;
			# moving bounds must never make the scheduler walk scene witnesses.
			var requirements: Dictionary = _source_description_requirements(region,bounds,source.binding)
			# Downstream retention consumes only immutable scheduling identity. Keep
			# the large source description at its owner instead of copying it into
			# every coordinator candidate.
			result.sites.append({"status":requirements.get("status","pending"),
				"reason":requirements.get("reason",""),"binding":source.binding,
				"groupIds":requirements.get("groupIds",[])})
			for dependency: Rect2i in requirements.get("dependencyBounds",[]):
				if not dependency_bounds_seen.has(dependency):
					dependency_bounds_seen[dependency] = true
					result.dependencyBounds.append(dependency)
				if not terrain_bounds_seen.has(dependency):
					terrain_bounds_seen[dependency] = true
					result.domainBounds.terrain.append(dependency)
				if not render_bounds_seen.has(dependency):
					render_bounds_seen[dependency] = true
					result.domainBounds.render.append(dependency)
			var declared_navigation_regions: Array = requirements.get("domainBounds",{}).get("navigation",[])
			if not declared_navigation_regions.is_empty():
				for navigation_region: Rect2i in declared_navigation_regions:
					if not navigation_bounds_seen.has(navigation_region):
						navigation_bounds_seen[navigation_region] = true
						result.domainBounds.navigation.append(navigation_region)
			for field: String in ["missingSourceIds","unresolvedCrossingIds"]:
				for id: String in requirements.get(field,[]):
					var seen: Dictionary = missing_source_ids_seen if field=="missingSourceIds" else unresolved_crossing_ids_seen
					if not seen.has(id):
						seen[id] = true
						result[field].append(id)
			for id: String in requirements.get("requiredCrossings",{}):
				if result.requiredCrossings.has(id) and result.requiredCrossings[id] != requirements.requiredCrossings[id]:
					if not missing_source_ids_seen.has(id):
						missing_source_ids_seen[id] = true
						result.missingSourceIds.append(id)
				else: result.requiredCrossings[id] = requirements.requiredCrossings[id]
				# New regional descriptions explicitly declare their immediate
				# navigation tiles. Fall back to crossing tile metadata only for
				# legacy descriptions that have not supplied that contract yet.
				if not declared_navigation_regions.is_empty(): continue
				for tile_key: String in requirements.requiredCrossings[id].get("tileKeys",[]):
					var coordinates: PackedStringArray = tile_key.split(",")
					if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int():
						if not missing_source_ids_seen.has(id):
							missing_source_ids_seen[id] = true
							result.missingSourceIds.append(id)
						continue
					var tile_bounds: Rect2i = Rect2i(Vector2i(int(coordinates[0]),int(coordinates[1]))*16,Vector2i.ONE*16)
					if not navigation_bounds_seen.has(tile_bounds):
						navigation_bounds_seen[tile_bounds] = true
						result.domainBounds.navigation.append(tile_bounds)
			if requirements.has("physicalOwnerAcknowledgements"):
				result.physicalOwnerAcknowledgements[site_id] = requirements.physicalOwnerAcknowledgements
			if requirements.get("status") != "described" and result.status != "failed":
				result.status = String(requirements.get("status","pending"))
				result.reason = String(requirements.get("reason","structure_dependency_source_pending"))
	if not result.missingSourceIds.is_empty() or not result.unresolvedCrossingIds.is_empty():
		result.status = "failed"; result.reason = "structure_source_dependencies_unresolved"
	return result

func region_publication_readiness(bounds: Rect2i) -> Dictionary:
	var result := region_dependency_requirements(bounds)
	if result.status != "described": return result
	var physical := physical_publication_state(bounds)
	result.status = String(physical.get("status","pending"))
	result.reason = String(physical.get("reason","structure_physical_publication_pending"))
	result["physicalPublication"] = physical
	result.publicationAcknowledged = result.status == "ready"
	result["acknowledgementScope"] = "structures_physical_only"
	return result

func region_dependency_revision(bounds: Rect2i) -> Array:
	var revision: Array = [_seed,_generation,_world_reset_pending,_closing]
	if _admission == null or not _bounded_region_rectangle(bounds): return revision + ["invalid"]
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			revision.append([region,source.get("status","unrequested"),source.get("binding",{}),
				_failures.get(region,{}),_described.get(region,{}).get("serial",0),
				_scenes[region].job.source_dependency_revision() if _scenes.has(region) else []])
	return revision

## Small change token for retained-demand polling. This deliberately omits the
## scene job's physical proof arrays; region_dependency_revision and the live
## publication owners remain authoritative at an acceptance boundary.
func region_dependency_scheduling_revision(bounds: Rect2i) -> Array:
	var revision: Array = [_seed,_generation,_world_reset_pending,_closing]
	if _admission == null or not _bounded_region_rectangle(bounds): return revision + ["invalid"]
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			var failure: Dictionary = _failures.get(region,{})
			revision.append([region,source.get("status","unrequested"),source.get("binding",{}),
				failure.get("status",""),failure.get("reason",""),_described.get(region,{}).get("serial",0),
				_scenes.has(region)])
	return revision

## Validate once at source admission, never per query or per worker turn.
## This is inventory schema validation; it does not certify physical readiness.
static func _valid_navigation_domain(value: Variant) -> bool:
	if not value is Dictionary or not value.is_read_only() or value.size()!=4 \
		or value.get("status")!="complete" or value.get("scope")!="source_navigation_output": return false
	var output_keys := {}
	for field: String in ["tileKeys","producerTileKeys"]:
		var keys: Variant = value.get(field)
		if not keys is Array or not keys.is_read_only() or keys.size()>MAX_NAVIGATION_DOMAIN_KEYS: return false
		var seen := {}
		for key: Variant in keys:
			if not key is String or key.length()>23 or seen.has(key): return false
			var coordinates: PackedStringArray = key.split(",",true)
			if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int(): return false
			var x := int(coordinates[0])
			var z := int(coordinates[1])
			if x < -2147483648 or x > 2147483647 or z < -2147483648 or z > 2147483647 or key!="%d,%d" % [x,z]: return false
			if field=="producerTileKeys" and not output_keys.has(key): return false
			seen[key] = true
		if field=="tileKeys": output_keys = seen
	return true

## Borrow a source inventory independently of cursor ownership. Described is
## neither a completed tile receipt nor scene/physics/navigation readiness.
func navigation_source_domain(region: Vector2i, expected_binding: Dictionary) -> Dictionary:
	if _closing or _world_reset_pending: return {"status":"pending","reason":"structure_world_reset_pending"}
	if not Worker.Preparation.valid_binding(expected_binding): return {"status":"failed","reason":"invalid_publication_binding"}
	if _admission==null or _region_retiring(region):
		return {"status":"pending","reason":"structure_navigation_domain_pending"}
	if _failures.has(region): return {"status":"failed","reason":_failures[region].reason}
	if not _navigation.has(region): return {"status":"pending","reason":"structure_navigation_domain_pending"}
	var current: Dictionary = _admission.source_state(region)
	var entry: Dictionary = _navigation[region]
	if current.get("status") not in ["ready","prepared"] or current.get("binding",{})!=expected_binding \
		or entry.binding!=expected_binding or not _current_binding(expected_binding):
		return {"status":"pending","reason":"structure_navigation_domain_stale"}
	var result := {"status":"described","binding":entry.binding,"domain":entry.domain}
	result.make_read_only()
	return result

func navigation_tile_sources(tile_key: Vector2i) -> Dictionary:
	var bounds := Rect2i(tile_key*16,Vector2i.ONE*16)
	if _admission==null: return {"status":"pending","reason":"structure_navigation_owner_missing","sources":[]}
	if _world_reset_pending or _closing: return {"status":"pending","reason":"structure_world_reset_pending","sources":[]}
	var admitted: Dictionary = _admission.request_bounds(bounds)
	if admitted.get("status")!="ready": return {"status":"pending","reason":"structure_navigation_source_pending","sources":[]}
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	var sources: Array = []
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			if source.get("status") not in ["ready","prepared"] or not source.reservationCells.intersects(bounds): continue
			if _world_reset_pending or _closing:
				return {"status":"pending","reason":"structure_world_reset_pending","sources":[]}
			var physical: Dictionary = _navigation_tile_physical_requirements(region,bounds,source.binding)
			if physical.get("status")!="described":
				return {"status":"pending","reason":physical.get("reason","structure_navigation_source_pending"),"sources":[]}
			# A packet-mode Citadel scene deliberately has no root until a physical
			# group is requested. This tile has no such group, so Citadel contributes
			# no source here and terrain remains the sole navigation authority.
			if physical.get("groupIds",[]).is_empty(): continue
			if not _scenes.has(region):
				return {"status":"pending","reason":"structure_navigation_scene_pending","sources":[]}
			var key := "%d,%d" % [tile_key.x,tile_key.y]
			var tile_receipt: Variant = null
			# A prepared navigation producer does not acknowledge scene collision.
			# Retain and freshly prove this tile's physical closure on every path,
			# including when another tile already caused the source to be prepared.
			if not _packet_navigation_physical_ready(region,source.binding,physical.get("groupIds",[]),_navigation_priority(key)):
				return {"status":"pending","reason":"structure_collision_publication_pending","sources":[]}
			if not _navigation.has(region):
				if not _begin_packet_navigation_source(region,source.binding,_navigation_priority(key)):
					return {"status":"pending","reason":"structure_navigation_source_pending","sources":[]}
				return {"status":"pending","reason":"structure_navigation_source_pending","sources":[]}
			if _navigation.has(region):
				var entry: Dictionary = _navigation[region]
				if entry.binding!=source.binding: return {"status":"pending","reason":"structure_navigation_source_stale","sources":[]}
				if not _request_navigation_tile(entry,key):
					return {"status":"pending","reason":"structure_navigation_request_capacity","sources":[]}
				tile_receipt = entry.receipts.get(key)
				if tile_receipt==null: return {"status":"pending","reason":"structure_navigation_tile_uncompiled","sources":[]}
			var artifact: Dictionary = _scenes[region].job.navigation_tile_artifact(key,source.binding,tile_receipt)
			if artifact.get("status")!="ready": return artifact
			sources.append(artifact)
	return {"status":"ready","sources":sources}


## Lightweight current-owner identity for navigation source-key validation.
## This never retains demand, scans physical receipts, or constructs an
## artifact. `navigation_tile_sources` remains the mandatory physical/crossing
## proof before capture; accepted installation checks may use this identity to
## reject a retired/replaced scene without replaying that proof on Main.
func navigation_tile_source_identity(tile_key: Vector2i) -> Dictionary:
	var bounds := Rect2i(tile_key*16,Vector2i.ONE*16)
	if _admission==null or _world_reset_pending or _closing:
		return {"status":"pending","reason":"structure_world_reset_pending","sources":[]}
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	var sources: Array = []
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			if source.get("status") not in ["ready","prepared"] or not source.get("reservationCells") is Rect2i \
					or not source.reservationCells.intersects(bounds): continue
			var physical: Dictionary = _navigation_tile_physical_requirements(region,bounds,source.binding)
			if physical.get("status")!="described":
				return {"status":"pending","reason":physical.get("reason","structure_navigation_description_pending"),"sources":[]}
			if physical.get("groupIds",[]).is_empty(): continue
			if not _scenes.has(region) or _scenes[region].binding!=source.binding or _region_retiring(region):
				return {"status":"pending","reason":"structure_navigation_scene_pending","sources":[]}
			sources.append({"binding":source.binding})
	return {"status":"ready","sources":sources}

func _navigation_tile_physical_requirements(region: Vector2i, bounds: Rect2i, binding: Dictionary) -> Dictionary:
	var described: Dictionary = _described.get(region,{})
	var description = described.get("description",null)
	if description==null or described.get("binding",{})!=binding:
		var base_entry: Dictionary = _packet_bootstrap_bases.get(region,{})
		var base = base_entry.get("base",null)
		description = base.description if base!=null else null
	if description==null and _scenes.has(region) and _scenes[region].binding==binding:
		var job = _scenes[region].get("job",null)
		var live_base = job._cpu.get("publicationBase",null) if job!=null else null
		description = live_base.description if live_base!=null else null
	if description==null or description.binding!=binding:
		return {"status":"pending","reason":"structure_navigation_description_pending"}
	# This query gates physical scene/collider publication only. The navigation
	# producer below still owns topology and crossing dependencies. Use the
	# conservative exact-member plan so a single tile cannot inherit the much
	# wider navigation-domain region closure.
	var base_entry: Dictionary = _packet_bootstrap_bases.get(region,{})
	var base = base_entry.get("base",null)
	if base==null and _scenes.has(region):
		var job = _scenes[region].get("job",null)
		base = job._cpu.get("publicationBase",null) if job!=null else null
	var compact_plan = base.publication_plan if base!=null else null
	return compact_plan.physical_group_requirements(bounds) if compact_plan!=null \
		else description.physical_group_requirements(bounds)

## Dense navigation remains deferred until the already-demanded foreground
## physical packet has a real scene receipt.  The packet scene still owns the
## exact source and binding; this only decides when the independent immutable
## navigation producer may take the shared worker.
func _packet_foreground_physical_ready(region: Vector2i, binding: Dictionary) -> bool:
	if not _scenes.has(region) or _scenes[region].binding!=binding: return false
	var entry: Dictionary = _scenes[region]
	if not bool(entry.get("packetMode",false)): return true
	var demand: Dictionary = entry.get("packetDemandStatus",{})
	if demand.get("status")!="retained": return false
	var receipt: Dictionary = entry.job.physical_groups_receipt(
		demand.get("readinessGroupIds",demand.get("foregroundGroupIds",[])),binding)
	return receipt.get("status")=="ready"

## A navigation tile receives its own exact physical group request.  It must
## not wait behind other retained tiles merely because they share a source.
func _packet_navigation_physical_ready(region: Vector2i, binding: Dictionary, group_ids: Array, priority: int) -> bool:
	if not _scenes.has(region) or _scenes[region].binding!=binding: return false
	var entry: Dictionary = _scenes[region]
	if not bool(entry.get("packetMode",false)): return true
	if priority<0 or priority>4: return false
	var required: Dictionary = entry.get("navigationPhysicalGroups",{})
	var changed := false
	# This map is a bounded active scheduling window, not a lifetime census.
	# Completed groups stay installed in the resident scene and need no retained
	# heap entry. Without pruning, a 64-tile background ring promoted thousands
	# of unrelated groups into every demand refresh and delayed the current tile.
	for retained_id: String in required.keys():
		if entry.job.physical_group_packet_completed_for_scheduling(retained_id,binding):
			required.erase(retained_id)
			changed = true
	var pending_ids: Array[String] = []
	for group_id: String in group_ids:
		# Scheduling asks only whether the packet transaction completed. The
		# navigation artifact immediately below performs one consolidated live
		# node/collision proof for the exact group closure. Repeating a standalone
		# physical proof for every group made a 100+ group tile scale quadratically.
		if not entry.job.physical_group_packet_completed_for_scheduling(group_id,binding):
			pending_ids.append(group_id)
	pending_ids.sort()
	if not pending_ids.is_empty():
		# A newly urgent tile may replace unstarted lower-priority scheduling
		# demand. Pinned worker/scene transactions remain owned and complete; only
		# the mutable next-work window changes.
		for retained_id: String in required.keys():
			if int(required[retained_id])>priority:
				required.erase(retained_id)
				changed = true
		var more_urgent_pending := false
		for retained_id: String in required:
			if int(required[retained_id])<priority:
				more_urgent_pending = true
				break
		if not more_urgent_pending:
			var additions := 0
			for group_id: String in pending_ids:
				if not required.has(group_id): additions+=1
			# A tile closure is atomic. Deferring the whole closure preserves its
			# dependency proof; inserting a prefix can strand a group whose support
			# was left outside the active window.
			if required.size()+additions<=MAX_ACTIVE_NAVIGATION_PHYSICAL_GROUPS:
				for group_id: String in pending_ids:
					if not required.has(group_id) or int(required[group_id])>priority:
						required[group_id]=priority
						changed=true
	if changed:
		entry["navigationPhysicalGroups"] = required
		entry["demandRevision"] = -1
	var pending: Dictionary = {}
	for group_id: String in pending_ids:
		if pending.size()<32:
			pending[group_id]="structure_collision_publication_pending"
	entry["navigationPhysicalPending"] = pending
	return pending.is_empty()

func _queue_packet_navigation_source(region: Vector2i, binding: Dictionary, priority: int) -> void:
	if priority<0 or priority>4: return
	var existing: Dictionary = _pending_packet_navigation.get(region,{})
	if existing.is_empty() or existing.get("binding",{})!=binding or int(existing.get("priority",4))>priority:
		_pending_packet_navigation[region] = {"binding":binding.duplicate(),"priority":priority}

func _dispatch_pending_packet_navigation() -> bool:
	if not _inflight.is_empty() or _pending_packet_navigation.is_empty(): return false
	var regions: Array[Vector2i] = []
	for region: Vector2i in _pending_packet_navigation:
		var pending: Dictionary = _pending_packet_navigation[region]
		if _scenes.has(region) and _scenes[region].binding==pending.get("binding",{}): regions.append(region)
		else: _pending_packet_navigation.erase(region)
	regions.sort_custom(func(a: Vector2i,b: Vector2i) -> bool:
		var pa: int = int(_pending_packet_navigation[a].priority)
		var pb: int = int(_pending_packet_navigation[b].priority)
		return pa<pb if pa!=pb else (a.y<b.y if a.y!=b.y else a.x<b.x))
	for region: Vector2i in regions:
		var pending: Dictionary = _pending_packet_navigation[region]
		if _begin_packet_navigation_source(region,pending.binding,int(pending.priority)):
			_pending_packet_navigation.erase(region)
			return true
	return false

func _begin_packet_navigation_source(region: Vector2i, binding: Dictionary, priority := 4) -> bool:
	if _navigation.has(region): return _navigation[region].binding==binding
	if not _scenes.has(region) or _scenes[region].binding!=binding: return false
	if not _inflight.is_empty():
		_queue_packet_navigation_source(region,binding,priority)
		return false
	var base: Preparation.PreparedPublicationBase = _scenes[region].job._cpu.get("publicationBase")
	var receipt := _worker.dispatch_publication_base_navigation(base,binding)
	if receipt.get("status") not in ["started","queued"] or receipt.get("duplicate",false): return false
	_inflight={"kind":"publication_base_navigation","region":region,"binding":binding,"token":int(receipt.token),"base":base,"profile":_scenes[region].profile}
	return true

## Readiness only, consumed by ordinary collision/loading gates. It never moves
## a player, invents geometry, publishes routes or upgrades diagnostic callbacks.
func physical_publication_state(bounds: Rect2i) -> Dictionary:
	if _admission == null: return {"status":"failed", "reason":"landmark_source_missing"}
	var source_ready: Dictionary = _admission.request_bounds(bounds)
	if source_ready.get("status") != "ready": return source_ready
	if _world_reset_pending or _closing: return {"status":"pending", "reason":"landmark_world_reset_pending"}
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end - Vector2i.ONE)
	var required := false
	var scene_ids: Array[int] = []
	for z in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			if source.get("status") not in ["ready", "prepared"]: continue
			if not source.reservationCells.intersects(bounds): continue
			var requirements: Dictionary
			if _scenes.has(region):
				requirements = _scenes[region].job.source_dependency_requirements(bounds,source.binding)
			else:
				requirements = _source_description_requirements(region,bounds,source.binding)
			if requirements.get("status")!="described":
				return {"status":"pending","reason":requirements.get("reason","landmark_group_description_pending")}
			if not _requires_scene_publication(requirements): continue
			required = true
			var state := scene_state(region)
			if state.status == "failed": return {"status":"failed", "reason":state.reason}
			if not _door_callbacks_ready() or not _require_tree_retirement_ack or not _scene_callbacks_ready():
				return {"status":"pending", "reason":"landmark_runtime_owners_pending"}
			if not _scenes.has(region) or _region_retiring(region) or state.get("binding",{}) != source.binding:
				return {"status":"pending", "reason":"landmark_structures_pending"}
			var job = _scenes[region].job
			if not requirements.get("groupDescriptionComplete",false):
				return {"status":"pending","reason":"landmark_group_description_pending"}
			# source_dependency_requirements just performed one nonyielding, fresh
			# batched proof for this acceptance operation. Consume those exact
			# receipts instead of immediately walking every witness a second time.
			var acknowledgements: Dictionary = requirements.get("physicalOwnerAcknowledgements",{})
			if acknowledgements.get("binding",{}) != source.binding or not acknowledgements.get("groups") is Dictionary:
				return {"status":"pending","reason":"landmark_physical_owner_acknowledgement_pending"}
			for group_id: String in requirements.get("groupIds",[]):
				var receipt: Dictionary = acknowledgements.groups.get(group_id,{})
				if receipt.get("status")!="ready": return receipt if not receipt.is_empty() else \
					{"status":"pending","reason":"structure_collision_publication_pending"}
			var site := scene_root(region)
			var parent: Node3D = _scene_parent.get_ref() as Node3D
			if not is_instance_valid(site) or site.is_queued_for_deletion() or not site.is_inside_tree() \
					or site.get_parent() != parent or not site.global_transform.is_equal_approx(Transform3D(Basis.IDENTITY,_scenes[region].profile.origin)):
				return {"status":"failed", "reason":"landmark_scene_owner_lost"}
			scene_ids.append(site.get_instance_id())
	return {"status":"ready", "reason":"landmark_physical_publication_complete", "required":required, "sceneInstanceIds":scene_ids}
