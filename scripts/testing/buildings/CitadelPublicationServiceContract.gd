extends SceneTree
## Direct service/lifecycle evidence. Historical source is injected through real
## Admission._accept; no live Site generation, city nodes or gameplay is claimed.
const Structures = preload("res://scripts/StructureSystem.gd")
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Queue = preload("res://scripts/world/CitadelSiteBuildQueue.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Service = preload("res://scripts/world/CitadelPublicationService.gd")
const WorkerControls = preload("res://scripts/testing/buildings/BuildingPublicationWorkerContract.gd")
const Runtime = preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"
const REGION := Vector2i(1,-3)
const SEED := "atlas-1492"
const ACTUAL_PACKET_GROUP := "building:castle_back_wall_foundation"
const ACTUAL_INELIGIBLE_GROUP := "building:castle_gatehouse_portcullis"
const ACTUAL_PACKET_TILE := Vector2i(198,-337)
const ACTUAL_PACKET_TILE_GROUPS: Array[String] = [
	"building:castle_compound_foundation_segment_00",
	"building:castle_tower_04_back",
	"building:castle_tower_04_battlement_back_0",
	"building:castle_tower_04_battlement_left_7",
	"building:castle_tower_04_floor",
	"building:castle_tower_04_foundation",
	"building:castle_tower_04_front",
	"building:castle_tower_04_left",
	"building:castle_tower_04_right",
	"building:castle_tower_04_roof_deck"
]

class Owner extends "res://scripts/MainRuntimeTools.gd":
	func _ready() -> void: pass # Deliberately no gameplay boot.

class ObservedStructures extends Structures:
	var last_bounds := Rect2i()
	var last_allow := false
	var last_budget_usec := -1
	var advance_calls := 0
	func advance_citadel_publication(observer_bounds := Rect2i(), allow_dispatch := false,
			budget_usec := CITADEL_PUBLICATION_BUDGET_USEC) -> Dictionary:
		last_bounds = observer_bounds
		last_allow = allow_dispatch
		last_budget_usec = budget_usec
		advance_calls += 1
		return super.advance_citadel_publication(observer_bounds,allow_dispatch,budget_usec)

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

class SchedulingJobProbe extends RefCounted:
	var source_requirement_calls := 0
	func source_dependency_requirements(_bounds: Rect2i, _binding: Dictionary) -> Dictionary:
		source_requirement_calls += 1
		return {"status":"failed","reason":"live_scene_proof_entered_scheduling"}

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
	func _prepare_source(source: Dictionary, binding: Dictionary, continuation: Callable, description_callback: Callable = Callable()) -> Dictionary:
		if gated:
			entered.post()
			gate.wait()
		return super._prepare_source(source,binding,continuation,description_callback)
	func poll() -> Dictionary:
		var result := super.poll()
		if synthetic_timeout and result.workerKind == "preparation":
			result.progress.elapsedUsec = 61000000
		return result

class DescriptionGatedWorker extends Worker:
	var gate := Semaphore.new()
	var forward_description: Callable
	func _prepare_source(source: Dictionary, binding: Dictionary, continuation: Callable, description_callback: Callable = Callable()) -> Dictionary:
		forward_description = description_callback
		var result: Dictionary = super._prepare_source(source,binding,continuation,_pause_description)
		forward_description = Callable()
		return result
	func _pause_description(value) -> bool:
		var accepted: bool = forward_description.call(value) == true
		gate.wait()
		return accepted

class PacketTrees extends RefCounted:
	var publish_calls := 0
	func publish(_parent: Node3D, _id: String, _position: Vector3, _biome: String, _request: Dictionary, _yaw: float) -> Dictionary:
		publish_calls += 1
		return {"status":"ignored"}
	func retire(_id: String, _body: StaticBody3D) -> void: pass

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

func retained_packet_request(binding: Dictionary, group_ids: Array[String]) -> Dictionary:
	var query := bounds()
	var admission: Dictionary = Service.DemandSet.from_regions([query],Service.DISCOVERY_CHUNK_SIZE,Service.MAX_DISCOVERY_CHUNKS,32)
	var navigation: Dictionary = Service.DemandSet.from_regions([query],Service.NAVIGATION_TILE_CELLS,Service.MAX_PENDING_NAVIGATION_TILES)
	var navigation_keys: Array[String] = []
	for key: Vector2i in navigation.keys:
		navigation_keys.append("%d,%d" % [key.x,key.y])
	navigation_keys.sort()
	return {"ownerId":77,"bounds":query,"priority":0,"admissionKeys":admission.keys.keys(),
		"navigationTileKeys":navigation_keys,"sites":[{"binding":binding.duplicate(),"groupIds":group_ids.duplicate()}]}

func retained_packet_tile_request(binding: Dictionary, group_ids: Array[String], tile: Vector2i) -> Dictionary:
	var request := retained_packet_request(binding,group_ids)
	var key := "%d,%d" % [tile.x,tile.y]
	if not request.navigationTileKeys.has(key): request.navigationTileKeys.append(key)
	request.navigationTileKeys.sort()
	return request

func exterior_boundary_probe(description, reservation: Rect2i, census: Dictionary) -> Dictionary:
	if reservation.size.x<=0 or reservation.size.y<=0: return {}
	var points: Array[Vector2i] = [reservation.position,
		Vector2i(reservation.end.x-1,reservation.position.y),
		Vector2i(reservation.position.x,reservation.end.y-1),reservation.end-Vector2i.ONE,
		Vector2i(reservation.position.x+reservation.size.x/2,reservation.position.y),
		Vector2i(reservation.position.x+reservation.size.x/2,reservation.end.y-1),
		Vector2i(reservation.position.x,reservation.position.y+reservation.size.y/2),
		Vector2i(reservation.end.x-1,reservation.position.y+reservation.size.y/2)]
	var eligible: Dictionary = {}
	for group_id: String in census.get("groups",{}):
		if bool(census.groups[group_id].get("eligible",false)): eligible[group_id] = true
	for point: Vector2i in points:
		var bounds := Rect2i(point,Vector2i.ONE)
		var direct: Dictionary = description.physical_group_requirements(bounds)
		if direct.get("status")!="described" or not direct.get("groupIds",[]).is_empty(): continue
		var boundary: Dictionary = description.exterior_structural_group_requirements(bounds,eligible)
		if boundary.get("status")=="described" and not boundary.get("groupIds",[]).is_empty():
			return {"bounds":bounds,"direct":direct,"boundary":boundary}
	return {}

func wait_inflight_kind(s, service, kind: String, label: String) -> void:
	var deadline := Time.get_ticks_msec()+105000
	while (service._inflight.get("kind","")!=kind) and Time.get_ticks_msec()<deadline:
		s.advance_citadel_publication(Rect2i(),true)
		await process_frame
	check(label,service._inflight.get("kind","")==kind)
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

func actual_packet_demand() -> void:
	# The retained-source request is the only production opt-in for packet mode.
	# Both controls use the frozen fixture; no recipe/city generation occurs.
	var source := load_actual()
	check("actual_packet_fixture_frozen",not source.is_empty() and source.is_read_only())
	if source.is_empty(): return
	var reservation: Rect2i = source.get("reservationCells",Rect2i())
	var value := owner()
	var s = value.structure_system
	var admission = s.citadel_terrain_admission
	var service = s.citadel_publication
	var parent := Node3D.new()
	var trees := PacketTrees.new()
	value.add_child(parent)
	inject(admission,REGION,source)
	source={}
	var binding: Dictionary = admission.source_state(REGION).binding
	check("actual_packet_scene_callbacks_bound",service.configure_scene_publication(parent,trees.publish,trees.retire))
	check("actual_packet_nonempty_normal_request_admitted",service.set_retained_source_requests([retained_packet_request(binding,[ACTUAL_PACKET_GROUP])]))
	await wait_inflight_kind(s,service,"physical_group_packet","actual_packet_worker_started")
	metrics.actualPacketPending={"inflight":service._inflight.duplicate(true),"prepared":service._prepared.size(),"scenes":service._scenes.size(),
		"sceneCallbacksReady":service._scene_callbacks_ready(),"failures":service._failures.duplicate(true),"stats":service.stats()}
	var active: Dictionary = service._worker._active
	var started_groups: Array = active.get("groupIds",[])
	var actual_base = service._scenes.get(REGION,{}).get("job",null)
	var base = actual_base._cpu.get("publicationBase") if actual_base!=null else null
	var census := Preparation.classify_physical_group_packet_eligibility(base.description.publication_groups,base.building_source,base.furnishing_source) if base!=null else {}
	var selected_census: Dictionary = census.get("groups",{}).get(ACTUAL_PACKET_GROUP,{})
	var useful: Dictionary = service._first_useful_packet_groups(base.description,base,census,{}) if base!=null else {}
	check("actual_packet_selected_exact_nonempty_normal_group",started_groups==[ACTUAL_PACKET_GROUP] and census.get("ready",false) \
		and selected_census.get("eligible",false) and selected_census.get("families",[]).has("normal"))
	check("actual_first_useful_window_includes_structural_clearance_anchor",useful.get("status")=="ready" \
		and useful.get("structuralGroupIds",[]).size()==1 \
		and useful.get("structuralGroupIds",[]).all(func(id): return useful.get("groupIds",[]).has(id)))
	var exterior_probe: Dictionary = exterior_boundary_probe(base.description if base!=null else null,reservation,census) if base!=null else {}
	var exterior_boundary: Dictionary = exterior_probe.get("boundary",{})
	check("actual_packet_exterior_reservation_selects_minimal_structural_closure",not exterior_probe.is_empty() \
		and exterior_probe.direct.get("groupIds",[]).is_empty() and exterior_boundary.get("boundarySelection","")=="nearest_collision_bearing_structural_group" \
		and not exterior_boundary.get("boundaryGroupId","").is_empty() and exterior_boundary.get("groupIds",[]).has(exterior_boundary.get("boundaryGroupId","")) \
		and exterior_boundary.get("groupIds",[]).size()<base.description.publication_groups.groups.size() and not exterior_boundary.get("publicationAcknowledged",true))
	metrics.actualPacketStart={"fixtureSha256":SHA,"binding":binding.duplicate(),"groupId":ACTUAL_PACKET_GROUP,
		"families":selected_census.get("families",[]),"workerKind":active.get("kind",""),
		"transactionId":service._inflight.get("transactionId",0),"exteriorBoundaryProbe":exterior_probe.duplicate(true),
		"scope":"actual frozen source, service dispatch and worker packet start plus exterior reservation boundary selection"}
	# The next receipt has to come from the packet-mode publisher itself.  Keep
	# the retained demand live while the bounded main-thread publication slices
	# advance; no complete PreparedSource or legacy scene request is permitted.
	var receipt: Dictionary = {}
	var trace: Array[Dictionary] = []
	var deadline := Time.get_ticks_msec()+120000
	while Time.get_ticks_msec()<deadline:
		var scene_entry: Dictionary = service._scenes.get(REGION,{})
		var scene_job = scene_entry.get("job",null)
		var phase := String(scene_job.status_count().get("phase","") if scene_job!=null else "")
		var state := {"inflight":String(service._inflight.get("kind","")),"phase":phase,
			"packetMode":bool(scene_entry.get("packetMode",false))}
		if trace.is_empty() or trace.back()!=state: trace.append(state)
		if scene_job!=null:
			receipt = scene_job.physical_group_receipt(ACTUAL_PACKET_GROUP,binding)
			if receipt.get("status") in ["ready","failed"]: break
		s.advance_citadel_publication(Rect2i(),true)
		await process_frame
	var final_scene_entry: Dictionary = service._scenes.get(REGION,{})
	var final_scene_job = final_scene_entry.get("job",null)
	if final_scene_job!=null and receipt.is_empty(): receipt=final_scene_job.physical_group_receipt(ACTUAL_PACKET_GROUP,binding)
	var publisher = final_scene_job._building if final_scene_job!=null else null
	check("actual_packet_physical_receipt_ready",receipt.get("status")=="ready")
	check("actual_packet_receipt_exact_binding_and_transaction",receipt.get("binding")==binding and receipt.get("groupId")==ACTUAL_PACKET_GROUP \
		and int(receipt.get("transactionId",0))>0 and int(receipt.get("sceneInstanceId",0))>0)
	check("actual_packet_receipt_remains_packet_native",bool(final_scene_entry.get("packetMode",false)) and final_scene_job!=null \
		and bool(final_scene_job._base_packet_mode) and not final_scene_job._cpu.has("prepared") and publisher!=null and bool(publisher._physical_packet_mode) \
		and service._failures.is_empty())
	metrics.actualPacketReceipt={"fixtureSha256":SHA,"binding":binding.duplicate(),"groupId":ACTUAL_PACKET_GROUP,
		"receipt":receipt.duplicate(true),"trace":trace,"worker":service._worker.poll(),"stats":service.stats(),
		"scope":"actual frozen source, exact retained group packet compiles and reaches a live physical receipt; no legacy geometry fallback"}
	await close(value,"actual_packet")

	# A separate admitted source prevents test cancellation from influencing the
	# deferred-group control. An unsupported door-owning group must retain its
	# exact source demand and binding in the packet scene. It must never widen to
	# a complete legacy source preparation.
	source = load_actual()
	check("actual_packet_deferred_fixture_frozen",not source.is_empty() and source.is_read_only())
	if source.is_empty(): return
	value = owner(); s=value.structure_system; admission=s.citadel_terrain_admission; service=s.citadel_publication
	parent=Node3D.new()
	trees=PacketTrees.new()
	value.add_child(parent)
	inject(admission,REGION,source); source={}
	binding=admission.source_state(REGION).binding
	check("actual_packet_deferred_scene_callbacks_bound",service.configure_scene_publication(parent,trees.publish,trees.retire))
	check("actual_packet_ineligible_request_admitted",service.set_retained_source_requests([retained_packet_request(binding,[ACTUAL_INELIGIBLE_GROUP])]))
	var deferred_entry: Dictionary = {}
	var deferred_demand: Dictionary = {}
	var deferred_trace: Array[Dictionary] = []
	var deferred_deadline := Time.get_ticks_msec()+120000
	while Time.get_ticks_msec()<deferred_deadline:
		deferred_entry=service._scenes.get(REGION,{})
		deferred_demand=deferred_entry.get("packetDemandStatus",{})
		var deferred_state := {"inflight":String(service._inflight.get("kind","")),"prepared":service._prepared.has(REGION),
			"scene":not deferred_entry.is_empty(),"packetMode":bool(deferred_entry.get("packetMode",false)),
			"demand":deferred_demand.duplicate(true),"failure":service._failures.get(REGION,{})}
		if deferred_trace.is_empty() or deferred_trace.back()!=deferred_state: deferred_trace.append(deferred_state)
		if bool(deferred_entry.get("packetMode",false)) and deferred_demand.get("reason","")=="packet_foreground_groups_deferred": break
		s.advance_citadel_publication(Rect2i(),true)
		await process_frame
	deferred_entry=service._scenes.get(REGION,{})
	deferred_demand=deferred_entry.get("packetDemandStatus",{})
	var deferred_job = deferred_entry.get("job",null)
	active=service._worker._active
	check("actual_packet_ineligible_is_explicitly_deferred",deferred_demand.get("status")=="retained" \
		and deferred_demand.get("reason")=="packet_foreground_groups_deferred" \
		and deferred_demand.get("blockedGroupIds",[]).has(ACTUAL_INELIGIBLE_GROUP) \
		and deferred_demand.get("deferredGroupIds",[]).has(ACTUAL_INELIGIBLE_GROUP) \
		and not deferred_demand.get("foregroundGroupIds",[]).has(ACTUAL_INELIGIBLE_GROUP) \
		and deferred_demand.get("requests",[]).is_empty())
	check("actual_packet_ineligible_retains_retryable_packet_demand",service._packet_group_ids(binding).has(ACTUAL_INELIGIBLE_GROUP) \
		and deferred_job!=null and bool(deferred_job._base_packet_mode) and bool(deferred_job._packet_foreground_configured) \
		and deferred_job._packet_deferred_groups.has(ACTUAL_INELIGIBLE_GROUP) and not deferred_job._packet_foreground_groups.has(ACTUAL_INELIGIBLE_GROUP))
	check("actual_packet_ineligible_preserves_binding_without_legacy_preparation",bool(deferred_entry.get("packetMode",false)) \
		and deferred_entry.get("binding",{})==binding and admission.source_state(REGION).binding==binding \
		and service._inflight.get("kind","")!="preparation" \
		and active.get("kind","")!="preparation" and deferred_job!=null and not deferred_job._cpu.has("prepared") \
		and service._failures.is_empty())
	metrics.actualPacketDeferred={"fixtureSha256":SHA,"binding":binding.duplicate(),"groupId":ACTUAL_INELIGIBLE_GROUP,
		"packetDemandStatus":deferred_demand.duplicate(true),"trace":deferred_trace,"workerKind":active.get("kind",""),"dispatchCount":service.stats().dispatchCount,
		"scope":"actual frozen source keeps an unsupported foreground group explicit and retryable in packet mode; no whole-source legacy preparation"}
	await close(value,"actual_packet_deferred")

## Exact actual packet closure for the smallest fully eligible navigation tile.
## It proves retained group ordering, packet physical receipt, then the existing
## navigation producer receipt. It intentionally stops before NavigationServer,
## route, NPC, or headed gameplay work.
func actual_packet_tile_receipt(retain_owner := false, tile: Vector2i = ACTUAL_PACKET_TILE, group_ids: Array[String] = ACTUAL_PACKET_TILE_GROUPS, background_group_id := "") -> Dictionary:
	var source := load_actual()
	var report := {"fixtureSha256":SHA,"tileKey":"%d,%d" % [tile.x,tile.y],
		"groupIds":group_ids.duplicate(),"trace":[],"scope":"actual frozen source packet receipt followed by exact tile producer receipt; no NavigationServer or gameplay"}
	if source.is_empty() or not source.is_read_only():
		report.reason="fixture_not_frozen"
		return report
	var value := owner()
	var s = value.structure_system
	var admission = s.citadel_terrain_admission
	var service = s.citadel_publication
	var parent := Node3D.new()
	var trees := PacketTrees.new()
	value.add_child(parent)
	inject(admission,REGION,source)
	source={}
	var binding: Dictionary = admission.source_state(REGION).binding
	if not service.configure_scene_publication(parent,trees.publish,trees.retire) \
		or not service.set_retained_source_requests([retained_packet_tile_request(binding,group_ids,tile)]):
		report.reason="service_admission_rejected"
		await close(value,"actual_packet_tile")
		return report
	var physical := {}
	var navigation := {}
	var priority_probe := {"requested":background_group_id,"submitted":background_group_id.is_empty(),"retained":false,"p0":false,"p2":false}
	var deadline := Time.get_ticks_msec()+120000
	while Time.get_ticks_msec()<deadline:
		var entry: Dictionary = service._scenes.get(REGION,{})
		var job = entry.get("job",null)
		if job!=null:
			# Submit one known deferred source group while the exact tile's physical
			# closure is still pending. This uses the real service demand path and
			# verifies that a retained background tile stays priority 2 rather than
			# silently joining the startup packet at priority 0.
			if not priority_probe.submitted:
				priority_probe.submitted = true
				service._packet_navigation_physical_ready(REGION,binding,[background_group_id],2)
			physical={}
			for group_id: String in group_ids:
				physical[group_id]=job.physical_group_receipt(group_id,binding)
			var demand: Dictionary = entry.get("packetDemandStatus",{})
			for request: Dictionary in demand.get("requests",[]):
				if request.get("groupIds",[]).has(background_group_id):
					priority_probe.retained = int(request.get("priority",-1))==2
				if request.get("groupIds",[]).has(group_ids[0]):
					priority_probe.p0 = int(request.get("priority",-1))==0
			priority_probe.p2 = not demand.get("foregroundGroupIds",[]).has(background_group_id)
			if physical.values().all(func(receipt): return receipt.get("status")=="ready"):
				navigation=service.navigation_tile_sources(tile)
		var state := {"inflight":String(service._inflight.get("kind","")),"phase":String(job.status_count().get("phase","") if job!=null else ""),
			"physicalReady":physical.values().filter(func(receipt): return receipt.get("status")=="ready").size(),"navigation":String(navigation.get("status","")),
			"navigationReason":String(navigation.get("reason",""))}
		if report.trace.is_empty() or report.trace.back()!=state: report.trace.append(state)
		if navigation.get("status") in ["ready","failed"]: break
		s.advance_citadel_publication(Rect2i(),true)
		await process_frame
	report.binding=binding.duplicate()
	report.physicalReceipts=physical.duplicate(true)
	report.navigation=navigation.duplicate(true)
	report.priorityProbe=priority_probe.duplicate(true)
	report.ready=physical.size()==group_ids.size() and physical.values().all(func(receipt): return receipt.get("status")=="ready") \
		and navigation.get("status")=="ready" and navigation.get("sources",[]).size()==1 and navigation.sources[0].get("binding")==binding \
		and (background_group_id.is_empty() or (priority_probe.retained and priority_probe.p0 and priority_probe.p2))
	report.stats=service.stats()
	if retain_owner:
		# The acknowledgement contract continues with this exact frozen source.
		# It is responsible for calling close after it has released navigation work.
		report.owner=value
	else:
		await close(value,"actual_packet_tile")
	return report

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
	# The fixture invokes the child without Main's ordinary frame-token setup.
	value.startup_loading_active = true
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
	# This fixture calls the terrain child directly rather than through Main's
	# normal frame setup, so use the production explicit-loading lifecycle.
	value.startup_loading_active = true
	runtime._process(0.016)
	var player_cell := Vector2i(floori(value.player.global_position.x/Runtime.CELL),floori(value.player.global_position.z/Runtime.CELL))
	var expected := Rect2i(player_cell-Vector2i(2,2),Vector2i(5,5))
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

func shared_gameplay_budget() -> void:
	var value := owner()
	var structures: ObservedStructures = value.structure_system
	var observer := bounds()
	var before := structures.advance_calls
	value.advance_citadel_publication_shared(observer,true)
	check("shared_budget_rejects_call_without_frame_claim",structures.advance_calls==before)
	value.gameplay_publication_frame_token = Engine.get_process_frames()
	value.gameplay_publication_frame_started_usec = Time.get_ticks_usec()
	value.gameplay_publication_lane = 2
	value.gameplay_publication_deadline_usec = value.gameplay_publication_frame_started_usec+6000
	value.advance_citadel_publication_shared(observer,true)
	var after_first := structures.advance_calls
	value.advance_citadel_publication_shared(observer,true)
	check("shared_budget_allows_only_one_citadel_claim_per_frame",after_first==before+1 and structures.advance_calls==after_first)
	check("shared_budget_caps_citadel_grant_at_four_milliseconds",
		structures.last_budget_usec>0 and structures.last_budget_usec<=Structures.CITADEL_PUBLICATION_BUDGET_USEC)
	await close(value,"shared_gameplay_budget")

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

func early_description_lifecycle() -> void:
	# Real worker transfer with a synthetic phase barrier, not gameplay evidence.
	for cancel_after_transfer: bool in [false,true]:
		var value: Owner = owner()
		var service = value.structure_system.citadel_publication
		var admission = value.structure_system.citadel_terrain_admission
		inject(admission,REGION,tiny(REGION))
		var worker := DescriptionGatedWorker.new()
		service._worker = worker
		var deadline: int = Time.get_ticks_msec()+10000
		while service._described.is_empty() and Time.get_ticks_msec()<deadline:
			value.structure_system.advance_citadel_publication(bounds(),true)
			await process_frame
		var prefix: String = "early_description_cancel" if cancel_after_transfer else "early_description_complete"
		var serial := -1
		check(prefix+"_arrives_before_final_preparation",service._described.has(REGION) and service.stats().acceptedCount==0 and worker.poll().workerRunning)
		if service._described.has(REGION):
			var source: Dictionary = admission.source_state(REGION)
			var entry: Dictionary = service._described[REGION]
			check(prefix+"_source_identity",entry.binding==source.binding and entry.description.binding==source.binding and entry.profile.origin==entry.description.origin)
			var obligations: Dictionary = service._source_description_requirements(REGION,bounds(),source.binding)
			check(prefix+"_obligations_are_not_receipt",obligations.get("status")=="described" and obligations.get("publicationAcknowledged")==false and not obligations.has("physicalOwnerAcknowledgements"))
			serial = int(entry.serial)
			value.structure_system.advance_citadel_publication(bounds(),true)
			check(prefix+"_transfer_not_duplicated",service._described[REGION].serial==serial)
		if cancel_after_transfer:
			service._prune_unwanted({})
			check(prefix+"_departure_revokes_description",service._described.is_empty() and service._inflight.is_empty())
		worker.gate.post() # Always release, including a failed assertion/deadline.
		if not cancel_after_transfer:
			await wait_prepared(value.structure_system,1,REGION,prefix+"_final_result_accepted")
			var completed_description = service._prepared.get(REGION,{}).get("prepared",null)
			completed_description = completed_description.describe(admission.source_state(REGION).binding) if completed_description!=null else null
			check(prefix+"_description_promotes_completed_representation",service._described.has(REGION) \
				and service._described[REGION].description==completed_description and service._described[REGION].serial==serial)
		await close(value,prefix)

func actual_early_description_promotion() -> void:
	# The two descriptions are independently restored from the actual frozen
	# source, matching bootstrap->legacy promotion rather than the shared-object
	# compact/dense sibling control above.
	var source := load_actual()
	check("actual_early_promotion_fixture_frozen",not source.is_empty() and source.is_read_only())
	if source.is_empty(): return
	# The archived fixture was captured for demanded navigation.  The headed
	# regression is the ordinary legacy branch, where dense navigation is built
	# after the early compact transfer. Preserve every frozen source value while
	# selecting that production branch explicitly.
	source = source.duplicate(true)
	source["demandedNavigation"] = false
	WorkerControls.freeze(source)
	var value: Owner = owner()
	var service = value.structure_system.citadel_publication
	var admission = value.structure_system.citadel_terrain_admission
	inject(admission,REGION,source)
	var worker := DescriptionGatedWorker.new()
	service._worker = worker
	var deadline := Time.get_ticks_msec()+120000
	while service._described.is_empty() and Time.get_ticks_msec()<deadline:
		value.structure_system.advance_citadel_publication(bounds(),true)
		await process_frame
	check("actual_early_promotion_compact_arrived",service._described.has(REGION) and worker.poll().workerRunning)
	var early = service._described.get(REGION,{})
	var early_description = early.get("description")
	var early_serial := int(early.get("serial",-1))
	var binding: Dictionary = admission.source_state(REGION).binding
	var early_digest := String(early_description.source_identity_digest) if early_description!=null else ""
	worker.gate.post()
	await wait_prepared(value.structure_system,1,REGION,"actual_early_promotion_final_accepted")
	var final_description = service._prepared.get(REGION,{}).get("prepared",null)
	final_description = final_description.describe(binding) if final_description!=null else null
	var stored = service._described.get(REGION,{})
	check("actual_early_promotion_exact_provenance",early_description!=null and final_description!=null \
		and early_serial>0 and early_digest.length()==64 \
		and early_digest==String(final_description.source_identity_digest) \
		and stored.get("description")==final_description and stored.get("binding",{})==binding \
		and int(stored.get("serial",-1))==early_serial \
		and stored.get("profile",{}).get("sourceSignature","")==admission.source_state(REGION).sourceSignature \
		and service._failures.is_empty())
	# A ready scene must not redirect moving-bound scheduling into live physical
	# proof. Acceptance owns that work through physical_publication_state.
	var scheduling_probe := SchedulingJobProbe.new()
	service._scenes[REGION] = {"region":REGION,"binding":binding,"phase":"scene_ready","job":scheduling_probe}
	var scheduled: Dictionary = service.region_dependency_requirements(bounds())
	check("scene_present_scheduling_uses_immutable_description",scheduled.get("status")=="described" \
		and scheduling_probe.source_requirement_calls==0 and scheduled.get("physicalOwnerAcknowledgements",{}).is_empty())
	service._scenes.erase(REGION)
	metrics.actualEarlyPromotion={"binding":binding.duplicate(),"digest":early_digest,"sourceSha256":SHA,
		"scope":"actual frozen source, independent early compact and final dense descriptors"}
	await close(value,"actual_early_promotion")

func _run() -> void:
	view_ranked_rolling_windows()
	await early_description_lifecycle()
	await actual_early_description_promotion()
	await retained_demand()
	await actual_source()
	await actual_packet_demand()
	await controlled_lifecycle()
	await runtime_dispatch()
	await shared_gameplay_budget()
	await paused_and_failure()
	var report := {"schema":"citadel-publication-service-contract/v1","complete":true,"passed":not checks.values().has(false),
		"evidenceLevel":"historical_source_direct_service_and_synthetic_lifecycle","sourceSha256":SHA,"seed":SEED,
		"checks":checks,"metrics":metrics,"doesNotProve":"No fresh recipe generation, scene parts, trees, doors, normal Main/New Game approach, visuals, save/Continue or gameplay/frame-budget acceptance."}
	var file := FileAccess.open(OS.get_environment("CITADEL_PUBLICATION_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("PUBLICATION SERVICE COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size()}))
	quit(0 if report.passed else 1)

func view_ranked_rolling_windows() -> void:
	# Pure scheduling coverage for a city larger than one physical packet window.
	# Geometry and receipts remain covered by the actual frozen-source cases.
	var groups: Dictionary = {}
	for index: int in range(300):
		var id := "synthetic-group-%03d" % index
		var dependencies: Array = ["synthetic-group-299"] if index==5 else []
		groups[id]={"bounds":AABB(Vector3(float(index%12)*4.0-22.0,0.0,-10.0-float(index/12)*3.0),Vector3(3,3,3)),
			"doorPartIds":["gate-door"] if index==5 else [],"dependencies":dependencies}
	var description := {"publication_groups":{"groups":groups}}
	var view := {"origin":Vector3.ZERO,"forward":Vector3(0,0,-1),"predictedOrigin":Vector3(0,0,-20),
		"horizontalFovDegrees":90.0,"farDistance":180.0}
	var service := Service.new()
	var first: Dictionary = service._bounded_packet_view_window(description,null,{},[{"viewIntent":view}],[],{})
	var safety: Dictionary = service._bounded_packet_view_window(description,null,{},[{"viewIntent":view}],
		[{"ownerId":"spatial-safety","groupIds":["synthetic-group-005"],"priority":0}],{})
	var completed: Dictionary = {}
	for id: String in first.get("foregroundGroupIds",[]): completed[id]=true
	var second: Dictionary = service._bounded_packet_view_window(description,null,{},[{"viewIntent":view}],[],completed)
	var union := completed.duplicate()
	for id: String in second.get("foregroundGroupIds",[]): union[id]=true
	check("view_window_caps_city_publication_without_full_source_fallback",first.get("status")=="ready"
		and first.get("foregroundGroupIds",[]).size()==Service.VIEW_WINDOW_PROGRESS_TARGET_GROUPS
		and first.get("deferredGroupIds",[]).size()==76)
	check("view_window_promotes_gate_and_dependency_complete_lookthrough",first.get("portalGroupIds",[]).has("synthetic-group-005")
		and first.get("foregroundGroupIds",[]).has("synthetic-group-005")
		and first.get("foregroundGroupIds",[]).has("synthetic-group-299"))
	check("view_window_keeps_spatial_readiness_smaller_than_background_window",
		safety.get("readinessGroupIds",[])==["synthetic-group-005","synthetic-group-299"]
		and safety.get("foregroundGroupIds",[]).size()==Service.VIEW_WINDOW_PROGRESS_TARGET_GROUPS)
	check("completed_window_promotes_all_remaining_city_groups",second.get("status")=="ready"
		and second.get("foregroundGroupIds",[]).size()==76 and second.get("deferredGroupIds",[]).is_empty()
		and union.size()==groups.size())
	metrics.viewRankedRollingWindows={"firstCount":first.get("foregroundGroupIds",[]).size(),
		"secondCount":second.get("foregroundGroupIds",[]).size(),"firstPortalGroups":first.get("portalGroupIds",[])}
