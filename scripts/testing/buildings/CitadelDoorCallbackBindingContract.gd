extends SceneTree
## Independent synthetic service callback-binding controls. Ownership markers
## isolate configuration guards; they do not simulate worker disposal proof.
## The tiny integration uses the real worker/preparation and scene job, with an
## empty blueprint. It proves pair capture, NOT door registration or gameplay.
const Service = preload("res://scripts/world/CitadelPublicationService.gd")
const WorkerControls = preload("res://scripts/testing/buildings/BuildingPublicationWorkerContract.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Smart = preload("res://scripts/npc_ai/interactions/SmartObjectService.gd")
const Portals = preload("res://scripts/npc_ai/interactions/DoorPortalService.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const REGION := Vector2i(1,-3)
const BINDING := {"siteId":"synthetic-site","sourceKey":"synthetic-source","generation":1}

class SyntheticAdmission extends RefCounted:
	var world_seed := "synthetic-world"
	var receipt: Dictionary = {}
	func stats() -> Dictionary:
		return {"generation":1,"worldSeed":world_seed}
	func source_state(_region: Vector2i) -> Dictionary:
		if not receipt.is_empty(): return receipt
		return {"status":"ready","binding":{"siteId":"synthetic-site","sourceKey":"synthetic-source","generation":1}}

class Callbacks extends RefCounted:
	var registered := 0
	var unregistered := 0
	func register_door(_body: Node) -> Dictionary:
		registered+=1
		return {"status":"registered","portalId":"synthetic-door"}
	func unregister_door(_body: Node) -> Dictionary:
		unregistered+=1
		return {"status":"absent","portalId":"synthetic-door"}
	func tree_publish(_parent: Node3D, _id: String, _position: Vector3, _biome: String, _request: Dictionary, _yaw: float) -> Dictionary:
		return {"status":"skipped","reason":"durable_harvest"}
	func tree_retire(_id: String, _body: StaticBody3D) -> void: pass

class ReentrantDoorOwner extends Node3D:
	var smart = Smart.new()
	var portals = Portals.new()
	var door_traversal = null
	var traffic_reservations = null
	var service: WeakRef
	var admission: WeakRef
	var mode := "reset"
	var registrations := 0
	var retirements := 0
	var children_before: Array = []
	var collision_count := 0
	var intact_after_reset := false
	var intact_before_retire := false
	var callback_retired_entry := false
	var callback_no_ready := false
	var observations: Dictionary = {}
	var trace: Array = []
	func setup() -> void:
		portals.setup(null,self)
		smart.setup(self,portals)
	func emit_door_state_revision(_leaf: Node, _open: bool, _reason: String, _revision: int) -> void: pass
	static func child_ids(node: Node) -> Array:
		var ids: Array=[]
		for child in node.get_children(true):
			ids.append(child.get_instance_id())
			ids.append_array(child_ids(child))
		return ids
	static func collision_children(node: Node) -> int:
		var count := 0
		for child in node.get_children(true):
			if child is CollisionShape3D: count+=1
			count+=collision_children(child)
		return count
	func register_door(body: Node) -> Dictionary:
		registrations+=1
		children_before=child_ids(body)
		collision_count=collision_children(body)
		var target = service.get_ref()
		var job = target._scenes[Vector2i(1,-3)].job
		observations={"job":weakref(job),"root":weakref(job.own_node_root()),"body":weakref(body),
			"publisher":weakref(job._building),"mesh":weakref(job._building.unit_box)}
		var portal_id: String=smart.register_door(body)
		trace.append(["shared_register",portal_id,body.get_instance_id()])
		if mode=="reset": target.configure(admission.get_ref())
		else: target.request_shutdown()
		intact_after_reset=is_instance_valid(body) and body.is_inside_tree() and children_before==child_ids(body)
		callback_retired_entry=not target._scenes.has(Vector2i(1,-3)) and target._retiring_scenes.size()==1 and job.status_count().phase=="teardown"
		callback_no_ready=target.stats().sceneCompletedCount==0 and not target.scene_state(Vector2i(1,-3)).gameplayReady
		trace.append(["reentrant_"+mode,callback_retired_entry,intact_after_reset])
		return {"status":"registered","portalId":portal_id}
	func unregister_door(body: Node) -> Dictionary:
		retirements+=1
		intact_before_retire=is_instance_valid(body) and body.is_inside_tree() and children_before==child_ids(body) and collision_children(body)==collision_count
		var receipt: Dictionary=smart.unregister_door(body)
		trace.append(["shared_unregister",receipt.get("status"),intact_before_retire])
		return receipt
	func close_services() -> void:
		smart.clear()
		smart.owner=null; smart.door_portals=null
		portals.owner=null; portals.main=null

var checks: Dictionary = {}
var metrics: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func check(label: String, passed: bool) -> void:
	checks[label]=passed
	if not passed: print("DOOR BINDING FAILURE ",label)

func fixture() -> Dictionary:
	var service := Service.new()
	var admission := SyntheticAdmission.new()
	service.configure(admission)
	var parent := Node3D.new()
	root.add_child(parent)
	var trees := Callbacks.new()
	check("fixture_%d_tree_configuration" % parent.get_instance_id(),service.configure_scene_publication(parent,trees.tree_publish,trees.tree_retire))
	return {"service":service,"admission":admission,"parent":parent,"trees":trees}

func same_pair(service, register_owner, unregister_owner) -> bool:
	return service._door_receiver!=null and service._door_retire_receiver!=null \
		and is_same(service._door_receiver.get_ref(),register_owner) and service._door_method==&"register_door" \
		and is_same(service._door_retire_receiver.get_ref(),unregister_owner) and service._door_retire_method==&"unregister_door"

func configuration_controls() -> void:
	var c := fixture()
	var s = c.service
	var first := Callbacks.new()
	var second := Callbacks.new()
	check("optional_explicit_unconfigured",not s.stats().doorLifecycleConfigured and not s.stats().doorLifecycleAvailable)
	check("optional_diagnostics_unchanged",s._scene_callbacks_ready() and s.stats().constructionStatus=="available")
	check("optional_no_gameplay_claim",not s.stats().publicationReady and not s.scene_state(REGION).gameplayReady)
	check("reject_empty_pair",not s.configure_door_publication(Callable(),Callable()))
	check("reject_missing_unregister",not s.configure_door_publication(first.register_door,Callable()))
	check("reject_missing_register",not s.configure_door_publication(Callable(),first.unregister_door))
	check("reject_custom_register",not s.configure_door_publication(func(_body): return {},first.unregister_door))
	check("reject_custom_unregister",not s.configure_door_publication(first.register_door,func(_body): return {}))
	check("reject_bound_register",not s.configure_door_publication(first.register_door.bind(null),first.unregister_door))
	check("reject_bound_unregister",not s.configure_door_publication(first.register_door,first.unregister_door.bind(null)))
	check("reject_self_register",not s.configure_door_publication(Callable(s,"stats"),first.unregister_door))
	check("reject_self_unregister",not s.configure_door_publication(first.register_door,Callable(s,"stats")))
	check("invalid_pairs_leave_no_partial_configuration",not s.stats().doorLifecycleConfigured and s._door_receiver==null and s._door_retire_receiver==null)
	check("valid_pair",s.configure_door_publication(first.register_door,first.unregister_door))
	check("configured_and_available",s.stats().doorLifecycleConfigured and s.stats().doorLifecycleAvailable and s._scene_callbacks_ready())
	check("same_pair_idle",s.configure_door_publication(first.register_door,first.unregister_door))
	check("cannot_disable",not s.configure_door_publication(Callable(),Callable()) and same_pair(s,first,first))
	for mode: String in ["publishing","scene_ready","paused_root_missing","retiring_nodes","pending_disposal","submitted_disposal"]:
		# Deliberately synthetic ownership markers, never advanced as scene jobs.
		match mode:
			"publishing","scene_ready","paused_root_missing": s._scenes[REGION]={"phase":"scene_ready" if mode=="scene_ready" else "publishing"}
			"retiring_nodes": s._retiring_scenes.append({"region":REGION})
			"pending_disposal": s._pending_scene_disposals[1]=REGION
			"submitted_disposal": s._submitted_scene_disposals[1]=REGION
		check(mode+"_same_pair_idempotent",s.configure_door_publication(first.register_door,first.unregister_door))
		check(mode+"_reject_pair_replacement",not s.configure_door_publication(second.register_door,second.unregister_door))
		check(mode+"_reject_register_only_change",not s.configure_door_publication(second.register_door,first.unregister_door))
		check(mode+"_reject_unregister_only_change",not s.configure_door_publication(first.register_door,second.unregister_door))
		check(mode+"_pair_preserved",same_pair(s,first,first))
		s._scenes.clear(); s._retiring_scenes.clear()
		s._pending_scene_disposals.clear(); s._submitted_scene_disposals.clear()
	check("replacement_after_all_ownership_gone",s.configure_door_publication(second.register_door,second.unregister_door) and same_pair(s,second,second))
	check("configuration_calls_no_callbacks",first.registered==0 and first.unregistered==0 and second.registered==0 and second.unregistered==0)
	s.request_shutdown()
	check("closing_rejects_configuration",not s.configure_door_publication(first.register_door,first.unregister_door))
	check("marker_fixture_no_worker_started",s._worker.poll().shutdownComplete)
	c.parent.free()

func bind_ephemeral_receiver(service, which: String) -> Dictionary:
	# Return from this frame before checking lifetime. A conditional argument to
	# weakref can leave the chosen strong Variant temporary alive at the check.
	var register_owner := Callbacks.new()
	var unregister_owner := Callbacks.new()
	var accepted: bool=service.configure_door_publication(register_owner.register_door,unregister_owner.unregister_door)
	if which=="register": return {"accepted":accepted,"weak":weakref(register_owner),"survivor":unregister_owner}
	return {"accepted":accepted,"weak":weakref(unregister_owner),"survivor":register_owner}

func receiver_loss_controls() -> void:
	for which: String in ["register","unregister"]:
		var c := fixture()
		var receivers := bind_ephemeral_receiver(c.service,which)
		check(which+"_separate_receivers_allowed",receivers.accepted)
		check(which+"_weak_owner_released",receivers.weak.get_ref()==null)
		check(which+"_loss_does_not_disable_opt_in",c.service.stats().doorLifecycleConfigured)
		check(which+"_loss_explicitly_unavailable",not c.service.stats().doorLifecycleAvailable)
		check(which+"_loss_no_diagnostic_fallback",not c.service._scene_callbacks_ready() and c.service.stats().constructionStatus=="pending" and c.service.stats().constructionReason=="scene_lifecycle_capability_missing")
		c.service.configure(c.admission)
		check(which+"_reset_does_not_restore_fallback",c.service.stats().doorLifecycleConfigured and not c.service._scene_callbacks_ready())
		c.service.request_shutdown()
		check(which+"_no_worker_started",c.service._worker.poll().shutdownComplete)
		c.parent.free()

func capture_observation(c: Dictionary, callbacks, configured: bool, label: String) -> Dictionary:
	# Synchronous inspection prevents coroutine receiver temporaries retaining jobs.
	var job = c.service._scenes[REGION].job
	check(label+"_real_job_before_publisher_begin",job.status_count().phase=="building_begin" and job.own_node_root()==null)
	if configured:
		check(label+"_captured_register",job._door_receiver!=null and is_same(job._door_receiver.get_ref(),callbacks) and job._door_method==&"register_door")
		check(label+"_captured_unregister",job._door_retire_receiver!=null and is_same(job._door_retire_receiver.get_ref(),callbacks) and job._door_retire_method==&"unregister_door")
	else:
		check(label+"_optional_job_pair_absent",job._door_receiver==null and job._door_retire_receiver==null)
	return {"job":weakref(job),"holder":weakref(job._cpu.prepared)}

func tiny_real_capture(configured: bool) -> void:
	var label := "configured_real" if configured else "optional_real"
	var c := fixture()
	var callbacks := Callbacks.new()
	if configured: check(label+"_bind",c.service.configure_door_publication(callbacks.register_door,callbacks.unregister_door))
	var receipt: Dictionary=c.service._worker.dispatch(WorkerControls.source(),BINDING)
	check(label+"_worker_queued",receipt.get("status") in ["queued","started"])
	var deadline := Time.get_ticks_msec()+6000
	var state: Dictionary=c.service._worker.poll()
	while state.completedToken==0 and Time.get_ticks_msec()<deadline:
		await process_frame
		state=c.service._worker.poll()
	check(label+"_worker_completed",state.completedToken==receipt.get("token",-1))
	var completion: Dictionary=c.service._worker.take_result(int(receipt.get("token",0)),BINDING)
	var prepared_ok: bool=completion.get("status")=="consumed" and completion.get("result",{}).get("ready",false)
	check(label+"_real_preparation_ready",prepared_ok)
	var observed: Dictionary={}
	if prepared_ok:
		c.service._prepared[REGION]={"binding":BINDING.duplicate(),"prepared":completion.result.prepared,"profile":completion.result.profile}
		completion={}
		check(label+"_start_scene",c.service._start_scene(REGION,c.admission.source_state(REGION)))
		if c.service._scenes.has(REGION):
			observed=capture_observation(c,callbacks,configured,label)
			check(label+"_holder_transferred_once",not c.service._prepared.has(REGION) and c.service.stats().sceneStartedCount==1)
			check(label+"_duplicate_start_rejected",not c.service._start_scene(REGION,c.admission.source_state(REGION)))
			var replacement := Callbacks.new()
			check(label+"_live_owner_rebind_rejected",not c.service.configure_door_publication(replacement.register_door,replacement.unregister_door))
			if configured:
				check(label+"_same_pair_live",c.service.configure_door_publication(callbacks.register_door,callbacks.unregister_door))
				var receiver: WeakRef = weakref(callbacks)
				callbacks=null
				check(label+"_job_does_not_retain_receiver",receiver.get_ref()==null)
				check(label+"_receiver_loss_blocks_readiness",not c.service._scene_callbacks_ready() and c.service.stats().doorLifecycleConfigured)
				c.service.advance(Rect2i(),false,1)
				check(label+"_receiver_loss_retires_on_drain",not c.service._scenes.has(REGION) and c.service.stats().retiringScenes>0)
			check(label+"_no_nodes_or_gameplay",c.parent.get_child_count()==0 and not c.service.scene_state(REGION).gameplayReady and not c.service.stats().publicationReady)
	else:
		if not completion.is_empty(): c.service._worker.retire_external_payload(completion)
		completion={}
	c.service.request_shutdown()
	deadline=Time.get_ticks_msec()+6000
	while Time.get_ticks_msec()<deadline:
		c.service.advance(Rect2i(),false,2500)
		if c.service.stats().shutdownComplete: break
		await process_frame
	check(label+"_shutdown_complete",c.service.stats().shutdownComplete)
	for key: String in observed:
		check(label+"_"+key+"_retired",observed[key].get_ref()==null)
	check(label+"_parent_empty",c.parent.get_child_count()==0)
	metrics[label]=c.service.stats()
	c.parent.free()

func setup_reentrant_scene(c: Dictionary, mode: String) -> ReentrantDoorOwner:
	var host := ReentrantDoorOwner.new()
	root.add_child(host)
	host.setup()
	host.mode=mode
	host.service=weakref(c.service); host.admission=weakref(c.admission)
	c.admission.world_seed="atlas-1492"
	var candidate: Dictionary=Field.candidate_for_region("atlas-1492",REGION)
	c.admission.receipt={"status":"prepared","binding":BINDING.duplicate(),"reservationCells":Rect2i(candidate.centerCell,Vector2i.ONE)}
	c.service.configure(c.admission)
	check(mode+"_reentrant_pair_bound",c.service.configure_door_publication(host.register_door,host.unregister_door))
	var profile: Dictionary=WorkerControls.profile()
	profile.worldSeed="atlas-1492"
	WorkerControls.freeze(profile)
	var blueprint := Blueprint.new("synthetic-reentrant-service-doors",1,"timber")
	for index in range(2):
		blueprint.add_part({"id":"door-"+str(index),"kind":"door","material":"timber",
			"size":Vector3(0.7,1.8,0.12),"position":Vector3(index*1.1,0.9,0)})
	# Explicit synthetic proof receipts, not physical/admission-source acceptance.
	# The real publisher, scene job, SmartObject and Portal paths run below.
	var holder := Preparation.PreparedSource.new()
	holder._binding=BINDING.duplicate()
	holder._payload={"blueprint":blueprint,"furnishingPlan":Plan.new("tiny-reentrant-furniture",1,blueprint.id),
		"physicalIntegrity":{"passed":true},"raisedRouteCoverage":{"passed":true},
		"preparationUsec":0,"routeUsec":0,"physicalUsec":0}
	c.service._prepared[REGION]={"binding":BINDING.duplicate(),"prepared":holder,"profile":profile}
	return host

func all_weak_released(observed: Dictionary) -> bool:
	for ref: WeakRef in observed.values():
		if ref.get_ref()!=null: return false
	return true

func pending_payload_retains_publisher(c: Dictionary, host: ReentrantDoorOwner) -> bool:
	return not c.service._pending_scene_disposals.is_empty() and host.observations.has("publisher") \
		and host.observations.publisher.get_ref()!=null and c.parent.get_child_count()==0

func reentrant_registration(mode: String) -> void:
	var c := fixture()
	var host := setup_reentrant_scene(c,mode)
	var footprint: Rect2i=c.admission.receipt.reservationCells
	var deadline := Time.get_ticks_msec()+6000
	while host.registrations==0 and Time.get_ticks_msec()<deadline:
		c.service.advance(footprint,true,1)
		await process_frame
	check(mode+"_real_shared_registration_once",host.registrations==1)
	check(mode+"_callback_has_real_collider_children",host.collision_count>0 and not host.children_before.is_empty())
	check(mode+"_callback_children_intact_after_invalidation",host.intact_after_reset)
	check(mode+"_callback_moved_entry_to_retirement",host.callback_retired_entry)
	check(mode+"_callback_no_ready_resurrection",host.callback_no_ready and not c.service._scenes.has(REGION) and c.service.stats().sceneCompletedCount==0)
	var payload_seen := false
	deadline=Time.get_ticks_msec()+6000
	while Time.get_ticks_msec()<deadline:
		payload_seen=payload_seen or pending_payload_retains_publisher(c,host)
		c.service.advance(Rect2i(),false,1)
		payload_seen=payload_seen or pending_payload_retains_publisher(c,host)
		if not host.observations.is_empty() and all_weak_released(host.observations) and c.service.stats().retiringScenes==0: break
		await process_frame
	check(mode+"_no_later_registration",host.registrations==1)
	check(mode+"_shared_unregister_once",host.retirements==1)
	check(mode+"_unregister_before_child_cleanup",host.intact_before_retire)
	check(mode+"_shared_registries_empty",host.smart.registrations.is_empty() and host.portals.portals.is_empty() and host.portals.controllers.is_empty() and host.portals.door_to_portal.is_empty())
	check(mode+"_nodes_gone_payload_still_owned",payload_seen)
	check(mode+"_worker_released_job_publisher_resources",not host.observations.is_empty() and all_weak_released(host.observations))
	var worker_state: Dictionary=c.service.stats().worker
	check(mode+"_disposal_off_main",int(worker_state.get("lastRetirementThreadId",-1))>=0 and int(worker_state.get("lastRetirementThreadId",-1))!=OS.get_thread_caller_id())
	check(mode+"_no_scene_or_completion_resurrection",c.service._scenes.is_empty() and c.service.stats().sceneStartedCount==1 and c.service.stats().sceneCompletedCount==0 and c.service.stats().constructedScenes==0 and c.service.stats().retiringScenes==0)
	check(mode+"_no_gameplay_or_failure_reinserted",not c.service.stats().publicationReady and not c.service.scene_state(REGION).gameplayReady and c.service._failures.is_empty())
	c.service.request_shutdown()
	deadline=Time.get_ticks_msec()+6000
	while Time.get_ticks_msec()<deadline:
		c.service.advance(Rect2i(),false)
		if c.service.stats().shutdownComplete: break
		await process_frame
	check(mode+"_reentrant_shutdown_complete",c.service.stats().shutdownComplete and c.parent.get_child_count()==0)
	metrics[mode+"_reentrant"]={"service":c.service.stats(),"trace":host.trace,"nodesGonePayloadOwned":payload_seen}
	host.close_services()
	host.free()
	c.parent.free()

func _run() -> void:
	var started := Time.get_ticks_msec()
	configuration_controls()
	receiver_loss_controls()
	await tiny_real_capture(false)
	await tiny_real_capture(true)
	await reentrant_registration("reset")
	await reentrant_registration("shutdown")
	var failures: Array=[]
	for label: String in checks:
		if not checks[label]: failures.append(label)
	var hashes: Dictionary={}
	for path: String in ["scripts/world/CitadelPublicationService.gd","scripts/buildings/BuildingScenePublicationJob.gd","scripts/buildings/BuildingPartPublisher.gd","scripts/buildings/BuildingPublicationWorker.gd","scripts/buildings/BuildingPublicationPreparation.gd","scripts/npc_ai/interactions/SmartObjectService.gd","scripts/npc_ai/interactions/DoorPortalService.gd","scripts/npc_ai/interactions/DoorPortal.gd","scripts/npc_ai/interactions/DoorController.gd","scripts/testing/buildings/BuildingPublicationWorkerContract.gd","scripts/testing/buildings/CitadelDoorCallbackBindingContract.gd"]:
		hashes[path]=FileAccess.get_sha256("res://"+path)
	var report := {"schema":"citadel-door-callback-binding/v1","complete":true,"passed":failures.is_empty(),"checkCount":checks.size(),"checks":checks,"failures":failures,"metrics":metrics,"sourceHashes":hashes,"elapsedMsec":Time.get_ticks_msec()-started,
		"evidenceLevel":"Independent synthetic service binding and ownership markers; real worker empty preparation/job capture; real service/publisher/SmartObject/Portal reentrant registration and worker retirement using tiny synthetic proof receipts",
		"doesNotProve":"No Source rebuild, physical/source-admission acceptance for synthetic door receipts, actual disposal-marker fence timing, rendered scene, actors, navigation, player readiness or headed gameplay. Empty jobs cancel before publisher begin; two-door jobs cancel after the first real shared registration."}
	var output := OS.get_environment("CITADEL_DOOR_CALLBACK_BINDING_OUTPUT")
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null:
		push_error("Cannot write CITADEL_DOOR_CALLBACK_BINDING_OUTPUT: "+output)
		quit(1)
		return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("DOOR BINDING COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size(),"failures":failures}))
	quit(0 if report.passed else 1)
