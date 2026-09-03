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
	metadata_cache_controls()
	metadata_capture_controls()
	metadata_selected_controls()
	metadata_graph_controls()
	prepared_metadata_controls()
	original_submission_parity()
	var report: Dictionary = {"evidence":"synthetic_static_batch_flush","checks":checks,"metrics":metrics,"passed":not checks.values().has(false)}
	var path:=OS.get_environment("BUILDING_STATIC_FLUSH_REPORT")
	var file:=FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("STATIC FLUSH ",JSON.stringify(report))
	quit(0 if report.passed else 1)

func drain_metadata(publisher, parent: Node3D) -> bool:
	publisher.collect_static_visual_transform(Transform3D.IDENTITY,StandardMaterial3D.new())
	publisher._begin_static_flush(parent,false)
	for i in range(10000):
		if not publisher.has_pending_static_flush(): return not publisher._publication_failed()
		if publisher.advance_static_flush(parent,2500).status=="failed": return false
	return false

func metadata_cache_controls() -> void:
	check("metadata_cache_controls_completed",false)
	var parent:=Node3D.new(); root.add_child(parent)
	var publisher:=StalePublisher.new()
	var typed: Array[Vector3] = [Vector3.ONE,Vector3.ZERO]
	for i in range(50): publisher.static_part_records[str(i)]={"id":str(i),"recipe":{"nested":[i,{"typed":typed.duplicate()}]}}
	var body:=publisher.static_collision_batch(parent)
	check("cache_first_flush",drain_metadata(publisher,parent))
	var first: Dictionary = body.get_meta("building_part_records")
	var first_bytes:=var_to_bytes(first)
	check("cache_records_deeply_immutable",first["0"].is_read_only() and first["0"].recipe.is_read_only() and first["0"].recipe.nested.is_read_only() and first["0"].recipe.nested[1].typed.is_read_only())
	publisher.static_part_records["new"]={"id":"new","recipe":{"nested":[100]}}
	check("cache_second_flush",drain_metadata(publisher,parent))
	var second: Dictionary = body.get_meta("building_part_records")
	check("cache_independent_prefix_shared_record",not is_same(first,second) and is_same(first["0"],second["0"]))
	check("cache_reuses_exact_records",publisher._static_record_cache_stats.copies==51 and publisher._static_record_cache_stats.hits==50)
	check("cache_preserves_typed_ordered_bytes",var_to_bytes(second)==var_to_bytes(publisher.static_part_records))
	publisher.static_part_records["0"].recipe.nested[0]=123
	publisher.static_part_records.erase("1")
	check("cache_changed_record_flush",drain_metadata(publisher,parent))
	var third: Dictionary = body.get_meta("building_part_records")
	check("cache_changed_record_isolated",not is_same(second["0"],third["0"]) and third["0"].recipe.nested[0]==123 and second["0"].recipe.nested[0]==0)
	check("cache_drops_removed_record",not third.has("1") and not publisher._static_record_cache.has("1"))
	check("cache_previous_snapshot_unchanged",var_to_bytes(first)==first_bytes)
	check("cache_changed_exact_source",var_to_bytes(third)==var_to_bytes(publisher.static_part_records))
	publisher.static_part_records["1"]={"id":"1","recipe":{"nested":[1,{"typed":typed.duplicate()}]}}
	check("cache_readd_flush",drain_metadata(publisher,parent))
	var readded: Dictionary = body.get_meta("building_part_records")
	check("cache_readd_not_removed_entry",readded.has("1") and not is_same(first["1"],readded["1"]))
	publisher.static_part_records["2"].recipe["other"]=7
	check("cache_key_order_setup",drain_metadata(publisher,parent))
	var before_order: Dictionary = body.get_meta("building_part_records")
	var nested: Array = publisher.static_part_records["2"].recipe.nested
	publisher.static_part_records["2"].recipe={"other":7,"nested":nested}
	check("cache_key_order_flush",drain_metadata(publisher,parent))
	var after_order: Dictionary = body.get_meta("building_part_records")
	check("cache_key_order_identity_exact",not is_same(before_order["2"],after_order["2"]) and var_to_bytes(after_order)==var_to_bytes(publisher.static_part_records))
	publisher.static_part_records["2"].recipe.nested[1].typed=[Vector3.ONE,Vector3.ZERO]
	check("cache_type_change_flush",drain_metadata(publisher,parent))
	var after_type: Dictionary = body.get_meta("building_part_records")
	check("cache_typed_identity_exact",after_order["2"].recipe.nested[1].typed.is_typed() and not after_type["2"].recipe.nested[1].typed.is_typed() and not is_same(after_order["2"],after_type["2"]))
	publisher.static_part_records["packed"]={"id":"packed","recipe":{"packed":PackedFloat32Array([1.0,2.0])}}
	check("cache_unsupported_first_flush",drain_metadata(publisher,parent))
	var packed_first: Dictionary = body.get_meta("building_part_records")
	check("cache_unsupported_second_flush",drain_metadata(publisher,parent))
	var packed_second: Dictionary = body.get_meta("building_part_records")
	check("cache_unsupported_copied_not_reused",not is_same(packed_first["packed"],packed_second["packed"]) and not publisher._static_record_cache["packed"].reusable and publisher._static_record_cache_stats.unsupportedCopies==2)
	check("cache_unsupported_type_preserved",typeof(packed_second["packed"].recipe.packed)==TYPE_PACKED_FLOAT32_ARRAY and var_to_bytes(packed_second)==var_to_bytes(publisher.static_part_records))
	check("cache_unsupported_containers_unfrozen",not packed_second["packed"].is_read_only() and not packed_second["packed"].recipe.is_read_only())
	packed_second["packed"].recipe["copyOnly"]=true
	check("cache_unsupported_copy_mutation_isolated",not packed_first["packed"].recipe.has("copyOnly") and not publisher.static_part_records["packed"].recipe.has("copyOnly"))
	var resource:=Resource.new()
	publisher.static_part_records["resource"]={"id":"resource","recipe":{"resource":resource}}
	check("cache_resource_first_flush",drain_metadata(publisher,parent))
	var resource_first: Dictionary = body.get_meta("building_part_records")
	check("cache_resource_second_flush",drain_metadata(publisher,parent))
	var resource_second: Dictionary = body.get_meta("building_part_records")
	check("cache_resource_not_reused",not is_same(resource_first["resource"],resource_second["resource"]) and not publisher._static_record_cache["resource"].reusable)
	check("cache_resource_legacy_reference_semantics",resource_first["resource"].recipe.resource==resource and resource_second["resource"].recipe.resource==resource)
	check("cache_resource_containers_unfrozen",not resource_second["resource"].is_read_only() and not resource_second["resource"].recipe.is_read_only())
	publisher.static_part_records["path"]={"id":"path","recipe":{"nodePath":NodePath("a/b")}}
	check("cache_node_path_first_flush",drain_metadata(publisher,parent))
	var path_first: Dictionary = body.get_meta("building_part_records")
	check("cache_node_path_second_flush",drain_metadata(publisher,parent))
	resource_second=body.get_meta("building_part_records")
	check("cache_node_path_stable_reuse",is_same(path_first.path,resource_second.path) and resource_second.path.recipe.nodePath==NodePath("a/b"))
	var typed_resources: Array[Resource] = []
	publisher.static_part_records["typedObjects"]={"recipe":{"objects":typed_resources}}
	check("cache_empty_object_container_flush",drain_metadata(publisher,parent))
	resource_second=body.get_meta("building_part_records")
	check("cache_empty_object_container_unfrozen",not resource_second.typedObjects.is_read_only() and not resource_second.typedObjects.recipe.objects.is_read_only() and not publisher._static_record_cache.typedObjects.reusable)
	var accepted_cache: Dictionary = publisher._static_record_cache
	var accepted_copies: int = publisher._static_record_cache_stats.copies
	publisher.static_part_records["new"].recipe.nested[0]=999
	publisher.collect_static_visual_transform(Transform3D.IDENTITY,StandardMaterial3D.new())
	publisher._begin_static_flush(parent,false)
	while publisher._static_flush.state!="commit": publisher._static_flush.advance(publisher,1)
	publisher.source_valid=false
	var rejected: Dictionary = publisher.advance_static_flush(parent,1)
	check("cache_rejection_does_not_publish_staged_entries",rejected.status=="failed" and is_same(accepted_cache,publisher._static_record_cache) and publisher._static_record_cache_stats.copies==accepted_copies and is_same(resource_second,body.get_meta("building_part_records")))
	parent.free(); publisher.published_nodes=[]; publisher.static_collision_body=null
	publisher.clear_published()
	check("cache_reset_isolated",publisher._static_record_cache.is_empty() and publisher._static_record_cache_stats.copies==0 and publisher._static_record_cache_stats.hits==0)
	check("metadata_cache_controls_completed",true)

func metadata_capture_controls() -> void:
	check("metadata_capture_controls_completed",false)
	for mode: String in ["nested","replace","remove","add","nested_remove","nested_add"]:
		var parent:=Node3D.new(); root.add_child(parent)
		var publisher:=StalePublisher.new()
		publisher.static_part_records["record"]={"recipe":{"nested":[1,2,3]}}
		var body:=publisher.static_collision_batch(parent)
		var old: Dictionary = {"old":true}
		body.set_meta("building_part_records",old)
		publisher.collect_static_visual_transform(Transform3D.IDENTITY,StandardMaterial3D.new())
		publisher._begin_static_flush(parent,false)
		while publisher._static_flush.state!="metadata_copy": publisher._static_flush.advance(publisher,1)
		match mode:
			"nested": publisher.static_part_records.record.recipe.nested[0]=99
			"replace": publisher.static_part_records.record={"recipe":{"different":true}}
			"remove": publisher.static_part_records.erase("record")
			"add": publisher.static_part_records["late"]={"recipe":{}}
			"nested_remove": publisher.static_part_records.record.erase("recipe")
			"nested_add": publisher.static_part_records.record["late"]=true
		var result: Dictionary = {}
		for i in range(1000):
			result=publisher.advance_static_flush(parent,1)
			if result.status!="pending_budget": break
		check("cache_capture_"+mode+"_rejects",result.status=="failed" and publisher._static_record_cache.is_empty() and is_same(old,body.get_meta("building_part_records")))
		parent.free(); publisher.published_nodes=[]; publisher.static_collision_body=null
	check("metadata_capture_controls_completed",true)

func metadata_selected_controls() -> void:
	check("metadata_selected_controls_completed",false)
	for reuse: bool in [false,true]:
		var parent:=Node3D.new(); root.add_child(parent)
		var publisher:=StalePublisher.new()
		publisher.static_part_records={"first":{"nested":[1]},"second":{"nested":[2]}}
		var body:=publisher.static_collision_batch(parent)
		body.set_meta("building_part_records",{"old":true})
		if reuse: check("selected_reuse_setup",drain_metadata(publisher,parent))
		var old: Dictionary = body.get_meta("building_part_records")
		var cache: Dictionary = publisher._static_record_cache
		publisher.collect_static_visual_transform(Transform3D.IDENTITY,StandardMaterial3D.new())
		publisher._begin_static_flush(parent,false)
		# Explicit unit stepping injects mutation after selection, before commit.
		for i in range(1000):
			publisher._static_flush._step(publisher)
			if publisher._static_flush._record_index==1: break
		check(str(reuse)+"_selected_first_record",publisher._static_flush._record_index==1)
		publisher.static_part_records.first.nested[0]=99
		var outcome: Dictionary = {}
		for i in range(1000):
			outcome=publisher.advance_static_flush(parent,1)
			if outcome.status!="pending_budget": break
		check(str(reuse)+"_selected_mutation_rejected",outcome.status=="failed" and outcome.reason=="metadata_source_changed_during_copy" and is_same(old,body.get_meta("building_part_records")) and is_same(cache,publisher._static_record_cache))
		parent.free(); publisher.published_nodes=[]; publisher.static_collision_body=null
	check("metadata_selected_controls_completed",true)

func prepared_metadata_controls() -> void:
	check("prepared_metadata_controls_completed",false)
	for mode: String in ["unchanged","part_changed","identity_changed"]:
		var parent:=Node3D.new(); root.add_child(parent)
		var publisher:=StalePublisher.new()
		var blueprint:=Blueprint.new("prepared",1,"timber")
		blueprint.add_part({"id":"post","kind":"post","material":"timber_beam","recipe":{"visual":false,"nodePath":NodePath("a/b")}})
		var compiled:=Preparation._compile_static_records(blueprint)
		publisher._prepared_static_records=compiled.staticRecords
		publisher._prepared_static_bindings=compiled.staticRecordBindings
		if mode=="part_changed": blueprint.parts[0].position+=Vector3.ONE
		publisher.publish_static_part(blueprint.parts[0],parent)
		if mode=="part_changed":
			check("prepared_changed_part_rejected_before_collision",publisher._publication_failed() and parent.get_child_count()==0 and publisher.static_part_records.is_empty())
		else:
			var body:=publisher.static_collision_batch(parent)
			var old: Dictionary = {"old":true}
			body.set_meta("building_part_records",old)
			publisher.collect_static_visual_transform(Transform3D.IDENTITY,StandardMaterial3D.new())
			publisher._begin_static_flush(parent,false)
			for i in range(1000):
				publisher._static_flush._step(publisher)
				if publisher._static_flush.state=="commit": break
			if mode=="identity_changed": publisher.static_part_records.post=publisher.static_part_records.post.duplicate(true)
			var outcome: Dictionary = publisher.advance_static_flush(parent,1)
			if mode=="identity_changed":
				check("prepared_equal_but_replaced_record_rejected",outcome.status=="failed" and is_same(old,body.get_meta("building_part_records")) and publisher._static_record_cache.is_empty())
			else:
				check("prepared_immutable_record_reused",outcome.status=="ready" and is_same(body.get_meta("building_part_records").post,compiled.staticRecords.post))
				check("prepared_no_main_copy",publisher._static_record_cache_stats.copies==0 and publisher._static_record_cache_stats.preparedHits==1)
		parent.free(); publisher.published_nodes=[]; publisher.static_collision_body=null
	check("prepared_metadata_controls_completed",true)

func metadata_graph_controls() -> void:
	check("metadata_graph_controls_completed",false)
	for mode: String in ["cycle","depth","late_cycle"]:
		var parent:=Node3D.new(); root.add_child(parent)
		var publisher:=StalePublisher.new()
		var graph: Array = []
		if mode=="cycle": graph.append(graph)
		elif mode=="depth":
			var cursor: Array = graph
			for i in range(130):
				var child: Array = []
				cursor.append(child); cursor=child
		publisher.static_part_records={"record":{"nested":graph}}
		var body:=publisher.static_collision_batch(parent)
		var old: Dictionary = {"old":true}
		body.set_meta("building_part_records",old)
		publisher.collect_static_visual_transform(Transform3D.IDENTITY,StandardMaterial3D.new())
		publisher._begin_static_flush(parent,false)
		if mode=="late_cycle":
			for i in range(1000):
				publisher._static_flush._step(publisher)
				if publisher._static_flush.state=="commit": break
			graph.append(graph)
		var result: Dictionary = {}
		for i in range(1000):
			result=publisher.advance_static_flush(parent,1)
			if result.status!="pending_budget": break
		check(mode+"_malformed_graph_rejected",result.status=="failed" and result.reason=="unsupported_metadata_graph" and publisher._static_record_cache.is_empty() and is_same(old,body.get_meta("building_part_records")))
		graph.clear()
		parent.free(); publisher.published_nodes=[]; publisher.static_collision_body=null
	check("metadata_graph_controls_completed",true)

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
	var compiled:=Preparation._compile_static_records(blueprint)
	prepared._payload["staticRecords"]=compiled.staticRecords
	prepared._payload["staticRecordBindings"]=compiled.staticRecordBindings
	blueprint=null
	var outcome: Dictionary = publisher.begin_prepared_publication(prepared,parent,binding)
	check("failed_begin_returns_owned_payload",not outcome.ready and not outcome.retirementPayload.is_empty() and reference.get_ref()!=null)
	check("failed_begin_detaches_scene_aliases",publisher._scene_blueprint==null and publisher._scene_parent==null and parent.get_child_count()==0)
	check("failed_begin_detaches_prepared_metadata",publisher._prepared_static_records.is_empty() and publisher._prepared_static_bindings.is_empty() and is_same(outcome.retirementPayload.staticRecords,compiled.staticRecords) and is_same(outcome.retirementPayload.scenePreparation.staticRecordBindings,compiled.staticRecordBindings))
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
	masonry_submission_parity(original)
	check("old_new_submission_completed",true)

func masonry_submission_parity(original: GDScript) -> void:
	check("masonry_submission_controls_completed",false)
	for collecting: bool in [false,true]:
		for kind: String in ["wall","foundation"]:
			var old_parent:=Node3D.new(); root.add_child(old_parent)
			var new_parent:=Node3D.new(); root.add_child(new_parent)
			var old=original.new()
			var current:=RecordingPublisher.new()
			old.source_blueprint_id="masonry-submission"; current.source_blueprint_id="masonry-submission"
			old.static_visual_collecting=collecting; current.static_visual_collecting=collecting
			var frame:=Transform3D(Basis(Vector3.UP,0.4),Vector3(10,3,-8))
			old.static_visual_part_transform=frame; current.static_visual_part_transform=frame
			var part:=Part.new({"id":"front_masonry","kind":kind,"material":"stone_foundation","size":Vector3(5,3,0.4),"position":Vector3(-5,1,9),"recipe":{"topSurfaceMaterial":"cobblestone"}})
			old.publish_brick_wall(part,old_parent)
			current.resumable_scene_publication=true
			current.publish_brick_wall(part,new_parent)
			var turns:=0
			while current._pending_masonry.state not in ["ready","failed"] and turns<10000:
				current._pending_masonry.advance(current,1)
				turns+=1
			var label:=str(collecting)+"_"+kind
			check(label+"_masonry_pending_complete",current._pending_masonry.state=="ready" and turns>1)
			check(label+"_masonry_cpu_submissions_exact",var_to_bytes(masonry_facts(old,old_parent))==var_to_bytes(masonry_facts(current,new_parent)))
			old_parent.free(); new_parent.free()
			old.published_nodes=[]; current.published_nodes=[]
	check("masonry_submission_controls_completed",true)

func masonry_facts(publisher, parent: Node3D) -> Dictionary:
	var facts: Dictionary={"materials":publisher.material_cache.keys(),"repairs":publisher.masonry_repair_clusters,"batches":[],"nodes":[]}
	for group in publisher.static_visual_batches.values():
		facts.batches.append([publisher.material_cache.find_key(group.material),group.transforms,group.customData])
	for node: Node3D in parent.get_children():
		if node is MultiMeshInstance3D:
			facts.nodes.append([node.name,node.transform,publisher.material_cache.find_key(node.material_override),node.multimesh.configuration,node.multimesh.submissions])
		elif node is MeshInstance3D:
			facts.nodes.append([node.name,node.transform,publisher.material_cache.find_key(node.material_override)])
	return facts
