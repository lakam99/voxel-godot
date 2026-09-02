extends SceneTree
## Synthetic publisher batching contract, not gameplay or runtime acceptance.
const Publisher=preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Recorder=preload("res://scripts/testing/buildings/RecordingPublicationMultiMesh.gd")
const Part=preload("res://scripts/buildings/BuildingPart.gd")
const Blueprint=preload("res://scripts/buildings/BuildingBlueprint.gd")
const Preparation=preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Plan=preload("res://scripts/buildings/FurnishingPlan.gd")
class RejectMasonry extends Publisher:
	func prepare_masonry_apertures(_blueprint) -> bool: return false
class PendingMasonry extends RefCounted:
	var state: String = "pending_budget"
	var reason: String = ""
	var metrics: Dictionary = {}
	func summary() -> Dictionary: return {}
	func _validate_all(_publisher) -> bool: return false
class StalePublisher extends RecordingPublisher:
	var source_valid: bool = true
	func validate_static_flush_source() -> bool: return source_valid
const ORIGINAL="res://artifacts/citadel-runtime-integration/publication-submission-reference-01/BuildingPartPublisherOriginal.gd"
const ORIGINAL_SHA="9db413eae5c45ab4ec65d3c310255c032850fb87bcf781c276d9304b07c37cc4"
class RecordingPublisher extends Publisher:
	func create_mesh_batch() -> MultiMesh: return Recorder.new()
	func submit_mesh_batch_instance(mesh: MultiMesh, index: int, transform: Transform3D, custom: Color) -> void:
		(mesh as Recorder).record_submission(index,transform,custom)
var checks: Dictionary = {}
var metrics: Dictionary = {}
func _initialize() -> void: call_deferred("run")
func check(key: String, value: bool) -> void: checks[key]=value
func run() -> void:
	for budget: int in [1,2500,4000]:
		var parent:=Node3D.new()
		root.add_child(parent)
		var publisher:=RecordingPublisher.new()
		var material:=StandardMaterial3D.new()
		var expected_transforms: Array = []
		var expected_custom: Array = []
		for i in range(321):
			var transform:=Transform3D(Basis.from_scale(Vector3(1,2,3)),Vector3(i,0,-i))
			var custom:=Color(float(i)/321,0.5,0.25,1)
			expected_transforms.append(transform); expected_custom.append(custom)
			publisher.collect_static_visual_transform(transform,material,custom)
			publisher.static_part_records[str(i)]={"id":str(i),"recipe":{"nested":[i,Vector3.ONE]}}
		var expected_records:=publisher.static_part_records.duplicate(true)
		var old: Dictionary = {"previous":{"record":[1,2,3]}}
		var body: StaticBody3D = publisher.static_collision_batch(parent)
		body.set_meta("building_part_records",old)
		publisher._begin_static_flush(parent,false)
		var turns:=0
		var max_atomic:=0
		var max_slice:=0
		var unchanged:=true
		while publisher.has_pending_static_flush() and turns<10000:
			var result: Dictionary = publisher.advance_static_flush(parent,budget)
			max_atomic=maxi(max_atomic,int(result.get("maxAtomicUsec",0)))
			max_slice=maxi(max_slice,int(result.get("maxSliceUsec",0)))
			turns+=1
			if publisher.has_pending_static_flush(): unchanged=unchanged and body.get_meta("building_part_records")==old
		check(str(budget)+"_completes",not publisher.has_pending_static_flush())
		check(str(budget)+"_metadata_unchanged_until_commit",unchanged)
		check(str(budget)+"_records_exact",var_to_bytes(body.get_meta("building_part_records"))==var_to_bytes(expected_records))
		check(str(budget)+"_old_snapshot_unchanged",old=={"previous":{"record":[1,2,3]}})
		publisher.static_part_records["0"].recipe.nested[0]=-1
		check(str(budget)+"_deep_snapshot_isolated",body.get_meta("building_part_records")["0"].recipe.nested[0]==0)
		var instance: MultiMeshInstance3D = publisher.published_nodes[-1] as MultiMeshInstance3D
		metrics["native_readback_"+str(budget)]={"bufferSize":instance.multimesh.buffer.size(),"transform":str(instance.multimesh.get_instance_transform(1)),"custom":str(instance.multimesh.get_instance_custom_data(1)),"expectedCustom":str(expected_custom[1])}
		var submitted: Array = instance.multimesh.submissions
		var exact:=instance!=null and instance.multimesh.instance_count==321 and submitted.size()==642
		if exact:
			for i in range(321):
				exact=exact and submitted[i*2]==["transform",i,expected_transforms[i]] and submitted[i*2+1]==["custom",i,expected_custom[i]]
		check(str(budget)+"_cpu_setter_submissions_exact",exact)
		check(str(budget)+"_configuration_exact",instance.multimesh.configuration.slice(0,4)==[MultiMesh.TRANSFORM_3D,true,false,321])
		check(str(budget)+"_boundary_retired",publisher.static_visual_batches.is_empty() and publisher.static_visual_transform_count==0 and publisher.incremental_static_flush_count==1)
		check(str(budget)+"_owned_retirement",not publisher._publication_retirement.is_empty())
		metrics[str(budget)]={"turns":turns,"maxAtomicUsec":max_atomic,"maxSliceUsec":max_slice}
		parent.free()
		publisher.published_nodes=[]; publisher.static_collision_body=null
	var parent:=Node3D.new()
	root.add_child(parent)
	var publisher:=Publisher.new()
	publisher.collect_static_visual_transform(Transform3D.IDENTITY,StandardMaterial3D.new())
	publisher._begin_static_flush(parent,false)
	parent.free()
	var lost: Dictionary = publisher._static_flush.advance(publisher,1)
	check("parent_loss_fails",lost.status=="failed" and lost.reason=="static_flush_parent_lost")
	stale_and_pending_controls()
	failed_preparation_ownership()
	original_submission_parity()
	var report: Dictionary = {"evidence":"synthetic_static_batch_flush","checks":checks,"metrics":metrics,"passed":not checks.values().has(false)}
	var path:=OS.get_environment("BUILDING_STATIC_FLUSH_REPORT")
	var file:=FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("STATIC FLUSH ",JSON.stringify(report))
	quit(0 if report.passed else 1)

func failed_preparation_ownership() -> void:
	check("failed_preparation_ownership_completed",false)
	var parent:=Node3D.new(); root.add_child(parent)
	var publisher:=RejectMasonry.new()
	var blueprint:=Blueprint.new("failed",1,"timber")
	blueprint.add_part({"id":"post","kind":"post","material":"timber_beam"})
	var reference: WeakRef = weakref(blueprint)
	var prepared:=Preparation.PreparedSource.new()
	var binding: Dictionary = {"siteId":"failed","sourceKey":"synthetic","generation":1}
	prepared._binding=binding
	prepared._payload={"blueprint":blueprint,"furnishingPlan":Plan.new("failed",1,"failed"),"physicalIntegrity":{"passed":true},"raisedRouteCoverage":{},"preparationUsec":0,"routeUsec":0,"physicalUsec":0}
	blueprint=null
	var outcome: Dictionary = publisher.begin_prepared_publication(prepared,parent,binding)
	check("failed_begin_returns_owned_payload",not outcome.ready and not outcome.retirementPayload.is_empty() and reference.get_ref()!=null)
	check("failed_begin_detaches_scene_aliases",publisher._scene_blueprint==null and publisher._scene_parent==null and parent.get_child_count()==0)
	outcome={}
	check("failed_begin_source_released_with_payload",reference.get_ref()==null)
	parent.free()
	check("failed_preparation_ownership_completed",true)

func stale_and_pending_controls() -> void:
	check("stale_and_pending_controls_completed",false)
	var parent:=Node3D.new(); root.add_child(parent)
	var publisher:=StalePublisher.new()
	publisher.collect_static_visual_transform(Transform3D.IDENTITY,StandardMaterial3D.new())
	publisher.static_part_records["new"]={"nested":[1,2,3]}
	var old: Dictionary = {"old":[4,5,6]}
	var body:=publisher.static_collision_batch(parent)
	body.set_meta("building_part_records",old)
	publisher._begin_static_flush(parent,false)
	while publisher._static_flush.state!="commit": publisher._static_flush.advance(publisher,1)
	publisher.source_valid=false
	var rejected: Dictionary = publisher.advance_static_flush(parent,1)
	check("stale_flush_rejects_before_replacement",rejected.status=="failed" and body.get_meta("building_part_records")==old)
	parent.free(); publisher.published_nodes=[]; publisher.static_collision_body=null
	parent=Node3D.new(); root.add_child(parent)
	var legacy:=Publisher.new()
	var blueprint:=Blueprint.new("pending",1,"timber")
	legacy._scene_blueprint=blueprint; legacy._scene_parent=weakref(parent)
	legacy._masonry_preparation=PendingMasonry.new()
	var started:=Time.get_ticks_msec()
	legacy.finish_publication(blueprint,parent)
	check("legacy_finish_does_not_spin_pending_masonry",Time.get_ticks_msec()-started<1000)
	parent.free()
	for mode: String in ["blueprint","parent","part","history"]:
		parent=Node3D.new(); root.add_child(parent)
		var other_parent:=Node3D.new(); root.add_child(other_parent)
		var current:=RecordingPublisher.new()
		blueprint=Blueprint.new("pending_paving",1,"stone")
		blueprint.add_part({"id":"floor","kind":"foundation","material":"cobblestone","size":Vector3(4,0.12,3)})
		check(mode+"_pending_begin",current.begin_publication(blueprint,parent,{"batchStaticParts":true,"resumableScenePublication":true}))
		current.publish_part_batch(blueprint,parent,0,1,1)
		current.publish_part_batch(blueprint,parent,0,1,1) # Capture the private history once.
		check(mode+"_pending_not_advanced",current.incremental_published_parts==0 and current._pending_paving!=null)
		match mode:
			"blueprint": current.publish_part_batch(Blueprint.new("other",1,"stone"),parent,0,1,1)
			"parent": current.publish_part_batch(blueprint,other_parent,0,1,1)
			"part":
				blueprint.parts[0].position+=Vector3.ONE
				current.publish_part_batch(blueprint,parent,0,1,1)
			"history":
				current.surface_history.route_corridors.append({"changed":true})
				check("history_private_snapshot_unaliased",current._paving_history_snapshot.route_corridors.is_empty())
				for i in range(100):
					current.publish_part_batch(blueprint,parent,0,1,4000)
					if current.publication_status().status=="failed": break
		check(mode+"_pending_change_rejected",current.publication_status().status=="failed" and current.incremental_published_parts==0)
		parent.free(); other_parent.free()
		current.published_nodes=[]; current.static_collision_body=null
	check("stale_and_pending_controls_completed",true)

func original_submission_parity() -> void:
	check("old_new_submission_completed",false)
	check("frozen_original_hash",FileAccess.get_sha256(ORIGINAL)==ORIGINAL_SHA)
	if not checks.frozen_original_hash: return
	var source:=FileAccess.get_file_as_string(ORIGINAL)
	# Test-only recording adapter: native methods cannot be virtually overridden.
	# Remove duplicate global registration; replace construction and the adjacent
	# setter pair ONLY. Loop ordering, arguments and transformations stay original.
	source=source.replace("class_name BuildingPartPublisher","")
	source=source.replace("MultiMesh.new()","preload(\"res://scripts/testing/buildings/RecordingPublicationMultiMesh.gd\").new()")
	source=source.replace("multi_mesh.set_instance_transform(index, instance_transform)\n\t\tmulti_mesh.set_instance_custom_data(index, custom_data[index] as Color)","multi_mesh.record_submission(index, instance_transform, custom_data[index] as Color)")
	var original:=GDScript.new()
	original.source_code=source
	if original.reload()!=OK: return
	for collecting: bool in [false,true]:
		var parent:=Node3D.new(); root.add_child(parent)
		var old=original.new()
		var current:=RecordingPublisher.new()
		var transforms: Array = []
		var custom: Array = []
		for i in range(47):
			transforms.append(Transform3D(Basis.from_euler(Vector3(0.1,float(i)/47,-0.03)),Vector3(i,-i*0.5,2)))
			custom.append(Color(float(i)/47,0.3,0.7,1))
		var material:=StandardMaterial3D.new()
		var frame:=Transform3D(Basis(Vector3.UP,0.4),Vector3(10,3,-8))
		old.static_visual_collecting=collecting; old.static_visual_part_transform=frame
		current.static_visual_collecting=collecting; current.static_visual_part_transform=frame
		var a: MultiMeshInstance3D = old.add_mesh_batch(parent,old.unit_box,transforms,material,"old",custom)
		var b: MultiMeshInstance3D = current.add_mesh_batch(parent,current.unit_box,transforms,material,"new",custom)
		var expected: Array = a.multimesh.submissions
		var actual: Array = b.multimesh.submissions
		check(str(collecting)+"_old_native_calls_intercepted",expected.size()==94 and actual.size()==94)
		check(str(collecting)+"_old_new_configuration",var_to_bytes(a.multimesh.configuration)==var_to_bytes(b.multimesh.configuration))
		check(str(collecting)+"_old_new_submissions",not expected.is_empty() and var_to_bytes(expected)==var_to_bytes(actual))
		var changed:=actual.duplicate(true)
		if not changed.is_empty(): changed[-1][2]=Color.WHITE
		check(str(collecting)+"_altered_submission_rejected",var_to_bytes(expected)!=var_to_bytes(changed))
		parent.free()
		old.published_nodes=[]; current.published_nodes=[]
	for collecting: bool in [false,true]:
		var old_parent:=Node3D.new(); root.add_child(old_parent)
		var new_parent:=Node3D.new(); root.add_child(new_parent)
		var old=original.new()
		var current:=RecordingPublisher.new()
		old.source_blueprint_id="submission"; current.source_blueprint_id="submission"
		old.static_visual_collecting=collecting; current.static_visual_collecting=collecting
		var frame:=Transform3D(Basis(Vector3.UP,0.4),Vector3(10,3,-8))
		old.static_visual_part_transform=frame; current.static_visual_part_transform=frame
		var part:=Part.new({"id":"paving","kind":"foundation","material":"cobble","size":Vector3(8,0.13,5),"position":Vector3(-5,1,9),"recipe":{"pavingFamily":"civic_setts"}})
		old.publish_settled_cobble(part,old_parent)
		current.resumable_scene_publication=true
		current.publish_settled_cobble(part,new_parent)
		var turns:=0
		while current._pending_paving.state not in ["ready","failed"] and turns<10000:
			current._pending_paving.advance(current,1)
			turns+=1
		var expected: Array = []
		var actual: Array = []
		for node: Node in old_parent.get_children():
			if node is MultiMeshInstance3D: expected.append([node.name,node.multimesh.configuration,node.multimesh.submissions])
		for node: Node in new_parent.get_children():
			if node is MultiMeshInstance3D: actual.append([node.name,node.multimesh.configuration,node.multimesh.submissions])
		check(str(collecting)+"_paving_tiny_budget_completes",current._pending_paving.state=="ready" and turns>1)
		check(str(collecting)+"_paving_old_new_submission",not expected.is_empty() and var_to_bytes(expected)==var_to_bytes(actual))
		old_parent.free(); new_parent.free()
		old.published_nodes=[]; current.published_nodes=[]
	check("old_new_submission_completed",true)
