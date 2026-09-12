extends RefCounted
class_name RegionalNavigationPublication

## Retained regional demand and acknowledgement adapter. No geometry, route,
## descriptor or worker authority: all publication uses the existing route queue.
## Bounds are half-open XZ terrain cells. Caller supplies dependency closure.
const TILE_SIZE := 16
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
var _order: Array[String] = []
var _cursor := 0
var _last_frame := -1
var _max_advance_usec := 0
var _ready_cache_hits := 0
var _receipt_rechecks := 0
var _tile_visits := 0
var _last_tile_work := {}

func configure(main_node) -> bool:
	_requests.clear()
	_tiles.clear()
	_order.clear()
	_cursor = 0
	_last_frame = -1
	_ready_cache_hits = 0
	_receipt_rechecks = 0
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
	last_rejection = ""
	return not _seed.is_empty()

func request_region(bounds: Rect2i, priority: int, reason: String) -> int:
	last_rejection = ""
	if not _current() or not _valid_bounds(bounds) or priority < 0 or priority > 4 or reason.strip_edges().is_empty():
		last_rejection = "invalid_navigation_region_request"
		return 0
	if _requests.size() >= MAX_REQUESTS:
		last_rejection = "navigation_region_capacity"
		return 0
	var keys := _tile_keys(bounds)
	var added := 0
	for key: String in keys:
		if not _tiles.has(key): added += 1
	if _tiles.size()+added > MAX_TILES:
		last_rejection = "navigation_tile_capacity"
		return 0
	var id := _next_id
	_next_id += 1
	_requests[id] = {"bounds":bounds,"priority":priority,"reason":reason,"tiles":keys,"requirements":{}}
	for key: String in keys:
		if not _tiles.has(key): _tiles[key] = _new_tile()
	_reorder()
	return id

func release_region(id: int) -> void:
	if not _requests.has(id): return
	_requests.erase(id)
	var retained := {}
	for request: Dictionary in _requests.values():
		for key: String in request.tiles: retained[key] = true
	for key: String in _tiles.keys():
		if not retained.has(key): _tiles.erase(key)
	_reorder()
	# Do not cancel shared tile/worker demand: actors and outstanding receipts
	# may still depend on it. Existing navigation owners retire their own output.

func advance(budget_usec := 4000) -> Dictionary:
	var started := Time.get_ticks_usec()
	var frame := Engine.get_process_frames()
	if not _current(): return {"status":"pending","reason":"navigation_owner_changed"}
	if budget_usec <= 0 or _last_frame == frame: return _stats()
	_last_frame = frame
	var deadline := started+mini(budget_usec,4000)
	# Each tile's source owner validates publication inputs. Declared regional
	# obligations are checked by region_publication_readiness; repeating that
	# graph walk here must not starve the tile queue it is waiting for.
	# Ready receipts are cheap to revisit. Do not spend an entire frame on one
	# while a nearby captured tile waits for its bounded source-ID proof.
	var visited := 0
	while not _order.is_empty() and visited < mini(8,_order.size()) and Time.get_ticks_usec() < deadline:
		_cursor %= _order.size()
		var key := _order[_cursor]
		_cursor = (_cursor+1)%_order.size()
		var tile_started := Time.get_ticks_usec()
		_advance_tile(key,deadline)
		_tile_visits += 1
		_last_tile_work = {"tileKey":key,"status":_tiles[key].status,"reason":_tiles[key].reason,
			"cursor":_tiles[key].cursor,"hasSnapshot":_tiles[key].has("snapshot"),
			"elapsedUsec":Time.get_ticks_usec()-tile_started}
		visited += 1
	# Consume captured source facts and receipts before starting more work. A
	# snapshot build may exceed this cooperative slice; it must not repeatedly
	# prevent acknowledgement of tiles whose source has already been captured.
	if Time.get_ticks_usec() < deadline:
		var nav = _nav.get_ref()
		var publisher = _publisher.get_ref()
		nav.advance_publication(maxi(1,deadline-Time.get_ticks_usec()))
		if Time.get_ticks_usec() < deadline:
			var published: int = publisher._process_queued_navmesh_tile_publishes(1,maxi(1,deadline-Time.get_ticks_usec()),false,false)
			if published > 0: publisher._sync_navmesh_after_queued_tile_publish()
	_max_advance_usec = maxi(_max_advance_usec,Time.get_ticks_usec()-started)
	return _stats()

func region_publication_readiness(bounds: Rect2i) -> Dictionary:
	if not _valid_bounds(bounds): return _state("failed","invalid_navigation_region_bounds")
	if not _current(): return _state("pending","navigation_owner_changed")
	var request: Dictionary = {}
	for retained: Dictionary in _requests.values():
		if retained.bounds.encloses(bounds): request = retained; break
	if request.is_empty(): return _state("pending","navigation_region_not_requested")
	# Check obligations before interpreting emitted IDs or installation receipts.
	var requirements := _read_requirements(bounds)
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
	var required_tiles := _tile_keys(bounds)
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
			var mapped := _ordinary_door_crossing(obligation,key,tile.snapshot,adapter)
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
	var adapter = _adapter.get_ref()
	var nav = _nav.get_ref()
	var publisher = _publisher.get_ref()
	var tile: Dictionary = _tiles[key]
	var source_key: String = adapter.navmesh_tile_source_key_for_tile(key)
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
	var sources: Dictionary = adapter.building_navigation_sources(key)
	if sources.get("status") != "ready":
		tile.status = sources.get("status","pending")
		tile.reason = sources.get("reason","building_navigation_source_pending")
		return
	# No build/register call here: the existing retained queue remains the only
	# consumer and owns retries, priority, source generation and install success.
	# Enqueue only once per source while it is retained by the shared queue.
	# Re-enqueueing each proof visit needlessly sorts that queue and spends the
	# proof budget before looking at its already-produced immutable capture.
	if not publisher.queued_navmesh_tile_source_keys.has(key):
		publisher.queue_navmesh_tile_publish(key,_priority(key)<=1)
	for index in range(publisher.last_navmesh_tile_queue_debug.size()-1,-1,-1):
		var attempt: Dictionary = publisher.last_navmesh_tile_queue_debug[index]
		if attempt.get("tile") != key or attempt.get("source") != source_key: continue
		if attempt.get("status") in ["failed","rejected"]:
	elif _priority(key)<=1:
		publisher.promote_queued_navmesh_tile_priority(key,source_key)
			tile.status = "failed"
			tile.reason = attempt.get("reason","navigation_publication_rejected")
			return
		break
	# Prefer immutable captured values already produced by that queue. A bounded
	# cache recovery below still uses the same authoritative source producer.
	if not tile.has("snapshot"):
		for cached: Dictionary in adapter.navmesh_tile_snapshot_cache.values():
			if cached.get("tileKey") != key or cached.get("sourceKey") != source_key or cached.get("worldSeed") != _seed: continue
			var capture: Dictionary = cached.get("publicationSource",{})
			if capture.get("status") == "prepared": tile.snapshot = capture.snapshot
			break
		if not tile.has("snapshot"):
			# An already acknowledged tile is skipped by the shared queue even
			# after its small source cache evicts. Recover source values through
			# that same authority, for this one selected tile within advance only.
			# Never infer authoritative emptiness from a missing descriptor/cache.
			var acknowledged := String(publisher.empty_navmesh_tile_keys.get(key,"")) == key+"|"+source_key \
				or String(publisher.published_navmesh_tile_keys.get(key,"")) == key+"|"+source_key
			if acknowledged and Time.get_ticks_usec() < deadline:
				var recovered: Dictionary = adapter.build_navmesh_tile_snapshot(key)
				var capture: Dictionary = recovered.get("publicationSource",{})
				if recovered.get("publicationStatus") == "ready" and recovered.get("sourceKey") == source_key \
						and recovered.get("worldSeed") == _seed and capture.get("status") == "prepared":
					tile.snapshot = capture.snapshot
				elif recovered.get("publicationStatus") == "failed":
					tile.status = "failed"
					tile.reason = recovered.get("reason","navigation_source_failed")
					return
			if not tile.has("snapshot"): tile.reason = "navigation_source_capture_pending"; return
	var snapshot: Dictionary = tile.snapshot
	if snapshot.get("unloaded",false): tile.reason = "navigation_source_unloaded"; return
	# Source ID collection is resumable, including very large structure tiles.
	var rows := 0
	var terrain: Array = snapshot.get("surfaces",[])
	var building: Array = snapshot.get("buildingSurfaces",[])
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
	# The route publisher records authoritative empty only after actual service
	# acceptance. An unloaded tile or absent source is never an empty success.
	if tile.surfaceIds.is_empty() and links.is_empty() and tile.crossings.is_empty():
		if String(publisher.empty_navmesh_tile_keys.get(key,"")) != key+"|"+source_key:
			tile.reason = "authoritative_empty_ack_pending"
			return
		tile.receipt = {"status":"ready","empty":true,"sourceKey":source_key}
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
	var doors: Dictionary = adapter.cached_doors
	for cached: Dictionary in adapter.navmesh_tile_snapshot_cache.values():
		if cached.get("tileKey") == key and cached.get("sourceKey") == snapshot.get("sourceKey") and cached.get("worldSeed") == _seed:
			doors = cached.get("doors",doors)
			break
	var body = adapter.door_at({"doors":doors},cell)
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
	if tile.receipt.get("empty",false):
		return String(_publisher.get_ref().empty_navmesh_tile_keys.get(key,"")) == key+"|"+String(tile.sourceKey)
	var region := "region:chunk:"+key
	var current: Dictionary = nav._tile_publication_receipts.get(region,{})
	return current.get("installationSerial",-1) == tile.receipt.get("installationSerial",-2) \
		and current.get("sourceRevision",-1) == tile.get("sourceRevision",-2) \
		and current.get("sourceKey","") == tile.sourceKey and not nav.dirty_regions_by_region.has(region) \
		and nav.region_rids_by_region.has(region) and nav.navigation_map_dirty_serial == nav.navigation_map_synced_serial

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
	var priority := 4
	for request: Dictionary in _requests.values():
		if request.tiles.has(key): priority = mini(priority,request.priority)
	return priority

static func _tile_keys(bounds: Rect2i) -> Array[String]:
	var result: Array[String] = []
	var low := Vector2i(floori(float(bounds.position.x)/TILE_SIZE),floori(float(bounds.position.y)/TILE_SIZE))
	var high := Vector2i(floori(float(bounds.end.x-1)/TILE_SIZE),floori(float(bounds.end.y-1)/TILE_SIZE))
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1): result.append("%d,%d" % [x,z])
	return result

static func _valid_bounds(bounds: Rect2i) -> bool:
	return bounds.size.x > 0 and bounds.size.y > 0 and bounds.size.x <= 512 and bounds.size.y <= 512 \
		and absi(bounds.position.x) < 1000000 and absi(bounds.position.y) < 1000000

static func _new_tile() -> Dictionary:
	return {"status":"pending","reason":"navigation_source_pending","sourceKey":"","cursor":0,
		"surfaceIds":[],"linkIds":[],"crossings":{},"receipt":{},"proofCheckedMsec":0}

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
		"readyProofCacheHits":_ready_cache_hits,"receiptRechecks":_receipt_rechecks}
