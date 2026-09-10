extends RefCounted
## Ordinary, unjointed cobble publication. Same descriptors, bed and regular/worn
## groups as the compatibility drain; one unfinished part stays owned throughout.
const Geometry=preload("res://scripts/buildings/SettledCobbleGeometry.gd")
const Upload=preload("res://scripts/buildings/BuildingMeshBatchUpload.gd")
const Part=preload("res://scripts/buildings/BuildingPart.gd")
const PartBinding=preload("res://scripts/buildings/BuildingPartBinding.gd")
var state: String = "geometry_begin"
var reason: String = ""
var _part
var _part_copy
var _part_binding: PackedByteArray
var _source_id: String
var _parent: WeakRef
var _frame: Transform3D
var _collecting: bool
var _cursor
var _geometry: Dictionary = {}
var _upload
var _uploads: Array = []
var _group := 0
var _prepared := false
var _packet
var _segments: Array = []
var _segment_index := 0
var _material: Material

func _init(part, parent: Node3D, frame: Transform3D, collecting: bool, source_id: String) -> void:
	_part=part; _parent=weakref(parent); _frame=frame; _collecting=collecting
	var snapshot: Dictionary = part.snapshot()
	_part_binding=var_to_bytes(snapshot)
	_part_copy=Part.new(snapshot)
	_source_id=source_id

func source_part(): return _part

func source_valid(publisher) -> bool:
	if _prepared:
		return publisher.source_blueprint_id==_source_id and publisher._prepared_surface_part_valid(_part,"paving")
	return publisher.source_blueprint_id==_source_id and PartBinding.encode(_part)==_part_binding

func advance(publisher, budget_usec: int = 2500) -> Dictionary:
	if budget_usec<1 or budget_usec>4000: return {"status":"failed","reason":"invalid_slice_budget"}
	var parent: Node3D = _parent.get_ref() as Node3D
	if not is_instance_valid(parent) or parent.is_queued_for_deletion():
		state="failed"; reason="paving_parent_lost"
	if not source_valid(publisher):
		state="failed"; reason="stale_paving_part"
	if state in ["ready","failed"]: return {"status":state,"reason":reason}
	var started:=Time.get_ticks_usec()
	var stage:=state
	match state:
		"geometry_begin":
			_geometry=publisher.prepared_surface_geometry(_part,"paving")
			if publisher._publication_failed():
				state="failed"; reason="stale_prepared_paving"
			elif not _geometry.is_empty():
				_prepared=true
				if _collecting: _packet=publisher.prepared_surface_packet(_part,"paving")
				if _packet!=null and _packet.frame!=_frame:
					state="failed"; reason="stale_paving_packet_frame"
				else: state="bed"
			else:
				_cursor=Geometry.begin_source(_part_copy,publisher.prepare_paving_history_snapshot(),_source_id)
				state="geometry"
		"geometry":
			var result: Dictionary = _cursor.advance(budget_usec)
			if result.status=="ready":
				_geometry=_cursor.take_result()
				state="bed"
			elif result.status!="pending_budget":
				state="failed"; reason="paving_geometry_"+String(result.get("reason",result.status))
		"bed":
			if not publisher.validate_paving_history_source():
				state="failed"; reason="stale_paving_history"
				return {"status":state,"reason":reason}
			var bed: Dictionary = _geometry.bed
			var saved_collecting: bool = publisher.static_visual_collecting
			var saved_frame: Transform3D = publisher.static_visual_part_transform
			publisher.static_visual_collecting=_collecting
			publisher.static_visual_part_transform=_frame
			var material: Material=publisher.material_for_id(bed.materialId,publisher.variation_for(_part)-0.025)
			if _packet!=null:
				publisher.collect_prepared_static_visual_segment(_packet.groups.bed.segments[0],material)
			else:
				publisher.add_box_visual(parent,bed.size,bed.position,material,"CobbleJointBed")
			publisher.static_visual_collecting=saved_collecting
			publisher.static_visual_part_transform=saved_frame
			state="group"
		"group":
			if _group==2:
				state="ready" if publisher.validate_paving_history_source() else "failed"
				if state=="failed": reason="stale_paving_history"
			else:
				var transforms: Array = _geometry.regularTransforms if _group==0 else _geometry.wornTransforms
				if transforms.is_empty():
					_group+=1
				else:
					var custom: Array = _geometry.regularCustomData if _group==0 else _geometry.wornCustomData
					var material: Material = publisher.material_for(_part) if _group==0 else publisher.material_for_id("worn_cobble",publisher.variation_for(_part)-0.016)
					var label: String = "SettledCobbleStones" if _group==0 else "WornSettledCobbleStones"
					if _packet!=null:
						_material=material
						_segments=(_packet.groups.regular if _group==0 else _packet.groups.worn).segments
						_segment_index=0; state="packet_collect"
					else:
						_upload=Upload.new(publisher.unit_box,transforms,custom,material,label,parent,_frame,_collecting)
						_uploads.append(_upload)
						state="upload"
		"packet_collect":
			if _segment_index>=_segments.size():
				_group+=1; state="group"
			else:
				publisher.collect_prepared_static_visual_segment(_segments[_segment_index],_material)
				_segment_index+=1
		"upload":
			var result: Dictionary = _upload.advance(publisher,budget_usec)
			if result.status=="ready":
				_group+=1
				state="group"
			elif result.status=="failed":
				state="failed"; reason=String(result.reason)
	if publisher._publication_failed():
		state="failed"; reason="paving_publisher_failed"
	publisher._record_publication_stage("paving_publish_"+stage,Time.get_ticks_usec()-started)
	return {"status":state if state in ["ready","failed"] else "pending_budget","reason":reason}
