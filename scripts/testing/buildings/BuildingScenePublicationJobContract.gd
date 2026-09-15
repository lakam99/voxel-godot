extends SceneTree
## Synthetic orchestration only: tiny real publishers, synthetic prepared proofs
## and tree callback. Not source preparation, live trees, doors, or gameplay.
const Job = preload("res://scripts/buildings/BuildingScenePublicationJob.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Assembly = preload("res://scripts/buildings/PavingFootingAssemblyRecipe.gd")
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
	func publish(parent: Node3D, id: String, position: Vector3, _biome: String, request: Dictionary, yaw: float) -> Dictionary:
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
		# Explicit synthetic tree geometry, derived from the declared request.
		var collision: CollisionShape3D = CollisionShape3D.new()
		var shape: CylinderShape3D = CylinderShape3D.new()
		shape.radius = float(request.trunkRadius)
		shape.height = float(request.collisionHeight)
		collision.shape = shape
		collision.position.y = shape.height * 0.5
		body.add_child(collision)
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


class PacketDoorCallbacks extends RefCounted:
	var job: WeakRef
	var group_id := ""
	var registrations := 0
	var retirements := 0
	var registered_before_receipt := false
	var retired_with_intact_body := false
	var registered_body: WeakRef
	var portal_id := ""
	func register_door(body: Node) -> Dictionary:
		if not body is StaticBody3D or not is_instance_valid(body): return {"status":"rejected"}
		portal_id=String(body.get_meta("door_portal_id", ""))
		if portal_id.is_empty(): return {"status":"rejected"}
		var active = job.get_ref() if job != null else null
		registered_before_receipt=active != null and active.physical_group_receipt(group_id,Fixtures.BINDING).status!="ready"
		registered_body=weakref(body)
		registrations+=1
		return {"status":"registered","portalId":portal_id}
	func retire_door(body: Node) -> Dictionary:
		retired_with_intact_body=is_instance_valid(body) and body is StaticBody3D and body.is_inside_tree() \
			and String(body.get_meta("door_portal_id", ""))==portal_id
		retirements+=1
		return {"status":"unregistered","portalId":portal_id}

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
	var tree_request: Dictionary = {"biome":"town", "architecture":"broadleaf", "speciesGrammar":"synthetic_contract",
		"visualHeight":3.0, "collisionHeight":2.0, "trunkRadius":0.2, "canopyRadius":1.0}
	blueprint.recipe["landscapeTrees"] = [
		{"id":"a", "position":Vector3(2, 0, 0), "rotationY":0.0, "canopyRadius":1.0, "rootButtressFootprints":[], "treeRequest":tree_request.duplicate(true)},
		{"id":"b", "position":Vector3(4, 0, 0), "rotationY":0.0, "canopyRadius":1.0, "rootButtressFootprints":[], "treeRequest":tree_request.duplicate(true)}]
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

func start(job, trees, prepared = null, binding: Dictionary = Fixtures.BINDING) -> Dictionary:
	if prepared == null: prepared = holder()
	# Compile after each case's source edits. Preserve an explicitly compiled
	# dense packet only in the separate source/artifact ownership control.
	if not prepared._payload.has("spatialDependencies"):
		prepared._payload.spatialDependencies = Preparation.SpatialDependencies.compile_description(
			prepared._payload.blueprint, prepared._payload.furnishingPlan, prepared._binding, frozen_profile().origin, Callable())
	var description = prepared._payload.spatialDependencies
	check("compiled_groups_" + str(checks.size()), description != null and description.publication_groups.get("ready", false))
	job.set_tree_retire_callback(trees.retire)
	return job.begin(prepared, frozen_profile(), binding, parent, trees.publish)

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
				reached=job._building!=null and (job._building._pending_paving!=null if phase=="pending" else job.status().phase=="publication_boundary")
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
		else: job._transaction_building_cursor=1
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
	await spatial_dependency_ownership()
	await base_packet_gate_control()
	await packet_transaction_order_control()
	await packet_occupied_transaction_rotation_control()
	await packet_occupied_dependency_reservation_control()
	await packet_local_partition_batch_control()
	await packet_interleaved_partition_batch_control()
	await packet_oversized_dependency_closure_control()
	await packet_foreground_deferral_control()
	await packet_furnishing_session_control()
	await packet_door_lifecycle_control()
	packet_publisher_validation_control()
	packet_publisher_incremental_session_control()
	jointed_packet_publisher_control()
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
	var stale_begin: Dictionary = start(job, trees, prepared, stale)
	check("stale_holder_rejected_unconsumed", stale_begin.status == "rejected" and not prepared._consumed and job.status().phase == "idle")
	# Rejection does not transfer the holder to the job. Its caller still owns
	# the one-shot payload and must retire it through the ordinary worker.
	check("stale_holder_nodes_gone", job.own_node_root() == null)
	var stale_payload: Dictionary = prepared.take(Fixtures.BINDING)
	check("stale_holder_retirement_once", not stale_payload.is_empty() and prepared.take(Fixtures.BINDING).is_empty())
	check("stale_holder_retirement_accepted", worker.retire_external_payload(stale_payload))
	stale_payload = {}
	prepared = null
	var stale_deadline: int = Time.get_ticks_msec() + 5000
	while worker.poll().busy and Time.get_ticks_msec() < stale_deadline: await process_frame
	check("stale_holder_worker_drained", not worker.poll().busy)

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
	# Groups now finish before this whole-site callback. Reentrant cancellation
	# must not restore a later phase or submit any further downstream work.
	trees = SyntheticTrees.new()
	job = Job.new()
	start(job, trees)
	for index in range(1000):
		# The public selector exposes the final empty transaction before its
		# first advance can invoke the real whole-site completion callback.
		if job.status().phase == "transaction_select": job.pending_publication_transaction()
		if job.status().phase == "building_finish": break
		job.advance(1)
		if job.status().phase == "building_finish" or job.status().status == "failed": break
	check("finish_callback_fixture_reaches_final_boundary", job.status().phase == "building_finish")
	var prior_furniture: int = job.status().counts.furnitureParts
	var prior_tree_calls: int = trees.calls
	var prior_tree_published: int = trees.published
	var finish_cancel := FinishCanceller.new()
	finish_cancel.target = weakref(job)
	job._building.incremental_progress_callback = finish_cancel.progress
	for index in range(100):
		job.advance(4000)
		if job.status().status == "cancelled": break
	check("finish_callback_cancel_preserves_teardown", job.status().status == "cancelled" and job.status().phase == "teardown")
	check("finish_callback_no_further_furniture_or_trees", job.status().counts.furnitureParts == prior_furniture and trees.calls == prior_tree_calls and trees.published == prior_tree_published)
	check("finish_callback_not_scene_ready", not job.status().sceneReady)
	await drain(job, "cancel_in_finish_callback")
	check("finish_callback_no_later_calls", finish_cancel.calls == 1 and trees.calls == prior_tree_calls and trees.published == prior_tree_published)
	check("finish_callback_completed_trees_retired_once", trees.retired == prior_tree_published and trees.retire_before_free and trees.retired_ids.values() == [1, 1])

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
		if job.status().phase == "group_tree_visuals" and job.status().treeVisualsComplete == 1: break
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
	check("completed_tree_disappearance_invalidates_ready", job.status().status == "failed" and job.status().reason == "publication_group_member_incomplete:tree:a" and not job.status().sceneReady)
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

func base_packet_gate_control() -> void:
	var prepared := holder()
	var building_source: Dictionary = prepared._payload.blueprint.snapshot()
	var furnishing_source: Dictionary = prepared._payload.furnishingPlan.snapshot()
	furnishing_source.accessReservations = []
	building_source.make_read_only()
	furnishing_source.make_read_only()
	var profile := frozen_profile()
	var base_result := Preparation.prepare_publication_base(building_source,furnishing_source,Fixtures.BINDING,profile)
	check("packet_gate_base_ready",base_result.ready and base_result.base.matches(Fixtures.BINDING))
	if not base_result.ready: return
	var trees := SyntheticTrees.new()
	var job := Job.new()
	var begun: Dictionary = job.begin_prepared_base(base_result.base,profile,Fixtures.BINDING,parent,trees.publish)
	check("packet_gate_base_begin_has_no_scene_owner",begun.status=="pending_budget" and job.own_node_root()==null and job._building==null)
	var first_group: String = String(base_result.base.description.publication_groups.order[0])
	var requested: Dictionary = job.request_publication_groups([first_group],Fixtures.BINDING,0)
	check("packet_gate_request_retained",requested.status=="retained")
	var pending: Dictionary = job.pending_publication_transaction()
	check("packet_gate_exact_scope_pending",pending.status=="pending" and pending.reason=="physical_group_packet_pending" \
		and pending.groupIds.has(first_group) and job.own_node_root()==null and job._building==null)
	var stale_binding := Fixtures.BINDING.duplicate(); stale_binding.generation += 1
	var packet_result := Preparation.compile_physical_group_packet(base_result.base,pending.groupIds)
	check("packet_gate_packet_compiled",packet_result.ready)
	if packet_result.ready:
		check("packet_gate_stale_offer_rejected",job.offer_physical_group_packet(packet_result.packet,stale_binding).reason=="invalid_physical_group_packet")
		check("packet_gate_offer_retained",job.offer_physical_group_packet(packet_result.packet,Fixtures.BINDING).status=="retained")
		check("packet_gate_duplicate_offer_rejected",job.offer_physical_group_packet(packet_result.packet,Fixtures.BINDING).reason=="physical_group_packet_already_retained")
	var promoted: Dictionary = job.pending_publication_transaction()
	check("packet_gate_offer_promotes_same_pinned_transaction",promoted.status=="ready" and promoted.id==pending.id \
		and promoted.groupIds==pending.groupIds and job.own_node_root()==null and job._building==null)
	var advance: Dictionary = job.advance(1,int(promoted.id))
	check("packet_gate_never_starts_scene_before_adapter",advance.status=="ready" and job.own_node_root()==null and job._building==null)
	var activated: Dictionary = job.activate_physical_group_packet_scene(int(promoted.id))
	check("packet_gate_adapter_activates_only_ready_transaction",activated.status=="pending_budget" and job.own_node_root()==null and job._building==null)
	var receipt: Dictionary = {}
	check("packet_gate_group_set_receipt_pending_before_publication",
		job.physical_groups_receipt([first_group],Fixtures.BINDING).status=="pending")
	for index in range(1024):
		job.advance(4000,int(promoted.id))
		receipt=job.physical_group_receipt(first_group,Fixtures.BINDING)
		if receipt.status in ["ready","failed"]: break
	check("packet_gate_adapter_publishes_selected_boundary",receipt.status=="ready" and job._building!=null \
		and job._building._physical_packet_mode and job._furniture==null and trees.calls==0)
	check("packet_gate_group_set_receipt_matches_single_authority",
		job.physical_groups_receipt([first_group],Fixtures.BINDING).status=="ready")
	check("packet_gate_group_set_receipt_rejects_unknown_group",
		job.physical_groups_receipt(["missing-group"],Fixtures.BINDING).status=="failed")
	var static_receipt: Dictionary = job.static_only_group_receipt(first_group,Fixtures.BINDING)
	check("packet_gate_static_only_receipt_retains_exact_static_scope",static_receipt.status=="ready" \
		and static_receipt.publicationKind=="packet_static_only" and static_receipt.packetSourceId==base_result.base.source_id \
		and static_receipt.staticRecordIds.has("tiny-post") and static_receipt.sourceMemberIds==receipt.sourceMemberIds)
	check("packet_gate_adapter_has_no_full_scene_completion",job.status().phase=="packet_wait" and not job.status().sceneReady)
	job.cancel()
	await drain(job,"packet_gate")
	prepared=null

## Packet compilation accepts canonical group scopes by design. Verify that a
## dependency/selection-ordered scope is normalized at the only boundary that
## owns the transaction IDs, physicalPacketKey, and later packet match.
func packet_transaction_order_control() -> void:
	var blueprint := Blueprint.new("packet-order",1,"timber")
	blueprint.recipe={"sourceBlueprintId":"packet_order_history","landscapeTrees":[]}
	blueprint.add_part({"id":"z-last","kind":"post","material":"timber_beam","collision":false,
		"size":Vector3(0.2,1.0,0.2),"position":Vector3.ZERO})
	blueprint.add_part({"id":"a-first","kind":"post","material":"timber_beam","collision":false,
		"size":Vector3(0.2,1.0,0.2),"position":Vector3(2,0,0)})
	var plan := Plan.new("packet-order-plan",1,blueprint.id)
	var building: Dictionary = blueprint.snapshot(); building.make_read_only()
	var furnishing: Dictionary = plan.snapshot(); furnishing.accessReservations=[]; furnishing.make_read_only()
	var profile := frozen_profile()
	var base_result := Preparation.prepare_publication_base(building,furnishing,Fixtures.BINDING,profile)
	check("packet_order_base_ready",base_result.ready and base_result.base.matches(Fixtures.BINDING))
	if not base_result.ready: return
	var trees := SyntheticTrees.new()
	var job := Job.new()
	var begun: Dictionary = job.begin_prepared_base(base_result.base,profile,Fixtures.BINDING,parent,trees.publish)
	check("packet_order_base_begin",begun.status=="pending_budget")
	# Deliberately dependency-first/noncanonical input. _pin_transaction is the
	# scene-owned canonical boundary, never a service-side repair.
	job._selection_groups.append("building:z-last")
	job._selection_groups.append("building:a-first")
	job._selection_members=2
	var pending: Dictionary = job._pin_transaction()
	var expected: Array[String] = ["building:a-first","building:z-last"]
	check("packet_order_transaction_canonical",pending.status=="pending" and pending.groupIds==expected)
	check("packet_order_key_matches_canonical_scope",pending.physicalPacketKey==Job._physical_packet_key(expected))
	var packet_result := Preparation.compile_physical_group_packet(base_result.base,pending.groupIds)
	check("packet_order_compiler_accepts_transaction_scope",packet_result.ready and packet_result.packet.matches(base_result.base,expected))
	if packet_result.ready:
		check("packet_order_offer_uses_same_canonical_scope",job.offer_physical_group_packet(packet_result.packet,Fixtures.BINDING).status=="retained")
		var promoted: Dictionary = job.pending_publication_transaction()
		check("packet_order_offer_promotes_exact_canonical_transaction",promoted.status=="ready" and promoted.groupIds==expected \
			and promoted.physicalPacketKey==pending.physicalPacketKey)
		check("packet_order_adapter_accepts_exact_canonical_transaction",job.activate_physical_group_packet_scene(int(promoted.id)).status=="pending_budget")
	job.cancel()
	await drain(job,"packet_order")


func packet_occupied_transaction_rotation_control() -> void:
	var blueprint := Blueprint.new("packet-occupied-rotation",1,"timber")
	blueprint.recipe={"sourceBlueprintId":"packet_occupied_rotation_history","landscapeTrees":[]}
	blueprint.add_part({"id":"occupied-room","kind":"wall","material":"timber_beam","collision":true,
		"size":Vector3(1,2,1),"position":Vector3(-6,1,0)})
	blueprint.add_part({"id":"independent-room","kind":"wall","material":"timber_beam","collision":true,
		"size":Vector3(1,2,1),"position":Vector3(6,1,0)})
	var plan := Plan.new("packet-occupied-rotation-plan",1,blueprint.id)
	var building: Dictionary=blueprint.snapshot(); building.make_read_only()
	var furnishing: Dictionary=plan.snapshot(); furnishing.accessReservations=[]; furnishing.make_read_only()
	var profile := frozen_profile()
	var base_result := Preparation.prepare_publication_base(building,furnishing,Fixtures.BINDING,profile)
	check("occupied_rotation_base_ready",base_result.ready)
	if not base_result.ready: return
	var groups: Array[String] = []
	for raw_id in base_result.base.description.publication_groups.order: groups.append(String(raw_id))
	groups.sort()
	check("occupied_rotation_has_two_independent_groups",groups.size()==2)
	if groups.size()!=2: return
	var trees := SyntheticTrees.new()
	var job := Job.new()
	job.begin_prepared_base(base_result.base,profile,Fixtures.BINDING,parent,trees.publish)
	job.replace_packet_foreground_group_demands([{"ownerId":"foreground","groupIds":groups,"priority":0}],[],Fixtures.BINDING)
	var first: Dictionary=job.pending_publication_transaction()
	check("occupied_rotation_pins_one_dependency_complete_root",first.get("status")=="pending" and first.groupIds.size()==1
		and first.get("estimatedCost",{}).get("bytes",0)>0 and first.get("cancelRevision",-1)==0)
	var retained: Dictionary=job.defer_occupied_publication_transaction(int(first.transactionId),"synthetic_actor_overlap")
	# A per-frame owner refresh must not recreate the parked packet scope.
	job.replace_packet_foreground_group_demands([{"ownerId":"foreground","groupIds":groups,"priority":0}],[],Fixtures.BINDING)
	var second: Dictionary=job.pending_publication_transaction()
	check("occupied_refresh_reserves_parked_group",retained.get("status")=="retained" and second.get("status")=="pending"
		and second.groupIds.size()==1 and second.groupIds[0]!=first.groupIds[0] and job._occupied_transactions.size()==1)
	job.defer_occupied_publication_transaction(int(second.transactionId),"synthetic_actor_overlap")
	job.replace_packet_foreground_group_demands([{"ownerId":"foreground","groupIds":groups,"priority":0}],[],Fixtures.BINDING)
	var restored: Dictionary=job.pending_publication_transaction()
	check("occupied_rotation_restores_exact_first_transaction",restored.transactionId==first.transactionId
		and restored.binding==first.binding and restored.groupIds==first.groupIds and restored.estimatedCost==first.estimatedCost
		and restored.occupancyWaitReason=="synthetic_actor_overlap" and restored.occupancyWaitCount==1)
	job.cancel()
	await drain(job,"packet_occupied_rotation")


func packet_occupied_dependency_reservation_control() -> void:
	var blueprint := Blueprint.new("packet-occupied-dependency",1,"timber")
	blueprint.recipe={"sourceBlueprintId":"packet_occupied_dependency_history","landscapeTrees":[]}
	blueprint.add_part({"id":"support","kind":"foundation","material":"stone","collision":true,
		"size":Vector3(2,2,2),"position":Vector3(-6,1,0)})
	blueprint.add_part({"id":"dependent","kind":"wall","material":"timber_beam","collision":true,
		"size":Vector3(1,2,1),"position":Vector3(-6,3,0)})
	blueprint.add_part({"id":"independent","kind":"wall","material":"timber_beam","collision":true,
		"size":Vector3(1,2,1),"position":Vector3(6,1,0)})
	var plan := Plan.new("packet-occupied-dependency-plan",1,blueprint.id)
	var building: Dictionary=blueprint.snapshot(); building.make_read_only()
	var furnishing: Dictionary=plan.snapshot(); furnishing.accessReservations=[]; furnishing.make_read_only()
	var profile := frozen_profile()
	var base_result := Preparation.prepare_publication_base(building,furnishing,Fixtures.BINDING,profile)
	check("occupied_dependency_base_ready",base_result.ready)
	if not base_result.ready: return
	var groups: Dictionary=base_result.base.description.publication_groups.groups
	var by_part: Dictionary=base_result.base.description.publication_groups.groupByPart
	var support_id := String(by_part.get("building:support",""))
	var dependent_id := String(by_part.get("building:dependent",""))
	var independent_id := String(by_part.get("building:independent",""))
	check("occupied_dependency_fixture_has_direct_support",not support_id.is_empty() and support_id!=dependent_id
		and groups.get(dependent_id,{}).get("dependencies",[]).has(support_id))
	if support_id.is_empty() or support_id==dependent_id or not groups.get(dependent_id,{}).get("dependencies",[]).has(support_id): return
	var trees := SyntheticTrees.new()
	var job := Job.new()
	job.begin_prepared_base(base_result.base,profile,Fixtures.BINDING,parent,trees.publish)
	job.replace_packet_foreground_group_demands([{"ownerId":"foreground","groupIds":[support_id],"priority":0}],
		[dependent_id,independent_id],Fixtures.BINDING)
	var support_transaction: Dictionary=job.pending_publication_transaction()
	job.defer_occupied_publication_transaction(int(support_transaction.transactionId),"synthetic_actor_overlap")
	job.replace_packet_foreground_group_demands([{"ownerId":"foreground",
		"groupIds":[support_id,dependent_id,independent_id],"priority":0}],[],Fixtures.BINDING)
	var independent_transaction: Dictionary=job.pending_publication_transaction()
	check("occupied_support_blocks_dependent_duplicate_selection",independent_transaction.get("status")=="pending"
		and independent_transaction.groupIds==[independent_id] and not independent_transaction.groupIds.has(support_id))
	job.defer_occupied_publication_transaction(int(independent_transaction.transactionId),"synthetic_actor_overlap")
	var restored: Dictionary=job.pending_publication_transaction()
	check("occupied_support_restores_before_dependent",restored.get("transactionId",0)==support_transaction.get("transactionId",-1)
		and restored.groupIds==[support_id])
	job.cancel()
	await drain(job,"packet_occupied_dependency")


func packet_local_partition_batch_control() -> void:
	var blueprint := Blueprint.new("packet-local-partition",1,"timber")
	blueprint.recipe={"sourceBlueprintId":"packet_local_partition_history","landscapeTrees":[]}
	blueprint.add_part({"id":"local-a","kind":"wall","material":"timber_beam","collision":true,
		"size":Vector3(1,2,1),"position":Vector3(1,1,1)})
	blueprint.add_part({"id":"local-b","kind":"wall","material":"timber_beam","collision":true,
		"size":Vector3(1,2,1),"position":Vector3(3,1,1)})
	var plan := Plan.new("packet-local-partition-plan",1,blueprint.id)
	var building: Dictionary=blueprint.snapshot(); building.make_read_only()
	var furnishing: Dictionary=plan.snapshot(); furnishing.accessReservations=[]; furnishing.make_read_only()
	var profile := frozen_profile()
	var base_result := Preparation.prepare_publication_base(building,furnishing,Fixtures.BINDING,profile)
	check("local_partition_base_ready",base_result.ready)
	if not base_result.ready: return
	var groups: Array[String]=[]
	for raw_id in base_result.base.description.publication_groups.order: groups.append(String(raw_id))
	groups.sort()
	check("local_partition_has_two_groups",groups.size()==2)
	if groups.size()!=2: return
	var trees := SyntheticTrees.new()
	var job := Job.new()
	job.begin_prepared_base(base_result.base,profile,Fixtures.BINDING,parent,trees.publish)
	job.replace_packet_foreground_group_demands([{"ownerId":"foreground","groupIds":groups,"priority":0}],[],Fixtures.BINDING)
	var transaction: Dictionary=job.pending_publication_transaction()
	check("local_partition_coalesces_roots",transaction.get("status")=="pending" and transaction.groupIds==groups
		and transaction.get("physicalPacketKey","")==Job._physical_packet_key(groups))
	job.cancel()
	await drain(job,"packet_local_partition")


## Semantic source IDs routinely interleave spatial blocks in a large generated
## structure. Packet scheduling must preserve the first requested block while
## selecting its local peers, or the spatial batching contract degenerates into
## one worker dispatch per source ID.
func packet_interleaved_partition_batch_control() -> void:
	var blueprint := Blueprint.new("packet-interleaved-partition",1,"timber")
	blueprint.recipe={"sourceBlueprintId":"packet_interleaved_partition_history","landscapeTrees":[]}
	for spec: Dictionary in [
		{"id":"a-near","position":Vector3(1,1,1)},
		{"id":"b-far","position":Vector3(33,1,1)},
		{"id":"c-near","position":Vector3(3,1,1)},
		{"id":"d-far","position":Vector3(35,1,1)}]:
		blueprint.add_part({"id":spec.id,"kind":"wall","material":"timber_beam","collision":true,
			"size":Vector3(1,2,1),"position":spec.position})
	var plan := Plan.new("packet-interleaved-partition-plan",1,blueprint.id)
	var building: Dictionary=blueprint.snapshot(); building.make_read_only()
	var furnishing: Dictionary=plan.snapshot(); furnishing.accessReservations=[]; furnishing.make_read_only()
	var profile := frozen_profile()
	var base_result := Preparation.prepare_publication_base(building,furnishing,Fixtures.BINDING,profile)
	check("interleaved_partition_base_ready",base_result.ready)
	if not base_result.ready: return
	var groups: Array[String]=["building:a-near","building:b-far","building:c-near","building:d-far"]
	var trees := SyntheticTrees.new()
	var job := Job.new()
	job.begin_prepared_base(base_result.base,profile,Fixtures.BINDING,parent,trees.publish)
	job.replace_packet_foreground_group_demands([{"ownerId":"foreground","groupIds":groups,"priority":0}],[],Fixtures.BINDING)
	var first: Dictionary=job.pending_publication_transaction()
	check("interleaved_partition_coalesces_first_local_block",first.get("status")=="pending"
		and first.groupIds==["building:a-near","building:c-near"])
	job.defer_occupied_publication_transaction(int(first.get("transactionId",0)),"contract_rotation")
	var second: Dictionary=job.pending_publication_transaction()
	check("interleaved_partition_coalesces_second_local_block",second.get("status")=="pending"
		and second.groupIds==["building:b-far","building:d-far"])
	job.cancel()
	await drain(job,"packet_interleaved_partition")


## A soft packet target may separate independent roots, but never a root from
## its dependency chain. The 65th group reproduces the historical split at the
## 64-group cap without constructing generated-world content.
func packet_oversized_dependency_closure_control() -> void:
	var blueprint := Blueprint.new("packet-closure-cap",1,"timber")
	blueprint.recipe={"sourceBlueprintId":"packet_closure_cap_history","landscapeTrees":[]}
	for index in range(65):
		var recipe: Dictionary={}
		if index>0: recipe["physicalRequiredSupportPartIds"]=["closure-%02d"%(index-1)]
		blueprint.add_part({"id":"closure-%02d"%index,"kind":"post","material":"timber_beam","collision":false,
			"size":Vector3(0.2,1.0,0.2),"position":Vector3(float(index)*0.01,0.5,0),"recipe":recipe})
	var plan := Plan.new("packet-closure-cap-plan",1,blueprint.id)
	var building: Dictionary=blueprint.snapshot(); building.make_read_only()
	var furnishing: Dictionary=plan.snapshot(); furnishing.accessReservations=[]; furnishing.make_read_only()
	var profile:=frozen_profile()
	var base_result:=Preparation.prepare_publication_base(building,furnishing,Fixtures.BINDING,profile)
	check("closure_cap_base_ready",base_result.ready)
	if not base_result.ready: return
	var trees:=SyntheticTrees.new()
	var job:=Job.new()
	job.begin_prepared_base(base_result.base,profile,Fixtures.BINDING,parent,trees.publish)
	var root_group:="building:closure-64"
	var requested:=job.request_publication_groups([root_group],Fixtures.BINDING,0)
	var transaction: Dictionary={}
	for attempt in range(128):
		transaction=job.pending_publication_transaction()
		if transaction.get("status")!="pending_budget": break
	check("closure_cap_request_retained",requested.get("status")=="retained")
	check("closure_cap_keeps_root_with_all_dependencies",transaction.get("status")=="pending"
		and transaction.get("groupIds",[]).size()==65 and transaction.get("groupIds",[]).has("building:closure-00")
		and transaction.get("groupIds",[]).has(root_group))
	job.cancel()
	await drain(job,"packet_closure_cap")


## A packet job may have a resident scene from an earlier closure while the
## streaming owner changes its next foreground tile. An unoffered pending
## packet contains no scene side effects and must be safely deferred, rather
## than causing the job to scan every remaining group in the source.
func packet_foreground_deferral_control() -> void:
	var blueprint := Blueprint.new("packet-foreground",1,"timber")
	blueprint.recipe={"sourceBlueprintId":"packet_foreground_history","landscapeTrees":[]}
	blueprint.add_part({"id":"first","kind":"post","material":"timber_beam","collision":false,
		"size":Vector3(0.2,1.0,0.2),"position":Vector3.ZERO})
	blueprint.add_part({"id":"second","kind":"post","material":"timber_beam","collision":false,
		"size":Vector3(0.2,1.0,0.2),"position":Vector3(2,0,0)})
	var plan := Plan.new("packet-foreground-plan",1,blueprint.id)
	var building: Dictionary = blueprint.snapshot(); building.make_read_only()
	var furnishing: Dictionary = plan.snapshot(); furnishing.accessReservations=[]; furnishing.make_read_only()
	var profile := frozen_profile()
	var base_result := Preparation.prepare_publication_base(building,furnishing,Fixtures.BINDING,profile)
	check("packet_foreground_base_ready",base_result.ready and base_result.base.matches(Fixtures.BINDING))
	if not base_result.ready: return
	var groups: Array[String] = []
	for raw_id in base_result.base.description.publication_groups.order: groups.append(String(raw_id))
	check("packet_foreground_fixture_has_two_groups",groups.size()==2)
	if groups.size()!=2: return
	var first: String = groups[0]
	var second: String = groups[1]
	var trees := SyntheticTrees.new()
	var job := Job.new()
	var begun: Dictionary = job.begin_prepared_base(base_result.base,profile,Fixtures.BINDING,parent,trees.publish)
	check("packet_foreground_base_begin",begun.status=="pending_budget")
	var configured: Dictionary = job.replace_packet_foreground_group_demands_compact([
		{"ownerId":"foreground","groupIds":[first],"priority":0}], [second], Fixtures.BINDING)
	check("packet_foreground_scope_retained",configured.status=="retained" and configured.foregroundGroups==1 and configured.deferredGroups==1 \
		and job._packet_deferred_groups.has(second))
	var first_pending: Dictionary = job.pending_publication_transaction()
	check("packet_foreground_selects_only_offered_group",first_pending.status=="pending" and first_pending.groupIds==[first])
	var first_packet := Preparation.compile_physical_group_packet(base_result.base,first_pending.groupIds)
	check("packet_foreground_first_packet_ready",first_packet.ready)
	if first_packet.ready:
		check("packet_foreground_first_packet_retained",job.offer_physical_group_packet(first_packet.packet,Fixtures.BINDING).status=="retained")
		var promoted: Dictionary = job.pending_publication_transaction()
		check("packet_foreground_first_packet_promoted",promoted.status=="ready" and promoted.id==first_pending.id)
		check("packet_foreground_first_packet_activated",job.activate_physical_group_packet_scene(int(promoted.id)).status=="pending_budget")
		for index in range(1024):
			job.advance(4000,int(promoted.id))
			if job.physical_group_receipt(first,Fixtures.BINDING).status in ["ready","failed"]: break
	var first_receipt: Dictionary = job.physical_group_receipt(first,Fixtures.BINDING)
	var resident_root: Node3D = job.own_node_root()
	check("packet_foreground_first_receipt_and_resident_root",first_receipt.status=="ready" and resident_root!=null and job.status().phase=="packet_wait")
	if first_receipt.status!="ready" or resident_root==null:
		job.cancel(); await drain(job,"packet_foreground_setup_failed"); return
	var source_revision_before_second_receipt: Array = job.source_dependency_revision()
	var next_scope: Dictionary = job.replace_packet_foreground_group_demands_compact([
		{"ownerId":"foreground","groupIds":[second],"priority":0}], [], Fixtures.BINDING)
	check("packet_foreground_next_scope_retained",next_scope.status=="retained" and next_scope.foregroundGroups==1 and next_scope.deferredGroups==0)
	var second_pending: Dictionary = job.pending_publication_transaction()
	check("packet_foreground_unoffered_second_packet_pinned",second_pending.status=="pending" and second_pending.groupIds==[second] and job.own_node_root()==resident_root)
	var deferred: Dictionary = job.replace_packet_foreground_group_demands_compact([], [second], Fixtures.BINDING)
	check("packet_foreground_unoffered_packet_deferred",deferred.status=="retained" and deferred.deferredTransactionCount==1)
	var waiting: Dictionary = job.pending_publication_transaction()
	check("packet_foreground_no_background_autoselection",waiting.status=="pending" and waiting.reason=="physical_packet_foreground_demand_pending" and job.status().publicationTransactionId==0)
	check("packet_foreground_deferral_preserves_resident_receipt",job.own_node_root()==resident_root \
		and job.physical_group_receipt(first,Fixtures.BINDING).status=="ready" and job.status().physicalGroupsComplete==1)
	var resumed: Dictionary = job.replace_packet_foreground_group_demands_compact([
		{"ownerId":"foreground","groupIds":[second],"priority":0}], [], Fixtures.BINDING)
	check("packet_foreground_deferred_group_can_resume",resumed.status=="retained")
	var resumed_pending: Dictionary = job.pending_publication_transaction()
	var resumed_packet := Preparation.compile_physical_group_packet(base_result.base,resumed_pending.groupIds)
	if resumed_packet.ready:
		job.offer_physical_group_packet(resumed_packet.packet,Fixtures.BINDING)
		var resumed_transaction: Dictionary = job.pending_publication_transaction()
		if resumed_transaction.status=="ready":
			job.activate_physical_group_packet_scene(int(resumed_transaction.id))
			for index in range(1024):
				job.advance(4000,int(resumed_transaction.id))
				if job.physical_group_receipt(second,Fixtures.BINDING).status in ["ready","failed"]: break
	var second_receipt: Dictionary = job.physical_group_receipt(second,Fixtures.BINDING)
	check("packet_receipt_invalidates_live_dependency_description",
		second_receipt.status=="ready" and job.source_dependency_revision()!=source_revision_before_second_receipt)
	job.cancel()
	await drain(job,"packet_foreground")


## Furnishings use the same resident packet session as structural groups, but
## retain their own immutable source records and publish only through the
## existing FurnishingPublisher. This proves an append never clears an earlier
## structural receipt or bypasses the live furnishing witness/proof path.
func packet_furnishing_session_control() -> void:
	var blueprint := Blueprint.new("packet-furnishing",1,"timber")
	blueprint.recipe={"sourceBlueprintId":"packet_furnishing_history","landscapeTrees":[]}
	blueprint.add_part({"id":"packet-post","kind":"post","material":"timber_beam","collision":true,
		"size":Vector3(0.2,1.0,0.2),"position":Vector3.ZERO})
	var plan := Plan.new("packet-furnishing-plan",1,blueprint.id)
	plan.add_part({"id":"packet-chair","roomId":"room","archetype":"chair","material":"timber_board",
		"position":Vector3(2,0,0),"rotation":Vector3.ZERO,"occupiedSize":Vector3(0.56,1.0,0.56),"collision":true,"semantic":"chair"})
	var building: Dictionary = blueprint.snapshot(); building.make_read_only()
	var furnishing: Dictionary = plan.snapshot(); furnishing.accessReservations=[]; furnishing.make_read_only()
	var profile := frozen_profile()
	var base_result := Preparation.prepare_publication_base(building,furnishing,Fixtures.BINDING,profile)
	check("packet_furnishing_base_ready",base_result.ready and base_result.base.matches(Fixtures.BINDING))
	if not base_result.ready: return
	var structural_group := ""
	var furnishing_group := ""
	for raw_group in base_result.base.description.publication_groups.order:
		var id := String(raw_group)
		var group: Dictionary = base_result.base.description.publication_groups.groups[id]
		if not group.buildingIndices.is_empty(): structural_group=id
		if not group.furnitureIndices.is_empty(): furnishing_group=id
	check("packet_furnishing_fixture_groups_isolated",not structural_group.is_empty() and not furnishing_group.is_empty() and structural_group!=furnishing_group)
	if structural_group.is_empty() or furnishing_group.is_empty() or structural_group==furnishing_group: return
	var trees := SyntheticTrees.new()
	var job := Job.new()
	check("packet_furnishing_base_begin",job.begin_prepared_base(base_result.base,profile,Fixtures.BINDING,parent,trees.publish).status=="pending_budget")
	var first_scope := job.replace_packet_foreground_group_demands([{"ownerId":"foreground","groupIds":[structural_group],"priority":0}], [furnishing_group], Fixtures.BINDING)
	check("packet_furnishing_structural_scope_retained",first_scope.status=="retained")
	var first := job.pending_publication_transaction()
	var first_packet := Preparation.compile_physical_group_packet(base_result.base,first.groupIds)
	check("packet_furnishing_structural_packet_ready",first.status=="pending" and first_packet.ready and first_packet.packet.furnishing_entries.is_empty())
	if not first_packet.ready:
		job.cancel(); await drain(job,"packet_furnishing_first_compile_failed"); return
	job.offer_physical_group_packet(first_packet.packet,Fixtures.BINDING)
	var first_ready := job.pending_publication_transaction()
	job.activate_physical_group_packet_scene(int(first_ready.id))
	for index in range(1024):
		job.advance(4000,int(first_ready.id))
		if job.physical_group_receipt(structural_group,Fixtures.BINDING).status in ["ready","failed"]: break
	var structural_receipt := job.physical_group_receipt(structural_group,Fixtures.BINDING)
	var resident_root := job.own_node_root()
	check("packet_furnishing_resident_structural_receipt",structural_receipt.status=="ready" and resident_root!=null and job._furniture==null)
	if structural_receipt.status!="ready" or resident_root==null:
		job.cancel(); await drain(job,"packet_furnishing_first_publish_failed"); return
	var second_scope := job.replace_packet_foreground_group_demands([{"ownerId":"foreground","groupIds":[furnishing_group],"priority":0}], [], Fixtures.BINDING)
	var second := job.pending_publication_transaction()
	var furnishing_packet := Preparation.compile_physical_group_packet(base_result.base,second.groupIds)
	var entry: Dictionary = furnishing_packet.packet.furnishing_entries.get("packet-chair",{}) if furnishing_packet.ready else {}
	check("packet_furnishing_compiler_emits_frozen_record",second_scope.status=="retained" and second.status=="pending" and furnishing_packet.ready \
		and furnishing_packet.packet.building_entries.is_empty() and entry.get("binding","")!="" and entry.get("record",{}).is_read_only())
	if furnishing_packet.ready:
		job.offer_physical_group_packet(furnishing_packet.packet,Fixtures.BINDING)
		var second_ready := job.pending_publication_transaction()
		check("packet_furnishing_exact_packet_promoted",second_ready.status=="ready" and second_ready.groupIds==[furnishing_group])
		# Model a late resident static boundary arriving between packet receipts.
		# The adapter must drain and retry it without rejecting the pinned packet.
		job._building._ensure_publication_boundary()
		var deferred_attach: Dictionary=job.activate_physical_group_packet_scene(int(second_ready.id))
		check("packet_append_drains_prior_boundary_before_attach",deferred_attach.status=="pending_budget"
			and deferred_attach.reason=="physical_packet_prior_boundary_pending" and job.status().phase=="packet_attach_boundary")
		for boundary_slice in range(64):
			job.advance(4000,int(second_ready.id))
			if job.status().phase=="packet_wait": break
		check("packet_append_prior_boundary_returns_to_same_transaction",job.status().phase=="packet_wait"
			and job.pending_publication_transaction().get("id",0)==second_ready.id
			and job.activate_physical_group_packet_scene(int(second_ready.id)).status=="pending_budget")
		for index in range(1024):
			job.advance(4000,int(second_ready.id))
			if job.physical_group_receipt(furnishing_group,Fixtures.BINDING).status in ["ready","failed"]: break
	var furnishing_receipt := job.physical_group_receipt(furnishing_group,Fixtures.BINDING)
	var chair: Node = resident_root.get_node_or_null("Furnishing_packet-chair") if resident_root!=null else null
	check("packet_furnishing_publishes_live_witness",furnishing_receipt.status=="ready" and furnishing_receipt.publicationKind=="packet_physical" \
		and chair is StaticBody3D and String(chair.get_meta("furnishing_part_id",""))=="packet-chair" and chair.get_child_count()>0)
	check("packet_furnishing_append_preserves_structural_receipt",job.own_node_root()==resident_root \
		and job.physical_group_receipt(structural_group,Fixtures.BINDING).status=="ready" and job.status().physicalGroupsComplete==2)
	job.cancel()
	await drain(job,"packet_furnishing")


## Packet doors are frozen source members, but their physical receipt is only
## legal after the existing body/portal callbacks have registered that body.
func packet_door_lifecycle_control() -> void:
	var blueprint := Blueprint.new("packet-door",1,"timber")
	blueprint.recipe={"sourceBlueprintId":"packet_door_history","landscapeTrees":[]}
	blueprint.add_part({"id":"packet-door-leaf","kind":"door","material":"timber_board","collision":true,
		"size":Vector3(0.9,2.0,0.14),"position":Vector3.ZERO,"recipe":{"doorPresentation":"door"}})
	var plan := Plan.new("packet-door-plan",1,blueprint.id)
	var building: Dictionary = blueprint.snapshot(); building.make_read_only()
	var furnishing: Dictionary = plan.snapshot(); furnishing.accessReservations=[]; furnishing.make_read_only()
	var profile := frozen_profile()
	var base_result := Preparation.prepare_publication_base(building,furnishing,Fixtures.BINDING,profile)
	check("packet_door_base_ready",base_result.ready and base_result.base.matches(Fixtures.BINDING))
	if not base_result.ready: return
	var door_group := ""
	for raw_group in base_result.base.description.publication_groups.order:
		var candidate: Dictionary = base_result.base.description.publication_groups.groups[String(raw_group)]
		if not candidate.doorPartIds.is_empty(): door_group=String(raw_group)
	check("packet_door_group_isolated",not door_group.is_empty())
	if door_group.is_empty(): return
	var eligibility: Dictionary = Preparation.classify_physical_group_packet_eligibility(base_result.base.description.publication_groups,base_result.base.building_source,base_result.base.furnishing_source)
	var compiled: Dictionary = Preparation.compile_physical_group_packet(base_result.base,[door_group])
	check("packet_door_compiler_admits_frozen_source",eligibility.ready and eligibility.groups[door_group].eligible and compiled.ready \
		and compiled.packet.building_entries.has("packet-door-leaf"))
	if not compiled.ready: return
	var trees := SyntheticTrees.new()
	var unconfigured := Job.new()
	check("packet_door_unconfigured_begin",unconfigured.begin_prepared_base(base_result.base,profile,Fixtures.BINDING,parent,trees.publish).status=="pending_budget")
	unconfigured.replace_packet_foreground_group_demands([{"ownerId":"foreground","groupIds":[door_group],"priority":0}],[],Fixtures.BINDING)
	var unconfigured_pending: Dictionary = unconfigured.pending_publication_transaction()
	check("packet_door_unconfigured_packet_retained",unconfigured_pending.status=="pending" and unconfigured.offer_physical_group_packet(compiled.packet,Fixtures.BINDING).status=="retained")
	var unconfigured_ready: Dictionary = unconfigured.pending_publication_transaction()
	var rejected: Dictionary = unconfigured.activate_physical_group_packet_scene(int(unconfigured_ready.id))
	check("packet_door_rejects_unbound_lifecycle_before_nodes",rejected.status=="rejected" and rejected.reason=="physical_packet_door_lifecycle_required" \
		and unconfigured.own_node_root()==null and unconfigured._building==null)
	unconfigured.cancel()
	await drain(unconfigured,"packet_door_unconfigured")
	var callbacks := PacketDoorCallbacks.new()
	var job := Job.new()
	check("packet_door_callbacks_bound_before_packet_begin",job.set_door_callbacks(callbacks.register_door,callbacks.retire_door))
	check("packet_door_bound_begin",job.begin_prepared_base(base_result.base,profile,Fixtures.BINDING,parent,trees.publish).status=="pending_budget")
	callbacks.job=weakref(job); callbacks.group_id=door_group
	job.replace_packet_foreground_group_demands([{"ownerId":"foreground","groupIds":[door_group],"priority":0}],[],Fixtures.BINDING)
	var pending: Dictionary = job.pending_publication_transaction()
	check("packet_door_bound_scope_pending",pending.status=="pending" and pending.groupIds==[door_group])
	if pending.status!="pending": job.cancel(); await drain(job,"packet_door_bound_setup_failed"); return
	check("packet_door_bound_packet_retained",job.offer_physical_group_packet(compiled.packet,Fixtures.BINDING).status=="retained")
	var ready: Dictionary = job.pending_publication_transaction()
	check("packet_door_bound_adapter_accepted",ready.status=="ready" and job.activate_physical_group_packet_scene(int(ready.id)).status=="pending_budget")
	for index in range(1024):
		job.advance(4000,int(ready.id))
		if job.physical_group_receipt(door_group,Fixtures.BINDING).status in ["ready","failed"]: break
	var receipt: Dictionary = job.physical_group_receipt(door_group,Fixtures.BINDING)
	var body: Node = callbacks.registered_body.get_ref() as Node if callbacks.registered_body != null else null
	var counts: Dictionary = job.status_count()
	check("packet_door_registration_precedes_exact_receipt",receipt.status=="ready" and callbacks.registrations==1 and callbacks.registered_before_receipt \
		and body is StaticBody3D and String(body.get_meta("door_portal_id",""))==callbacks.portal_id \
		and counts.doorsRegistered==1 and counts.doorClaims==1)
	job.cancel()
	await drain(job,"packet_door_bound")
	counts=job.status_count()
	check("packet_door_retirement_acknowledges_live_registered_body",callbacks.retirements==1 and callbacks.retired_with_intact_body \
		and counts.doorsRetired==1 and counts.doorClaims==0)

## This remains a source/packet contract: it deliberately creates no scene
## node. The publisher admission must reject a packet when the separately
## restored scene source no longer expresses the packet's physical member.
func jointed_packet_publisher_control() -> void:
	var blueprint := Blueprint.new("packet-jointed",2,"timber")
	blueprint.recipe={"sourceBlueprintId":"packet_jointed_history"}
	var finish=blueprint.add_part({"id":"finish","kind":"foundation","material":"cobblestone","collision":false,"position":Vector3(0,0.0625,0),"size":Vector3(4,0.125,4),"recipe":{"pavingFamily":"civic_setts"}})
	var foot=blueprint.add_part({"id":"foot","kind":"beam","material":"stone_foundation","collision":true,"position":Vector3(0,0.25,0),"size":Vector3(0.25,0.5,0.25)})
	var assembly: Dictionary=Assembly.prepare(blueprint,[finish.id],[foot],0.01)
	if not assembly.ready:
		check("jointed_packet_fixture_ready",false); return
	finish.recipe.pavingFootingJoints=assembly.joints.finish.duplicate(true)
	var plan:=Plan.new("packet-jointed-plan",2,blueprint.id)
	var building: Dictionary=blueprint.snapshot(); building.make_read_only()
	var furniture: Dictionary=plan.snapshot(); furniture.accessReservations=[]; furniture.make_read_only()
	var base_result:=Preparation.prepare_publication_base(building,furniture,Fixtures.BINDING,{"origin":Vector3.ZERO})
	var groups: Array[String]=[]
	if base_result.ready:
		for group_id in base_result.base.description.publication_groups.order:
			groups.append(String(group_id))
	var packet_result:=Preparation.compile_physical_group_packet(base_result.get("base"),groups)
	var scene:=Preparation.restore_publication_scene_source(base_result.get("base"),Fixtures.BINDING)
	var publisher:=Publisher.new(); var target:=Node3D.new(); parent.add_child(target)
	var begun:=publisher.begin_physical_group_packet_scene(base_result.get("base"),packet_result.get("packet"),scene.get("blueprint"),target,Fixtures.BINDING,{"resumableScenePublication":true})
	check("jointed_packet_hydrates_without_legacy_prepare",base_result.ready and packet_result.ready and scene.ready and begun.ready and publisher._paving_blueprint==null and publisher._physical_packet_jointed_artifacts.has("finish"))
	publisher.clear_published(); target.free()

func packet_publisher_validation_control() -> void:
	var blueprint := Blueprint.new("packet-publisher",1,"timber")
	blueprint.add_part({"id":"packet-wall","kind":"wall","material":"fired_brick",
		"size":Vector3(4,3,0.4),"position":Vector3(-6,1.5,0)})
	blueprint.add_part({"id":"packet-paving","kind":"foundation","material":"cobblestone",
		"size":Vector3(4,0.12,3),"position":Vector3(0,0.06,0),
		"recipe":{"pavingFamily":"civic_setts","pavingHeading":"x"}})
	blueprint.add_part({"id":"packet-roof","kind":"roof","material":"roof_slate",
		"size":Vector3(4,0.15,3),"position":Vector3(6,3,0)})
	var furnishings := Plan.new("packet-publisher-furnishings",1,blueprint.id)
	var building_source: Dictionary = blueprint.snapshot()
	var furnishing_source: Dictionary = furnishings.snapshot()
	furnishing_source.accessReservations=[]
	building_source.make_read_only()
	furnishing_source.make_read_only()
	var profile := frozen_profile()
	var base_result := Preparation.prepare_publication_base(building_source,furnishing_source,Fixtures.BINDING,profile)
	check("packet_publisher_base_ready",base_result.ready)
	if not base_result.ready: return
	var group_ids: Array[String] = []
	for group_id in base_result.base.description.publication_groups.order:
		group_ids.append(String(group_id))
	group_ids.sort()
	var packet_result := Preparation.compile_physical_group_packet(base_result.base,group_ids)
	var scene_result := Preparation.restore_publication_scene_source(base_result.base,Fixtures.BINDING)
	check("packet_publisher_packet_and_scene_ready",packet_result.ready and scene_result.ready)
	if not packet_result.ready or not scene_result.ready: return
	var publisher := Publisher.new()
	var admitted: Dictionary = publisher.validate_physical_group_packet(base_result.base,packet_result.packet,Fixtures.BINDING,group_ids,scene_result.blueprint)
	var member_ids: Array = admitted.get("memberIds",[])
	member_ids.sort()
	check("packet_publisher_admits_exact_value_packet",admitted.ready and member_ids==["packet-paving","packet-roof","packet-wall"])
	var rejected_root := Node3D.new()
	parent.add_child(rejected_root)
	var static_only_rejected := publisher.begin_static_only_group_packet_scene(base_result.base,packet_result.packet,scene_result.blueprint,rejected_root,Fixtures.BINDING,
		{"batchStaticParts":true,"resumableScenePublication":true,"publicationSiteId":Fixtures.BINDING.siteId})
	check("packet_publisher_static_only_entry_rejects_geometry_family",not static_only_rejected.ready and static_only_rejected.reason=="physical_packet_static_only_family_present")
	rejected_root.free()
	var packet_root := Node3D.new()
	parent.add_child(packet_root)
	var begun: Dictionary = publisher.begin_physical_group_packet_scene(base_result.base,packet_result.packet,scene_result.blueprint,packet_root,Fixtures.BINDING,
		{"batchStaticParts":true,"resumableScenePublication":true,"publicationSiteId":Fixtures.BINDING.siteId})
	check("packet_publisher_scene_begin_avoids_whole_prepare",begun.ready and publisher._masonry_preparation==null and publisher._paving_blueprint==null)
	var cursor := 0
	for attempt in range(512):
		if cursor>=scene_result.blueprint.parts.size() or publisher.publication_status().status=="failed": break
		var next: int = publisher.publish_part_batch(scene_result.blueprint,packet_root,cursor,1,4000)
		if next>cursor: cursor=next
	var boundary: Dictionary = {}
	for attempt in range(512):
		boundary=publisher.advance_publication_boundary(packet_root,4000)
		if boundary.status!="pending_budget": break
	check("packet_publisher_scene_selected_cursor",cursor==scene_result.blueprint.parts.size() and publisher.publication_status().status!="failed")
	check("packet_publisher_scene_selected_collision",publisher.collision_count==3)
	check("packet_publisher_scene_selected_boundary_ready",boundary.status=="ready")
	check("packet_publisher_scene_selected_boundary_members",boundary.committedSourcePartIds==["packet-wall","packet-paving","packet-roof"])
	publisher.clear_published()
	packet_root.queue_free()
	scene_result.blueprint.parts[0].size.x+=0.25
	var stale: Dictionary = publisher.validate_physical_group_packet(base_result.base,packet_result.packet,Fixtures.BINDING,group_ids,scene_result.blueprint)
	check("packet_publisher_rejects_changed_scene_member",not stale.ready and stale.reason=="stale_physical_group_member")


## Two disjoint packet closures share one publisher/root. This is a publisher
## session contract only: it proves a later attachment retains the first
## transaction's static collision owner and committed boundary epoch.
func packet_publisher_incremental_session_control() -> void:
	var blueprint := Blueprint.new("packet-session",1,"timber")
	blueprint.add_part({"id":"session-first","kind":"wall","material":"fired_brick","size":Vector3(2,2,0.4),"position":Vector3(-3,1,0)})
	blueprint.add_part({"id":"session-later","kind":"wall","material":"fired_brick","size":Vector3(2,2,0.4),"position":Vector3(3,1,0)})
	var furnishings := Plan.new("packet-session-furnishings",1,blueprint.id)
	var building_source: Dictionary = blueprint.snapshot(); building_source.make_read_only()
	var furnishing_source: Dictionary = furnishings.snapshot(); furnishing_source.accessReservations=[]; furnishing_source.make_read_only()
	var base_result := Preparation.prepare_publication_base(building_source,furnishing_source,Fixtures.BINDING,frozen_profile())
	if not base_result.ready:
		check("packet_session_base_ready",false)
		return
	var groups: Array[String] = []
	for group_id in base_result.base.description.publication_groups.order: groups.append(String(group_id))
	groups.sort()
	if groups.size()!=2:
		check("packet_session_two_disjoint_groups",false)
		return
	var first_groups: Array[String] = [groups[0]]
	var later_groups: Array[String] = [groups[1]]
	var first_packet := Preparation.compile_physical_group_packet(base_result.base,first_groups)
	var later_packet := Preparation.compile_physical_group_packet(base_result.base,later_groups)
	var scene := Preparation.restore_publication_scene_source(base_result.base,Fixtures.BINDING)
	var root := Node3D.new(); parent.add_child(root)
	var publisher := Publisher.new()
	var options := {"batchStaticParts":true,"resumableScenePublication":true,"publicationSiteId":Fixtures.BINDING.siteId}
	var begun := publisher.begin_physical_group_packet_scene(base_result.base,first_packet.get("packet"),scene.get("blueprint"),root,Fixtures.BINDING,options)
	check("packet_session_first_packet_ready",first_packet.ready and later_packet.ready and scene.ready and begun.ready)
	if not begun.ready:
		root.free()
		return
	var first_index: int = int(base_result.base.description.publication_groups.groups[first_groups[0]].buildingIndices[0])
	var first_cursor := first_index
	for attempt in range(128):
		first_cursor=publisher.publish_part_batch(scene.blueprint,root,first_index,1,4000)
		if first_cursor>first_index or publisher.publication_status().status=="failed": break
	var first_boundary: Dictionary = {}
	for attempt in range(128):
		first_boundary=publisher.advance_publication_boundary(root,4000)
		if first_boundary.status!="pending_budget": break
	var first_id := String(scene.blueprint.parts[first_index].id)
	var first_epoch := publisher.source_part_publication_epoch(first_id)
	var collider := publisher.static_collision_body
	var attached := publisher.attach_physical_group_packet_scene(base_result.base,later_packet.get("packet"),scene.blueprint,root,Fixtures.BINDING,options)
	check("packet_session_attach_preserves_foreground_owner",first_boundary.status=="ready" and first_epoch>0 and collider!=null and attached.ready \
		and publisher.static_collision_body==collider and publisher.source_part_publication_epoch(first_id)==first_epoch \
		and publisher._source_part_boundaries.has(first_id) and publisher._physical_packet_attached_part_ids.has(first_id))
	var duplicate := publisher.attach_physical_group_packet_scene(base_result.base,first_packet.get("packet"),scene.blueprint,root,Fixtures.BINDING,options)
	check("packet_session_rejects_previously_attached_member",not duplicate.ready and duplicate.reason=="physical_packet_member_already_attached")
	var later_index: int = int(base_result.base.description.publication_groups.groups[later_groups[0]].buildingIndices[0])
	var later_cursor := later_index
	for attempt in range(128):
		later_cursor=publisher.publish_part_batch(scene.blueprint,root,later_index,1,4000)
		if later_cursor>later_index or publisher.publication_status().status=="failed": break
	var later_boundary: Dictionary = {}
	for attempt in range(128):
		later_boundary=publisher.advance_publication_boundary(root,4000)
		if later_boundary.status!="pending_budget": break
	check("packet_session_later_boundary_keeps_prior_epoch",later_boundary.status=="ready" and publisher.source_part_publication_epoch(first_id)==first_epoch \
		and publisher.source_part_publication_epoch(String(scene.blueprint.parts[later_index].id))>first_epoch)
	publisher.clear_published()
	root.free()

func spatial_dependency_ownership() -> void:
	var prepared := holder()
	# A real sampled floor makes this an artifact ownership test, never a
	# ready-but-empty tile fabricated from an isolated post.
	prepared._payload.blueprint.add_part({"id":"spatial-floor", "kind":"floor", "material":"timber_board",
		"size":Vector3(3, 0.2, 3), "position":Vector3(0, 0.1, 0)})
	prepared._payload.spatialDependencies = Preparation.SpatialDependencies.compile(prepared._payload.blueprint,
		prepared._payload.furnishingPlan,Fixtures.BINDING,frozen_profile().origin,Callable())
	var packet_owner: WeakRef = weakref(prepared._payload.spatialDependencies)
	var job := Job.new()
	var trees := SyntheticTrees.new()
	start(job,trees,prepared)
	var bounds := Rect2i(6,13,3,3)
	var early: Dictionary = job.source_dependency_requirements(bounds,Fixtures.BINDING)
	check("spatial_unconsumed_description_available",early.status=="described" and not prepared._consumed and not early.groupIds.is_empty())
	var all_pending: bool = true
	for receipt: Dictionary in early.physicalOwnerAcknowledgements.groups.values():
		all_pending = all_pending and receipt.get("status") != "ready"
	check("spatial_unconsumed_pending",all_pending and not early.get("publicationAcknowledged",true) and job.own_node_root()==null)
	for i in range(100):
		job.advance(1)
		if job._cpu.has("buildingBegin"): break
	var described: Dictionary = job.source_dependency_requirements(bounds,Fixtures.BINDING)
	check("spatial_live_source_described",described.get("status")=="described" and described.get("partIds",[]).has("building:tiny-post"))
	check("spatial_runtime_requirements_are_owned_mutable_copy",not described.is_read_only()
		and not (described.get("requiredCrossings",{}) as Dictionary).is_read_only())
	check("spatial_not_publication_receipt",not described.get("publicationAcknowledged",true))
	var stale := Fixtures.BINDING.duplicate()
	stale.generation+=1
	check("spatial_stale_generation_pending",job.source_dependency_requirements(bounds,stale).status=="pending")
	check("navigation_unpublished_pending",job.navigation_tile_artifact("0,0",Fixtures.BINDING).status=="pending")
	for i in range(1000):
		job.advance(4000)
		if job.status().sceneReady: break
	var artifact: Dictionary = job.navigation_tile_artifact("0,0",Fixtures.BINDING)
	check("navigation_live_owner_ready",artifact.status=="ready" and not artifact.get("tile",{}).get("surfaces",[]).is_empty())
	check("navigation_stale_binding_pending",job.navigation_tile_artifact("0,0",stale).status=="pending")
	var other := Node3D.new()
	root.add_child(other)
	job.own_node_root().reparent(other,true)
	check("navigation_same_transform_wrong_parent_rejected",job.navigation_tile_artifact("0,0",Fixtures.BINDING).status=="pending")
	job.own_node_root().reparent(parent,true)
	other.free()
	job.cancel()
	check("spatial_cancel_revokes_description",job.source_dependency_requirements(bounds,Fixtures.BINDING).status=="pending")
	check("navigation_cancel_revokes_receipt",job.navigation_tile_artifact("0,0",Fixtures.BINDING).status=="pending")
	prepared=null
	await drain(job,"spatial_dependency")
	check("spatial_packet_released_with_owner",packet_owner.get_ref()==null)
