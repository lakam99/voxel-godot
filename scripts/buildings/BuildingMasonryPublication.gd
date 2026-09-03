extends RefCounted
## Same masonry descriptor/material/batch sequence, with owned pending work.
const Geometry=preload("res://scripts/buildings/MasonryDescriptorGeometry.gd")
const Upload=preload("res://scripts/buildings/BuildingMeshBatchUpload.gd")
const Part=preload("res://scripts/buildings/BuildingPart.gd")
const Preparation=preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
var state := "geometry_begin"
var reason := ""
var defer_practical_light := false
var _part
var _copy
var _binding: String
var _source_id: String
var _parent: WeakRef
var _frame: Transform3D
var _collecting: bool
var _compatibility: bool
var _cursor
var _geometry: Dictionary = {}
var _artifact: Dictionary = {}
var _group := 0
var _entry := 0
var _transforms: Array = []
var _custom: Array = []
var _material: Material
var _label := ""
var _batch_index := 0
var _after_batch := ""
var _upload
var _uploads: Array = []

func _init(part, parent: Node3D, frame: Transform3D, collecting: bool, source_id: String, artifact: Dictionary, compatibility := false) -> void:
	_part=part; _parent=weakref(parent); _frame=frame; _collecting=collecting
	_compatibility=compatibility
	var snapshot: Dictionary = part.snapshot()
	_binding=Preparation.static_record_binding(snapshot)
	_copy=Part.new(snapshot)
	_source_id=source_id; _artifact=artifact

func source_part(): return _part

func source_valid(publisher) -> bool:
	return publisher.source_blueprint_id==_source_id and Preparation.static_record_binding(_part.snapshot())==_binding

func _validate_authority(publisher, parent: Node3D) -> bool:
	var started:=Time.get_ticks_usec()
	if publisher._publication_failed():
		state="failed"; reason="masonry_publisher_failed"
	elif not is_instance_valid(parent) or parent.is_queued_for_deletion():
		state="failed"; reason="masonry_parent_lost"
	else:
		var binding_started:=Time.get_ticks_usec()
		var valid:=source_valid(publisher)
		publisher._record_publication_stage("masonry_part_binding",Time.get_ticks_usec()-binding_started)
		var aperture_started:=Time.get_ticks_usec()
		if valid: valid=publisher._masonry_part_valid(_part)
		publisher._record_publication_stage("masonry_aperture_guard",Time.get_ticks_usec()-aperture_started)
		if not valid: state="failed"; reason="stale_masonry_part"
	publisher._record_publication_stage("masonry_authority_validation",Time.get_ticks_usec()-started)
	return state!="failed"

func advance(publisher, budget_usec: int = 2500) -> Dictionary:
	if budget_usec<1 or budget_usec>4000: return {"status":"failed","reason":"invalid_slice_budget"}
	var started:=Time.get_ticks_usec()
	var parent: Node3D = _parent.get_ref() as Node3D
	_validate_authority(publisher,parent)
	if state in ["ready","failed"]: return {"status":state,"reason":reason}
	var saved_collecting: bool = publisher.static_visual_collecting
	var saved_frame: Transform3D = publisher.static_visual_part_transform
	publisher.static_visual_collecting=_collecting
	publisher.static_visual_part_transform=_frame
	var units:=0
	while state not in ["ready","failed"] and (units==0 or Time.get_ticks_usec()-started<budget_usec):
		var unit_started:=Time.get_ticks_usec()
		var stage:=state
		_step(publisher,parent,maxi(1,budget_usec-int(unit_started-started)))
		# Public hooks can reject reentrantly. Never emit another unit after a
		# failure, even if the hook itself returned normally.
		if publisher._publication_failed():
			state="failed"; reason="masonry_publisher_failed"
		publisher._record_publication_stage("masonry_publish_"+stage,Time.get_ticks_usec()-unit_started)
		units+=1
	publisher.static_visual_collecting=saved_collecting
	publisher.static_visual_part_transform=saved_frame
	return {"status":state if state in ["ready","failed"] else "pending_budget","reason":reason}

func _step(publisher, parent: Node3D, budget_usec: int) -> void:
	match state:
		"geometry_begin":
			if _artifact.is_empty():
				_geometry=publisher.prepared_masonry_geometry(_part)
				if publisher._publication_failed():
					state="failed"; reason="stale_prepared_masonry"; return
				if not _geometry.is_empty(): state="bed"
				else:
					_cursor=Geometry.begin_source(_copy,publisher.prepare_paving_history_snapshot(),_source_id)
					state="geometry"
			else:
				_geometry=_artifact.geometry
				state="bed"
		"geometry":
			var result: Dictionary = _cursor.advance(budget_usec)
			if result.status=="ready":
				_geometry=_cursor.take_result(); state="bed"
			elif result.status!="pending_budget":
				state="failed"; reason="masonry_geometry_"+String(result.get("reason",result.status))
		"bed":
			if not publisher.validate_paving_history_source():
				state="failed"; reason="stale_masonry_history"; return
			publisher.add_box_visual(parent,_geometry.mortarSize,Vector3.ZERO,publisher.material_for_id("mortar",publisher.variation_for(_part)-0.035),"MasonryBed")
			state="top"
		"top":
			var top:=String(_part.recipe.get("topSurfaceMaterial",""))
			var size: Vector3 = _part.size
			if String(_part.kind)=="foundation" and not top.is_empty():
				publisher.add_box_visual(parent,Vector3(maxf(0.08,size.x-0.05),0.028,maxf(0.08,size.z-0.05)),Vector3(0.0,size.y*0.5+0.014,0.0),publisher.material_for_id(top,publisher.variation_for(_part)-0.025),"FoundationTopSurface")
			var profile: Dictionary = _geometry.repairProfile
			if not profile.is_empty():
				publisher.masonry_repair_clusters.append({"partId":String(_part.id),"face":int(profile.get("face",-1)),"centerY":float(profile.get("centerY",0.5)),"centerAlong":float(profile.get("centerAlong",0.5)),"radiusY":float(profile.get("radiusY",0.0)),"radiusAlong":float(profile.get("radiusAlong",0.0))})
			state="group"
		"group":
			if _group==2 or (_group==1 and _geometry.repairTransforms.is_empty()):
				state="finish"; return
			_material=publisher.material_for_id(_geometry.surfaceMaterialId,publisher.masonry_family_variation(_part)) if _group==0 else publisher.masonry_repair_material_for(_part,_geometry.surfaceMaterialId)
			_label="BrickCourses" if _group==0 else "MasonryRepairCourses"
			if _artifact.is_empty():
				_transforms=_geometry.regularTransforms if _group==0 else _geometry.repairTransforms
				_custom=_geometry.regularCustomData if _group==0 else _geometry.repairCustomData
				_start_box_batch("next_group")
			else:
				_entry=0; _transforms=[]; _custom=[]; state="entries"
		"entries":
			if _entry>=_artifact.entries.size():
				_start_box_batch("next_group"); return
			var entry: Dictionary = _artifact.entries[_entry]
			if entry.original.group!=("regular" if _group==0 else "repair"):
				_entry+=1; return
			if entry.unchanged:
				_transforms.append(entry.original.localTransform); _custom.append(entry.original.customData)
				_entry+=1; return
			if not _transforms.is_empty():
				_start_box_batch("entries"); return
			var prepared: Dictionary = _artifact.preparedMeshes[entry.original.id]
			_entry+=1
			if prepared.mesh!=null:
				if _compatibility:
					publisher.add_mesh_batch(parent,prepared.mesh,[entry.original.localTransform],_material,_label,[entry.original.customData])
					return
				_upload=Upload.new(prepared.mesh,[entry.original.localTransform],[entry.original.customData],_material,_label,parent,_frame,_collecting)
				_uploads.append(_upload); _after_batch="entries"; state="upload"
		"box_begin":
			if _transforms.is_empty(): state=_after_batch
			elif _compatibility:
				# Existing diagnostic collectors override this public hook. The
				# compatibility drain keeps that dispatch; runtime uses cheap units.
				publisher.add_box_batch(parent,_transforms,_material,_label,_custom)
				_end_batch()
			elif _collecting: state="collect"
			else:
				_upload=Upload.new(publisher.unit_box,_transforms,_custom,_material,_label,parent,_frame,false)
				_uploads.append(_upload); state="upload"
		"collect":
			publisher.collect_static_visual_transform(_frame*_transforms[_batch_index],_material,_custom[_batch_index])
			_batch_index+=1
			if _batch_index==_transforms.size(): _end_batch()
		"upload":
			var result: Dictionary = _upload.advance(publisher,budget_usec)
			if result.status=="ready": _end_batch()
			elif result.status=="failed": state="failed"; reason=String(result.reason)
		"next_group":
			_group+=1; state="group"
		"finish":
			if not _validate_authority(publisher,parent): return
			if not publisher.validate_paving_history_source():
				state="failed"; reason="stale_masonry_history"; return
			if defer_practical_light:
				publisher.publish_practical_light(_part,parent)
				if not _validate_authority(publisher,parent): return
			state="ready"

func _start_box_batch(next_state: String) -> void:
	_after_batch=next_state; _batch_index=0; state="box_begin"

func _end_batch() -> void:
	# Do not clear arrays borrowed from immutable geometry or completed uploads.
	_transforms=[]; _custom=[]; _upload=null; state=_after_batch
