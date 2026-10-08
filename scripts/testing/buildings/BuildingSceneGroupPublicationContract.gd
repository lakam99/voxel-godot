extends SceneTree

## Synthetic source/registry fixture using the real scene job, publishers,
## compiled group description, collision Nodes and worker retirement. This is
## contract evidence, not generated-world, navigation or gameplay acceptance.
const Job = preload("res://scripts/buildings/BuildingScenePublicationJob.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Controls = preload("res://scripts/testing/buildings/BuildingPublicationWorkerContract.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const BINDING := {"siteId":"synthetic-scene-group","sourceKey":"synthetic-scene-source","generation":7}

class RegistryFixture extends RefCounted:
	var doors: Dictionary = {}
	var trees: Dictionary = {}
	var defer_doors: bool = false
	var defer_tree_visual: bool = false
	var skip_tree: bool = false
	func tree_publication_proof(body: Variant, include_installed := true) -> Dictionary:
		if not is_instance_valid(body): return {"status":"failed", "reason":"synthetic_tree_owner_lost"}
		var reference: Variant = trees.get(String(body.get_meta("prop_id", "")))
		var ready := reference is WeakRef and reference.get_ref() == body \
			and body.get_meta("tree_visual_state", "") == "published" \
			and body.get_node_or_null("GeneratedTreeVisual") != null
		return {"status":"ready" if ready else "pending", "bodyInstanceId":body.get_instance_id(),
			"sourcePrepared":ready, "installed":ready and include_installed}
	func tree_source_is_durably_removed(_prop_id: String) -> bool: return skip_tree
	func register_door(body: StaticBody3D) -> Dictionary:
		if defer_doors: return {"status":"pending_budget","sideEffects":false}
		var id: String = String(body.get_meta("door_portal_id",""))
		doors[id] = weakref(body)
		return {"status":"registered","portalId":id}
	func retire_door(body: StaticBody3D) -> Dictionary:
		var id: String = String(body.get_meta("door_portal_id",""))
		doors.erase(id)
		return {"status":"unregistered","portalId":id}
	func publish_tree(parent: Node3D, id: String, position: Vector3, _biome: String, request: Dictionary, yaw: float) -> Dictionary:
		if skip_tree: return {"status":"skipped","reason":"removed_prop"}
		var body: StaticBody3D = StaticBody3D.new()
		body.position = position
		body.rotation.y = yaw
		body.set_meta("prop_id",id)
		var collision: CollisionShape3D = CollisionShape3D.new()
		var shape: CylinderShape3D = CylinderShape3D.new()
		shape.radius = float(request.trunkRadius)
		shape.height = float(request.collisionHeight)
		collision.shape = shape
		collision.position.y = shape.height*0.5
		body.add_child(collision)
		parent.add_child(body)
		trees[id] = weakref(body)
		body.set_meta("tree_visual_state","queued")
		if not defer_tree_visual: publish_visual(body)
		return {"status":"published","body":body}
	func publish_visual(body: StaticBody3D) -> void:
		var visual: Node3D = Node3D.new()
		visual.name = "GeneratedTreeVisual"
		body.add_child(visual)
		body.set_meta("tree_visual_state","published")
	func retire_tree(id: String, _body) -> Dictionary:
		trees.erase(id)
		return {"status":"unregistered","objectId":"prop:"+id}

var checks: Dictionary = {}
var metrics: Dictionary = {}
var parent: Node3D
var worker

func _initialize() -> void: call_deferred("_run")
func check(label: String, value: bool) -> void:
	checks[label] = value
	if not value: print("SCENE GROUP CONTRACT FAILURE ",label)

func post(blueprint, id: String, x: float, dependencies: Array = []) -> void:
	blueprint.add_part({"id":id,"kind":"post","material":"timber_beam","size":Vector3(0.25,1,0.25),
		"position":Vector3(x,0.5,0),"recipe":{"physicalSupportPartIds":dependencies}})

func profile() -> Dictionary:
	var result: Dictionary = Controls.profile()
	result.siteId = BINDING.siteId
	result.origin = Vector3(10,0,20)
	Controls.freeze(result)
	return result

func start(blueprint, plan, registry):
	var prepared = Preparation.PreparedSource.new()
	prepared._binding = BINDING
	var frozen_profile: Dictionary = profile()
	var spatial = Preparation.SpatialDependencies.compile_description(blueprint,plan,BINDING,frozen_profile.origin,Callable())
	check("description_"+blueprint.id,spatial != null and spatial.publication_groups.get("ready",false))
	prepared._payload = {"blueprint":blueprint,"furnishingPlan":plan,"spatialDependencies":spatial,
		"physicalIntegrity":{"passed":true},"raisedRouteCoverage":{"passed":true},"preparationUsec":0,"routeUsec":0,"physicalUsec":0}
	var job = Job.new()
	check("door_callbacks_"+blueprint.id,job.set_door_callbacks(registry.register_door,registry.retire_door))
	check("tree_callbacks_"+blueprint.id,job.set_tree_retire_callback(registry.retire_tree,true))
	var begun: Dictionary = job.begin(prepared,frozen_profile,BINDING,parent,registry.publish_tree)
	check("begin_"+blueprint.id,begun.get("status")=="pending_budget")
	if not metrics.has("setup"): metrics.setup = {}
	metrics.setup[blueprint.id] = {"profileSiteId":frozen_profile.siteId,"binding":BINDING,
		"descriptionReady":spatial != null and spatial.publication_groups.get("ready",false),
		"descriptionReason":spatial.publication_groups.get("reason","") if spatial != null else "description_missing",
		"begin":begun}
	if begun.get("status") != "pending_budget":
		# Rejection never transfers this holder to the idle job. Keep the failed
		# setup assertion, retire the caller's payload through the existing worker,
		# and stop this case before invoking any transaction/scene teardown APIs.
		check("rejected_"+blueprint.id+"_holder_unconsumed",not prepared._consumed and job.own_node_root()==null)
		var rejected: Dictionary = {"prepared":prepared}
		check("rejected_"+blueprint.id+"_retirement_accepted",worker.retire_external_payload(rejected))
		prepared = null
		spatial = null
		rejected = {}
		var deadline: int = Time.get_ticks_msec()+5000
		while worker.poll().busy and Time.get_ticks_msec()<deadline: await process_frame
		check("rejected_"+blueprint.id+"_worker_drained",not worker.poll().busy)
		return null
	return job

func pin(job) -> Dictionary:
	for turn: int in range(10000):
		var result: Dictionary = job.pending_publication_transaction()
		if result.get("status") != "pending_budget":
			metrics.lastSelection = result
			return result
	return {"status":"failed","reason":"synthetic_selection_deadline"}

func complete_transaction(job, transaction: Dictionary) -> void:
	for turn: int in range(20000):
		var result: Dictionary = job.advance(2500,int(transaction.transactionId))
		if job._transaction.is_empty() or result.status in ["failed","cancelled","ready"]:
			metrics.lastTransaction = {"transaction":transaction,"result":result}
			return
	check("transaction_completes_"+str(transaction.transactionId),false)

func complete_site(job) -> void:
	for turn: int in range(30000):
		var result: Dictionary = job.advance(2500)
		if result.status in ["failed","cancelled","ready"]:
			metrics.lastSite = result
			return
	check("site_completes",false)

func retire(job, registry, label: String) -> void:
	job.cancel()
	for turn: int in range(20000):
		if job.status().retirementReady: break
		job.advance(2500)
	check(label+"_scene_retired",job.status().retirementReady and job.own_node_root()==null and registry.doors.is_empty() and registry.trees.is_empty())
	var payload: Dictionary = job.take_retirement_payload()
	check(label+"_one_shot_retirement",not payload.is_empty() and job.take_retirement_payload().is_empty())
	if not payload.is_empty(): worker.retire_external_payload(payload)
	payload = {}
	var deadline: int = Time.get_ticks_msec()+5000
	while worker.poll().busy and Time.get_ticks_msec()<deadline: await process_frame
	check(label+"_worker_drained",not worker.poll().busy)

func demand_and_boundaries() -> void:
	check("demand_case_completed",false)
	var blueprint = Blueprint.new("demand",1,"timber")
	for index: int in range(70): post(blueprint,"p%02d"%index,float(index)*3.0)
	var plan = Plan.new("demand-furniture",1,blueprint.id)
	var before: PackedByteArray = var_to_bytes([blueprint.snapshot(),plan.snapshot()])
	var registry = RegistryFixture.new()
	var job = await start(blueprint,plan,registry)
	if job == null: return
	check("request_unknown_rejected",job.request_publication_groups(["building:missing"],BINDING).get("status")=="failed" and job._group_requests.is_empty())
	check("owner_replacement_validated_atomically",job.replace_publication_group_demands([
		{"ownerId":"player","groupIds":["building:p69"],"priority":0},{"ownerId":"bad","groupIds":["bad"],"priority":1}],BINDING).get("status")=="failed" and job._group_requests.is_empty())
	check("priority_request_retained",job.replace_publication_group_demands([{"ownerId":"player","groupIds":["building:p69","building:p68"],"priority":0}],BINDING).get("status")=="retained")
	var transaction: Dictionary = pin(job)
	check("demand_transaction_selected",transaction.get("status")=="ready")
	if transaction.get("status") != "ready": await retire(job,registry,"demand_selection_failed"); return
	check("demand_selected_before_background",transaction.get("groupIds")==["building:p69","building:p68"] and transaction.get("buildingIndices")==[68,69])
	check("selection_has_no_scene_side_effects",job.own_node_root()==null and job.status().buildingCursor==0)
	check("individual_collision_bounds",transaction.collisionMemberBounds.size()==2 and not transaction.collisionMemberBounds[0].encloses(transaction.collisionMemberBounds[1]))
	check("immutable_transaction",transaction.is_read_only() and transaction.groupIds.is_read_only() and transaction.collisionMemberBounds.is_read_only())
	check("wrong_guard_token_rejected",job.advance(2500,int(transaction.transactionId)+1).get("reason")=="publication_transaction_changed" and job.own_node_root()==null)
	job.replace_publication_group_demands([{ "ownerId":"replacement","groupIds":["building:p67"],"priority":0}],BINDING)
	check("replaced_demand_preserves_pinned_transaction",is_same(job.pending_publication_transaction(),transaction) and not job._group_requests.has("building:p69"))
	var observed_uncommitted: bool = false
	for turn: int in range(10000):
		job.advance(1,int(transaction.transactionId))
		if job._building != null and job._building.collision_count>0:
			observed_uncommitted = job.physical_group_receipt("building:p68",BINDING).status=="pending"
			break
	check("collision_without_boundary_is_not_receipt",observed_uncommitted)
	complete_transaction(job,transaction)
	check("near_group_ready_before_whole_site",job.physical_group_receipt("building:p69",BINDING).status=="ready" and not job.status().sceneReady)
	check("advance_stops_before_next_transaction",job._transaction.is_empty() and job.status().buildingCursor==2)
	var second: Dictionary = pin(job)
	check("replacement_transaction_selected",second.get("status")=="ready")
	if second.get("status") != "ready": await retire(job,registry,"replacement_selection_failed"); return
	check("new_guard_excludes_completed_members",second.groupIds==["building:p67"] and second.collisionMemberBounds.size()==1)
	complete_transaction(job,second)
	job.replace_publication_group_demands([],BINDING)
	var background: Dictionary = pin(job)
	check("background_transaction_selected",background.get("status")=="ready")
	if background.get("status") != "ready": await retire(job,registry,"background_selection_failed"); return
	check("background_coalesces_multiple_groups",background.groupIds.size()==Job.MAX_TRANSACTION_GROUPS and background.buildingIndices.size()==Job.MAX_TRANSACTION_GROUPS)
	complete_transaction(job,background)
	complete_site(job)
	check("whole_site_completes_without_demand_loss",job.status().sceneReady and job.status().buildingCursor==70 and job._building.incremental_published_parts==70)
	if not job.status().sceneReady: await retire(job,registry,"demand_completion_failed"); return
	check("original_source_unchanged",before==var_to_bytes([blueprint.snapshot(),plan.snapshot()]))
	check("source_indices_not_duplicated",job._building.static_part_records.size()==70)
	metrics.demand = job.status()
	var epoch: int = job._building.source_part_publication_epoch("p68")
	check("batch_owners_shared_across_groups",job._boundary_witnesses.has(epoch) and job._building.source_part_publication_epoch("p69")==epoch)
	var shared_body: StaticBody3D = job._building.static_collision_body
	shared_body.position.x += 1.0
	check("moved_shared_collision_owner_revokes_receipt",job.physical_group_receipt("building:p68",BINDING).status=="pending")
	shared_body.position.x -= 1.0
	check("restored_exact_owner_pose_is_usable",job.physical_group_receipt("building:p68",BINDING).status=="ready")
	var collider: CollisionShape3D = job._member_witnesses["building:p68"].collisions[0].node.get_ref() as CollisionShape3D
	collider.free()
	check("lost_member_collider_revokes_receipt",job.physical_group_receipt("building:p68",BINDING).status=="pending")
	job.cancel()
	check("cancel_immediately_revokes_other_receipts",job.physical_group_receipt("building:p69",BINDING).status=="pending")
	await retire(job,registry,"demand")
	check("demand_case_completed",true)

func check_tree_dimension_mutation(job, body: StaticBody3D) -> void:
	var collision: CollisionShape3D = body.get_child(0) as CollisionShape3D
	var cylinder: CylinderShape3D = collision.shape as CylinderShape3D
	var original_radius: float = cylinder.radius
	cylinder.radius += 0.1
	check("changed_tree_cylinder_dimension_revokes_receipt",job.physical_group_receipt("tree:tree",BINDING).status=="pending")
	cylinder.radius = original_radius
	check("restored_exact_tree_cylinder_dimension_is_usable",job.physical_group_receipt("tree:tree",BINDING).status=="ready")
	# Local shape aliases end before the caller drains whole-scene retirement.

func dependencies_and_leaves() -> void:
	check("leaves_case_completed",false)
	var blueprint = Blueprint.new("leaves",2,"timber")
	post(blueprint,"upper",0,["foundation"])
	post(blueprint,"foundation",4)
	blueprint.add_part({"id":"door","kind":"door","material":"timber_board","size":Vector3(1.2,2.2,0.12),"position":Vector3(8,1.1,0)})
	var request: Dictionary = {"architecture":"broadleaf","speciesGrammar":"synthetic_contract","visualHeight":6.0,"collisionHeight":3.0,"trunkRadius":0.3,"canopyRadius":2.0}
	blueprint.recipe.landscapeTrees = [{"id":"tree","position":Vector3(12,0,0),"rotationY":0.0,"canopyRadius":2.0,"rootButtressFootprints":[],"treeRequest":request}]
	var plan = Plan.new("leaf-furniture",1,blueprint.id)
	plan.add_part({"id":"chair","archetype":"chair","position":Vector3(16,0,0)})
	var registry = RegistryFixture.new()
	registry.defer_doors = true
	registry.defer_tree_visual = true
	var job = await start(blueprint,plan,registry)
	if job == null: return
	job.request_publication_groups(["building:upper","building:door","furnishing:chair","tree:tree"],BINDING,0)
	var transaction: Dictionary = pin(job)
	check("leaves_transaction_selected",transaction.get("status")=="ready")
	if transaction.get("status") != "ready": await retire(job,registry,"leaves_selection_failed"); return
	check("requested_support_closure_retained",transaction.groupIds.has("building:foundation") and transaction.groupIds.size()==5)
	for turn: int in range(10000):
		job.advance(2500,int(transaction.transactionId))
		if job.status().phase=="door_registration": break
	check("door_ack_pending_keeps_group_unready",job.physical_group_receipt("building:door",BINDING).status=="pending" and registry.doors.is_empty())
	registry.defer_doors = false
	for turn: int in range(10000):
		job.advance(2500,int(transaction.transactionId))
		if job.status().phase=="group_tree_visuals": break
	check("queued_tree_does_not_acknowledge_transaction",job.physical_group_receipt("tree:tree",BINDING).status=="pending" and not registry.trees.is_empty())
	if not registry.trees.is_empty():
		var published_tree: StaticBody3D = registry.trees.values()[0].get_ref() as StaticBody3D
		registry.publish_visual(published_tree)
		var collision: CollisionShape3D = published_tree.get_child(0) as CollisionShape3D
		var cylinder: CylinderShape3D = collision.shape as CylinderShape3D
		metrics.treeDimensions = {"requestedRadius":request.trunkRadius,"requestedHeight":request.collisionHeight,
			"actualRadius":cylinder.radius,"actualHeight":cylinder.height,"collisionTransform":collision.transform}
	complete_transaction(job,transaction)
	check("exact_leaves_acknowledged",job.physical_group_receipt("building:door",BINDING).status=="ready" and job.physical_group_receipt("tree:tree",BINDING).status=="ready" and job.physical_group_receipt("furnishing:chair",BINDING).status=="ready")
	if not checks.exact_leaves_acknowledged: await retire(job,registry,"leaves_completion_failed"); return
	check_tree_dimension_mutation(job,registry.trees.values()[0].get_ref() as StaticBody3D)
	var tree_body: Node3D = registry.trees.values()[0].get_ref() as Node3D
	tree_body.position.x += 1.0
	check("moved_tree_owner_revokes_receipt",job.physical_group_receipt("tree:tree",BINDING).status=="pending")
	tree_body.position.x -= 1.0
	check("restored_tree_source_pose_is_usable",job.physical_group_receipt("tree:tree",BINDING).status=="ready")
	var foundation: CollisionShape3D = job._member_witnesses["building:foundation"].collisions[0].node.get_ref() as CollisionShape3D
	foundation.free()
	check("support_loss_revokes_dependent_group",job.physical_group_receipt("building:upper",BINDING).status=="pending")
	await retire(job,registry,"leaves")
	check("leaves_case_completed",true)

func source_mutation_before_publication() -> void:
	for kind: String in ["building","furnishing"]:
		var blueprint = Blueprint.new("mutation-"+kind,3,"timber")
		post(blueprint,"post",0)
		var plan = Plan.new("mutation-furniture",1,blueprint.id)
		plan.add_part({"id":"chair","archetype":"chair","position":Vector3(4,0,0)})
		var registry = RegistryFixture.new()
		var job = await start(blueprint,plan,registry)
		if job == null: continue
		var transaction: Dictionary = pin(job)
		check(kind+"_mutation_transaction_selected",transaction.get("status")=="ready")
		if transaction.get("status") != "ready": await retire(job,registry,kind+"_mutation_selection_failed"); continue
		if kind == "building": blueprint.parts[0].position.x += 100.0
		else: plan.parts[0].position.x += 100.0
		complete_transaction(job,transaction)
		check(kind+"_source_mutation_rejected_before_collision",job.status().status=="failed" \
			and String(job.status().reason).begins_with("publication_source_geometry_changed:") \
			and (job._building.collision_count==0 if kind=="building" else job._furniture.published_parts.is_empty()))
		check(kind+"_selection_exposes_terminal_failure",job.pending_publication_transaction().get("status")=="failed")
		await retire(job,registry,kind+"_mutation")

func _run() -> void:
	parent = Node3D.new()
	root.add_child(parent)
	worker = Worker.new()
	await demand_and_boundaries()
	await dependencies_and_leaves()
	await source_mutation_before_publication()
	worker.request_shutdown()
	var deadline: int = Time.get_ticks_msec()+5000
	while not worker.poll().shutdownComplete and Time.get_ticks_msec()<deadline: await process_frame
	check("worker_shutdown",worker.poll().shutdownComplete)
	parent.free()
	var report: Dictionary = {"schema":"building-scene-group-contract/v1","complete":true,"passed":not checks.values().has(false),"checks":checks,"metrics":metrics,"evidence":"synthetic_scene_group_publication","doesNotProve":"No generated-world, navigation or live gameplay acceptance."}
	var file: FileAccess = FileAccess.open(OS.get_environment("BUILDING_SCENE_GROUP_REPORT"),FileAccess.WRITE)
	if file == null: push_error("scene_group_report_unavailable"); quit(1); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("SCENE GROUP ",JSON.stringify(report))
	quit(0 if report.passed else 1)
