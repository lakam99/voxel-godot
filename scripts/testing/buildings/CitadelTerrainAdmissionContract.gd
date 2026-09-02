extends SceneTree
## Synthetic service/state-machine evidence only. Never invokes Site.prepare.
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Store = preload("res://scripts/world/GeneratedSiteProfileStore.gd")
const Queue = preload("res://scripts/world/CitadelSiteBuildQueue.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Profile = preload("res://scripts/world/BuildingTerrainProfile.gd")
const SEED := "atlas-1492"
const POLICY := {"regionCells": 64, "spawnChance": 0.0}

class SyntheticQueue extends Queue:
	const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
	const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
	var mode := "absent"
	var source_templates: Dictionary = {}
	var gate := Semaphore.new()
	var fail_retirement_once := false
	var synthetic_elapsed_usec := -1
	var cancelled_tokens: Array = []
	func poll() -> Dictionary:
		var value := super.poll()
		# Controlled elapsed-time report; never wait 450 seconds in a contract.
		if synthetic_elapsed_usec >= 0 and value.workerKind == "source":
			value.progress.elapsedUsec = synthetic_elapsed_usec
		return value
	func cancel(token: int) -> bool:
		cancelled_tokens.append(token)
		return super.cancel(token)
	func _prepare_site(_request: Dictionary, continuation: Callable) -> Dictionary:
		if mode == "prepared":
			var value: Dictionary = source_templates[_request.region].duplicate(true)
			value.blueprint = Blueprint.new("synthetic-admission",1,"stone")
			value.furnishingPlan = Plan.new("synthetic-furniture",1,"synthetic-admission")
			return value
		if mode == "gated":
			continuation.call("synthetic_wait")
			gate.wait()
			if not continuation.call("synthetic_released"): return {"status":"cancelled", "reason":"cancelled"}
		return {"status":"failed" if mode == "failed" else "absent", "reason":"synthetic_failure" if mode == "failed" else "synthetic_absent"}
	func _start_thread(work: Callable) -> int:
		if fail_retirement_once and _active.get("kind") == "retirement":
			fail_retirement_once = false
			return ERR_CANT_CREATE
		return super._start_thread(work)

class DisposalTrace extends RefCounted:
	var mutex := Mutex.new()
	var thread_id := -1
	func record() -> void:
		mutex.lock(); thread_id = OS.get_thread_caller_id(); mutex.unlock()
	func read() -> int:
		mutex.lock(); var result := thread_id; mutex.unlock(); return result

class DisposalProbe extends RefCounted:
	var trace: DisposalTrace
	func _init(value: DisposalTrace) -> void: trace = value
	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE: trace.record()

var checks: Dictionary = {}
var report := {"schema":"citadel-terrain-admission-contract/v1", "evidenceLevel":"synthetic_service_and_owned_worker_contract", "complete":false, "passed":false,
	"doesNotProve":"No Source rebuild, terrain/WGS admission, runtime publication, headed, NPC, navigation or gameplay acceptance."}
var regions: Array[Vector2i] = []
var output := ""

func _initialize() -> void: call_deferred("_run")
func check(key: String, value: bool) -> void:
	checks[key] = value
	if not value: print("CONTRACT FAILURE ", key)
func _freeze(value: Variant) -> void:
	if value is Dictionary:
		for item in value.values(): _freeze(item)
		value.make_read_only()
	elif value is Array:
		for item in value: _freeze(item)
		value.make_read_only()
func _candidate(region: Vector2i) -> Dictionary: return Field.candidate_for_region(SEED, region)
func _bounds(region: Vector2i) -> Rect2i: return Rect2i(_candidate(region).centerCell, Vector2i.ONE)
func _profile(region: Vector2i) -> Dictionary:
	var candidate := _candidate(region)
	var center: Vector2i = candidate.centerCell
	var origin := Vector3(center.x * 1.35, 0.0, center.y * 1.35)
	var mask: Array = []; var distances: Array = []
	for z in range(-2,3):
		for x in range(-2,3):
			mask.append(1 if absi(x)<=1 and absi(z)<=1 else 0)
			distances.append(float(maxi(0,maxi(absi(x),absi(z))-1)))
	return {"version":1,"worldSeed":SEED,"siteId":candidate.siteId,"sourceSignature":"a".repeat(64),"cellSize":1.35,
		"coreCells":Rect2i(center-Vector2i.ONE,Vector2i(3,3)),"envelopeCells":Rect2i(center-Vector2i(2,2),Vector2i(5,5)),
		"origin":origin,"level":0.0,"apronCells":1,"groundRootPoints":[origin+Vector3(-0.4,0,-0.4),origin+Vector3(0.4,0,-0.4),origin+Vector3(0.4,0,0.4),origin+Vector3(-0.4,0,0.4)],
		"reservationCells":Rect2i(center-Vector2i(2,2),Vector2i(5,5)),"supportMask":mask,"distanceCells":distances}
func _source(region: Vector2i) -> Dictionary:
	var profile := _profile(region)
	return {"status":"prepared","reason":"","candidate":_candidate(region),"profile":profile,"manifest":{"ready":true,"sourceSignature":profile.sourceSignature},
		"reservationCells":profile.reservationCells,"terrainReady":false,"publicationReady":false,"fixture":"synthetic_small_profile_no_recipe"}
func _admission(mode := "absent"):
	var a = Admission.new(); var q := SyntheticQueue.new(); q.mode = mode; a._queue = q
	a.configure(SEED,{},POLICY)
	a.finalize_town_inputs({})
	return a
func _receipt(a, region: Vector2i, source: Dictionary) -> Dictionary:
	a.request_bounds(_bounds(region)); a.advance()
	var result: Dictionary = a._requests[region].receipt.duplicate(true)
	result.status = "consumed"; result.result = source; return result
func _drain(a, label: String) -> void:
	a.request_shutdown()
	var deadline := Time.get_ticks_msec()+4000
	while Time.get_ticks_msec()<deadline:
		if a.advance().shutdownComplete: break
		await process_frame
	check(label+"_shutdown_complete", a.stats().shutdownComplete)
func _run() -> void:
	output = OS.get_environment("CITADEL_ADMISSION_OUTPUT")
	for z in range(-6,7):
		for x in range(-6,7):
			if not _candidate(Vector2i(x,z)).is_empty(): regions.append(Vector2i(x,z))
	check("candidate_fixture_count", regions.size()>=10)
	_store_controls()
	await _bounds_and_pressure()
	await _receipts_and_failures()
	await _lifecycle()
	await _external_disposal()
	await _source_deadline()
	await _capacity_reconstruction()
	await _unfinalized_controls()
	report.checks = checks; report.complete = true; report.passed = false not in checks.values()
	var f := FileAccess.open(output.path_join("report.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"\t")); f.close()
	print("ADMISSION RESULT ",JSON.stringify({"passed":report.passed,"checks":checks.size(),"complete":true}))
	quit(0 if report.passed else 1)
func _store_controls() -> void:
	var store := Store.new(SEED); var before := store.snapshot(); var p := _profile(regions[1])
	check("store_world_seed_getter",store.world_seed()==SEED)
	check("synthetic_profile_valid", Profile.valid(p,SEED,1.35))
	check("store_rejects_mutable", not store.append_prepared_profile(p))
	var shallow := p.duplicate(true); shallow.make_read_only()
	check("store_rejects_mutable_nested", not store.append_prepared_profile(shallow))
	_freeze(p); check("store_accepts_first",store.append_prepared_profile(p))
	var one := store.snapshot(); var bytes := var_to_bytes(one)
	var second := _profile(regions[0]); _freeze(second)
	check("store_accepts_second",store.append_prepared_profile(second))
	var two := store.snapshot()
	check("store_old_snapshot_immutable",before.is_read_only() and before.is_empty() and one.is_read_only() and var_to_bytes(one)==bytes)
	check("store_new_snapshot_sorted",two.is_read_only() and two.size()==2 and String(two[0].siteId)<String(two[1].siteId))
	check("store_nested_frozen",two[0].is_read_only() and two[0].supportMask.is_read_only() and two[0].groundRootPoints.is_read_only())
	check("store_duplicate_rejected",not store.append_prepared_profile(p))
	var overlap := p.duplicate(true); overlap.siteId = "synthetic-overlap"; _freeze(overlap)
	check("store_overlap_rejected",not store.append_prepared_profile(overlap))
	var other_seed := p.duplicate(true); other_seed.worldSeed = "other"; _freeze(other_seed)
	check("store_seed_rejected",not store.append_prepared_profile(other_seed))
	check("store_rejections_preserve_snapshot",var_to_bytes(two)==var_to_bytes(store.snapshot()))
func _bounds_and_pressure() -> void:
	var a = _admission(); var first: Vector2i = regions[0]
	var declared := Admission.declared_influence(_candidate(first))
	check("declared_extent_exact",declared.size==Vector2i(769,769) and declared.get_center()==_candidate(first).centerCell)
	check("outside_influence_ready",a.request_bounds(Rect2i(declared.end,Vector2i.ONE)).status=="ready" and a.stats().pendingRegions==0)
	check("invalid_bounds_failed",a.request_bounds(Rect2i()).reason=="unsupported_admission_bounds")
	check("region_limit_failed",a.request_bounds(Rect2i(Vector2i.ZERO,Vector2i(17*2048,1))).reason=="admission_region_limit")
	for index in range(10): check("demand_%d_retained"%index,a.request_bounds(_bounds(regions[index]),false).status=="pending")
	a.request_bounds(_bounds(first),true)
	check("duplicate_demand_priority",a.stats().pendingRegions==10 and a._requests[first].priority)
	check("candidate_cache_exact",a._candidates[first]==_candidate(first) and a._candidates.size()==10)
	a.advance()
	var undispatched := 0
	for request: Dictionary in a._requests.values():
		if request.receipt.is_empty(): undispatched += 1
	check("queue_full_retains_demands",undispatched==2 and a.stats().pendingRegions==10 and a._decisions.is_empty())
	var deadline := Time.get_ticks_msec()+4000
	while a.stats().pendingRegions>0 and Time.get_ticks_msec()<deadline:
		a.advance(); await process_frame
	check("queue_full_retries_all",a.stats().pendingRegions==0 and a.stats().decidedRegions==10)
	check("actual_absent_workers_ready",a.request_bounds(_bounds(first)).status=="ready" and a.stats().preparedSites==0)
	await _drain(a,"pressure")
func _receipts_and_failures() -> void:
	var first: Vector2i = regions[0]
	for field: String in ["token","epoch","sourceKey"]:
		var a = _admission(); var source := _source(first); _freeze(source)
		var exact := _receipt(a,first,source); var wrong := exact.duplicate(true)
		wrong[field] = "wrong-key" if field=="sourceKey" else int(exact[field])+1
		a._accept(wrong)
		check("fence_"+field,a.stats().pendingRegions==1 and a.stats().preparedSites==0 and a.profile_store.snapshot().is_empty() and a.stats().retiredGenerations==1)
		a._accept(exact)
		check("exact_after_"+field,a.stats().preparedSites==1 and a.request_bounds(_bounds(first)).status=="ready")
		var view: Dictionary = a.prepared_sources(); view.clear()
		check("registry_shell_detached_"+field,a.stats().preparedSites==1)
		await _drain(a,"fence_"+field)
	for fault: String in ["failed","cancelled","mutable","candidate","signature","outside"]:
		var a = _admission(); var source := _source(first)
		match fault:
			"failed", "cancelled": source = {"status":fault,"reason":"synthetic_"+fault}
			"candidate": source.candidate = _candidate(regions[1])
			"signature": source.manifest.sourceSignature = "mismatch"
			"outside": source.reservationCells = Admission.declared_influence(source.candidate).grow(1)
		if fault!="mutable": _freeze(source)
		a._accept(_receipt(a,first,source))
		check("reject_"+fault,a.request_bounds(_bounds(first)).status=="failed" and a.stats().preparedSites==0 and a.profile_store.snapshot().is_empty())
		if fault in ["failed","cancelled"]: check("reason_preserved_"+fault,a.request_bounds(_bounds(first)).reason=="synthetic_"+fault)
		await _drain(a,"reject_"+fault)
	var worker = _admission("failed"); worker.request_bounds(_bounds(first))
	var deadline := Time.get_ticks_msec()+4000
	while worker.request_bounds(_bounds(first)).status=="pending" and Time.get_ticks_msec()<deadline:
		worker.advance(); await process_frame
	check("actual_failed_worker_not_absent",worker.request_bounds(_bounds(first))=={"status":"failed","reason":"synthetic_failure"})
	await _drain(worker,"failed_worker")
func _lifecycle() -> void:
	var first: Vector2i = regions[0]; var a = _admission()
	var source := _source(first); _freeze(source); var exact := _receipt(a,first,source); a._accept(exact)
	var old_profiles: Array = a.profile_store.snapshot(); var old_bytes := var_to_bytes(old_profiles)
	a.configure(SEED,{},POLICY)
	a.finalize_town_inputs({})
	check("configure_clears_candidate_cache",a._candidates.is_empty())
	check("configure_resets_generation",a.stats().generation==2 and a.stats().preparedSites==0 and a.profile_store.snapshot().is_empty())
	a._accept(exact)
	check("old_generation_receipt_rejected",a.stats().preparedSites==0 and a.stats().decidedRegions==0)
	a.advance()
	check("old_profile_snapshot_survives_reset",var_to_bytes(old_profiles)==old_bytes)
	await _drain(a,"reset")
	check("shutdown_rejects_demand",a.request_bounds(_bounds(first))=={"status":"failed","reason":"shutting_down"})
	for operation: String in ["reset","shutdown"]:
		var gated = _admission("gated"); gated.request_bounds(_bounds(first)); gated.advance(); gated.advance()
		var deadline := Time.get_ticks_msec()+2000
		while gated._queue._state != null and gated._queue._state.snapshot().stage!="synthetic_wait" and Time.get_ticks_msec()<deadline: await process_frame
		check(operation+"_worker_entered",gated._queue._state != null and gated._queue._state.snapshot().stage=="synthetic_wait")
		if operation=="reset":
			gated.configure(SEED,{},POLICY)
			gated.finalize_town_inputs({})
		else: gated.request_shutdown()
		gated._queue.gate.post()
		await _drain(gated,"active_"+operation)
		check(operation+"_no_late_admission",gated.stats().preparedSites==0 and gated.profile_store.snapshot().is_empty())
func _external_disposal() -> void:
	var q := SyntheticQueue.new(); q.fail_retirement_once = true
	var trace := DisposalTrace.new(); var payload := {"probe":DisposalProbe.new(trace)}
	check("external_retirement_accepted",q.retire_external_payload(payload)); payload = {}
	check("external_retirement_busy_retained",not q.retire_external_payload({"second":true}))
	var first := q.poll()
	check("retirement_start_failure_retryable",first.retirementPending and first.retirementStartError==ERR_CANT_CREATE and trace.read()==-1)
	q.request_shutdown()
	var status := q.poll(); var deadline := Time.get_ticks_msec()+4000
	while not status.shutdownComplete and Time.get_ticks_msec()<deadline:
		await process_frame; status = q.poll()
	check("retirement_retry_shutdown_complete",status.shutdownComplete)
	check("external_payload_destroyed_on_worker",trace.read()!=-1 and trace.read()!=OS.get_thread_caller_id() and status.lastRetirementThreadId==trace.read())
	report.retirement = {"ownerThreadId":OS.get_thread_caller_id(),"destructorThreadId":trace.read(),"queue":status}
func _source_deadline() -> void:
	var a = _admission("gated"); var first: Vector2i = regions[0]
	a.request_bounds(_bounds(first)); a.advance()
	var token: int = a._requests[first].receipt.token
	a._queue.synthetic_elapsed_usec = 450000000
	a.advance()
	check("source_deadline_exact_boundary_pending",a.request_bounds(_bounds(first)).status=="pending" and a._queue.cancelled_tokens.is_empty())
	a._queue.synthetic_elapsed_usec = 450000001
	a.advance()
	check("source_deadline_expired_failed",a.request_bounds(_bounds(first))=={"status":"failed","reason":"citadel_source_preparation_timeout"})
	check("source_deadline_cancels_exact_token",a._queue.cancelled_tokens==[token] and a._queue._state.is_cancelled())
	check("source_deadline_no_profile",a.profile_store.snapshot().is_empty() and a.stats().preparedSites==0)
	a._queue.synthetic_elapsed_usec = -1
	a._queue.gate.post()
	await _drain(a,"source_deadline")
	report.sourceDeadlineEvidence = "Synthetic elapsed-time injection into real queue status; boundary 450000000 us pending, 450000001 us failed/cancelled. No wall-clock timeout test."
func _capacity_reconstruction() -> void:
	var a = _admission("prepared")
	for i in range(17):
		a._queue.source_templates[regions[i]] = _source(regions[i])
		a.request_bounds(_bounds(regions[i]))
	var oldest: Variant = null
	var snapshot16: Array = []
	var bytes16 := PackedByteArray()
	var deadline := Time.get_ticks_msec()+5000
	while a.stats().pendingRegions>0 and Time.get_ticks_msec()<deadline:
		a.advance()
		if a.stats().preparedSites==16 and oldest==null:
			oldest=a._sources.keys()[0]; snapshot16=a.profile_store.snapshot(); bytes16=var_to_bytes(snapshot16)
		await process_frame
	check("capacity17_completed",a.stats().pendingRegions==0 and a.stats().decidedRegions==17)
	check("capacity17_profiles17_cache16",a.profile_store.snapshot().size()==17 and a.stats().preparedSites==16)
	check("capacity17_oldest_evicted",oldest!=null and not a._sources.has(oldest) and a._decisions[oldest].status=="prepared")
	check("capacity17_old_snapshot_unchanged",snapshot16.size()==16 and var_to_bytes(snapshot16)==bytes16)
	if oldest==null:
		await _drain(a,"capacity17_failed_setup"); return
	var terrain: Array = a.profile_store.snapshot(); var terrain_bytes := var_to_bytes(terrain)
	var canonical_key: String = a._decisions[oldest].sourceKey
	var evicted_next: Vector2i = a._sources.keys()[0]
	check("evicted_terrain_still_ready",a.request_bounds(_bounds(oldest)).status=="ready")
	check("evicted_source_reconstruction_pending",a.request_source(oldest).status=="pending")
	var dispatched_key := ""
	deadline=Time.get_ticks_msec()+5000
	while a.request_source(oldest).status=="pending" and Time.get_ticks_msec()<deadline:
		a.advance()
		if a._requests.has(oldest): dispatched_key=String(a._requests[oldest].receipt.get("sourceKey",dispatched_key))
		await process_frame
	check("reconstruction_ready",a.request_source(oldest).status=="ready")
	check("reconstruction_same_canonical_key",dispatched_key==canonical_key and a._decisions[oldest].sourceKey==canonical_key)
	check("reconstruction_profiles17_cache16",a.profile_store.snapshot().size()==17 and a.stats().preparedSites==16 and not a._sources.has(evicted_next))
	check("reconstruction_terrain_exact",var_to_bytes(a.profile_store.snapshot())==terrain_bytes and var_to_bytes(terrain)==terrain_bytes)
	check("eviction_uses_owned_retirement",a.stats().queue.lastRetirementThreadId!=-1 and a.stats().queue.lastRetirementThreadId!=OS.get_thread_caller_id())
	var previous: Dictionary = a._decisions[evicted_next]
	for field: String in ["sourceKey","sourceSignature","level","envelopeCells","apronCells"]:
		var receipt := {"sourceKey":previous.sourceKey}; var altered := _profile(evicted_next)
		match field:
			"sourceKey": receipt.sourceKey="different-canonical-key"
			"sourceSignature": altered.sourceSignature="b".repeat(64)
			"level": altered.level+=1.35
			"envelopeCells": altered.envelopeCells=altered.envelopeCells.grow(1)
			"apronCells": altered.apronCells+=1
		check("reconstruction_rejects_stale_"+field,not a._admit_or_reuse_profile(evicted_next,receipt,altered))
	# Real queue delivery of a stale reconstruction, not just direct predicate.
	var stale := _source(evicted_next)
	stale.profile.sourceSignature="b".repeat(64); stale.manifest.sourceSignature=stale.profile.sourceSignature
	a._queue.source_templates[evicted_next]=stale
	a.request_source(evicted_next)
	deadline=Time.get_ticks_msec()+5000
	while a.request_source(evicted_next).status=="pending" and Time.get_ticks_msec()<deadline:
		a.advance(); await process_frame
	check("stale_worker_reconstruction_failed",a.request_source(evicted_next).status=="failed" and a.request_source(evicted_next).reason=="generated_site_profile_admission_failed")
	check("stale_reconstruction_not_cached",not a._sources.has(evicted_next) and a.stats().preparedSites==16)
	check("stale_reconstruction_preserves_terrain",var_to_bytes(a.profile_store.snapshot())==terrain_bytes)
	report.capacity={"admittedProfiles":a.profile_store.snapshot().size(),"cachedSources":a.stats().preparedSites,"evictedRegion":oldest,"reconstructedSourceKey":dispatched_key,"staleRegion":evicted_next,"evidence":"17 real owned-worker deliveries of synthetic small prepared sources; same-key reconstruction and stale-signature worker rejection."}
	# One additional tiny synthetic source legitimately evicts another prepared
	# source. Its real queue rebuild then contradicts admission by returning absent.
	var absent_region: Vector2i = a._sources.keys()[0]
	var absent_key: String = a._decisions[absent_region].sourceKey
	var extra: Vector2i = regions[17]
	a._queue.source_templates[extra]=_source(extra)
	a.request_bounds(_bounds(extra))
	deadline=Time.get_ticks_msec()+5000
	while a.request_bounds(_bounds(extra)).status=="pending" and Time.get_ticks_msec()<deadline:
		a.advance(); await process_frame
	check("absent_rebuild_prepared_then_evicted",a._decisions[absent_region].status=="prepared" and not a._sources.has(absent_region))
	var before_absent: Array = a.profile_store.snapshot()
	var before_absent_bytes := var_to_bytes(before_absent)
	a._queue.mode="absent"
	check("absent_rebuild_requested",a.request_source(absent_region).status=="pending")
	var absent_dispatch_key := ""
	deadline=Time.get_ticks_msec()+5000
	while a.request_source(absent_region).status=="pending" and Time.get_ticks_msec()<deadline:
		a.advance()
		if a._requests.has(absent_region): absent_dispatch_key=String(a._requests[absent_region].receipt.get("sourceKey",absent_dispatch_key))
		await process_frame
	var absent_result: Dictionary = a.request_source(absent_region)
	check("absent_rebuild_same_canonical_key",absent_dispatch_key==absent_key)
	check("prepared_to_absent_failed_exact_reason",absent_result.get("status")=="failed" and absent_result.get("reason")=="prepared_site_rebuild_became_absent")
	check("prepared_to_absent_bounds_failed",a.request_bounds(_bounds(absent_region))=={"status":"failed","reason":"prepared_site_rebuild_became_absent"})
	check("prepared_to_absent_profile_retained_exact",a.profile_store.snapshot().size()==18 and var_to_bytes(a.profile_store.snapshot())==before_absent_bytes and var_to_bytes(before_absent)==before_absent_bytes)
	check("prepared_to_absent_no_source_cached",not a._sources.has(absent_region) and a.stats().preparedSites==16)
	report.preparedToAbsent={"region":absent_region,"sourceKey":absent_dispatch_key,"result":absent_result,"profilesRetained":a.profile_store.snapshot().size(),"cachedSources":a.stats().preparedSites,"evidence":"Real synthetic-worker absent result after actual cache eviction; prior 17-profile capacity assertions are recorded separately."}
	await _drain(a,"capacity17")
func _unfinalized_controls() -> void:
	var a := Admission.new(); var queue := SyntheticQueue.new(); a._queue=queue
	a.configure(SEED,{},POLICY)
	var absent_region := Vector2i.ZERO
	for x in range(-20,21):
		if _candidate(Vector2i(x,0)).is_empty(): absent_region=Vector2i(x,0); break
	check("unfinalized_candidate_free_fixture",_candidate(absent_region).is_empty())
	var expected := {"status":"failed","reason":"citadel_town_inputs_unfinalized"}
	check("unfinalized_candidate_free_bounds_rejected",a.request_bounds(Rect2i(absent_region*2048,Vector2i.ONE))==expected)
	check("unfinalized_candidate_bounds_rejected",a.request_bounds(_bounds(regions[0]))==expected)
	check("unfinalized_source_rejected",a.request_source(regions[0])==expected)
	check("unfinalized_no_domain_mutations",a._candidates.is_empty() and a._requests.is_empty() and a._decisions.is_empty() and a._sources.is_empty() and a.profile_store.snapshot().is_empty())
	a.advance()
	check("unfinalized_no_queue_dispatch",queue._next_token==1 and queue._pending.is_empty() and queue._active.is_empty() and queue._thread==null)
	# Defensive dispatch guard: deliberately inject an otherwise unreachable
	# pending shell, then prove advance cannot dispatch it before finalization.
	a._requests[regions[0]]={"priority":true,"receipt":{}}
	a.advance()
	check("unfinalized_advance_defensive_guard",queue._next_token==1 and queue._pending.is_empty() and queue._thread==null and a._requests[regions[0]].receipt.is_empty())
	a._requests.clear()
	check("unfinalized_not_fatal_poison",a.stats().failure.is_empty())
	check("unfinalized_later_finalize_ready",a.finalize_town_inputs({}).status=="ready")
	check("finalized_candidate_free_ready",a.request_bounds(Rect2i(absent_region*2048,Vector2i.ONE)).status=="ready")
	check("finalized_source_pending",a.request_source(regions[0]).status=="pending")
	var deadline := Time.get_ticks_msec()+3000
	while a.request_source(regions[0]).status=="pending" and Time.get_ticks_msec()<deadline:
		a.advance(); await process_frame
	check("finalized_ordinary_completion",a.request_source(regions[0]).status=="absent" and a.request_bounds(_bounds(regions[0])).status=="ready" and a.stats().failure.is_empty())
	await _drain(a,"unfinalized")
