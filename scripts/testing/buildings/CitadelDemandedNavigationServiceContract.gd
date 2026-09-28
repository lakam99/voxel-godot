extends "res://scripts/testing/buildings/CitadelPublicationServiceContract.gd"

## Real admission/preparation/service worker lifetime with a tiny injected source.
## No scene, NavigationServer receipt, player movement or gameplay acceptance.
const Manifest = preload("res://scripts/buildings/BuildingSiteManifestBuilder.gd")
const Layout = preload("res://scripts/buildings/layout/BuildingLayoutConstants.gd")

class SyntheticUrgencyAdmission extends RefCounted:
	var states: Dictionary = {}
	func stats() -> Dictionary: return {"generation":1,"worldSeed":"synthetic-source-urgency"}
	func request_bounds(_bounds: Rect2i) -> Dictionary: return {"status":"ready"}
	func source_state(region: Vector2i) -> Dictionary: return states.get(region,{"status":"absent"})

class SyntheticUrgencyWorker extends RefCounted:
	# Only admission/completion timing is synthetic. Tests call the real service
	# dispatch, ranking, pending metadata and receipt collector; no engine worker.
	var mode := "queued"
	var token := 0
	var calls: Array[Dictionary] = []
	var cancellations := 0
	var resets := 0
	var closing := false
	func dispatch_scene_source(_source: Dictionary, binding: Dictionary) -> Dictionary:
		return _receipt("preparation",binding,[],[])
	func dispatch_navigation(_source: Dictionary, keys: Array[String], binding: Dictionary, order: Array[String] = []) -> Dictionary:
		return _receipt("navigation",binding,keys,order)
	func _receipt(kind: String, binding: Dictionary, keys: Array, order: Array) -> Dictionary:
		calls.append({"kind":kind,"binding":binding.duplicate(),"keys":keys.duplicate(),"order":order.duplicate()})
		if mode in ["busy","failed"]: return {"status":mode,"reason":"synthetic_admission_control"}
		if mode=="duplicate": return {"status":"queued","token":maxi(1,token),"duplicate":true,"requestedTileOrder":order.duplicate()}
		token += 1
		return {"status":"queued","token":token,"requestedTileOrder":order.duplicate()}
	func cancel(_token: int) -> void: cancellations += 1
	func reset() -> void: resets += 1
	func request_shutdown() -> void: closing = true

class SyntheticUrgencyScene extends RefCounted:
	func navigation_tile_artifact(key: String, binding: Dictionary, receipt: Dictionary) -> Dictionary:
		return {"status":"ready","tileKey":key,"binding":binding,"tile":receipt.tile}
	func cancel() -> void: pass

func _urgency_context() -> Dictionary:
	var service = Service.new()
	var worker := SyntheticUrgencyWorker.new()
	var admission := SyntheticUrgencyAdmission.new()
	service._worker = worker
	service.configure(admission)
	return {"service":service,"worker":worker,"admission":admission,"ready":{},"envelopes":{}}

func _urgency_source(context: Dictionary, region: Vector2i, navigation_keys: Array[String] = []) -> void:
	var binding := {"siteId":"synthetic-urgency:%d,%d" % [region.x,region.y],"sourceKey":"synthetic-source","generation":1}
	var source := {"status":"ready","binding":binding,"reservationCells":Rect2i(region*Field.REGION_CELLS,Vector2i(512,512)),"source":{}}
	context.ready[region] = source
	context.admission.states[region] = source
	if navigation_keys.is_empty(): return
	var domain := {"status":"complete","scope":"source_navigation_output","tileKeys":navigation_keys.duplicate(),"producerTileKeys":[]}
	WorkerControls.freeze(domain)
	var envelope := {"binding":binding.duplicate(),"domain":domain}
	WorkerControls.freeze(envelope)
	context.envelopes[region] = envelope # Synthetic value envelope, no producer.
	var entry := {"binding":envelope.binding,"domain":domain,"navigationSource":envelope,
		"requested":{},"receipts":{},"activeTileKey":"","producerProgress":{}}
	context.service._navigation[region] = entry
	context.service._prepared[region] = {"binding":binding} # Synthetic resident marker only.
	for key: String in navigation_keys: context.service._request_navigation_tile(entry,key)

func _urgency_manifest(owner_id: int, priority: int, query: Rect2i, keys: Array[String]) -> Dictionary:
	return {"ownerId":owner_id,"bounds":query,"priority":priority,
		"admissionKeys":Service.DemandSet.from_regions([query],28,256,32).keys.keys(),"navigationTileKeys":keys,"sites":[]}

func _urgency_complete(context: Dictionary, complete_tiles := false, active := "") -> void:
	var service = context.service
	var work: Dictionary = service._inflight
	if work.is_empty(): return
	var region: Vector2i = work.region
	if work.kind=="preparation":
		service._prepared[region] = {"binding":work.binding} # Synthetic completion marker.
		service._inflight = {}
		return
	var receipts := {}
	if complete_tiles:
		for key: String in work.tileKeys:
			var tile := {}
			tile.make_read_only()
			var receipt := {"status":"ready","tileKey":key,"tile":tile,"outputPresent":false}
			receipt.make_read_only()
			receipts[key] = receipt
	receipts.make_read_only()
	var result := {"ready":true,"kind":"navigation_batch","navigationSource":context.envelopes[region],
		"requestedTileKeys":work.tileKeys,"requestedTileOrder":work.tileOrder,"tileReceipts":receipts,"batchComplete":complete_tiles,
		"producerStatus":{"activeTileKey":active,"phase":"idle" if active.is_empty() else "sample",
			"sampleCount":0,"surfaceCount":0,"preparationUsec":0}}
	service._collect_navigation(region,work.binding,result,work.tileKeys,work.tileOrder)
	service._inflight = {}

func _urgency_cleanup(context: Dictionary, label: String) -> void:
	context.service._prune_unwanted({})
	# These fixtures own no scenes, producer, resource or thread. Remove only
	# their named synthetic scene bookkeeping before ordinary service shutdown.
	context.service._scenes.clear()
	context.service._retiring_scenes.clear()
	context.service.request_shutdown()
	check(label,context.service._navigation.is_empty() and context.service._preparation_schedule.is_empty()
		and context.service._retained_navigation_priorities.is_empty() and context.worker.closing)

func _urgency_order_and_admission() -> void:
	var context := _urgency_context()
	var service = context.service
	var region := Vector2i.ZERO
	var keys: Array[String] = []
	for x: int in range(10): keys.append("%d,0" % x)
	_urgency_source(context,region,keys)
	check("urgency_high_priority_manifest_admitted",service.set_retained_source_requests([
		_urgency_manifest(1,0,Rect2i(144,0,1,1),["9,0"])]))
	var entry: Dictionary = service._navigation[region]
	entry.activeTileKey = "8,0"
	var before: PackedByteArray = var_to_bytes([entry.requested,entry.schedule])
	for mode: String in ["busy","failed","duplicate"]:
		context.worker.mode = mode
		for attempt: int in range(5):
			service._request_navigation_tile(entry,"9,0")
			service._dispatch(context.ready,Vector2i.ZERO)
		check("urgency_"+mode+"_preserves_age_intent_and_ownership",service._dispatch_turn==0 and service._inflight.is_empty()
			and entry.has("navigationSource") and var_to_bytes([entry.requested,entry.schedule])==before)
	context.worker.mode = "queued"
	service._dispatch(context.ready,Vector2i.ZERO)
	var admitted: bool = service._inflight.get("kind")=="navigation"
	check("urgency_actual_dispatch_admitted",admitted)
	if not admitted: _urgency_cleanup(context,"urgency_failed_setup_cleanup"); return
	var selected: Array = service._inflight.tileOrder
	var canonical: Array = service._inflight.tileKeys
	var sorted: Array = selected.duplicate()
	sorted.sort()
	check("urgency_active_output_then_late_urgent_output_selected",selected.size()==8 and selected[0]=="8,0" and selected[1]=="9,0"
		and not selected.has("6,0") and not selected.has("7,0") and canonical==sorted)
	check("urgency_successful_dispatch_alone_advances_age",service._dispatch_turn==1
		and entry.requested["9,0"].lastDispatchTurn==1 and entry.requested["6,0"].lastDispatchTurn==0
		and not entry.has("navigationSource"))
	_urgency_complete(context,false,"8,0")
	check("urgency_returned_active_and_pending_intents_survive",entry.activeTileKey=="8,0" and entry.requested.size()==10
		and entry.producerProgress.sampleCount==0 and entry.producerProgress.preparationUsec==0)
	service._dispatch(context.ready,Vector2i.ZERO)
	var continued_order: Array = service._inflight.get("tileOrder",[])
	check("urgency_active_continuation_stays_in_next_receipt_coverage",not continued_order.is_empty() and continued_order[0]=="8,0")
	var cancel_before: int = context.worker.cancellations
	service._prune_unwanted({})
	service._prune_unwanted({})
	check("urgency_departure_cancels_once_and_revokes_pending",context.worker.cancellations==cancel_before+1
		and service._navigation.is_empty() and service._inflight.is_empty())
	_urgency_cleanup(context,"urgency_order_cleanup")

func _urgency_fair_dispatch() -> void:
	var context := _urgency_context()
	var service = context.service
	_urgency_source(context,Vector2i.ZERO,["0,0"])
	_urgency_source(context,Vector2i(1,0),["128,0"])
	_urgency_source(context,Vector2i(2,0))
	check("fairness_hot_source_manifest_admitted",service.set_retained_source_requests([
		_urgency_manifest(1,0,Rect2i(0,0,1,1),["0,0"])]))
	var other_turn := 0
	var preparation_turn := 0
	var bound: int = 4*Service.PRIORITY_AGING_DISPATCH_TURNS+3
	for index: int in range(bound):
		service._dispatch(context.ready,Vector2i.ZERO)
		var work: Dictionary = service._inflight
		if work.is_empty(): break
		if work.region==Vector2i(1,0) and other_turn==0: other_turn = service._dispatch_turn
		if work.kind=="preparation" and preparation_turn==0: preparation_turn = service._dispatch_turn
		# The highest-priority source stays continuously pending. These are
		# explicitly synthetic returned turns with zero producer progress.
		_urgency_complete(context)
	check("fairness_other_navigation_region_eventually_dispatches",other_turn>0 and other_turn<=bound)
	check("fairness_preparation_eventually_dispatches_amid_hot_navigation",preparation_turn>0 and preparation_turn<=bound)
	check("fairness_telemetry_distinguishes_dispatch_from_progress",service._dispatch_metrics.agedDispatches>=2
		and service._navigation[Vector2i.ZERO].producerProgress.sampleCount==0)
	metrics.syntheticFairDispatch = {"otherNavigationTurn":other_turn,"preparationTurn":preparation_turn,
		"boundEligibleDispatches":bound,"policyQuantum":Service.PRIORITY_AGING_DISPATCH_TURNS,"scope":"synthetic eligible dispatch fairness; no walltime guarantee"}
	_urgency_cleanup(context,"fairness_cleanup")

func _urgency_pending_capacity() -> void:
	var context := _urgency_context()
	var service = context.service
	_urgency_source(context,Vector2i.ZERO,["0,0"])
	var entry: Dictionary = service._navigation[Vector2i.ZERO]
	var full := true
	for x: int in range(512): full = service._request_navigation_tile(entry,"%d,0" % x) and full
	var before: PackedByteArray = var_to_bytes([entry.requested,entry.schedule])
	check("pending_navigation_capacity_is_exact_and_retryable",full and entry.requested.size()==512
		and not service._request_navigation_tile(entry,"512,0") and var_to_bytes([entry.requested,entry.schedule])==before)
	_urgency_cleanup(context,"pending_capacity_cleanup")
	context = _urgency_context()
	service = context.service
	var domain_keys: Array[String] = []
	for index: int in range(513): domain_keys.append("%d,%d" % [index%32,floori(float(index)/32.0)])
	domain_keys.sort()
	_urgency_source(context,Vector2i.ZERO,["0,0"])
	entry = service._navigation[Vector2i.ZERO]
	var domain := {"status":"complete","scope":"source_navigation_output","tileKeys":domain_keys,"producerTileKeys":[]}
	WorkerControls.freeze(domain)
	var envelope := {"binding":entry.binding,"domain":domain}
	WorkerControls.freeze(envelope)
	entry.domain = domain
	entry.navigationSource = envelope
	context.envelopes[Vector2i.ZERO] = envelope
	service._scenes[Vector2i.ZERO] = {"region":Vector2i.ZERO,"binding":entry.binding,"phase":"scene_ready","job":SyntheticUrgencyScene.new()}
	var sequential := Service._valid_navigation_domain(domain)
	var max_pending := 0
	for key: String in domain_keys:
		var coordinates: PackedStringArray = key.split(",")
		var tile := Vector2i(int(coordinates[0]),int(coordinates[1]))
		var requested: Dictionary = service.navigation_tile_sources(tile)
		max_pending = maxi(max_pending,entry.requested.size())
		if requested.get("reason")!="structure_navigation_tile_uncompiled": sequential = false; break
		service._dispatch(context.ready,Vector2i.ZERO)
		if service._inflight.is_empty(): sequential = false; break
		_urgency_complete(context,true)
		var complete: Dictionary = service.navigation_tile_sources(tile)
		if complete.get("status")!="ready" or not entry.requested.is_empty(): sequential = false; break
	check("completed_receipts_do_not_consume_pending_capacity",sequential and max_pending==1
		and entry.receipts.size()==513 and entry.requested.is_empty() and not entry.has("schedule"))
	check("complete_domain_inventory_limit_is_unchanged",Service.MAX_NAVIGATION_DOMAIN_KEYS==16900
		and entry.domain.tileKeys.size()==513 and Service._valid_navigation_domain(entry.domain))
	metrics.syntheticSequentialReceipts = {"receipts":entry.receipts.size(),"maxPending":max_pending,"scope":"synthetic receipt collection, no geometry or NavigationServer acceptance"}
	_urgency_cleanup(context,"sequential_receipt_cleanup")

func _producer_weak(service) -> WeakRef:
	# The caller holds a WeakRef only; no producer observation temporary may
	# survive in its coroutine while the service transfers or retires the cursor.
	var producer = service._navigation[REGION].navigationSource.producer
	return weakref(producer)

func _producer_completed_count(service) -> int:
	var producer = service._navigation[REGION].navigationSource.producer
	return int(producer.status().completedTileCount)

func _same_producer(service, observed: WeakRef) -> bool:
	var producer = observed.get_ref()
	return producer!=null and service._navigation[REGION].navigationSource.producer==producer

func _producer_alive(observed: WeakRef) -> bool:
	var producer = observed.get_ref()
	return producer!=null

func _domain_schema_contract() -> void:
	var valid := {"status":"complete","scope":"source_navigation_output","tileKeys":["0,0"],"producerTileKeys":["0,0"]}
	WorkerControls.freeze(valid)
	check("domain_schema_accepts_frozen_complete_inventory",Service._valid_navigation_domain(valid))
	check("domain_schema_rejects_mutable_header",not Service._valid_navigation_domain(valid.duplicate(false)))
	for change: String in ["mutable_keys","duplicate","noncanonical","producer_outside","oversized"]:
		var candidate: Dictionary = valid.duplicate(true)
		match change:
			"duplicate": candidate.tileKeys.append("0,0")
			"noncanonical": candidate.tileKeys[0]="00,0"
			"producer_outside": candidate.producerTileKeys[0]="1,0"
			"oversized": candidate.tileKeys.resize(Service.MAX_NAVIGATION_DOMAIN_KEYS+1)
		if change=="mutable_keys": candidate.make_read_only()
		else: WorkerControls.freeze(candidate)
		check("domain_schema_rejects_"+change,not Service._valid_navigation_domain(candidate))
	var larger: Dictionary = valid.duplicate(true)
	larger.tileKeys.clear()
	for index in range(513): larger.tileKeys.append("%d,%d" % [index%32,floori(float(index)/32.0)])
	WorkerControls.freeze(larger)
	check("domain_inventory_not_truncated_to_active_request_limit",Service._valid_navigation_domain(larger))

func _domain_reset_lifecycle() -> void:
	var value: Owner = owner()
	var service = value.structure_system.citadel_publication
	var admission = value.structure_system.citadel_terrain_admission
	var source: Dictionary = tiny(REGION)
	inject(admission,REGION,source)
	source = {}
	await wait_prepared(value.structure_system,1,REGION,"domain_reset_preparation")
	if service._navigation.has(REGION):
		var binding: Dictionary = service._navigation[REGION].binding
		check("domain_reset_inventory_initially_described",service.navigation_source_domain(REGION,binding).get("status")=="described")
		service.begin_world_reset()
		var retired: Dictionary = service.navigation_source_domain(REGION,binding)
		check("domain_reset_revokes_inventory_before_retirement",service._navigation.is_empty()
			and retired.get("status")=="pending" and retired.get("reason")=="structure_world_reset_pending" and not retired.has("domain"))
		service.request_shutdown()
		check("domain_closing_does_not_return_inventory",not service.navigation_source_domain(REGION,binding).has("domain"))
	else: check("domain_reset_inventory_initially_described",false)
	await close(value,"domain_reset")

func _nonempty_source(region: Vector2i) -> Dictionary:
	var candidate: Dictionary = Field.candidate_for_region(SEED,region)
	check("fixture_candidate_available",not candidate.is_empty())
	if candidate.is_empty(): return {}
	var blueprint = WorkerControls.Blueprint.new("synthetic-demanded-foundation",1,"stone")
	blueprint.add_part({"id":"demand-floor","kind":"foundation","material":"stone_foundation",
		"position":Vector3(0,0.25,0),"size":Vector3(30,0.5,6),"collision":true,
		"physicalIntent":"structural_root","recipe":{"navigationRole":"walkable_support"}})
	var plan = WorkerControls.Plan.new("synthetic-demanded-furniture",1,blueprint.id)
	var manifest: Dictionary = Manifest.build(blueprint,plan,Layout.CELL_SIZE)
	metrics.sourceManifest = {"ready":manifest.get("ready",false),"reason":manifest.get("reason","")}
	var manifest_ready: bool = manifest.get("ready",false) and manifest.get("supportRootIds",[])==["demand-floor"]
	check("fixture_real_grounded_manifest",manifest_ready)
	if not manifest_ready: return {}
	var made: Dictionary = WorkerControls.Profile.create(manifest,SEED,candidate.siteId,candidate.centerCell,0.0,1,Layout.CELL_SIZE)
	metrics.sourceProfile = {"ready":made.get("ready",false),"reason":made.get("reason","")}
	check("fixture_real_profile_created",made.get("ready",false))
	if not made.get("ready",false): return {}
	var profile: Dictionary = made.profile
	var profile_valid: bool = WorkerControls.Profile.valid(profile,SEED,Layout.CELL_SIZE) \
		and profile.siteId==candidate.siteId and profile.sourceSignature==manifest.sourceSignature \
		and Admission.declared_influence(candidate).encloses(profile.reservationCells) \
		and Field.reservation_fits_region(region,profile.reservationCells)
	check("fixture_profile_matches_signed_source_and_region",profile_valid)
	if not profile_valid: return {}
	metrics.sourceProfile.merge({"sourceSignature":profile.sourceSignature,"origin":profile.origin,
		"reservationCells":profile.reservationCells,"groundRootCount":manifest.groundRoots.size(),
		"profileSamples":profile.supportMask.size()})
	var furniture: Dictionary = plan.snapshot()
	furniture["accessReservations"] = plan.access_reservations_snapshot()
	var source: Dictionary = {"status":"prepared","candidate":candidate,"manifest":manifest,
		"blueprint":blueprint.snapshot(),"furnishingPlan":furniture,"profile":profile,
		"reservationCells":profile.reservationCells}
	WorkerControls.freeze(source)
	return source

func _request_observation_controls() -> void:
	# Synthetic owner metadata only; real dispatch ordering, no engine worker.
	var context := _urgency_context()
	_urgency_source(context,Vector2i.ZERO,["0,0","1,0","2,0"])
	var service = context.service
	var entry: Dictionary = service._navigation[Vector2i.ZERO]
	var binding: Dictionary = entry.binding.duplicate()
	entry.activeTileKey = "2,0"
	service.set_retained_source_requests([_urgency_manifest(1,0,Rect2i(16,0,1,1),["1,0"])])
	var before: PackedByteArray = var_to_bytes([entry,service._dispatch_turn,context.worker.calls])
	var observed: Dictionary = service.navigation_request_observation(Vector2i.ZERO,"0,0",binding)
	check("observation_reports_active_first_and_priority_rank",observed.status=="pending" and observed.selectionRank==3
		and observed.outputsAhead==2 and observed.basePriority==4 and not observed.selected)
	check("observation_active_output_is_first",service.navigation_request_observation(Vector2i.ZERO,"2,0",binding).selectionRank==1)
	check("observation_unknown_key_does_not_admit",service.navigation_request_observation(Vector2i.ZERO,"3,0",binding).status=="unrequested")
	check("observation_absent_region_does_not_discover",service.navigation_request_observation(Vector2i(8,8),"0,0",binding).status=="absent")
	var stale: Dictionary = binding.duplicate()
	stale.generation += 1
	check("observation_rejects_stale_binding",service.navigation_request_observation(Vector2i.ZERO,"0,0",stale).status=="stale_binding")
	observed.binding.sourceKey = "caller-mutation"
	check("observation_copies_binding_and_never_drives_work",before==var_to_bytes([entry,service._dispatch_turn,context.worker.calls]))
	service._dispatch_turn = 16 # Named synthetic age, not a live timing claim.
	var aged: Dictionary = service.navigation_request_observation(Vector2i.ZERO,"0,0",binding)
	check("observation_reports_retained_age",aged.selectionRank==2 and aged.pendingWaitTurns==16
		and aged.firstPendingTurn==0 and aged.effectivePriority==0)
	service._dispatch(context.ready,Vector2i.ZERO)
	check("observation_distinguishes_selection_from_completion",service.navigation_request_observation(Vector2i.ZERO,"0,0",binding).selected
		and service.navigation_request_observation(Vector2i.ZERO,"0,0",binding).status=="pending")
	_urgency_complete(context,true)
	var count: int = entry.requested.size()
	check("observation_completed_receipt_does_not_requeue",service.navigation_request_observation(Vector2i.ZERO,"0,0",binding).status=="completed"
		and entry.requested.size()==count)
	_urgency_cleanup(context,"observation_cleanup")

func _run() -> void:
	_request_observation_controls()
	_urgency_order_and_admission()
	_urgency_fair_dispatch()
	_urgency_pending_capacity()
	_domain_schema_contract()
	await _domain_reset_lifecycle()
	check("demanded_lifecycle_completed",false)
	var value: Owner = owner()
	var service = value.structure_system.citadel_publication
	var admission = value.structure_system.citadel_terrain_admission
	var source: Dictionary = _nonempty_source(REGION)
	if source.is_empty():
		await close(value,"invalid_source_fixture")
		_finish_report()
		return
	inject(admission,REGION,source)
	source = {}
	var admitted: Dictionary = admission.source_state(REGION)
	var admission_ready: bool = admitted.get("status")=="ready"
	metrics.sourceAdmission = {"status":admitted.get("status",""),"reason":admitted.get("reason","")}
	check("fixture_nonempty_source_admitted",admission_ready)
	admitted = {}
	if not admission_ready:
		await close(value,"invalid_admission_fixture")
		_finish_report()
		return
	await wait_prepared(value.structure_system,1,REGION,"demanded_preparation_accepted")
	var available: bool = service._navigation.has(REGION) and service._prepared.has(REGION)
	check("producer_and_scene_holder_separate",available)
	if available:
		var binding: Dictionary = service._navigation[REGION].binding
		var description = service._prepared[REGION].prepared.describe(binding)
		check("scene_description_has_no_dense_tiles",description!=null and description.navigation_tiles.is_empty())
		var physical_valid: bool = service._prepared[REGION].prepared._payload.get("physicalIntegrity",{}).get("passed",false)
		check("fixture_source_passes_real_physical_validation",physical_valid)
		if description==null or not physical_valid:
			description = null
			await close(value,"invalid_preparation_fixture")
			_finish_report()
			return
		var producer_ref: WeakRef = _producer_weak(service)
		check("producer_initially_has_no_completed_tiles",_producer_completed_count(service)==0)
		# Query only a small declared output. The service must retain all remaining
		# tile requests across partial worker slices while holding no cursor alias.
		var inventory: Dictionary = service.navigation_source_domain(REGION,binding)
		var domain: Dictionary = inventory.get("domain",{})
		var domain_valid: bool = inventory.get("status")=="described" and inventory.is_read_only() \
			and inventory.get("binding")==binding and binding.is_read_only() and Service._valid_navigation_domain(domain)
		check("source_inventory_is_immutable_current_and_described",domain_valid)
		if not domain_valid:
			description=null; domain={}; inventory={}
			await close(value,"invalid_domain_fixture")
			_finish_report()
			return
		check("domain_description_is_not_physical_readiness",service.physical_publication_state(bounds()).get("status")!="ready")
		var source_requests: int = admission.source_requests
		var wrong: Dictionary = binding.duplicate()
		wrong.sourceKey += "|wrong-domain-request"
		check("wrong_binding_cannot_borrow_domain",service.navigation_source_domain(REGION,wrong).get("reason")=="structure_navigation_domain_stale")
		var original_key: String = admission._decisions[REGION].sourceKey
		admission._decisions[REGION].sourceKey = original_key+"|synthetic-current-source-change"
		check("stale_admission_cannot_borrow_domain",service.navigation_source_domain(REGION,binding).get("reason")=="structure_navigation_domain_stale")
		admission._decisions[REGION].sourceKey = original_key
		check("domain_queries_never_request_source_work",admission.source_requests==source_requests and service._inflight.is_empty())
		var keys: Array[String] = []
		# The producer domain includes conservative empty neighbours. These
		# points lie inside the declared slab, well clear of edges and tile seams.
		var tile_width: float = Layout.CELL_SIZE * Layout.NAV_TILE_CELL_SIZE
		for local_point: Vector3 in [Vector3(-10,0.5,0),Vector3(10,0.5,0)]:
			var world_point: Vector3 = description.origin + local_point
			var key: String = "%d,%d" % [floori(world_point.x/tile_width),floori(world_point.z/tile_width)]
			if not keys.has(key): keys.append(key)
		check("fixture_has_requested_tiles",keys.size()==2)
		var keys_in_domain: bool = keys.size()==2 and domain.tileKeys.has(keys[0]) and domain.tileKeys.has(keys[1])
		check("fixture_interior_tiles_are_distinct_and_in_domain",keys_in_domain)
		metrics.requestedTileKeys = keys.duplicate()
		if keys.size()!=2 or not keys_in_domain:
			description = null
			domain = {}
			inventory = {}
			await close(value,"invalid_tile_fixture")
			_finish_report()
			return
		for key: String in keys: check("retain_navigation_request_"+key,service._request_navigation_tile(service._navigation[REGION],key))
		var ready: Dictionary = service._refresh_demand(bounds())
		check("navigation_dispatch_accepted",service._dispatch_navigation(ready) and service._inflight.get("kind")=="navigation")
		check("service_relinquishes_mutable_cursor_before_poll",not service._navigation[REGION].has("navigationSource"))
		var in_flight_inventory: Dictionary = service.navigation_source_domain(REGION,binding)
		check("domain_available_independently_of_inflight_cursor",in_flight_inventory.get("status")=="described"
			and in_flight_inventory.is_read_only() and is_same(in_flight_inventory.get("domain"),domain)
			and in_flight_inventory.get("binding")==binding and _producer_alive(producer_ref))
		in_flight_inventory = {}
		var token: int = int(service._inflight.get("token",0))
		check("repeat_advance_does_not_redispatch_owned_cursor",not service._dispatch_navigation(ready) and service._inflight.get("token")==token)
		var deadline: int = Time.get_ticks_msec()+10000
		while service._navigation.has(REGION) and service._navigation[REGION].receipts.size()<keys.size() and Time.get_ticks_msec()<deadline:
			value.structure_system.advance_citadel_publication(bounds(),true)
			await process_frame
		var completed: bool = service._navigation.has(REGION) and service._navigation[REGION].receipts.size()==keys.size()
		check("requested_tiles_eventually_return",completed)
		if completed:
			check("same_source_cursor_returned",_same_producer(service,producer_ref))
			check("domain_identity_preserved_through_worker_roundtrip",is_same(service.navigation_source_domain(REGION,binding).get("domain"),domain))
			for key: String in keys:
				var receipt: Dictionary = service._navigation[REGION].receipts[key]
				check("immutable_bound_receipt_"+key,receipt.is_read_only() and receipt.binding==binding and receipt.tileKey==key and receipt.tile.is_read_only())
				check("real_nonempty_surface_receipt_"+key,receipt.get("outputPresent",false) and not receipt.tile.get("surfaces",[]).is_empty())
			check("tile_compilation_is_not_gameplay_readiness",service.physical_publication_state(bounds()).get("status")!="ready")
			# A new empty-domain request is still a real immutable producer receipt.
			# Cancel while queued, before the worker can mutate its input.
			check("retain_second_slice_request",service._request_navigation_tile(service._navigation[REGION],"62499,62499"))
			value.structure_system.advance_citadel_publication(bounds(),true)
			check("second_slice_queued",not service._inflight.is_empty())
			check("service_starts_transferred_navigation_on_dispatch_advance",service._last_worker_status.get("workerRunning",false)
				and service._last_worker_status.get("workerKind")=="navigation")
			service._prune_unwanted({})
			check("departure_revokes_cursor_receipts_and_token",service._navigation.is_empty() and service._inflight.is_empty())
			check("departure_revokes_domain_inventory",not service.navigation_source_domain(REGION,binding).has("domain"))
		# Release every borrowed source container before off-thread retirement.
		description = null
		domain = {}
		inventory = {}
		ready = {}
		await close(value,"demanded_navigation")
		check("producer_released_after_owned_worker_drain",not _producer_alive(producer_ref))
	else:
		await close(value,"demanded_navigation_failed_setup")
	check("demanded_lifecycle_completed",true)
	_finish_report()

func _finish_report() -> void:
	var report := {"schema":"citadel-demanded-navigation-service/v1","complete":true,"passed":not checks.values().has(false),
		"evidenceLevel":"injected_source_direct_service_lifecycle","checks":checks,"metrics":metrics,
		"doesNotProve":"No live scene, collision/nav publication, player movement, visual or loading-time acceptance."}
	var file := FileAccess.open(OS.get_environment("CITADEL_DEMANDED_NAVIGATION_REPORT"),FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	quit(0 if report.passed else 1)
