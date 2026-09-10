extends RefCounted
## Shared CPU-only roof arithmetic. The caller owns source/history stability.
## No Nodes, rendering resources or material creation. Cancellation retains data
## for the owner's normal retirement path.
const Descriptor = preload("res://scripts/buildings/MasonryDescriptorGeometry.gd")
static func begin_source(part, history, source_id: String, defer_custom := false) -> Cursor:
	return Cursor.new(part,history,source_id,defer_custom)

class Cursor extends RefCounted:
	var state := "setup"
	var reason := ""
	var _copy
	var _history_part
	var _history
	var _source_id: String
	var _cancelled := false
	var _advancing := false
	var _taken := false
	var _defer_custom := false
	var _transforms: Array[Transform3D] = []
	var _weathered_transforms: Array[Transform3D] = []
	var _active: Array[Transform3D] = []
	var _custom: Array[Color] = []
	var _custom_groups: Array = []
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

	func _init(part, history, source_id: String, defer_custom := false) -> void:
		_copy=part; _history_part=part; _history=history; _source_id=source_id; _defer_custom=defer_custom
		if part==null or history==null:
			state="failed"; reason="invalid_roof_source"
		else:
			_size=part.size

	func cancel() -> void:
		_cancelled=true
		state="failed"; reason="cancelled"

	func advance(budget_usec: int = 2500) -> Dictionary:
		if budget_usec<1 or budget_usec>4000: return {"status":"failed","reason":"invalid_slice_budget"}
		if _advancing: return {"status":"failed","reason":"reentrant_advance"}
		_advancing=true
		var started := Time.get_ticks_usec()
		var units := 0
		while state not in ["ready","failed"] and (units==0 or Time.get_ticks_usec()-started<budget_usec):
			_step()
			units+=1
		_advancing=false
		return {"status":state if state in ["ready","failed"] else "pending_budget","reason":reason}

	func take_result() -> Dictionary:
		if state!="ready" or _taken: return {}
		_taken=true
		var regular: Array[Color] = []
		var weathered: Array[Color] = []
		if not _custom_groups.is_empty(): regular=_custom_groups[0]
		if _custom_groups.size()>1: weathered=_custom_groups[1]
		return {"regularTransforms":_transforms,"weatheredTransforms":_weathered_transforms,
			"regularCustomData":regular,"weatheredCustomData":weathered,
			"eave":{"position":Vector3(_eave_x,_size.y*0.18,0.0),"size":Vector3(0.18,maxf(0.10,_size.y*0.72),_size.z+0.14)},
			"ridge":{"position":Vector3(_ridge_x,_size.y*0.44,0.0),"size":Vector3(0.24,maxf(0.11,_size.y*0.82),_size.z+0.18)}}

	func _step() -> void:
		if _cancelled or state in ["ready","failed"]: return
		match state:
			"setup":
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
				var exposure: float=_history.history_for(_history_part,_copy.position+transform.origin,_course_t,piece_noise)
				if _cancelled: return
				if exposure>0.58 and piece_noise>0.78: _weathered_transforms.append(transform)
				else: _transforms.append(transform)
				_tile+=1
			"group":
				if _group==2 or (_group==1 and _weathered_transforms.is_empty()) or _defer_custom:
					state="ready"; return
				_active=_transforms if _group==0 else _weathered_transforms
				_custom=[]; _custom_groups.append(_custom)
				_index=0; _min_y=INF; _max_y=-INF
				state="extrema"
			"extrema":
				if _index<_active.size():
					_min_y=minf(_min_y,_active[_index].origin.y); _max_y=maxf(_max_y,_active[_index].origin.y); _index+=1
				else:
					_height_range=maxf(0.001,_max_y-_min_y)
					_seed_phase=float(posmod(String(_copy.id).hash(),4093))/4093.0
					_index=0; state="custom"
			"custom":
				if _index==_active.size(): _group+=1; state="group"; return
				var origin:=_active[_index].origin
				var height:=clampf((origin.y-_min_y)/_height_range,0.0,1.0)
				var stable:=fposmod(sin(origin.x*17.13+origin.y*43.77+origin.z*11.91+_seed_phase*97.0)*31757.13,1.0)
				var custom: Color=Descriptor.history_custom_data(_copy.position+origin,_history)
				if _cancelled: return
				_custom.append(custom); _index+=1
