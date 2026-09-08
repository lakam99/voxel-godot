extends RefCounted
class_name BuildingPartPublisher

## Scene publication for material-aware construction parts. It intentionally
## consumes only BuildingPart data: the visual recipe and collision shape share
## one record, and board/brick detail is instanced per parent part.

const ConstructionMaterialCatalogScript := preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const SurfaceHistoryFieldScript := preload("res://scripts/buildings/SurfaceHistoryField.gd")
# Existing review consumers access this public constant directly.
const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const PublicationPreparation := preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const StaticBatchFlush := preload("res://scripts/buildings/BuildingStaticBatchFlush.gd")
const MeshBatchUpload := preload("res://scripts/buildings/BuildingMeshBatchUpload.gd")
const PavingPublication := preload("res://scripts/buildings/BuildingPavingPublication.gd")
const MasonryPublication := preload("res://scripts/buildings/BuildingMasonryPublication.gd")
const RoofPublication := preload("res://scripts/buildings/BuildingRoofPublication.gd")
const MasonryDescriptor := preload("res://scripts/buildings/MasonryDescriptorGeometry.gd")
const BuildingGoodsGeometryScript := preload("res://scripts/buildings/BuildingGoodsGeometry.gd")
const BuildingDoorGeometryScript := preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const SettledCobbleGeometryScript := preload("res://scripts/buildings/SettledCobbleGeometry.gd")
const PavingFootingAssemblyScript := preload("res://scripts/buildings/PavingFootingAssemblyRecipe.gd")
const MasonryWallGeometryScript := preload("res://scripts/buildings/MasonryWallGeometry.gd")
const MasonryAperturePublicationScript := preload("res://scripts/buildings/MasonryAperturePublication.gd")
const MAX_JOINTED_FINISHES := 4
const MAX_JOINTED_FEET := 16
const INCREMENTAL_STATIC_BATCH_INSTANCE_LIMIT := 12000
const MONUMENTAL_MASONRY_INSTANCE_BUDGET := MasonryDescriptor.MONUMENTAL_MASONRY_INSTANCE_BUDGET
# Temporary user-authorized bypass on the visuals branch (2026-08-30).
# Keep actual failures in reports; rendering does not certify structural safety.
const PHYSICAL_INTEGRITY_REQUIRED_FOR_PUBLICATION := false

var unit_box: BoxMesh
var material_cache: Dictionary = {}
var published_nodes: Array = []
var published_part_count := 0
var collision_count := 0
var visual_batch_count := 0
var recipe_build_usec := 0
var publication_usec := 0
var diagnostic_preparation_usec := 0
var scene_preparation_usec := 0
var source_blueprint_id := ""
var publication_site_id := ""
var batch_static_parts := false
var static_collision_body: StaticBody3D
var static_part_records: Dictionary = {}
var static_visual_batches: Dictionary = {}
var static_visual_collecting := false
var static_visual_part_transform := Transform3D.IDENTITY
var static_visual_transform_count := 0
var incremental_progress_callback: Callable
var incremental_total_parts := 0
var incremental_published_parts := 0
var incremental_static_flush_count := 0
var paving_treatments: Array = []
var surface_history := SurfaceHistoryFieldScript.new()
var masonry_repair_clusters: Array[Dictionary] = []
var physical_integrity: Dictionary = {}
var raised_route_coverage: Dictionary = {}
var active_publication_started_usec := 0
var _paving_artifacts: Dictionary = {}
var _paving_source_parts: Dictionary = {}
var _paving_blueprint = null
var _paving_binding := PackedByteArray()
var _paving_history_binding := PackedByteArray()
var _paving_failure := ""
var _paving_prepared := false
var _paving_complete := false
var _masonry_preparation
var _scene_finalized := false
var _publication_stage_metrics: Dictionary = {}
var _static_flush
var _static_flush_notify := false
var _publication_retirement: Array = []
var _static_record_cache: Dictionary = {}
var _static_record_cache_stats: Dictionary = {"copies":0,"hits":0,"preparedHits":0,"copiedEncodedBytes":0,"unsupportedCopies":0}
var _prepared_static_records: Dictionary = {}
var _prepared_static_bindings: Dictionary = {}
var resumable_scene_publication := false
var _finish_validated := false
var _pending_paving
var _pending_masonry
var _pending_roof
var _pending_part_index := -1
var _scene_blueprint
var _scene_parent: WeakRef
var _paving_history_snapshot
var _paving_history_source
var _paving_history_source_bytes := PackedByteArray()
var _completed_paving: Array = []
var _prepared_history
var _prepared_masonry
var _prepared_masonry_identity


func _init() -> void:
	unit_box = BoxMesh.new()
	unit_box.size = Vector3.ONE


func publish(blueprint, parent: Node3D, options: Dictionary = {}) -> Dictionary:
	if not begin_publication(blueprint, parent, options):
		return summary()
	while _masonry_preparation.state == "pending_budget":
		_masonry_preparation.advance(self)
	if _masonry_preparation.state != "ready": return summary()
	var cursor := 0
	while cursor < blueprint.parts.size():
		cursor=publish_part_batch(blueprint,parent,cursor,blueprint.parts.size())
		if _publication_failed(): return summary()
	return finish_publication(blueprint, parent)


func publish_incremental(blueprint, parent: Node3D, parts_per_frame := 6, options: Dictionary = {}) -> Dictionary:
	# Uses the same part records and publish_part path as synchronous publication.
	# Consumers with an on-screen loading state can spread a larger blueprint over
	# frames without inventing a second visual/collision publication authority.
	if not begin_publication(blueprint, parent, options):
		return summary()
	while _masonry_preparation.state == "pending_budget":
		_masonry_preparation.advance(self)
		report_incremental_progress("masonry_preparation")
		if _masonry_preparation.state == "pending_budget": await parent.get_tree().process_frame
	if _masonry_preparation.state != "ready": return summary()
	var frame_budget := maxi(1, parts_per_frame)
	var part_index := 0
	while part_index < blueprint.parts.size():
		part_index = publish_part_batch(blueprint, parent, part_index, frame_budget)
		if _publication_failed(): return summary()
		if part_index < blueprint.parts.size():
			report_incremental_progress("frame_budget")
			await parent.get_tree().process_frame
	return finish_publication(blueprint, parent)


func begin_publication(blueprint, parent: Node3D, options: Dictionary = {}) -> bool:
	clear_published()
	if blueprint == null or parent == null:
		return false
	var prepared := PublicationPreparation.evaluate(blueprint, options)
	if not prepared.ready: return false
	raised_route_coverage = prepared.raisedRouteCoverage
	physical_integrity = prepared.physicalIntegrity
	diagnostic_preparation_usec = prepared.preparationUsec
	var started := Time.get_ticks_usec()
	var ready := _begin_scene_publication(blueprint, options, parent)
	scene_preparation_usec = Time.get_ticks_usec() - started
	return ready


## Consumes an exclusively owned, one-shot worker result. No proof replay or
## whole-source hashing on the main thread. The owner supplies its current
## site/source/generation binding; stale and already-consumed holders reject.
## Scene preparation remains measured separately and is not yet frame-bounded.
func begin_prepared_publication(prepared: PublicationPreparation.PreparedSource, parent: Node3D, expected_binding: Dictionary, options: Dictionary = {}) -> Dictionary:
	if prepared == null or parent == null or not PublicationPreparation.valid_binding(expected_binding) \
			or options.has("structuralAuthorityBlueprint"):
		return {"ready":false, "reason":"invalid_prepared_publication_request"}
	var source := prepared.take(expected_binding)
	if source.is_empty(): return {"ready":false, "reason":"stale_or_consumed_publication"}
	clear_published()
	raised_route_coverage = source.raisedRouteCoverage
	physical_integrity = source.physicalIntegrity
	diagnostic_preparation_usec = source.preparationUsec
	_prepared_static_records=source.get("staticRecords",{})
	_prepared_static_bindings=source.get("staticRecordBindings",{})
	_prepared_history=source.get("preparedHistory")
	_prepared_masonry=source.get("preparedMasonry")
	_prepared_masonry_identity=_prepared_masonry
	var started := Time.get_ticks_usec()
	var ready := _begin_scene_publication(source.blueprint, options, parent)
	scene_preparation_usec = Time.get_ticks_usec() - started
	if not ready:
		# Return ownership for retirement/retry; do not destroy the large source
		# here or expose it as a successful/partially usable publication.
		source["scenePreparation"] = _detach_preparation_for_retirement()
		return {"ready":false, "reason":"scene_preparation_failed", "retirementPayload":source}
	return {"ready":true, "reason":"", "blueprint":source.blueprint, "furnishingPlan":source.furnishingPlan,
		"preparationUsec":source.preparationUsec, "routeUsec":source.routeUsec, "physicalUsec":source.physicalUsec,
		"metadataPreparationUsec":source.get("metadataPreparationUsec",0)}


func _detach_preparation_for_retirement() -> Dictionary:
	# begin creates no scene nodes. Transfer its CPU/resource state without
	# clearing aliased containers or retaining the failed blueprint in publisher.
	var state := {"physicalIntegrity":physical_integrity, "raisedRouteCoverage":raised_route_coverage,
		"sceneBlueprint":_scene_blueprint,
		"staticRecords":_prepared_static_records,"staticRecordBindings":_prepared_static_bindings,
		"pavingBlueprint":_paving_blueprint, "pavingParts":_paving_source_parts,
		"pavingArtifacts":_paving_artifacts, "pavingBinding":_paving_binding,
		"pavingHistoryBinding":_paving_history_binding, "pavingTreatments":paving_treatments,
		"masonry":_masonry_preparation, "surfaceHistory":surface_history,"preparedHistory":_prepared_history,"preparedMasonry":_prepared_masonry,"preparedMasonryIdentity":_prepared_masonry_identity,
		"progressCallback":incremental_progress_callback}
	physical_integrity = {}
	raised_route_coverage = {}
	_scene_blueprint=null
	_scene_parent=null
	_prepared_static_records={}
	_prepared_static_bindings={}
	_paving_blueprint = null
	_paving_source_parts = {}
	_paving_artifacts = {}
	_paving_binding = PackedByteArray()
	_paving_history_binding = PackedByteArray()
	paving_treatments = []
	_masonry_preparation = null
	_prepared_history=null
	_prepared_masonry=null
	_prepared_masonry_identity=null
	surface_history = SurfaceHistoryFieldScript.new()
	incremental_progress_callback = Callable()
	_paving_prepared = false
	return state


func _begin_scene_publication(blueprint, options: Dictionary, parent: Node3D) -> bool:
	# Citadel route-publication requirements are retired on this visuals branch.
	# Keep the real diagnostic (including failures) without making it a renderer
	# prerequisite. Physical integrity is temporarily diagnostic-only by request.
	if PHYSICAL_INTEGRITY_REQUIRED_FOR_PUBLICATION and not bool(physical_integrity.get("passed", false)):
		push_error("Building publication blocked by invalid physical recipe: %s" % JSON.stringify(physical_integrity.get("violations", [])))
		return false
	configure_publication_options(options)
	_scene_blueprint=blueprint
	_scene_parent=weakref(parent)
	incremental_total_parts = blueprint.parts.size()
	incremental_published_parts = 0
	incremental_static_flush_count = 0
	source_blueprint_id = canonical_source_blueprint_id(blueprint)
	paving_treatments = blueprint.recipe.get("pavingTreatments", []) as Array
	var stage_started := Time.get_ticks_usec()
	if _prepared_history!=null:
		if not _prepared_history is PublicationPreparation.PreparedHistory or not _prepared_history.matches(_prepared_history.history,source_blueprint_id):
			return _paving_reject("invalid_prepared_history")
		surface_history=_prepared_history.history
	else:
		surface_history.configure(blueprint.recipe, blueprint.parts)
	if _prepared_masonry!=null:
		if not _prepared_masonry is PublicationPreparation.PreparedMasonry or not _prepared_masonry.matches_history(_prepared_history,surface_history,source_blueprint_id):
			return _paving_reject("invalid_prepared_masonry")
	_record_publication_stage("history",Time.get_ticks_usec()-stage_started)
	stage_started = Time.get_ticks_usec()
	var paving_ready := _prepare_paving_publication(blueprint)
	_record_publication_stage("paving_begin",Time.get_ticks_usec()-stage_started)
	if not paving_ready: return false
	stage_started = Time.get_ticks_usec()
	var masonry_ready := prepare_masonry_apertures(blueprint)
	_record_publication_stage("masonry_begin",Time.get_ticks_usec()-stage_started)
	if not masonry_ready: return false
	active_publication_started_usec = Time.get_ticks_usec()
	return true


func publish_part_batch(blueprint, parent: Node3D, start_index: int, max_parts: int, budget_usec := 2500) -> int:
	if blueprint == null or parent == null:
		return start_index
	if not _scene_owner_matches(blueprint,parent):
		_paving_reject("scene_publication_owner_mismatch")
		return start_index
	var pending_job = _pending_paving if _pending_paving!=null else (_pending_masonry if _pending_masonry!=null else _pending_roof)
	if pending_job!=null:
		if start_index!=_pending_part_index or start_index>=blueprint.parts.size() or blueprint.parts[start_index]!=pending_job.source_part():
			_paving_reject("pending_part_cursor_mismatch")
			return start_index
		var pending: Dictionary = pending_job.advance(self,budget_usec)
		if pending.status=="failed":
			_paving_reject(String(pending.reason))
			return start_index
		if pending.status!="ready": return start_index
		_publication_retirement.append(pending_job)
		if _pending_paving!=null: _completed_paving.append({"job":_pending_paving,"index":start_index})
		_pending_paving=null
		_pending_masonry=null
		_pending_roof=null
		_pending_part_index=-1
		incremental_published_parts+=1
		if batch_static_parts and static_visual_transform_count >= INCREMENTAL_STATIC_BATCH_INSTANCE_LIMIT: _begin_static_flush(parent,true)
		return start_index+1
	if has_pending_static_flush():
		advance_static_flush(parent)
		if has_pending_static_flush() or _publication_failed(): return start_index
	_finish_validated = false
	var validation_started := Time.get_ticks_usec()
	var paving_valid := _paving_session_valid(blueprint)
	_record_publication_stage("paving_revalidation",Time.get_ticks_usec()-validation_started)
	if not paving_valid: return start_index
	if _masonry_preparation != null and _masonry_preparation.state == "pending_budget":
		_masonry_preparation.advance(self)
		if _masonry_preparation.state != "ready": return start_index
	if _publication_failed(): return start_index
	var part_index := clampi(start_index, 0, blueprint.parts.size())
	var processed := 0
	while part_index < blueprint.parts.size() and processed < maxi(1, max_parts):
		var part = blueprint.parts[part_index]
		part_index += 1
		processed += 1
		if part == null:
			continue
		publish_part(part, parent)
		if _publication_failed(): return part_index - 1
		if _pending_paving!=null or _pending_masonry!=null or _pending_roof!=null:
			_pending_part_index=part_index-1
			return _pending_part_index
		incremental_published_parts += 1
		if batch_static_parts and static_visual_transform_count >= INCREMENTAL_STATIC_BATCH_INSTANCE_LIMIT:
			if resumable_scene_publication:
				_begin_static_flush(parent,true)
				break
			else:
				flush_static_batches(parent)
				report_incremental_progress("static_batch_flush")
	return part_index


func finish_publication(blueprint, parent: Node3D) -> Dictionary:
	var result := finish_scene_publication(blueprint,parent)
	# Only drain an actual in-flight flush here. Pending masonry/parts require
	# their own advance calls; repeatedly asking finish cannot make them progress.
	while result.get("status")=="pending_budget" and has_pending_static_flush(): result=finish_scene_publication(blueprint,parent)
	return summary()


## Runtime orchestration uses bounded status, not summary()'s full copied proof
## reports. Compatibility callers still receive that historical full summary.
func finish_scene_publication(blueprint, parent: Node3D, budget_usec := 2500) -> Dictionary:
	if blueprint == null or parent == null:
		return {"status":"failed","reason":"invalid_scene_publication_request","complete":false}
	if not _scene_owner_matches(blueprint,parent):
		_paving_reject("scene_publication_owner_mismatch")
		return publication_status()
	if _pending_paving!=null or _pending_masonry!=null or _pending_roof!=null: return {"status":"pending_budget","reason":"part_publication_pending","complete":false}
	if not _finish_validated:
		if not _paving_session_valid(blueprint): return publication_status()
		if _masonry_preparation != null and (_masonry_preparation.state != "ready" or not _masonry_preparation._validate_all(self)): return publication_status()
		_finish_validated = true
	if resumable_scene_publication:
		if _static_flush==null and not static_visual_batches.is_empty(): _begin_static_flush(parent,false)
		var result := advance_static_flush(parent,budget_usec)
		if result.status!="ready": return {"status":result.status,"reason":result.get("reason",""),"complete":false}
	else:
		flush_static_batches(parent)
	# Mutable legacy callers can change a source while finalization yields.
	# Recheck at the commit boundary, not once per metadata-copy slice.
	if not validate_static_flush_source(): return publication_status()
	report_incremental_progress("complete")
	publication_usec = Time.get_ticks_usec() - active_publication_started_usec if active_publication_started_usec > 0 else 0
	active_publication_started_usec = 0
	_paving_complete = incremental_published_parts == incremental_total_parts
	_scene_finalized = _paving_complete
	_finish_validated = false
	return publication_status()


func advance_scene_preparation(budget_usec := 2500) -> Dictionary:
	if budget_usec < 1 or budget_usec > 4000:
		return {"status":"failed","reason":"invalid_slice_budget","complete":false}
	if _masonry_preparation != null and not _publication_failed() and _masonry_preparation.state == "pending_budget":
		_masonry_preparation.advance(self,budget_usec)
	return publication_status()


func publication_status() -> Dictionary:
	var reason := _paving_failure
	if reason.is_empty() and _masonry_preparation != null: reason = _masonry_preparation.reason
	if reason.is_empty() and _masonry_preparation == null: reason = "scene_publication_not_started"
	var state := "failed" if not reason.is_empty() else ("pending_budget" if _masonry_preparation.state == "pending_budget" else "ready")
	if state=="ready" and (_pending_paving!=null or _pending_masonry!=null or _pending_roof!=null or _static_flush!=null): state="pending_budget"
	return {"status":state,"reason":reason,"complete":_scene_finalized and state=="ready",
		"publishedPartCount":incremental_published_parts,"totalParts":incremental_total_parts,
		"collisionPartCount":collision_count,"visualBatchCount":visual_batch_count}


func clear_published() -> void:
	if _pending_roof!=null: _pending_roof.cancel()
	_prepared_history=null
	_prepared_masonry=null
	_prepared_masonry_identity=null
	_paving_history_snapshot=null
	_paving_history_source=null
	_paving_history_source_bytes=PackedByteArray()
	_completed_paving=[]
	_scene_blueprint=null
	_scene_parent=null
	_pending_paving=null
	_pending_masonry=null
	_pending_roof=null
	_pending_part_index=-1
	_static_flush = null
	_publication_retirement = []
	_static_record_cache={}
	_static_record_cache_stats={"copies":0,"hits":0,"preparedHits":0,"copiedEncodedBytes":0,"unsupportedCopies":0}
	_prepared_static_records={}
	_prepared_static_bindings={}
	_finish_validated = false
	_scene_finalized = false
	_publication_stage_metrics = {}
	for node in published_nodes:
		if node != null and is_instance_valid(node):
			node.queue_free()
	published_nodes.clear()
	published_part_count = 0
	collision_count = 0
	visual_batch_count = 0
	recipe_build_usec = 0
	publication_usec = 0
	diagnostic_preparation_usec = 0
	scene_preparation_usec = 0
	source_blueprint_id = ""
	publication_site_id = ""
	batch_static_parts = false
	static_collision_body = null
	static_part_records.clear()
	static_visual_batches.clear()
	static_visual_collecting = false
	static_visual_part_transform = Transform3D.IDENTITY
	static_visual_transform_count = 0
	incremental_total_parts = 0
	incremental_published_parts = 0
	incremental_static_flush_count = 0
	# This array comes from the accepted blueprint recipe. Relinquish the
	# publisher's alias; never erase retained source treatment declarations.
	paving_treatments = []
	incremental_progress_callback = Callable()
	# Prepared history containers are immutable. Detach, never clear aliases.
	surface_history=SurfaceHistoryFieldScript.new()
	masonry_repair_clusters.clear()
	physical_integrity.clear()
	raised_route_coverage.clear()
	active_publication_started_usec = 0
	_paving_artifacts.clear()
	_paving_source_parts.clear()
	_paving_blueprint = null
	_paving_binding.clear()
	_paving_history_binding.clear()
	_paving_failure = ""
	_paving_prepared = false
	_paving_complete = false
	_masonry_preparation = null


func configure_publication_options(options: Dictionary) -> void:
	batch_static_parts = bool(options.get("batchStaticParts", false))
	resumable_scene_publication = bool(options.get("resumableScenePublication",false))
	publication_site_id = String(options.get("publicationSiteId", ""))
	var callback_value = options.get("progressCallback")
	incremental_progress_callback = callback_value as Callable if callback_value is Callable else Callable()


func canonical_source_blueprint_id(blueprint) -> String:
	var result := String(blueprint.id) if blueprint != null else ""
	if blueprint != null and blueprint.recipe is Dictionary:
		result = String((blueprint.recipe as Dictionary).get("sourceBlueprintId", result))
	return result




func publish_part(part, parent: Node3D) -> StaticBody3D:
	if not _paving_part_valid(part): return null
	if not _masonry_part_valid(part): return null
	var started := Time.get_ticks_usec()
	published_part_count += 1
	if batch_static_parts and String(part.kind) != "door":
		publish_static_part(part, parent)
		var elapsed := Time.get_ticks_usec() - started
		recipe_build_usec += elapsed
		_record_publication_stage("part",elapsed,String(part.id))
		return null
	var body := StaticBody3D.new()
	body.name = "ConstructionPart_%s" % String(part.id)
	body.position = part.position
	body.rotation = part.rotation
	body.set_meta("building_part_id", part.id)
	body.set_meta("building_part_kind", part.kind)
	body.set_meta("building_material", part.material_id)
	body.set_meta("building_semantic", part.semantic)
	body.set_meta("building_part_record", part.snapshot())
	parent.add_child(body)
	if String(part.kind) == "door":
		configure_door_leaf(body, part)
	published_nodes.append(body)
	if part.collision_enabled:
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = part.size
		collision.shape = shape
		collision.set_meta("building_part_id", part.id)
		collision.set_meta("building_part_kind", part.kind)
		collision.set_meta("building_semantic", part.semantic)
		collision.set_meta("building_collision_role", "blocking_part")
		body.add_child(collision)
		collision_count += 1
	# Some construction records are collision stringers beneath richer generated
	# geometry (for example a stair flight's visible treads).  They remain normal
	# source parts with real collision, but do not duplicate the finished visual.
	if bool(part.recipe.get("visual", true)):
		publish_visual(part, body)
	if bool(part.recipe.get("practicalLight", false)):
		if _pending_masonry!=null: _pending_masonry.defer_practical_light=true
		elif _pending_roof!=null: _pending_roof.defer_practical_light=true
		else: publish_practical_light(part, body)
	if String(part.kind) == "door":
		add_door_interaction_proxy(body, part)
	var elapsed := Time.get_ticks_usec() - started
	recipe_build_usec += elapsed
	_record_publication_stage("part",elapsed,String(part.id))
	return body


func publish_static_part(part, parent: Node3D) -> void:
	if not _paving_part_valid(part): return
	if not _masonry_part_valid(part): return
	# Static construction records remain the source of visual and collision facts;
	# this only composes their publication under shared scene nodes. Doors keep
	# their individual bodies because DoorPortalService owns their interaction and
	# collision state.
	if part.collision_enabled:
		var record: Dictionary = part.snapshot()
		if _prepared_static_records.has(String(part.id)):
			if not _prepared_static_bindings.has(String(part.id)) or PublicationPreparation.static_record_binding(record)!=_prepared_static_bindings[String(part.id)]:
				_paving_reject("stale_prepared_metadata_source")
				return
			record=_prepared_static_records[String(part.id)]
		var collision_body := static_collision_batch(parent)
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = part.size
		collision.shape = shape
		collision.set_meta("building_part_id", part.id)
		collision.set_meta("building_part_kind", part.kind)
		collision.set_meta("building_semantic", part.semantic)
		collision.set_meta("building_collision_role", "blocking_part")
		collision.position = part.position
		collision.rotation = part.rotation
		collision_body.add_child(collision)
		static_part_records[String(part.id)] = record
		collision_count += 1
	if bool(part.recipe.get("visual", true)):
		static_visual_collecting = true
		static_visual_part_transform = Transform3D(Basis.from_euler(part.rotation), part.position)
		publish_visual(part, parent)
		if bool(part.recipe.get("practicalLight", false)):
			if _pending_masonry!=null: _pending_masonry.defer_practical_light=true
			elif _pending_roof!=null: _pending_roof.defer_practical_light=true
			else: publish_practical_light(part, parent)
		static_visual_collecting = false
		static_visual_part_transform = Transform3D.IDENTITY
	elif bool(part.recipe.get("practicalLight", false)):
		static_visual_collecting = true
		static_visual_part_transform = Transform3D(Basis.from_euler(part.rotation), part.position)
		publish_practical_light(part, parent)
		static_visual_collecting = false
		static_visual_part_transform = Transform3D.IDENTITY


func static_collision_batch(parent: Node3D) -> StaticBody3D:
	if static_collision_body != null and is_instance_valid(static_collision_body):
		return static_collision_body
	static_collision_body = StaticBody3D.new()
	static_collision_body.name = "ConstructionStaticCollisionBatch"
	static_collision_body.set_meta("building_part_kind", "batched_static")
	static_collision_body.set_meta("building_source_blueprint", source_blueprint_id)
	parent.add_child(static_collision_body)
	published_nodes.append(static_collision_body)
	return static_collision_body


func publish_visual(part, parent: Node3D) -> void:
	if not _paving_part_valid(part): return
	if not _masonry_part_valid(part): return
	match String(part.kind):
		"wall":
			if ConstructionMaterialCatalogScript.is_masonry_material(String(part.material_id)):
				publish_brick_wall(part, parent)
			else:
				publish_timber_wall(part, parent)
		"foundation":
			if ConstructionMaterialCatalogScript.is_cobble_material(String(part.material_id)):
				publish_settled_cobble(part, parent)
			elif ConstructionMaterialCatalogScript.is_masonry_material(String(part.material_id)):
				publish_brick_wall(part, parent)
			else:
				add_box_visual(parent, part.size, Vector3.ZERO, material_for(part), "Visual_foundation")
		"floor":
			publish_board_floor(part, parent)
		"beam":
			if String(part.material_id) in ["timber_beam", "timber_board"]:
				publish_aged_timber_beam(part, parent)
			else:
				add_box_visual(parent, part.size, Vector3.ZERO, material_for(part), "Visual_beam")
		"roof":
			publish_roof_shingles(part, parent)
		"door":
			if String(part.recipe.get("doorPresentation", "")) == "portcullis":
				publish_portcullis(part, parent)
			else:
				publish_door_boards(part, parent)
		"window":
			publish_window(part, parent)
		"barrel":
			publish_barrel(part, parent)
		"crate":
			publish_framed_crate(part, parent)
		"pennant":
			publish_cloth_pennant(part, parent)
		"ground_patch":
			publish_irregular_ground_patch(part, parent)
		"sack":
			publish_sack(part, parent)
		"pottery":
			publish_pottery(part, parent)
		"basket":
			publish_basket(part, parent)
		"tool_rack":
			publish_tool_rack(part, parent)
		_:
			add_box_visual(parent, part.size, Vector3.ZERO, material_for(part), "Visual_%s" % part.kind)


func publish_practical_light(part, parent: Node3D) -> void:
	var light := OmniLight3D.new()
	light.name = "RecipePracticalLight_%s" % String(part.id)
	light.light_color = Color(1.0, 0.58, 0.30)
	light.light_energy = float(part.recipe.get("lightEnergy", 1.5))
	light.omni_range = float(part.recipe.get("lightRange", 5.0))
	light.shadow_enabled = light.light_energy >= 1.70
	if static_visual_collecting:
		light.position = static_visual_part_transform.origin
	parent.add_child(light)


func publish_timber_wall(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var row_height := 0.34
	var rows := maxi(1, ceili(size.y / row_height))
	var transforms: Array[Transform3D] = []
	var weathered_transforms: Array[Transform3D] = []
	var horizontal_axis := 0 if size.x >= size.z else 2
	var horizontal_length := size[horizontal_axis]
	var depth_axis := 2 if horizontal_axis == 0 else 0
	var part_phase := float(posmod(String(part.id).hash(), 997)) / 997.0
	for row in range(rows):
		var height := size.y / float(rows)
		var y := -size.y * 0.5 + height * (float(row) + 0.5)
		var row_phase := fposmod(part_phase + float(row) * 0.317, 1.0)
		var cursor := -horizontal_length * 0.5 - (0.52 + row_phase * 0.74 if row % 2 == 1 else 0.0)
		var column := 0
		while cursor < horizontal_length * 0.5 - 0.03:
			var piece_phase := fposmod(sin(float(row + 1) * 17.137 + float(column + 1) * 43.771 + part_phase * 9.1) * 23171.31, 1.0)
			var nominal_length := lerpf(1.10, 2.35, piece_phase)
			var piece_start := maxf(cursor, -horizontal_length * 0.5)
			var piece_end := minf(cursor + nominal_length, horizontal_length * 0.5)
			if piece_end - piece_start >= 0.18:
				var board_size := size
				board_size[horizontal_axis] = maxf(0.14, piece_end - piece_start - 0.026)
				board_size.y = maxf(0.04, height - 0.026)
				var position := Vector3.ZERO
				position[horizontal_axis] = (piece_start + piece_end) * 0.5
				position[depth_axis] = (piece_phase - 0.5) * 0.022
				position.y = y + (piece_phase - 0.5) * 0.012
				var conditions := surface_history.conditions_at(part.position + position)
				var weathered := float(conditions.get("runoff", 0.0)) > 0.44
				if weathered:
					position[depth_axis] -= 0.014 + piece_phase * 0.016
					board_size.y *= lerpf(0.935, 0.985, piece_phase)
				var settlement_axis := Vector3.FORWARD if horizontal_axis == 0 else Vector3.RIGHT
				var settlement := (piece_phase - 0.5) * deg_to_rad(0.72)
				var transform := Transform3D(Basis(settlement_axis, settlement).scaled(board_size), position)
				if weathered:
					weathered_transforms.append(transform)
				else:
					transforms.append(transform)
			cursor += nominal_length
			column += 1
	add_box_batch(parent, transforms, material_for(part), "PlankCladding", build_facade_custom_data(transforms, part))
	if not weathered_transforms.is_empty():
		add_box_batch(parent, weathered_transforms, weathered_timber_material_for(part), "WeatheredPlankCladding", build_facade_custom_data(weathered_transforms, part))


func publish_aged_timber_beam(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	# Load-bearing joinery can opt into a straight profile: cosmetic segment
	# bending must not pull visible bearing faces away from their real seats.
	# Keep the same material and facade-condition custom-data pipeline.
	var preserve_faces = part.recipe.get("preserveBearingFaces", false)
	if preserve_faces is bool and preserve_faces:
		var joined: Array[Transform3D] = [box_transform(Vector3.ZERO, size)]
		add_box_batch(parent, joined, material_for(part), "BearingTimber", build_facade_custom_data(joined, part))
		return
	var longest_axis := 0
	var longest_length := size.x
	if size.y > longest_length:
		longest_axis = 1
		longest_length = size.y
	if size.z > longest_length:
		longest_axis = 2
		longest_length = size.z
	var segment_count := 3 if longest_length > 1.05 else 1
	if segment_count == 1:
		add_box_visual(parent, size, Vector3.ZERO, material_for(part), "AgedTimberBeam")
		return
	var transforms: Array[Transform3D] = []
	var segment_length := longest_length / float(segment_count)
	var part_phase := float(posmod(String(part.id).hash(), 997)) / 997.0
	for segment_index in range(segment_count):
		var segment_phase := fposmod(part_phase + float(segment_index) * 0.371, 1.0)
		var resolved_size := size
		resolved_size[longest_axis] = segment_length + 0.045
		var axis_offset := -longest_length * 0.5 + segment_length * (float(segment_index) + 0.5)
		var position := Vector3.ZERO
		position[longest_axis] = axis_offset
		var bend := (segment_phase - 0.5) * deg_to_rad(1.15)
		var thickness_offset := sin(float(segment_index) * 1.9 + part_phase * TAU) * minf(0.018, longest_length * 0.004)
		var rotation_axis := Vector3.FORWARD if longest_axis in [0, 1] else Vector3.RIGHT
		if longest_axis == 0:
			position.y += thickness_offset
		elif longest_axis == 1:
			position.x += thickness_offset
		else:
			position.y += thickness_offset
		var basis := Basis(rotation_axis, bend).scaled(resolved_size * lerpf(0.985, 1.015, segment_phase))
		transforms.append(Transform3D(basis, position))
	add_box_batch(parent, transforms, material_for(part), "AgedTimberSegments", build_facade_custom_data(transforms, part))


func publish_brick_wall(part, parent: Node3D) -> void:
	if not _masonry_part_valid(part): return
	var artifact: Dictionary = _masonry_preparation.artifact(part) if _masonry_preparation!=null else {}
	var publication:=MasonryPublication.new(part,parent,static_visual_part_transform,static_visual_collecting,source_blueprint_id,artifact,not resumable_scene_publication)
	if resumable_scene_publication:
		_pending_masonry=publication
		return
	while publication.state not in ["ready","failed"]: publication.advance(self)
	if publication.state=="failed": _paving_reject(publication.reason)


func prepare_masonry_apertures(blueprint) -> bool:
	_masonry_preparation = MasonryAperturePublicationScript.new()
	return _masonry_preparation.begin_incremental(blueprint,self) if resumable_scene_publication else _masonry_preparation.begin(blueprint, self)


func _publication_failed() -> bool:
	return not _paving_failure.is_empty() or (_masonry_preparation != null and _masonry_preparation.state == "failed")


func _masonry_part_valid(part) -> bool:
	if _publication_failed(): return false
	if not _prepared_masonry_part_valid(part): return false
	if _masonry_preparation != null and _masonry_preparation.state == "pending_budget": return false
	if _masonry_preparation != null and not _masonry_preparation.validate_unit_source(self): return false
	if _masonry_preparation != null and not _masonry_preparation.accepts_source_member(part): return false
	var required: bool = part.recipe.has("masonryApertureSource") or (_masonry_preparation != null and _masonry_preparation.owns(part))
	if not required: return true
	if _masonry_preparation == null:
		_masonry_preparation = MasonryAperturePublicationScript.new()
		return _masonry_preparation._fail("unprepared_direct_masonry_publication")
	return _masonry_preparation.ready_for(part, self)

func _prepared_masonry_part_valid(part) -> bool:
	if _prepared_masonry!=_prepared_masonry_identity:
		return _paving_reject("replaced_prepared_masonry")
	if _prepared_masonry==null: return true
	if not _prepared_masonry.matches_history(_prepared_history,surface_history,source_blueprint_id):
		return _paving_reject("stale_prepared_masonry_history")
	if _prepared_masonry.has_part(part) and not _prepared_masonry.validate_part(part):
		return _paving_reject("stale_prepared_masonry_part")
	return true

func prepared_masonry_geometry(part) -> Dictionary:
	var started:=Time.get_ticks_usec()
	if not _prepared_masonry_part_valid(part): return {}
	if _prepared_masonry==null: return {}
	var geometry: Dictionary=_prepared_masonry.geometry_for(part)
	_record_publication_stage("prepared_masonry_lookup",Time.get_ticks_usec()-started)
	return geometry


func _publish_masonry_group(parent: Node3D, artifact: Dictionary, group: String, material: Material, label: String) -> void:
	var transforms: Array = []
	var custom: Array = []
	for entry: Dictionary in artifact.entries:
		if entry.original.group != group: continue
		if entry.unchanged:
			transforms.append(entry.original.localTransform)
			custom.append(entry.original.customData)
			continue
		if not transforms.is_empty():
			add_box_batch(parent, transforms, material, label, custom)
			transforms = []
			custom = []
		var prepared: Dictionary = artifact.preparedMeshes[entry.original.id]
		if prepared.mesh != null:
			add_mesh_batch(parent, prepared.mesh, [entry.original.localTransform], material, label, [entry.original.customData])
	if not transforms.is_empty(): add_box_batch(parent, transforms, material, label, custom)


func describe_masonry(part) -> Dictionary:
	return MasonryDescriptor.describe_source(part,surface_history,source_blueprint_id)


func masonry_brick_solids(part, geometry: Dictionary) -> Array:
	# Stable source identities describe the actual native unit-box instances.
	# Group-local ordinals are not old/new correspondence after re-coursing.
	var result: Array = []
	var frame := Transform3D(Basis.from_euler(part.rotation), part.position)
	for group: String in ["regular", "repair"]:
		var transforms: Array = geometry[group + "Transforms"]
		var custom: Array = geometry[group + "CustomData"]
		var material_key := "%s:%0.3f" % [geometry.surfaceMaterialId, masonry_family_variation(part)]
		if group == "repair": material_key = "masonry_repair:" + material_key
		for index in range(transforms.size()):
			result.append({"id": "%s:%s:%d" % [part.id, group, index], "group": group, "ordinal": index,
				"materialKey": material_key, "surfaceMaterialId": geometry.surfaceMaterialId, "customData": custom[index],
				"localTransform": transforms[index], "transform": frame * transforms[index]})
	return result


func publish_settled_cobble(part, parent: Node3D) -> void:
	if not _paving_part_valid(part): return
	if part.recipe.has("pavingFootingJoints"):
		_publish_jointed_paving(part, parent)
		return
	if resumable_scene_publication:
		_pending_paving=PavingPublication.new(part,parent,static_visual_part_transform,static_visual_collecting,source_blueprint_id)
		return
	var geometry: Dictionary = SettledCobbleGeometryScript.describe_source(part, surface_history, source_blueprint_id)
	var bed: Dictionary = geometry.bed
	add_box_visual(parent, bed.size, bed.position, material_for_id(bed.materialId, variation_for(part) - 0.025), "CobbleJointBed")
	add_mesh_batch(parent, unit_box, geometry.regularTransforms, material_for(part), "SettledCobbleStones", geometry.regularCustomData)
	if not geometry.wornTransforms.is_empty():
		add_mesh_batch(parent, unit_box, geometry.wornTransforms, material_for_id("worn_cobble", variation_for(part) - 0.016), "WornSettledCobbleStones", geometry.wornCustomData)


func _paving_reject(reason: String) -> bool:
	if _paving_failure.is_empty(): _paving_failure = reason
	_paving_complete = false
	return false


func _prepare_paving_publication(b) -> bool:
	var finishes: Array = []
	for part in b.parts:
		if part != null and part.recipe.has("pavingFootingJoints"): finishes.append(part)
	# Preserve the legacy source/material path when no declaration is present.
	if finishes.is_empty(): return true
	if b.parts.size() > 10000 or finishes.size() > MAX_JOINTED_FINISHES: return _paving_reject("paving_collection_limit")
	var by_id: Dictionary = {}
	for part in b.parts:
		if part == null or part.id.is_empty() or by_id.has(part.id): return _paving_reject("paving_invalid_source_ids")
		by_id[part.id] = part
	var requests: Array = []
	var all_feet: Dictionary = {}
	# Validate ALL declarations and aggregate limits before any mesh preparation.
	for finish in finishes:
		var declaration: Variant = finish.recipe.pavingFootingJoints
		if not declaration is Dictionary or declaration.size() != 4 or not declaration.get("footPartIds") is Array or not (declaration.get("nominalJoint") is float or declaration.get("nominalJoint") is int): return _paving_reject("paving_invalid_declaration")
		for key in ["geometryDigest", "constructionDigest"]:
			if not declaration.get(key) is String or declaration[key].length() != 64 or not declaration[key].is_valid_hex_number(false): return _paving_reject("paving_invalid_committed_digest")
		var joint: float = declaration.nominalJoint
		if not is_finite(joint) or joint <= 0.0 or joint > PavingFootingAssemblyScript.FootCuts.MAX_JOINT or declaration.footPartIds.is_empty() or declaration.footPartIds.size() > MAX_JOINTED_FEET: return _paving_reject("paving_invalid_joint_or_feet")
		if finish.collision_enabled or finish.kind != "foundation" or not ConstructionMaterialCatalogScript.is_cobble_material(finish.material_id) or finish.recipe.get("visual", true) != true: return _paving_reject("paving_requires_visible_noncollision_finish")
		var feet: Array = []
		var seen: Dictionary = {}
		for id in declaration.footPartIds:
			if not id is String or id.is_empty() or id == finish.id or seen.has(id) or not by_id.has(id): return _paving_reject("paving_unresolved_or_duplicate_foot")
			seen[id] = true
			all_feet[id] = true
			feet.append(by_id[id])
		if all_feet.size() > MAX_JOINTED_FEET: return _paving_reject("paving_total_foot_limit")
		requests.append({"finish": finish, "feet": feet, "joint": joint})
	for request in requests:
		_paving_source_parts[request.finish.id] = request.finish
		for foot in request.feet: _paving_source_parts[foot.id] = foot
	_paving_blueprint = b
	var binding: PackedByteArray = _paving_source_binding(b)
	if binding.is_empty(): return _paving_reject("paving_invalid_source_binding")
	var staged: Dictionary = {}
	for request in requests:
		var result: Dictionary = PavingFootingAssemblyScript.prepare(b, [request.finish.id], request.feet, request.joint)
		if not bool(result.get("ready", false)): return _paving_reject("paving_prepare:" + String(result.get("reason", "unknown")))
		if not result.get("joints") is Dictionary or not result.joints.has(request.finish.id) or var_to_bytes(result.joints[request.finish.id]) != var_to_bytes(request.finish.recipe.pavingFootingJoints): return _paving_reject("paving_committed_geometry_mismatch")
		if not result.get("artifacts") is Dictionary or result.artifacts.size() != 1 or not result.artifacts.has(request.finish.id): return _paving_reject("paving_missing_finalized_artifact")
		var artifact: Dictionary = result.artifacts[request.finish.id]
		if not _paving_artifact_valid(artifact, request.finish): return _paving_reject("paving_invalid_finalized_artifact")
		staged[request.finish.id] = {"artifact": artifact, "sourceBinding": binding}
	if binding != _paving_source_binding(b): return _paving_reject("paving_preparation_mutated_source")
	_paving_artifacts = staged
	_paving_binding = binding
	_paving_history_binding = _paving_history_identity()
	_paving_prepared = true
	return true


func _paving_source_binding(b) -> PackedByteArray:
	if b == null or b.parts.size() > 10000: return PackedByteArray()
	var ids: Dictionary = {}
	var records: Array = []
	for part in b.parts:
		if part == null or part.id.is_empty() or ids.has(part.id): return PackedByteArray()
		ids[part.id] = true
		if _paving_source_parts.has(part.id) and _paving_source_parts[part.id] != part: return PackedByteArray()
		# These are exactly the part families consumed by History.configure.
		# Recipe is retained in full, including canonical ID, routes and trees.
		if _paving_source_parts.has(part.id) or part.recipe.has("pavingFootingJoints") or part.kind in ["door", "window"] or part.semantic.contains("eave") or bool(part.recipe.get("weatheringEave", false)):
			records.append(part.snapshot())
	for id in _paving_source_parts:
		if not ids.has(id): return PackedByteArray()
	return var_to_bytes([canonical_source_blueprint_id(b), b.recipe, ids.keys(), records])


func _paving_session_valid(b) -> bool:
	if not _paving_failure.is_empty(): return false
	if _paving_blueprint == null: return true
	if not _paving_prepared or b != _paving_blueprint or source_blueprint_id != canonical_source_blueprint_id(b) or _paving_binding != _paving_source_binding(b) or _paving_history_binding != _paving_history_identity(): return _paving_reject("paving_stale_preparation")
	return true


func _paving_history_identity() -> PackedByteArray:
	return var_to_bytes([surface_history.route_corridors, surface_history.tree_placements, surface_history.history_events, surface_history.history_event_cells])


func _paving_part_valid(part) -> bool:
	if not _paving_failure.is_empty(): return false
	# Feet have no finish artifact, but their exact source identity/pose owns the
	# aperture. Also recognize retained objects whose ID was changed after begin.
	var bound: bool = _paving_source_parts.has(part.id) or _paving_source_parts.find_key(part) != null
	var needs_artifact: bool = part.recipe.has("pavingFootingJoints") or _paving_artifacts.has(part.id)
	if not bound and not needs_artifact: return true
	if not _paving_prepared or _paving_source_parts.get(part.id) != part or (needs_artifact and not _paving_artifacts.has(part.id)): return _paving_reject("paving_unprepared_direct_publication")
	if not _paving_session_valid(_paving_blueprint): return false
	return true


func _paving_artifact_valid(artifact: Dictionary, part) -> bool:
	if artifact.get("completed") != true or artifact.get("stage") != "represented_publication_geometry" or not artifact.get("entries") is Array or artifact.entries.is_empty() or artifact.entries.size() > 8192: return false
	var source_transform: Transform3D = Transform3D(Basis.from_euler(part.rotation), part.position)
	if artifact.get("sourceTransform") != source_transform: return false
	var group_index: int = 0
	var ordinal: int = 0
	for entry in artifact.entries:
		if not entry is Dictionary or not entry.get("original") is Dictionary or not entry.get("unchanged") is bool: return false
		var original: Dictionary = entry.original
		var next_group: int = ["bed", "regular", "worn"].find(original.get("group"))
		if next_group < group_index or next_group < 0: return false
		if next_group != group_index:
			group_index = next_group
			ordinal = 0
		if original.get("ordinal") != ordinal or not original.get("localTransform") is Transform3D or original.get("transform") != source_transform * original.localTransform: return false
		ordinal += 1
		if group_index == 0:
			if ordinal != 1 or original.get("customData") != null or not original.get("materialKey") is String: return false
		elif not original.get("customData") is Color: return false
		if not entry.unchanged:
			if not entry.has("mesh") or not entry.get("cells") is Array: return false
			if entry.mesh == null:
				if not entry.cells.is_empty(): return false
			elif not entry.mesh is ArrayMesh or entry.mesh.get_surface_count() != 1: return false
	return artifact.entries[0].original.group == "bed"


func _publish_jointed_paving(part, parent: Node3D) -> void:
	var artifact: Dictionary = _paving_artifacts[part.id].artifact
	# No geometry recomputation or world-to-local round trip here. Artifacts are
	# privately owned after preparation and never supplied through source caches.
	var bed: Dictionary = artifact.entries[0]
	var local: Transform3D = bed.original.localTransform
	var bed_material: Material = material_for_id(bed.original.materialKey, variation_for(part) - 0.025)
	if bed.unchanged:
		add_box_visual(parent, Vector3(local.basis.x.x, local.basis.y.y, local.basis.z.z), local.origin, bed_material, "CobbleJointBed")
	elif bed.mesh != null:
		if static_visual_collecting:
			add_mesh_batch(parent, bed.mesh, [local], bed_material, "CobbleJointBed", [Color(0.5, 0.5, 0.5, 1.0)])
		else:
			add_mesh_visual(parent, bed.mesh, Vector3(local.basis.x.x, local.basis.y.y, local.basis.z.z), local.origin, bed_material, "CobbleJointBed")
	# Keep the original material evaluation order, including an empty regular
	# group and fully removed entries; never warm a new material during prepare.
	var regular_material: Material = material_for(part)
	for group in ["regular", "worn"]:
		var entries: Array = artifact.entries.filter(func(entry): return entry.original.group == group)
		if entries.is_empty(): continue
		var material: Material = regular_material if group == "regular" else material_for_id("worn_cobble", variation_for(part) - 0.016)
		var label: String = "SettledCobbleStones" if group == "regular" else "WornSettledCobbleStones"
		var transforms: Array = []
		var custom: Array = []
		for entry in entries:
			if entry.unchanged:
				transforms.append(entry.original.localTransform)
				custom.append(entry.original.customData)
				continue
			if not transforms.is_empty():
				add_mesh_batch(parent, unit_box, transforms, material, label, custom)
				transforms = []
				custom = []
			if entry.mesh != null:
				add_mesh_batch(parent, entry.mesh, [entry.original.localTransform], material, label, [entry.original.customData])
		if not transforms.is_empty(): add_mesh_batch(parent, unit_box, transforms, material, label, custom)


func paving_family_for(part) -> String:
	return SettledCobbleGeometryScript.family_for(part)


func paving_runs_along_x(part) -> bool:
	return SettledCobbleGeometryScript.runs_along_x(part)


func paving_region_phase(part) -> float:
	return SettledCobbleGeometryScript.region_phase(part, source_blueprint_id)


func paving_treatment_strength(world_position: Vector3) -> float:
	return float(surface_history.wear_contact_at(world_position).get("influence", 0.0))


func build_masonry_custom_data(transforms: Array[Transform3D], part, repair_flags: Array[bool] = [], repair_profile: Dictionary = {}) -> Array[Color]:
	return MasonryDescriptor.build_masonry_custom_data(transforms,part,surface_history,repair_flags,repair_profile)


func build_facade_custom_data(transforms: Array[Transform3D], part) -> Array[Color]:
	var result: Array[Color] = []
	var min_y := INF
	var max_y := -INF
	for transform in transforms:
		min_y = minf(min_y, transform.origin.y)
		max_y = maxf(max_y, transform.origin.y)
	var height_range := maxf(0.001, max_y - min_y)
	var seed_phase := float(posmod(String(part.id).hash(), 4093)) / 4093.0
	for index in range(transforms.size()):
		var origin := transforms[index].origin
		var height := clampf((origin.y - min_y) / height_range, 0.0, 1.0)
		var stable := fposmod(sin(origin.x * 17.13 + origin.y * 43.77 + origin.z * 11.91 + seed_phase * 97.0) * 31757.13, 1.0)
		result.append(history_custom_data(part.position + origin))
	return result


func history_custom_data(world_position: Vector3) -> Color:
	return MasonryDescriptor.history_custom_data(world_position,surface_history)


func pack_route_history(influence: float, lateral: float) -> float:
	return SettledCobbleGeometryScript.pack_route_history(influence, lateral)


func append_brick_face_transforms(transforms: Array[Transform3D], repair_flags: Array[bool], size: Vector3, axis_x: bool, face_sign: float, unit_length: float, unit_height: float, joint_width: float, face_depth: float, masonry_phase: float, repair_profile: Dictionary, face_index: int) -> void:
	MasonryDescriptor.append_brick_face_transforms(transforms,repair_flags,size,axis_x,face_sign,unit_length,unit_height,joint_width,face_depth,masonry_phase,repair_profile,face_index)


func masonry_repair_profile(part) -> Dictionary:
	return MasonryDescriptor.masonry_repair_profile(part,surface_history,source_blueprint_id)


func masonry_repair_cluster_at(part, origin: Vector3, repair_profile: Dictionary) -> bool:
	return MasonryDescriptor.masonry_repair_cluster_at(part,origin,repair_profile)


func masonry_repair_cluster_matches(repair_profile: Dictionary, face_index: int, normalized_y: float, normalized_along: float, course_index := -1) -> bool:
	return MasonryDescriptor.masonry_repair_cluster_matches(repair_profile,face_index,normalized_y,normalized_along,course_index)


func masonry_repair_patch_blend(part, origin: Vector3, repair_profile: Dictionary, stone_phase: float) -> float:
	return MasonryDescriptor.masonry_repair_patch_blend(part,origin,repair_profile,stone_phase)


func publish_board_floor(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var board_width := 0.36
	var count := maxi(1, ceili(size.x / board_width))
	var transforms: Array[Transform3D] = []
	for index in range(count):
		var width := size.x / float(count)
		transforms.append(box_transform(Vector3(-size.x * 0.5 + width * (float(index) + 0.5), 0.0, 0.0), Vector3(maxf(0.04, width - 0.024), size.y, size.z)))
	add_box_batch(parent, transforms, material_for(part), "FloorBoards")


func publish_roof_shingles(part, parent: Node3D) -> void:
	var job=RoofPublication.new(part,parent,static_visual_part_transform,static_visual_collecting,source_blueprint_id,not resumable_scene_publication)
	if resumable_scene_publication:
		_pending_roof=job
		return
	while true:
		var result: Dictionary=job.advance(self,2500)
		if result.status=="failed":
			_paving_reject(String(result.reason))
			return
		if result.status=="ready": return


func publish_door_boards(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var geometry: Dictionary = BuildingDoorGeometryScript.describe(size)
	var pivot := Node3D.new()
	pivot.name = "DoorPivot"
	pivot.position = geometry.pivotPosition
	parent.add_child(pivot)
	var leaf := Node3D.new()
	leaf.name = "DoorLeaf"
	leaf.position = geometry.leafPosition
	pivot.add_child(leaf)
	var transforms: Array[Transform3D] = []
	for board in geometry.boards:
		transforms.append(box_transform(board.position, board.size))
	add_box_batch(leaf, transforms, material_for(part), "DoorBoards")
	# The frame, brace and handle belong to the same semantic door part; they make
	# the opening readable without creating a second collision authority.
	add_box_visual(leaf, geometry.brace.size, geometry.brace.position, material_for_id("timber_beam", variation_for(part)), "DoorBrace")
	var frame_material := material_for_id("timber_beam", variation_for(part))
	add_box_visual(parent, geometry.frameLeft.size, geometry.frameLeft.position, frame_material, "DoorFrameLeft")
	add_box_visual(parent, geometry.frameRight.size, geometry.frameRight.position, frame_material, "DoorFrameRight")
	add_box_visual(parent, geometry.frameTop.size, geometry.frameTop.position, frame_material, "DoorFrameTop")
	add_box_visual(leaf, geometry.handle.size, geometry.handle.position, material_for_id("brass", variation_for(part)), "DoorHandle")


func publish_portcullis(part, parent: Node3D) -> void:
	# A castle gate is a raised iron grille, not a painted plank wall.  It is
	# still one ordinary door part: the shared controller owns its closed
	# collision and lifts the same visual leaf clear when opened.
	var size: Vector3 = part.size
	var geometry: Dictionary = BuildingDoorGeometryScript.describe_portcullis(size)
	var pivot := Node3D.new()
	pivot.name = "DoorPivot"
	parent.add_child(pivot)
	var leaf := Node3D.new()
	leaf.name = "DoorLeaf"
	pivot.add_child(leaf)
	var bars: Array[Transform3D] = []
	for bar in geometry.bars:
		bars.append(box_transform(bar.position, bar.size))
	add_box_batch(leaf, bars, material_for(part), "PortcullisBars")
	for crossbar in geometry.crossbars:
		add_box_visual(leaf, crossbar.size, crossbar.position, material_for(part), "PortcullisCrossbar")
	publish_portcullis_lever(part, parent)


func publish_portcullis_lever(part, parent: Node3D) -> void:
	var geometry: Dictionary = BuildingDoorGeometryScript.describe_portcullis(part.size)
	var lever := Node3D.new()
	lever.name = "PortcullisLever"
	lever.position = geometry.leverPosition
	parent.add_child(lever)
	add_box_visual(lever, geometry.mount.size, geometry.mount.position, material_for_id("stone_foundation", variation_for(part)), "LeverMount")
	var arm_pivot := Node3D.new()
	arm_pivot.name = "LeverArmPivot"
	arm_pivot.rotation = geometry.leverRotation
	lever.add_child(arm_pivot)
	add_box_visual(arm_pivot, geometry.arm.size, geometry.arm.position, material_for_id("ironwork", variation_for(part)), "LeverArm")
	add_box_visual(arm_pivot, geometry.handle.size, geometry.handle.position, material_for_id("brass", variation_for(part)), "LeverHandle")


func configure_door_leaf(body: StaticBody3D, part) -> void:
	# Match the established DoorPortal/DoorController leaf contract. The generic
	# controller owns swing state and collider disabling; this publisher only
	# provides a building-derived door leaf for it to operate on.
	# One recipe can be published at multiple sites. Site identity is supplied
	# by the revision-bound owner; it does not mutate the visual/source recipe.
	var building_id := publication_site_id if not publication_site_id.is_empty() else source_blueprint_id
	var portal_id := "building:%s:%s" % [building_id, String(part.id)]
	body.set_meta("block_type", "door")
	body.set_meta("open", false)
	body.set_meta("closed_rotation", body.rotation.y)
	body.set_meta("open_swing", BuildingDoorGeometryScript.DEFAULT_OPEN_SWING)
	body.set_meta("door_motion", String(part.recipe.get("doorMotion", "swing")))
	body.set_meta("door_presentation", String(part.recipe.get("doorPresentation", "door")))
	body.set_meta("open_visual_offset", BuildingDoorGeometryScript.raised_visual_offset(part.size) if String(part.recipe.get("doorMotion", "swing")) == "raise" else Vector3.ZERO)
	body.set_meta("door_portal_id", portal_id)
	body.set_meta("door_group_id", portal_id)
	body.set_meta("door_building_id", building_id)
	body.set_meta("door_side", door_side_for_world_transform(body.global_transform))
	body.set_meta("door_public_access", true)
	body.set_meta("door_policy", "private_home")
	body.set_meta("locked", false)
	body.set_meta("jammed", false)
	body.set_meta("destroyed", false)
	body.set_meta("unloaded", false)


func door_side_for_world_transform(transform: Transform3D) -> int:
	var forward := transform.basis * Vector3.FORWARD
	forward.y = 0.0
	if forward.length_squared() <= 0.0001:
		return 0
	forward = forward.normalized()
	if absf(forward.x) > absf(forward.z):
		return 1 if forward.x > 0.0 else 3
	return 0 if forward.z >= 0.0 else 2


func add_door_interaction_proxy(door: StaticBody3D, part) -> void:
	var size: Vector3 = part.size
	var area := Area3D.new()
	area.name = "DoorInteraction"
	area.collision_layer = 1 << 10
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	area.set_meta("interaction_parent", door)
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x * 1.26, size.y * 1.04, maxf(1.10, size.z * 4.0))
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.set_meta("building_part_id", part.id)
	collider.set_meta("building_part_kind", part.kind)
	collider.set_meta("building_semantic", part.semantic)
	collider.set_meta("building_collision_role", "door_interaction_proxy")
	area.add_child(collider)
	door.add_child(area)
	if String(part.recipe.get("doorPresentation", "")) == "portcullis":
		# The stationary control targets the same door through the established
		# interaction_parent contract, including while the grille is raised.
		# Areas are ray targets only; no extra blocking or navigation geometry.
		for piece: Dictionary in BuildingDoorGeometryScript.portcullis_closed_primitives(size, Transform3D.IDENTITY):
			if bool(piece.moving): continue
			var control_shape := CollisionShape3D.new()
			control_shape.name="LeverInteraction_"+String(piece.name)
			var box := BoxShape3D.new()
			box.size=piece.size
			control_shape.shape=box
			control_shape.transform=piece.transform
			control_shape.set_meta("building_collision_role","door_interaction_proxy")
			area.add_child(control_shape)


func publish_window(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var monumental := String(part.id).begins_with("castle_keep_") or String(part.id).begins_with("castle_gatehouse_")
	var trim := material_for_id("stone_foundation" if monumental else "timber_beam", variation_for(part) - 0.02)
	add_box_visual(parent, size, Vector3.ZERO, material_for(part), "WindowGlass")
	if size.x < size.z:
		add_box_visual(parent, Vector3(size.x * 1.62, size.y * 1.18, 0.14), Vector3(0.0, 0.0, -size.z * 0.58), trim, "WindowFrameNear")
		add_box_visual(parent, Vector3(size.x * 1.62, size.y * 1.18, 0.14), Vector3(0.0, 0.0, size.z * 0.58), trim, "WindowFrameFar")
		add_box_visual(parent, Vector3(size.x * 1.62, 0.15, size.z * 1.30), Vector3(0.0, size.y * 0.59, 0.0), trim, "WindowLintel")
		add_box_visual(parent, Vector3(size.x * 1.82, 0.17, size.z * 1.36), Vector3(0.0, -size.y * 0.59, 0.0), trim, "WindowSill")
		add_box_visual(parent, Vector3(size.x * 1.68, 0.075, size.z * 1.68), Vector3(0.0, 0.0, 0.0), trim, "WindowMullionHorizontal")
		add_box_visual(parent, Vector3(size.x * 1.68, size.y * 1.05, 0.075), Vector3(0.0, 0.0, 0.0), trim, "WindowMullionVertical")
	else:
		add_box_visual(parent, Vector3(0.14, size.y * 1.18, size.z * 1.62), Vector3(-size.x * 0.58, 0.0, 0.0), trim, "WindowFrameNear")
		add_box_visual(parent, Vector3(0.14, size.y * 1.18, size.z * 1.62), Vector3(size.x * 0.58, 0.0, 0.0), trim, "WindowFrameFar")
		add_box_visual(parent, Vector3(size.x * 1.30, 0.15, size.z * 1.62), Vector3(0.0, size.y * 0.59, 0.0), trim, "WindowLintel")
		add_box_visual(parent, Vector3(size.x * 1.36, 0.17, size.z * 1.82), Vector3(0.0, -size.y * 0.59, 0.0), trim, "WindowSill")
		add_box_visual(parent, Vector3(size.x * 1.68, 0.075, size.z * 1.68), Vector3(0.0, 0.0, 0.0), trim, "WindowMullionHorizontal")
		add_box_visual(parent, Vector3(0.075, size.y * 1.05, size.z * 1.68), Vector3(0.0, 0.0, 0.0), trim, "WindowMullionVertical")


func publish_barrel(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var radius := minf(size.x, size.z) * 0.46
	var stave_count := 12
	var stave_width := TAU * radius / float(stave_count) * 0.86
	var staves: Array[Transform3D] = []
	var hoops: Array[Transform3D] = []
	for stave_index in range(stave_count):
		var angle := TAU * float(stave_index) / float(stave_count)
		var position := Vector3(sin(angle) * radius, 0.0, cos(angle) * radius)
		staves.append(oriented_box_transform(position, Vector3(stave_width, size.y, maxf(0.055, radius * 0.18)), angle))
		for hoop_y in [-size.y * 0.31, size.y * 0.31]:
			hoops.append(oriented_box_transform(position + Vector3(0.0, hoop_y, 0.0), Vector3(stave_width * 1.04, 0.075, maxf(0.065, radius * 0.20)), angle))
	add_box_batch(parent, staves, material_for_id("timber_board", variation_for(part)), "BarrelStaves")
	add_box_batch(parent, hoops, material_for_id("ironwork", variation_for(part)), "BarrelHoops")
	add_box_visual(parent, Vector3(radius * 1.52, 0.07, radius * 1.52), Vector3(0.0, size.y * 0.5 - 0.04, 0.0), material_for_id("timber_board", variation_for(part) - 0.02), "BarrelTop")


func publish_framed_crate(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var panel_material := material_for_id("timber_board", variation_for(part))
	var frame_material := material_for_id("timber_beam", variation_for(part) - 0.02)
	add_box_visual(parent, Vector3(size.x * 0.88, size.y * 0.76, size.z * 0.88), Vector3.ZERO, panel_material, "CratePanels")
	for x_sign in [-1.0, 1.0]:
		for z_sign in [-1.0, 1.0]:
			add_box_visual(parent, Vector3(0.095, size.y, 0.095), Vector3(x_sign * size.x * 0.43, 0.0, z_sign * size.z * 0.43), frame_material, "CrateCorner")
	for y_sign in [-1.0, 1.0]:
		add_box_visual(parent, Vector3(size.x, 0.09, 0.10), Vector3(0.0, y_sign * size.y * 0.43, size.z * 0.46), frame_material, "CrateFaceRail")
		add_box_visual(parent, Vector3(0.10, 0.09, size.z), Vector3(size.x * 0.46, y_sign * size.y * 0.43, 0.0), frame_material, "CrateSideRail")


func publish_cloth_pennant(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_normal(Vector3.FORWARD)
	surface.set_uv(Vector2(0.0, 0.0))
	surface.add_vertex(Vector3(-size.x * 0.5, size.y * 0.5, 0.0))
	surface.set_uv(Vector2(1.0, 0.0))
	surface.add_vertex(Vector3(size.x * 0.5, size.y * 0.5, 0.0))
	surface.set_uv(Vector2(0.5, 1.0))
	surface.add_vertex(Vector3(0.0, -size.y * 0.5, 0.0))
	var mesh := surface.commit()
	var visual := MeshInstance3D.new()
	visual.name = "ClothPennant"
	visual.mesh = mesh
	visual.material_override = material_for(part)
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if static_visual_collecting:
		visual.transform = static_visual_part_transform
	parent.add_child(visual)
	visual_batch_count += 1


func publish_irregular_ground_patch(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var surface := SurfaceTool.new()
	var segment_count := 14
	var phase := float(posmod(String(part.id).hash(), 360)) * PI / 180.0
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_normal(Vector3.UP)
	for segment_index in range(segment_count):
		var angle_a := TAU * float(segment_index) / float(segment_count)
		var angle_b := TAU * float(segment_index + 1) / float(segment_count)
		var radius_a := 0.82 + sin(angle_a * 3.0 + phase) * 0.10 + sin(angle_a * 7.0 + phase * 0.7) * 0.06
		var radius_b := 0.82 + sin(angle_b * 3.0 + phase) * 0.10 + sin(angle_b * 7.0 + phase * 0.7) * 0.06
		var point_a := Vector3(cos(angle_a) * size.x * 0.5 * radius_a, 0.0, sin(angle_a) * size.z * 0.5 * radius_a)
		var point_b := Vector3(cos(angle_b) * size.x * 0.5 * radius_b, 0.0, sin(angle_b) * size.z * 0.5 * radius_b)
		surface.set_uv(Vector2(0.5, 0.5))
		surface.add_vertex(Vector3.ZERO)
		surface.set_uv(Vector2(0.5 + point_b.x / maxf(size.x, 0.01), 0.5 + point_b.z / maxf(size.z, 0.01)))
		surface.add_vertex(point_b)
		surface.set_uv(Vector2(0.5 + point_a.x / maxf(size.x, 0.01), 0.5 + point_a.z / maxf(size.z, 0.01)))
		surface.add_vertex(point_a)
	var mesh := surface.commit()
	var visual := MeshInstance3D.new()
	visual.name = "IrregularGroundPatch"
	visual.mesh = mesh
	visual.material_override = material_for(part)
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if static_visual_collecting:
		visual.transform = static_visual_part_transform
	parent.add_child(visual)
	visual_batch_count += 1


func publish_sack(part, parent: Node3D) -> void:
	_publish_goods_geometry(part, parent, "sack")


func publish_pottery(part, parent: Node3D) -> void:
	_publish_goods_geometry(part, parent, "pottery")


func publish_basket(part, parent: Node3D) -> void:
	_publish_goods_geometry(part, parent, "basket")


func _publish_goods_geometry(part, parent: Node3D, kind: String) -> void:
	for piece in BuildingGoodsGeometryScript.describe(kind, part.size):
		var mesh: Mesh = null
		if piece.primitive != "box":
			mesh = BuildingGoodsGeometryScript.create_mesh(piece)
		var request: Dictionary = piece.material
		var material: Material
		if request.mode == "part":
			material = material_for(part)
		elif request.has("subtract"):
			material = material_for_id(String(request.id), variation_for(part) - float(request.subtract))
		else:
			# Do not add a zero offset: retain bare variation_for evaluation,
			# including its signed-zero behavior and material request ordering.
			material = material_for_id(String(request.id), variation_for(part))
		if piece.primitive == "box":
			add_box_visual(parent, piece.size, piece.position, material, piece.nodeName)
		else:
			add_mesh_visual(parent, mesh, piece.size, piece.position, material, piece.nodeName)


func publish_tool_rack(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	add_box_visual(parent, Vector3(size.x, 0.12, size.z), Vector3(0.0, size.y * 0.30, 0.0), material_for_id("timber_beam", variation_for(part)), "ToolRackRail")
	for tool_index in range(4):
		var x := -size.x * 0.36 + float(tool_index) * size.x * 0.24
		add_box_visual(parent, Vector3(0.065, size.y * (0.55 + float(tool_index % 2) * 0.14), 0.07), Vector3(x, -size.y * 0.03, -size.z * 0.10), material_for_id("ironwork", variation_for(part)), "HangingTool%02d" % tool_index)
		add_box_visual(parent, Vector3(0.22, 0.09, 0.08), Vector3(x, -size.y * (0.31 + float(tool_index % 2) * 0.06), -size.z * 0.10), material_for_id("ironwork", variation_for(part)), "ToolHead%02d" % tool_index)


func add_mesh_visual(parent: Node3D, mesh: Mesh, size: Vector3, position: Vector3, material: Material, node_name: String) -> void:
	var visual := MeshInstance3D.new()
	visual.name = node_name
	visual.mesh = mesh
	visual.position = position
	visual.scale = size
	visual.material_override = material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if static_visual_collecting:
		visual.transform = static_visual_part_transform * visual.transform
	parent.add_child(visual)
	visual_batch_count += 1


func add_box_batch(parent: Node3D, transforms: Array, material: Material, node_name: String, custom_data_override: Array = []) -> MultiMeshInstance3D:
	if transforms.is_empty():
		return null
	var custom_data := custom_data_override if custom_data_override.size() == transforms.size() else build_batch_custom_data(transforms)
	if static_visual_collecting:
		for index in range(transforms.size()):
			var transform_value = transforms[index]
			if transform_value is Transform3D:
				collect_static_visual_transform(static_visual_part_transform * (transform_value as Transform3D), material, custom_data[index] as Color)
		return null
	var multi_mesh := create_mesh_batch()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_custom_data = true
	multi_mesh.instance_count = transforms.size()
	multi_mesh.mesh = unit_box
	for index in range(transforms.size()):
		var instance_transform := transforms[index] as Transform3D
		submit_mesh_batch_instance(multi_mesh,index,instance_transform,custom_data[index] as Color)
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multi_mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	visual_batch_count += 1
	return instance


func create_mesh_batch() -> MultiMesh:
	return MultiMesh.new()


func submit_mesh_batch_instance(mesh: MultiMesh, index: int, transform: Transform3D, custom: Color) -> void:
	mesh.set_instance_transform(index,transform)
	mesh.set_instance_custom_data(index,custom)


func add_mesh_batch(parent: Node3D, mesh: Mesh, transforms: Array, material: Material, node_name: String, custom_data_override: Array = []) -> MultiMeshInstance3D:
	if transforms.is_empty() or mesh == null:
		return null
	var custom_data := custom_data_override if custom_data_override.size() == transforms.size() else build_batch_custom_data(transforms)
	var upload := MeshBatchUpload.new(mesh,transforms,custom_data,material,node_name,parent,static_visual_part_transform,static_visual_collecting)
	while upload.state not in ["ready","failed"]: upload.advance(self)
	if upload.state=="failed": _paving_reject(upload.reason)
	return upload.result()


func build_batch_custom_data(transforms: Array) -> Array[Color]:
	var result: Array[Color] = []
	var min_y := INF
	var max_y := -INF
	for transform_value in transforms:
		if transform_value is Transform3D:
			var origin := (transform_value as Transform3D).origin
			min_y = minf(min_y, origin.y)
			max_y = maxf(max_y, origin.y)
	var height_range := max_y - min_y
	for index in range(transforms.size()):
		var instance_transform := transforms[index] as Transform3D
		var origin := instance_transform.origin
		var stable_piece_tint := fposmod(sin(origin.x * 12.9898 + origin.y * 78.233 + origin.z * 37.719 + float(index) * 0.173) * 43758.5453, 1.0)
		var normalized_height := clampf((origin.y - min_y) / height_range, 0.0, 1.0) if height_range > 0.001 else 0.5
		var exposure := fposmod(sin(origin.x * 23.417 + origin.y * 7.913 + origin.z * 51.173 + float(index) * 0.271) * 19642.349, 1.0)
		result.append(Color(stable_piece_tint, normalized_height, exposure, 1.0))
	return result


func add_box_visual(parent: Node3D, size: Vector3, position: Vector3, material: Material, node_name: String) -> void:
	if static_visual_collecting:
		collect_static_visual_transform(static_visual_part_transform * box_transform(position, size), material, Color(0.5, 0.5, 0.5, 1.0))
		return
	var visual := MeshInstance3D.new()
	visual.name = node_name
	visual.mesh = unit_box
	visual.position = position
	visual.scale = size
	visual.material_override = material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(visual)
	visual_batch_count += 1


func collect_static_visual_transform(transform: Transform3D, material: Material, custom_data := Color(0.5, 0.5, 0.5, 1.0)) -> void:
	if material == null:
		return
	var key := str(material.get_instance_id())
	var group: Dictionary = static_visual_batches.get(key, {}) if static_visual_batches.get(key, {}) is Dictionary else {}
	if group.is_empty():
		group = {"material": material, "transforms": [], "customData": []}
	var transforms: Array = group.get("transforms", []) as Array
	var custom_data_values: Array = group.get("customData", []) as Array
	transforms.append(transform)
	custom_data_values.append(custom_data)
	static_visual_transform_count += 1
	group["transforms"] = transforms
	group["customData"] = custom_data_values
	static_visual_batches[key] = group


func flush_static_batches(parent: Node3D) -> void:
	if _static_flush==null: _begin_static_flush(parent,false)
	while has_pending_static_flush():
		if advance_static_flush(parent).status=="failed": break


func _begin_static_flush(parent: Node3D, notify_progress: bool) -> void:
	if _static_flush!=null or static_visual_batches.is_empty() or parent==null: return
	_static_flush = StaticBatchFlush.new()
	_static_flush_notify = notify_progress
	_static_flush.begin(static_visual_batches,static_part_records,parent)


func has_pending_static_flush() -> bool:
	return _static_flush!=null


func _scene_owner_matches(blueprint, parent: Node3D) -> bool:
	return blueprint==_scene_blueprint and _scene_parent!=null and _scene_parent.get_ref()==parent


func validate_static_flush_source() -> bool:
	if _publication_failed(): return false
	var started := Time.get_ticks_usec()
	if _scene_blueprint!=null and not _paving_session_valid(_scene_blueprint): return false
	_record_publication_stage("flush_validate_paving_session",Time.get_ticks_usec()-started)
	started=Time.get_ticks_usec()
	if _masonry_preparation!=null and not _masonry_preparation._validate_all(self): return false
	_record_publication_stage("flush_validate_apertures",Time.get_ticks_usec()-started)
	started=Time.get_ticks_usec()
	if not validate_paving_history_source(): return false
	_record_publication_stage("flush_validate_history",Time.get_ticks_usec()-started)
	started=Time.get_ticks_usec()
	for completed in _completed_paving:
		if _scene_blueprint==null or completed.index>=_scene_blueprint.parts.size() or _scene_blueprint.parts[completed.index]!=completed.job.source_part() or not completed.job.source_valid(self): return _paving_reject("stale_completed_paving_source")
	_record_publication_stage("flush_validate_completed_paving",Time.get_ticks_usec()-started)
	return true


func prepare_paving_history_snapshot():
	if _prepared_history!=null: return surface_history
	if _paving_history_snapshot!=null: return _paving_history_snapshot
	# Once per exclusively owned publication session, never once per stone or
	# slice. Standalone edits to public history invalidate at publication commits;
	# they do not rewrite history underneath an in-flight cursor.
	var started:=Time.get_ticks_usec()
	_paving_history_source=surface_history
	_paving_history_source_bytes=_paving_history_identity()
	var snapshot:=SurfaceHistoryFieldScript.new()
	snapshot.route_corridors=surface_history.route_corridors.duplicate(true)
	snapshot.tree_placements=surface_history.tree_placements.duplicate(true)
	snapshot.history_events=surface_history.history_events.duplicate(true)
	snapshot.history_event_cells=surface_history.history_event_cells.duplicate(true)
	for value in [snapshot.route_corridors,snapshot.tree_placements,snapshot.history_events,snapshot.history_event_cells]: _freeze_publication_value(value)
	_paving_history_snapshot=snapshot
	_record_publication_stage("paving_history_snapshot",Time.get_ticks_usec()-started)
	return snapshot


static func _freeze_publication_value(value: Variant) -> void:
	if value is Dictionary:
		for key in value: _freeze_publication_value(value[key])
		value.make_read_only()
	elif value is Array:
		for item in value: _freeze_publication_value(item)
		value.make_read_only()


func validate_paving_history_source() -> bool:
	if _prepared_history!=null:
		var started:=Time.get_ticks_usec()
		var valid: bool=_prepared_history.matches(surface_history,source_blueprint_id)
		_record_publication_stage("prepared_history_identity_validation",Time.get_ticks_usec()-started)
		return true if valid else _paving_reject("stale_prepared_history")
	if _paving_history_snapshot==null: return true
	var started:=Time.get_ticks_usec()
	var valid: bool = surface_history==_paving_history_source and _paving_history_source_bytes==_paving_history_identity()
	_record_publication_stage("paving_history_boundary_validation",Time.get_ticks_usec()-started)
	return true if valid else _paving_reject("stale_paving_history")


func advance_static_flush(parent: Node3D, budget_usec := 2500) -> Dictionary:
	if parent==null: return {"status":"failed","reason":"static_flush_parent_lost"}
	if _static_flush==null: return {"status":"ready","reason":""}
	if _static_flush._parent.get_ref()!=parent:
		_paving_reject("static_flush_parent_mismatch")
		return {"status":"failed","reason":"static_flush_parent_mismatch"}
	var result: Dictionary = _static_flush.advance(self,budget_usec)
	if result.status=="failed": _paving_reject(String(result.reason))
	if result.status in ["ready","failed"]:
		# Keep old deep metadata and consumed arrays out of main-thread release.
		_publication_retirement.append(_static_flush)
		_static_flush = null
		var notify := _static_flush_notify
		_static_flush_notify = false
		if result.status=="ready" and notify: report_incremental_progress("static_batch_flush")
	return result


func _record_publication_stage(stage: String, usec: int, detail := "") -> void:
	if not _publication_stage_metrics.has(stage):
		_publication_stage_metrics[stage] = {"calls":0,"totalUsec":0,"maxUsec":0,"detail":""}
	var record: Dictionary = _publication_stage_metrics[stage]
	record.calls += 1
	record.totalUsec += usec
	if usec > record.maxUsec:
		record.maxUsec = usec
		record.detail = detail.left(160)


func publication_timing() -> Dictionary:
	return _publication_stage_metrics.duplicate(true)


func report_incremental_progress(reason: String) -> void:
	if not incremental_progress_callback.is_valid():
		return
	incremental_progress_callback.call({
		"reason": reason,
		"publishedParts": incremental_published_parts,
		"totalParts": incremental_total_parts,
		"pendingStaticVisualInstances": static_visual_transform_count,
		"staticFlushCount": incremental_static_flush_count
	})


func box_transform(position: Vector3, size: Vector3) -> Transform3D:
	return Transform3D(Basis.from_scale(size), position)


func oriented_box_transform(position: Vector3, size: Vector3, yaw: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(size), position)


func variation_for(part) -> float:
	return float(part.recipe.get("variation", 0.0))


func masonry_family_variation(part) -> float:
	var tokens := String(part.id).split("_", false)
	var family_token_count := mini(4, tokens.size())
	var family_key := "_".join(tokens.slice(0, family_token_count))
	var family_index := posmod((source_blueprint_id + ":" + family_key).hash(), 5)
	var family_offsets := [-0.042, -0.021, 0.0, 0.018, 0.039]
	return variation_for(part) + float(family_offsets[family_index])


func masonry_event_weathering(part, transform: Transform3D, index: int) -> bool:
	var conditions := surface_history.conditions_at(part.position + transform.origin)
	var runoff := float(conditions.get("runoff", 0.0))
	return runoff >= 0.40


func weathered_masonry_material_for(part, material_id: String) -> Material:
	var variation := masonry_family_variation(part)
	var key := "weathered_masonry:%s:%0.3f" % [material_id, variation]
	if material_cache.has(key):
		return material_cache[key] as Material
	var material := ConstructionMaterialCatalogScript.create_material(material_id, variation)
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		var definition := ConstructionMaterialCatalogScript.definition_for(material_id)
		var base: Color = definition.get("base", Color.WHITE) as Color
		var accent: Color = definition.get("accent", Color.WHITE) as Color
		shader_material.set_shader_parameter("base_color", base.darkened(0.17))
		shader_material.set_shader_parameter("accent_color", accent.darkened(0.10))
		shader_material.set_shader_parameter("age_strength", minf(1.0, float(definition.get("age", 0.60)) + 0.20))
		shader_material.set_shader_parameter("damp_strength", minf(1.0, float(definition.get("damp", 0.36)) + 0.18))
		shader_material.set_shader_parameter("moss_strength", minf(0.70, float(definition.get("moss", 0.10)) + 0.18))
	material_cache[key] = material
	return material


func weathered_timber_material_for(part) -> Material:
	var variation := variation_for(part)
	var material_id := String(part.material_id)
	var key := "weathered_timber:%s:%0.3f" % [material_id, variation]
	if material_cache.has(key):
		return material_cache[key] as Material
	var material := ConstructionMaterialCatalogScript.create_material(material_id, variation)
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		var definition := ConstructionMaterialCatalogScript.definition_for(material_id)
		var base: Color = definition.get("base", Color.WHITE) as Color
		var accent: Color = definition.get("accent", Color.WHITE) as Color
		shader_material.set_shader_parameter("base_color", base.darkened(0.11))
		shader_material.set_shader_parameter("accent_color", accent.darkened(0.08))
		shader_material.set_shader_parameter("age_strength", minf(1.0, float(definition.get("age", 0.66)) + 0.17))
		shader_material.set_shader_parameter("damp_strength", minf(1.0, float(definition.get("damp", 0.22)) + 0.25))
	material_cache[key] = material
	return material


func material_for(part) -> Material:
	return material_for_id(String(part.material_id), variation_for(part))


func material_for_id(material_id: String, variation := 0.0) -> Material:
	var key := "%s:%0.3f" % [material_id, variation]
	if material_cache.has(key):
		return material_cache[key] as Material
	var material: Material = ConstructionMaterialCatalogScript.create_material(material_id, variation)
	material_cache[key] = material
	return material


func masonry_repair_material_for(part, host_material_id: String) -> Material:
	var host_variation := masonry_family_variation(part)
	var key := "masonry_repair:%s:%0.3f" % [host_material_id, host_variation]
	if material_cache.has(key):
		return material_cache[key] as Material
	var repair_material := ConstructionMaterialCatalogScript.create_material("repair_stone", host_variation + 0.035) as ShaderMaterial
	var host_definition := ConstructionMaterialCatalogScript.definition_for(host_material_id)
	var tint := clampf(host_variation, -0.12, 0.12)
	var host_base: Color = host_definition.get("base", Color.WHITE) as Color
	var host_accent: Color = host_definition.get("accent", Color.WHITE) as Color
	repair_material.set_shader_parameter("repair_strength", 1.0)
	repair_material.set_shader_parameter("repair_phase", float(posmod((source_blueprint_id + ":repair:" + String(part.id)).hash(), 4093)) / 4093.0)
	repair_material.set_shader_parameter("repair_host_base", host_base.lightened(maxf(0.0, tint)).darkened(maxf(0.0, -tint)))
	repair_material.set_shader_parameter("repair_host_accent", host_accent.lightened(maxf(0.0, tint * 0.7)).darkened(maxf(0.0, -tint * 0.7)))
	material_cache[key] = repair_material
	return repair_material


func summary() -> Dictionary:
	var result: Dictionary = {
		"publishedPartCount": published_part_count,
		"publishedNodeCount": published_nodes.size(),
		"collisionPartCount": collision_count,
		"visualBatchCount": visual_batch_count,
		"batchedStaticParts": batch_static_parts,
		"staticRecordCount": static_part_records.size(),
		"masonryRepairClusterCount": masonry_repair_clusters.size(),
		"masonryRepairClusters": masonry_repair_clusters.duplicate(true),
		"surfaceHistory": surface_history.summary(),
		"physicalIntegrity": physical_integrity.duplicate(true),
		"physicalIntegrityRequiredForPublication": PHYSICAL_INTEGRITY_REQUIRED_FOR_PUBLICATION,
		"raisedRouteCoverage": raised_route_coverage.duplicate(true),
		"raisedRouteCoverageRequiredForPublication": false,
		"recipeBuildUsec": recipe_build_usec,
		"diagnosticPreparationUsec": diagnostic_preparation_usec,
		"scenePreparationUsec": scene_preparation_usec,
		"publicationUsec": publication_usec
	}
	if _paving_blueprint != null or not _paving_failure.is_empty():
		result["pavingFootingPublication"] = {"prepared": _paving_prepared, "ready": _paving_prepared and _paving_failure.is_empty(),
			"complete": _paving_complete and _paving_failure.is_empty(), "reason": _paving_failure, "finishCount": _paving_artifacts.size()}
	if _masonry_preparation != null:
		result["masonryAperturePublication"] = {"state": _masonry_preparation.state, "reason": _masonry_preparation.reason, "metrics": _masonry_preparation.metrics.duplicate()}
	return result
