extends SceneTree
## Direct service/lifecycle evidence. Historical source is injected through real
## Admission._accept; no live Site generation, city nodes or gameplay is claimed.
const Structures = preload("res://scripts/StructureSystem.gd")
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Queue = preload("res://scripts/world/CitadelSiteBuildQueue.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const Service = preload("res://scripts/world/CitadelPublicationService.gd")
const WorkerControls = preload("res://scripts/testing/buildings/BuildingPublicationWorkerContract.gd")
const Runtime = preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"
const REGION := Vector2i(1,-3)
const SEED := "atlas-1492"

class Owner extends "res://scripts/MainCore.gd":
	var voxel_terrain_runtime
	func _ready() -> void: pass # Deliberately no gameplay boot.

class ObservedStructures extends Structures:
	var last_bounds := Rect2i()
	var last_allow := false
	func advance_citadel_publication(observer_bounds := Rect2i(), allow_dispatch := false) -> Dictionary:
		last_bounds = observer_bounds
		last_allow = allow_dispatch
		return super.advance_citadel_publication(observer_bounds,allow_dispatch)

class QuietGate extends "res://scripts/terrain/VoxelTerrainSiteGate.gd":
	# Real current-profile comparison; suppress unrelated native loading work.
	func advance() -> void: pass

class QuietRuntime extends Runtime:
	# Actual _process and generation_context_current, synthetic unrelated work.
	func update_viewer_position() -> void: pass
	func update_viewer_distance(_delta: float) -> void: pass
	func prune_startup_auxiliary_viewers() -> void: pass
	func collect_volume_edit_changes() -> void: pass
	func process_pending_edit_sections() -> void: pass

class ObservedAdmission extends Admission:
	var source_requests := 0
	var source_reads := 0
	func source_state(region: Vector2i) -> Dictionary:
		source_reads += 1
		return super.source_state(region)
	func request_source(region: Vector2i, priority := true) -> Dictionary:
		source_requests += 1
		return super.request_source(region,priority)

class DispatchProbe extends Worker:
	var calls := 0
	func dispatch(_source: Dictionary, _binding: Dictionary) -> Dictionary:
		calls += 1
		return {"status":"busy"} # Synthetic capacity observation; no worker launch.

class RetirementProbe extends RefCounted:
	var cancellations := 0
	func cancel() -> void: cancellations += 1

class ReleaseGuard extends RefCounted:
	var service
	func permits(_bounds: Rect2i) -> bool:
		service.set_retained_region_bounds([])
		return true

class GatedWorker extends Worker:
	var gate := Semaphore.new()
	var entered := Semaphore.new()
	var gated := true
	var synthetic_timeout := false
	func _prepare_source(source: Dictionary, binding: Dictionary, continuation: Callable) -> Dictionary:
		if gated:
			entered.post()
			gate.wait()
		return super._prepare_source(source,binding,continuation)
	func poll() -> Dictionary:
		var result := super.poll()
		if synthetic_timeout and result.workerKind == "preparation":
			result.progress.elapsedUsec = 61000000
		return result

var checks := {}
var metrics := {}
func _initialize() -> void: call_deferred("_run")
func check(label: String, ok: bool) -> void:
	checks[label] = ok
	if not ok: print("PUBLICATION SERVICE FAILURE ",label)
func owner() -> Owner:
	var value := Owner.new()
	value.seed_text = SEED
	root.add_child(value)
	value.set_process(false)
	value.set_physics_process(false)
	value.structure_system = ObservedStructures.new()
	value.structure_system.citadel_terrain_admission = ObservedAdmission.new()
	value.structure_system.setup(value)
	value.structure_system.citadel_terrain_admission.finalize_town_inputs({})
	return value
func bounds(region := REGION) -> Rect2i:
	return Rect2i(Field.candidate_for_region(SEED,region).centerCell,Vector2i.ONE)
func inject(a, region: Vector2i, source: Dictionary) -> void:
	var request := Queue._canonical_request(SEED,region,{},a._policy)
	var receipt := {"token":41,"epoch":a._queue._epoch,"sourceKey":request.sourceKey}
	a._requests[region] = {"priority":true,"receipt":receipt}
	var completion := receipt.duplicate()
	completion.status = "consumed"
	completion.result = source
	a._accept(completion)
func tiny(region: Vector2i) -> Dictionary:
	var candidate := Field.candidate_for_region(SEED,region)
	var source := WorkerControls.source().duplicate(true)
	var profile: Dictionary = source.profile
	var center: Vector2i = candidate.centerCell
	var origin := Vector3(center.x*1.35,0,center.y*1.35)
	profile.worldSeed = SEED
	profile.siteId = candidate.siteId
	profile.origin = origin
	profile.coreCells = Rect2i(center-Vector2i.ONE,Vector2i(3,3))
	profile.envelopeCells = Rect2i(center-Vector2i(2,2),Vector2i(5,5))
	profile.reservationCells = profile.envelopeCells
	for i in range(profile.groundRootPoints.size()): profile.groundRootPoints[i] += origin
	source.candidate = candidate
	source.manifest = {"ready":true,"sourceSignature":profile.sourceSignature}
	source.reservationCells = profile.reservationCells
	WorkerControls.freeze(source)
	return source
func evict(a, region: Vector2i) -> void:
	a._retired["contract-eviction:%s" % region] = a._sources[region]
	a._sources.erase(region)
func wait_entered(job, label: String) -> void:
	var deadline := Time.get_ticks_msec()+5000
	var entered: bool = job.entered.try_wait()
	while not entered and Time.get_ticks_msec()<deadline:
		await process_frame
		entered = job.entered.try_wait()
	check(label,entered)
func wait_prepared(s, target: int, region: Vector2i, label: String) -> void:
	var deadline := Time.get_ticks_msec()+60000
	while s.citadel_publication.stats().acceptedCount<target and Time.get_ticks_msec()<deadline:
		s.advance_citadel_publication(bounds(region),true)
		await process_frame
	check(label,s.citadel_publication.stats().acceptedCount==target)
func close(value: Owner, label: String) -> void:
	await value.wait_for_terrain_workers_before_quit()
	check(label+"_publication_shutdown",value.structure_system.citadel_publication.stats().shutdownComplete)
	check(label+"_admission_shutdown",value.structure_system.citadel_terrain_admission.stats().shutdownComplete)
	value.structure_system.main = null
	value.structure_system = null
	value.free()

static func load_actual() -> Dictionary:
	if FileAccess.get_sha256(INPUT)!=SHA: return {}
	var file := FileAccess.open(INPUT,FileAccess.READ)
	var source: Dictionary = file.get_var(false)
	file.close()
	WorkerControls.freeze(source)
	return source
func actual_source() -> void:
	print("PUBLICATION SERVICE actual_source")
	var loader := Thread.new()
	check("fixture_loader_started",loader.start(load_actual)==OK)
	while loader.is_alive(): await process_frame
	var source: Dictionary = loader.wait_to_finish()
	check("fixture_hash_and_frozen",not source.is_empty() and source.is_read_only())
	if source.is_empty(): return
	var value := owner()
	var s = value.structure_system
	var a = s.citadel_terrain_admission
	var service = s.citadel_publication
	inject(a,REGION,source)
	source = {}
	check("actual_admission_accepted",a.source_state(REGION).get("status")=="ready")
	var identity: Dictionary = a.source_state(REGION).binding
	s.advance_citadel_publication(bounds(),true)
	check("actual_queued_once",service.stats().dispatchCount==1 and not service.stats().publicationReady)
	# Eviction during owned preparation must not trigger a second Site build.
	evict(a,REGION)
	check("evicted_identity_survives",a.source_state(REGION).status=="prepared" and a.source_state(REGION).binding==identity)
	await wait_prepared(s,1,REGION,"actual_source_prepared")
	if service._prepared.has(REGION):
		var entry: Dictionary = service._prepared[REGION]
		check("actual_revision_profile",entry.binding==identity and entry.profile.sourceSignature==a.source_state(REGION).sourceSignature)
		check("actual_parts_retained",entry.prepared._payload.blueprint.parts.size()==4703)
		check("actual_furnishings_retained",entry.prepared._payload.furnishingPlan.parts.size()==210)
		metrics.actualPreparationUsec = entry.prepared._payload.preparationUsec
		var held: WeakRef = weakref(entry.prepared)
		entry = {}
		for i in range(4): s.advance_citadel_publication(bounds(),true)
		check("evicted_active_and_prepared_no_rebuild",a.source_requests==0 and a._requests.is_empty() and service.stats().dispatchCount==1)
		check("retained_actual_set",service.set_retained_region_bounds([bounds()]))
		s.advance_citadel_publication(Rect2i(),true)
		check("retained_evicted_prepared_survives_observer_departure",service._prepared.has(REGION) and a.source_requests==0 and held.get_ref()!=null)
		check("retained_actual_release",service.set_retained_region_bounds([]))
		s.advance_citadel_publication(Rect2i(),true)
		var deadline := Time.get_ticks_msec()+5000
		while held.get_ref()!=null and Time.get_ticks_msec()<deadline:
			await value.startup_loading_yield("Contract: draining departed prepared site")
		check("loading_yield_retires_departure",held.get_ref()==null and service.stats().preparedSites==0)
		metrics.actual = service.stats()
		# New approach with no owned source/preparation requires reconstruction.
		s.advance_citadel_publication(bounds(),true)
		check("reentry_requests_missing_source",a.source_requests==1 and a._requests.has(REGION))
		for i in range(4): s.advance_citadel_publication(bounds(),true)
		check("reentry_deduplicates_pending_request",a._requests.size()==1 and a._requests.has(REGION) and a._requests[REGION].receipt.is_empty() and service.stats().dispatchCount==1)
	check("preparation_not_city_readiness",s.generated_building_count==0 and s.generated_structures.is_empty() and not service.stats().publicationReady)
	await close(value,"actual")

func controlled_lifecycle() -> void:
	print("PUBLICATION SERVICE synthetic_lifecycle")
	var other := Vector2i.ZERO
	for z in range(-4,5):
		for x in range(-4,5):
			var region := Vector2i(x,z)
			if region!=REGION and not Field.candidate_for_region(SEED,region).is_empty(): other=region
	var value := owner()
	var s = value.structure_system
	var a = s.citadel_terrain_admission
	var service = s.citadel_publication
	var job := GatedWorker.new()
	service._worker = job
	inject(a,REGION,tiny(REGION)); inject(a,other,tiny(other))
	s.advance_citadel_publication(bounds(),true)
	s.advance_citadel_publication(bounds(),true)
	await wait_entered(job,"departure_worker_entered")
	check("retained_inflight_set",service.set_retained_region_bounds([bounds()]))
	var retained_token: int = service._inflight.token
	s.advance_citadel_publication(bounds(other),true)
	check("retained_inflight_survives_other_observer",service._inflight.get("token")==retained_token and service._desired.has(REGION) and service._desired.has(other))
	service.set_retained_region_bounds([])
	s.advance_citadel_publication(bounds(other),true)
	job.gated = false
	job.gate.post()
	await wait_prepared(s,1,other,"different_site_after_departure")
	check("departure_never_accepted",not service._prepared.has(REGION) and service._prepared.has(other))
	# Reset through the actual StructureSystem owner, retaining its worker.
	var original_generation: int = service.stats().generation
	s.reset()
	check("reset_same_owner_and_worker",s.citadel_publication==service and service._worker==job and service.stats().generation>original_generation)
	a.finalize_town_inputs({})
	inject(a,REGION,tiny(REGION))
	job.gated = true
	s.advance_citadel_publication(bounds(),true)
	var deadline := Time.get_ticks_msec()+5000
	while job._state==null and Time.get_ticks_msec()<deadline:
		s.advance_citadel_publication(bounds(),true); await process_frame
	s.advance_citadel_publication(bounds(),true)
	await wait_entered(job,"reset_worker_entered")
	s.reset(); a.finalize_town_inputs({})
	job.gate.post()
	# Actual Runtime early-return path must still drain a stale owned worker.
	var runtime := Runtime.new()
	runtime.main = value
	runtime.authority_ready = false
	deadline = Time.get_ticks_msec()+5000
	while Time.get_ticks_msec()<deadline:
		runtime._process(0.016)
		if not service.stats().worker.get("busy",true): break
		await process_frame
	check("native_unready_drain_rejects_old_generation",not service.stats().worker.busy and service.stats().preparedSites==0 and service.stats().acceptedCount==1)
	runtime.main = null; runtime.free()
	await close(value,"synthetic_reset")

func runtime_dispatch() -> void:
	var value := owner()
	var s = value.structure_system
	var a = s.citadel_terrain_admission
	inject(a,REGION,tiny(REGION))
	value.player = CharacterBody3D.new()
	value.add_child(value.player)
	var cell: Vector2i = Field.candidate_for_region(SEED,REGION).centerCell
	# Use the cell interior, not a float32 world coordinate on an exact boundary.
	value.player.position = Vector3((cell.x+0.5)*1.35,0,(cell.y+0.5)*1.35)
	var runtime := QuietRuntime.new()
	runtime.main = value
	runtime.configured_seed = SEED
	runtime.authority_ready = true
	runtime.terrain = VoxelTerrain.new() # Off-tree, no native loading.
	var gate := QuietGate.new()
	gate._admission = a
	gate._store = a.profile_store
	runtime.site_gate = gate
	check("runtime_real_generation_current",runtime.generation_context_current())
	runtime._process(0.016)
	var expected := Rect2i(cell-Vector2i.ONE*176,Vector2i.ONE*353)
	check("runtime_current_supplies_player_footprint",s.last_allow and s.last_bounds==expected)
	check("runtime_current_dispatches",s.citadel_publication.stats().dispatchCount==1)
	s.reset()
	check("runtime_real_generation_stale",not runtime.generation_context_current())
	var deadline := Time.get_ticks_msec()+5000
	while Time.get_ticks_msec()<deadline:
		runtime._process(0.016)
		if not s.citadel_publication.stats().worker.get("busy",true): break
		await process_frame
	check("runtime_stale_drains_without_dispatch",not s.last_allow and s.last_bounds==Rect2i() and not s.citadel_publication.stats().worker.busy and s.citadel_publication.stats().dispatchCount==1)
	runtime.terrain.free(); runtime.terrain=null
	runtime.site_gate=null; runtime.main=null; runtime.free()
	await close(value,"runtime_hooks")

func paused_and_failure() -> void:
	print("PUBLICATION SERVICE paused_and_failure")
	for unavailable: String in ["fatal","shutdown","unfinalized","timeout","paused"]:
		var value := owner()
		var s = value.structure_system
		var a = s.citadel_terrain_admission
		var service = s.citadel_publication
		var job := GatedWorker.new()
		service._worker = job
		inject(a,REGION,tiny(REGION))
		s.advance_citadel_publication(bounds(),true); s.advance_citadel_publication(bounds(),true)
		await wait_entered(job,unavailable+"_entered")
		if unavailable=="timeout":
			job.synthetic_timeout = true
			s.advance_citadel_publication(bounds(),true)
			check("timeout_recorded",service._failures.get(REGION,{}).get("reason")=="building_preparation_timeout")
			evict(a,REGION)
		else:
			evict(a,REGION)
		job.gate.post()
		var deadline := Time.get_ticks_msec()+5000
		while job._thread!=null and job._thread.is_alive() and Time.get_ticks_msec()<deadline: await process_frame
		# Drain-only maintenance must retain completion; elapsed timeout injection
		# cannot turn a completed result into running-work failure.
		job.synthetic_timeout = true
		s.advance_citadel_publication()
		if unavailable!="timeout": check(unavailable+"_paused_completion_retained",service.stats().worker.completedToken>0 and service.stats().preparedSites==0)
		match unavailable:
			"fatal": a._fatal="synthetic_admission_failure"
			"shutdown": a.request_shutdown()
			"unfinalized": a._town_inputs_finalized=false
			"paused": pass
		if unavailable in ["fatal","shutdown","unfinalized"]: check(unavailable+"_state_guard",a.source_state(REGION).status=="failed")
		for i in range(3):
			s.advance_citadel_publication(bounds(),true)
			await process_frame
		check(unavailable+"_acceptance",service.stats().acceptedCount==(1 if unavailable=="paused" else 0))
		check(unavailable+"_no_recipe_rebuild",a.source_requests==0 and a._requests.is_empty())
		check(unavailable+"_no_completed_timeout",not service._failures.has(REGION) if unavailable=="paused" else true)
		await close(value,unavailable)

func retained_demand() -> void:
	var value := owner()
	var a = value.structure_system.citadel_terrain_admission
	var service = value.structure_system.citadel_publication
	var regions: Array[Vector2i] = []
	for z in range(-6,7):
		for x in range(-6,7):
			var region := Vector2i(x,z)
			if not Field.candidate_for_region(SEED,region).is_empty(): regions.append(region)
	check("retained_fixture_enough_candidates",regions.size()>17)
	if regions.size()<=17:
		await close(value,"retained_short_fixture")
		return
	var first: Vector2i = regions.front()
	var last: Vector2i = regions.back()
	inject(a,first,tiny(first)); inject(a,last,tiny(last))
	var input: Array[Rect2i] = [bounds(first),bounds(last),bounds(first)]
	check("retained_disjoint_accepted",service.set_retained_region_bounds(input))
	input.clear()
	a.source_reads = 0
	var ready: Dictionary = service._refresh_demand(bounds(first))
	check("retained_disjoint_not_enclosed_and_deduplicated",ready.size()==2 and ready.has(first) and ready.has(last) and service._desired.size()==2 and a.source_reads==2)
	check("retained_input_array_owned",service.stats().retainedBounds==3)
	var prior: Array[Rect2i] = service._retained_region_bounds.duplicate()
	var too_many: Array[Rect2i] = []
	for i in range(65): too_many.append(bounds(first))
	check("retained_count_reject_atomic",not service.set_retained_region_bounds(too_many) and service._retained_region_bounds==prior)
	for invalid: Rect2i in [Rect2i(),Rect2i(Vector2i.ZERO,Vector2i(-1,1)),Rect2i(Vector2i.ZERO,Vector2i(Field.REGION_CELLS*17,1)),Rect2i(Vector2i(1000001,0),Vector2i.ONE),Rect2i(Vector2i(2147483640,0),Vector2i(100,1))]:
		check("retained_invalid_atomic_%s" % str(invalid),not service.set_retained_region_bounds([bounds(first),invalid]) and service._retained_region_bounds==prior)
	var full: Array[Rect2i] = []
	for i in range(64): full.append(Rect2i(Vector2i.ZERO,Vector2i(Field.REGION_CELLS*4,Field.REGION_CELLS*4)))
	check("retained_exact_limits_accepted",service.set_retained_region_bounds(full))
	service.set_retained_region_bounds(prior)
	ready = service._refresh_demand(Rect2i(Vector2i.ZERO,Vector2i(Field.REGION_CELLS*17,1)))
	check("retained_oversized_observer_preserves_both",ready.has(first) and ready.has(last) and service.stats().observerBoundsRejected)
	service.set_retained_region_bounds([])
	ready = service._refresh_demand(Rect2i(Vector2i.ZERO,Vector2i(Field.REGION_CELLS*17,1)))
	check("oversized_observer_retains_last_valid_sample",ready.size()==1 and ready.has(first))
	ready = service._refresh_demand(Rect2i())
	check("retained_empty_and_empty_observer_release",ready.is_empty() and service._desired.is_empty() and not service.stats().observerBoundsRejected)
	# Synthetic ready scene: exercise actual pruning and balanced single cancel,
	# without claiming node construction or actor-safe coordinator release.
	service.set_retained_region_bounds([bounds(last)])
	ready = service._refresh_demand(Rect2i())
	var probe := RetirementProbe.new()
	service._scenes[last] = {"region":last,"binding":ready[last].binding,"phase":"scene_ready","job":probe}
	service._prune_unwanted(ready)
	check("retained_ready_scene_not_observer_pruned",service._scenes.has(last) and probe.cancellations==0)
	service.set_retained_region_bounds([])
	service._prune_unwanted(service._refresh_demand(Rect2i()))
	service._prune_unwanted({})
	check("retained_release_cancels_once",service._scenes.is_empty() and service._retiring_scenes.size()==1 and probe.cancellations==1)
	service._retiring_scenes.clear() # Only the synthetic job above, no resources.
	# Capacity limits residency, never the complete desired/ready maps.
	var dispatch_probe := DispatchProbe.new()
	service._worker = dispatch_probe
	var requests: Array[Rect2i] = []
	for i in range(17):
		var region: Vector2i = regions[i]
		if region!=first and region!=last: inject(a,region,tiny(region))
		requests.append(bounds(region))
	service.set_retained_region_bounds(requests)
	ready = service._refresh_demand(Rect2i())
	for i in range(Service.MAX_REGIONS): service._prepared[regions[i]] = {"binding":ready[regions[i]].binding}
	service._dispatch(ready,Vector2i.ZERO)
	check("retained_capacity_keeps_all_demand",dispatch_probe.calls==0 and service._resident_region_count()==16 and service._desired.size()==17 and ready.size()==17)
	service._prepared.erase(regions[0])
	service._dispatch(ready,Vector2i.ZERO)
	check("retained_capacity_retries_after_slot_release",dispatch_probe.calls==1 and service._desired.size()==17)
	service._prepared.clear() # Synthetic registry entries, no prepared payloads.
	var guard := ReleaseGuard.new()
	guard.service = service
	check("retained_release_guard_bound",service.configure_construction_guard(guard.permits))
	check("retained_callback_release_rejects_stale_construction",not service._construction_allowed(ready[regions[16]]) and service.stats().retainedBounds==0)
	check("retained_unchanged_empty_demand_no_spurious_revision",service._construction_allowed(ready[regions[16]]))
	service.set_retained_region_bounds([bounds(last)])
	service.configure(a)
	check("retained_configure_clears",service.stats().retainedBounds==0 and service._refresh_demand(Rect2i()).is_empty())
	await close(value,"retained")

func _run() -> void:
	await retained_demand()
	await actual_source()
	await controlled_lifecycle()
	await runtime_dispatch()
	await paused_and_failure()
	var report := {"schema":"citadel-publication-service-contract/v1","complete":true,"passed":not checks.values().has(false),
		"evidenceLevel":"historical_source_direct_service_and_synthetic_lifecycle","sourceSha256":SHA,"seed":SEED,
		"checks":checks,"metrics":metrics,"doesNotProve":"No fresh recipe generation, scene parts, trees, doors, normal Main/New Game approach, visuals, save/Continue or gameplay/frame-budget acceptance."}
	var file := FileAccess.open(OS.get_environment("CITADEL_PUBLICATION_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("PUBLICATION SERVICE COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size()}))
	quit(0 if report.passed else 1)
