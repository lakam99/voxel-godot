extends "res://scripts/testing/buildings/BuildingSceneGroupPublicationContract.gd"

## Synthetic contract using the existing real scene-job/publisher fixture.
## Direct commit staging isolates receipt validation; it is not gameplay,
## terrain, navigation, generated-citadel or performance acceptance.

var proof_cases_completed: Dictionary = {"diamond":false,"mutations":false,"atomic":false,"memo":false,"memo_door":false}

class OversizedRequirements extends RefCounted:
	var parts: Dictionary = {}
	var cells: Dictionary = {}
	var publication_groups: Dictionary = {}
	var binding: Dictionary = {}
	var origin := Vector3.ZERO
	var values: Array = []
	var calls := 0
	func physical_group_requirements(_bounds: Rect2i) -> Dictionary:
		calls += 1
		return {"status":"described","groupIds":[],"syntheticOversizedValues":values.duplicate()}

func proof_before(job, kind: String) -> Dictionary:
	return job._proof_totals.get(kind,{}).duplicate()

func proof_delta(job, kind: String, before: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var after: Dictionary = job._proof_totals.get(kind,{})
	for key: String in Job.PROOF_COUNTERS: result[key] = int(after.get(key,0))-int(before.get(key,0))
	result["calls"] = int(after.get("calls",0))-int(before.get("calls",0))
	return result

func shape_and_parent_mutations(job) -> void:
	var key := "building:foundation"
	var witness: Dictionary = job._member_witnesses.get(key,{})
	check("collision_has_exact_parent_witness",witness.get("collisions",[]).size()==1 and witness.collisions[0].get("parent") is WeakRef)
	if witness.get("collisions",[]).size()!=1: return
	var collision: CollisionShape3D = witness.collisions[0].node.get_ref() as CollisionShape3D
	check("mutation_fixture_collision_available",is_instance_valid(collision))
	if not is_instance_valid(collision): return
	var shape: BoxShape3D = collision.shape as BoxShape3D
	check("mutation_fixture_box_shape",shape!=null)
	if shape==null: return
	var original_size: Vector3 = shape.size
	shape.size = original_size+Vector3(0.1,0,0)
	check("same_frame_shape_change_revokes",job.physical_group_receipt("building:top_a",BINDING).status=="pending")
	shape.size = original_size
	check("same_frame_shape_restore_recovers",job.physical_group_receipt("building:top_a",BINDING).status=="ready")
	var original_parent: Node = collision.get_parent()
	var original_transform: Transform3D = collision.transform
	var foreign: StaticBody3D = StaticBody3D.new()
	foreign.position = Vector3(100,0,0)
	job.own_node_root().add_child(foreign)
	collision.reparent(foreign,false)
	check("same_frame_foreign_collision_parent_revokes",job.physical_group_receipt("building:top_a",BINDING).status=="pending")
	collision.reparent(original_parent,false)
	collision.transform = original_transform
	check("same_frame_exact_collision_parent_restore_recovers",job.physical_group_receipt("building:top_a",BINDING).status=="ready")
	foreign.free()
	var source = witness.source
	var source_size: Vector3 = source.size
	source.size += Vector3(0.1,0,0)
	check("same_frame_source_geometry_change_revokes",job.physical_group_receipt("building:top_a",BINDING).status=="pending")
	source.size = source_size
	check("same_frame_source_geometry_restore_recovers",job.physical_group_receipt("building:top_a",BINDING).status=="ready")
	var epoch: int = job._building.source_part_publication_epoch("top_a")
	var batch: Node3D
	for entry: Dictionary in job._boundary_witnesses.get(epoch,[]):
		if entry.renderOwner:
			batch = entry.node.get_ref() as Node3D
			break
	check("shared_boundary_has_render_witness",batch!=null)
	if batch!=null:
		var original: Transform3D = batch.transform
		batch.position.x += 1.0
		check("same_frame_shared_batch_change_revokes",job.physical_group_receipt("building:top_a",BINDING).status=="pending")
		batch.transform = original
		check("same_frame_shared_batch_restore_recovers",job.physical_group_receipt("building:top_a",BINDING).status=="ready")
		proof_cases_completed.mutations = true

func diamond_and_shared_boundary() -> void:
	var blueprint = Blueprint.new("proof-diamond",1,"timber")
	post(blueprint,"foundation",0.0)
	post(blueprint,"left",3.0,["foundation"])
	post(blueprint,"right",6.0,["foundation"])
	post(blueprint,"top_a",9.0,["left","right"])
	post(blueprint,"top_b",12.0,["left","right"])
	var registry = RegistryFixture.new()
	var job = await start(blueprint,Plan.new("proof-diamond-furniture",1,blueprint.id),registry)
	if job==null: return
	var graph_valid: bool = job._groups.groups.size()==5 \
		and job._groups.groups.has_all(["building:foundation","building:left","building:right","building:top_a","building:top_b"]) \
		and job._groups.groups["building:left"].dependencies==["building:foundation"] \
		and job._groups.groups["building:right"].dependencies==["building:foundation"] \
		and job._groups.groups["building:top_a"].dependencies==["building:left","building:right"]
	check("diamond_source_graph_precondition",graph_valid)
	if not graph_valid: await retire(job,registry,"diamond_graph"); return
	job.request_publication_groups(["building:foundation"],BINDING)
	var first: Dictionary = pin(job)
	check("foundation_transaction_only",first.get("groupIds")==["building:foundation"])
	if first.get("groupIds")!=["building:foundation"]: await retire(job,registry,"foundation_selection"); return
	complete_transaction(job,first)
	check("foundation_real_receipt",job.physical_group_receipt("building:foundation",BINDING).status=="ready")
	if not checks.foundation_real_receipt: await retire(job,registry,"foundation_commit"); return
	job.request_publication_groups(["building:top_a","building:top_b"],BINDING)
	var second: Dictionary = pin(job)
	check("diamond_transaction_four_groups",second.get("groupIds",[]).size()==4 and not second.get("groupIds",[]).has("building:foundation"))
	if second.get("groupIds",[]).size()!=4: await retire(job,registry,"diamond_selection"); return
	var before: Dictionary = proof_before(job,"commit")
	complete_transaction(job,second)
	var committed: Dictionary = proof_delta(job,"commit",before)
	metrics["diamondCommit"] = committed
	check("diamond_commit_succeeds_with_internal_dependencies",job._group_receipts.size()==5 and committed.calls==1)
	if not checks.diamond_commit_succeeds_with_internal_dependencies: await retire(job,registry,"diamond_commit"); return
	check("commit_external_support_checked_once",committed.groupChecks==1 and committed.groupCacheHits==1)
	check("commit_members_checked_once",committed.memberChecks==5 and committed.transactionGroups==4)
	check("commit_shared_boundaries_checked_once",committed.boundaryChecks==2 and committed.boundaryCacheHits==3)
	before = proof_before(job,"single_receipt")
	var receipt: Dictionary = job.physical_group_receipt("building:top_a",BINDING)
	var single: Dictionary = proof_delta(job,"single_receipt",before)
	metrics["diamondReceipt"] = single
	check("diamond_receipt_ready",receipt.status=="ready")
	check("diamond_closure_groups_once",single.groupChecks==4 and single.groupCacheHits==1)
	check("diamond_closure_members_once",single.memberChecks==4)
	check("diamond_closure_boundaries_once",single.boundaryChecks==2 and single.boundaryCacheHits==2)
	before = proof_before(job,"source_requirements")
	var requirements: Dictionary = job.source_dependency_requirements(Rect2i(0,0,32,32),BINDING)
	var source: Dictionary = proof_delta(job,"source_requirements",before)
	metrics["sourceProof"] = source
	check("source_query_describes_all_groups",requirements.get("status")=="described" and requirements.get("groupIds",[]).size()==5)
	check("source_query_reuses_group_and_member_union",source.calls==1 and source.groupChecks==5 and source.memberChecks==5 and source.groupCacheHits>0)
	check("source_query_reuses_boundaries",source.boundaryChecks==2 and source.boundaryCacheHits==3)
	# Empty post-only tile facts isolate the physical receipt path; no navigation
	# publication or NavigationServer acknowledgement is claimed by this fixture.
	var tile: Dictionary = {"doors":[]}
	Controls.freeze(tile)
	var tile_override: Dictionary = {"status":"ready","binding":BINDING,"tileKey":"0,0","tile":tile}
	before = proof_before(job,"navigation_tile")
	var required: Dictionary = job._spatial.physical_group_requirements(Rect2i(0,0,16,16))
	var navigation: Dictionary = job.navigation_tile_artifact("0,0",BINDING,tile_override)
	var nav: Dictionary = proof_delta(job,"navigation_tile",before)
	metrics["navigationProof"] = nav
	check("navigation_physical_gate_ready",navigation.get("status")=="ready" and required.get("status")=="described")
	check("navigation_gate_reuses_union",nav.calls==1 and nav.groupChecks==required.get("groupIds",[]).size() and nav.memberChecks==required.get("groupIds",[]).size() and nav.groupCacheHits>0)
	verify_requirement_memo(job,tile_override,required)
	shape_and_parent_mutations(job)
	var before_repeat: Dictionary = proof_before(job,"single_receipt")
	for turn: int in range(20): job.physical_group_receipt("building:top_a",BINDING)
	var repeated: Dictionary = proof_delta(job,"single_receipt",before_repeat)
	check("separate_calls_repeat_live_checks",repeated.calls==20 and repeated.memberChecks==80 and repeated.boundaryChecks==40)
	var observed: Dictionary = job.status().physicalProof
	check("proof_metrics_bounded",observed.byKind.size()<=4 and observed.maximum.size()==Job.PROOF_COUNTERS.size()+2)
	metrics["proofTotals"] = observed
	await retire(job,registry,"diamond")
	proof_cases_completed.diamond = true

func verify_requirement_memo(job, tile_override: Dictionary, required: Dictionary) -> void:
	var bounds := Rect2i(0,0,16,16)
	var packet = job._spatial
	var valid: bool = required.get("status")=="described" and required.get("groupIds") is Array and required.get("dependencyBounds") is Array
	check("memo_exact_source_prerequisite",valid)
	if not valid: return
	var exact: PackedByteArray = var_to_bytes(required)
	var before: Dictionary = job.status().physicalProof.immutableRequirements
	var cached: Dictionary = job._navigation_physical_requirements(packet,"0,0",bounds)
	check("memo_cached_exact_ordered_typed_result",var_to_bytes(cached)==exact)
	if not cached.get("groupIds") is Array or not cached.get("dependencyBounds") is Array: return
	check("memo_private_result_deep_frozen",cached.is_read_only() and cached.groupIds.is_read_only() and cached.dependencyBounds.is_read_only())
	var caller_copy: Dictionary = cached.duplicate(true)
	caller_copy.groupIds.clear()
	caller_copy.dependencyBounds.clear()
	check("memo_caller_copy_cannot_change_retained_result",var_to_bytes(job._navigation_physical_requirements(packet,"0,0",bounds))==exact)
	var proof_start: Dictionary = proof_before(job,"navigation_tile")
	var first: Dictionary = job.navigation_tile_artifact("0,0",BINDING,tile_override)
	check("memo_artifact_prerequisite",first.get("status")=="ready" and first.get("doorBodies") is Dictionary)
	if first.get("status")!="ready" or not first.get("doorBodies") is Dictionary: return
	first.doorBodies["synthetic-caller-only"] = true
	var second: Dictionary = job.navigation_tile_artifact("0,0",BINDING,tile_override)
	var proof: Dictionary = proof_delta(job,"navigation_tile",proof_start)
	var after: Dictionary = job.status().physicalProof.immutableRequirements
	check("memo_hits_do_not_repeat_immutable_closure",after.hits-before.hits==4 and after.misses==before.misses)
	check("memo_artifact_headers_do_not_alias",second.status=="ready" and not second.doorBodies.has("synthetic-caller-only"))
	check("memo_hits_repeat_live_physical_proof",proof.calls==2 and proof.memberChecks==required.groupIds.size()*2)
	var collisions: Array = job._member_witnesses.get("building:foundation",{}).get("collisions",[])
	check("memo_live_mutation_prerequisite",collisions.size()==1 and is_instance_valid(job.own_node_root()))
	if collisions.size()!=1 or not is_instance_valid(job.own_node_root()): return
	var collision: CollisionShape3D = collisions[0].node.get_ref() as CollisionShape3D
	check("memo_live_collision_prerequisite",is_instance_valid(collision) and collision.shape is BoxShape3D)
	if not is_instance_valid(collision) or not collision.shape is BoxShape3D: return
	var original_size: Vector3 = collision.shape.size
	collision.shape.size += Vector3(0.1,0,0)
	check("memo_hit_changed_collider_still_pending",job.navigation_tile_artifact("0,0",BINDING,tile_override).status=="pending")
	collision.shape.size = original_size
	check("memo_hit_restored_collider_ready",job.navigation_tile_artifact("0,0",BINDING,tile_override).status=="ready")
	var original_transform: Transform3D = job.own_node_root().transform
	job.own_node_root().position.x += 1.0
	check("memo_hit_changed_root_still_pending",job.navigation_tile_artifact("0,0",BINDING,tile_override).status=="pending")
	job.own_node_root().transform = original_transform
	check("memo_hit_restored_root_ready",job.navigation_tile_artifact("0,0",BINDING,tile_override).status=="ready")
	for field: String in ["parts","cells","publication_groups","binding"]:
		var original: Dictionary = packet.get(field)
		var replacement: Dictionary = original.duplicate(true)
		Controls.freeze(replacement)
		var misses: int = job._physical_requirement_metrics.misses
		packet.set(field,replacement)
		var changed: Dictionary = job._navigation_physical_requirements(packet,"0,0",bounds)
		check("memo_"+field+"_identity_replacement_misses",job._physical_requirement_metrics.misses==misses+1 and var_to_bytes(changed)==exact)
		packet.set(field,original)
		job._navigation_physical_requirements(packet,"0,0",bounds)
	var old_origin: Vector3 = packet.origin
	packet.origin += Vector3.ONE
	var origin_misses: int = job._physical_requirement_metrics.misses
	check("memo_origin_replacement_exact",var_to_bytes(job._navigation_physical_requirements(packet,"0,0",bounds))==var_to_bytes(packet.physical_group_requirements(bounds)) \
		and job._physical_requirement_metrics.misses==origin_misses+1)
	packet.origin = old_origin
	job._navigation_physical_requirements(packet,"0,0",bounds)
	var replacement_packet = Preparation.SpatialDependencies.new()
	for field: String in ["parts","cells","publication_groups","binding","origin","navigation","furnishing_navigation","navigation_tiles","solid_records"]:
		replacement_packet.set(field,packet.get(field))
	job._spatial = replacement_packet
	var packet_misses: int = job._physical_requirement_metrics.misses
	check("memo_packet_replacement_misses",job.navigation_tile_artifact("0,0",BINDING,tile_override).status=="ready" \
		and job._physical_requirement_metrics.misses==packet_misses+1)
	job._spatial = packet
	job._navigation_physical_requirements(packet,"0,0",bounds)
	check("memo_owner_change_permanently_uses_exact_fallback",job._physical_requirement_memo.disabled \
		and job._physical_requirement_metrics.ownerChanges==1 and job._physical_requirement_memo.retainedEntries==1)
	var capacity_job = Job.new()
	for index: int in range(Job.MAX_PHYSICAL_REQUIREMENT_TILES):
		if capacity_job._physical_requirement_memo.retainedEntries>=Job.MAX_PHYSICAL_REQUIREMENT_TILES: break
		var tile := Vector2i(1000+index,0)
		capacity_job._navigation_physical_requirements(packet,"%d,0"%tile.x,Rect2i(tile*16,Vector2i.ONE*16))
	check("memo_retained_entry_limit_reached",capacity_job._physical_requirement_memo.retainedEntries==Job.MAX_PHYSICAL_REQUIREMENT_TILES)
	var fallback_bounds := Rect2i(80000,0,16,16)
	var fallback_exact: PackedByteArray = var_to_bytes(packet.physical_group_requirements(fallback_bounds))
	var fallback_count: int = capacity_job._physical_requirement_metrics.capacityFallbacks
	for turn: int in range(2):
		check("memo_capacity_exact_fallback_"+str(turn),var_to_bytes(capacity_job._navigation_physical_requirements(packet,"5000,0",fallback_bounds))==fallback_exact)
	check("memo_capacity_never_retains_or_omits",capacity_job._physical_requirement_memo.retainedEntries==Job.MAX_PHYSICAL_REQUIREMENT_TILES \
		and capacity_job._physical_requirement_metrics.capacityFallbacks==fallback_count+2)
	var oversized = OversizedRequirements.new()
	for field: String in ["parts","cells","publication_groups","binding"]: oversized.set(field,packet.get(field))
	oversized.values.resize(Job.MAX_PHYSICAL_REQUIREMENT_VALUES+1)
	oversized.values.fill(7)
	var oversized_job = Job.new()
	for turn: int in range(2):
		var actual: Dictionary = oversized_job._navigation_physical_requirements(oversized,"0,0",bounds)
		check("memo_oversized_exact_fallback_"+str(turn),actual.syntheticOversizedValues==oversized.values and actual.groupIds.is_empty())
	check("memo_value_limit_retains_nothing",oversized.calls==2 and oversized_job._physical_requirement_memo.retainedEntries==0 \
		and oversized_job._physical_requirement_memo.retainedValues==0 and oversized_job._physical_requirement_metrics.capacityFallbacks==2)
	metrics["immutableRequirementMemo"] = job.status().physicalProof.immutableRequirements
	metrics["capacityRequirementMemo"] = capacity_job.status().physicalProof.immutableRequirements
	metrics["oversizedRequirementMemo"] = oversized_job.status().physicalProof.immutableRequirements
	check("memo_payload_owns_only_original_source",is_same(job._cpu.physicalRequirementMemo,job._physical_requirement_memo) \
		and job._physical_requirement_memo.owner.packet==packet and job._physical_requirement_memo.retainedValues<=Job.MAX_PHYSICAL_REQUIREMENT_VALUES)
	proof_cases_completed.memo = true


func memo_door_mutations() -> void:
	var blueprint = Blueprint.new("memo-door",3,"timber")
	blueprint.add_part({"id":"door","kind":"door","material":"timber_board","size":Vector3(1.2,2.2,0.12),"position":Vector3(0,1.1,0)})
	var registry = RegistryFixture.new()
	var job = await start(blueprint,Plan.new("memo-door-furniture",1,blueprint.id),registry)
	if job==null: return
	complete_site(job)
	check("memo_door_real_registration_prerequisite",job.status().sceneReady and registry.doors.size()==1)
	if not job.status().sceneReady or registry.doors.size()!=1: await retire(job,registry,"memo_door_setup"); return
	var tile: Dictionary = {"doors":[{"sourcePartId":"door"}]}
	Controls.freeze(tile)
	var override: Dictionary = {"status":"ready","binding":BINDING,"tileKey":"0,0","tile":tile}
	check("memo_door_initial_ready",job.navigation_tile_artifact("0,0",BINDING,override).status=="ready")
	var body: StaticBody3D = registry.doors.values()[0].get_ref() as StaticBody3D
	check("memo_door_body_prerequisite",is_instance_valid(body))
	if not is_instance_valid(body): await retire(job,registry,"memo_door_body"); return
	var portal_id: String = body.get_meta("door_portal_id","")
	body.set_meta("door_portal_id",portal_id+"-changed")
	check("memo_hit_changed_door_identity_rejected",job.navigation_tile_artifact("0,0",BINDING,override).status=="pending")
	body.set_meta("door_portal_id",portal_id)
	check("memo_hit_restored_door_identity_ready",job.navigation_tile_artifact("0,0",BINDING,override).status=="ready")
	var original: Transform3D = body.transform
	body.rotation.y += 0.4
	check("memo_keeps_moving_door_exception",job.navigation_tile_artifact("0,0",BINDING,override).status=="ready")
	body.transform = original
	check("memo_door_queries_hit_cache",job.status().physicalProof.immutableRequirements.hits>=3)
	await retire(job,registry,"memo_door")
	proof_cases_completed.memo_door = true


func atomic_failure() -> void:
	var blueprint = Blueprint.new("proof-atomic",2,"timber")
	post(blueprint,"alpha",0.0)
	post(blueprint,"beta",3.0,["alpha"])
	var registry = RegistryFixture.new()
	var job = await start(blueprint,Plan.new("proof-atomic-furniture",1,blueprint.id),registry)
	if job==null: return
	job.request_publication_groups(["building:beta"],BINDING)
	var transaction: Dictionary = pin(job)
	check("atomic_internal_dependency_selected",transaction.get("groupIds")==["building:alpha","building:beta"])
	if transaction.get("groupIds")!=["building:alpha","building:beta"]: await retire(job,registry,"atomic_selection"); return
	# Direct phase steps intentionally stop before the one nonyielding commit.
	for turn: int in range(20000):
		if job._phase=="group_commit" or job.status().status in ["failed","cancelled"]: break
		job._step(2500)
	check("atomic_commit_precondition",job._phase=="group_commit" and job._group_receipts.is_empty())
	if job._phase!="group_commit": await retire(job,registry,"atomic_staging"); return
	var collisions: Array = job._member_witnesses.get("building:beta",{}).get("collisions",[])
	check("atomic_collision_witness_precondition",collisions.size()==1)
	if collisions.size()!=1: await retire(job,registry,"atomic_collision"); return
	var collision: CollisionShape3D = collisions[0].node.get_ref() as CollisionShape3D
	check("atomic_collision_node_precondition",is_instance_valid(collision))
	if not is_instance_valid(collision): await retire(job,registry,"atomic_collision_node"); return
	collision.disabled = true
	check("atomic_last_member_failure",not job._commit_transaction() and job.status().reason=="publication_group_member_incomplete:building:beta")
	check("atomic_failure_publishes_no_receipts",job._group_receipts.is_empty())
	await retire(job,registry,"atomic")
	proof_cases_completed.atomic = true

func _run() -> void:
	parent = Node3D.new()
	root.add_child(parent)
	worker = Worker.new()
	await diamond_and_shared_boundary()
	await memo_door_mutations()
	await atomic_failure()
	worker.request_shutdown()
	var deadline: int = Time.get_ticks_msec()+5000
	while not worker.poll().shutdownComplete and Time.get_ticks_msec()<deadline: await process_frame
	check("worker_shutdown",worker.poll().shutdownComplete)
	parent.free()
	for name: String in proof_cases_completed: check(name+"_case_completed",bool(proof_cases_completed[name]))
	var complete: bool = not proof_cases_completed.values().has(false) and bool(checks.get("worker_shutdown",false)) and not is_instance_valid(parent)
	var report: Dictionary = {"schema":"building-scene-proof-context-contract/v1","complete":complete,
		"passed":complete and not checks.values().has(false),"checks":checks,"metrics":metrics,
		"evidence":"synthetic_scene_publication_receipt_validation",
		"doesNotProve":"No generated-world, navigation, live gameplay or runtime performance acceptance."}
	var file: FileAccess = FileAccess.open(OS.get_environment("BUILDING_SCENE_PROOF_CONTEXT_REPORT"),FileAccess.WRITE)
	if file==null: push_error("scene_proof_report_unavailable"); quit(1); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("SCENE PROOF ",JSON.stringify(report))
	quit(0 if report.passed else 1)
