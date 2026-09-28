extends RefCounted
class_name RegionalNavigationPublication

## Retained regional demand and acknowledgement adapter. No geometry, route,
## descriptor or worker authority: all publication uses the existing route queue.
## Bounds are half-open XZ terrain cells. Sparse requests retain exact tile sets;
## the caller supplies dependency closure without enclosing the gaps between it.
const TILE_SIZE := 16
const WORLD_CELL_LIMIT := 1000000
const MAX_REQUESTS := 64
const MAX_TILES := 512
const MAX_ROWS_PER_ADVANCE := 4096
const RECEIPT_RECHECK_MSEC := 1000
var last_rejection := ""
var _main: WeakRef
var _adapter: WeakRef
var _nav: WeakRef
var _publisher: WeakRef
var _structures: WeakRef
var _seed := ""
var _next_id := 1
var _requests: Dictionary = {}
var _tiles: Dictionary = {}
var _tile_owner_counts: Dictionary = {}
var _tile_priority_counts: Dictionary = {}
var _order: Array[String] = []
var _cursor := 0
var _completion_debt := {}
var _completion_order: Array[String] = []
var _last_frame := -1
var _max_advance_usec := 0
var _ready_cache_hits := 0
var _receipt_rechecks := 0
var _tile_visits := 0
var _last_tile_work := {}
var _completion_visits := 0
var _last_completion_work := {}
var _collection_usec := 0

func configure(main_node) -> bool:
	_release_all_publish_owners()
	if _nav != null:
		var previous = _nav.get_ref()
		if is_instance_valid(previous) and previous.has_signal("accepted_tile_changed") \
				and previous.is_connected("accepted_tile_changed",_on_accepted_tile_changed):
			previous.disconnect("accepted_tile_changed",_on_accepted_tile_changed)
	_requests.clear()
	_tiles.clear()
	_tile_owner_counts.clear()
	_tile_priority_counts.clear()
	_order.clear()
	_cursor = 0
	_completion_debt.clear()
	_completion_order.clear()
	_last_frame = -1
	_ready_cache_hits = 0
	_receipt_rechecks = 0
	_completion_visits = 0
	_last_completion_work = {}
	_main = null
	_adapter = null
	_nav = null
	_publisher = null
	_structures = null
	_seed = ""
	var owners := _owners(main_node)
	if owners.is_empty(): last_rejection = "navigation_owners_unavailable"; return false
	_main = weakref(main_node)
	_adapter = weakref(owners.adapter)
	_nav = weakref(owners.nav)
	_publisher = weakref(owners.publisher)
	_structures = weakref(owners.structures)
	_seed = String(main_node.seed_text)
	if owners.nav.has_signal("accepted_tile_changed"):
		owners.nav.connect("accepted_tile_changed",_on_accepted_tile_changed)
	last_rejection = ""
	return not _seed.is_empty()

func request_region(bounds: Rect2i, priority: int, reason: String) -> int:
	if not _valid_bounds(bounds):
		last_rejection = "invalid_navigation_region_request"
		return 0
	var id := request_tiles(_tile_keys(bounds),priority,reason)
	if id > 0: _requests[id].bounds = bounds
	return id

func request_tiles(tile_keys: Array, priority: int, reason: String) -> int:
	last_rejection = ""
	var keys := _normalized_tiles(tile_keys)
	if not _current() or keys.is_empty() or priority < 0 or priority > 4 or reason.strip_edges().is_empty():
		last_rejection = "invalid_navigation_region_request"
		return 0
	if _requests.size() >= MAX_REQUESTS:
		last_rejection = "navigation_region_capacity"
		return 0
	if not _replacement_fits(0,keys):
		last_rejection = "navigation_tile_capacity"
		return 0
	var id := _next_id
	_next_id += 1
	_commit_request(id,keys,priority,reason)
	return id

func replace_region(id: int, bounds: Rect2i, priority: int, reason: String) -> bool:
	if not _valid_bounds(bounds):
		last_rejection = "invalid_navigation_region_request"
		return false
	if not replace_tiles(id,_tile_keys(bounds),priority,reason): return false
	_requests[id].bounds = bounds
	return true

func replace_tiles(id: int, tile_keys: Array, priority: int, reason: String) -> bool:
	last_rejection = ""
	var keys := _normalized_tiles(tile_keys)
	if not _current() or not _requests.has(id) or keys.is_empty() or priority < 0 or priority > 4 or reason.strip_edges().is_empty():
		last_rejection = "invalid_navigation_region_request"
		return false
	# Admission is transactional. In particular, a full 64-handle provider can
	# replace an existing consumer, and its released tiles do not count twice.
	# No owner callbacks or request/receipt mutation occurs after validation.
	if not _replacement_fits(id,keys):
		last_rejection = "navigation_tile_capacity"
		return false
	_commit_request(id,keys,priority,reason)
	return true

func _replacement_fits(id: int, keys: Array[String]) -> bool:
	var retained := _tiles.duplicate()
	if _requests.has(id):
		for key: String in _requests[id].tiles:
			if int(_tile_owner_counts.get(key,0))<=1: retained.erase(key)
	for key: String in keys: retained[key] = true
	return retained.size() <= MAX_TILES

func _commit_request(id: int, keys: Array[String], priority: int, reason: String) -> void:
	if _requests.has(id): _release_membership(_requests[id],id)
	var membership := {}
	for key: String in keys: membership[key] = true
	keys.make_read_only()
	membership.make_read_only()
	_requests[id] = {"bounds":Rect2i(),"priority":priority,"reason":reason,
		"tiles":keys,"tileSet":membership,"requirements":{}}
	_retain_membership(_requests[id])
	for key: String in keys:
		if not _tiles.has(key):
			_tiles[key] = _new_tile()
			var nav = _nav.get_ref()
			if nav.has_method("accepted_tile_scheduling_hint"):
				var hint: Dictionary = nav.accepted_tile_scheduling_hint(key,_seed,_adapter.get_ref())
				if not hint.is_empty(): _retain_completion_hint(key,hint)
	_prune_tiles()
	_reorder()

func _retained_tiles(excluding_id: int = 0) -> Dictionary:
	var retained := _tiles.duplicate()
	if excluding_id>0 and _requests.has(excluding_id):
		for key: String in _requests[excluding_id].tiles:
			if int(_tile_owner_counts.get(key,0))<=1: retained.erase(key)
	return retained

func _prune_tiles() -> void:
	for key: String in _tiles.keys():
		if int(_tile_owner_counts.get(key,0))<=0:
			_tiles.erase(key)
			_completion_debt.erase(key)
			_completion_order.erase(key)

func _retain_membership(request: Dictionary) -> void:
	var priority: int = int(request.priority)
	for key: String in request.tiles:
		_tile_owner_counts[key] = int(_tile_owner_counts.get(key,0))+1
		var counts: Array = _tile_priority_counts.get(key,[0,0,0,0,0])
		counts[priority] = int(counts[priority])+1
		_tile_priority_counts[key] = counts

func _release_membership(request: Dictionary, owner_id := 0) -> void:
	var priority: int = int(request.priority)
	for key: String in request.tiles:
		if owner_id > 0: _release_publish_owner(key,owner_id)
		var owner_count: int = int(_tile_owner_counts.get(key,0))-1
		if owner_count<=0: _tile_owner_counts.erase(key)
		else: _tile_owner_counts[key] = owner_count
		var counts: Array = _tile_priority_counts.get(key,[0,0,0,0,0])
		counts[priority] = maxi(0,int(counts[priority])-1)
		if counts.all(func(value): return int(value)==0): _tile_priority_counts.erase(key)
		else: _tile_priority_counts[key] = counts

func release_region(id: int) -> void:
	if not _requests.has(id): return
	_release_membership(_requests[id],id)
	_requests.erase(id)
	_prune_tiles()
	_reorder()

func _publish_owner(id: int) -> Dictionary:
	return {"kind":"regional_streaming","id":"%d:%d" % [get_instance_id(),id]}

func _release_publish_owner(tile_key: String, id: int) -> void:
	if _publisher == null: return
	var publisher = _publisher.get_ref()
	if is_instance_valid(publisher) and publisher.has_method("release_navmesh_tile_publish_owner"):
		publisher.release_navmesh_tile_publish_owner(tile_key,_publish_owner(id))

func _release_all_publish_owners() -> void:
	for id_value in _requests:
		var id := int(id_value)
		for key: String in _requests[id].tiles:
			_release_publish_owner(key,id)

func _request_ids_for_tile(tile_key: String) -> Array[int]:
	var result: Array[int] = []
	for id_value in _requests:
		var id := int(id_value)
		if _requests[id].tileSet.has(tile_key): result.append(id)
	result.sort()
	return result

func advance(budget_usec := 4000) -> Dictionary:
	var started := Time.get_ticks_usec()
	var frame := Engine.get_process_frames()
	if not _current(): return {"status":"pending","reason":"navigation_owner_changed"}
	if budget_usec <= 0 or _last_frame == frame: return _stats()
	_last_frame = frame
	var deadline := started+mini(budget_usec,4000)
	var nav = _nav.get_ref()
	var publisher = _publisher.get_ref()
	# Progress the sole owned worker/upload slot first. If it becomes ready, pay
	# the existing completion debt in this frame before any regional source proof.
	# Installation still performs the authoritative live physical validation.
	nav.advance_publication(maxi(1,deadline-Time.get_ticks_usec()))
	if publisher.has_method("_process_ready_navmesh_tile_publication"):
		var completed: int = publisher._process_ready_navmesh_tile_publication(1)
		if completed > 0 or nav.publication_sync_pending():
			publisher._sync_navmesh_after_queued_tile_publish()
	# A final retained tile may await synchronization after its worker/queue slot
	# is gone. Service that explicit obligation before another source-ID slice.
	if nav.publication_sync_pending(): publisher._sync_navmesh_after_queued_tile_publish()
	# Installation transfers an obligation to this consumer too. Discover that
	# debt through borrowed immutable ownership, before expensive pending-source
	# scans. One rotating completion visit per slice bounds work and keeps all
	# retained accepted tiles progressing, even while request membership changes.
	var completion_key := _accepted_completion_key(nav, _adapter.get_ref())
	if not completion_key.is_empty():
		var completion_started := Time.get_ticks_usec()
		_advance_tile(completion_key,Time.get_ticks_usec()+mini(budget_usec,4000))
		_completion_visits += 1
		_last_completion_work = {"tileKey":completion_key,"status":_tiles[completion_key].status,
			"reason":_tiles[completion_key].reason,"cursor":_tiles[completion_key].cursor,
			"acceptedSerial":_tiles[completion_key].acceptedSerial,"elapsedUsec":Time.get_ticks_usec()-completion_started,
			"collectionUsec":_tiles[completion_key].get("collectionUsec",0),
			"proofAndReceiptUsec":_tiles[completion_key].get("proofAndReceiptUsec",0),
			"observedToAcknowledgedMsec":_tiles[completion_key].get("observedToAcknowledgedMsec",-1)}
	# Each tile's source owner validates publication inputs. Declared regional
	# obligations are checked by region_publication_readiness; repeating that
	# graph walk here must not starve the tile queue it is waiting for.
	# Ready receipts are cheap to revisit. Do not spend an entire frame on one
	# while a nearby captured tile waits for its bounded source-ID proof.
	var visited := 0
	var visited_keys: Dictionary={}
	var foreground_key := _priority_zero_pending_key()
	if not foreground_key.is_empty() and foreground_key!=completion_key and Time.get_ticks_usec()<deadline:
		var foreground_started := Time.get_ticks_usec()
		_advance_tile(foreground_key,deadline)
		_tile_visits+=1
		visited+=1
		visited_keys[foreground_key]=true
		_last_tile_work={"tileKey":foreground_key,"status":_tiles[foreground_key].status,
			"reason":_tiles[foreground_key].reason,"cursor":_tiles[foreground_key].cursor,
			"hasSnapshot":int(_tiles[foreground_key].get("acceptedSerial",0))>0,
			"elapsedUsec":Time.get_ticks_usec()-foreground_started}
	var foreground_blocking: bool = not foreground_key.is_empty() and String(_tiles.get(foreground_key,{}).get("status",""))!="ready"
	while not foreground_blocking and not _order.is_empty() and visited < mini(8,_order.size()) and Time.get_ticks_usec() < deadline:
		_cursor %= _order.size()
		var key := _order[_cursor]
		_cursor = (_cursor+1)%_order.size()
		if key == completion_key or visited_keys.has(key):
			visited += 1
			continue
		var tile_started := Time.get_ticks_usec()
		_advance_tile(key,deadline)
		_tile_visits += 1
		_last_tile_work = {"tileKey":key,"status":_tiles[key].status,"reason":_tiles[key].reason,
			"cursor":_tiles[key].cursor,"hasSnapshot":int(_tiles[key].get("acceptedSerial",0)) > 0,
			"elapsedUsec":Time.get_ticks_usec()-tile_started}
		visited += 1
	# Consume captured source facts and receipts before starting more work. A
	# snapshot build may exceed this cooperative slice; it must not repeatedly
	# prevent acknowledgement of tiles whose source has already been captured.
	if Time.get_ticks_usec() < deadline:
		nav.advance_publication(maxi(1,deadline-Time.get_ticks_usec()))
		if Time.get_ticks_usec() < deadline:
			var published: int = publisher._process_queued_navmesh_tile_publishes(1,maxi(1,deadline-Time.get_ticks_usec()),false,false)
			if published > 0 or nav.publication_sync_pending(): publisher._sync_navmesh_after_queued_tile_publish()
	_max_advance_usec = maxi(_max_advance_usec,Time.get_ticks_usec()-started)
	return _stats()


func _priority_zero_pending_key() -> String:
	# _reorder keeps priority classes stable and lexical within a class. Scan only
	# the leading foreground class; background frontier size cannot affect this
	# playable-area decision.
	for key: String in _order:
		if _priority(key)>0: break
		if _tiles.get(key,{}).get("status")!="ready": return key
	return ""

func _accepted_completion_key(nav, adapter) -> String:
	if not nav.has_method("accepted_tile_progress_source"): return ""
	if _completion_order.is_empty(): return ""
	# Exactly one coalesced event per visit. Completed/stale entries retire here;
	# neither idle frames nor selection walk every retained descriptor anymore.
	var key: String = _completion_order.pop_front()
	var hint: Dictionary = _completion_debt.get(key,{})
	if not _tiles.has(key) or hint.is_empty():
		_completion_debt.erase(key)
		return ""
	var tile: Dictionary = _tiles[key]
	if tile.status == "ready" and int(tile.acceptedSerial)==int(hint.serial):
		_completion_debt.erase(key)
		return ""
	var accepted: Dictionary = nav.accepted_tile_progress_source(key,String(hint.sourceKey),_seed,adapter)
	if accepted.is_empty() or int(accepted.serial)!=int(hint.serial):
		_completion_debt.erase(key)
		return ""
	if tile.sourceKey != hint.sourceKey:
		tile = _new_tile()
		tile.sourceKey = hint.sourceKey
		_tiles[key] = tile
	_completion_order.append(key)
	return key

func _retain_completion_hint(key: String, hint: Dictionary) -> void:
	if not _completion_debt.has(key): _completion_order.append(key)
	_completion_debt[key] = hint

func _on_accepted_tile_changed(key: String, source: String, seed: String, owner_id: int, serial: int, present: bool) -> void:
	# The service callback only records values: no reentrant publication/proof.
	if seed!=_seed or not _tiles.has(key) or _adapter==null: return
	var adapter = _adapter.get_ref()
	if not is_instance_valid(adapter) or adapter.get_instance_id()!=owner_id: return
	if present:
		_retain_completion_hint(key,{"sourceKey":source,"serial":serial})
	elif int(_completion_debt.get(key,{}).get("serial",-1))==serial:
		_completion_debt.erase(key)
		_completion_order.erase(key)

func region_publication_readiness(bounds: Rect2i) -> Dictionary:
	if not _valid_bounds(bounds): return _state("failed","invalid_navigation_region_bounds")
	return tiles_publication_readiness(_tile_keys(bounds),bounds)

func tiles_publication_readiness(tile_keys: Array, query_bounds: Rect2i, request_id: int = 0, request_ids: Array = []) -> Dictionary:
	if not _valid_bounds(query_bounds): return _state("failed","invalid_navigation_region_bounds")
	var required_tiles := _normalized_tiles(tile_keys)
	if required_tiles.is_empty() or request_id < 0: return _state("failed","invalid_navigation_tile_request")
	var allowed_requests: Dictionary = {}
	for id in request_ids:
		if not id is int or int(id)<=0: return _state("failed","invalid_navigation_tile_request")
		allowed_requests[int(id)] = true
	if request_id>0: allowed_requests[request_id] = true
	# A sparse closure must include the original query itself, not just its
	# remote crossings. Query geometry remains owned by the structure provider.
	for key: String in _tile_keys(query_bounds):
		if not required_tiles.has(key): return _state("pending","navigation_query_tiles_not_requested")
	if not _current(): return _state("pending","navigation_owner_changed")
	var request: Dictionary = {}
	var collective_tiles: Dictionary = {}
	# A caller must name more than one retained handle before their members can
	# be combined. An unscoped (or single-handle) read remains isolated to one
	# consumer and cannot borrow another consumer's ready tiles.
	var collective_requested: bool = allowed_requests.size() > 1
	for id: int in _requests:
		if not allowed_requests.is_empty() and not allowed_requests.has(id): continue
		var retained: Dictionary = _requests[id]
		if collective_requested:
			for key: String in retained.tileSet: collective_tiles[key] = true
		var complete := true
		for key: String in required_tiles:
			if not retained.tileSet.has(key): complete = false; break
		if complete: request = retained; break
	if request.is_empty() and collective_requested and not collective_tiles.is_empty():
		var collective_complete := true
		for key: String in required_tiles:
			if not collective_tiles.has(key): collective_complete = false; break
		if collective_complete: request = {"collective":true,"tileSet":collective_tiles}
	if request.is_empty(): return _state("pending","navigation_region_not_requested")
	# Check obligations before interpreting emitted IDs or installation receipts.
	# Never query a merged envelope: unrelated structures in a sparse gap do not
	# become dependencies, and source facts are freshly validated on every read.
	var requirements := _read_requirements(query_bounds)
	request.requirements = requirements
	if requirements.get("status") != "described": return requirements
	var result := _state("ready","")
	result.sourceRevisions = {"worldSeed":_seed,"structures":requirements.get("sourceRevisions",{}),"tiles":{}}
	var declared := {}
	for id: String in requirements.requiredCrossings:
		var obligation: Variant = requirements.requiredCrossings[id]
		if id.is_empty() or not obligation is Dictionary or obligation.get("sourceId") != id:
			return _state("failed","invalid_declared_crossing")
		declared[id] = false
	var adapter = _adapter.get_ref()
	var nav = _nav.get_ref()
	for key: String in required_tiles:
		var tile: Dictionary = _tiles[key]
		var source_key: String = adapter.navmesh_tile_source_key_for_tile(key)
		result.sourceRevisions.tiles[key] = source_key
		if tile.get("sourceKey","") != source_key or tile.get("status") != "ready":
			_missing(result,key,String(tile.get("reason","navigation_tile_pending")),tile.get("status") == "failed")
			continue
		if not _receipt_current(key,tile,nav):
			_missing(result,key,"navigation_acknowledgement_changed")
			continue
		# Ordinary/town doors have structure-owned portal obligations rather
		# than building packet sourcePartIds. Resolve the real captured link and
		# live adapter leaf; never invent a building-source mapping for them.
		for id: String in requirements.requiredCrossings:
			var obligation: Dictionary = requirements.requiredCrossings[id]
			if obligation.has("sourcePartId") or obligation.get("ownerTileKey") != key or String(obligation.get("portalId","")).is_empty(): continue
			var accepted_state: Dictionary = nav.accepted_tile_state(key,source_key,_seed,adapter)
			if accepted_state.get("status")!="acknowledged":
				_missing(result,key,"navigation_accepted_source_pending")
				continue
			var accepted: Dictionary = accepted_state.accepted
			var mapped := _ordinary_door_crossing(obligation,key,accepted.source.snapshot,adapter)
			if mapped.status != "described":
				_missing(result,key,mapped.reason,mapped.status == "failed")
				continue
			tile.crossings[id] = mapped.mapping
		for id: String in tile.get("crossings",{}):
			if not declared.has(id): continue
			var obligation: Dictionary = requirements.requiredCrossings[id]
			var mapping: Dictionary = tile.crossings[id]
			var matches: bool = obligation.get("ownerTileKey") == key and obligation.get("binding") == mapping.binding
			if obligation.get("kind") == "doors":
				matches = matches and mapping.get("kind") == "doors"
				if obligation.has("sourcePartId"):
					matches = matches and obligation.sourcePartId == mapping.get("sourcePartId")
				elif not String(obligation.get("portalId","")).is_empty():
					matches = matches and mapping.get("portalId") == obligation.portalId \
						and mapping.get("doorSource") == obligation.get("doorSource")
			for link_id: String in obligation.get("requiredLinkIds",[]):
				matches = matches and mapping.linkIds.has(link_id)
			for dependency_tile: String in obligation.get("tileKeys",[]):
				matches = matches and required_tiles.has(dependency_tile)
			declared[id] = matches
	for id: String in declared:
		if not declared[id]: result.unresolvedCrossingIds.append(id)
	if not result.unresolvedCrossingIds.is_empty():
		# Ready emitted tiles cannot excuse an absent/misbound declared link.
		if result.status == "ready": result.status = "failed"
		result.reason = "declared_crossing_not_acknowledged"
	if result.status == "ready": result.reason = "regional_navigation_publication_acknowledged"
	return result

func _advance_tile(key: String, deadline: int) -> void:
	var started := Time.get_ticks_usec()
	_collection_usec = 0
	_advance_tile_owned(key,deadline)
	var tile: Dictionary = _tiles[key]
	tile.collectionUsec = _collection_usec
	# Separate resumable ID collection from the remaining live source and receipt
	# proof. This is consumer cost, not worker compilation or engine install time.
	tile.proofAndReceiptUsec = Time.get_ticks_usec()-started-_collection_usec
	var hint: Dictionary = _completion_debt.get(key,{})
	if not hint.is_empty() and ((int(hint.serial)==int(tile.acceptedSerial) and tile.status in ["ready","failed"]) \
			or String(hint.sourceKey)!=String(tile.sourceKey)):
		_completion_debt.erase(key)
		_completion_order.erase(key)
	if tile.status == "ready" and int(tile.get("installationObservedMsec",-1)) >= 0 \
			and int(tile.get("observedToAcknowledgedMsec",-1)) < 0:
		tile.observedToAcknowledgedMsec = Time.get_ticks_msec()-int(tile.installationObservedMsec)

func _advance_tile_owned(key: String, deadline: int) -> void:
	var adapter = _adapter.get_ref()
	var nav = _nav.get_ref()
	var publisher = _publisher.get_ref()
	var tile: Dictionary = _tiles[key]
	# Once the service owns an installed immutable source, source-ID collection
	# must progress from that source before another live structure proof. It is
	# not readiness evidence: the full proof still runs below before receipts or
	# crossings are acknowledged.
	if not String(tile.get("sourceKey","")).is_empty() \
			and nav.has_method("accepted_tile_progress_source"):
		var retained: Dictionary = nav.accepted_tile_progress_source(key,String(tile.sourceKey),_seed,adapter)
		if not retained.is_empty():
			if int(tile.get("acceptedSerial",0)) != int(retained.serial):
				var retained_key := String(tile.sourceKey)
				tile = _new_tile()
				tile.sourceKey = retained_key
				tile.acceptedSerial = int(retained.serial)
				tile.installationObservedMsec = Time.get_ticks_msec()
				_tiles[key] = tile
			var retained_snapshot: Dictionary = retained.source.snapshot
			if retained_snapshot.get("unloaded",false):
				tile.status = "pending"
				tile.reason = "navigation_source_unloaded"
				return
			var retained_terrain: Array = retained_snapshot.get("surfaces",[])
			var retained_building: Array = retained_snapshot.get("buildingSurfaces",[])
			var retained_rows := 0
			var retained_collection_started := Time.get_ticks_usec()
			while tile.cursor < retained_terrain.size()+retained_building.size() \
					and retained_rows < MAX_ROWS_PER_ADVANCE and Time.get_ticks_usec() < deadline:
				var retained_index: int = tile.cursor
				if retained_index < retained_terrain.size():
					var retained_surface: Dictionary = retained_terrain[retained_index]
					if not retained_surface.get("blocked",false):
						var retained_cell: Vector3i = retained_surface.cell
						tile.surfaceIds.append("surface:%s:%d,%d,%d:%d" % [key,retained_cell.x,retained_cell.y,retained_cell.z,int(retained_surface.get("spanIndex",retained_index))])
				else:
					tile.surfaceIds.append(String(retained_building[retained_index-retained_terrain.size()].id))
				tile.cursor += 1
				retained_rows += 1
			_collection_usec += Time.get_ticks_usec()-retained_collection_started
			if tile.cursor < retained_terrain.size()+retained_building.size():
				tile.reason = "navigation_source_ids_pending"
				return
	# The retained publisher owns source refresh and final live validation while
	# an exact request is queued. Rewalking Citadel collision receipts here could
	# consume the entire regional slice every frame without advancing its capture.
	# A changed source is written back into the queue by the publisher, and an
	# accepted request is removed, so either transition falls through next visit.
	var retained_queue_source := String(publisher.queued_navmesh_tile_source_keys.get(key,""))
	var retained_capture: Dictionary = adapter.active_navigation_capture_source(key) \
		if adapter.has_method("active_navigation_capture_source") else {}
	if not retained_queue_source.is_empty() and retained_queue_source==String(tile.get("sourceKey","")) \
			and String(retained_capture.get("sourceKey",""))==retained_queue_source:
		if _priority(key)<=1:
			publisher.promote_queued_navmesh_tile_priority(key,retained_queue_source)
			if publisher.has_method("retry_ready_queued_navmesh_tile_priority"):
				publisher.retry_ready_queued_navmesh_tile_priority(key,retained_queue_source)
		if publisher.has_method("set_queued_navmesh_tile_regional_priority"):
			publisher.set_queued_navmesh_tile_regional_priority(key,retained_queue_source,_priority(key))
		tile.status = "pending"
		if tile.reason in ["", "navigation_source_pending", "navigation_accepted_source_absent"]:
			tile.reason = "navigation_publication_retained"
		return
	# Acquire structure facts once. The key helper is deliberately pure over the
	# obtained immutable artifacts; calling the public key query here would repeat
	# the same physical proof before the queue can consume it. Focused synthetic
	# adapters keep the older public-only contract.
	var sources: Dictionary = adapter.building_navigation_sources(key)
	var source_key: String = String(adapter._navmesh_tile_source_key_from_building_sources(key,sources)) \
		if adapter.has_method("_navmesh_tile_source_key_from_building_sources") \
		else String(adapter.navmesh_tile_source_key_for_tile(key))
	if tile.get("sourceKey","") != source_key:
		tile = _new_tile()
		tile.sourceKey = source_key
		_tiles[key] = tile
	if tile.status == "ready" and _receipt_current(key,tile,nav):
		if Time.get_ticks_msec()-int(tile.get("proofCheckedMsec",0)) < RECEIPT_RECHECK_MSEC:
			_ready_cache_hits += 1
			return
		if Time.get_ticks_usec() >= deadline: return
		# Same owner/source and installation serial: the immutable surface ID
		# coverage proof still applies. Periodically recheck actual server/link
		# ownership, without walking source geometry or collecting IDs again.
		if not tile.receipt.get("empty",false):
			var refreshed: Dictionary = nav.tile_publication_readiness(key,source_key,[],tile.linkIds)
			refreshed.erase("signature")
			tile.receipt = refreshed
			tile.status = refreshed.get("status","pending")
			tile.reason = refreshed.get("reason","")
			tile.sourceRevision = refreshed.get("sourceRevision",tile.sourceRevision)
		tile.proofCheckedMsec = Time.get_ticks_msec()
		_receipt_rechecks += 1
		return
	# This source owner independently rejects unresolved authoritative crossings.
	if sources.get("status") != "ready":
		tile.status = sources.get("status","pending")
		tile.reason = sources.get("reason","building_navigation_source_pending")
		return
	# No build/register call here: the existing retained queue remains the only
	# consumer and owns retries, priority, source generation and install success.
	# Enqueue only once per source while it is retained by the shared queue.
	# Re-enqueueing each proof visit needlessly sorts that queue and spends the
	# proof budget before looking at its already-produced immutable capture.
	for owner_id in _request_ids_for_tile(key):
		publisher.queue_navmesh_tile_publish(key,_priority(key)<=1,_publish_owner(owner_id))
	if _priority(key)<=1 and publisher.queued_navmesh_tile_source_keys.has(key):
		publisher.promote_queued_navmesh_tile_priority(key,source_key)
		if publisher.has_method("retry_ready_queued_navmesh_tile_priority"):
			publisher.retry_ready_queued_navmesh_tile_priority(key,source_key)
	if publisher.has_method("set_queued_navmesh_tile_regional_priority"):
		publisher.set_queued_navmesh_tile_regional_priority(key,source_key,_priority(key))
	# A newly queued publisher request cannot already be this call's accepted
	# result. Let its resumable capture run before performing the service's final
	# physical/current-owner proof; the next visit falls through after acceptance.
	if adapter.has_method("_navmesh_tile_source_key_from_building_sources") \
			and String(publisher.queued_navmesh_tile_source_keys.get(key,""))==source_key:
		tile.status = "pending"
		tile.reason = "navigation_publication_retained"
		return
	for index in range(publisher.last_navmesh_tile_queue_debug.size()-1,-1,-1):
		var attempt: Dictionary = publisher.last_navmesh_tile_queue_debug[index]
		if attempt.get("tile") != key or attempt.get("source") != source_key: continue
		if attempt.get("status") in ["failed","rejected"]:
			tile.status = "failed"
			tile.reason = attempt.get("reason","navigation_publication_rejected")
			return
		break
	# Source facts belong to the exact accepted worker installation, including
	# empty tiles. Do not recover them by filtering again after cache eviction.
	var accepted_state: Dictionary = nav.accepted_tile_state(key,source_key,_seed,adapter)
	if not accepted_state.get("sourceOwned",false):
		tile.status = "failed" if accepted_state.get("status")=="invalid" else "pending"
		tile.reason = accepted_state.get("reason","navigation_accepted_source_pending")
		return
	var accepted: Dictionary = accepted_state.accepted
	if tile.get("acceptedSerial",0) != accepted.serial:
		tile = _new_tile()
		tile.sourceKey = source_key
		tile.acceptedSerial = accepted.serial
		tile.installationObservedMsec = Time.get_ticks_msec()
		_tiles[key] = tile
	var snapshot: Dictionary = accepted.source.snapshot
	if snapshot.get("unloaded",false): tile.reason = "navigation_source_unloaded"; return
	# Source ID collection is resumable, including very large structure tiles.
	var rows := 0
	var terrain: Array = snapshot.get("surfaces",[])
	var building: Array = snapshot.get("buildingSurfaces",[])
	var collection_started := Time.get_ticks_usec()
	while tile.cursor < terrain.size()+building.size() and rows < MAX_ROWS_PER_ADVANCE and Time.get_ticks_usec() < deadline:
		var index: int = tile.cursor
		if index < terrain.size():
			var surface: Dictionary = terrain[index]
			if not surface.get("blocked",false):
				var cell: Vector3i = surface.cell
				tile.surfaceIds.append("surface:%s:%d,%d,%d:%d" % [key,cell.x,cell.y,cell.z,int(surface.get("spanIndex",index))])
		else:
			tile.surfaceIds.append(String(building[index-terrain.size()].id))
		tile.cursor += 1
		rows += 1
	_collection_usec += Time.get_ticks_usec()-collection_started
	if tile.cursor < terrain.size()+building.size(): tile.reason = "navigation_source_ids_pending"; return
	var obligations := _tile_crossings(key,sources,snapshot,adapter)
	if obligations.status != "described":
		tile.status = obligations.status
		tile.reason = obligations.reason
		return
	tile.crossings = obligations.crossings
	var links: Array = []
	for link: Dictionary in snapshot.get("crossingLinks",[]): links.append(String(link.id))
	# Ordinary grouped doors legitimately share a route link ID. Prove every
	# source leaf's exact installed crossing without changing those route IDs.
	# Building packet doors use the same exact receipt request; their source-part
	# obligation mapping remains unchanged.
	for link: Dictionary in snapshot.get("doorLinks",[]): links.append(_door_source(link))
	tile.linkIds = links
	# Empty-source acknowledgement belongs to the service, including any old
	# geometry's retirement barrier. Publisher markers are scheduling hints.
	if tile.surfaceIds.is_empty() and links.is_empty() and tile.crossings.is_empty():
		if accepted_state.get("status")!="acknowledged" or not accepted_state.get("empty",false):
			tile.status = "pending"
			tile.reason = accepted_state.get("reason","authoritative_empty_ack_pending")
			return
		tile.receipt = accepted_state.receipt.duplicate()
	else:
		tile.receipt = nav.tile_publication_readiness(key,source_key,tile.surfaceIds,links)
	tile.status = tile.receipt.get("status","pending")
	tile.reason = tile.receipt.get("reason","")
	# sourceKey is the tile-local identity. A recovered source capture can have
	# a newer global snapshot counter after unrelated tiles changed; preserve
	# the actual acknowledged revision rather than pretending it was reinstalled.
	tile.sourceRevision = tile.receipt.get("sourceRevision",snapshot.get("sourceRevision",-1))
	tile.receipt.erase("signature")
	tile.proofCheckedMsec = Time.get_ticks_msec()

func _tile_crossings(key: String, sources: Dictionary, snapshot: Dictionary, adapter) -> Dictionary:
	var emitted := {}
	for link: Dictionary in snapshot.get("crossingLinks",[])+snapshot.get("doorLinks",[]): emitted[String(link.id)] = link
	var result := {"status":"described","reason":"","crossings":{}}
	for source: Dictionary in sources.get("sources",[]):
		var facts: Dictionary = source.get("tile",{})
		for id: String in facts.get("requiredCrossingIds",[]):
			if not emitted.has(id): return {"status":"failed","reason":"declared_tile_crossing_not_emitted:"+id}
			result.crossings[id] = {"linkIds":[id],"binding":source.binding,"kind":"physical"}
		for fact: Dictionary in facts.get("doors",[]):
			var reference: WeakRef = source.get("doorBodies",{}).get(String(fact.sourcePartId))
			var body = reference.get_ref() if reference != null else null
			if not is_instance_valid(body): return {"status":"pending","reason":"declared_door_owner_pending"}
			var portal_id: String = adapter._door_portal_id(body,adapter.world_cell(body.global_position))
			var link_id := "door-link:%s:%s" % [portal_id,key]
			var link: Dictionary = emitted.get(link_id,{})
			if link.is_empty() or link.get("portalId") != portal_id or link.get("start") != fact.exterior or link.get("end") != fact.interior:
				return {"status":"failed","reason":"declared_door_link_identity_mismatch:"+String(fact.id)}
			result.crossings[String(fact.id)] = {"linkIds":[link_id],"binding":source.binding,
				"kind":"doors","sourcePartId":String(fact.sourcePartId)}
	return result

func _ordinary_door_crossing(obligation: Dictionary, key: String, snapshot: Dictionary, adapter) -> Dictionary:
	var portal_id := String(obligation.get("portalId",""))
	var expected_id := "door-link:%s:%s" % [portal_id,key]
	if obligation.get("mappingStatus") != "described":
		return {"status":"pending","reason":"ordinary_door_source_mapping_pending"}
	if obligation.get("requiredLinkIds",[]) != [expected_id]:
		return {"status":"failed","reason":"ordinary_door_declared_link_identity_mismatch"}
	var expected: Dictionary = obligation.get("doorSource",{})
	var cell: Variant = expected.get("cell")
	if expected.get("id") != expected_id or expected.get("portalId") != portal_id \
			or not cell is Vector2i or cell != obligation.get("cell") or adapter.tile_key_for_cell(cell) != key \
			or not expected.get("start") is Vector3 or not expected.get("end") is Vector3 \
			or expected.start != obligation.get("entrance") or expected.end != obligation.get("exit"):
		return {"status":"failed","reason":"ordinary_door_declared_source_mismatch"}
	var link: Dictionary = {}
	for fact: Dictionary in snapshot.get("doorLinks",[]):
		if _door_source(fact) == expected:
			if not link.is_empty(): return {"status":"failed","reason":"ordinary_door_link_ambiguous"}
			link = fact
	if link.is_empty(): return {"status":"failed","reason":"ordinary_door_link_not_emitted"}
	var accepted_state: Dictionary = _nav.get_ref().accepted_tile_state(key,String(snapshot.get("sourceKey","")),_seed,adapter)
	if accepted_state.get("status")!="acknowledged":
		return {"status":"pending","reason":accepted_state.get("reason","ordinary_door_publication_pending")}
	var accepted: Dictionary = accepted_state.accepted
	var reference: WeakRef = accepted.get("doorOwners",{}).get(cell)
	var body = reference.get_ref() if reference != null else null
	if not is_instance_valid(body) or not body.is_inside_tree() or body.is_queued_for_deletion():
		return {"status":"pending","reason":"ordinary_door_live_owner_pending"}
	if adapter.block_world_cell(body) != cell or adapter._door_portal_id(body,cell) != portal_id:
		return {"status":"failed","reason":"ordinary_door_live_portal_mismatch"}
	var portals = _main.get_ref().npc_system.autonomy_system.door_portals
	var live_portal = portals.portal_for_door(body)
	if not is_instance_valid(live_portal) or live_portal.portal_id != portal_id or not live_portal.leaf_nodes.has(body) \
			or portals.door_to_portal.get(body.get_instance_id()) != portal_id:
		return {"status":"pending","reason":"ordinary_door_portal_owner_pending"}
	var portal: Dictionary = {}
	for fact: Dictionary in snapshot.get("doorPortals",[]):
		if fact.get("id") == portal_id and fact.get("cell") == cell \
				and fact.get("entrance") == expected.start and fact.get("exit") == expected.end:
			if not portal.is_empty(): return {"status":"failed","reason":"ordinary_door_emitted_portal_ambiguous"}
			portal = fact
	if portal.is_empty():
		return {"status":"failed","reason":"ordinary_door_emitted_endpoint_mismatch"}
	var step := Vector2i.RIGHT if String(adapter._door_crossing_axis(body)) == "x" else Vector2i.DOWN
	if expected.start != adapter.cell_position(cell-step) or expected.end != adapter.cell_position(cell+step):
		return {"status":"failed","reason":"ordinary_door_declared_endpoint_mismatch"}
	return {"status":"described","reason":"","mapping":{"kind":"doors","portalId":portal_id,
		"linkIds":[expected_id],"doorSource":expected.duplicate(),"binding":obligation.binding}}

static func _door_source(link: Dictionary) -> Dictionary:
	# No coercion or fallback: malformed source facts must fail the receipt proof.
	return {"id":link.get("id"),"portalId":link.get("portalId"),"cell":link.get("cell"),
		"start":link.get("start"),"end":link.get("end")}

func _read_requirements(bounds: Rect2i) -> Dictionary:
	var provider = _structures.get_ref()
	if not provider.has_method("region_dependency_requirements"):
		return _state("pending","structure_dependency_provider_unavailable")
	var value: Dictionary = provider.region_dependency_requirements(bounds)
	if value.get("status") != "described": return value
	if not value.get("requiredCrossings") is Dictionary:
		return _state("failed","missing_declared_crossing_contract")
	for field: String in ["missingSourceIds","unresolvedCrossingIds"]:
		if not value.get(field) is Array: return _state("failed","invalid_structure_dependency_contract")
		if not value[field].is_empty():
			var failed := _state("failed","structure_dependencies_unresolved")
			failed[field] = value[field]
			failed.sourceRevisions = value.get("sourceRevisions",{})
			return failed
	return value

func _receipt_current(key: String, tile: Dictionary, nav) -> bool:
	var state: Dictionary = nav.accepted_tile_state(key,String(tile.sourceKey),_seed,_adapter.get_ref())
	if state.get("status")!="acknowledged" or state.get("acceptedSerial",0)!=tile.get("acceptedSerial",0): return false
	if tile.receipt.get("empty",false):
		return state.get("empty",false)
	if state.get("empty",false): return false
	var current: Dictionary = state.get("receipt",{})
	return current.get("installationSerial",-1) == tile.receipt.get("installationSerial",-2) \
		and current.get("sourceRevision",-1) == tile.get("sourceRevision",-2) \
		and current.get("sourceKey","") == tile.sourceKey

func _current() -> bool:
	if _main == null: return false
	var main_node = _main.get_ref()
	var owners := _owners(main_node)
	return not owners.is_empty() and String(main_node.seed_text) == _seed \
		and is_same(owners.adapter,_adapter.get_ref()) and is_same(owners.nav,_nav.get_ref()) \
		and is_same(owners.publisher,_publisher.get_ref()) and is_same(owners.structures,_structures.get_ref())

static func _owners(main_node) -> Dictionary:
	if not is_instance_valid(main_node): return {}
	if main_node is Node and main_node.is_queued_for_deletion(): return {}
	var npc = main_node.get("npc_system")
	var structures = main_node.get("structure_system")
	if not is_instance_valid(npc) or not is_instance_valid(structures): return {}
	var pathing = npc.get("pathing")
	var autonomy = npc.get("autonomy_system")
	if not is_instance_valid(pathing) or not is_instance_valid(autonomy): return {}
	var adapter = pathing.get("navigation_world")
	var authority = pathing.get("route_planner")
	var nav = autonomy.get("navmesh_world")
	var publisher = authority.get("delegate") if is_instance_valid(authority) else null
	if not is_instance_valid(adapter) or not is_instance_valid(nav) or not is_instance_valid(publisher): return {}
	if not publisher.has_method("queue_navmesh_tile_publish") or not publisher.has_method("_process_queued_navmesh_tile_publishes"): return {}
	return {"adapter":adapter,"nav":nav,"publisher":publisher,"structures":structures}

func _reorder() -> void:
	_order.assign(_tiles.keys())
	_order.sort_custom(func(a: String,b: String) -> bool:
		var pa := _priority(a)
		var pb := _priority(b)
		return pa < pb if pa != pb else a < b)
	_cursor = 0 if _order.is_empty() else _cursor%_order.size()

func _priority(key: String) -> int:
	var counts: Array = _tile_priority_counts.get(key,[])
	for priority in range(counts.size()):
		if int(counts[priority])>0: return priority
	return 4

static func _normalized_tiles(tile_keys: Array) -> Array[String]:
	var result: Array[String] = []
	if tile_keys.is_empty(): return result
	var seen := {}
	for value: Variant in tile_keys:
		if not value is String: return []
		var key: String = value
		if key.length() > 23: return []
		var coordinates := key.split(",",true)
		if coordinates.size() != 2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int(): return []
		var x := int(coordinates[0])
		var z := int(coordinates[1])
		# Canonical signed 32-bit coordinates have a single spelling and cannot
		# alias another tile through parsing, overflow, whitespace or leading zeroes.
		if x < -2147483648 or x > 2147483647 or z < -2147483648 or z > 2147483647 \
				or key != "%d,%d" % [x,z]: return []
		# Reject tiles wholly outside the same cell world accepted by rectangles.
		# Scalar int arithmetic precedes any Vector2i conversion/multiplication;
		# a tile touching a legal edge cell remains admissible.
		if x*TILE_SIZE >= WORLD_CELL_LIMIT or (x+1)*TILE_SIZE <= -WORLD_CELL_LIMIT \
				or z*TILE_SIZE >= WORLD_CELL_LIMIT or (z+1)*TILE_SIZE <= -WORLD_CELL_LIMIT: return []
		if not seen.has(key):
			seen[key] = true
			result.append(key)
	result.sort()
	return result

static func _tile_keys(bounds: Rect2i) -> Array[String]:
	var result: Array[String] = []
	var low := Vector2i(floori(float(bounds.position.x)/TILE_SIZE),floori(float(bounds.position.y)/TILE_SIZE))
	var high := Vector2i(floori(float(bounds.end.x-1)/TILE_SIZE),floori(float(bounds.end.y-1)/TILE_SIZE))
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1): result.append("%d,%d" % [x,z])
	return result

static func _valid_bounds(bounds: Rect2i) -> bool:
	return bounds.size.x > 0 and bounds.size.y > 0 and bounds.size.x <= 512 and bounds.size.y <= 512 \
		and absi(bounds.position.x) < WORLD_CELL_LIMIT and absi(bounds.position.y) < WORLD_CELL_LIMIT \
		and bounds.position.x <= WORLD_CELL_LIMIT-bounds.size.x and bounds.position.y <= WORLD_CELL_LIMIT-bounds.size.y

static func _new_tile() -> Dictionary:
	return {"status":"pending","reason":"navigation_source_pending","sourceKey":"","cursor":0,
		"surfaceIds":[],"linkIds":[],"crossings":{},"receipt":{},"proofCheckedMsec":0,"acceptedSerial":0}

static func _state(status: String, reason: String) -> Dictionary:
	return {"status":status,"reason":reason,"sourceRevisions":{},"missing":[],
		"missingSourceIds":[],"unresolvedCrossingIds":[],"publicationOnly":true}

static func _missing(result: Dictionary, key: String, reason: String, failed := false) -> void:
	result.missing.append({"tileKey":key,"reason":reason})
	if failed: result.status = "failed"
	elif result.status != "failed": result.status = "pending"
	result.reason = "regional_navigation_pending"

func _stats() -> Dictionary:
	return {"status":"pending" if not _requests.is_empty() else "idle","requests":_requests.size(),
		"tiles":_tiles.size(),"maxAdvanceUsec":_max_advance_usec,"worldSeed":_seed,
		"tileVisits":_tile_visits,"lastTileWork":_last_tile_work,
		"completionVisits":_completion_visits,"lastCompletionWork":_last_completion_work,
		"completionDebt":_completion_debt.size(),
		"readyProofCacheHits":_ready_cache_hits,"receiptRechecks":_receipt_rechecks}
