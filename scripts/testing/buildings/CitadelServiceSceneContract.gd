extends "res://scripts/testing/buildings/BuildingScenePublicationContract.gd"
## Accepted historical source, real Admission/service/jobs/publishers/tree queue.
## Player-free host: no Main boot, gameplay door capability, or spawn acceptance.
const Structures = preload("res://scripts/StructureSystem.gd")
const SiteQueue = preload("res://scripts/world/CitadelSiteBuildQueue.gd")
const SiteField = preload("res://scripts/world/CitadelSiteField.gd")
const REGION := Vector2i(1,-3)
const SEED := "atlas-1492"

class ServiceHost extends MainFixture:
	var retired_trees: Dictionary = {}
	var retired_before_free := true
	func retire_tree(id: String, body: StaticBody3D) -> void:
		# No NPC registry is configured in this player-free fixture. This observer
		# proves the owning service calls retirement before freeing each real tree.
		retired_before_free=retired_before_free and is_instance_valid(body) and body.is_inside_tree()
		retired_trees[id]=int(retired_trees.get(id,0))+1

func inject_source(admission, source: Dictionary) -> void:
	var request: Dictionary=SiteQueue._canonical_request(SEED,REGION,{},admission._policy)
	var receipt: Dictionary={"token":41,"epoch":admission._queue._epoch,"sourceKey":request.sourceKey}
	admission._requests[REGION]={"priority":true,"receipt":receipt}
	var completed: Dictionary=receipt.duplicate()
	completed.status="consumed"; completed.result=source
	admission._accept(completed)

func inspect_constructed(service) -> Dictionary:
	# End all strong observation aliases before the caller awaits retirement.
	var job=service._scenes[REGION].job
	metrics.publication=job.status()
	metrics.publisherStages=job._building.publication_timing()
	audit_scene(job) # Existing exact collision/render/metadata auditor, unchanged.
	return {"job":weakref(job),"publisher":weakref(job._building),"unitMesh":weakref(job._building.unit_box)}

func source_hashes() -> Dictionary:
	var result := {}
	for path: String in ["scripts/world/CitadelPublicationService.gd","scripts/world/CitadelTerrainAdmission.gd",
		"scripts/StructureSystem.gd","scripts/buildings/BuildingScenePublicationJob.gd",
		"scripts/buildings/BuildingPartPublisher.gd","scripts/buildings/FurnishingPublisher.gd",
		"scripts/buildings/BuildingPublicationPreparation.gd","scripts/buildings/BuildingPublicationWorker.gd",
		"scripts/buildings/BuildingRoofPublication.gd","scripts/buildings/BuildingMasonryPublication.gd",
		"scripts/buildings/BuildingPavingPublication.gd","scripts/buildings/BuildingPartBinding.gd","scripts/buildings/BuildingStaticBatchFlush.gd",
		"scripts/buildings/BuildingMeshBatchUpload.gd","scripts/buildings/MasonryAperturePublication.gd",
		"scripts/MainPlaytestTools.gd","scripts/environment/TreePublicationQueue.gd",
		"scripts/testing/buildings/BuildingScenePublicationContract.gd",
		"scripts/testing/buildings/CitadelServiceSceneContract.gd"]:
		result[path]=FileAccess.get_sha256("res://"+path)
	return result

func _run() -> void:
	output=OS.get_environment("CITADEL_SERVICE_SCENE_OUTPUT")
	if output.is_empty(): quit(2); return
	actual_requested=true
	var hashes:=source_hashes()
	check("actual_scene_audit_completed",false)
	progress("service_historical_source")
	var loader:=Thread.new()
	check("service_loader_started",loader.start(load_source)==OK)
	while loader.is_alive(): await process_frame
	var source: Dictionary=loader.wait_to_finish()
	check("service_fixture_hash",not source.is_empty())
	if source.is_empty(): quit(2); return
	var main:=ServiceHost.new()
	main.seed_text=SEED
	root.add_child(main)
	main.set_process(false); main.set_physics_process(false)
	var parent:=Node3D.new()
	parent.position=Vector3(13,5,-19)
	main.add_child(parent)
	main.structure_system=Structures.new()
	main.structure_system.setup(main)
	var admission=main.structure_system.citadel_terrain_admission
	admission.finalize_town_inputs({})
	var service=main.structure_system.citadel_publication
	inject_source(admission,source)
	source={}
	check("service_admitted_real_source",admission.source_state(REGION).get("status")=="ready")
	check("service_unconfigured_capability_pending",service.stats().constructionStatus=="pending" and not service.stats().publicationReady)
	check("service_player_free_host_bound",service.configure_scene_publication(parent,main.make_tree_from_runtime_request,main.retire_tree))
	var bounds:=Rect2i(SiteField.candidate_for_region(SEED,REGION).centerCell,Vector2i.ONE)
	var started:=Time.get_ticks_usec()
	var deadline:=Time.get_ticks_msec()+150000
	var next_progress:=0
	var evicted:=false
	while Time.get_ticks_msec()<deadline:
		main.structure_system.advance_citadel_publication(bounds,true)
		var status: Dictionary=service.scene_state(REGION)
		if Time.get_ticks_msec()>=next_progress:
			progress("service_"+String(status.status),service.stats())
			next_progress=Time.get_ticks_msec()+3000
		if service.stats().sceneStartedCount==1 and not evicted:
			admission._retired["fixture-cache-eviction"]=admission._sources[REGION]
			admission._sources.erase(REGION)
			evicted=true
		if status.status in ["scene_ready","failed"]: break
		await process_frame
	metrics.serviceConstructionElapsedUsec=Time.get_ticks_usec()-started
	metrics.service=service.stats()
	check("service_scene_constructed",service.scene_state(REGION).status=="scene_ready")
	check("service_single_owned_job",service.stats().sceneStartedCount==1 and service.stats().dispatchCount==1 and service.stats().preparedSites==0)
	check("service_eviction_no_reconstruction",evicted and admission._requests.is_empty() and admission.source_state(REGION).status=="prepared")
	check("service_no_gameplay_claim",not service.stats().publicationReady and not service.scene_state(REGION).gameplayReady)
	var watched: Dictionary={}
	if checks.service_scene_constructed:
		await physics_frame; await process_frame
		await physics_frame; await process_frame
		watched=inspect_constructed(service)
	progress("service_departure")
	main.structure_system.advance_citadel_publication(Rect2i(),true)
	deadline=Time.get_ticks_msec()+30000
	while Time.get_ticks_msec()<deadline:
		var state: Dictionary=service.stats()
		if state.retiringScenes==0 and state.pendingRetirements==0 and not state.worker.get("busy",true): break
		await main.startup_loading_yield("Contract: retiring constructed landmark")
	check("service_departure_nodes_gone",parent.get_child_count()==0 and service.stats().retiringScenes==0)
	check("service_balanced_tree_retirement",main.retired_before_free and main.retired_trees.size()==4 and main.retired_trees.values()==[1,1,1,1])
	for key: String in watched: check("service_retired_"+key,watched[key].get_ref()==null)
	await main.wait_for_terrain_workers_before_quit()
	check("service_shutdown_drained",service.stats().shutdownComplete and admission.stats().shutdownComplete)
	if main.tree_publication_queue!=null:
		deadline=Time.get_ticks_msec()+15000
		while Time.get_ticks_msec()<deadline:
			var queue: Dictionary=main.tree_publication_queue.metrics()
			if queue.pending==0 and queue.activeWorkers==0 and queue.completed==0: break
			await process_frame
		metrics.treeQueue=main.tree_publication_queue.metrics()
		check("service_tree_queue_drained",metrics.treeQueue.pending==0 and metrics.treeQueue.activeWorkers==0 and metrics.treeQueue.completed==0)
	main.structure_system.main=null
	main.structure_system=null
	main.free()
	await process_frame
	check("service_source_hashes_unchanged",hashes==source_hashes())
	var report: Dictionary={"passed":not checks.values().has(false),"complete":true,"checks":checks,"metrics":metrics,
		"seed":SEED,"sourceSha256":SHA,"sourceHashes":hashes,
		"evidenceLevel":"accepted_source_service_construction_and_retirement_with_actual_publishers_and_shared_tree_queue",
		"doesNotProve":"No fresh generation, player-safe production admission, real doors/navigation, Main/New Game, save/Continue, headed/GPU or whole-frame budget acceptance."}
	var file:=FileAccess.open(output.path_join("report.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("SERVICE SCENE COMPLETE ",checks.size()," passed=",report.passed)
	quit(0 if report.passed else 1)
