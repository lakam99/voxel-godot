extends SceneTree
## Synthetic orchestration only: tiny real publishers, synthetic prepared proofs
## and tree callback. Not source preparation, live trees, doors, or gameplay.
const Job = preload("res://scripts/buildings/BuildingScenePublicationJob.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const Fixtures = preload("res://scripts/testing/buildings/BuildingPublicationWorkerContract.gd")

class InvalidatingMasonryPublisher extends "res://scripts/buildings/BuildingPartPublisher.gd":
	var hook := "collect"
	var mutation := false
	var fired := false
	var light_calls := 0
	func invalidate() -> void:
		fired=true
		if mutation: _pending_masonry.source_part().size.x+=0.25
		else: _paving_reject("synthetic_hook_rejection")
	func collect_static_visual_transform(transform: Transform3D, material: Material, custom_data := Color(0.5,0.5,0.5,1.0)) -> void:
		super.collect_static_visual_transform(transform,material,custom_data)
		if not fired and hook=="collect" and _pending_masonry!=null and _pending_masonry.state=="collect": invalidate()
	func publish_practical_light(part, target: Node3D) -> void:
		light_calls+=1
		super.publish_practical_light(part,target)
		if not fired and hook=="light": invalidate()

class RoofCancellationPublisher extends "res://scripts/buildings/BuildingPartPublisher.gd":
	var cancellation_target: WeakRef
	var collect_calls := 0
	func collect_static_visual_transform(transform: Transform3D, material: Material, custom_data := Color(0.5,0.5,0.5,1.0)) -> void:
		super.collect_static_visual_transform(transform,material,custom_data)
		collect_calls+=1
		if cancellation_target!=null: cancellation_target.get_ref().cancel()

class SyntheticTrees extends RefCounted:
	var published := 0
	var retired := 0
	var retired_ids: Dictionary = {}
	var retire_before_free := true
	var visual_state := "published"
	var defer_once := false
	var calls := 0
	var cancel_target: WeakRef
	var second_pending := false
	var bodies: Array[WeakRef] = []
	func publish(parent: Node3D, id: String, position: Vector3, _biome: String, _request: Dictionary, yaw: float) -> Dictionary:
		calls += 1
		if defer_once:
			defer_once = false
			return {"status":"deferred", "reason":"synthetic_overlap"}
		var body := StaticBody3D.new()
		body.position = position
		body.rotation.y = yaw
		body.set_meta("prop_id", id)
		var state := "queued" if second_pending and published == 1 else visual_state
		body.set_meta("tree_visual_state", state)
		parent.add_child(body)
		if state == "published":
			var visual := Node3D.new()
			visual.name = "GeneratedTreeVisual"
			body.add_child(visual)
		published += 1
		bodies.append(weakref(body))
		if cancel_target != null: cancel_target.get_ref().cancel()
		return {"status":"published", "reason":"visual_queued", "body":body}
	func retire(id: String, body: StaticBody3D) -> void:
		retire_before_free = retire_before_free and is_instance_valid(body) and body.get_parent() != null
		retired += 1
		retired_ids[id] = int(retired_ids.get(id, 0)) + 1

class FinishCanceller extends RefCounted:
	var target: WeakRef
	var calls := 0
	func progress(record: Dictionary) -> void:
		calls += 1
		if record.get("reason") == "complete": target.get_ref().cancel()

var checks: Dictionary = {}
var worker = Worker.new()
var parent: Node3D

func _initialize() -> void: call_deferred("_run")

func check(label: String, value: bool) -> void:
	checks[label] = value
	if not value: print("SCENE JOB CONTRACT FAILURE ", label)

func holder() -> Preparation.PreparedSource:
	var blueprint = Blueprint.new("synthetic-publication", 1, "timber")
	blueprint.add_part({"id":"tiny-post", "kind":"post", "material":"timber_beam",
		"size":Vector3(0.2, 1.0, 0.2), "position":Vector3(0, 0.5, 0)})
	blueprint.recipe["landscapeTrees"] = [
		{"id":"a", "position":Vector3(2, 0, 0), "rotationY":0.0, "treeRequest":{"biome":"town"}},
		{"id":"b", "position":Vector3(4, 0, 0), "rotationY":0.0, "treeRequest":{"biome":"town"}}]
	var result := Preparation.PreparedSource.new()
	result._binding = Fixtures.BINDING
	result._payload = {"blueprint":blueprint, "furnishingPlan":Plan.new("tiny", 1, blueprint.id),
		"physicalIntegrity":{"passed":true}, "raisedRouteCoverage":{"passed":true},
		"preparationUsec":0, "routeUsec":0, "physicalUsec":0}
	return result

func frozen_profile() -> Dictionary:
	var profile: Dictionary = Fixtures.profile()
	profile.origin = Vector3(10, 0, 20)
	Fixtures.freeze(profile)
	return profile

func start(job, trees, prepared = null, binding: Dictionary = Fixtures.BINDING) -> void:
	if prepared == null: prepared = holder()
	job.set_tree_retire_callback(trees.retire)
	job.begin(prepared, frozen_profile(), binding, parent, trees.publish)

func drain(job, label: String) -> void:
	for index in range(1000):
		if job.status().retirementReady: break
		job.advance(4000)
	check(label + "_nodes_gone", job.own_node_root() == null and job.status().retirementReady)
	var payload: Dictionary = job.take_retirement_payload()
	check(label + "_retirement_once", not payload.is_empty() and job.take_retirement_payload().is_empty())
	worker.retire_external_payload(payload)
	payload = {}
	# The wrapper is the process watchdog; this is only a bounded worker drain.
	var deadline := Time.get_ticks_msec() + 5000
	while worker.poll().busy and Time.get_ticks_msec() < deadline: await process_frame
	check(label + "_worker_drained", not worker.poll().busy)

## Real pending publisher helpers on synthetic geometry. The static-flush case
## injects a labelled threshold-sized transform batch, not a generated building.
func pending_holder(paving: bool) -> Preparation.PreparedSource:
	var prepared := holder()
	var blueprint = prepared._payload.blueprint
	blueprint.parts.clear()
	if paving:
		blueprint.add_part({"id":"pending-paving", "kind":"foundation", "material":"cobblestone",
			"collision":true, "size":Vector3(24, 0.12, 18), "position":Vector3(0, 0.1, 0),
			"recipe":{"pavingFamily":"civic_setts", "pavingHeading":"x"}})
	else:
		blueprint.add_part({"id":"flush-trigger", "kind":"post", "material":"timber_beam",
			"size":Vector3(0.2, 1.0, 0.2), "position":Vector3(0, 0.5, 0)})
	blueprint.add_part({"id":"after-pending", "kind":"post", "material":"timber_beam",
		"size":Vector3(0.2, 1.0, 0.2), "position":Vector3(2, 0.5, 0)})
	return prepared

func inject_synthetic_flush_threshold(job) -> void:
	# One unchanged, explicitly synthetic batch at the production threshold.
	var transforms: Array[Transform3D] = []
	transforms.resize(job._building.INCREMENTAL_STATIC_BATCH_INSTANCE_LIMIT)
	transforms.fill(Transform3D.IDENTITY)
	var custom: Array[Color] = []
	custom.resize(transforms.size())
	custom.fill(Color(0.5, 0.5, 0.5, 1.0))
	job._building.static_visual_batches["synthetic-threshold"] = {
		"material":job._building.material_for_id("timber_beam", 0.0),
		"transforms":transforms, "customData":custom}
	job._building.static_visual_transform_count = transforms.size()

func pending_masonry_holder() -> Preparation.PreparedSource:
	var prepared:=pending_holder(false)
	prepared._payload.blueprint.parts[0]=Blueprint.BuildingPartScript.new({"id":"pending-masonry","kind":"wall","material":"stone_foundation","size":Vector3(6,8,0.4),"recipe":{"practicalLight":true}})
	return prepared

func pending_roof_holder() -> Preparation.PreparedSource:
	var prepared:=pending_holder(false)
	prepared._payload.blueprint.parts[0]=Blueprint.BuildingPartScript.new({"id":"pending-roof","kind":"roof","material":"roof_slate","size":Vector3(18,0.15,14),"recipe":{"practicalLight":true}})
	return prepared

func pending_target_reached(job, target: String) -> bool:
	if job._building == null: return false
	if target.begins_with("roof_"):
		var roof=job._building._pending_roof
		if roof==null: return false
		if target=="roof_tiles":
			return roof.state=="geometry" and roof._cursor!=null and roof._cursor.state=="tiles" \
				and roof._cursor._transforms.size()+roof._cursor._weathered_transforms.size()>0
		return roof.state=="collect" and roof._index>0 and roof._index<roof._active.size()
	if target.begins_with("masonry_"):
		var masonry=job._building._pending_masonry
		if masonry==null: return false
		if target=="masonry_geometry": return masonry.state=="geometry" and masonry._cursor!=null
		if target=="masonry_packet_collect": return masonry.state=="packet_collect" and masonry._packet_index>0 and masonry._packet_index<masonry._packet_segments.size()
		return masonry.state=="collect" and masonry._batch_index>0 and masonry._batch_index<masonry._transforms.size()
	if target == "static_flush":
		var flush = job._building._static_flush
		return flush != null and flush.state == "instances" \
			and flush._transforms.size() >= job._building.INCREMENTAL_STATIC_BATCH_INSTANCE_LIMIT \
			and flush._instance_index > 0 and flush._instance_index < flush._transforms.size()
	var paving = job._building._pending_paving
	if paving == null: return false
	if target == "paving_geometry":
		return paving.state == "geometry" and paving._cursor != null \
			and paving._cursor.status().status == "pending_budget" \
			and paving._cursor.regular_ids.size() + paving._cursor.worn_ids.size() > 0
	return paving.state == "upload" and paving._upload != null \
		and paving._upload.state == "instances" and paving._upload._cursor > 0 \
		and paving._upload._cursor < paving._upload._transforms.size()

func collision_count_for(job, id: String) -> int:
	var site: Node3D = job.own_node_root()
	if site == null: return 0
	var count := 0
	for node: Node in site.find_children("*", "CollisionShape3D", true, false):
		if node.get_meta("building_part_id", "") == id and node.get_meta("building_collision_role", "") == "blocking_part": count += 1
	return count

func pending_progress(job) -> Dictionary:
	var publisher = job._building
	var result := {"parts":publisher.published_part_count, "accepted":publisher.incremental_published_parts,
		"collisions":publisher.collision_count, "visuals":publisher.visual_batch_count,
		"cursor":job.status().buildingCursor, "stages":publisher._publication_stage_metrics.duplicate(true)}
	if publisher._pending_paving != null:
		var paving = publisher._pending_paving
		result.pavingState = paving.state
		if paving._cursor != null: result.geometryUnits = paving._cursor.status().units
		if paving._upload != null: result.uploadCursor = paving._upload._cursor
	if publisher._static_flush != null:
		result.flushState = publisher._static_flush.state
		result.flushUnits = publisher._static_flush.units
		result.flushCursor = publisher._static_flush._instance_index
	if publisher._pending_masonry!=null:
		result.masonryState=publisher._pending_masonry.state
		result.masonryCollect=publisher._pending_masonry._batch_index
	if publisher._pending_roof!=null:
		var roof=publisher._pending_roof
		# cancel() intentionally changes helper states; only submission/progress
		# counters must remain unchanged while teardown retires its allocations.
		result.roofCollect=roof._index
		if roof._cursor!=null:
			result.roofGeometryCount=roof._cursor._transforms.size()+roof._cursor._weathered_transforms.size()
	return result

func watch_pending_resources(job) -> Dictionary:
	# Weak references only: this audit must not itself keep Resources alive.
	var publisher = job._building
	var watched := {"publisher":weakref(publisher), "unitMesh":weakref(publisher.unit_box)}
	for key: String in publisher.material_cache:
		watched["material:" + key] = weakref(publisher.material_cache[key])
	if publisher._pending_paving != null:
		var paving = publisher._pending_paving
		watched.paving = weakref(paving)
		if paving._cursor != null: watched.geometry = weakref(paving._cursor)
		if paving._upload != null:
			watched.upload = weakref(paving._upload)
			if paving._upload._multi != null: watched.pendingMultiMesh = weakref(paving._upload._multi)
	if publisher._static_flush != null:
		watched.flush = weakref(publisher._static_flush)
		if publisher._static_flush._mesh != null: watched.pendingMultiMesh = weakref(publisher._static_flush._mesh)
	if publisher._pending_masonry!=null:
		watched.masonry=weakref(publisher._pending_masonry)
		if publisher._pending_masonry._cursor!=null: watched.geometry=weakref(publisher._pending_masonry._cursor)
	if publisher._pending_roof!=null:
		watched.roof=weakref(publisher._pending_roof)
		if publisher._pending_roof._cursor!=null: watched.roofGeometry=weakref(publisher._pending_roof._cursor)
	return watched

func pending_cancellation_case(target: String) -> void:
	var trees := SyntheticTrees.new()
	var job = Job.new()
	start(job, trees, pending_roof_holder() if target.begins_with("roof_") else (pending_masonry_holder() if target.begins_with("masonry_") else pending_holder(target != "static_flush")))
	job.advance(1) # Establish real publishers; begin itself consumed no part.
	if target == "static_flush": inject_synthetic_flush_threshold(job)
	for index in range(10000):
		if pending_target_reached(job, target): break
		job.advance(1)
		if job.status().status in ["failed", "ready"]: break
	check(target + "_pending_reached", pending_target_reached(job, target))
	if not pending_target_reached(job, target):
		job.cancel()
		await drain(job, target + "_setup_failed")
		return
	var part_id := "pending-roof" if target.begins_with("roof_") else ("pending-masonry" if target.begins_with("masonry_") else ("flush-trigger" if target == "static_flush" else "pending-paving"))
	var expected_cursor := 1 if target == "static_flush" else 0
	check(target + "_one_initial_collider", collision_count_for(job, part_id) == 1 and job._building.collision_count == 1)
	check(target + "_next_part_not_submitted", collision_count_for(job, "after-pending") == 0 and job.status().buildingCursor == expected_cursor)
	if target.begins_with("roof_"):
		var finish: Dictionary=job._building.finish_scene_publication(job._blueprint,job.own_node_root(),1)
		check(target+"_finish_waits",finish.status=="pending_budget" and not finish.complete)
	# Retry the same pending cursor several times: neither collision creation nor
	# source submission is repeated while geometry/upload/flush makes progress.
	for index in range(6): job.advance(1)
	check(target + "_retries_do_not_duplicate_collision", collision_count_for(job, part_id) == 1 and job._building.collision_count == 1 and job._building.published_part_count == 1)
	check(target + "_cursor_stays_pending", pending_target_reached(job, target) and job.status().buildingCursor == expected_cursor)
	var watched := watch_pending_resources(job)
	if target in ["paving_upload","static_flush"]: check(target + "_allocated_resource_under_test", watched.has("pendingMultiMesh"))
	var before := var_to_bytes(pending_progress(job))
	job.cancel()
	check(target + "_cancel_immediate", job.status().status == "cancelled" and not job.status().sceneReady and not job.status().gameplayReady)
	var leaf_only := true
	var ever_ready := false
	for index in range(10000):
		if job.status().retirementReady: break
		# Pure unit control avoids timing-dependent packing: one teardown step
		# descends or frees one leaf, never recursively frees an owned subtree.
		var site: Node3D = job.own_node_root()
		var prior_nodes := site.find_children("*", "", true, false).size() + 1 if site != null else 0
		var prior_freed: int = job.status().freedNodes
		job._step(1)
		site = job.own_node_root()
		var next_nodes := site.find_children("*", "", true, false).size() + 1 if site != null else 0
		leaf_only = leaf_only and prior_nodes - next_nodes <= 1 and job.status().freedNodes - prior_freed <= 1
		ever_ready = ever_ready or job.status().sceneReady
	check(target + "_leaf_cleanup", leaf_only and job.own_node_root() == null and job.status().retirementReady)
	check(target + "_no_later_submissions", before == var_to_bytes(pending_progress(job)) and trees.calls == 0)
	check(target + "_never_ready_after_cancel", not ever_ready and not job.status().sceneReady)
	var retained := true
	for reference: WeakRef in watched.values(): retained = retained and reference.get_ref() != null
	check(target + "_resources_retained_until_handoff", retained)
	await drain(job, target)
	await process_frame
	var released := true
	for reference: WeakRef in watched.values(): released = released and reference.get_ref() == null
	check(target + "_resources_released_after_worker_retirement", released)

func pending_completion_control() -> void:
	var trees := SyntheticTrees.new()
	var job = Job.new()
	start(job, trees, pending_holder(true))
	var pending_observed := false
	for index in range(10000):
		job.advance(2500)
		if job._building != null and job._building._pending_paving != null: pending_observed = true
		if job.status().status in ["ready", "failed"]: break
	check("pending_success_observed_and_completed", pending_observed and job.status().sceneReady)
	check("pending_success_cursor_exact", job.status().buildingCursor == 2 and job._building.published_part_count == 2 and job._building.incremental_published_parts == 2)
	check("pending_success_collision_exact_once", job._building.collision_count == 2 and collision_count_for(job, "pending-paving") == 1 and collision_count_for(job, "after-pending") == 1)
	check("pending_success_trees_after_building", trees.calls == 2 and job.status().treeVisualsComplete == 2)
	job.cancel()
	await drain(job, "pending_success")
	check("pending_success_tree_retirement", trees.retired == 2 and trees.retired_ids.values() == [1, 1])

func paving_binding_mutation_controls() -> void:
	# Real mutable paving source: reject changes both during geometry publication
	# and after paving completed but before the final metadata commit.
	for phase: String in ["pending", "final"]:
		for change: String in ["value", "type", "order"]:
			var prepared := pending_holder(true)
			prepared._payload.blueprint.parts[0].size=Vector3(3,0.12,3)
			prepared._payload.blueprint.parts[0].recipe["bindingFixture"]={"one":1,"two":2}
			var trees:=SyntheticTrees.new()
			var job:=Job.new()
			start(job,trees,prepared)
			prepared=null
			var reached:=false
			for index in range(10000):
				job.advance(1)
				reached=job._building!=null and (job._building._pending_paving!=null if phase=="pending" else job.status().phase=="building_finish")
				if reached or job.status().status in ["ready","failed"]: break
			var label:="paving_binding_"+phase+"_"+change
			check(label+"_boundary_reached",reached)
			if reached:
				var body=job._building.static_collision_body
				var had_metadata: bool=body.has_meta("building_part_records")
				var previous: Variant=body.get_meta("building_part_records") if had_metadata else null
				var part=job._blueprint.parts[0]
				match change:
					"value": part.recipe.bindingFixture.one=3
					"type": part.recipe.bindingFixture.one=1.0
					"order":
						part.recipe.bindingFixture.erase("one")
						part.recipe.bindingFixture.one=1
				for index in range(10000):
					job.advance(1)
					if job.status().status in ["ready","failed"]: break
				check(label+"_rejected",job.status().status=="failed" and not job.status().sceneReady)
				check(label+"_binding_guard",job._building._paving_failure==("stale_paving_part" if phase=="pending" else "stale_completed_paving_source"))
				check(label+"_metadata_not_replaced",body.has_meta("building_part_records")==had_metadata and (not had_metadata or is_same(previous,body.get_meta("building_part_records"))))
				check(label+"_no_furniture_or_trees",job._furniture==null and trees.calls==0)
				body=null; part=null; previous=null
			job.cancel()
			await drain(job,label)

func masonry_completion_control() -> void:
	var trees:=SyntheticTrees.new()
	var job=Job.new()
	start(job,trees,pending_masonry_holder())
	var pending_seen:=false
	for index in range(10000):
		job.advance(2500)
		if job._building!=null and job._building._pending_masonry!=null: pending_seen=true
		if job.status().status in ["ready","failed"]: break
	check("masonry_success_pending_and_complete",pending_seen and job.status().sceneReady)
	check("masonry_success_exact_cursor",job.status().buildingCursor==2 and job._building.incremental_published_parts==2)
	check("masonry_success_single_collision",collision_count_for(job,"pending-masonry")==1 and job._building.collision_count==2)
	check("masonry_success_deferred_light_once",job.own_node_root().find_children("*","OmniLight3D",true,false).size()==1)
	job.cancel()
	await drain(job,"masonry_success")

func roof_reentrant_job_cancellation() -> void:
	# Synthetic ownership setup, real helper -> collection hook -> Job.cancel.
	# Proves the same call stops; it is not ordinary-world activation evidence.
	var publisher:=RoofCancellationPublisher.new()
	var job=Job.new()
	job._phase="building"
	job._building=publisher
	publisher.cancellation_target=weakref(job)
	publisher.source_blueprint_id="roof-cancellation"
	var part=Blueprint.BuildingPartScript.new({"id":"pending-roof","kind":"roof","material":"roof_slate","size":Vector3(8,0.15,6)})
	var helper=publisher.RoofPublication.new(part,parent,Transform3D.IDENTITY,true,publisher.source_blueprint_id)
	publisher._pending_roof=helper
	for index in range(10000):
		helper.advance(publisher,2500)
		if publisher.collect_calls>0: break
	check("roof_reentrant_job_cancelled",job.status().status=="cancelled" and job.status().phase=="teardown")
	check("roof_reentrant_one_submission",publisher.collect_calls==1)
	helper.advance(publisher,4000)
	check("roof_reentrant_no_later_submission",publisher.collect_calls==1 and helper.state=="failed")
	publisher.clear_published()
	job._building=null

func roof_lifecycle_controls() -> void:
	roof_reentrant_job_cancellation()
	var trees:=SyntheticTrees.new()
	var job=Job.new()
	start(job,trees,pending_roof_holder())
	var pending_seen:=false
	for index in range(10000):
		job.advance(2500)
		if job._building!=null and job._building._pending_roof!=null: pending_seen=true
		if job.status().status in ["ready","failed"]: break
	check("roof_success_pending_and_complete",pending_seen and job.status().sceneReady)
	check("roof_success_exact_cursor",job.status().buildingCursor==2 and job._building.incremental_published_parts==2)
	check("roof_success_single_collision",collision_count_for(job,"pending-roof")==1 and job._building.collision_count==2)
	check("roof_success_deferred_light_once",job.own_node_root().find_children("*","OmniLight3D",true,false).size()==1)
	check("roof_success_trees_after_building",trees.calls==2)
	job.cancel()
	await drain(job,"roof_success")
	for mode: String in ["mutation","replacement","cursor"]:
		trees=SyntheticTrees.new()
		job=Job.new()
		start(job,trees,pending_roof_holder())
		for index in range(1000):
			job.advance(1)
			if pending_target_reached(job,"roof_tiles"): break
		check("roof_"+mode+"_pending_reached",pending_target_reached(job,"roof_tiles"))
		if mode=="mutation": job._blueprint.parts[0].size.x+=0.1
		elif mode=="replacement": job._blueprint.parts[0]=Blueprint.BuildingPartScript.new(job._blueprint.parts[0].snapshot())
		else: job._building_cursor=1
		job.advance(1)
		check("roof_"+mode+"_failed_not_ready",job.status().status=="failed" and not job.status().sceneReady and trees.calls==0)
		check("roof_"+mode+"_no_second_collision",job._building.collision_count==1)
		await drain(job,"roof_"+mode)

func masonry_hook_controls() -> void:
	# Synthetic fault injection through real publisher hooks. The cursor below
	# is the publisher's acceptance result, not a claim of live-world readiness.
	for hook: String in ["collect","light"]:
		for mutation: bool in [false,true]:
			var publisher:=InvalidatingMasonryPublisher.new()
			publisher.hook=hook; publisher.mutation=mutation
			var target:=Node3D.new()
			parent.add_child(target)
			var result: Dictionary=publisher.begin_prepared_publication(pending_masonry_holder(),target,Fixtures.BINDING,{"batchStaticParts":true,"resumableScenePublication":true})
			var cursor:=0
			for index in range(10000):
				var preparation: Dictionary=publisher.advance_scene_preparation(2500)
				if preparation.status=="ready": break
				if preparation.status=="failed": break
			for index in range(10000):
				cursor=publisher.publish_part_batch(result.blueprint,target,cursor,1,2500)
				if publisher._publication_failed() or cursor>0: break
			var label:="masonry_hook_"+hook+("_mutation" if mutation else "_reject")
			check(label+"_fired",publisher.fired)
			check(label+"_failed_without_acceptance",publisher._publication_failed() and cursor==0 and publisher.incremental_published_parts==0 and publisher._pending_masonry.state=="failed")
			check(label+"_light_boundary",publisher.light_calls==(1 if hook=="light" else 0))
			check(label+"_no_following_part",publisher.published_part_count==1 and publisher.collision_count==1)
			var lights:=target.find_children("*","OmniLight3D",true,false)
			check(label+"_created_light_owned",lights.size()==(1 if hook=="light" else 0))
			var references: Array[WeakRef]=[]
			for light: Node in lights: references.append(weakref(light))
			lights=[]
			target.free()
			var gone:=true
			for reference: WeakRef in references: gone=gone and reference.get_ref()==null
			check(label+"_light_cleanup",gone)
			publisher=null

func prepared_history_holder() -> Preparation.PreparedSource:
	var prepared:=pending_masonry_holder()
	var result: Dictionary=Preparation._compile_history(prepared._payload.blueprint)
	prepared._payload.preparedHistory=result.preparedHistory
	return prepared

func prepared_masonry_holder(unsupported := false) -> Preparation.PreparedSource:
	var prepared:=prepared_history_holder()
	if unsupported: prepared._payload.blueprint.parts[0].recipe["unsupportedExtra"]=PackedInt32Array([1,2])
	var result: Dictionary=Preparation._compile_masonry(prepared._payload.blueprint,prepared._payload.preparedHistory)
	prepared._payload.preparedMasonry=result.preparedMasonry
	return prepared

func prepared_masonry_observation(job) -> Dictionary:
	# Keep the test's publisher/descriptor aliases inside this synchronous helper
	# so neither can survive across the worker-retirement await in the caller.
	var publisher=job._building
	var pending=publisher._pending_masonry
	return {"certificate":weakref(publisher._prepared_masonry),"publisher":weakref(publisher),
		"borrowed":pending!=null and pending._cursor==null and pending._geometry.is_read_only(),
		"packetSealed":pending!=null and pending._packet!=null and pending._packet.is_read_only()}

func prepared_masonry_controls() -> void:
	for mode: String in ["part_size","part_id","part_replace","missing_entry","history_replace","artifact_drop"]:
		var job=Job.new()
		var trees:=SyntheticTrees.new()
		start(job,trees,prepared_masonry_holder())
		job.advance(1)
		var publisher=job._building
		var source_part=job._blueprint.parts[0]
		match mode:
			"part_size": source_part.size.x+=0.5
			"part_id": source_part.id+="-changed"
			"part_replace": job._blueprint.parts[0]=Blueprint.BuildingPartScript.new(source_part.snapshot())
			"missing_entry":
				var snapshot: Dictionary=source_part.snapshot()
				snapshot.id="new-unprepared-wall"
				job._blueprint.parts[0]=Blueprint.BuildingPartScript.new(snapshot)
			"history_replace": publisher._prepared_history=Preparation._compile_history(job._blueprint).preparedHistory
			"artifact_drop": publisher._prepared_masonry=null
		job.advance(2500)
		check("prepared_masonry_"+mode+"_fails",job.status().status=="failed" and not job.status().sceneReady)
		check("prepared_masonry_"+mode+"_before_collision",job.status().buildingCursor==0 and publisher.published_part_count==0 and publisher.collision_count==0 and publisher._pending_masonry==null)
		publisher=null; source_part=null
		await drain(job,"prepared_masonry_"+mode)
	for unsupported: bool in [false,true]:
		var job=Job.new()
		var trees:=SyntheticTrees.new()
		start(job,trees,prepared_masonry_holder(unsupported))
		var seen:=false
		var borrowed:=false
		var observed: Dictionary={}
		for index in range(10000):
			job.advance(1)
			if pending_target_reached(job,"masonry_collect" if unsupported else "masonry_packet_collect"):
				seen=true
				observed=prepared_masonry_observation(job)
				borrowed=observed.borrowed
				break
			if job.status().status in ["ready","failed"]: break
		var label:="prepared_masonry_"+("unsupported" if unsupported else "compiled")
		check(label+"_pending",seen and job.status().buildingCursor==0)
		check(label+"_correct_algorithm_path",not borrowed if unsupported else borrowed)
		job.cancel()
		await drain(job,label)
		check(label+"_released",not observed.is_empty() and observed.certificate.get_ref()==null and observed.publisher.get_ref()==null)
		check(label+"_packet_sealed",unsupported or observed.get("packetSealed",false))
	var job=Job.new()
	var trees:=SyntheticTrees.new()
	start(job,trees,prepared_masonry_holder())
	for index in range(10000):
		job.advance(2500)
		if job.status().status in ["ready","failed"]: break
	check("prepared_masonry_complete",job.status().sceneReady and job.status().buildingCursor==2)
	check("prepared_masonry_no_main_descriptor",not job._building.publication_timing().has("masonry_publish_geometry") and job._building.publication_timing().get("prepared_masonry_lookup",{}).get("calls",0)==1)
	check("prepared_masonry_complete_collision_light",job._building.collision_count==2 and job.own_node_root().find_children("*","OmniLight3D",true,false).size()==1)
	job.cancel()
	await drain(job,"prepared_masonry_success")

func prepared_history_lifecycle_controls() -> void:
	for change: String in ["none","object","routes","trees","events","cells"]:
		var trees:=SyntheticTrees.new()
		var job=Job.new()
		start(job,trees,prepared_history_holder())
		job.advance(1)
		var publisher=job._building
		var history=publisher.surface_history
		var certificate: WeakRef=weakref(publisher._prepared_history)
		var retained_history: WeakRef=weakref(history)
		check("prepared_history_"+change+"_adopted",publisher._prepared_history!=null and publisher.validate_paving_history_source() and history.route_corridors.is_read_only())
		match change:
			"object": publisher.surface_history=publisher.SurfaceHistoryFieldScript.new()
			"routes": history.route_corridors=history.route_corridors.duplicate(true)
			"trees": history.tree_placements=history.tree_placements.duplicate(true)
			"events": history.history_events=history.history_events.duplicate(true)
			"cells": history.history_event_cells=history.history_event_cells.duplicate(true)
		if change!="none":
			check("prepared_history_"+change+"_rejects",not publisher.validate_paving_history_source())
			job.advance(2500)
			check("prepared_history_"+change+"_no_ready",job.status().status=="failed" and not job.status().sceneReady and job.status().buildingCursor==0)
		else: job.cancel()
		history=null; publisher=null
		await drain(job,"prepared_history_"+change)
		check("prepared_history_"+change+"_released",certificate.get_ref()==null and retained_history.get_ref()==null)
	var prepared:=prepared_history_holder()
	var certificate: WeakRef=weakref(prepared._payload.preparedHistory)
	prepared._payload.blueprint.id="changed-after-history-preparation"
	var publisher:=InvalidatingMasonryPublisher.new()
	var target:=Node3D.new()
	parent.add_child(target)
	var result: Dictionary=publisher.begin_prepared_publication(prepared,target,Fixtures.BINDING)
	check("prepared_history_failed_begin_detached",not result.ready and publisher._prepared_history==null and result.retirementPayload.scenePreparation.preparedHistory!=null)
	worker.retire_external_payload(result.retirementPayload)
	result={}; prepared=null
	var deadline:=Time.get_ticks_msec()+5000
	while worker.poll().busy and Time.get_ticks_msec()<deadline: await process_frame
	check("prepared_history_failed_begin_released",certificate.get_ref()==null)
	publisher.clear_published()
	check("prepared_history_clear_mutable_replacement",not publisher.surface_history.route_corridors.is_read_only() and not publisher.surface_history.history_events.is_read_only())
	result=publisher.begin_prepared_publication(prepared_history_holder(),target,Fixtures.BINDING)
	check("prepared_history_clear_fixture_adopted",result.ready and publisher._prepared_history!=null)
	certificate=weakref(publisher._prepared_history)
	publisher.clear_published()
	check("prepared_history_successful_clear_released",certificate.get_ref()==null and publisher._prepared_history==null and not publisher.surface_history.history_events.is_read_only())
	target.free()

func _run() -> void:
	parent = Node3D.new()
	parent.position = Vector3(3, 0, 5)
	root.add_child(parent)
	var trees := SyntheticTrees.new()
	var job = Job.new()
	var prepared := holder()
	start(job, trees, prepared)
	check("begin_queues_without_nodes_or_consume", job.own_node_root() == null and not prepared._consumed)
	check("budget_zero_rejected", job.advance(0).status == "rejected")
	check("budget_4001_rejected", job.advance(4001).status == "rejected")
	check("bad_budgets_do_not_consume", not prepared._consumed and job.own_node_root() == null)
	job.cancel()
	check("cancel_immediately_not_ready", not job.status().sceneReady and job.status().status == "cancelled")
	prepared = null
	await drain(job, "cancel_before_begin")
	check("cancel_before_begin_no_callback", trees.calls == 0)

	job = Job.new()
	prepared = holder()
	var stale := Fixtures.BINDING.duplicate()
	stale.generation += 1
	start(job, trees, prepared, stale)
	job.advance(1)
	check("stale_holder_rejected_unconsumed", job.status().status == "failed" and not prepared._consumed)
	prepared = null
	await drain(job, "stale_holder")

	job = Job.new()
	start(job, trees)
	for index in range(100):
		job.advance(1)
		if job.status().buildingCursor > 0: break
	check("actual_part_collision_created", job._building.collision_count > 0)
	check("root_exact_world_origin", job.own_node_root().global_position.is_equal_approx(Vector3(10, 0, 20)))
	job.cancel()
	await drain(job, "cancel_after_collider")
	check("collider_cancel_no_tree_callback", trees.calls == 0)

	# The real publisher invokes its ordinary progress callback from finish.
	# That reentrant cancellation must not restore furniture_begin afterwards.
	trees = SyntheticTrees.new()
	job = Job.new()
	start(job, trees)
	job.advance(1)
	var finish_cancel := FinishCanceller.new()
	finish_cancel.target = weakref(job)
	job._building.incremental_progress_callback = finish_cancel.progress
	for index in range(100):
		job.advance(4000)
		if job.status().status == "cancelled": break
	check("finish_callback_cancel_preserves_teardown", job.status().status == "cancelled" and job.status().phase == "teardown")
	check("finish_callback_no_furniture_or_trees", job._furniture == null and trees.calls == 0)
	check("finish_callback_not_scene_ready", not job.status().sceneReady)
	await drain(job, "cancel_in_finish_callback")
	check("finish_callback_no_later_calls", finish_cancel.calls == 1 and trees.calls == 0)

	# Root-loss recovery before external tree registrations exist. After trees
	# are registered, an external owner must balance its hook BEFORE destroying
	# those bodies; the job cannot issue a before-free callback retroactively.
	job = Job.new()
	start(job, trees)
	job.advance(1)
	check("root_loss_fixture_has_no_children", job.own_node_root().get_child_count() == 0)
	job.own_node_root().free()
	job.advance(1)
	check("root_loss_is_explicit_failure", job.status().status == "failed" and job.status().reason == "publication_root_lost")
	check("root_loss_never_scene_ready", not job.status().sceneReady)
	await drain(job, "lost_root")

	trees = SyntheticTrees.new()
	job = Job.new()
	trees.cancel_target = weakref(job)
	start(job, trees)
	for index in range(100):
		job.advance(4000)
		if job.status().status == "cancelled": break
	check("reentrant_cancel_one_callback", trees.calls == 1 and trees.published == 1)
	await drain(job, "cancel_in_tree_callback")
	check("no_callback_after_cancel", trees.calls == 1)
	check("tree_retired_exactly_once_before_free", trees.retired == 1 and trees.retire_before_free and trees.retired_ids.values() == [1])

	trees = SyntheticTrees.new()
	trees.defer_once = true
	job = Job.new()
	start(job, trees)
	for index in range(100):
		job.advance(4000)
		if job.status().sceneReady: break
	check("deferred_tree_retained_and_completed", job.status().sceneReady and trees.calls == 3 and trees.published == 2)
	check("scene_not_gameplay_ready", not job.status().gameplayReady)
	check("both_tree_visuals_required", job.status().treeVisualsComplete == 2)
	job.cancel()
	await drain(job, "successful_scene")
	check("both_successful_trees_retired_once", trees.retired == 2 and trees.retired_ids.values() == [1, 1])

	# First tree was already observed complete; it disappears while the second
	# remains queued. Completion must revalidate the first weak reference too.
	trees = SyntheticTrees.new()
	trees.second_pending = true
	job = Job.new()
	start(job, trees)
	for index in range(100):
		job.advance(1)
		if job.status().phase == "tree_visuals" and job.status().treeVisualsComplete == 1: break
	check("disappearance_fixture_first_seen_second_pending", job.status().treeVisualsComplete == 1 and not job.status().sceneReady and trees.published == 2)
	var first: StaticBody3D = trees.bodies[0].get_ref() as StaticBody3D
	var second: StaticBody3D = trees.bodies[1].get_ref() as StaticBody3D
	# Simulate an external owner correctly balancing its own registration before
	# removal. This is not a harvest and writes no durable removed_props entry.
	trees.retire(String(first.get_meta("prop_id")), first)
	first.get_node("GeneratedTreeVisual").free()
	first.free()
	first = null
	var completed_visual := Node3D.new()
	completed_visual.name = "GeneratedTreeVisual"
	second.add_child(completed_visual)
	second.set_meta("tree_visual_state", "published")
	second = null
	completed_visual = null
	for index in range(100):
		job.advance(1)
		if job.status().status == "failed": break
	check("completed_tree_disappearance_invalidates_ready", job.status().status == "failed" and job.status().reason == "tree_body_lost_before_visual" and not job.status().sceneReady)
	await drain(job, "completed_tree_disappeared")
	check("surviving_tree_retired_once", trees.retired == 2 and trees.retired_ids.values() == [1, 1])

	for state: String in ["failed", "failed_fallback", ""]:
		trees = SyntheticTrees.new()
		trees.visual_state = state
		job = Job.new()
		start(job, trees)
		for index in range(100):
			job.advance(4000)
			if job.status().status == "failed": break
		check("bad_tree_state_" + state, job.status().status == "failed" and not job.status().sceneReady)
		await drain(job, "bad_tree_" + state)
	for target: String in ["paving_geometry", "paving_upload", "static_flush","masonry_geometry","masonry_collect","roof_tiles","roof_collect"]:
		await pending_cancellation_case(target)
	await pending_completion_control()
	await paving_binding_mutation_controls()
	await masonry_completion_control()
	await roof_lifecycle_controls()
	masonry_hook_controls()
	await prepared_history_lifecycle_controls()
	await prepared_masonry_controls()
	worker.request_shutdown()
	var deadline := Time.get_ticks_msec() + 5000
	while not worker.poll().shutdownComplete and Time.get_ticks_msec() < deadline: await process_frame
	check("shutdown_complete", worker.poll().shutdownComplete)
	check("parent_empty", parent.get_child_count() == 0)
	parent.free()
	var failures: Array = []
	for key: String in checks:
		if not checks[key]: failures.append(key)
	var report := {"evidence":"synthetic scene orchestration; no live gameplay", "checks":checks,
		"checkCount":checks.size(), "failureCount":failures.size(), "failures":failures}
	var output := OS.get_environment("BUILDING_SCENE_PUBLICATION_JOB_OUTPUT")
	if not output.is_empty():
		DirAccess.make_dir_recursive_absolute(output)
		var file := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "\t"))
	print("SCENE_JOB_CONTRACT checks=", checks.size(), " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
