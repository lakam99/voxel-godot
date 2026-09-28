extends "res://scripts/testing/buildings/CitadelServiceSceneContract.gd"
## Accepted historical source through ordinary StructureSystem/NpcSystem binding.
## Main boot and NPC processing are suppressed; this is NOT a New Game playtest.

func runtime_hashes() -> Dictionary:
	var hashes := source_hashes()
	for path: String in ["scripts/StructureSystem.gd","scripts/MainCore.gd","scripts/MainSetupScene.gd","scripts/MainSaveState.gd","scripts/NpcSystem.gd","scripts/npc_ai/NpcAutonomySystem.gd","scripts/npc_ai/navigation/NavmeshWorldService.gd","scripts/world/GeneratedStructureRuntimeBindings.gd","scripts/environment/TreePublicationQueue.gd","scripts/testing/buildings/CitadelRuntimeOwnersActualContract.gd"]:
		hashes[path] = FileAccess.get_sha256("res://"+path)
	return hashes

func _run() -> void:
	output = OS.get_environment("CITADEL_RUNTIME_OWNERS_OUTPUT")
	if output.is_empty(): quit(2); return
	actual_requested = true
	var hashes := runtime_hashes()
	check("actual_scene_audit_completed",false)
	progress("runtime_owners_historical_source")
	var loader := Thread.new()
	check("source_loader_started",loader.start(load_source)==OK)
	while loader.is_alive(): await process_frame
	var source: Dictionary = loader.wait_to_finish()
	check("accepted_source_hash",not source.is_empty())
	if source.is_empty(): quit(2); return
	var main := MainFixture.new()
	main.seed_text = SEED
	main.startup_loading_active = true
	root.add_child(main)
	main.set_process(false); main.set_physics_process(false)
	main.player = CharacterBody3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius=0.42; capsule.height=1.72
	var collider := CollisionShape3D.new()
	collider.name="PlayerCollider"; collider.shape=capsule; collider.position.y=0.86
	main.player.add_child(collider)
	main.add_child(main.player)
	main.player.set_physics_process(false)
	main.structure_system=Structures.new()
	main.structure_system.setup(main)
	# Real production setup hook configures the composed binding adapter.
	main.setup_npc_system()
	main.npc_system.set_process(false); main.npc_system.set_physics_process(false)
	main.npc_system.autonomy_system.set_physics_process(false)
	var autonomy = main.npc_system.autonomy_system
	var admission=main.structure_system.citadel_terrain_admission
	admission.finalize_town_inputs({})
	var service=main.structure_system.citadel_publication
	inject_source(admission,source)
	source={}
	check("ordinary_setup_binds_real_owners",main.structure_system.citadel_runtime_bindings!=null and main.structure_system.citadel_runtime_bindings.available() and service.stats().doorLifecycleAvailable)
	var bounds:=Rect2i(SiteField.candidate_for_region(SEED,REGION).centerCell,Vector2i.ONE)
	var started:=Time.get_ticks_usec()
	var deadline:=Time.get_ticks_msec()+150000
	var next_progress:=0
	while Time.get_ticks_msec()<deadline:
		main.structure_system.advance_citadel_publication(bounds,true)
		var state: Dictionary=service.scene_state(REGION)
		if Time.get_ticks_msec()>=next_progress:
			progress("runtime_owners_"+String(state.status),service.stats())
			next_progress=Time.get_ticks_msec()+3000
		if state.status in ["scene_ready","failed"]: break
		await process_frame
	metrics.constructionElapsedUsec=Time.get_ticks_usec()-started
	check("ordinary_owner_scene_constructed",service.scene_state(REGION).status=="scene_ready")
	var watched := {}
	if checks.ordinary_owner_scene_constructed:
		await physics_frame; await process_frame
		watched=inspect_constructed(service)
		check("all_twenty_real_doors_registered",autonomy.door_portals.portals.size()==20 and autonomy.door_portals.door_to_portal.size()==20)
		check("four_real_tree_resources_registered",autonomy.smart_objects.registrations.size()==24)
		check("ordinary_readiness_requires_complete_scene",main.structure_system.citadel_physical_publication_state(bounds).status=="ready")
		check("no_parallel_block_navigation_source",main.blocks.is_empty())
		metrics.navigation=autonomy.navmesh_world.stats()
		check("no_citadel_route_query",autonomy.navmesh_world.path_query_count==0)
	progress("runtime_owners_retirement")
	check("production_pre_reset_drain",await main.retire_generated_scenes_before_world_reset())
	check("scene_nodes_retired",service.scene_root(REGION)==null and not service.requires_scene_retirement())
	check("all_door_registries_retired",autonomy.door_portals.portals.is_empty() and autonomy.door_portals.controllers.is_empty() and autonomy.door_portals.door_to_portal.is_empty())
	check("navigation_state_retired",autonomy.navmesh_world.door_portal_states.is_empty() and autonomy.navmesh_world.door_link_records_by_portal.is_empty())
	var trees_unbound: bool = autonomy.smart_objects.registrations.size()==4
	for registration in autonomy.smart_objects.registrations.values():
		trees_unbound = trees_unbound and registration.node==null and not registration.depleted
	check("trees_unbound_not_harvested",trees_unbound and main.removed_props.is_empty())
	for key: String in watched: check("retired_resource_"+key,watched[key].get_ref()==null)
	await main.wait_for_terrain_workers_before_quit()
	check("source_and_scene_shutdown",service.stats().shutdownComplete and admission.stats().shutdownComplete)
	if main.tree_publication_queue!=null:
		deadline=Time.get_ticks_msec()+15000
		while Time.get_ticks_msec()<deadline:
			var state: Dictionary=main.tree_publication_queue.metrics()
			if state.pending==0 and state.activeWorkers==0 and state.completed==0: break
			await process_frame
		metrics.treeQueue=main.tree_publication_queue.metrics()
		check("tree_queue_drained",metrics.treeQueue.pending==0 and metrics.treeQueue.activeWorkers==0 and metrics.treeQueue.completed==0)
	await main.wait_for_npc_navigation_before_quit()
	main.structure_system.main=null
	main.structure_system=null
	main.free()
	await process_frame
	check("source_hashes_unchanged",hashes==runtime_hashes())
	var report := {"passed":not checks.values().has(false),"checks":checks,"metrics":metrics,"seed":SEED,"sourceSha256":SHA,"sourceHashes":hashes,
		"evidenceLevel":"accepted source, real production owner binding/publishers/tree queue/shared NPC registries; suppressed Main boot and actor processing",
		"doesNotProve":"No fresh seed generation, New Game/Continue, live player/NPC movement, harvesting/save, headed visuals or runtime performance acceptance."}
	var file:=FileAccess.open(output.path_join("report.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("RUNTIME OWNERS ACTUAL checks=",checks.size()," passed=",report.passed)
	quit(0 if report.passed else 1)
