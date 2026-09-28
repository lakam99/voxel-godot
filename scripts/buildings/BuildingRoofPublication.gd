extends RefCounted
## Exact roof course/partition/custom/cap order, with one owned pending part.
## Cancel invalidates only: retain arrays and Resources for worker retirement.
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Geometry = preload("res://scripts/buildings/BuildingRoofGeometry.gd")
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
var _geometry: Dictionary = {}
var _cursor
var _packet
var _packet_segments: Array = []
var _packet_index := 0
var _prepared := false
var _group := 0
var _index := 0

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
	if _prepared:
		return publisher.source_blueprint_id==_source_id and publisher._prepared_surface_part_valid(_part,"roof")
	return _part!=null and publisher.source_blueprint_id==_source_id and not _binding.is_empty() \
		and _acyclic(_part.recipe,[]) and Preparation.static_record_binding(_part.snapshot())==_binding

func cancel() -> void:
	_cancelled=true
	if _cursor!=null: _cursor.cancel()
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
			if not _compatibility:
				if not publisher._prepared_surface_part_valid(_part,"roof"):
					_fail("stale_prepared_roof"); return
				_geometry=publisher.prepared_surface_geometry(_part,"roof")
				if not _after_external(publisher): return
				if not _geometry.is_empty():
					_prepared=true
					if _collecting:
						_packet=publisher.prepared_surface_packet(_part,"roof")
						if not _after_external(publisher): return
						if _packet!=null and _packet.frame!=_frame:
							_fail("stale_roof_packet_frame"); return
			if not _geometry.is_empty():
				_accept_geometry()
			else:
				# Compatibility passes the original record to virtual history and
				# defers custom hooks until after each material request.
				_cursor=Geometry.begin_source(_copy,_history,_source_id,_compatibility)
				if _compatibility: _cursor._history_part=_part
				state="geometry"
		"geometry":
			# One shared arithmetic unit preserves immediate external cancellation.
			_cursor._step()
			if not _after_external(publisher): return
			if _cursor.state=="failed": _fail(_cursor.reason); return
			if _cursor.state=="ready":
				_geometry=_cursor.take_result()
				_accept_geometry()
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
			_index=0
			if _compatibility:
				state="compat_custom"
			else:
				_custom=_geometry.regularCustomData if _group==0 else _geometry.weatheredCustomData
				state="batch"
		"compat_custom":
			_custom=publisher.build_facade_custom_data(_active,_part)
			_custom_groups.append(_custom)
			if _after_external(publisher): state="batch"
		"batch":
			if not _validate(publisher,parent): return
			_index=0
			if _compatibility:
				publisher.add_box_batch(parent,_active,_material,_label,_custom)
				if _after_external(publisher): _group+=1; state="group"
			elif _active.is_empty(): _group+=1; state="group"
			elif _collecting:
				if _packet!=null:
					_packet_segments=(_packet.groups.regular if _group==0 else _packet.groups.weathered).segments
					_packet_index=0; state="packet_collect"
				else: state="collect"
			else:
				_upload=Upload.new(publisher.unit_box,_active,_custom,_material,_label,parent,_frame,false)
				_uploads.append(_upload); state="upload"
		"collect":
			publisher.collect_static_visual_transform(_frame*_active[_index],_material,_custom[_index])
			if not _after_external(publisher): return
			_index+=1
			if _index==_active.size(): _group+=1; state="group"
		"packet_collect":
			if _packet_index>=_packet_segments.size(): _group+=1; state="group"; return
			publisher.collect_prepared_static_visual_segment(_packet_segments[_packet_index],_material)
			if not _after_external(publisher): return
			_packet_index+=1
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
			if _packet!=null:
				publisher.collect_prepared_static_visual_segment(_packet.groups.eave.segments[0],_cap_material)
			else:
				publisher.add_box_visual(parent,_geometry.eave.size,_geometry.eave.position,_cap_material,"RoofEaveCourse")
			if _after_external(publisher): state="ridge"
		"ridge":
			if not _validate(publisher,parent): return
			if _packet!=null:
				publisher.collect_prepared_static_visual_segment(_packet.groups.ridge.segments[0],_cap_material)
			else:
				publisher.add_box_visual(parent,_geometry.ridge.size,_geometry.ridge.position,_cap_material,"RoofRidgeCap")
			if _after_external(publisher): state="finish"
		"finish":
			if not _validate(publisher,parent): return
			if defer_practical_light:
				publisher.publish_practical_light(_part,parent)
				if not _validate(publisher,parent): return
			if _after_external(publisher): state="ready"


func _accept_geometry() -> void:
	_transforms=_geometry.regularTransforms
	_weathered_transforms=_geometry.weatheredTransforms
	state="group"
