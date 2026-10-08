extends "res://scripts/testing/buildings/CitadelPublicationServiceContract.gd"
## Synthetic service-owned scene lifecycle. Reuses setup/injection helpers only;
## the inherited actual-source campaign is NOT run. Real worker, admission,
## scene job and publishers; synthetic tiny input/tree visual acknowledgements.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")

class RetirementGate extends Worker:
	# Actual worker/thread/RetirementState disposal; only its start is held.
	# No source/scene payload is copied or released by this test adapter.
	var gate_next_retirement := true
	var entered := Semaphore.new()
	var release := Semaphore.new()
	func _start_thread(work: Callable) -> int:
		if _active.get("kind")=="retirement" and gate_next_retirement:
			gate_next_retirement=false
			return super._start_thread(_gated_release.bind(work))
		return super._start_thread(work)
	func _gated_release(work: Callable) -> int:
		entered.post()
		release.wait()
		return int(work.call())

class Trees extends RefCounted:
	var calls := 0
	var retired := 0
	var balanced := true
	var ids := {}
	var bodies: Array[WeakRef] = []
	var action := ""
	var target: WeakRef
	var admission: WeakRef
	var callback_status := ""
	var callback_calls := 0
	func tree_publication_proof(body: Variant, include_installed := true) -> Dictionary:
		if not is_instance_valid(body): return {"status":"failed", "reason":"synthetic_tree_owner_lost"}
		var ready := body.get_meta("tree_visual_state", "") == "published" \
			and body.get_node_or_null("GeneratedTreeVisual") != null
		return {"status":"ready" if ready else "pending", "bodyInstanceId":body.get_instance_id(),
			"sourcePrepared":ready, "installed":ready and include_installed}
	func tree_source_is_durably_removed(_prop_id: String) -> bool: return false
	func publish(parent: Node3D, id: String, position: Vector3, _biome: String, request: Dictionary, yaw: float) -> Dictionary:
		calls += 1
		var body := StaticBody3D.new()
		body.position = position
		body.rotation.y = yaw
		body.set_meta("prop_id",id)
		parent.add_child(body)
		body.set_meta("tree_visual_state","queued")
		if not request.get("syntheticHold",false): complete(body)
		bodies.append(weakref(body))
		if not action.is_empty():
			callback_calls+=1
			match action:
				"reset": target.get_ref().configure(admission.get_ref())
				"shutdown": target.get_ref().request_shutdown()
				"reenter": callback_status=String(target.get_ref().advance().get("reason",""))
		return {"status":"published","reason":"visual_queued","body":body}
	func complete(body: Node3D) -> void:
		body.set_meta("tree_visual_state","published")
		if body.get_node_or_null("GeneratedTreeVisual")==null:
			var visual := Node3D.new()
			visual.name = "GeneratedTreeVisual"
			body.add_child(visual)
	func release_visuals() -> void:
		for ref: WeakRef in bodies:
			if is_instance_valid(ref.get_ref()): complete(ref.get_ref())
	func retire(id: String, body: StaticBody3D) -> void:
		balanced = balanced and is_instance_valid(body) and body.get_parent()!=null
		retired += 1
		ids[id] = int(ids.get(id,0))+1

var total_started := 0

func scene_source(region: Vector2i, hold := false, with_tree := true) -> Dictionary:
	var source: Dictionary = tiny(region).duplicate(true)
	var b := Blueprint.new("synthetic-scene-lifecycle",73,"castle")
	b.add_part({"id":"base","kind":"foundation","material":"stone_foundation","size":Vector3(2,0.4,2),"position":Vector3(0,0.2,0)})
	b.add_part({"id":"wall","kind":"wall","material":"fired_brick","size":Vector3(1.5,1,0.3),"position":Vector3(0,0.9,0)})
	b.add_part({"id":"roof","kind":"roof","material":"roof_slate","size":Vector3(2,0.12,2),"position":Vector3(0,1.46,0)})
	b.recipe["landscapeTrees"] = [{"id":"tree","position":Vector3(2,0,0),"rotationY":0.0,"treeRequest":{"biome":"town","syntheticHold":hold}}]
	if not with_tree: b.recipe["landscapeTrees"] = []
	var f := Plan.new("synthetic-scene-furniture",73,b.id)
	f.add_part({"id":"crate","archetype":"crate","position":Vector3(0.6,0.5,0.6)})
	source.blueprint = b.snapshot()
	source.furnishingPlan = f.snapshot()
	source.furnishingPlan["accessReservations"] = f.access_reservations_snapshot()
	WorkerControls.freeze(source)
	return source

func setup_scene(hold := false, with_tree := true) -> Dictionary:
	var value := owner()
	var a = value.structure_system.citadel_terrain_admission
	var service = value.structure_system.citadel_publication
	var trees := Trees.new()
	var parent := Node3D.new()
	value.add_child(parent)
	inject(a,REGION,scene_source(REGION,hold,with_tree))
	return {"owner":value,"admission":a,"service":service,"trees":trees,"parent":parent}

func bind_scene(c: Dictionary, label: String) -> void:
	check(label,c.service.configure_scene_publication(c.parent,c.trees.publish,c.trees.retire))

func wait_scene(c: Dictionary, region: Vector2i, wanted: String, label: String, footprint := Rect2i(), budget := 2500) -> void:
	if footprint==Rect2i(): footprint=bounds(region)
	var deadline := Time.get_ticks_msec()+6000
	var turns := 0
	while c.service.scene_state(region).status!=wanted and Time.get_ticks_msec()<deadline:
		c.service.advance(footprint,true,budget)
		turns+=1
		if turns%8==0: await process_frame
	check(label,c.service.scene_state(region).status==wanted)
	metrics[label] = {"turns":turns,"state":c.service.scene_state(region)}

func phase(c: Dictionary, region := REGION) -> String:
	if not c.service._scenes.has(region): return ""
	return String(c.service._scenes[region].job.status_count().phase)

func wait_phase(c: Dictionary, target: String, label: String) -> void:
	var deadline := Time.get_ticks_msec()+6000
	var turns := 0
	while phase(c)!=target and Time.get_ticks_msec()<deadline:
		c.service.advance(bounds(),true,1)
		turns+=1
		if turns%16==0: await process_frame
	check(label,phase(c)==target)

func observe(c: Dictionary, region := REGION) -> Dictionary:
	# NO strong receiver temporaries may cross an await in a test coroutine.
	# These synchronous observations return only WeakRefs and scalar snapshots.
	if not c.service._scenes.has(region): return {}
	var job = c.service._scenes[region].job
	var refs := {"job":weakref(job)}
	if job.own_node_root()!=null: refs.root=weakref(job.own_node_root())
	if job._building!=null:
		var publisher = job._building
		refs.publisher=weakref(publisher)
		refs.mesh=weakref(publisher.unit_box)
		for id in publisher.material_cache: refs["material:"+String(id)]=weakref(publisher.material_cache[id])
		if publisher._prepared_masonry_identity!=null: refs.masonry=weakref(publisher._prepared_masonry_identity)
	if job._furniture!=null: refs.furniture=weakref(job._furniture)
	return refs

func all_released(refs: Dictionary) -> bool:
	for ref: WeakRef in refs.values():
		if ref.get_ref()!=null: return false
	return true

func retained(ref: WeakRef) -> bool:
	return ref.get_ref()!=null

func watch_retirement(c: Dictionary, refs: Dictionary, label: String) -> void:
	var deadline := Time.get_ticks_msec()+6000
	while (not all_released(refs) or c.service.stats().retiringScenes>0 or c.service.stats().pendingRetirements>0 or c.service.stats().worker.get("busy",false)) and Time.get_ticks_msec()<deadline:
		c.service.advance(Rect2i(),false,2500)
		await process_frame
	check(label+"_refs_released",not refs.is_empty() and all_released(refs))
	check(label+"_scene_slots_empty",c.service.stats().retiringScenes==0 and c.service.stats().pendingRetirements==0)

func finish_case(c: Dictionary, label: String) -> void:
	var refs := observe(c)
	c.service.request_shutdown()
	c.admission.request_shutdown() # No real Source dispatch during this fixture.
	var deadline := Time.get_ticks_msec()+6000
	while Time.get_ticks_msec()<deadline:
		c.service.advance(Rect2i(),false)
		c.admission.advance()
		if c.service.stats().shutdownComplete and c.admission.stats().shutdownComplete: break
		await process_frame
	check(label+"_shutdown",c.service.stats().shutdownComplete and c.admission.stats().shutdownComplete)
	check(label+"_empty_parent",c.parent.get_child_count()==0)
	check(label+"_all_owned_roots_gone",c.service._scenes.is_empty() and c.service._retiring_scenes.is_empty() and c.service._prepared.is_empty())
	check(label+"_refs_released",all_released(refs))
	check(label+"_tree_balance",c.trees.balanced and c.trees.calls==c.trees.retired)
	check(label+"_no_gameplay_claim",not c.service.stats().publicationReady)
	metrics[label] = c.service.stats()
	c.owner.structure_system.main=null
	c.owner.structure_system=null
	c.owner.free()

func capability_and_eviction() -> void:
	var c := setup_scene(true)
	check("initial_absent",c.service.scene_state(REGION).status=="absent")
	check("budget_zero_rejected",c.service.advance(bounds(),true,0).get("reason")=="invalid_slice_budget")
	check("budget_over_rejected",c.service.advance(bounds(),true,4001).get("reason")=="invalid_slice_budget")
	await wait_prepared(c.owner.structure_system,1,REGION,"capability_prepared_without_scene")
	check("capability_denial",c.service.stats().constructionReason=="scene_lifecycle_capability_missing" and c.service.scene_state(REGION).status=="pending" and c.service.scene_root(REGION)==null and c.parent.get_child_count()==0 and not c.service.stats().publicationReady)
	check("custom_callback_refused",not c.service.configure_scene_publication(c.parent,func(): return {},c.trees.retire))
	bind_scene(c,"capability_configured")
	await wait_phase(c,"tree_visuals","pending_real_publishers_complete")
	check("pending_not_ready",c.service.scene_state(REGION).status=="publishing" and c.service.stats().constructedScenes==0)
	var refs := observe(c)
	check("real_resources_observed",refs.has("mesh") and refs.has("masonry") and refs.has("furniture"))
	var original_id: int = c.service.scene_root(REGION).get_instance_id()
	var profile_origin: Vector3 = c.service._scenes[REGION].profile.origin
	check("root_at_profile_origin",c.service.scene_root(REGION).global_transform.is_equal_approx(Transform3D(Basis.IDENTITY,profile_origin)))
	check("same_owner_idempotent",c.service.configure_scene_publication(c.parent,c.trees.publish,c.trees.retire))
	var other := Node3D.new()
	c.owner.add_child(other)
	check("different_live_owner_refused",not c.service.configure_scene_publication(other,c.trees.publish,c.trees.retire))
	evict(c.admission,REGION)
	for i in range(12): c.service.advance(bounds(),true,1)
	check("evicted_pending_not_rebuilt",c.admission.source_requests==0 and c.service.stats().dispatchCount==1 and c.service.stats().sceneStartedCount==1 and c.service.scene_root(REGION).get_instance_id()==original_id)
	var calls_before: int = c.trees.calls
	for i in range(8): c.service.advance(Rect2i(),false,4000)
	check("drain_only_pauses_valid_scene",c.service.scene_state(REGION).status=="publishing" and phase(c)=="tree_visuals" and c.trees.calls==calls_before)
	c.trees.release_visuals()
	await wait_scene(c,REGION,"scene_ready","scene_ready_after_visual_ack")
	for i in range(8): c.service.advance(bounds(),true)
	check("ready_not_gameplay",not c.service.scene_state(REGION).gameplayReady and c.service.scene_state(REGION).reason=="door_activation_pending")
	check("evicted_ready_deduplicated",c.admission.source_requests==0 and c.service.stats().sceneStartedCount==1 and c.service.stats().sceneCompletedCount==1 and c.service.scene_root(REGION).get_instance_id()==original_id)
	c.service.advance(Rect2i(),true,1)
	check("departure_invalidates_root_access",c.service.scene_state(REGION).status=="retiring" and c.service.scene_root(REGION)==null)
	check("retiring_rebind_refused",not c.service.configure_scene_publication(other,c.trees.publish,c.trees.retire))
	c.service.advance(bounds(),true,1)
	check("return_while_retiring_no_duplicate",c.service.stats().sceneStartedCount==1 and c.admission.source_requests==0)
	await watch_retirement(c,refs,"departure")
	check("rebind_after_retirement",c.service.configure_scene_publication(other,c.trees.publish,c.trees.retire))
	c.service.advance(bounds(),true,1)
	check("unowned_reentry_requests_source",c.admission.source_requests==1 and c.admission._requests.has(REGION))
	inject(c.admission,REGION,scene_source(REGION))
	await wait_scene(c,REGION,"scene_ready","reentry_new_scene")
	check("reentry_exactly_once_new_root",c.service.stats().sceneStartedCount==2 and c.service.stats().sceneCompletedCount==2 and c.service.scene_root(REGION).get_instance_id()!=original_id and c.service.scene_root(REGION).get_parent()==other)
	await finish_case(c,"eviction")

func reset_controls() -> void:
	for kind: String in ["same_seed","different_seed","stale_binding"]:
		var c := setup_scene(true)
		bind_scene(c,kind+"_configured")
		await wait_phase(c,"tree_visuals",kind+"_pending")
		var refs := observe(c)
		var old_generation: int = c.service.stats().generation
		if kind=="stale_binding":
			c.admission._decisions[REGION].sourceKey="synthetic-new-source-revision"
		else:
			c.admission.configure("another-synthetic-seed" if kind=="different_seed" else SEED,{},c.admission._policy)
			c.admission.finalize_town_inputs({})
		c.service.advance(Rect2i(),false,1)
		check(kind+"_invalidated_on_drain",c.service.scene_root(REGION)==null and c.service.stats().constructedScenes==0 and c.service.stats().sceneCompletedCount==0)
		if kind!="stale_binding": check(kind+"_generation_updated",c.service.stats().generation>old_generation)
		await watch_retirement(c,refs,kind)
		check(kind+"_no_late_tree_calls",c.trees.calls==1 and c.trees.retired==1)
		await finish_case(c,kind)

func late_worker_control() -> void:
	var c := setup_scene()
	var gated := GatedWorker.new()
	c.service._worker=gated
	bind_scene(c,"late_worker_configured")
	c.service.advance(bounds(),true)
	c.service.advance(bounds(),true)
	await wait_entered(gated,"late_worker_entered")
	c.admission.configure(SEED,{},c.admission._policy)
	c.admission.finalize_town_inputs({})
	c.service.advance(Rect2i(),false)
	gated.gated=false
	gated.gate.post()
	var deadline := Time.get_ticks_msec()+6000
	while Time.get_ticks_msec()<deadline:
		c.service.advance(Rect2i(),false)
		if not c.service.stats().worker.get("busy",true): break
		await process_frame
	check("late_worker_never_attaches",c.service.stats().acceptedCount==0 and c.service.stats().sceneStartedCount==0 and c.parent.get_child_count()==0 and c.service.stats().worker.get("completedToken",0)==0)
	await finish_case(c,"late_worker")

func root_controls() -> void:
	for mutation: String in ["moved","reparented","freed"]:
		# Externally destroying an entire tree subtree cannot prove before-free
		# callback balance. Keep that separate control tree-free, explicitly.
		var c := setup_scene(false,mutation!="freed")
		bind_scene(c,mutation+"_configured")
		await wait_scene(c,REGION,"scene_ready",mutation+"_ready")
		var refs := observe(c)
		mutate_root(c,mutation)
		c.service.advance(Rect2i(),false,1)
		check(mutation+"_not_ready",c.service.scene_state(REGION).status!="scene_ready" and c.service.scene_root(REGION)==null)
		await watch_retirement(c,refs,mutation)
		check(mutation+"_failure_not_absence",c.service.scene_state(REGION).status=="failed" and c.service.scene_state(REGION).reason=="constructed_scene_owner_lost")
		await finish_case(c,mutation)

func shutdown_controls() -> void:
	for target: String in ["building","tree_visuals","retiring"]:
		var c := setup_scene(true)
		bind_scene(c,"shutdown_"+target+"_configured")
		await wait_phase(c,"building" if target=="building" else "tree_visuals","shutdown_"+target+"_reached")
		var refs := observe(c)
		if target=="retiring": c.service.advance(Rect2i(),true,1)
		var calls_before: int = c.trees.calls
		await finish_case(c,"shutdown_"+target)
		check("shutdown_"+target+"_old_refs_gone",all_released(refs))
		check("shutdown_"+target+"_no_later_publish",c.trees.calls==calls_before)

func callback_controls() -> void:
	for action: String in ["reset","shutdown","reenter"]:
		var c := setup_scene()
		bind_scene(c,"callback_"+action+"_configured")
		c.trees.action=action
		c.trees.target=weakref(c.service)
		c.trees.admission=weakref(c.admission)
		var deadline := Time.get_ticks_msec()+6000
		while c.trees.callback_calls==0 and Time.get_ticks_msec()<deadline:
			c.service.advance(bounds(),true,2500)
			await process_frame
		check("callback_"+action+"_fired",c.trees.callback_calls==1)
		if action=="reenter":
			check("nested_advance_rejected",c.trees.callback_status=="reentrant_advance")
			await wait_scene(c,REGION,"scene_ready","nested_advance_outer_completes")
		else:
			check("callback_"+action+"_not_ready",c.service.scene_state(REGION).status!="scene_ready" and c.service.stats().sceneCompletedCount==0 and c.service.stats().sceneStartedCount==1)
		await finish_case(c,"callback_"+action)

func mutate_root(c: Dictionary, mutation: String) -> void:
	var site: Node3D=c.service.scene_root(REGION)
	match mutation:
		"moved": site.position.x+=1
		"reparented": site.reparent(c.owner)
		"freed": site.free() # Deliberate external destruction, not orderly cleanup.

func publishing_root_controls() -> void:
	for mutation: String in ["moved","reparented","freed","parent_moved"]:
		var c := setup_scene()
		bind_scene(c,"publishing_"+mutation+"_configured")
		await wait_phase(c,"building","publishing_"+mutation+"_reached")
		var refs := observe(c)
		check("publishing_"+mutation+"_root_exists",refs.has("root") and c.service.scene_state(REGION).status=="publishing")
		if mutation=="parent_moved": c.parent.position.x+=1
		else: mutate_root(c,mutation)
		var calls_before: int = c.trees.calls
		c.service.advance(Rect2i(),false,1)
		check("publishing_"+mutation+"_drain_invalidates",c.service.scene_root(REGION)==null and c.service.scene_state(REGION).status=="retiring")
		await watch_retirement(c,refs,"publishing_"+mutation)
		check("publishing_"+mutation+"_failure_explicit",c.service.scene_state(REGION).status=="failed" and c.service.scene_state(REGION).reason=="publication_scene_owner_lost")
		check("publishing_"+mutation+"_no_later_publication",c.service.stats().sceneCompletedCount==0 and c.trees.calls==calls_before)
		await finish_case(c,"publishing_"+mutation)
	# building_begin legitimately owns no root yet. Parent translation alone
	# must not invent a lost root; begin still places it at the profile origin.
	var c := setup_scene()
	bind_scene(c,"prebegin_parent_configured")
	await wait_phase(c,"building_begin","prebegin_root_not_created")
	c.parent.position=Vector3(3,0,7)
	c.service.advance(Rect2i(),false,1)
	check("prebegin_root_none_not_lost",phase(c)=="building_begin" and c.service.scene_state(REGION).status=="publishing" and c.service.scene_root(REGION)==null)
	await wait_scene(c,REGION,"scene_ready","prebegin_translated_parent_ready")
	check("prebegin_final_origin_exact",c.service.scene_root(REGION).global_transform.is_equal_approx(Transform3D(Basis.IDENTITY,c.service._scenes[REGION].profile.origin)))
	await finish_case(c,"prebegin_parent")

func disposal_claim_control() -> void:
	var c := setup_scene()
	var worker := RetirementGate.new()
	c.service._worker=worker
	bind_scene(c,"disposal_claim_configured")
	await wait_scene(c,REGION,"scene_ready","disposal_claim_scene_ready")
	var refs := observe(c)
	evict(c.admission,REGION)
	var other := Node3D.new()
	c.owner.add_child(other)
	c.service.advance(Rect2i(),true,1)
	var deadline := Time.get_ticks_msec()+6000
	while c.service._retired.is_empty() and Time.get_ticks_msec()<deadline:
		c.service.advance(Rect2i(),false,1)
		await process_frame
	check("disposal_staged_nodes_gone",c.service._retiring_scenes.is_empty() and c.parent.get_child_count()==0 and not c.service._retired.is_empty())
	check("disposal_staged_claim_retained",c.service.scene_state(REGION).status=="retiring" and not all_released(refs))
	check("disposal_staged_rebind_denied",not c.service.configure_scene_publication(other,c.trees.publish,c.trees.retire))
	# Re-entry here straddles the owner -> worker handoff. Source reconstruction
	# must remain blocked even though the node cleanup queue is already empty.
	c.service.advance(bounds(),true,1)
	var entered := worker.entered.try_wait()
	deadline=Time.get_ticks_msec()+6000
	while not entered and Time.get_ticks_msec()<deadline:
		c.service.advance(bounds(),true,1)
		await process_frame
		entered=worker.entered.try_wait()
	check("disposal_actual_worker_gated",entered and c.service.stats().worker.workerRunning and c.service.stats().worker.workerKind=="retirement")
	for i in range(8): c.service.advance(bounds(),true,2500)
	check("disposal_handoff_empty_node_and_payload_queues",c.service._retiring_scenes.is_empty() and c.service._retired.is_empty())
	check("disposal_running_region_retained",c.service.scene_state(REGION).status=="retiring" and c.service.scene_root(REGION)==null)
	check("disposal_running_no_reconstruction",c.admission.source_requests==0 and c.admission._requests.is_empty() and c.service.stats().dispatchCount==1 and c.service.stats().sceneStartedCount==1)
	check("disposal_running_rebind_denied",not c.service.configure_scene_publication(other,c.trees.publish,c.trees.retire))
	check("disposal_real_resources_still_owned",not all_released(refs) and retained(refs.publisher))
	worker.release.post() # Always release, including assertion failure paths.
	await watch_retirement(c,refs,"disposal_completed")
	check("disposal_worker_off_main",c.service.stats().worker.lastRetirementThreadId!=-1 and c.service.stats().worker.lastRetirementThreadId!=OS.get_thread_caller_id())
	check("disposal_claim_cleared_after_worker",c.service.scene_state(REGION).status!="retiring")
	check("disposal_completed_rebind_allowed",c.service.configure_scene_publication(other,c.trees.publish,c.trees.retire))
	c.service.advance(bounds(),true,1)
	check("disposal_completed_reconstruction_once",c.admission.source_requests==1 and c.admission._requests.has(REGION) and c.service.stats().sceneStartedCount==1)
	await finish_case(c,"disposal_claim")

func fairness_control() -> void:
	var other := REGION
	for z in range(REGION.y-1,REGION.y+2):
		for x in range(REGION.x-1,REGION.x+2):
			var candidate_region:=Vector2i(x,z)
			if candidate_region!=REGION and not Field.candidate_for_region(SEED,candidate_region).is_empty(): other=candidate_region
	check("fairness_second_candidate",other!=REGION)
	if other==REGION: return
	var c := setup_scene(true)
	bind_scene(c,"fairness_configured")
	await wait_phase(c,"tree_visuals","fairness_first_waiting")
	inject(c.admission,other,scene_source(other))
	var footprint := bounds().merge(bounds(other))
	await wait_scene(c,other,"scene_ready","fairness_second_finishes",footprint,2500)
	check("fairness_waiting_site_not_starving_other",phase(c)=="tree_visuals" and c.service.stats().sceneStartedCount==2 and c.service.stats().sceneCompletedCount==1)
	var refs := observe(c)
	c.service.advance(bounds(other),true,1)
	check("fairness_retirement_started",c.service.scene_state(REGION).status=="retiring")
	var deadline := Time.get_ticks_msec()+6000
	while not all_released(refs) and Time.get_ticks_msec()<deadline:
		c.service.advance(bounds(other),true,2500)
		await process_frame
	check("fairness_retirement_progresses_with_demand",all_released(refs) and c.service.scene_state(other).status=="scene_ready" and c.service.stats().sceneStartedCount==2)
	await finish_case(c,"fairness")

func _run() -> void:
	total_started=Time.get_ticks_msec()
	await capability_and_eviction()
	await reset_controls()
	await late_worker_control()
	await root_controls()
	await publishing_root_controls()
	await disposal_claim_control()
	await shutdown_controls()
	await callback_controls()
	await fairness_control()
	var failures: Array = []
	for label: String in checks:
		if not checks[label]: failures.append(label)
	var report := {"schema":"citadel-scene-lifecycle-contract/v1","complete":true,"passed":failures.is_empty(),"checkCount":checks.size(),"failureCount":failures.size(),"failures":failures,"checks":checks,"metrics":metrics,"elapsedMsec":Time.get_ticks_msec()-total_started,
		"evidenceLevel":"synthetic service-owned lifecycle; real admission/preparation/scene job/publishers, synthetic tree acknowledgements",
		"doesNotProve":"No live Source rebuild, ordinary activation, shared live trees, doors/NPCs, gameplay access, visuals/GPU, save or hard frame-budget acceptance.",
		"sources":{"contract":FileAccess.get_sha256(get_script().resource_path),"service":FileAccess.get_sha256("res://scripts/world/CitadelPublicationService.gd"),"job":FileAccess.get_sha256("res://scripts/buildings/BuildingScenePublicationJob.gd")}}
	var file := FileAccess.open(OS.get_environment("CITADEL_SCENE_LIFECYCLE_OUTPUT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("SCENE LIFECYCLE COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size(),"failures":failures,"elapsedMsec":report.elapsedMsec}))
	quit(0 if failures.is_empty() else 1)
