extends SceneTree

## Synthetic retained-demand contract. Only RegionalNavigationPublication is
## production; source requirements and accepted installation receipts are named
## stand-ins. No NavigationServer, route, generated geometry or live acceptance.
const Publication = preload("res://scripts/world/RegionalNavigationPublication.gd")
const QUERY := Rect2i(0,0,1,1)

class OwnerLinks extends RefCounted:
	var seed_text := "synthetic-sparse-publication"
	var npc_system
	var structure_system
	var pathing
	var autonomy_system
	var navigation_world
	var route_planner
	var navmesh_world
	var delegate

class SyntheticStructures extends RefCounted:
	var queries: Array[Rect2i] = []
	var revision := 1
	var required_crossings := {}
	var status := "described"
	func region_dependency_requirements(bounds: Rect2i) -> Dictionary:
		queries.append(bounds)
		return {"status":status,"reason":"synthetic_source_requirements",
			"sourceRevisions":{"fixture":revision},"requiredCrossings":required_crossings,
			"missingSourceIds":[],"unresolvedCrossingIds":[]}

class SyntheticPublicationOwners extends RefCounted:
	signal accepted_tile_changed(tile_key: String, source_key: String, world_seed: String, owner_id: int, serial: int, present: bool)
	var revision := 1
	var accepted := {}
	var _tile_publication_receipts := {}
	var dirty_regions_by_region := {}
	var region_rids_by_region := {}
	var navigation_map_dirty_serial := 1
	var navigation_map_synced_serial := 1
	var empty_navmesh_tile_keys := {}
	var queue_calls := 0
	var queued_navmesh_tile_source_keys := {}
	var last_navmesh_tile_queue_debug: Array = []
	var physically_valid := true
	var expensive_key := ""
	var physical_checks := 0
	var visits: Array[String] = []
	var hint_reads := 0
	var borrow_reads := 0
	func accepted_tile_scheduling_hint(key: String, seed: String, owner) -> Dictionary:
		hint_reads += 1
		var value: Dictionary = accepted.get(key,{})
		if not is_same(owner,self) or value.get("seed")!=seed: return {}
		return {"sourceKey":value.sourceKey,"serial":value.serial}
	func queue_navmesh_tile_publish(key: String, _urgent: bool, _owner := {}) -> void:
		queue_calls += 1
		queued_navmesh_tile_source_keys[key] = navmesh_tile_source_key_for_tile(key)
	func promote_queued_navmesh_tile_priority(_key: String, _source: String) -> void: pass
	func advance_publication(_budget: int) -> Dictionary: return {}
	func _sync_navmesh_after_queued_tile_publish() -> void: pass
	func building_navigation_sources(key: String) -> Dictionary:
		physical_checks += 1
		visits.append(key)
		if key == expensive_key: OS.delay_usec(5000)
		return {"status":"ready","sources":[]}
	func accepted_tile_progress_source(key: String, source: String, seed: String, owner) -> Dictionary:
		borrow_reads += 1
		return accepted_tile_source(key,source,seed,owner)
	func tile_publication_readiness(key: String, _source: String, _surfaces: Array, _links: Array) -> Dictionary:
		return _tile_publication_receipts.get("region:chunk:"+key,{}).duplicate()
	func publication_sync_pending() -> bool: return navigation_map_dirty_serial!=navigation_map_synced_serial
	func _process_queued_navmesh_tile_publishes(_count: int, _budget: int, _force: bool, _sync: bool) -> int: return 0
	func navmesh_tile_source_key_for_tile(key: String) -> String: return "%s:synthetic-v%d" % [key,revision]
	func accepted_tile_source(key: String, source: String, seed: String, owner) -> Dictionary:
		var receipt: Dictionary = accepted.get(key,{})
		if not is_same(owner,self) or receipt.get("sourceKey") != source or receipt.get("seed") != seed: return {}
		return receipt
	func accepted_tile_state(key: String, source: String, seed: String, owner) -> Dictionary:
		# Explicit synthetic service facts; no engine registration is simulated.
		if not physically_valid:
			return {"status":"invalid","sourceOwned":false,"reason":"synthetic_physical_mutation"}
		var owned: Dictionary = accepted_tile_source(key,source,seed,owner)
		if owned.is_empty(): return {"status":"absent","sourceOwned":false,"reason":"synthetic_source_absent"}
		var region := "region:chunk:"+key
		var receipt: Dictionary = _tile_publication_receipts.get(region,{})
		var empty: bool = owned.get("empty",false)
		var membership: bool = not region_rids_by_region.has(region) if empty else region_rids_by_region.has(region)
		var ready: bool = (not receipt.is_empty() and receipt.get("sourceKey")==source
			and not dirty_regions_by_region.has(region) and membership
			and navigation_map_dirty_serial==navigation_map_synced_serial)
		return {"status":"acknowledged" if ready else "retained","sourceOwned":true,"empty":empty,
			"accepted":owned,"acceptedSerial":owned.serial,"receipt":receipt.duplicate(),"reason":"synthetic_publication_state"}

var checks: Dictionary = {}
var metrics: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	checks[label] = passed
	if not passed: print("SPARSE NAVIGATION FAILURE ",label)

func _context() -> Dictionary:
	var main := OwnerLinks.new()
	var npc := OwnerLinks.new()
	var pathing := OwnerLinks.new()
	var authority := OwnerLinks.new()
	var structures := SyntheticStructures.new()
	var owners := SyntheticPublicationOwners.new()
	main.npc_system = npc
	main.structure_system = structures
	npc.pathing = pathing
	npc.autonomy_system = pathing
	pathing.navigation_world = owners
	pathing.navmesh_world = owners
	pathing.route_planner = authority
	authority.delegate = owners
	var publication := Publication.new()
	var configured: bool = publication.configure(main)
	return {"main":main,"structures":structures,"owners":owners,"publication":publication,"configured":configured}

func _keys(first: int, count: int) -> Array[String]:
	var result: Array[String] = []
	for x in range(first,first+count): result.append("%d,0" % x)
	return result

func _synthetic_acknowledge(context: Dictionary, keys: Array) -> bool:
	var publication = context.publication
	var owners = context.owners
	for key: String in keys:
		if not publication._tiles.has(key): return false
		var source: String = owners.navmesh_tile_source_key_for_tile(key)
		var region := "region:chunk:"+key
		var receipt := {"status":"ready","sourceKey":source,"sourceRevision":1,"installationSerial":1}
		owners.accepted[key] = {"serial":1,"sourceKey":source,"seed":context.main.seed_text}
		owners._tile_publication_receipts[region] = receipt.duplicate()
		owners.region_rids_by_region[region] = true # Synthetic presence, never a real RID.
		var tile: Dictionary = publication._tiles[key]
		tile.status = "ready"
		tile.reason = "synthetic_acknowledgement"
		tile.sourceKey = source
		tile.sourceRevision = 1
		tile.acceptedSerial = 1
		tile.receipt = receipt
		owners.accepted_tile_changed.emit(key,source,context.main.seed_text,owners.get_instance_id(),1,true)
	return true

func _retention_and_readiness() -> void:
	var context := _context()
	var publication = context.publication
	var requested: Array = ["10,0","0,0","10,0"]
	var id: int = publication.request_tiles(requested,2,"synthetic islands")
	_check("sparse_source_owners_configured",context.configured)
	_check("sparse_single_handle_and_exact_unique_tiles",id>0 and publication._requests.size()==1
		and publication._order==["0,0","10,0"] and not publication._tiles.has("5,0"))
	if id <= 0: return
	requested.append("5,0")
	_check("caller_cannot_mutate_retained_set",publication._requests[id].tiles==["0,0","10,0"]
		and publication._requests[id].tiles.is_read_only() and publication._requests[id].tileSet.is_read_only())
	_check("pending_receipts_never_become_empty_ready",publication.tiles_publication_readiness(["0,0","10,0"],QUERY,id).status=="pending")
	_check("synthetic_receipt_setup",_synthetic_acknowledge(context,["0,0","10,0"]))
	var state: Dictionary = publication.tiles_publication_readiness(["10,0","0,0"],QUERY,id)
	_check("exact_sparse_set_can_acknowledge",state.status=="ready" and state.sourceRevisions.tiles.size()==2)
	_check("only_original_query_reaches_structure_owner",context.structures.queries.all(func(bounds: Rect2i): return bounds==QUERY))
	_check("gap_is_not_retained_by_sparse_envelope",publication.region_publication_readiness(Rect2i(80,0,1,1)).status=="pending")
	_check("sparse_gap_cannot_join_explicit_readiness",publication.tiles_publication_readiness(["0,0","5,0","10,0"],QUERY,id).status=="pending")
	_check("query_geometry_cannot_be_omitted",publication.tiles_publication_readiness(["10,0"],QUERY,id).get("reason")=="navigation_query_tiles_not_requested")
	var local_id: int = publication.request_tiles(["0,0"],0,"synthetic local consumer")
	_check("readiness_cannot_borrow_another_consumers_tiles",publication.tiles_publication_readiness(["0,0","10,0"],QUERY,local_id).status=="pending")
	var collective_remote_id: int = publication.request_tiles(["10,0"],2,"synthetic remote consumer")
	_check("explicit_collective_handles_can_acknowledge_exact_split_closure",collective_remote_id>0
		and publication.tiles_publication_readiness(["0,0","10,0"],QUERY,0,[local_id,collective_remote_id]).status=="ready")
	publication.release_region(collective_remote_id)
	_check("local_subset_does_not_wait_for_far_pending",publication.replace_tiles(id,["0,0","10,0","20,0"],2,"synthetic expanded islands")
		and publication.tiles_publication_readiness(["0,0"],QUERY,local_id).status=="ready"
		and publication.tiles_publication_readiness(["0,0","20,0"],QUERY,id).status=="pending")
	var binding := {"sourceKey":"synthetic-crossing-source","generation":1}
	context.structures.required_crossings = {"crossing":{"sourceId":"crossing","ownerTileKey":"10,0",
		"kind":"physical","binding":binding,"requiredLinkIds":["link"],"tileKeys":["0,0","10,0"]}}
	publication._tiles["10,0"].crossings = {"crossing":{"binding":binding,"kind":"physical","linkIds":["link"]}}
	_check("declared_crossing_uses_exact_remote_members",publication.tiles_publication_readiness(["0,0","10,0"],QUERY,id).status=="ready")
	_check("declared_crossing_cannot_be_omitted",publication.tiles_publication_readiness(["0,0"],QUERY,id).status=="failed")
	context.structures.required_crossings.crossing.tileKeys.append("5,0")
	_check("declared_crossing_dependency_cannot_hide_in_gap",publication.tiles_publication_readiness(["0,0","10,0"],QUERY,id).status=="failed")
	context.structures.required_crossings.clear()
	context.structures.revision = 2
	var revised: Dictionary = publication.tiles_publication_readiness(["0,0"],QUERY,id)
	_check("source_obligations_are_read_fresh",revised.status=="ready" and revised.sourceRevisions.structures.fixture==2)
	context.structures.status = "pending"
	_check("pending_source_description_never_becomes_ready",publication.tiles_publication_readiness(["0,0"],QUERY,id).status=="pending")
	context.structures.status = "described"
	context.owners._tile_publication_receipts["region:chunk:0,0"].installationSerial = 2
	_check("changed_installation_invalidates_sparse_receipt",publication.tiles_publication_readiness(["0,0"],QUERY,id).status=="pending")
	context.owners._tile_publication_receipts["region:chunk:0,0"].installationSerial = 1
	context.owners.revision = 2
	_check("changed_tile_source_invalidates_sparse_receipt",publication.tiles_publication_readiness(["0,0"],QUERY,id).status=="pending")
	_check("retention_and_readiness_never_drive_route_queue",context.owners.queue_calls==0)
	publication.release_region(id)
	_check("release_preserves_other_consumer_tiles",publication._tiles.keys()==["0,0"] and publication._requests.size()==1)
	var remote_id: int = publication.request_tiles(["10,0"],2,"synthetic separate remote consumer")
	_check("unscoped_readiness_cannot_splice_separate_consumers",remote_id>0
		and publication.tiles_publication_readiness(["0,0","10,0"],QUERY).status=="pending")
	publication.release_region(remote_id)
	publication.release_region(local_id)
	_check("last_release_retires_all_local_receipts",publication._requests.is_empty() and publication._tiles.is_empty() and publication._order.is_empty())

func _empty_acknowledgement() -> void:
	# The service state is synthetic; the actual regional consumer must obey it
	# independently of stale or absent publisher markers.
	var context := _context()
	var publication = context.publication
	var owners = context.owners
	var id: int = publication.request_tiles(["0,0"],0,"synthetic empty consumer")
	var prepared: bool = id>0 and _synthetic_acknowledge(context,["0,0"])
	_check("empty_ack_fixture_admitted",prepared)
	if not prepared: return
	var source: String = owners.navmesh_tile_source_key_for_tile("0,0")
	owners.accepted["0,0"]["empty"] = true
	owners.region_rids_by_region.erase("region:chunk:0,0")
	owners._tile_publication_receipts["region:chunk:0,0"]["empty"] = true
	publication._tiles["0,0"].receipt["empty"] = true
	owners.empty_navmesh_tile_keys["0,0"] = "0,0|"+source
	owners.navigation_map_dirty_serial = 2
	_check("stale_empty_marker_cannot_skip_pending_sync",publication.tiles_publication_readiness(["0,0"],QUERY,id).status=="pending")
	_check("pending_sync_retains_source_ownership",owners.accepted_tile_state("0,0",source,context.main.seed_text,owners).sourceOwned)
	owners.empty_navmesh_tile_keys.clear()
	owners.navigation_map_synced_serial = 2
	_check("service_empty_ack_needs_no_publisher_marker",publication.tiles_publication_readiness(["0,0"],QUERY,id).status=="ready")
	owners.accepted.erase("0,0")
	owners.empty_navmesh_tile_keys["0,0"] = "0,0|"+source
	_check("empty_marker_cannot_replace_missing_source",publication.tiles_publication_readiness(["0,0"],QUERY,id).status=="pending")
	publication.release_region(id)
	_check("empty_consumer_release_balances_retention",publication._requests.is_empty() and publication._tiles.is_empty())

func _transactional_capacity() -> void:
	var context := _context()
	var publication = context.publication
	var ids: Array[int] = []
	for index in range(Publication.MAX_REQUESTS): ids.append(publication.request_tiles(["0,0"],4,"synthetic retained consumer"))
	_check("sixty_four_consumers_share_one_tile",not ids.has(0) and publication._requests.size()==64 and publication._tiles.size()==1)
	if ids.has(0): return
	_check("sixty_fifth_consumer_is_rejected",publication.request_tiles(["0,0"],0,"synthetic overflow")==0
		and publication.last_rejection=="navigation_region_capacity")
	var original: Dictionary = publication._tiles["0,0"]
	original.cursor = 17
	_check("full_handle_table_replaces_in_place",publication.replace_tiles(ids[0],["0,0","10,0"],1,"synthetic updated")
		and publication._requests.size()==64 and publication._tiles.size()==2 and is_same(original,publication._tiles["0,0"])
		and publication._tiles["0,0"].cursor==17 and publication._priority("0,0")==1)
	var before: PackedByteArray = var_to_bytes([publication._requests,publication._tiles,publication._order,publication._cursor,publication._next_id])
	var rejected := true
	for malformed: Array in [[],["00,0"],["-0,0"],["+1,0"],["1,,0"],[" 1,0"],["1,0 "],["2147483648,0"],[Vector2i.ZERO],["0,0",5]]:
		rejected = rejected and not publication.replace_tiles(ids[0],malformed,0,"synthetic invalid")
	rejected = rejected and not publication.replace_tiles(ids[0],["0,0"],-1,"synthetic invalid")
	rejected = rejected and not publication.replace_tiles(ids[0],["0,0"],5,"synthetic invalid")
	rejected = rejected and not publication.replace_tiles(ids[0],["0,0"],0," ")
	_check("invalid_replacements_preserve_every_retained_fact",rejected
		and before==var_to_bytes([publication._requests,publication._tiles,publication._order,publication._cursor,publication._next_id]))
	_check("region_wrapper_replaces_same_handle",publication.replace_region(ids[0],Rect2i(-17,-1,18,2),3,"synthetic legacy rectangle")
		and publication._requests[ids[0]].tiles==["-1,-1","-1,0","-2,-1","-2,0","0,-1","0,0"]
		and publication._requests[ids[0]].bounds==Rect2i(-17,-1,18,2))
	for id: int in ids: publication.release_region(id)
	var large_id: int = publication.request_tiles(_keys(0,512),2,"synthetic complete tile capacity")
	_check("five_hundred_twelve_unique_tiles_admitted",large_id>0 and publication._tiles.size()==512)
	_check("capacity_replacement_counts_removed_tiles_once",publication.replace_tiles(large_id,_keys(1000,512),2,"synthetic relocated capacity")
		and publication._tiles.size()==512 and not publication._tiles.has("0,0"))
	var shared_id: int = publication.request_tiles(["1000,0"],0,"synthetic shared old tile")
	var preserved: PackedByteArray = var_to_bytes([publication._requests,publication._tiles,publication._order,publication._cursor,publication._next_id])
	_check("tile_overflow_replacement_rejected_without_losing_request",not publication.replace_tiles(large_id,_keys(2000,512),1,"synthetic overflow replacement")
		and publication.last_rejection=="navigation_tile_capacity"
		and preserved==var_to_bytes([publication._requests,publication._tiles,publication._order,publication._cursor,publication._next_id]))
	_check("new_tile_overflow_rejected_without_losing_request",publication.request_tiles(["2000,0"],0,"synthetic extra tile")==0
		and publication.last_rejection=="navigation_tile_capacity"
		and preserved==var_to_bytes([publication._requests,publication._tiles,publication._order,publication._cursor,publication._next_id]))
	publication.release_region(shared_id)
	_check("replacement_progresses_after_conflicting_retention_released",publication.replace_tiles(large_id,_keys(2000,512),1,"synthetic retry retained demand")
		and publication._requests.size()==1 and publication._tiles.size()==512)
	context.main.seed_text = "synthetic-reconfigured-seed"
	_check("owner_change_rejects_without_dropping_old_request",not publication.replace_tiles(large_id,["0,0"],0,"synthetic stale owner")
		and publication._requests.has(large_id))
	_check("configure_resets_owned_demand",publication.configure(context.main) and publication._requests.is_empty() and publication._tiles.is_empty())
	var new_id: int = publication.request_region(QUERY,0,"synthetic new generation")
	_check("old_handle_cannot_replace_new_configuration",new_id>large_id and not publication.replace_tiles(large_id,["10,0"],0,"synthetic stale id")
		and publication._requests.size()==1 and publication._requests.has(new_id))
	publication.release_region(large_id)
	_check("old_handle_cannot_release_new_configuration",publication._requests.has(new_id))
	metrics.requestCapacity = Publication.MAX_REQUESTS
	metrics.tileCapacity = Publication.MAX_TILES
	metrics.lastConsumerId = new_id
	publication.release_region(new_id)

func _world_edges() -> void:
	var context := _context()
	var publication = context.publication
	var negative: int = publication.request_region(Rect2i(-999999,-999999,1,1),0,"synthetic negative edge")
	var positive: int = publication.request_region(Rect2i(999999,999999,1,1),0,"synthetic positive edge")
	_check("valid_region_edges_keep_covering_tiles",negative>0 and positive>0
		and publication._requests[negative].tiles==["-62500,-62500"]
		and publication._requests[positive].tiles==["62499,62499"])
	if negative<=0 or positive<=0: return
	_check("sparse_edge_tiles_match_region_domain",publication.replace_tiles(negative,["-62500,62499"],0,"synthetic sparse legal edges"))
	var before: PackedByteArray = var_to_bytes([publication._requests,publication._tiles,publication._order,publication._cursor,publication._next_id])
	var rejected := true
	for key: String in ["-62501,0","62500,0","0,-62501","0,62500","134217728,0","-134217729,0","2147483647,0","-2147483648,0"]:
		var accepted: bool = publication.replace_tiles(negative,[key],0,"synthetic outside world")
		rejected = rejected and not accepted
	_check("outside_world_and_multiplication_overflow_reject_atomically",rejected
		and before==var_to_bytes([publication._requests,publication._tiles,publication._order,publication._cursor,publication._next_id]))
	_check("rectangle_end_cannot_escape_world",not publication.replace_region(positive,Rect2i(999999,0,2,1),0,"synthetic escaped end")
		and publication.request_region(Rect2i(0,999999,1,512),0,"synthetic escaped end")==0
		and before==var_to_bytes([publication._requests,publication._tiles,publication._order,publication._cursor,publication._next_id]))
	publication.release_region(negative)
	publication.release_region(positive)

func _next_engine_frame(previous: int) -> bool:
	for wake in range(2):
		await process_frame
		if Engine.get_process_frames()!=previous: return true
	return false

func _completion_trace(publication) -> void:
	if not metrics.has("completionFrames"): metrics.completionFrames = []
	metrics.completionFrames.append({"frame":Engine.get_process_frames(),"visits":publication._completion_visits,
		"selected":publication._last_completion_work.get("tileKey",""),
		"firstCursor":publication._tiles["50,0"].cursor,"secondCursor":publication._tiles["51,0"].cursor})

func _completion_progress() -> void:
	var context := _context()
	var publication = context.publication
	var owners = context.owners
	var background: int = publication.request_tiles(_keys(0,40),2,"synthetic_expensive_background")
	var foreground: int = publication.request_tiles(["50,0","51,0"],0,"synthetic_accepted_foreground")
	_synthetic_acknowledge(context,["50,0","51,0"])
	for key: String in ["50,0","51,0"]:
		var surfaces: Array = []
		for index in range(4200): surfaces.append({"cell":Vector3i(index,0,0)})
		owners.accepted[key].source = {"snapshot":{"surfaces":surfaces,"buildingSurfaces":[]}}
		var tile: Dictionary = publication._new_tile()
		tile.sourceKey = owners.navmesh_tile_source_key_for_tile(key)
		publication._tiles[key] = tile
	owners.expensive_key = "0,0"
	publication._cursor = 0
	publication.advance(4000)
	_completion_trace(publication)
	_check("accepted_source_collection_precedes_expensive_background_proof",
		publication._tiles["50,0"].cursor>0 and publication._tiles["50,0"].acceptedSerial==1)
	var first_cursor: int = publication._tiles["50,0"].cursor
	_check("oversized_accepted_source_retains_collection_cursor",first_cursor<=4096 and first_cursor<4200)
	# Reordering demand cannot reset the completion rotation or erase progress.
	publication.replace_tiles(background,_keys(0,39),2,"synthetic_background_reordered")
	var changed: bool = await _next_engine_frame(Engine.get_process_frames())
	_check("completion_fixture_second_tick_has_distinct_engine_frame",changed)
	publication.advance(4000)
	_completion_trace(publication)
	_check("accepted_completion_rotation_services_second_retained_tile",publication._tiles["51,0"].cursor>0)
	for frame in range(12):
		changed = await _next_engine_frame(Engine.get_process_frames())
		_check("completion_fixture_engine_frame_%d" % frame,changed)
		publication.advance(4000)
		_completion_trace(publication)
		if publication._tiles["50,0"].status=="ready" and publication._tiles["51,0"].status=="ready": break
	_check("accepted_foreground_eventually_acknowledged_with_competing_expensive_sources",
		publication._tiles["50,0"].status=="ready" and publication._tiles["51,0"].status=="ready")
	_check("completion_keeps_original_demand_handles",publication._requests.has(background) and publication._requests.has(foreground))
	# Borrowing immutable facts is deliberately weaker than physical validation.
	publication._tiles["50,0"].status = "pending"
	owners.physically_valid = false
	publication._advance_tile("50,0",Time.get_ticks_usec()+4000)
	_check("borrowed_completion_cannot_acknowledge_physical_mutation",
		publication._tiles["50,0"].status=="failed" and publication._tiles["50,0"].reason=="synthetic_physical_mutation")
	owners.physically_valid = true
	owners.revision += 1
	publication._advance_tile("51,0",Time.get_ticks_usec()+4000)
	_check("changed_source_discards_borrowed_collection",publication._tiles["51,0"].acceptedSerial==0 and publication._tiles["51,0"].status!="ready")
	publication.release_region(foreground)
	_check("released_completion_demand_cannot_be_selected",publication._accepted_completion_key(owners,owners).is_empty())
	publication.release_region(background)
	var reads_before: int = owners.borrow_reads
	publication._accepted_completion_key(owners,owners)
	_check("idle_completion_selection_does_not_scan_retained_sources",owners.borrow_reads==reads_before)

func _completion_events() -> void:
	var context := _context()
	var publication = context.publication
	var owners = context.owners
	var request: int = publication.request_tiles(_keys(0,512),2,"synthetic_capacity_idle")
	var before: int = owners.borrow_reads
	publication._accepted_completion_key(owners,owners)
	_check("idle_completion_with_512_retained_tiles_performs_zero_borrow_lookups",owners.borrow_reads==before)
	owners.accepted_tile_changed.emit("5,0","first",context.main.seed_text,owners.get_instance_id(),1,true)
	owners.accepted_tile_changed.emit("5,0","second",context.main.seed_text,owners.get_instance_id(),2,true)
	owners.accepted_tile_changed.emit("5,0","first",context.main.seed_text,owners.get_instance_id(),1,false)
	_check("completion_events_coalesce_and_old_retirement_preserves_successor",
		publication._completion_order==["5,0"] and publication._completion_debt["5,0"].serial==2)
	owners.accepted_tile_changed.emit("5,0","second",context.main.seed_text,owners.get_instance_id(),2,false)
	_check("retirement_removes_exact_completion_debt",publication._completion_order.is_empty())
	publication.release_region(request)
	owners.accepted["5,0"] = {"sourceKey":"late","seed":context.main.seed_text,"serial":3}
	request = publication.request_tiles(["5,0"],0,"synthetic_late_subscriber")
	_check("newly_retained_installed_tile_seeds_completion_without_discovery",
		publication._completion_debt["5,0"].serial==3)
	publication.release_region(request)

func _run() -> void:
	_retention_and_readiness()
	_empty_acknowledgement()
	_transactional_capacity()
	_world_edges()
	_completion_events()
	await _completion_progress()
	var report := {"schema":"regional-navigation-sparse-contract/v1","complete":true,"passed":not checks.values().has(false),
		"checks":checks,"metrics":metrics,"evidenceLevel":"synthetic_retention_and_receipt_policy_contract",
		"doesNotProve":"No live geometry, NavigationServer installation, source generation, routes, movement, runtime throughput or gameplay acceptance."}
	var file := FileAccess.open(OS.get_environment("REGIONAL_NAVIGATION_SPARSE_REPORT"),FileAccess.WRITE)
	if file == null:
		push_error("Cannot write sparse navigation contract report")
		quit(2)
		return
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("SPARSE NAVIGATION CONTRACT COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size()}))
	quit(0 if report.passed else 1)
