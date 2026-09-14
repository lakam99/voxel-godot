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
const DemandSet = preload("res://scripts/world/RegionDemandSet.gd")
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
const MAX_INCREMENTAL_FOREGROUND_GROUPS := 256

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
var _observer_region_bounds := Rect2i()
var _observer_bounds_rejected := false
var _demand_revision := 0
var _prepared: Dictionary = {}
var _navigation: Dictionary = {}
var _pending_packet_navigation: Dictionary = {}
# Packet publication records an exact oversized foreground closure here before
# retiring its partial scene into the complete-source lifecycle. A narrow or
# not-yet-described request must never set this marker or silently widen.
var _packet_source_fallback: Dictionary = {}
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
	_clear_retained_priorities()
	_packet_source_fallback = {}
	_observer_region_bounds = Rect2i()
	_observer_bounds_rejected = false
	_demand_revision += 1
	_inflight = {}
	_failures = {}
	_admission = admission
	var state: Dictionary = admission.stats()
	_generation = int(state.generation)
	_seed = String(state.worldSeed)

## The coordinator owns tokens, priorities and release hysteresis. Replacement
## is atomic and privately copied; this service owns only publication demand.
func set_retained_region_bounds(bounds: Array) -> bool:
	if _closing or bounds.size() > MAX_RETAINED_BOUNDS: return false
	var owned: Array[Rect2i] = []
	for rectangle in bounds:
		if not rectangle is Rect2i or not _bounded_region_rectangle(rectangle): return false
		owned.append(rectangle)
	if bounds == _retained_region_bounds and _retained_consumers.is_empty(): return true
	_retained_region_bounds = owned
	_retained_consumers = []
	_clear_retained_priorities()
	_demand_revision += 1
	return true

## One logical consumer owns its current query and trailing source pins.
## Discovery keys come only from original queries, never dependency envelopes.
func set_retained_source_requests(requests: Array) -> bool:
	if _closing or requests.size()>MAX_RETAINED_BOUNDS: return false
	var owned: Array[Dictionary] = []
	var discovery: Dictionary = {}
	var navigation_priorities: Dictionary = {}
	var binding_priorities: Dictionary = {}
	var discovery_priorities: Dictionary = {}
	var ids: Dictionary = {}
	for value in requests:
		if not value is Dictionary or not value.get("ownerId") is int or int(value.ownerId)<=0 or ids.has(value.ownerId): return false
		if not value.get("bounds") is Rect2i or not DemandSet.valid_bounds(value.bounds): return false
		if not value.get("priority") is int or int(value.priority)<0 or int(value.priority)>4 or not value.get("sites",[]) is Array: return false
		if not value.get("admissionKeys") is Array or value.admissionKeys.is_empty() or value.admissionKeys.size()>MAX_DISCOVERY_CHUNKS: return false
		if not value.get("navigationTileKeys") is Array or value.navigationTileKeys.is_empty() \
			or value.navigationTileKeys.size()>MAX_PENDING_NAVIGATION_TILES: return false
		if value.has("navigationTilePriorities") and not value.navigationTilePriorities is Dictionary: return false
		if value.get("sites",[]).size()>MAX_REGIONS: return false
		ids[value.ownerId] = true
		var consumer_keys: Dictionary = {}
		for key in value.admissionKeys:
			# Validate before multiplying int32 grid coordinates. Edge chunks are
			# clipped to the same legal terrain domain after exact compression.
			if not key is Vector2i or key.x < -35715 or key.x > 35714 or key.y < -35715 or key.y > 35714: return false
			consumer_keys[key] = true
			discovery[key] = true
			if discovery.size()>MAX_DISCOVERY_CHUNKS: return false
		var required: Dictionary = DemandSet.from_regions([value.bounds],DISCOVERY_CHUNK_SIZE,MAX_DISCOVERY_CHUNKS,32)
		if required.status!="ready" or not DemandSet.contains(consumer_keys,required.keys): return false
		var navigation_members: Dictionary = {}
		var navigation_keys: Array[String] = []
		var declared_tile_priorities: Dictionary = value.get("navigationTilePriorities",{})
		for raw_key in value.navigationTileKeys:
			if not raw_key is String or raw_key.length()>23: return false
			var coordinates: PackedStringArray = raw_key.split(",",true)
			if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int(): return false
			var x: int = int(coordinates[0])
			var z: int = int(coordinates[1])
			# Same finite cell domain as the regional navigation owner. Validate
			# scalar coordinates before Vector2i multiplication can overflow.
			if x < -62500 or x > 62499 or z < -62500 or z > 62499 or raw_key!="%d,%d" % [x,z]: return false
			var tile := Vector2i(x,z)
			if not navigation_members.has(tile): navigation_keys.append(raw_key)
			navigation_members[tile] = true
			var tile_priority: int = int(declared_tile_priorities.get(raw_key,value.priority))
			if tile_priority<0 or tile_priority>4: return false
			navigation_priorities[raw_key] = mini(int(navigation_priorities.get(raw_key,4)),tile_priority)
			if navigation_priorities.size()>MAX_PENDING_NAVIGATION_TILES: return false
		var required_navigation: Dictionary = DemandSet.from_regions([value.bounds],NAVIGATION_TILE_CELLS,MAX_PENDING_NAVIGATION_TILES)
		if required_navigation.status!="ready" or not DemandSet.contains(navigation_members,required_navigation.keys): return false
		navigation_keys.sort()
		var admission_keys: Array[Vector2i] = []
		for key: Vector2i in consumer_keys:
			admission_keys.append(key)
			var chunk_bounds := Rect2i(key*DISCOVERY_CHUNK_SIZE,Vector2i.ONE*DISCOVERY_CHUNK_SIZE)
			var low: Vector2i = Field.region_for_cell(chunk_bounds.position)
			var high: Vector2i = Field.region_for_cell(chunk_bounds.end-Vector2i.ONE)
			for z: int in range(low.y,high.y+1):
				for x: int in range(low.x,high.x+1):
					var region := Vector2i(x,z)
					if not discovery_priorities.has(region): discovery_priorities[region] = {}
					discovery_priorities[region][key] = mini(int(discovery_priorities[region].get(key,4)),int(value.priority))
		admission_keys.sort_custom(func(a: Vector2i,b: Vector2i): return a.y<b.y if a.y!=b.y else a.x<b.x)
		var sites: Array[Dictionary] = []
		var site_bindings: Array[Dictionary] = []
		var total_group_ids := 0
		for site in value.get("sites",[]):
			if not site is Dictionary: return false
			if not site.has("groupIds"): continue # Source still pending; retain original area.
			if not site.get("binding") is Dictionary or not site.groupIds is Array or site.groupIds.size()>30000: return false
			var binding: Dictionary = site.binding
			if binding.size()!=3 or not binding.get("siteId") is String or binding.siteId.is_empty() \
					or not binding.get("sourceKey") is String or binding.sourceKey.is_empty() \
					or not binding.get("generation") is int or int(binding.generation)<=0: return false
			# Keep historical revisions distinct. Exact duplicate bindings would
			# issue competing orders to one scene; old IDs must not migrate to a
			# newer binding merely because the site's name is unchanged.
			if site_bindings.has(binding): return false
			site_bindings.append(binding)
			var group_ids: Array[String] = []
			var seen_groups: Dictionary = {}
			for id in site.groupIds:
				if not id is String or id.is_empty(): return false
				if seen_groups.has(id): continue
				seen_groups[id] = true
				group_ids.append(id)
			total_group_ids += group_ids.size()
			if total_group_ids > 30000: return false
			var foreground_keys: Array[String] = []
			var foreground_seen: Dictionary = {}
			if site.has("foregroundNavigationTileKeys"):
				if not site.foregroundNavigationTileKeys is Array or site.foregroundNavigationTileKeys.size()>MAX_PENDING_NAVIGATION_TILES: return false
				for raw_key in site.foregroundNavigationTileKeys:
					if not raw_key is String or raw_key.length()>23: return false
					var coordinates: PackedStringArray = raw_key.split(",",true)
					if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int(): return false
					var tile := Vector2i(int(coordinates[0]),int(coordinates[1]))
					if tile.x < -62500 or tile.x > 62499 or tile.y < -62500 or tile.y > 62499 \
							or raw_key!="%d,%d" % [tile.x,tile.y] or not navigation_members.has(tile): return false
					if not foreground_seen.has(raw_key): foreground_keys.append(raw_key)
					foreground_seen[raw_key] = true
			foreground_keys.sort()
			var foreground_groups: Array[String] = []
			var foreground_group_seen: Dictionary = {}
			if site.has("foregroundGroupIds"):
				if not site.foregroundGroupIds is Array or site.foregroundGroupIds.size()>30000: return false
				for id in site.foregroundGroupIds:
					if not id is String or id.is_empty() or not seen_groups.has(id): return false
					if not foreground_group_seen.has(id): foreground_groups.append(id)
					foreground_group_seen[id] = true
			foreground_groups.sort()
			var retained_site := {"binding":site.binding.duplicate(),"groupIds":group_ids,"foregroundNavigationTileKeys":foreground_keys}
			# Empty is meaningful only when the coordinator explicitly supplied the
			# capsule closure. Legacy/direct callers omit the field and retain their
			# established tile-derived packet request.
			if site.has("foregroundGroupIds"): retained_site["foregroundGroupIds"] = foreground_groups
			sites.append(retained_site)
			var binding_key := _priority_binding_key(binding)
			binding_priorities[binding_key] = mini(int(binding_priorities.get(binding_key,4)),int(value.priority))
		var retained_tile_priorities := {}
		for key: String in navigation_keys: retained_tile_priorities[key] = int(declared_tile_priorities.get(key,value.priority))
		owned.append({"ownerId":value.ownerId,"bounds":value.bounds,"priority":value.priority,
			"admissionKeys":admission_keys,"navigationTileKeys":navigation_keys,"navigationTilePriorities":retained_tile_priorities,"sites":sites})
	var bounds: Array[Rect2i] = []
	var world_bounds := Rect2i(-1000000,-1000000,2000000,2000000)
	for rectangle: Rect2i in DemandSet.rectangles(discovery,DISCOVERY_CHUNK_SIZE):
		var clipped: Rect2i = rectangle.intersection(world_bounds)
		if not _bounded_region_rectangle(clipped): return false
		bounds.append(clipped)
	if owned==_retained_consumers and bounds==_retained_region_bounds: return true
	_retained_consumers = owned
	_retained_region_bounds = bounds
	_retained_navigation_priorities = navigation_priorities
	_retained_binding_priorities = binding_priorities
	_retained_discovery_priorities = discovery_priorities
	_demand_revision += 1
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
		if source.get("status") in ["ready","prepared"]:
			var intersects := false
			for rectangle: Rect2i in matching:
				if source.reservationCells.intersects(rectangle):
					intersects = true
					break
			if not intersects or not _current_binding(source.binding): continue
			ready[region] = source
			if source.status == "prepared" and not _prepared.has(region) and not _scenes.has(region) and not _region_retiring(region) and not _failures.has(region) \
					and (_inflight.is_empty() or _inflight.region != region):
				_admission.request_source(region,true)
		desired[region] = true
	_desired = desired
	return ready

func _current_binding(binding: Dictionary) -> bool:
	return int(binding.get("generation",-1)) == _generation \
		and String(_admission.stats().worldSeed) == _seed

func _prune_unwanted(ready: Dictionary) -> void:
	for region: Vector2i in _packet_source_fallback.keys():
		if not ready.has(region) or ready[region].binding != _packet_source_fallback[region]:
			_packet_source_fallback.erase(region)
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
	if _packet_source_fallback.get(region,{})==binding: return false
	for consumer: Dictionary in _retained_consumers:
		for site: Dictionary in consumer.sites:
			if site.binding==binding and (not site.groupIds.is_empty() or not site.get("foregroundNavigationTileKeys",[]).is_empty()): return true
	return false

## A no-site retained source consumer is the coordinator's first pass before
## it has a description from which to derive group membership.  It is the one
## case that may retain a publication base without entering a whole-source
## scene.  A consumer that already names sites (including an empty/ineligible
## group set) is an actual publication demand and follows normal eligibility.
func _packet_bootstrap_requested_for_source(source: Dictionary) -> bool:
	for fallback_binding in _packet_source_fallback.values():
		if fallback_binding==source.get("binding",{}): return false
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

func _packet_foreground_plan(region: Vector2i, binding: Dictionary, description, base = null) -> Dictionary:
	if description==null or description.binding!=binding or not description.publication_groups.get("ready",false):
		return {"status":"pending","reason":"packet_foreground_description_pending"}
	var foreground: Dictionary = {}
	var blocked: Dictionary = {}
	var requests: Array[Dictionary] = []
	var boundary_groups: Dictionary = {}
	var census: Dictionary = base.packet_eligibility if base!=null else {}
	if base!=null and census.is_empty():
		census=Preparation.classify_physical_group_packet_eligibility(description.publication_groups,base.building_source,base.furnishing_source)
	var consumers: Array = _retained_consumers.duplicate()
	# The foreground observer is a real owner of immediate loading work, even
	# before the streaming coordinator has rebuilt a retained source-members
	# record after admission.  Describe its exact source closure here; this is
	# scheduling input only.  Packet compilation, scene installation and fresh
	# collision validation remain below this boundary.
	var observer_source: Dictionary = _admission.source_state(region) if _admission!=null else {}
	if _observer_region_bounds.has_area() and observer_source.get("binding",{})==binding \
			and observer_source.get("reservationCells") is Rect2i and observer_source.reservationCells.intersects(_observer_region_bounds):
		var observer_requirements: Dictionary = description.physical_group_requirements(_observer_region_bounds)
		if observer_requirements.get("status")!="described":
			return {"status":observer_requirements.get("status","pending"),"reason":observer_requirements.get("reason","packet_observer_description_pending")}
		consumers.append({"ownerId":"observer:%d,%d,%d,%d" % [_observer_region_bounds.position.x,_observer_region_bounds.position.y,
			_observer_region_bounds.size.x,_observer_region_bounds.size.y],"bounds":_observer_region_bounds,"priority":0,
			"sites":[{"binding":binding,"groupIds":observer_requirements.get("groupIds",[]),
			"foregroundGroupIds":observer_requirements.get("groupIds",[])}]})
	for consumer: Dictionary in consumers:
		for site: Dictionary in consumer.sites:
			if site.binding!=binding: continue
			var ids: Dictionary = {}
			if site.has("foregroundGroupIds"):
				for id: String in site.foregroundGroupIds: ids[id] = true
				# An explicitly empty immediate closure means this streaming tile has
				# no member of its own.  It is not permission to leave a retained
				# source resident forever without a physical packet.  When the
				# consumer already intersects the conservative reservation, retain
				# the nearest eligible exterior structural closure.  The worker still
				# prepares the immutable packet and the scene validates it at the
				# physical installation boundary.
				if ids.is_empty():
					var boundary: Dictionary = _packet_exterior_boundary_requirements(region,binding,description,consumer,census)
					if boundary.get("status") not in ["described","pending"]:
						return {"status":boundary.get("status","failed"),"reason":boundary.get("reason","packet_exterior_boundary_failed")}
					if boundary.get("status")=="described":
						for id: String in boundary.get("groupIds",[]): ids[id] = true
						if not String(boundary.get("boundaryGroupId","")).is_empty():
							boundary_groups[String(boundary.boundaryGroupId)] = true
			else:
				var foreground_tiles: Array = site.get("foregroundNavigationTileKeys",[])
				if foreground_tiles.is_empty():
				# Existing direct service callers retain their explicit group closure.
				# Production streaming supplies tile keys, which are always derived here.
					for id: String in site.groupIds: ids[id] = true
				else:
					for key: String in foreground_tiles:
						var coordinates: PackedStringArray = key.split(",",true)
						if coordinates.size()!=2: return {"status":"failed","reason":"invalid_packet_foreground_tile"}
						var tile := Vector2i(int(coordinates[0]),int(coordinates[1]))
						var requirements: Dictionary = description.physical_group_requirements(Rect2i(tile*NAVIGATION_TILE_CELLS,Vector2i.ONE*NAVIGATION_TILE_CELLS))
						if requirements.get("status")!="described": return {"status":requirements.get("status","pending"),"reason":requirements.get("reason","packet_foreground_description_pending")}
						for id: String in requirements.get("groupIds",[]): ids[id] = true
					# A capsule can overlap the source's declared reservation before any
					# of its navigation tiles intersects source geometry.  Keep the
					# ordinary tile-derived closure empty in that case, but give the
					# packet scene one nearest real structural collision closure to
					# publish.  The live scene receipt remains the only acknowledgement.
					if ids.is_empty():
						var boundary: Dictionary = _packet_exterior_boundary_requirements(region,binding,description,consumer,census)
						if boundary.get("status") not in ["described","pending"]:
							return {"status":boundary.get("status","failed"),"reason":boundary.get("reason","packet_exterior_boundary_failed")}
						if boundary.get("status")=="described":
							for id: String in boundary.get("groupIds",[]):
								ids[id] = true
							if not String(boundary.get("boundaryGroupId","")).is_empty():
								boundary_groups[String(boundary.boundaryGroupId)] = true
			var ordered: Array[String] = []
			for id: String in ids:
				ordered.append(id)
			ordered.sort()
			var publishable: Array[String] = []
			for id: String in ordered:
				if not description.publication_groups.groups.has(id): return {"status":"failed","reason":"packet_foreground_group_unknown","groupId":id}
				var eligible := false
				if base!=null and census.get("ready",false):
					eligible = _packet_group_publishable(description,census,id)
				if base==null or eligible: publishable.append(id)
				else: blocked[id] = true
			if not publishable.is_empty(): requests.append({"ownerId":"region:%s" % str(consumer.ownerId),"groupIds":publishable,"priority":consumer.priority})
			for id: String in publishable: foreground[id] = true
	var deferred: Array[String] = []
	for id: String in description.publication_groups.groups:
		if not foreground.has(id): deferred.append(id)
	deferred.sort()
	var blocked_ids: Array[String] = []
	for id: String in blocked:
		blocked_ids.append(id)
	blocked_ids.sort()
	var boundary_ids: Array = boundary_groups.keys()
	boundary_ids.sort()
	return {"status":"ready","requests":requests,"deferredGroupIds":deferred,"foregroundGroupIds":foreground.keys(),
		"blockedGroupIds":blocked_ids,"boundaryGroupIds":boundary_ids,"censusReady":census.get("ready",base==null)}

func _packet_group_publishable(description, census: Dictionary, group_id: String) -> bool:
	if not bool(census.get("groups",{}).get(group_id,{}).get("eligible",false)):
		return false
	var group: Dictionary = description.publication_groups.get("groups",{}).get(group_id,{})
	# The frozen compiler can describe a door, but it cannot create the ordinary
	# portal lifecycle.  Keep that packet demand retained until the scene owner
	# has supplied both callbacks instead of dispatching work that must fail at
	# installation.
	return group.get("doorPartIds",[]).is_empty() or _door_callbacks_ready()

## The source reservation is a conservative physical-safety envelope.  When a
## retained consumer already intersects it but has no tile-owned group, request
## the nearest declared structural closure rather than asking the player to
## enter an unpublished collision area.  This only selects immutable source
## membership; `BuildingScenePublicationJob` still validates and acknowledges
## the physical packet when it is installed.
func _packet_exterior_boundary_requirements(region: Vector2i, binding: Dictionary, description, consumer: Dictionary, census: Dictionary) -> Dictionary:
	if _admission==null or not consumer.get("bounds") is Rect2i:
		return {"status":"pending","reason":"packet_exterior_source_pending"}
	var source: Dictionary = _admission.source_state(region)
	if source.get("binding",{})!=binding or not source.get("reservationCells") is Rect2i:
		return {"status":"pending","reason":"packet_exterior_source_pending"}
	var reservation: Rect2i = source.reservationCells
	if not reservation.intersects(consumer.bounds):
		return {"status":"described","groupIds":[]}
	var eligible: Dictionary = {}
	if census.get("ready",false):
		for group_id: String in census.get("groups",{}):
			if _packet_group_publishable(description,census,group_id):
				eligible[group_id] = true
	return description.exterior_structural_group_requirements(consumer.bounds,eligible)

func _base_packet_eligible(base, binding: Dictionary, region: Vector2i) -> Dictionary:
	if base==null or not base.matches(binding): return {"status":"failed","reason":"packet_publication_base_stale"}
	var plan: Dictionary = _packet_foreground_plan(region,binding,base.description,base)
	if plan.get("status")!="ready": return plan
	if not plan.get("censusReady",false): return {"status":"failed","reason":"packet_foreground_census_missing"}
	if plan.get("foregroundGroupIds",[]).size()>MAX_INCREMENTAL_FOREGROUND_GROUPS:
		return {"status":"failed","reason":"packet_foreground_scope_too_large","groupCount":plan.foregroundGroupIds.size()}
	return plan

func _collect_publication_base(region: Vector2i, current: Dictionary, result: Dictionary) -> void:
	var base = result.get("base")
	if result.get("ready",false) and base!=null and _packet_bootstrap_requested_for_source(current):
		_retain_packet_bootstrap_base(region,current,base,result.get("profile",{}))
		if _packet_bootstrap_bases.has(region):
			_accepted_count += 1
			_inflight = {}
			return
	var packet_plan: Dictionary = _base_packet_eligible(base,current.binding,region) if result.get("ready",false) and base!=null else {}
	if not result.get("ready",false) or base==null or packet_plan.get("status")!="ready":
		if packet_plan.get("reason")=="packet_foreground_scope_too_large":
			_packet_source_fallback[region] = current.binding.duplicate()
		if base!=null: _retire({"base":base})
		var receipt := _worker.dispatch_scene_source(current.get("source",{}),current.binding)
		if receipt.get("status") in ["started","queued"] and not receipt.get("duplicate",false):
			_inflight={"kind":"preparation","region":region,"binding":current.binding.duplicate(),"token":int(receipt.token)}
			_dispatch_count+=1
		else: _inflight={}
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
	var activated: Dictionary = entry.job.activate_physical_group_packet_scene(transaction_id)
	if activated.get("status")!="pending_budget":
		_failures[region]={"binding":current.binding,"reason":String(activated.get("reason","physical_packet_activate_failed"))}; _retire_scene(region)

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
		var bootstrap_requested: bool = _packet_bootstrap_requested_for_source(source)
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
			# Exact group membership is now known but cannot use packet mode.  Drop
			# the base and enter the established source path only for that ineligible
			# demand; an unresolved bootstrap never falls back on its own.
			_retire(bootstrap)
			_packet_bootstrap_bases.erase(region)
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
	_retained_region_bounds = []
	_retained_consumers = []
	_clear_retained_priorities()
	_observer_region_bounds = Rect2i()
	_demand_revision += 1
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
			"packetForegroundGroups":demand.get("foregroundGroupIds",[]).size(),"packetDeferredGroups":demand.get("deferredGroupIds",[]).size(),
			"physicalGroupsComplete":int(job_status.get("physicalGroupsComplete",0)),"physicalGroupsTotal":int(job_status.get("physicalGroupsTotal",0)),
			"retainedGroupRequests":int(job_status.get("retainedGroupRequests",0)),"publicationTransactionId":int(job_status.get("publicationTransactionId",0))})
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
		"residentSites":_resident_region_count(),"residentLimit":MAX_REGIONS,
		"worldResetPending":_world_reset_pending,"worldResetReady":world_reset_ready(),
		"preparedSites":_prepared.size(),"bootstrapBases":_packet_bootstrap_bases.size(),"describedSites":_described.size(),"pendingRetirements":_retired.size(),
		"activeToken":_inflight.get("token",0),"failures":_failures.duplicate(true),
		"dispatchCount":_dispatch_count,"acceptedCount":_accepted_count,"maxAdvanceUsec":_max_advance_usec,
		"publicationReady":false,"worker":_last_worker_status,"sourceScheduling":scheduling,
		"sceneDiagnostics":scenes,"demandRevision":_demand_revision,
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
			or (_described.has(region) and _described[region].description!=description):
		_failures[region] = {"binding":prepared.binding,"reason":"scene_description_identity_mismatch"}
		_retire(prepared)
		_prepared.erase(region)
		return false
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
	_scenes[region]={"region":region,"binding":prepared.binding,"profile":prepared.profile,"job":job,"phase":"publishing","packetMode":packet_mode}
	_prepared.erase(region)
	_scene_started_count+=1
	return true

func _refresh_scene_group_demand(entry: Dictionary) -> bool:
	if entry.get("demandRevision",-1)==_demand_revision: return true
	if bool(entry.get("packetMode",false)):
		var base: Preparation.PreparedPublicationBase = entry.job._cpu.get("publicationBase")
		var plan: Dictionary = _packet_foreground_plan(entry.region,entry.binding,base.description if base!=null else null,base)
		if plan.get("status")!="ready":
			entry["packetDemandStatus"] = plan.duplicate(true)
			return false
		if plan.get("foregroundGroupIds",[]).size()>MAX_INCREMENTAL_FOREGROUND_GROUPS:
			# A city-scale closure is cheaper and more stable as one prepared source
			# than as thousands of packet receipts that are replaced while walking.
			# Preserve the source binding, retire the partial packet scene, and let
			# the next worker turn use the established full-source lifecycle.
			_packet_source_fallback[entry.region] = entry.binding.duplicate()
			_retire_scene(entry.region)
			return false
		var navigation_groups: Dictionary = entry.get("navigationPhysicalGroups",{})
		if not navigation_groups.is_empty():
			# Navigation publication can ask for tiles from both the capsule and the
			# retained background ring.  They share a packet scene, but they must not
			# share foreground priority: otherwise every background physical closure
			# is promoted into the startup gate before the capsule tile can receive a
			# receipt. Preserve the per-tile request priority all the way to group
			# selection. A group shared by tiles keeps its most urgent owner.
			var requested_by_priority: Dictionary = {}
			var navigation_ids: Dictionary = {}
			for group_id: String in navigation_groups:
				var priority: int = int(navigation_groups[group_id])
				if priority<0 or priority>4:
					entry["packetDemandStatus"] = {"status":"failed","reason":"invalid_navigation_physical_priority"}
					return false
				if not requested_by_priority.has(priority): requested_by_priority[priority] = []
				requested_by_priority[priority].append(group_id)
				navigation_ids[group_id] = true
			for priority: int in range(5):
				if not requested_by_priority.has(priority): continue
				var requested: Array[String] = []
				for group_id: String in requested_by_priority[priority]: requested.append(group_id)
				requested.sort()
				plan.requests.append({"ownerId":"navigation:%d,%d:%d" % [entry.region.x,entry.region.y,priority],"groupIds":requested,"priority":priority})
				if priority==0:
					for group_id: String in requested:
						if not plan.foregroundGroupIds.has(group_id): plan.foregroundGroupIds.append(group_id)
			plan.foregroundGroupIds.sort()
			var deferred: Array[String] = []
			for group_id: String in plan.deferredGroupIds:
				if not navigation_ids.has(group_id): deferred.append(group_id)
			plan.deferredGroupIds = deferred
		var packet_result: Dictionary = entry.job.replace_packet_foreground_group_demands(plan.requests,plan.deferredGroupIds,entry.binding)
		if packet_result.get("status")!="retained":
			entry["packetDemandStatus"] = packet_result.duplicate(true)
			return false
		entry["packetDemandStatus"] = {"status":"retained","reason":"packet_foreground_groups_deferred" if not plan.blockedGroupIds.is_empty() and plan.requests.is_empty() else "",
			"requests":plan.requests.duplicate(true),
			"foregroundGroupIds":plan.foregroundGroupIds.duplicate(),"deferredGroupIds":plan.deferredGroupIds.duplicate(),
			"blockedGroupIds":plan.blockedGroupIds.duplicate(),"boundaryGroupIds":plan.boundaryGroupIds.duplicate()}
		entry["demandRevision"] = _demand_revision
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
					if not _refresh_scene_group_demand(entry): continue
					var transaction: Dictionary = entry.job.pending_publication_transaction()
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
								and _packet_foreground_physical_ready(region,entry.binding):
							if entry.phase!="scene_ready":
								entry.phase="scene_ready"
								_scene_completed_count+=1
							progressed=true
							break
						if transaction.get("status") not in ["ready","pending"] \
								or transaction.get("status")=="pending" and transaction.get("reason")!="physical_group_packet_pending": continue
						if not _inflight.is_empty(): continue
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
							for raw_request in blocked.get("requests",[]):
								if not raw_request is Dictionary: continue
								var remaining_ids: Array[String] = []
								for group_id: String in raw_request.get("groupIds",[]):
									if not transaction_ids.has(group_id): remaining_ids.append(group_id)
								if not remaining_ids.is_empty():
									remaining_requests.append({"ownerId":raw_request.ownerId,"groupIds":remaining_ids,"priority":raw_request.priority})
							var deferred_result: Dictionary = entry.job.replace_packet_foreground_group_demands(remaining_requests,deferred,entry.binding)
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
						var receipt := _worker.dispatch_physical_group_packet(base,transaction.groupIds,entry.binding)
						if receipt.get("status") in ["started","queued"] and not receipt.get("duplicate",false):
							_inflight={"kind":"physical_group_packet","region":region,"binding":entry.binding,"token":int(receipt.token),"transactionId":int(transaction.transactionId)}
							progressed=true
						break
					if transaction.get("status")!="ready": continue
					if not _construction_transaction_allowed(transaction):
						if configuration!=_configuration_serial or demand_revision!=_demand_revision or _closing: break
						continue
					# Guard callbacks are external owners too: recapture no mutable
					# job from a generation/entry cancelled during the callback.
					if not is_same(_scenes.get(region),entry) or entry.phase!="publishing" or entry.job.status_count().phase!=phase: continue
					if _admission.source_state(region).get("binding",{}) != entry.binding or not _scene_callbacks_ready(): continue
					_scene_cursor=(index+1)%regions.size()
					var result: Dictionary=entry.job.advance(remaining,int(transaction.transactionId))
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
			if not _navigation.has(region):
				if not _packet_navigation_physical_ready(region,source.binding,physical.get("groupIds",[]),_navigation_priority(key)):
					return {"status":"pending","reason":"structure_collision_publication_pending","sources":[]}
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
	return description.physical_group_requirements(bounds)

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
	for group_id: String in demand.get("foregroundGroupIds",[]):
		if entry.job.physical_group_receipt(group_id,binding).get("status")!="ready": return false
	return true

## A navigation tile receives its own exact physical group request.  It must
## not wait behind other retained tiles merely because they share a source.
func _packet_navigation_physical_ready(region: Vector2i, binding: Dictionary, group_ids: Array, priority: int) -> bool:
	if not _scenes.has(region) or _scenes[region].binding!=binding: return false
	var entry: Dictionary = _scenes[region]
	if not bool(entry.get("packetMode",false)): return true
	if priority<0 or priority>4: return false
	var required: Dictionary = entry.get("navigationPhysicalGroups",{})
	var changed := false
	for group_id: String in group_ids:
		if not required.has(group_id) or int(required[group_id])>priority:
			required[group_id] = priority
			changed = true
	if changed:
		entry["navigationPhysicalGroups"] = required
		entry["demandRevision"] = -1
	for group_id: String in group_ids:
		if entry.job.physical_group_receipt(group_id,binding).get("status")!="ready": return false
	return true

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
