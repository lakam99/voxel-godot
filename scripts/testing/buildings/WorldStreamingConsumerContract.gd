extends SceneTree

## PROPOSAL: install only with the reviewed stable-consumer coordinator change.
## Synthetic contract: real coordinator, named source/terrain/navigation owners.
## Direct closure calls isolate demand state; no engine frame or live proof claim.
const Coordinator = preload("res://scripts/world/WorldStreamingCoordinator.gd")
const ViewPriority = preload("res://scripts/world/GeneratedContentViewPriority.gd")
const A := Rect2i(0,0,1,1)
const B := Rect2i(112,0,1,1)
const C := Rect2i(224,0,1,1)

class SyntheticStructures extends RefCounted:
	var revision := 1
	var scheduling_revision := 1
	var extra_groups: Array[String] = []
	var calls: Array[Rect2i] = []
	var pending: Dictionary = {}
	var domains: Dictionary = {}
	func region_dependency_revision(_bounds: Rect2i) -> Dictionary:
		return {"fixtureRevision":revision}
	func region_dependency_scheduling_revision(_bounds: Rect2i) -> Dictionary:
		return {"fixtureRevision":revision,"schedulingRevision":scheduling_revision}
	func region_dependency_requirements(bounds: Rect2i) -> Dictionary:
		calls.append(bounds)
		return {"status":"pending" if pending.has(bounds) else "described","reason":"synthetic_source",
			"sourceRevisions":{"fixture":revision},"missingSourceIds":[],"unresolvedCrossingIds":[],
			"domainBounds":domains.get(bounds,{}).duplicate(true),"requiredCrossings":{},
			"sites":[] if pending.has(bounds) else [{"binding":{"siteId":"synthetic-site","sourceKey":"source-%d" % revision,"generation":revision},
				"groupIds":["group:%d:%d" % [bounds.position.x,bounds.position.y]]+extra_groups}]}
	func region_publication_readiness(bounds: Rect2i) -> Dictionary:
		return {"status":"pending" if pending.has(bounds) else "ready","reason":"synthetic_source_receipt","sourceRevision":revision}

class SyntheticTerrain extends RefCounted:
	var ready := true
	var during_proof: Callable
	var queries: Array[Rect2i] = []
	func region_publication_readiness(bounds: Rect2i) -> Dictionary:
		queries.append(bounds)
		if during_proof.is_valid(): during_proof.call()
		return {"status":"ready" if ready else "pending","reason":"synthetic_terrain_receipt","sourceRevision":1}

class SyntheticNavigation extends RefCounted:
	var requests: Dictionary = {}
	var next_id := 1
	var request_calls := 0
	var replacement_calls := 0
	var release_calls: Dictionary = {}
	var reject := false
	var pending: Dictionary = {}
	var queries: Array[Dictionary] = []
	func _fits(id: int, keys: Array) -> bool:
		var unique: Dictionary = {}
		for other: int in requests:
			if other==id: continue
			for key: String in requests[other].keys: unique[key] = true
		for key: String in keys: unique[key] = true
		return unique.size()<=512
	func request_tiles(keys: Array, priority: int, reason: String) -> int:
		request_calls += 1
		if reject or requests.size()>=64 or not _fits(0,keys): return 0
		var id: int = next_id; next_id += 1
		requests[id] = {"keys":keys.duplicate(),"priority":priority,"reason":reason}
		return id
	func replace_tiles(id: int, keys: Array, priority: int, reason: String) -> bool:
		replacement_calls += 1
		if reject or not requests.has(id) or not _fits(id,keys): return false
		requests[id] = {"keys":keys.duplicate(),"priority":priority,"reason":reason}
		return true
	func release_region(id: int) -> void:
		release_calls[id] = int(release_calls.get(id,0))+1
		requests.erase(id)
	func advance(_budget: int) -> void: pass
	func tiles_publication_readiness(keys: Array, bounds: Rect2i, id: int = 0, ids: Array = []) -> Dictionary:
		var allowed: Dictionary = {}
		if id>0: allowed[id] = true
		for candidate in ids:
			if candidate is int and int(candidate)>0: allowed[int(candidate)] = true
		queries.append({"keys":keys.duplicate(),"bounds":bounds,"id":id,"ids":allowed.keys()})
		if allowed.is_empty(): return {"status":"pending","reason":"synthetic_consumer_absent"}
		for key: String in keys:
			var owned := false
			for candidate: int in allowed:
				owned = owned or (requests.has(candidate) and requests[candidate].keys.has(key))
			if not owned or pending.has(key): return {"status":"pending","reason":"synthetic_tile_pending"}
		return {"status":"ready","reason":"synthetic_navigation_receipt","sourceRevision":1}

var checks: Dictionary = {}
var metrics: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	checks[label] = passed
	if not passed: print("STREAMING CONSUMER FAILURE ",label)

func _context() -> Dictionary:
	var structures := SyntheticStructures.new()
	var terrain := SyntheticTerrain.new()
	var navigation := SyntheticNavigation.new()
	var coordinator = Coordinator.new()
	coordinator.configure("synthetic-stable-consumer",{"structures":structures,"terrain":terrain,"navigation":navigation})
	return {"coordinator":coordinator,"structures":structures,"terrain":terrain,"navigation":navigation}

func _refresh(context: Dictionary, id: int) -> bool:
	if not context.coordinator._requests.has(id): return false
	context.coordinator._refresh_request(context.coordinator._requests[id])
	return context.coordinator._requests[id].closureStatus=="ready"

func _request(context: Dictionary, bounds: Rect2i, label: String, foreground_navigation_tiles: Array = [],
		foreground_bounds := Rect2i(), member_hysteresis_ms := Coordinator.RELEASE_HYSTERESIS_MS) -> int:
	var id: int = context.coordinator.request_region(bounds,0,"synthetic consumer",foreground_navigation_tiles,
		foreground_bounds,member_hysteresis_ms)
	var ready: bool = id>0 and _refresh(context,id)
	_check(label,ready)
	return id if ready else 0

func _replace(context: Dictionary, id: int, bounds: Rect2i, priority := 0, foreground_navigation_tiles: Array = [],
		foreground_bounds := Rect2i(), member_hysteresis_ms := Coordinator.RELEASE_HYSTERESIS_MS) -> bool:
	return context.coordinator.replace_region(id,bounds,priority,"synthetic consumer",foreground_navigation_tiles,
		foreground_bounds,member_hysteresis_ms)

func _nav_id(context: Dictionary, id: int) -> int:
	return int(context.coordinator._requests.get(id,{}).get("providerRequests",{}).get("navigation",{}).get("id",0))

func _background_nav_id(context: Dictionary, id: int) -> int:
	return int(context.coordinator._requests.get(id,{}).get("providerRequests",{}).get("navigationBackground",{}).get("id",0))

func _snapshot(context: Dictionary) -> PackedByteArray:
	return var_to_bytes([context.coordinator._requests,context.coordinator.retained_gameplay_chunks(),
		context.coordinator.retained_cell_bounds(),context.coordinator.revision(),context.coordinator._next_id,context.navigation.requests])

func _group_deadline(request: Dictionary, name: String) -> int:
	for source: Dictionary in request.get("sourceMembers",{}).values():
		if source.groups.has(name): return int(source.groups[name])
	return -2

func _cleanup(context: Dictionary, label: String) -> void:
	context.coordinator.configure("",{})
	var balanced: bool = context.navigation.requests.is_empty() and context.coordinator._requests.is_empty()
	for count: int in context.navigation.release_calls.values(): balanced = balanced and count==1
	_check(label,balanced and context.coordinator.retained_gameplay_chunks().is_empty()
		and context.coordinator.retained_source_requests().is_empty())

func _forecast_churn() -> void:
	var context := _context()
	var id: int = _request(context,A,"forecast_setup")
	if id<=0: _cleanup(context,"forecast_setup_cleanup"); return
	var navigation_id: int = _nav_id(context,id)
	var replaced := true
	for index: int in range(400):
		var bounds: Rect2i = B if index%2==0 else A
		replaced = _replace(context,id,bounds) and replaced
		replaced = _refresh(context,id) and replaced
	_check("four_hundred_forecast_updates_keep_one_consumer_and_handle",replaced and context.coordinator._requests.size()==1
		and _nav_id(context,id)==navigation_id and context.navigation.requests.size()==1 and context.navigation.request_calls==1)
	var request: Dictionary = context.coordinator._requests[id]
	_check("forecast_history_is_deduplicated_members_not_snapshots",request.members.discovery.size()==32
		and request.members.navigation.size()==2 and request.sourceMembers.size()==1
		and request.sourceMembers.values()[0].groups.size()==2)
	var manifests: Array = context.coordinator.retained_source_requests()
	_check("navigation_priority_manifest_is_exact_retained_membership",manifests.size()==1
		and manifests[0].ownerId==id and manifests[0].priority==request.priority
		and manifests[0].navigationTileKeys==Coordinator._string_keys(Coordinator._held_keys(request,"navigation"))
		and manifests[0].navigationTileKeys==context.navigation.requests[navigation_id].keys)
	manifests[0].navigationTileKeys.clear()
	_check("manifest_navigation_keys_are_private_copies",context.coordinator.retained_source_requests()[0].navigationTileKeys.size()==2)
	var before: PackedByteArray = _snapshot(context)
	var source_calls: int = context.structures.calls.size()
	_check("identical_current_intent_is_noop",_replace(context,id,A) and _snapshot(context)==before
		and context.structures.calls.size()==source_calls)
	metrics["forecastReplacements"] = 400
	metrics["forecastProviderReplacements"] = context.navigation.replacement_calls
	_cleanup(context,"forecast_cleanup_balanced")

func _forecast_without_member_hysteresis() -> void:
	var context := _context()
	var id: int = _request(context,A,"zero_hysteresis_forecast_setup",[],Rect2i(),0)
	if id<=0: _cleanup(context,"zero_hysteresis_forecast_setup_cleanup"); return
	var bounded := true
	for index: int in range(400):
		var bounds: Rect2i = B if index%2==0 else A
		bounded = _replace(context,id,bounds,0,[],Rect2i(),0) and bounded
		bounded = _refresh(context,id) and bounded
		var request: Dictionary = context.coordinator._requests[id]
		bounded = bounded and request.members.navigation.size()==request.sets.navigation.keys.size() \
			and request.members.terrain.size()==request.sets.terrain.keys.size() \
			and request.members.render.size()==request.sets.render.keys.size()
	_check("forecast_without_hysteresis_never_accumulates_departed_tiles",bounded
		and context.coordinator._requests[id].get("memberHysteresisMs")==0)
	_cleanup(context,"zero_hysteresis_forecast_cleanup_balanced")

func _member_expiry_and_revisit() -> void:
	var source_only := _context()
	var source_only_id: int = _request(source_only,A,"source_only_expiry_setup")
	var source_only_request: Dictionary = source_only.coordinator._requests.get(source_only_id,{})
	var source_only_key := "source-1"
	if source_only_request.get("sourceMembers",{}).has(source_only_key):
		source_only_request.sourceMembers[source_only_key].groups["group:0:0"] = Time.get_ticks_msec()
		source_only_request.sourceMembers[source_only_key].expiresAt = -1
		source_only_request.nextExpiryAt = Time.get_ticks_msec()
	var source_only_replacements: int = source_only.navigation.replacement_calls
	source_only.coordinator.advance(Time.get_ticks_msec()+1)
	_check("source_only_expiry_preserves_navigation_handle_without_replacement",
		source_only_id>0 and source_only.navigation.replacement_calls==source_only_replacements
		and _nav_id(source_only,source_only_id)>0)
	_cleanup(source_only,"source_only_expiry_cleanup_balanced")
	var context := _context()
	var id: int = _request(context,A,"expiry_setup")
	var departure_started: int = Time.get_ticks_msec()
	if id<=0 or not _replace(context,id,B) or not _refresh(context,id):
		_check("expiry_transition_setup",false); _cleanup(context,"expiry_setup_cleanup"); return
	var request: Dictionary = context.coordinator._requests[id]
	var deadline: int = int(request.members.discovery.get(Vector2i.ZERO,-1))
	var group_deadline: int = _group_deadline(request,"group:0:0")
	_check("departure_creates_ten_second_member_deadline",deadline>=departure_started+10000
		and deadline<=Time.get_ticks_msec()+10000 and group_deadline>=0)
	var replaced := true
	for index: int in range(200):
		replaced = _replace(context,id,C if index%2==0 else B) and replaced
		replaced = _refresh(context,id) and replaced
	_check("unrelated_updates_do_not_extend_old_tile_or_group",replaced
		and int(request.members.discovery.get(Vector2i.ZERO,-1))==deadline
		and _group_deadline(request,"group:0:0")==group_deadline)
	context.navigation.reject = true
	var before: PackedByteArray = _snapshot(context)
	context.coordinator.advance(maxi(deadline,group_deadline))
	_check("rejected_expiry_preserves_members_and_original_deadlines",_snapshot(context)==before)
	context.navigation.reject = false
	context.coordinator.advance(maxi(deadline,group_deadline))
	_check("expiry_retry_releases_only_due_history",not request.members.discovery.has(Vector2i.ZERO)
		and not request.members.navigation.has(Vector2i.ZERO) and _group_deadline(request,"group:0:0")==-2
		and request.members.discovery.has(Vector2i(4,0)) and _nav_id(context,id)>0)
	_check("navigation_priority_manifest_tracks_successful_expiry",not context.coordinator.retained_source_requests()[0].navigationTileKeys.has("0,0")
		and context.coordinator.retained_source_requests()[0].navigationTileKeys==Coordinator._string_keys(Coordinator._held_keys(request,"navigation")))
	_cleanup(context,"expiry_cleanup_balanced")
	context = _context()
	id = _request(context,A,"revisit_setup")
	if id<=0 or not _replace(context,id,B) or not _refresh(context,id):
		_check("revisit_transition_setup",false); _cleanup(context,"revisit_setup_cleanup"); return
	request = context.coordinator._requests[id]
	deadline = int(request.members.discovery.get(Vector2i.ZERO,-1))
	var revisited: bool = _replace(context,id,A) and _refresh(context,id)
	_check("revisit_reactivates_exact_members",revisited and int(request.members.discovery.get(Vector2i.ZERO,-2))==-1
		and _group_deadline(request,"group:0:0")==-1)
	context.coordinator.advance(deadline+1)
	_check("old_deadline_cannot_expire_revisited_current_demand",request.members.discovery.has(Vector2i.ZERO)
		and request.members.navigation.has(Vector2i.ZERO) and _group_deadline(request,"group:0:0")==-1)
	_cleanup(context,"revisit_cleanup_balanced")

func _pending_history_and_readiness() -> void:
	var context := _context()
	context.structures.pending[A] = true
	var id: int = context.coordinator.request_region(A,0,"synthetic consumer")
	_check("pending_source_retains_base_without_fake_ready",id>0 and not _refresh(context,id)
		and context.coordinator.region_readiness(A,id).status=="pending")
	if id<=0 or not _replace(context,id,B) or not _refresh(context,id):
		_check("pending_history_replacement_setup",false); _cleanup(context,"pending_history_setup_cleanup"); return
	context.navigation.pending["0,0"] = true
	var manifests: Array = context.coordinator.retained_source_requests()
	_check("undiscovered_historical_source_keeps_admission_cells",manifests.size()==1 and manifests[0].bounds==B
		and manifests[0].admissionKeys.has(Vector2i.ZERO) and manifests[0].admissionKeys.has(Vector2i(4,0))
		and manifests[0].navigationTileKeys==["0,0","7,0"])
	_check("historical_pending_work_does_not_block_current_query",context.coordinator.region_readiness(B,id).status=="ready")
	_check("historical_query_cannot_borrow_current_consumer_readiness",context.coordinator.region_readiness(A,id).status=="pending")
	_check("navigation_readiness_receives_current_query_only",not context.navigation.queries.is_empty()
		and context.navigation.queries.back().bounds==B and context.navigation.queries.back().keys==["7,0"])
	context.terrain.ready = false
	_check("current_query_still_requires_terrain_receipt",context.coordinator.region_readiness(B,id).status=="pending")
	context.terrain.ready = true
	context.structures.pending[B] = true
	_check("current_query_still_requires_source_receipt",context.coordinator.region_readiness(B,id).status=="pending")
	context.structures.pending.erase(B)
	context.navigation.pending["7,0"] = true
	_check("current_query_still_requires_navigation_receipt",context.coordinator.region_readiness(B,id).status=="pending")
	_cleanup(context,"pending_history_cleanup_balanced")

func _transaction_and_candidate_identity() -> void:
	var context := _context()
	var id: int = _request(context,A,"transaction_setup")
	if id<=0: _cleanup(context,"transaction_setup_cleanup"); return
	context.navigation.reject = true
	var before: PackedByteArray = _snapshot(context)
	_check("provider_reject_preserves_complete_current_intent",not _replace(context,id,B) and _snapshot(context)==before)
	context.navigation.reject = false
	_check("capacity_reject_preserves_complete_current_intent",not _replace(context,id,Rect2i(0,0,400,400)) and _snapshot(context)==before)
	context.structures.revision = 2
	context.structures.domains[A] = {"navigation":[Rect2i(1600,0,1,1)]}
	context.navigation.reject = true
	_check("changed_source_revision_invalidates_current_readiness_immediately",context.coordinator.region_readiness(A,id).status=="pending")
	_refresh(context,id)
	var request: Dictionary = context.coordinator._requests[id]
	_check("rejected_source_closure_retains_retryable_candidate",request.has("pendingCandidate") and request.closureStatus=="pending")
	if not request.has("pendingCandidate"):
		_cleanup(context,"candidate_setup_cleanup"); return
	var first_identity: Dictionary = request.pendingCandidate.identity.duplicate(true)
	var calls: int = context.structures.calls.size()
	_refresh(context,id)
	_check("same_revision_retry_reuses_compiled_candidate",context.structures.calls.size()==calls
		and request.pendingCandidate.identity==first_identity)
	context.structures.revision = 3
	_refresh(context,id)
	_check("changed_revision_rebuilds_pending_candidate",context.structures.calls.size()==calls+1
		and request.pendingCandidate.identity!=first_identity)
	context.navigation.reject = false
	var replaced: bool = _replace(context,id,B)
	_check("changed_bounds_invalidates_old_candidate_and_admission",replaced and not request.has("pendingCandidate")
		and request.admittedSequence!=request.sequence and context.coordinator.region_readiness(B,id).status=="pending")
	_check("new_current_closure_can_complete_on_same_handle",_refresh(context,id)
		and request.admittedSequence==request.sequence and context.coordinator.region_readiness(B,id).status=="ready"
		and context.navigation.request_calls==1)
	var historical_binding := false
	var current_binding := false
	var unaccepted_binding := false
	for source: Dictionary in request.sourceMembers.values():
		if source.binding.generation==1:
			historical_binding = int(source.groups.get("group:0:0",-1))>=0
		elif source.binding.generation==3:
			current_binding = source.groups=={"group:112:0":-1}
		else: unaccepted_binding = true
	_check("binding_revisions_keep_exact_group_ownership",historical_binding and current_binding and not unaccepted_binding)
	_cleanup(context,"transaction_candidate_cleanup_balanced")

func _consumer_capacity_and_release() -> void:
	var context := _context()
	var ids: Array[int] = []
	var ready := true
	for index: int in range(64):
		var id: int = context.coordinator.request_region(A,0,"synthetic consumer")
		ready = id>0 and ready
		if id>0: ids.append(id); ready = _refresh(context,id) and ready
	_check("sixty_four_real_consumers_hold_sixty_four_handles",ready and ids.size()==64 and context.navigation.requests.size()==64)
	if ids.size()!=64:
		_cleanup(context,"consumer_capacity_setup_cleanup"); return
	var first: int = ids[0]
	var handle: int = _nav_id(context,first)
	_check("replacement_at_handle_capacity_needs_no_sixty_fifth_slot",_replace(context,first,B) and _refresh(context,first)
		and _nav_id(context,first)==handle and context.navigation.requests.size()==64 and context.navigation.request_calls==64)
	var before: PackedByteArray = _snapshot(context)
	_check("sixty_fifth_logical_consumer_rejected_atomically",context.coordinator.request_region(A,0,"synthetic extra")==0 and _snapshot(context)==before)
	context.coordinator.release_region(first)
	var deadline: int = context.coordinator._requests[first].releaseAt
	context.coordinator.release_region(first)
	_check("release_is_idempotent_and_never_extends_hysteresis",context.coordinator._requests[first].releaseAt==deadline
		and context.coordinator.region_readiness(B,first).status=="pending")
	context.coordinator.advance(deadline-1)
	_check("released_consumer_retains_handle_until_deadline",context.navigation.requests.has(handle))
	context.coordinator.advance(deadline)
	_check("released_consumer_releases_one_handle_at_deadline",not context.coordinator._requests.has(first)
		and not context.navigation.requests.has(handle) and context.navigation.release_calls.get(handle,0)==1)
	var old_max: int = ids.back()
	context.coordinator.configure("synthetic-successor",{"structures":context.structures,"terrain":context.terrain,"navigation":context.navigation})
	_check("configuration_balances_all_old_handles",context.navigation.requests.is_empty() and context.coordinator._requests.is_empty())
	var successor: int = _request(context,A,"successor_setup")
	_check("logical_ids_are_monotonic_across_configuration",successor>old_max)
	var successor_handle: int = _nav_id(context,successor)
	context.coordinator.release_region(first)
	_check("old_world_release_cannot_release_successor",context.navigation.requests.has(successor_handle)
		and int(context.coordinator._requests.get(successor,{}).get("releaseAt",0))<0)
	_cleanup(context,"consumer_capacity_release_cleanup_balanced")

func _navigation_union_capacity() -> void:
	var context := _context()
	context.structures.domains[A] = {"navigation":[Rect2i(0,0,512,256)]}
	var id: int = _request(context,A,"navigation_union_setup")
	if id<=0: _cleanup(context,"navigation_union_setup_cleanup"); return
	_check("full_navigation_union_uses_one_handle",context.navigation.requests[_nav_id(context,id)].keys.size()==512)
	var before: PackedByteArray = _snapshot(context)
	_check("historical_navigation_counts_toward_total_capacity",not _replace(context,id,Rect2i(1600,0,1,1)) and _snapshot(context)==before)
	_check("remote_navigation_closure_never_becomes_source_discovery",context.coordinator.retained_source_requests()[0].admissionKeys.size()==16
		and context.structures.calls.all(func(bounds: Rect2i): return bounds==A))
	_cleanup(context,"navigation_union_cleanup_balanced")

func _foreground_navigation_tiles() -> void:
	var context := _context()
	# The retained navigation set is deliberately wider than the immediate
	# foreground capsule. The coordinator must preserve both without promoting
	# the background tile into a structure packet demand.
	context.structures.domains[A] = {"navigation":[Rect2i(160,0,1,1)]}
	var id: int = _request(context,A,"foreground_setup",[Vector2i.ZERO,Vector2i.ZERO])
	if id<=0:
		_cleanup(context,"foreground_setup_cleanup")
		return
	var manifest: Dictionary = context.coordinator.retained_source_requests()[0]
	var sites: Array = manifest.sites
	_check("foreground_tiles_are_canonical_subset_of_retained_navigation",manifest.navigationTileKeys==["0,0","10,0"]
		and sites.size()==1 and sites[0].foregroundNavigationTileKeys==["0,0"])
	var navigation_id: int = _nav_id(context,id)
	var background_navigation_id: int = _background_nav_id(context,id)
	var before: PackedByteArray = _snapshot(context)
	_check("foreground_tile_outside_retained_navigation_rejects_atomically",
		not _replace(context,id,A,0,[Vector2i(11,0)]) and context.coordinator.last_rejection=="foreground_navigation_tile_not_retained"
		and _snapshot(context)==before)
	_check("foreground_only_replacement_preserves_background_navigation_handle",
		background_navigation_id>0 and _replace(context,id,A,0,[Vector2i(10,0)]) and _refresh(context,id)
		and _nav_id(context,id)==navigation_id and _background_nav_id(context,id)==background_navigation_id
		and context.navigation.requests[navigation_id].keys==["10,0"]
		and context.navigation.requests[background_navigation_id].keys==["0,0"])
	manifest = context.coordinator.retained_source_requests()[0]
	_check("foreground_only_replacement_reissues_exact_structure_tile_intent",manifest.navigationTileKeys==["0,0","10,0"]
		and manifest.sites.size()==1 and manifest.sites[0].foregroundNavigationTileKeys==["10,0"])
	_check("foreground_manifest_preserves_per_tile_navigation_priority",manifest.navigationTilePriorities=={"0,0":2,"10,0":0})
	var split_readiness: Dictionary = context.coordinator.region_readiness(A,id)
	var readiness_handles: Array = context.navigation.queries.back().ids
	readiness_handles.sort()
	var expected_handles: Array = [navigation_id,background_navigation_id]
	expected_handles.sort()
	_check("foreground_and_background_handles_collectively_acknowledge_current_region",split_readiness.status=="ready"
		and readiness_handles==expected_handles)
	manifest.sites[0].foregroundNavigationTileKeys.clear()
	_check("foreground_structure_tile_intent_is_a_private_copy",
		context.coordinator.retained_source_requests()[0].sites[0].foregroundNavigationTileKeys==["10,0"])
	_cleanup(context,"foreground_cleanup_balanced")
	context = _context()
	var retained_bounds := Rect2i(0,0,32,1)
	var capsule_bounds := Rect2i(0,0,1,1)
	# The broad player ring has a remote dependency, while the capsule has its
	# own nearer crossing. Foreground work must include the capsule's compiled
	# dependency closure, not just the raw capsule tile.
	context.structures.domains[retained_bounds] = {"navigation":[Rect2i(32,0,1,1),Rect2i(160,0,1,1)]}
	context.structures.domains[capsule_bounds] = {"navigation":[Rect2i(32,0,1,1)]}
	id = _request(context,retained_bounds,"foreground_dependency_closure_setup",[Vector2i.ZERO],capsule_bounds)
	if id>0:
		var primary: int = _nav_id(context,id)
		var background: int = _background_nav_id(context,id)
		var closure_manifest: Dictionary = context.coordinator.retained_source_requests()[0]
		_check("foreground_navigation_uses_exact_compiled_dependency_closure",primary>0 and background>0
			and context.navigation.requests[primary].keys==["0,0","2,0"]
			and context.navigation.requests[background].keys==["1,0","10,0"]
			and closure_manifest.sites[0].foregroundNavigationTileKeys==["0,0","2,0"])
	else: _check("foreground_navigation_uses_exact_compiled_dependency_closure",false)
	_cleanup(context,"foreground_dependency_closure_cleanup_balanced")

func _ready_base_survives_pending_forecast_refresh() -> void:
	var context := _context()
	var broad := Rect2i(0,0,32,32)
	var forecast := Rect2i(0,0,16,16)
	var base_id := _request(context,broad,"ready_base_before_forecast")
	if base_id<=0:
		_cleanup(context,"ready_base_before_forecast_cleanup")
		return
	context.structures.pending[forecast] = true
	var forecast_id: int = context.coordinator.request_region(forecast,0,"pending_forecast")
	var forecast_ready := forecast_id>0 and _refresh(context,forecast_id)
	var readiness: Dictionary = context.coordinator.region_readiness(A)
	_check("pending_forecast_does_not_revoke_completed_enclosing_readiness",
		forecast_id>0 and not forecast_ready and readiness.status=="ready"
		and int(context.coordinator._requests[base_id].admittedSequence)==int(context.coordinator._requests[base_id].sequence)
		and context.coordinator._requests[forecast_id].closureStatus=="pending")
	# Selecting the completed enclosing owner preserves progress only. It must
	# still revalidate the authoritative source at the actual query boundary.
	context.structures.revision += 1
	var stale_readiness: Dictionary = context.coordinator.region_readiness(A)
	_check("completed_enclosing_request_rejects_changed_source_revision",
		stale_readiness.status=="pending" and stale_readiness.reason=="local_source_demand_pending")
	_cleanup(context,"ready_base_before_forecast_cleanup")

func _live_acceptance_under_scheduling_churn() -> void:
	var context := _context()
	var broad := Rect2i(0,0,32,32)
	var id := _request(context,broad,"live_acceptance_setup")
	if id<=0:
		_cleanup(context,"live_acceptance_cleanup"); return
	context.structures.scheduling_revision += 1
	_check("scheduling_change_with_current_local_proofs_remains_ready",
		context.coordinator.region_readiness(A,id).status=="ready")
	context.structures.pending[broad] = true
	_refresh(context,id)
	_check("pending_broad_refresh_preserves_current_local_acceptance",
		context.coordinator._requests[id].closureStatus=="pending"
		and context.coordinator.region_readiness(A,id).status=="ready")
	context.structures.extra_groups.append("new-required-group")
	_check("new_group_in_same_source_requires_active_demand",
		context.coordinator.region_readiness(A,id).reason=="local_source_demand_pending")
	context.structures.extra_groups.clear()
	var retained: Dictionary = context.coordinator._requests[id].sourceMembers.values()[0]
	retained.groups["group:0:0"] = Time.get_ticks_msec()+1000
	_check("historical_group_cannot_authorize_current_query",
		context.coordinator.region_readiness(A,id).reason=="local_source_demand_pending")
	retained.groups["group:0:0"] = -1
	context.structures.domains[A] = {"navigation":[B]}
	_check("new_dependency_tile_requires_retained_provider_demand",
		context.coordinator.region_readiness(A,id).status=="pending")
	context.structures.domains.erase(A)
	context.terrain.ready = false
	_check("same_identity_still_requires_live_terrain_proof",
		context.coordinator.region_readiness(A,id).status=="pending")
	context.terrain.ready = true
	context.navigation.pending["0,0"] = true
	_check("same_identity_still_requires_live_navigation_acknowledgement",
		context.coordinator.region_readiness(A,id).status=="pending")
	context.navigation.pending.clear()
	context.terrain.during_proof = func(): context.structures.revision += 1; context.structures.scheduling_revision += 1
	_check("mutation_during_acceptance_rejects_mixed_revision_proof",
		context.coordinator.region_readiness(A,id).status=="pending")
	context.terrain.during_proof = func(): context.coordinator.release_region(id)
	_check("cancellation_during_acceptance_rejects_proof",
		context.coordinator.region_readiness(A,id).status=="pending")
	context.terrain.during_proof = Callable()
	_cleanup(context,"live_acceptance_cleanup")
	context = _context()
	id = _request(context,A,"replacement_during_acceptance_setup")
	context.terrain.during_proof = func(): _replace(context,id,B)
	_check("replacement_during_acceptance_rejects_previous_query_proof",
		context.coordinator.region_readiness(A,id).status=="pending")
	context.terrain.during_proof = Callable()
	_cleanup(context,"replacement_during_acceptance_cleanup")

func _foreground_admission_preempts_ready_backlog() -> void:
	var context := _context()
	var background_ready := true
	for index: int in range(20):
		var id: int = context.coordinator.request_region(B,1,"background:%d" % index)
		background_ready = id>0 and _refresh(context,id) and background_ready
	var foreground_id: int = context.coordinator.request_region(A,0,"predicted_traversal")
	var initially_pending: bool = foreground_id>0 \
		and context.coordinator._requests[foreground_id].closureStatus=="pending"
	context.coordinator._last_advance_frame = -1
	context.coordinator.advance()
	_check("pending_foreground_admission_preempts_ready_background_audit",
		background_ready and initially_pending
		and context.coordinator._requests[foreground_id].closureStatus=="ready"
		and int(context.coordinator._requests[foreground_id].admittedSequence) \
			== int(context.coordinator._requests[foreground_id].sequence))
	_cleanup(context,"foreground_admission_preemption_cleanup")

func _view_intent_is_stable_scheduling_input() -> void:
	var context := _context()
	var id := _request(context,A,"view_intent_setup")
	if id<=0:
		_cleanup(context,"view_intent_setup_cleanup")
		return
	var navigation_id: int = _nav_id(context,id)
	var provider_replacements: int = int(context.navigation.replacement_calls)
	var revision_before: int = context.coordinator.revision()
	var view_revision_before: int = context.coordinator.view_revision()
	var raw := {"origin":Vector3(1.0,2.0,1.0),"forward":Vector3(0.0,0.0,-1.0),
		"predictedOrigin":Vector3(1.0,2.0,-7.0),"horizontalFovDegrees":78.0,"farDistance":181.0}
	_check("view_intent_rejects_non_dictionary_without_mutation",
		not context.coordinator.set_request_view_intent(id,"invalid")
		and context.coordinator.revision()==revision_before and _nav_id(context,id)==navigation_id)
	_check("view_intent_updates_scheduling_without_provider_handle_churn",
		context.coordinator.set_request_view_intent(id,raw)
		and context.coordinator.revision()==revision_before
		and context.coordinator.view_revision()==view_revision_before+1 and _nav_id(context,id)==navigation_id
		and context.navigation.replacement_calls==provider_replacements)
	var normalized: Dictionary = ViewPriority.normalize(raw)
	var manifest: Dictionary = context.coordinator.retained_source_requests()[0]
	_check("view_intent_manifest_is_normalized_and_private",manifest.get("viewIntent",{})==normalized)
	manifest.viewIntent.origin = Vector3(900,0,900)
	_check("view_intent_manifest_mutation_cannot_change_owner",
		context.coordinator.retained_source_requests()[0].viewIntent==normalized)
	var jittered := raw.duplicate(true)
	jittered.origin += Vector3(0.2,0.2,0.2)
	jittered.predictedOrigin += Vector3(0.2,0.2,0.2)
	var stable_revision: int = context.coordinator.revision()
	var stable_view_revision: int = context.coordinator.view_revision()
	_check("sub_quantum_camera_jitter_is_a_noop",
		context.coordinator.set_request_view_intent(id,jittered)
		and context.coordinator.revision()==stable_revision
		and context.coordinator.view_revision()==stable_view_revision
		and context.navigation.replacement_calls==provider_replacements)
	var turned := raw.duplicate(true)
	turned.forward = Vector3.RIGHT
	_check("meaningful_view_turn_changes_only_scheduling_revision",
		context.coordinator.set_request_view_intent(id,turned)
		and context.coordinator.revision()==stable_revision
		and context.coordinator.view_revision()==stable_view_revision+1 and _nav_id(context,id)==navigation_id
		and context.navigation.replacement_calls==provider_replacements)
	var groups := {
		"gate":{"bounds":AABB(Vector3(-2,0,-22),Vector3(4,4,4)),"doorPartIds":["gate-door"]},
		"interior":{"bounds":AABB(Vector3(-3,0,-43),Vector3(6,4,6)),"doorPartIds":[]},
		"visible":{"bounds":AABB(Vector3(20,0,-32),Vector3(4,4,4)),"doorPartIds":[]},
		"near_offscreen":{"bounds":AABB(Vector3(29,0,-1),Vector3(2,2,2)),"doorPartIds":[]},
		"background":{"bounds":AABB(Vector3(99,0,-1),Vector3(2,2,2)),"doorPartIds":[]}}
	var ranked: Array[Dictionary] = ViewPriority.ranked_groups(groups,{
		"origin":Vector3.ZERO,"forward":Vector3(0,0,-1),"predictedOrigin":Vector3(0,0,-12),
		"horizontalFovDegrees":80.0,"farDistance":180.0})
	var rank_by_id: Dictionary = {}
	for row: Dictionary in ranked: rank_by_id[row.id]=row
	metrics["viewRanks"] = rank_by_id.duplicate(true)
	_check("view_priority_orders_gate_lookthrough_visible_near_and_background",
		rank_by_id.gate.priority==1 and rank_by_id.gate.portal
		and rank_by_id.interior.priority==1 and rank_by_id.interior.throughPortal
		and rank_by_id.visible.priority==2 and rank_by_id.near_offscreen.priority==3
		and rank_by_id.background.priority==4)
	_cleanup(context,"view_intent_cleanup_balanced")

func _run() -> void:
	var probe = Coordinator.new()
	var available: bool = probe.has_method("replace_region")
	_check("reviewed_stable_consumer_api_is_available",available)
	if available:
		_forecast_churn()
		_forecast_without_member_hysteresis()
		_member_expiry_and_revisit()
		_pending_history_and_readiness()
		_transaction_and_candidate_identity()
		_consumer_capacity_and_release()
		_navigation_union_capacity()
		_foreground_navigation_tiles()
		_ready_base_survives_pending_forecast_refresh()
		_live_acceptance_under_scheduling_churn()
		_foreground_admission_preempts_ready_backlog()
		_view_intent_is_stable_scheduling_input()
	var report := {"schema":"world-streaming-consumer-contract/v1","complete":true,
		"passed":not checks.values().has(false),"checks":checks,"metrics":metrics,
		"evidenceLevel":"synthetic_retained_consumer_contract",
		"doesNotProve":"No frame scheduling, source generation, scene collision, NavigationServer, routes, movement, runtime performance or live gameplay acceptance."}
	var file := FileAccess.open(OS.get_environment("WORLD_STREAMING_CONSUMER_REPORT"),FileAccess.WRITE)
	if file==null:
		push_error("Cannot write streaming consumer contract report")
		quit(2)
		return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("STREAMING CONSUMER CONTRACT COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size()}))
	quit(0 if report.passed else 1)
