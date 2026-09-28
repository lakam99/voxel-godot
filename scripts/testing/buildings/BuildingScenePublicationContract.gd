extends SceneTree
## Historical source -> real scene publishers and shared production tree queue.
## Main gameplay boot is suppressed. Door ownership uses the explicitly
## synthetic callback below. This is not live-world/visual/door acceptance.
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Controls = preload("res://scripts/testing/buildings/BuildingPublicationWorkerContract.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"

class MainFixture extends "res://scripts/Main.gd":
	func _ready() -> void: pass
	func _process(_delta: float) -> void: pass
	func _physics_process(_delta: float) -> void: pass

class SummarySpy extends Publisher:
	var summary_calls := 0
	func summary() -> Dictionary:
		summary_calls += 1
		return super.summary()

## The historical-source scene fixture does not boot NPC/door registries.
## This adapter proves balanced callback ownership only; it grants no gameplay
## door authority and is never used by a production runtime or headed runner.
class SyntheticDoorLifecycle extends RefCounted:
	var claims: Dictionary = {}
	var registered: int = 0
	var retired: int = 0
	var retire_before_free: bool = true
	func register(body: StaticBody3D) -> Dictionary:
		var id: String = String(body.get_meta("door_portal_id", ""))
		if id.is_empty() or claims.has(id): return {"status":"failed", "reason":"synthetic_door_identity"}
		claims[id] = weakref(body)
		registered += 1
		return {"status":"registered", "portalId":id}
	func retire(body: StaticBody3D) -> Dictionary:
		var id: String = String(body.get_meta("door_portal_id", ""))
		if not claims.has(id) or claims[id].get_ref() != body:
			return {"status":"failed", "reason":"synthetic_door_retirement_identity"}
		retire_before_free = retire_before_free and is_instance_valid(body) and body.get_parent() != null
		claims.erase(id)
		retired += 1
		return {"status":"unregistered", "portalId":id}

var checks := {}
var metrics := {}
var output := ""
var actual_requested := false
func _initialize() -> void: call_deferred("_run")
func check(label: String, ok: bool) -> void:
	checks[label] = ok
	if not ok: print("SCENE PUBLICATION CHECK FAILED ",label)
func progress(label: String, values: Dictionary = {}) -> void:
	print("SCENE PUBLICATION ",label," ",JSON.stringify(values))
	var file := FileAccess.open(output+"/progress.txt",FileAccess.WRITE)
	file.store_string(label+" "+JSON.stringify(values)); file.close()

func publisher_facade() -> void:
	for site: String in ["","synthetic-site-a","synthetic-site-b"]:
		var parent := Node3D.new()
		parent.position = Vector3(110,17,-40)
		root.add_child(parent)
		var blueprint := Blueprint.new("shared-recipe",8,"timber")
		blueprint.add_part({"id":"door","kind":"door","material":"timber_board","size":Vector3(1.3,2.2,0.12),"position":Vector3(2,1.1,0)})
		var publisher := SummarySpy.new()
		check(site+"_not_started_rejects",publisher.publication_status().status=="failed")
		check(site+"_begin",publisher.begin_publication(blueprint,parent,{"publicationSiteId":site}))
		var before := var_to_bytes(blueprint.snapshot())
		check(site+"_bad_budget_rejected",publisher.advance_scene_preparation(4001).status=="failed")
		check(site+"_ready_status",publisher.advance_scene_preparation(1).status=="ready")
		check(site+"_batch_progress",publisher.publish_part_batch(blueprint,parent,0,1)==1)
		var result := publisher.finish_scene_publication(blueprint,parent)
		check(site+"_complete",result.status=="ready" and result.complete and result.publishedPartCount==1)
		check(site+"_no_proof_summary_copy",publisher.summary_calls==0 and not result.has("physicalIntegrity"))
		var door: Node3D = publisher.published_nodes[0]
		var expected_site := site if not site.is_empty() else "shared-recipe"
		check(site+"_door_namespace",door.get_meta("door_portal_id")=="building:%s:door"%expected_site and door.get_meta("door_building_id")==expected_site)
		check(site+"_exact_local_and_world_transform",door.position==Vector3(2,1.1,0) and door.global_position.is_equal_approx(parent.position+door.position))
		check(site+"_source_unchanged",before==var_to_bytes(blueprint.snapshot()))
		var legacy := publisher.finish_publication(blueprint,parent)
		check(site+"_legacy_full_summary_retained",publisher.summary_calls==1 and legacy.has("physicalIntegrity") and legacy.publishedPartCount==1)
		publisher.clear_published()
		check(site+"_clear_resets_site_and_state",publisher.publication_site_id.is_empty() and not publisher.publication_status().complete)
		await process_frame
		parent.free()

static func load_source() -> Dictionary:
	if FileAccess.get_sha256(INPUT)!=SHA: return {}
	var file := FileAccess.open(INPUT,FileAccess.READ)
	var source: Dictionary = file.get_var(false)
	file.close()
	Controls.freeze(source)
	return source

func actual_publication() -> void:
	actual_requested = true
	# A script error can abort a nested call without aborting this coroutine.
	# The audit must explicitly finish; omitted checks must never imply success.
	check("actual_scene_audit_completed",false)
	progress("loading_historical_source")
	var loader := Thread.new()
	check("actual_loader_started",loader.start(load_source)==OK)
	while loader.is_alive(): await process_frame
	var source: Dictionary = loader.wait_to_finish()
	check("actual_fixture_hash",not source.is_empty())
	if source.is_empty(): return
	var profile: Dictionary = source.profile
	var binding := {"siteId":profile.siteId,"sourceKey":"historical_actual_source:"+SHA,"generation":1}
	var worker := Worker.new()
	var receipt := worker.dispatch(source,binding)
	source = {}
	check("actual_preparation_queued",receipt.status=="queued")
	progress("background_preparation")
	var background_started:=Time.get_ticks_usec()
	var deadline := Time.get_ticks_msec()+60000
	var preparation: Dictionary = worker.poll()
	while preparation.completedToken==0 and Time.get_ticks_msec()<deadline:
		await process_frame
		preparation = worker.poll()
	var completed: Dictionary = worker.take_result(receipt.token,binding)
	metrics.backgroundPreparationElapsedUsec=Time.get_ticks_usec()-background_started
	check("actual_preparation_ready",completed.get("result",{}).get("ready",false))
	if not checks.actual_preparation_ready:
		worker.request_shutdown()
		while not worker.poll().shutdownComplete: await process_frame
		return
	var main := MainFixture.new()
	main.seed_text = "atlas-1492"
	root.add_child(main)
	main.set_process(false); main.set_physics_process(false)
	var parent := Node3D.new()
	# Deliberately translated parent proves profile.origin is applied once.
	parent.position = Vector3(13,5,-19)
	main.add_child(parent)
	var job_script = load("res://scripts/buildings/BuildingScenePublicationJob.gd")
	var job = job_script.new()
	var synthetic_doors: SyntheticDoorLifecycle = SyntheticDoorLifecycle.new()
	check("actual_synthetic_door_callbacks_bound",job.set_door_callbacks(synthetic_doors.register,synthetic_doors.retire))
	metrics.metadataPreparationUsec=completed.result.prepared._payload.get("metadataPreparationUsec",0)
	metrics.historyPreparationUsec=completed.result.prepared._payload.get("historyPreparationUsec",0)
	metrics.masonryPreparationUsec=completed.result.prepared._payload.get("masonryPreparationUsec",0)
	metrics.surfacePreparationUsec=completed.result.prepared._payload.get("surfacePreparationUsec",{})
	var prepared_masonry=completed.result.prepared._payload.get("preparedMasonry")
	metrics.preparedMasonryCount=prepared_masonry.count() if prepared_masonry!=null else 0
	check("actual_masonry_descriptors_prepared",metrics.preparedMasonryCount==1450)
	prepared_masonry=null
	check("actual_immutable_history_prepared",completed.result.prepared._payload.get("preparedHistory")!=null)
	var description = completed.result.prepared.describe(binding)
	check("actual_compiled_publication_groups",description != null and description.publication_groups.get("ready",false) and description.origin == profile.origin)
	description = null
	var begin: Dictionary = job.begin(completed.result.prepared,profile,binding,parent,main.make_tree_from_runtime_request)
	check("actual_begin_queued_without_nodes",begin.status=="pending_budget" and parent.get_child_count()==0)
	if begin.status != "pending_budget":
		metrics.rejectedBegin = begin
		# Rejected begin never takes ownership. Relinquish every caller alias
		# before polling the existing worker that disposes the prepared source.
		worker.request_shutdown()
		check("actual_rejected_begin_retirement_accepted",worker.retire_external_payload(completed))
		completed = {}; profile = {}
		deadline = Time.get_ticks_msec()+15000
		while not worker.poll().shutdownComplete and Time.get_ticks_msec()<deadline: await process_frame
		check("actual_rejected_begin_worker_shutdown",worker.poll().shutdownComplete)
		main.free()
		return
	completed = {}; profile = {}
	var status: Dictionary = job.status()
	var last_phase := ""
	var next_progress := 0
	deadline = Time.get_ticks_msec()+150000
	var scene_started := Time.get_ticks_usec()
	while not status.sceneReady and status.status not in ["failed","cancelled"] and Time.get_ticks_msec()<deadline:
		if status.phase!=last_phase or Time.get_ticks_msec()>next_progress:
			progress(status.phase,status.counts)
			last_phase = status.phase
			next_progress = Time.get_ticks_msec()+3000
		status = job.advance(2500)
		await process_frame
	metrics.sceneElapsedUsec = Time.get_ticks_usec()-scene_started
	metrics.publication = status
	metrics.publisherStages = job._building.publication_timing() if job._building!=null else {}
	check("actual_history_uses_identity_guards",metrics.publisherStages.get("prepared_history_identity_validation",{}).get("calls",0)>0 and metrics.publisherStages.get("paving_history_boundary_validation",{}).get("calls",0)==0)
	check("actual_advance_accounting",status.advanceCalls>0 and status.advanceCpuUsec>0 and status.betweenAdvanceUsec>=0)
	check("actual_no_main_masonry_descriptor",metrics.publisherStages.get("masonry_publish_geometry",{}).get("calls",0)==0 and job._building._masonry_preparation.metrics.maxDescriptorUsec==0)
	check("actual_prepared_masonry_consumed",metrics.publisherStages.get("prepared_masonry_lookup",{}).get("calls",0)==metrics.preparedMasonryCount)
	metrics.roofPublicationSource=measure_prepared_roof_publication(job)
	var roof_count: int=int(metrics.roofPublicationSource.roofCount)
	metrics.roofCount=roof_count
	check("actual_roofs_use_resumable_publication",roof_count>0 and metrics.roofPublicationSource.valid \
		and metrics.roofPublicationSource.preparedCount==roof_count and metrics.roofPublicationSource.maxSegmentsPerGroup>1 \
		and metrics.publisherStages.get("roof_publish_setup",{}).get("calls",0)==roof_count \
		and metrics.publisherStages.get("roof_publish_packet_collect",{}).get("calls",0)==metrics.roofPublicationSource.expectedCollectCalls \
		and metrics.roofPublicationSource.expectedCollectCalls>roof_count \
		and metrics.publisherStages.get("roof_publish_geometry",{}).get("calls",0)==0 \
		and metrics.publisherStages.get("roof_publish_collect",{}).get("calls",0)==0 \
		and metrics.publisherStages.get("roof_publish_compat_custom",{}).get("calls",0)==0)
	check("actual_roofs_complete_exactly_once",metrics.publisherStages.get("roof_publish_eave",{}).get("calls",0)==roof_count and metrics.publisherStages.get("roof_publish_ridge",{}).get("calls",0)==roof_count and metrics.publisherStages.get("roof_publish_finish",{}).get("calls",0)==roof_count)
	metrics.retainedMetadata=measure_retained_metadata(job._building)
	metrics.metadataCache=job._building._static_record_cache_stats.duplicate() if job._building!=null else {}
	metrics.metadataCache["currentRecords"]=job._building._static_record_cache.size() if job._building!=null else 0
	check("actual_metadata_prepared_without_main_copy",metrics.metadataCache.get("copies",-1)==0 and metrics.metadataCache.get("preparedHits",0)>3159 and metrics.metadataCache.currentRecords==3159)
	var unit_resource: WeakRef = weakref(job._building.unit_box) if job._building!=null else null
	var material_resource: WeakRef = weakref(job._building.material_cache.values()[0]) if job._building!=null and not job._building.material_cache.is_empty() else null
	check("actual_scene_ready",status.sceneReady)
	check("actual_not_gameplay_ready",not status.gameplayReady)
	if status.sceneReady:
		check("actual_building_count",status.counts.buildingParts==4703 and status.counts.buildingTotal==4703)
		check("actual_furniture_count",status.counts.furnitureParts==210 and status.counts.furnitureTotal==210)
		check("actual_trees_all_visuals",status.counts.treesRegistered>0 and status.counts.treeVisualsComplete==status.counts.treesTotal and status.counts.treesSkipped==0)
		check("actual_synthetic_door_owners_registered",synthetic_doors.registered>0 and synthetic_doors.registered==status.counts.doorsRegistered and synthetic_doors.claims.size()==synthetic_doors.registered)
		await physics_frame
		await process_frame
		await physics_frame
		await process_frame
		audit_scene(job)
	else:
		progress("publication_not_ready",status)
	progress("scene_cleanup")
	job.cancel()
	deadline = Time.get_ticks_msec()+30000
	while not job.status().retirementReady and Time.get_ticks_msec()<deadline:
		job.advance(2500)
		await process_frame
	check("actual_scene_cleanup",job.status().retirementReady and parent.get_child_count()==0)
	check("actual_synthetic_door_owners_retired_once",synthetic_doors.claims.is_empty() and synthetic_doors.retired==synthetic_doors.registered and synthetic_doors.retire_before_free)
	metrics.syntheticDoorLifecycle = {"registered":synthetic_doors.registered,"retired":synthetic_doors.retired,"claimsRemaining":synthetic_doors.claims.size(),"retireBeforeFree":synthetic_doors.retire_before_free}
	metrics.afterCleanup = job.status()
	var payload: Dictionary = job.take_retirement_payload()
	check("actual_cpu_retirement_payload",not payload.is_empty())
	check("actual_retirement_one_shot",job.take_retirement_payload().is_empty())
	worker.request_shutdown()
	check("actual_worker_accepts_retirement",worker.retire_external_payload(payload))
	payload = {}
	deadline = Time.get_ticks_msec()+15000
	while not worker.poll().shutdownComplete and Time.get_ticks_msec()<deadline: await process_frame
	check("actual_worker_shutdown",worker.poll().shutdownComplete)
	check("actual_unique_mesh_released",unit_resource!=null and unit_resource.get_ref()==null)
	check("actual_unique_material_released",material_resource!=null and material_resource.get_ref()==null)
	if main.tree_publication_queue != null:
		deadline = Time.get_ticks_msec()+15000
		while Time.get_ticks_msec()<deadline:
			var queue: Dictionary = main.tree_publication_queue.metrics()
			if queue.pending==0 and queue.activeWorkers==0 and queue.completed==0: break
			await process_frame
		metrics.treeQueue = main.tree_publication_queue.metrics()
		check("actual_tree_queue_drained",metrics.treeQueue.pending==0 and metrics.treeQueue.activeWorkers==0 and metrics.treeQueue.completed==0)
	main.free()
	await process_frame

func measure_prepared_roof_publication(job) -> Dictionary:
	# Keep borrowed prepared Objects/Arrays inside this synchronous observation
	# frame. Only scalars survive into metrics and later retirement awaits.
	var result: Dictionary={"valid":false,"reason":"missing_roof_artifact","partId":"", \
		"roofCount":0,"preparedCount":0,"expectedCollectCalls":0,"maxSegmentsPerGroup":0,"instanceCount":0}
	# Count the whole source even if a later prepared-record guard rejects.
	for part in job._blueprint.parts:
		if part!=null and String(part.kind)=="roof" and bool(part.recipe.get("visual",true)): result.roofCount+=1
	if job._building==null: return result
	var publisher: Variant=job._building
	var artifact: Variant=publisher._prepared_surfaces.get("roof")
	if not artifact is Preparation.PreparedGeometry: return result
	if artifact.family!="roof" or not artifact.matches_history(publisher._prepared_history,publisher.surface_history,publisher.source_blueprint_id): return result
	for part in job._blueprint.parts:
		if part==null or String(part.kind)!="roof" or not bool(part.recipe.get("visual",true)): continue
		result.partId=String(part.id)
		result.reason="roof_source_binding"
		if not artifact.has_part(part) or not artifact.validate_part(part): return result
		var geometry: Dictionary=artifact.geometry_for(part)
		var packet: Variant=artifact.packet_for(part)
		result.reason="roof_packet_binding"
		if geometry.is_empty() or not packet is Dictionary: return result
		if not packet.is_read_only() or packet.get("family")!="roof" \
			or packet.get("frame")!=Transform3D(Basis.from_euler(part.rotation),part.position) \
			or not packet.get("groups") is Dictionary or not packet.groups.is_read_only(): return result
		for family: String in ["regular","weathered"]:
			result.reason="roof_packet_group:"+family
			var transforms: Variant=geometry.get(family+"Transforms")
			var group: Variant=packet.groups.get(family)
			if not transforms is Array or not group is Dictionary or not group.is_read_only(): return result
			if not group.get("segments") is Array: return result
			var segments: Array=group.segments
			if not segments.is_read_only() or segments.is_empty()!=transforms.is_empty(): return result
			var group_instances: int=0
			for segment: Variant in segments:
				result.reason="roof_packet_segment:"+family
				if not segment is Dictionary or not segment.is_read_only(): return result
				var instance_count: Variant=segment.get("instanceCount")
				if not instance_count is int or instance_count<1 or instance_count>256: return result
				for field: String in ["transforms","customData","buffer"]:
					if not segment.get(field) is Array or not segment[field].is_read_only(): return result
				if segment.transforms.size()!=instance_count or segment.customData.size()!=instance_count \
					or segment.buffer.size()!=instance_count*16: return result
				group_instances+=int(instance_count)
			result.reason="roof_packet_instance_count:"+family
			if group_instances!=transforms.size(): return result
			result.instanceCount+=group_instances
			result.maxSegmentsPerGroup=maxi(int(result.maxSegmentsPerGroup),segments.size())
			# Each nonempty packet group is consumed one segment per unit, then
			# one terminal cursor unit. Empty groups never enter packet_collect.
			if not segments.is_empty(): result.expectedCollectCalls+=segments.size()+1
		result.preparedCount+=1
	result.valid=true
	result.reason=""
	result.partId=""
	return result

func measure_retained_metadata(publisher) -> Dictionary:
	# Keep observation aliases in a separate call frame: a for-loop iterator can
	# retain the entire retirement array across later awaits in the caller.
	# These are encoded bytes, not allocator/driver resident-memory measurements.
	var prefixes:=0
	var records:=0
	var bytes:=0
	if publisher!=null:
		for value in publisher._publication_retirement:
			if value is Dictionary and not value.is_empty():
				var first: Variant = value.values()[0]
				if first is Dictionary and first.has("recipe") and first.has("id"):
					prefixes+=1; records+=value.size(); bytes+=var_to_bytes(value).size()
	return {"prefixes":prefixes,"records":records,"encodedBytes":bytes,"notHeapMemory":true}

func audit_scene(job) -> void:
	# Exhaustive test-only scene inspection is outside job slice measurements.
	var site: Node3D = job.own_node_root()
	var expected_origin: Vector3 = job._cpu.profile.origin
	check("actual_world_origin_once",site.global_position.is_equal_approx(expected_origin) and site.global_basis.is_equal_approx(Basis.IDENTITY))
	var expected := {}
	for part in job._blueprint.parts:
		if part.collision_enabled: expected[part.id] = part
	var stack: Array[Node] = [site]
	var collision_seen := {}
	var furniture_seen := {}
	var door_seen := {}
	var shapes_exact := true
	var transforms_exact := true
	var ids_unique := true
	var sample_shape: CollisionShape3D
	var render_facts: Array[String] = []
	var resources := {}
	var mesh_facts := {}
	var metadata_facts: Array[String] = []
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child: Node in node.get_children(): stack.append(child)
		if node is GeometryInstance3D:
			var row: Array = [node.global_transform,node.visible,node.layers,node.cast_shadow,
				resource_fact(node.material_override,resources),resource_fact(node.material_overlay,resources)]
			var mesh: Mesh
			if node is MultiMeshInstance3D:
				mesh = node.multimesh.mesh
				row.append_array(["multi",node.multimesh.buffer,node.multimesh.instance_count,node.multimesh.visible_instance_count])
			elif node is MeshInstance3D:
				mesh = node.mesh
				row.append("mesh")
				for surface in range(mesh.get_surface_count()): row.append(resource_fact(node.get_surface_override_material(surface),resources))
			if mesh!=null:
				if not mesh_facts.has(mesh.get_instance_id()):
					var arrays: Array = []
					for surface in range(mesh.get_surface_count()):
						# Only ArrayMesh exposes surface_get_primitive_type to scripts.
						# PrimitiveMesh's native geometry is triangle-only.
						if mesh is ArrayMesh:
							arrays.append([mesh.surface_get_primitive_type(surface),mesh.surface_get_arrays(surface),resource_fact(mesh.surface_get_material(surface),resources)])
						elif mesh is PrimitiveMesh:
							arrays.append([Mesh.PRIMITIVE_TRIANGLES,mesh.get_mesh_arrays(),resource_fact(mesh.surface_get_material(surface),resources)])
						else:
							check("actual_supported_mesh_type",false)
							return
					mesh_facts[mesh.get_instance_id()] = digest(arrays)
				row.append(mesh_facts[mesh.get_instance_id()])
			render_facts.append(digest(row))
		for key: StringName in [&"building_part_records",&"building_part_record",&"furnishing_part_record"]:
			if node.has_meta(key): metadata_facts.append(digest([key,node.get_meta(key)]))
		if node is CollisionShape3D and node.get_meta("building_collision_role","")=="blocking_part":
			var id := String(node.get_meta("building_part_id"))
			ids_unique = ids_unique and not collision_seen.has(id)
			collision_seen[id] = true
			if not expected.has(id): shapes_exact=false; continue
			var part = expected[id]
			shapes_exact = shapes_exact and node.shape is BoxShape3D and node.shape.size==part.size and not node.disabled
			var transform := Transform3D(Basis.IDENTITY,expected_origin)*Transform3D(Basis.from_euler(part.rotation),part.position)
			transforms_exact = transforms_exact and node.global_transform.is_equal_approx(transform)
			if sample_shape==null: sample_shape=node
		if node.has_meta("furnishing_part_id"):
			furniture_seen[String(node.get_meta("furnishing_part_id"))] = true
		if node.has_meta("door_portal_id") and node is StaticBody3D:
			var id := String(node.get_meta("building_part_id"))
			door_seen[id] = node.get_meta("door_portal_id")=="building:%s:%s"%[job._binding.siteId,id]
	check("actual_exact_collision_shapes",shapes_exact and collision_seen.size()==expected.size() and ids_unique)
	check("actual_exact_collision_world_transforms",transforms_exact)
	check("actual_all_furniture_bodies",furniture_seen.size()==210)
	check("actual_site_specific_doors",not door_seen.is_empty() and not door_seen.values().has(false))
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.005
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY,sample_shape.global_position)
	var hits := site.get_world_3d().direct_space_state.intersect_shape(query,32)
	var matched := false
	for hit: Dictionary in hits:
		if hit.collider==sample_shape.get_parent(): matched=true
	check("actual_collision_registered_after_physics",matched)
	metrics.sceneAudit = {"collisionParts":collision_seen.size(),"furnishingBodies":furniture_seen.size(),"doors":door_seen.size(),"physicsProbeHits":hits.size()}
	render_facts.sort(); metadata_facts.sort()
	metrics.renderBaseline = {"renderNodes":render_facts.size(),"uniqueMeshes":mesh_facts.size(),"visualDigest":digest(render_facts),"metadataDigest":digest(metadata_facts)}
	var baseline := FileAccess.open(output+"/render-baseline.json",FileAccess.WRITE)
	if baseline==null: return
	baseline.store_string(JSON.stringify({"summary":metrics.renderBaseline,"renderFacts":render_facts,"metadataFacts":metadata_facts},"\t")); baseline.close()
	check("actual_scene_audit_completed",not render_facts.is_empty() and not metadata_facts.is_empty())

static func digest(value: Variant) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(value))
	return hash.finish().hex_encode()

func resource_fact(resource: Resource, cache: Dictionary) -> Variant:
	if resource==null: return null
	var key := resource.get_instance_id()
	if cache.has(key): return cache[key]
	cache[key] = "resource_cycle:"+resource.get_class()
	var result := {"class":resource.get_class(),"properties":{}}
	for property: Dictionary in resource.get_property_list():
		if int(property.usage)&PROPERTY_USAGE_STORAGE==0 and not String(property.name).begins_with("shader_parameter/"): continue
		var value: Variant = resource.get(property.name)
		if value is Resource: value=resource_fact(value,cache)
		result.properties[property.name]=value
	cache[key] = digest(result)
	return cache[key]

func _run() -> void:
	output = OS.get_environment("BUILDING_SCENE_OUTPUT")
	await publisher_facade()
	if OS.get_environment("BUILDING_SCENE_PHASE")=="actual": await actual_publication()
	_finish()

func _finish() -> void:
	var report := {"schema":"building-scene-publication/v1","complete":true,"passed":not checks.values().has(false),
		"evidenceLevel":"historical_source_actual_publishers_and_shared_tree_queue" if actual_requested else "synthetic_publisher_facade","checks":checks,"metrics":metrics,
		"measuredBudgetsMet":checks.get("actual_scene_ready",false) and metrics.get("afterCleanup",{}).get("maxAtomicUsec",999999)<=8000 and metrics.get("afterCleanup",{}).get("maxSliceUsec",999999)<=4000,
		"doesNotProve":"Door registration is an explicitly synthetic balanced callback adapter. No ordinary-world city spawning, visual acceptance, gameplay doors, NPC behavior, terrain, saves or runtime performance acceptance."}
	var file := FileAccess.open(output+"/report.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("SCENE PUBLICATION COMPLETE ",JSON.stringify({"checks":checks.size(),"passed":report.passed}))
	quit(0 if report.passed else 1)
