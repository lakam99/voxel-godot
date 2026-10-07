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
class PacketBackend extends Node:
	var installed: Dictionary={}
	var staged: Dictionary={}
	var release_status: Variant={"status":"released"}
	func installed_snapshot(source_id: String) -> Dictionary: return installed.get(source_id,{"generation":0})
	func begin_packet(source_id: String, owner_cell: Vector2i, generation: int, source_revision: String,
			digest: String, _transform: Transform3D, segment_count: int, instance_count: int) -> Dictionary:
		staged[source_id]={"ownerCell":owner_cell,"generation":generation,"sourceRevision":source_revision,
			"packetDigest":digest,"segmentCount":segment_count,"instanceCount":instance_count,"segments":0}
		return {"status":"ready_to_append" if segment_count>0 else "ready_to_commit"}
	func append_batch(source_id: String, _generation: int, _batch_id: String, _mesh: Mesh, _mesh_digest: String, _material: Material,
			_buffer: PackedFloat32Array, _bounds: AABB, _tier: String, _shadow: bool,
			_visibility: float, _fade: float) -> Dictionary:
		staged[source_id].segments+=1
		return {"status":"accepted"}
	func advance_packet(_source_id: String, _generation: int, _max_segments: int) -> Dictionary:
		return {"status":"ready_to_commit"}
	func commit_packet(source_id: String, generation: int) -> Dictionary:
		installed[source_id]=staged[source_id].duplicate(true)
		staged.erase(source_id)
		installed[source_id].generation=generation
		return {"status":"ready"}
	func receipt_installed(source_id: String, generation: int, source_revision: String, digest: String) -> bool:
		var value: Dictionary=installed.get(source_id,{})
		return not value.is_empty() and int(value.generation)==generation \
			and String(value.sourceRevision)==source_revision and String(value.packetDigest)==digest
	func abort_packet(source_id: String, _generation: int) -> bool:
		staged.erase(source_id)
		return true
	func release_packet(source_id: String, _generation: int) -> Variant:
		if release_status is bool and release_status or release_status is Dictionary and release_status.get("status")=="released":
			installed.erase(source_id)
		return release_status
class ReplayPublisher extends Publisher:
	var current_chunk: Node3D
	var current_backend: PacketBackend
	func resolve_chunk_render_packet_backend(_owner_cell: Vector2i) -> Dictionary:
		if not is_instance_valid(current_chunk) or not is_instance_valid(current_backend): return {"status":"pending"}
		return {"status":"ready","chunk":current_chunk,"backend":current_backend}
	func resolve_existing_chunk_render_packet_backend(_owner_cell: Vector2i) -> Dictionary:
		if not is_instance_valid(current_chunk) or not is_instance_valid(current_backend): return {"status":"pending"}
		return {"status":"ready","chunk":current_chunk,"backend":current_backend}
	func validate_static_flush_source() -> bool: return true
const ORIGINAL="res://artifacts/citadel-runtime-integration/publication-submission-reference-01/BuildingPartPublisherOriginal.gd"
const ORIGINAL_SHA="9db413eae5c45ab4ec65d3c310255c032850fb87bcf781c276d9304b07c37cc4"
class RecordingPublisher extends Publisher:
	func create_mesh_batch() -> MultiMesh: return Recorder.new()
	func submit_mesh_batch_instance(mesh: MultiMesh, index: int, transform: Transform3D, custom: Color) -> void:
		(mesh as Recorder).record_submission(index,transform,custom)
	func submit_mesh_batch_buffer(mesh: MultiMesh, buffer: PackedFloat32Array) -> void:
		(mesh as Recorder).record_buffer(buffer)
var checks: Dictionary = {}
var metrics: Dictionary = {}
func _initialize() -> void: call_deferred("run")
func check(key: String, value: bool) -> void: checks[key]=value
func run() -> void:
	if OS.get_environment("BUILDING_STATIC_FLUSH_REPLAY_ONLY")=="1":
		chunk_packet_replay_controls()
		var focused: Dictionary={"evidence":"synthetic_chunk_packet_replay_contract","checks":checks,"passed":not checks.values().has(false)}
		var focused_path:=OS.get_environment("BUILDING_STATIC_FLUSH_REPORT")
		var focused_file:=FileAccess.open(focused_path,FileAccess.WRITE)
		focused_file.store_string(JSON.stringify(focused,"\t")); focused_file.close()
		print("STATIC PACKET REPLAY ",JSON.stringify(focused))
		quit(0 if focused.passed else 1)
		return
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
		check(str(budget)+"_decoded_cpu_submissions_exact",exact)
		check(str(budget)+"_single_buffer_upload",instance.multimesh.buffer_submissions==1)
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
	var cell_parent := Node3D.new()
	root.add_child(cell_parent)
	var cell_publisher := RecordingPublisher.new()
	var cell_material := StandardMaterial3D.new()
	cell_publisher.static_visual_owner_cell=Vector2i(-1,0)
	cell_publisher.collect_static_visual_transform(Transform3D(Basis.IDENTITY,Vector3(-43.3,0,0)),cell_material)
	cell_publisher.static_visual_owner_cell=Vector2i.ZERO
	cell_publisher.collect_static_visual_transform(Transform3D(Basis.IDENTITY,Vector3(0,0,0)),cell_material)
	cell_publisher.static_visual_source_part_id="wall-a"
	cell_publisher.collect_static_visual_transform(Transform3D(Basis.IDENTITY,Vector3(1,0,0)),cell_material)
	cell_publisher.static_visual_source_part_id="wall-b"
	cell_publisher.collect_static_visual_transform(Transform3D(Basis.IDENTITY,Vector3(2,0,0)),cell_material)
	var observed_cells: Array[Vector2i]=[]
	var observed_parts: Array[String]=[]
	for group: Dictionary in cell_publisher.static_visual_batches.values():
		observed_cells.append(group.ownerCell)
		observed_parts.append(String(group.get("sourcePartId","")))
	check("owner_cell_and_source_part_batches_are_partitioned",cell_publisher.static_visual_batches.size()==4 \
		and observed_cells.has(Vector2i(-1,0)) and observed_cells.count(Vector2i.ZERO)==3 \
		and observed_parts.has("wall-a") and observed_parts.has("wall-b"))
	cell_publisher._begin_static_flush(cell_parent,false)
	while cell_publisher.has_pending_static_flush(): cell_publisher.advance_static_flush(cell_parent,4000)
	var installed_cells: Array[Vector2i]=[]
	var installed_parts: Array[String]=[]
	for visual: Node in cell_publisher.published_nodes:
		if visual is MultiMeshInstance3D:
			installed_cells.append(visual.get_meta("building_owner_cell",Vector2i(99,99)))
			installed_parts.append(String(visual.get_meta("building_source_part_id","")))
	check("owner_cell_flush_receipts_retain_partition",installed_cells.size()==4 \
		and installed_cells.has(Vector2i(-1,0)) and installed_cells.count(Vector2i.ZERO)==3 \
		and installed_parts.has("wall-a") and installed_parts.has("wall-b"))
	cell_publisher.clear_published()
	cell_parent.free()
	stale_and_pending_controls()
	failed_preparation_ownership()
	metadata_cache_controls()
	metadata_capture_controls()
	metadata_selected_controls()
	metadata_graph_controls()
	prepared_metadata_controls()
	publication_boundary_controls()
	publication_boundary_rejections()
	publication_boundary_pending_part()
	chunk_packet_replay_controls()
	original_submission_parity()
	var report: Dictionary = {"evidence":"synthetic_static_batch_flush","checks":checks,"metrics":metrics,"passed":not checks.values().has(false)}
	var path:=OS.get_environment("BUILDING_STATIC_FLUSH_REPORT")
	var file:=FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("STATIC FLUSH ",JSON.stringify(report))
	quit(0 if report.passed else 1)

func chunk_packet_replay_controls() -> void:
	var parent:=Node3D.new(); root.add_child(parent)
	var publisher:=ReplayPublisher.new()
	publisher.source_blueprint_id="replay-blueprint"
	publisher.publication_site_id="replay-site"
	publisher.unit_box=BoxMesh.new()
	var old_chunk:=Node3D.new(); old_chunk.name="Chunk_0_0"; root.add_child(old_chunk)
	var old_backend:=PacketBackend.new(); old_chunk.add_child(old_backend)
	publisher.current_chunk=old_chunk; publisher.current_backend=old_backend
	var material:=StandardMaterial3D.new()
	var buffer: Array[float]=[]
	for value in [1.0,0.0,0.0,1.0, 0.0,1.0,0.0,1.0, 0.0,0.0,1.0,1.0, 1.0,1.0,1.0,1.0]: buffer.append(value)
	buffer.make_read_only()
	var segment: Dictionary={"buffer":buffer,"bounds":AABB(Vector3(0.5,0.0,0.5),Vector3.ONE),"instanceCount":1}
	segment.make_read_only()
	var segments: Dictionary={0:segment}
	var group: Dictionary={"material":material,"transforms":[Transform3D.IDENTITY],"customData":[Color.WHITE],
		"renderTier":"structural","ownerCell":Vector2i.ZERO,"renderChunkKey":Vector2i.ZERO,
		"sourcePartId":"replay-wall",
		"sourceRevision":"revision-1","materialKey":"material-key","preparedSegments":segments}
	publisher.static_visual_batches={"group":group}
	publisher._pending_publication_boundary={"epoch":1,"sourcePartIds":["replay-wall"],
		"sourceRevisions":{"replay-wall":"revision-1"},"sourceKinds":{"replay-wall":"wall"},
		"transformArtifactRejections":{},"committed":false}
	publisher._finish_validated=true
	publisher._begin_static_flush(parent,false,true)
	var turns:=0
	while publisher.has_pending_static_flush() and turns<100:
		publisher.advance_static_flush(parent,4000); turns+=1
	var ids: Array[String]=publisher.chunk_static_packet_source_ids("replay-wall")
	var source_id:=ids[0] if not ids.is_empty() else ""
	check("static_packet_initial_receipt_installed",not source_id.is_empty() \
		and publisher.chunk_static_packet_receipt_live("replay-wall",source_id) \
		and publisher._chunk_static_packet_recipes.has(source_id))
	var retained: Dictionary=publisher._chunk_static_packet_recipes.get(source_id,{})
	check("static_packet_replay_recipe_owns_frozen_segments",not retained.is_empty() \
		and retained.preparedSegments[0].buffer.is_read_only() and retained.preparedSegments[0].is_read_only())
	old_chunk.free()
	publisher.current_chunk=Node3D.new(); publisher.current_chunk.name="Chunk_0_0"; root.add_child(publisher.current_chunk)
	publisher.current_backend=PacketBackend.new(); publisher.current_chunk.add_child(publisher.current_backend)
	var replay: Dictionary={"status":"pending_budget"}
	turns=0
	while replay.status=="pending_budget" and turns<100:
		replay=publisher.advance_chunk_static_packet_replay(parent,4000); turns+=1
	check("static_packet_replayed_after_chunk_recreation",replay.get("status")=="completed" \
		and publisher.current_backend.receipt_installed(source_id,
			int(publisher._chunk_static_packet_expected["replay-wall"][source_id].generation),
			String(publisher._chunk_static_packet_expected["replay-wall"][source_id].sourceRevision),
			String(publisher._chunk_static_packet_expected["replay-wall"][source_id].packetDigest)) \
		and publisher.chunk_static_packet_receipt_live("replay-wall",source_id))
	publisher._chunk_static_packet_expected["replay-wall"].erase(source_id)
	publisher.current_backend.release_status={"status":"failed","reason":"installed_generation_mismatch"}
	check("static_packet_failed_release_retains_retry_receipt",\
		not publisher.retire_chunk_static_packet_if_unexpected("replay-wall",source_id) \
		and publisher._chunk_static_packet_receipts.get("replay-wall",{}).has(source_id) \
		and publisher._chunk_static_packet_recipes.has(source_id) \
		and publisher.current_backend.installed.has(source_id))
	publisher.current_backend.release_status={"status":"released"}
	check("static_packet_release_ack_clears_receipt_and_recipe",\
		publisher.retire_chunk_static_packet_if_unexpected("replay-wall",source_id) \
		and not publisher._chunk_static_packet_receipts.get("replay-wall",{}).has(source_id) \
		and not publisher._chunk_static_packet_recipes.has(source_id) \
		and not publisher.current_backend.installed.has(source_id))
	parent.free(); publisher.current_chunk.free()

func drain_publication_boundary(publisher, parent: Node3D, budget: int) -> Dictionary:
	var outcome: Dictionary = {}
	for turn: int in range(10000):
		outcome = publisher.advance_publication_boundary(parent,budget)
		if outcome.status != "pending_budget": return outcome
	return {"status":"failed","reason":"synthetic_boundary_limit"}

func publication_boundary_controls() -> void:
	for budget: int in [1,4000]:
		var label: String = "boundary_"+str(budget)
		var parent: Node3D = Node3D.new()
		root.add_child(parent)
		var publisher: RecordingPublisher = RecordingPublisher.new()
		var blueprint: BuildingBlueprint = Blueprint.new("boundary",7,"timber")
		blueprint.add_part({"id":"support","kind":"post","material":"timber_beam","recipe":{"visual":false}})
		blueprint.add_part({"id":"visible_a","kind":"post","material":"timber_beam","position":Vector3(2,0,0)})
		blueprint.add_part({"id":"visible_b","kind":"post","material":"timber_beam","position":Vector3(4,0,0)})
		blueprint.add_part({"id":"door","kind":"door","material":"timber_board","position":Vector3(6,0,0)})
		check(label+"_begin",publisher.begin_publication(blueprint,parent,{"batchStaticParts":true,"resumableScenePublication":true}))
		var next: int = publisher.publish_part_batch(blueprint,parent,0,1,budget)
		var body: StaticBody3D = publisher.static_collision_body
		check(label+"_collision_before_receipt",next==1 and is_instance_valid(body) and body.get_child_count()==1 \
			and not body.has_meta("building_part_records") and publisher.source_part_publication_epoch("support")==0 \
			and publisher.static_visual_batches.is_empty())
		var first: Dictionary = drain_publication_boundary(publisher,parent,budget)
		var first_records: Dictionary = body.get_meta("building_part_records",{})
		check(label+"_collision_only_metadata_committed",first.status=="ready" and first.publicationEpoch==1 \
			and first.committedSourcePartIds==["support"] and first_records.keys()==["support"] \
			and var_to_bytes(first_records.support)==var_to_bytes(blueprint.parts[0].snapshot()) \
			and publisher.source_part_publication_epoch("support")==1 and publisher.visual_batch_count==0)
		check(label+"_no_whole_site_completion",not publisher.publication_status().complete \
			and publisher.source_part_publication_epoch("visible_a")==0 and publisher.source_part_publication_epoch("unknown")==0)
		next=publisher.publish_part_batch(blueprint,parent,1,2,budget)
		check(label+"_shared_batch_pending",next==3 and publisher.static_visual_batches.size()==1 \
			and publisher.source_part_publication_epoch("visible_a")==0 and publisher.source_part_publication_epoch("visible_b")==0 \
			and publisher.source_part_publication_epoch("support")==1 and is_same(body.get_meta("building_part_records"),first_records))
		publisher._begin_static_flush(parent,false,true)
		var receipts_hidden: bool = true
		for turn: int in range(10000):
			if publisher._static_flush.state=="commit": break
			publisher._static_flush._step(publisher)
			receipts_hidden=receipts_hidden and publisher.source_part_publication_epoch("visible_a")==0 \
				and publisher.source_part_publication_epoch("visible_b")==0 \
				and is_same(body.get_meta("building_part_records"),first_records)
		var attached_visual: MultiMeshInstance3D
		for published_node in publisher.published_nodes:
			if published_node is MultiMeshInstance3D:
				attached_visual=published_node
				break
		check(label+"_attached_visual_is_not_receipt",receipts_hidden and publisher._static_flush.state=="commit" and publisher.visual_batch_count==1)
		check(label+"_source_tier_visibility_and_shadow_policy",is_instance_valid(attached_visual) \
			and attached_visual.get_meta("building_render_tier","")=="structural" \
			and is_equal_approx(attached_visual.visibility_range_end,240.0) \
			and attached_visual.visibility_range_fade_mode==GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF \
			and attached_visual.cast_shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
		var second: Dictionary = drain_publication_boundary(publisher,parent,budget)
		check(label+"_shared_batch_atomic_receipt",second.status=="ready" and second.publicationEpoch==2 \
			and second.committedSourcePartIds==["visible_a","visible_b"] and second.committedSourcePartIds.is_read_only() \
			and publisher.source_part_publication_epoch("visible_a")==2 and publisher.source_part_publication_epoch("visible_b")==2 \
			and publisher.source_part_publication_epoch("support")==1 and first_records.keys()==["support"] \
			and body.get_meta("building_part_records").keys()==["support","visible_a","visible_b"] and publisher.visual_batch_count==1)
		var flushes: int = publisher.incremental_static_flush_count
		next=publisher.publish_part_batch(blueprint,parent,3,1,budget)
		check(label+"_direct_door_pending",next==4 and publisher.source_part_publication_epoch("door")==0 \
			and publisher.static_visual_batches.is_empty() and not publisher.has_pending_static_flush())
		var third: Dictionary = drain_publication_boundary(publisher,parent,budget)
		check(label+"_direct_node_receipt_without_static_flush",third.status=="ready" and third.publicationEpoch==3 \
			and third.committedSourcePartIds==["door"] and publisher.source_part_publication_epoch("door")==3 \
			and publisher.incremental_static_flush_count==flushes and not publisher.has_pending_static_flush())
		var repeated: Dictionary = publisher.advance_publication_boundary(parent,budget)
		check(label+"_idle_boundary_does_not_grow",repeated.status=="ready" and repeated.publicationEpoch==3 \
			and is_same(repeated.committedSourcePartIds,third.committedSourcePartIds))
		check(label+"_invalid_budget_does_not_commit",publisher.advance_publication_boundary(parent,0).status=="failed" \
			and publisher.source_part_publication_epoch("door")==3)
		var finished: Dictionary = publisher.finish_scene_publication(blueprint,parent,budget)
		check(label+"_whole_site_finishes_once",finished.complete and publisher._publication_epoch==3)
		publisher.clear_published()
		check(label+"_reset_revokes_receipts",publisher.source_part_publication_epoch("support")==0 \
			and publisher.source_part_publication_epoch("door")==0 and publisher._publication_epoch==0)
		parent.free()

func publication_boundary_rejections() -> void:
	for mode: String in ["stale_source","replaced_boundary","lost_collision_owner"]:
		var parent: Node3D = Node3D.new()
		root.add_child(parent)
		var publisher: StalePublisher = StalePublisher.new()
		var blueprint: BuildingBlueprint = Blueprint.new("rejected_boundary",9,"timber")
		blueprint.add_part({"id":"support","kind":"post","material":"timber_beam","recipe":{"visual":false}})
		check(mode+"_boundary_begin",publisher.begin_publication(blueprint,parent,{"batchStaticParts":true,"resumableScenePublication":true}))
		publisher.publish_part_batch(blueprint,parent,0,1,1)
		var body: StaticBody3D = publisher.static_collision_body
		var old: Dictionary = {"previous":{"record":[1,2,3]}}
		body.set_meta("building_part_records",old)
		publisher._begin_static_flush(parent,false,true)
		for turn: int in range(10000):
			if publisher._static_flush.state=="commit": break
			publisher._static_flush._step(publisher)
		if mode=="stale_source": publisher.source_valid=false
		elif mode=="replaced_boundary": publisher._pending_publication_boundary={}
		else: body.free()
		var outcome: Dictionary = publisher.advance_publication_boundary(parent,1)
		var metadata_unchanged: bool = not is_instance_valid(body) if mode=="lost_collision_owner" else is_same(body.get_meta("building_part_records"),old)
		check(mode+"_boundary_not_acknowledged",outcome.status=="failed" and publisher.source_part_publication_epoch("support")==0 \
			and publisher._publication_epoch==0 and metadata_unchanged)
		parent.free()
		publisher.published_nodes=[]
		publisher.static_collision_body=null
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	var publisher: StalePublisher = StalePublisher.new()
	var blueprint: BuildingBlueprint = Blueprint.new("direct_rejected_boundary",10,"timber")
	blueprint.add_part({"id":"door","kind":"door","material":"timber_board"})
	check("direct_stale_boundary_begin",publisher.begin_publication(blueprint,parent,{"batchStaticParts":true,"resumableScenePublication":true}))
	publisher.publish_part_batch(blueprint,parent,0,1,1)
	publisher.source_valid=false
	var outcome: Dictionary = publisher.advance_publication_boundary(parent,1)
	check("direct_stale_boundary_not_acknowledged",outcome.status=="failed" and outcome.reason=="stale_static_flush_source" \
		and publisher.source_part_publication_epoch("door")==0 and publisher._publication_epoch==0 and not publisher.has_pending_static_flush())
	parent.free()
	publisher.published_nodes=[]

func publication_boundary_pending_part() -> void:
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	var publisher: RecordingPublisher = RecordingPublisher.new()
	var blueprint: BuildingBlueprint = Blueprint.new("pending_boundary",11,"stone")
	blueprint.add_part({"id":"paving","kind":"foundation","material":"cobblestone","size":Vector3(4,0.12,3)})
	check("pending_boundary_begin",publisher.begin_publication(blueprint,parent,{"batchStaticParts":true,"resumableScenePublication":true}))
	var next: int = publisher.publish_part_batch(blueprint,parent,0,1,1)
	var pending: Dictionary = publisher.advance_publication_boundary(parent,1)
	check("pending_part_prevents_boundary",next==0 and pending.status=="pending_budget" and pending.reason=="part_publication_pending" \
		and publisher._pending_paving!=null and not publisher.has_pending_static_flush() and publisher.source_part_publication_epoch("paving")==0)
	for turn: int in range(10000):
		if next==1 or publisher.publication_status().status=="failed": break
		next=publisher.publish_part_batch(blueprint,parent,0,1,4000)
	var complete: Dictionary = drain_publication_boundary(publisher,parent,4000)
	check("completed_part_commits_at_boundary",next==1 and complete.status=="ready" \
		and complete.committedSourcePartIds==["paving"] and publisher.source_part_publication_epoch("paving")>0)
	parent.free()
	publisher.published_nodes=[]
	publisher.static_collision_body=null

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
	prepared_packet_submission_parity(original)
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

func prepared_packet_submission_parity(original: GDScript) -> void:
	var blueprint := Blueprint.new("packet-parity",17)
	for index in 2:
		blueprint.add_part({"id":"front_masonry_shared_family_"+str(index),"kind":"foundation" if index==0 else "wall",
			"material":"stone_foundation","size":Vector3(7.1,3.2,0.4),"position":Vector3(-7+index*10,2,9),
			"rotation":Vector3(0.12,0.37,-0.06),"recipe":{"topSurfaceMaterial":"cobblestone"}})
	var history: Dictionary = Preparation._compile_history(blueprint)
	var prepared: Dictionary = Preparation._compile_masonry(blueprint,history.preparedHistory)
	check("packet_fixture_prepared",prepared.ready and prepared.preparedMasonry!=null)
	var old_parent:=Node3D.new(); root.add_child(old_parent)
	var new_parent:=Node3D.new(); root.add_child(new_parent)
	var old=original.new()
	var current:=RecordingPublisher.new()
	for publisher in [old,current]:
		publisher.source_blueprint_id=blueprint.id
		publisher.surface_history=history.preparedHistory.history
		publisher.static_visual_collecting=true
	current._prepared_history=history.preparedHistory
	current._prepared_masonry=prepared.preparedMasonry
	current._prepared_masonry_identity=prepared.preparedMasonry
	current.resumable_scene_publication=true
	for part in blueprint.parts:
		old.static_visual_part_transform=blueprint.part_transform(part)
		current.static_visual_part_transform=blueprint.part_transform(part)
		old.publish_brick_wall(part,old_parent)
		current.publish_brick_wall(part,new_parent)
		var turns:=0
		while current._pending_masonry.state not in ["ready","failed"] and turns<10000:
			current._pending_masonry.advance(current,1)
			turns+=1
		check(part.id+"_packet_used",current._pending_masonry._packet!=null and current._pending_masonry.state=="ready")
	check("packet_ordered_geometry_exact",var_to_bytes(masonry_facts(old,old_parent))==var_to_bytes(masonry_facts(current,new_parent)))
	var materials_exact: bool=old.material_cache.keys()==current.material_cache.keys()
	for key in old.material_cache:
		for parameter in ["repair_strength","repair_phase","repair_host_base","repair_host_accent"]:
			materials_exact=materials_exact and old.material_cache[key].get_shader_parameter(parameter)==current.material_cache[key].get_shader_parameter(parameter)
	check("packet_material_first_request_exact",materials_exact)
	# Interleave a non-packet instance in an existing material group, then upload.
	var material: Material=current.material_cache.values()[0]
	current.collect_static_visual_transform(Transform3D.IDENTITY,material,Color(0.1,0.2,0.3,0.4))
	var expected: Array=[]
	var keys: Array=current.static_visual_batches.keys(); keys.sort()
	for key in keys:
		var group: Dictionary=current.static_visual_batches[key]
		for index in group.transforms.size():
			expected.append([group.transforms[index],group.customData[index]])
	current._begin_static_flush(new_parent,false)
	while current.has_pending_static_flush(): current.advance_static_flush(new_parent,2500)
	var actual: Array=[]
	for node in current.published_nodes:
		if node is MultiMeshInstance3D:
			for index in node.multimesh.instance_count:
				actual.append([node.multimesh.submissions[index*2][2],node.multimesh.submissions[index*2+1][2]])
	check("mixed_packet_buffer_decodes_exact",var_to_bytes(actual)==var_to_bytes(expected))
	old_parent.free(); new_parent.free()
	old.published_nodes=[]; current.published_nodes=[]
