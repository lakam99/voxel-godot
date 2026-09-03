extends "res://scripts/testing/buildings/CitadelSceneLifecycleContract.gd"
## Synthetic source/callback contract, real service/jobs/publishers. No player
## movement or normal-world acceptance is inferred from these readiness values.

class Callbacks extends RefCounted:
	var trees: WeakRef
	var allow_construction := true
	var target: WeakRef
	var admission: WeakRef
	var action := ""
	var action_calls := 0
	var region := Vector2i.ZERO
	func construction_allowed(_bounds: Rect2i) -> bool:
		var pending := action
		action = ""
		if not pending.is_empty():
			action_calls += 1
			match pending:
				"configure": target.get_ref().configure(admission.get_ref())
				"reset": target.get_ref().begin_world_reset()
				"retire": target.get_ref()._retire_scene(region)
		return allow_construction
	func retire_tree(id: String, body: StaticBody3D) -> Dictionary:
		trees.get_ref().retire(id, body)
		return {"status":"unregistered", "objectId":"prop:" + id}
	func register_door(_body: Node) -> Dictionary:
		return {"status":"failed", "reason":"unexpected_door_in_tiny_fixture"}
	func retire_door(_body: Node) -> Dictionary:
		return {"status":"absent"}

func guard_callback_case(action: String, during_publication: bool) -> void:
	var label := action + ("_during" if during_publication else "_before")
	var c := setup_scene(true)
	var callbacks := Callbacks.new()
	callbacks.trees=weakref(c.trees); callbacks.target=weakref(c.service)
	callbacks.admission=weakref(c.admission); callbacks.region=REGION
	check(label+"_guard",c.service.configure_construction_guard(callbacks.construction_allowed))
	check(label+"_doors",c.service.configure_door_publication(callbacks.register_door,callbacks.retire_door))
	check(label+"_trees",c.service.configure_scene_publication(c.parent,c.trees.publish,callbacks.retire_tree,true))
	if during_publication: await wait_phase(c,"tree_visuals",label+"_waiting")
	callbacks.action=action
	var deadline := Time.get_ticks_msec()+6000
	while callbacks.action_calls==0 and Time.get_ticks_msec()<deadline:
		c.service.advance(bounds(),true)
		await process_frame
	check(label+"_action_once",callbacks.action_calls==1)
	check(label+"_no_stale_completion",c.service.stats().sceneCompletedCount==0 and not c.service._scenes.has(REGION))
	check(label+"_no_stale_start",c.service.stats().sceneStartedCount==(1 if during_publication else 0))
	await finish_case(c,label+"_finish")

func _run() -> void:
	var output := OS.get_environment("CITADEL_PHYSICAL_READINESS_OUTPUT")
	if output.is_empty(): quit(2); return
	for action: String in ["configure","reset"]:
		await guard_callback_case(action,false)
		await guard_callback_case(action,true)
	await guard_callback_case("retire",true)
	var c := setup_scene(true)
	var callbacks := Callbacks.new()
	callbacks.trees = weakref(c.trees)
	var footprint := bounds()
	var outside := Rect2i(footprint.end + Vector2i.ONE * 5, Vector2i.ONE)
	var no_site: Dictionary = c.service.physical_publication_state(outside)
	check("outside_reservation_no_scene_required", no_site.get("status") == "ready" and not no_site.get("required", true))
	check("missing_runtime_callbacks_pending", c.service.physical_publication_state(footprint).status == "pending")
	check("door_callbacks_bound", c.service.configure_door_publication(callbacks.register_door, callbacks.retire_door))
	check("construction_guard_bound",c.service.configure_construction_guard(callbacks.construction_allowed))
	check("acknowledged_tree_callbacks_bound", c.service.configure_scene_publication(c.parent,c.trees.publish,callbacks.retire_tree,true))
	await wait_phase(c,"tree_visuals","partial_scene_waiting")
	callbacks.allow_construction=false
	c.trees.release_visuals()
	for index in range(6):
		c.service.advance(footprint,true)
		await process_frame
	check("active_player_guard_retains_pending_job",phase(c)=="tree_visuals" and c.service.stats().constructedScenes==0)
	callbacks.allow_construction=true
	var pending: Dictionary = c.service.physical_publication_state(footprint)
	check("partial_scene_not_accessible", pending.status == "pending" and pending.reason == "landmark_structures_pending")
	c.trees.release_visuals()
	await wait_scene(c,REGION,"scene_ready","construction_completed")
	var ready: Dictionary = c.service.physical_publication_state(footprint)
	check("matching_constructed_scene_ready", ready.status == "ready" and ready.required)
	var site: Node3D = c.service.scene_root(REGION)
	var original := site.global_transform
	site.position.x += 1.0
	check("moved_root_never_ready", c.service.physical_publication_state(footprint).status == "failed")
	site.global_transform = original
	check("restored_root_matches_source", c.service.physical_publication_state(footprint).status == "ready")
	check("cannot_downgrade_ack_while_live", not c.service.configure_scene_publication(c.parent,c.trees.publish,callbacks.retire_tree,false))
	c.service.begin_world_reset()
	check("reset_never_ready", c.service.physical_publication_state(footprint).status == "pending")
	site = null
	await finish_case(c,"readiness_finish")
	var failures: Array = []
	for label: String in checks:
		if not checks[label]: failures.append(label)
	var source_hashes := {}
	for path: String in [get_script().resource_path,"res://scripts/world/CitadelPublicationService.gd","res://scripts/StructureSystem.gd","res://scripts/buildings/BuildingScenePublicationJob.gd","res://scripts/terrain/VoxelTerrainRuntime.gd","res://scripts/MainCore.gd","res://scripts/MainSetupScene.gd"]:
		source_hashes[path] = FileAccess.get_sha256(path)
	var report := {"passed":failures.is_empty(),"checks":checks,"failures":failures,"metrics":metrics,
		"sourceSha256":source_hashes,"evidenceLevel":"synthetic source/service readiness; no live gameplay or visual acceptance"}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("CITADEL PHYSICAL READINESS checks=",checks.size()," failures=",failures.size())
	quit(0 if failures.is_empty() else 1)
