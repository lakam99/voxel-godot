extends RefCounted
## Exact roof course/partition/custom/cap order, with one owned pending part.
## Cancel invalidates only: retain arrays and Resources for worker retirement.
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Descriptor = preload("res://scripts/buildings/MasonryDescriptorGeometry.gd")
const Upload = preload("res://scripts/buildings/BuildingMeshBatchUpload.gd")
var state := "setup"
var reason := ""
var defer_practical_light := false
var _part
var _copy
var _binding := ""
var _source_id: String
var _parent: WeakRef
var _frame: Transform3D
var _collecting: bool
var _compatibility: bool
var _history
var _history_owner
var _history_certificate
var _advancing := false
var _cancelled := false
var _max_slice_usec := 0
var _max_atomic_usec := 0
var _transforms: Array[Transform3D] = []
var _weathered_transforms: Array[Transform3D] = []
var _active: Array[Transform3D] = []
var _custom: Array[Color] = []
var _custom_groups: Array = []
var _upload
var _uploads: Array = []
var _material: Material
var _cap_material: Material
var _label := ""
var _size: Vector3
var _course_count := 0
var _tile_count := 0
var _tile_span := 0.0
var _roof_phase := 0.0
var _eave_x := 0.0
var _ridge_x := 0.0
var _course := 0
var _tile := 0
var _course_t := 0.0
var _course_width := 0.0
var _row_offset := 0.0
var _group := 0
var _index := 0
var _min_y := INF
var _max_y := -INF
var _height_range := 0.0
var _seed_phase := 0.0

func _init(part, parent: Node3D, frame: Transform3D, collecting: bool, source_id: String, compatibility := false) -> void:
	_part=part; _parent=weakref(parent) if parent!=null else null
	_frame=frame; _collecting=collecting; _source_id=source_id; _compatibility=compatibility
	if part==null or not _acyclic(part.recipe,[]):
		_fail("invalid_roof_source"); return
	var snapshot: Dictionary = part.snapshot()
	_binding=Preparation.static_record_binding(snapshot)
	_copy=Part.new(snapshot)
	# Constructor authoring normalization must not change preserved source facts.
	_copy.id=snapshot.id; _copy.kind=snapshot.kind; _copy.material_id=snapshot.material
	_copy.position=snapshot.position; _copy.rotation=snapshot.rotation; _copy.size=snapshot.size
	_copy.collision_enabled=snapshot.collision; _copy.semantic=snapshot.semantic
	_copy.physical_intent=snapshot.physicalIntent
	_size=_copy.size

static func _acyclic(value: Variant, ancestors: Array, depth := 0) -> bool:
	if not (value is Array or value is Dictionary): return true
	if depth>=128: return false
	for ancestor in ancestors:
		if is_same(ancestor,value): return false
	ancestors.append(value)
	if value is Dictionary:
		for key in value:
			if not _acyclic(key,ancestors,depth+1) or not _acyclic(value[key],ancestors,depth+1):
				ancestors.pop_back(); return false
	else:
		for item in value:
			if not _acyclic(item,ancestors,depth+1):
				ancestors.pop_back(); return false
	ancestors.pop_back()
	return true

func source_part(): return _part

func source_valid(publisher) -> bool:
	return _part!=null and publisher.source_blueprint_id==_source_id and not _binding.is_empty() \
		and _acyclic(_part.recipe,[]) and Preparation.static_record_binding(_part.snapshot())==_binding

func cancel() -> void:
	_cancelled=true
	_fail("cancelled")

func _fail(value: String) -> bool:
	if reason.is_empty(): reason=value
	state="failed"
	return false

func _after_external(publisher) -> bool:
	if _cancelled or state=="failed": return false
	if publisher._publication_failed(): return _fail("roof_publisher_failed")
	return true

func _validate(publisher, parent: Node3D) -> bool:
	if not _after_external(publisher): return false
	if not is_instance_valid(parent) or parent.is_queued_for_deletion(): return _fail("roof_parent_lost")
	if not source_valid(publisher): return _fail("stale_roof_part")
	if _history!=null:
		if publisher.surface_history!=_history_owner or publisher._prepared_history!=_history_certificate:
			return _fail("stale_roof_history")
		var valid: bool=publisher.validate_paving_history_source()
		if not _after_external(publisher): return false
		if not valid: return _fail("stale_roof_history")
	return true

func advance(publisher, budget_usec: int = 2500) -> Dictionary:
	if budget_usec<1 or budget_usec>4000: return {"status":"failed","reason":"invalid_slice_budget"}
	if _advancing: return {"status":"failed","reason":"reentrant_advance"}
	if state in ["ready","failed"]: return _status()
	_advancing=true
	var started:=Time.get_ticks_usec()
	var parent: Node3D=_parent.get_ref() as Node3D if _parent!=null else null
	var saved_collecting: bool=publisher.static_visual_collecting
	var saved_frame: Transform3D=publisher.static_visual_part_transform
	if _validate(publisher,parent):
		publisher.static_visual_collecting=_collecting
		publisher.static_visual_part_transform=_frame
		var units:=0
		while state not in ["ready","failed"] and (units==0 or Time.get_ticks_usec()-started<budget_usec):
			var unit_started:=Time.get_ticks_usec()
			var phase:=state
			_step(publisher,parent)
			_after_external(publisher)
			var elapsed:=Time.get_ticks_usec()-unit_started
			_max_atomic_usec=maxi(_max_atomic_usec,elapsed)
			publisher._record_publication_stage("roof_publish_"+phase,elapsed)
			units+=1
	publisher.static_visual_collecting=saved_collecting
	publisher.static_visual_part_transform=saved_frame
	_max_slice_usec=maxi(_max_slice_usec,Time.get_ticks_usec()-started)
	_advancing=false
	return _status()

func _status() -> Dictionary:
	return {"status":state if state in ["ready","failed"] else "pending_budget","reason":reason,
		"phase":state,"maxAtomicUsec":_max_atomic_usec,"maxSliceUsec":_max_slice_usec}

func _step(publisher, parent: Node3D) -> void:
	match state:
		"setup":
			_history_owner=publisher.surface_history
			_history_certificate=publisher._prepared_history
			# Compatibility keeps virtual/custom history dispatch; runtime borrows
			# the existing private immutable history snapshot (no new copier).
			_history=_history_owner if _compatibility else publisher.prepare_paving_history_snapshot()
			if not _after_external(publisher): return
			var monumental:=String(_copy.id).begins_with("castle_") or String(_copy.semantic).contains("civic")
			var course_run:=0.46 if monumental else 0.54
			_tile_span=0.56 if monumental else 0.68
			_course_count=maxi(1,ceili(_size.x/course_run)); _tile_count=maxi(1,ceili(_size.z/_tile_span))
			_roof_phase=float(posmod((_source_id+":roof:"+String(_copy.id)).hash(),4093))/4093.0
			var left:=String(_copy.id).ends_with("_left") or String(_copy.id).contains("roof_left")
			var sign: float=-1.0 if left else 1.0
			_eave_x=sign*_size.x*0.5; _ridge_x=-_eave_x
			state="course"
		"course":
			if _course==_course_count: state="group"; return
			_course_t=(float(_course)+0.5)/float(_course_count)
			_course_width=_size.x/float(_course_count)
			_row_offset=_tile_span*0.5 if _course%2==1 else 0.0
			_row_offset+=(fposmod(sin(float(_course+1)*19.193+_roof_phase*71.713)*15731.743,1.0)-0.5)*_tile_span*0.18
			_tile=0; state="tiles"
		"tiles":
			if _tile==_tile_count+2: _course+=1; state="course"; return
			var slot_width:=_size.z/float(_tile_count)
			var z: float=-_size.z*0.5+slot_width*(float(_tile)+0.5)-_row_offset
			var tile_start:=maxf(-_size.z*0.5,z-slot_width*0.5)
			var tile_end:=minf(_size.z*0.5,z+slot_width*0.5)
			if tile_end-tile_start<0.08: _tile+=1; return
			z=(tile_start+tile_end)*0.5
			var piece_noise:=fposmod(sin(float(_course+1)*41.17+float(_tile+1)*13.71+_roof_phase*29.17)*31991.37,1.0)
			var secondary_noise:=fposmod(sin(float(_course+1)*11.73+float(_tile+1)*57.19+_roof_phase*83.11)*23171.31,1.0)
			var x:=lerpf(_eave_x,_ridge_x,_course_t)
			var tile_size:=Vector3(maxf(0.08,_course_width*lerpf(1.04,1.18,piece_noise)),_size.y*lerpf(0.92,1.16,secondary_noise),maxf(0.08,(tile_end-tile_start-0.026)*lerpf(0.84,1.0,piece_noise)))
			var tile_lift: float=(1.0-_course_t)*_size.y*0.52+(piece_noise-0.5)*0.018
			var transform:=Transform3D(Basis(Vector3.FORWARD,(secondary_noise-0.5)*deg_to_rad(1.7)).scaled(tile_size),Vector3(x,tile_lift,z))
			var exposure: float=_history.history_for(_part if _compatibility else _copy,_copy.position+transform.origin,_course_t,piece_noise)
			if not _after_external(publisher): return
			if exposure>0.58 and piece_noise>0.78: _weathered_transforms.append(transform)
			else: _transforms.append(transform)
			_tile+=1
		"group":
			if _group==2 or (_group==1 and _weathered_transforms.is_empty()): state="cap_material"; return
			_active=_transforms if _group==0 else _weathered_transforms
			_label="RoofCourses" if _group==0 else "RoofReplacementCourses"
			if _group==0: _material=publisher.material_for(_part)
			else:
				var variation: float=publisher.variation_for(_part)
				if not _after_external(publisher): return
				_material=publisher.material_for_id("roof_slate_weathered",variation-0.025)
			if not _after_external(publisher): return
			_custom=[]; _custom_groups.append(_custom)
			_index=0; _min_y=INF; _max_y=-INF
			state="compat_custom" if _compatibility else "extrema"
		"compat_custom":
			_custom=publisher.build_facade_custom_data(_active,_part)
			_custom_groups.append(_custom)
			if _after_external(publisher): state="batch"
		"extrema":
			if _index<_active.size():
				_min_y=minf(_min_y,_active[_index].origin.y); _max_y=maxf(_max_y,_active[_index].origin.y); _index+=1
			else:
				_height_range=maxf(0.001,_max_y-_min_y)
				_seed_phase=float(posmod(String(_copy.id).hash(),4093))/4093.0
				_index=0; state="custom"
		"custom":
			if _index==_active.size(): state="batch"; return
			var origin:=_active[_index].origin
			var height:=clampf((origin.y-_min_y)/_height_range,0.0,1.0)
			var stable:=fposmod(sin(origin.x*17.13+origin.y*43.77+origin.z*11.91+_seed_phase*97.0)*31757.13,1.0)
			var custom: Color=Descriptor.history_custom_data(_copy.position+origin,_history)
			if not _after_external(publisher): return
			_custom.append(custom); _index+=1
		"batch":
			if not _validate(publisher,parent): return
			_index=0
			if _compatibility:
				publisher.add_box_batch(parent,_active,_material,_label,_custom)
				if _after_external(publisher): _group+=1; state="group"
			elif _active.is_empty(): _group+=1; state="group"
			elif _collecting: state="collect"
			else:
				_upload=Upload.new(publisher.unit_box,_active,_custom,_material,_label,parent,_frame,false)
				_uploads.append(_upload); state="upload"
		"collect":
			publisher.collect_static_visual_transform(_frame*_active[_index],_material,_custom[_index])
			if not _after_external(publisher): return
			_index+=1
			if _index==_active.size(): _group+=1; state="group"
		"upload":
			# Reuse exactly ONE existing upload unit so a reentrant cancellation
			# cannot be followed by another submission inside a nested budget loop.
			var phase: String=_upload.state
			var started:=Time.get_ticks_usec()
			_upload._step(publisher)
			var elapsed:=Time.get_ticks_usec()-started
			_upload.max_atomic_usec=maxi(_upload.max_atomic_usec,elapsed)
			publisher._record_publication_stage("mesh_upload_"+phase,elapsed)
			if not _after_external(publisher): return
			if _upload.state=="failed": _fail("roof_upload:"+String(_upload.reason))
			elif _upload.state=="ready": _group+=1; state="group"
		"cap_material":
			var variation: float=publisher.variation_for(_part)
			if not _after_external(publisher): return
			_cap_material=publisher.material_for_id("roof_slate_cap",variation-0.015)
			if _after_external(publisher): state="eave"
		"eave":
			if not _validate(publisher,parent): return
			publisher.add_box_visual(parent,Vector3(0.18,maxf(0.10,_size.y*0.72),_size.z+0.14),Vector3(_eave_x,_size.y*0.18,0.0),_cap_material,"RoofEaveCourse")
			if _after_external(publisher): state="ridge"
		"ridge":
			if not _validate(publisher,parent): return
			publisher.add_box_visual(parent,Vector3(0.24,maxf(0.11,_size.y*0.82),_size.z+0.18),Vector3(_ridge_x,_size.y*0.44,0.0),_cap_material,"RoofRidgeCap")
			if _after_external(publisher): state="finish"
		"finish":
			if not _validate(publisher,parent): return
			if defer_practical_light:
				publisher.publish_practical_light(_part,parent)
				if not _validate(publisher,parent): return
			if _after_external(publisher): state="ready"
