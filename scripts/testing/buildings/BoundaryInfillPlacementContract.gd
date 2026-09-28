extends SceneTree
## Synthetic pure placement + actual BuildingPart record contract; not gameplay.
const Placement = preload("res://scripts/buildings/BoundaryInfillPlacement.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
var checks := {}
var observations := {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("BOUNDARY_INFILL_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path): quit(2); return
	var moving := AABB(Vector3(-1,0,-1),Vector3(2,2,2))
	var domain := Rect2(-10,-10,20,20)
	var center_obstacle := AABB(Vector3(-1,0,-1),Vector3(2,2,2))
	var clear := _probe("unchanged",moving,domain,[],0,true)
	_check("unchanged:exact",clear.get("translation")==Vector3.ZERO and var_to_bytes(clear.get("placedBounds"))==var_to_bytes(moving))
	var tied := _probe("tie_lower",moving,domain,[center_obstacle],0,true)
	_check("tie:lower_z",tied.get("translation")==Vector3(0,0,-2))
	var inset := _probe("named_clearance",moving,domain,[center_obstacle],0.25,true)
	_check("clearance:lower_z",inset.get("translation")==Vector3(0,0,-2.25))
	var touching := AABB(Vector3(-1,0,1),Vector3(2,2,2))
	_check("touch:unchanged",_probe("touch",moving,domain,[touching],0,true).get("translation")==Vector3.ZERO)
	var above := AABB(Vector3(-3,2,-3),Vector3(6,2,6))
	_check("y_touch:not_expanded",_probe("y_touch",moving,domain,[above],0.5,true).get("translation")==Vector3.ZERO)
	var beside := AABB(Vector3(1,0,-8),Vector3(2,2,16))
	_check("x_touch:unchanged",_probe("x_touch",moving,domain,[beside],0,true).get("translation")==Vector3.ZERO)
	var low_x := AABB(Vector3(-12,0,-1),moving.size)
	_check("x_clamp:nearest",_probe("x_clamp",low_x,domain,[],0,true).get("translation")==Vector3(2,0,0))
	var high_x := AABB(Vector3(9,0,-1),moving.size)
	_check("x_clamp:high_nearest",_probe("x_clamp_high",high_x,domain,[],0,true).get("translation")==Vector3(-1,0,0))
	_probe("fixed_x_no_global_escape",moving,domain,[AABB(Vector3(-1,-1,-10),Vector3(2,4,20))],0,false)
	_probe("no_domain_fit",moving,Rect2(0,0,1,1),[],0,false)
	var gap_obstacles: Array = [AABB(Vector3(-2,0,-10),Vector3(4,2,9)),AABB(Vector3(-2,0,1),Vector3(4,2,9))]
	_check("exact_sized_gap:retained",_probe("exact_sized_gap",moving,domain,gap_obstacles,0,true).get("translation")==Vector3.ZERO)
	var obstacles: Array = [center_obstacle,AABB(Vector3(-1,0,-3),Vector3(2,2,2)),center_obstacle,AABB(Vector3(-1,0,0),Vector3(2,2,2))]
	var forward := _probe("union",moving,domain,obstacles,0,true)
	var reverse := obstacles.duplicate()
	reverse.reverse()
	_check("reversed:complete_exact",var_to_bytes(forward)==var_to_bytes(_probe("reversed",moving,domain,reverse,0,true)))
	_check("repeat:complete_exact",var_to_bytes(forward)==var_to_bytes(_probe("repeat",moving,domain,obstacles,0,true)))
	for offset: Vector3 in [Vector3(32,8,-16),Vector3(-32,-8,16)]:
		var translated_obstacles: Array = obstacles.map(func(box):return AABB(box.position+offset,box.size))
		var shifted := _probe("translated_"+str(offset),AABB(moving.position+offset,moving.size),Rect2(domain.position+Vector2(offset.x,offset.z),domain.size),translated_obstacles,0,true)
		_check("translation_equivariance_"+str(offset),shifted.get("translation")==forward.get("translation"))
	var asymmetric: Array = [AABB(Vector3(-1,0,-2),Vector3(2,2,4))]
	var a := _probe("asymmetric",AABB(Vector3(-1,0,0),moving.size),domain,asymmetric,0,true)
	var b := _probe("mirror_z",AABB(Vector3(-1,0,-2),moving.size),domain,asymmetric,0,true)
	_check("mirror:opposite_nearest_translation",a.get("translation")==-b.get("translation"))
	_malformed(moving,domain)
	var many: Array = []
	for index in range(10000): many.append(center_obstacle)
	var large := _probe("limit_10000",moving,domain,many,0,true)
	_check("limit:merged_work",large.get("testedCandidates",100000)<=6)
	many.append(center_obstacle)
	_probe("over_limit",moving,domain,many,0,false)
	_cancellation(moving,domain,obstacles)
	_actual_record()
	_represented_endpoints()
	_columns()
	_column_pruning()
	var passed: bool = not checks.values().has(false)
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify({"passed":passed,"checkCount":checks.size(),"checks":checks,"observations":observations,
		"evidenceLevel":"synthetic_pure_placement_actual_record_not_gameplay","sourceSha256":FileAccess.get_sha256("res://scripts/buildings/BoundaryInfillPlacement.gd")},"\t"))
	file.close()
	print("Boundary infill: ",checks.size()," checks passed=",passed)
	quit(0 if passed else 1)

func _probe(label: String,moving: AABB,domain: Rect2,obstacles: Array,clearance: float,expected: bool) -> Dictionary:
	var before := var_to_bytes([moving,domain,obstacles,clearance])
	var result := Placement.fit(moving,domain,obstacles,clearance)
	_check(label+":immutable",before==var_to_bytes([moving,domain,obstacles,clearance]))
	_check(label+":status",result.get("ready")==expected)
	_check(label+":bounded_candidates",result.get("testedCandidates") is int and result.testedCandidates>=0 and result.testedCandidates<=20004)
	if result.get("ready")==true:
		_check(label+":independent_geometry",_valid_result(moving,domain,obstacles,clearance,result))
	else:
		_check(label+":no_partial",not result.has("translation") and not result.has("placedBounds") and not String(result.get("reason","")).is_empty())
	observations[label]=result
	return result

func _valid_result(original: AABB,domain: Rect2,obstacles: Array,clearance: float,result: Dictionary) -> bool:
	if not result.get("translation") is Vector3 or not result.get("placedBounds") is AABB: return false
	var placed: AABB = result.placedBounds
	if result.translation.y!=0.0 or placed.position.y!=original.position.y or placed.size!=original.size or placed.position!=original.position+result.translation: return false
	for pair: Array in [[0,0],[2,1]]:
		var axis: int = pair[0]
		var d: int = pair[1]
		if placed.position[axis]<domain.position[d] or float(placed.position[axis])+float(placed.size[axis])>float(domain.position[d])+float(domain.size[d]) or placed.end[axis]>domain.end[d]: return false
	for obstacle: AABB in obstacles:
		var overlap := true
		for axis in range(3):
			var expansion := 0.0 if axis==1 else clearance
			var high_a := maxf(float(placed.end[axis]),float(placed.position[axis])+float(placed.size[axis]))
			var high_b := maxf(float(obstacle.end[axis]),float(obstacle.position[axis])+float(obstacle.size[axis]))+expansion
			overlap=overlap and minf(high_a,high_b)>maxf(float(placed.position[axis]),float(obstacle.position[axis])-expansion)
		if overlap: return false
	return true

func _malformed(moving: AABB,domain: Rect2) -> void:
	_probe("invalid_obstacle_type",moving,domain,[7],0,false)
	for value in [-1.0,NAN,INF,10001.0]: _probe("invalid_clearance_"+str(value),moving,domain,[],value,false)
	for axis in range(3):
		for value in [0.0,-1.0,NAN,INF,10001.0]:
			var bad := moving
			bad.size[axis]=value
			_probe("invalid_size_%d_%s" % [axis,str(value)],bad,domain,[],0,false)
			_probe("invalid_obstacle_size_%d_%s" % [axis,str(value)],moving,domain,[bad],0,false)
		for value in [NAN,INF,10001.0]:
			var bad := moving
			bad.position[axis]=value
			_probe("invalid_position_%d_%s" % [axis,str(value)],bad,domain,[],0,false)
	for axis in range(2):
		for value in [0.0,-1.0,NAN,INF,10001.0]:
			var bad := domain
			bad.size[axis]=value
			_probe("invalid_domain_%d_%s" % [axis,str(value)],moving,bad,[],0,false)
	# Validation cannot skip malformed later obstacles after apparent success.
	_probe("late_invalid_obstacle",moving,domain,[AABB(Vector3(8,0,8),Vector3.ONE),AABB()],0,false)

func _cancellation(moving: AABB,domain: Rect2,obstacles: Array) -> void:
	for stop_at in [1,3,8,15]:
		var calls := [0]
		var continuation := func()->bool:
			calls[0]+=1
			return calls[0]<stop_at
		var result := Placement.fit(moving,domain,obstacles,0,continuation)
		_check("cancel_%d:terminal" % stop_at,result.get("ready")==false and result.get("reason")=="cancelled" and calls[0]==stop_at and not result.has("placedBounds"))
	var default_result := Placement.fit(moving,domain,obstacles,0)
	_check("continuation_true:exact",var_to_bytes(default_result)==var_to_bytes(Placement.fit(moving,domain,obstacles,0,func()->bool:return true)))
	_check("continuation_empty:exact",var_to_bytes(default_result)==var_to_bytes(Placement.fit(moving,domain,obstacles,0,Callable())))

func _actual_record() -> void:
	# Historical represented foundation dimensions from candidate-threshold-05;
	# new placement domain/obstacle are explicitly synthetic, not a source replay.
	var part = Part.new({"id":"historical_foundation_record","kind":"foundation","position":Vector3(3.333567,2.421393,-10.22929),"size":Vector3(8.423232,4.842786,11.107),"collision":true})
	var before := var_to_bytes(part.snapshot())
	var moving := AABB(part.position-part.size*0.5,part.size)
	_probe("actual_part_record",moving,Rect2(-20,-30,40,60),[],0,true)
	_check("actual_part:source_unmodified",before==var_to_bytes(part.snapshot()))

func _represented_endpoints() -> void:
	var moving := AABB(Vector3(0,0,0.35),Vector3(0.1,1,0.1))
	var obstacle := AABB(Vector3(0,0,0.4),Vector3(0.1,1,0.2))
	var domain := Rect2(0,0,1,1)
	var nearest := Vector3(0,0,0.2999999821186065673828125)
	var witness := {"translation":nearest-moving.position,"placedBounds":AABB(nearest,moving.size)}
	_check("rounding:independent_nearer_witness_clear",_valid_result(moving,domain,[obstacle],0,witness))
	var penetrating := Vector3(0,0,0.30000001192092896)
	_check("rounding:next_higher_witness_penetrates",not _valid_result(moving,domain,[obstacle],0,{"translation":penetrating-moving.position,"placedBounds":AABB(penetrating,moving.size)}))
	var result := _probe("rounding_lower_endpoint",moving,domain,[obstacle],0,true)
	_check("rounding:nearest_lower_not_distant_upper",result.get("ready")==true and result.placedBounds.position.z==nearest.z)
	var reversed := _probe("rounding_duplicate_obstacles",moving,domain,[obstacle,obstacle],0,true)
	_check("rounding:duplicate_exact",var_to_bytes(result)==var_to_bytes(reversed))
	var mirrored := AABB(Vector3(0,0,-0.45),moving.size)
	var mirrored_obstacle := AABB(Vector3(0,0,-0.6),obstacle.size)
	var upper := _probe("rounding_upper_endpoint",mirrored,Rect2(0,-1,1,1),[mirrored_obstacle],0,true)
	_check("rounding:upper_stays_nearest_side",upper.get("ready")==true and upper.translation.z>0.0 and upper.translation.z<0.1)
	for axis in [0,2]:
		var outside := moving
		outside.position[axis]=1.1
		var clamped := _probe("rounding_domain_upper_%d" % axis,outside,domain,[],0,true)
		_check("rounding:domain_upper_nearest_%d" % axis,clamped.get("ready")==true and clamped.placedBounds.position[axis]==Vector3(0.8999999761581421,0.8999999761581421,0.8999999761581421)[axis])
		var far := AABB(Vector3(0.2,0,0.2),Vector3(0.1,1,0.1))
		far.position[axis]=-1000.0
		_probe("rounding_domain_lower_%d" % axis,far,Rect2(0.1,0.1,1,1),[],0,true)

func _column_probe(label: String,moving: AABB,domain: Rect2,obstacles: Array,clearance: float,expected: bool) -> Dictionary:
	var before := var_to_bytes([moving,domain,obstacles,clearance])
	var result := Placement.fit_columns(moving,domain,obstacles,clearance)
	_check(label+":immutable",before==var_to_bytes([moving,domain,obstacles,clearance]))
	_check(label+":status",result.get("ready")==expected)
	if result.get("ready")==true:
		_check(label+":independent_geometry",_valid_result(moving,domain,obstacles,clearance,result))
		_check(label+":bounded_inventory",result.columnEndpoints<=Placement.MAX_COLUMN_ENDPOINTS and result.testedColumns<=result.columnEndpoints)
		_check(label+":bounded_work",result.workUpperBound<=Placement.MAX_COLUMN_WORK)
	else:
		_check(label+":no_partial",not result.has("translation") and not result.has("placedBounds") and not String(result.get("reason","")).is_empty())
	observations[label]=result
	return result

func _columns() -> void:
	# Synthetic corridor with actual reported widths/endpoints. The deliberately
	# rejected 64-point grid is an independent negative control, not production.
	var moving := AABB(Vector3(20,0,5),Vector3(12.604,2,13.2))
	var domain := Rect2(0,0,50.89,30)
	var obstacles: Array = [AABB(Vector3(0,0,0),Vector3(37.52,2,30)),AABB(Vector3(50.92,0,0),Vector3(1,2,30))]
	_check("columns:narrow_fixed_x_fails",not Placement.fit(moving,domain,obstacles,0.25).ready)
	var grid_fits := 0
	for index in range(64):
		var x := (float(domain.end.x)-float(moving.size.x))*float(index)/63.0
		var total := Vector3(x-float(moving.position.x),0,0)
		if _valid_result(moving,domain,obstacles,0.25,{"translation":total,"placedBounds":AABB(moving.position+total,moving.size)}): grid_fits+=1
	_check("columns:narrow_64_subsampling_misses",grid_fits==0)
	var corridor := _column_probe("columns_narrow",moving,domain,obstacles,0.25,true)
	if corridor.get("ready",false):
		_check("columns:actual_endpoint_not_far_domain_edge",corridor.placedBounds.position.x>37.76 and corridor.placedBounds.position.x<37.78)
	var reversed := obstacles.duplicate()
	reversed.reverse()
	_check("columns:reorder_exact",var_to_bytes(corridor)==var_to_bytes(_column_probe("columns_narrow_reverse",moving,domain,reversed,0.25,true)))
	_check("columns:repeat_exact",var_to_bytes(corridor)==var_to_bytes(Placement.fit_columns(moving,domain,obstacles,0.25)))
	_check("columns:empty_callback_exact",var_to_bytes(corridor)==var_to_bytes(Placement.fit_columns(moving,domain,obstacles,0.25,Callable())))
	_check("columns:true_callback_exact",var_to_bytes(corridor)==var_to_bytes(Placement.fit_columns(moving,domain,obstacles,0.25,func()->bool:return true)))
	var box := AABB(Vector3(0,0,0),Vector3.ONE)
	var space := Rect2(-10,-10,20,20)
	_check("columns:original_clear_exact",_column_probe("columns_clear",box,space,[],0,true).get("translation")==Vector3.ZERO)
	var fixed := Placement.fit(box,space,[box],0)
	var preferred := _column_probe("columns_original_x_priority",box,space,[box],0,true)
	_check("columns:original_x_keeps_fixed_z_choice",preferred.get("translation")==fixed.get("translation"))
	var wall := AABB(Vector3(0,0,-10),Vector3(1,1,20))
	_check("columns:equal_x_tie_lower",_column_probe("columns_tie",box,space,[wall],0,true).get("translation")==Vector3(-1,0,0))
	# Swap the reviewed Z rounding counterexample onto the lateral axis.
	var rounded := AABB(Vector3(0.35,0,0),Vector3(0.1,1,1))
	var blocker := AABB(Vector3(0.4,0,0),Vector3(0.2,1,1))
	var rounded_result := _column_probe("columns_float_lower",rounded,Rect2(0,0,1,1),[blocker],0,true)
	_check("columns:nearest_representable_lower",rounded_result.get("ready",false) and rounded_result.placedBounds.position.x==Vector3(0.2999999821186065673828125,0,0).x)
	_column_probe("columns_float_upper",AABB(Vector3(-0.45,0,0),rounded.size),Rect2(-1,0,1,1),[AABB(Vector3(-0.6,0,0),blocker.size)],0,true)
	_column_probe("columns_far_origin",AABB(Vector3(-1000,0,0.2),Vector3(0.1,1,0.1)),Rect2(0.1,0.1,1,1),[],0,true)
	_column_probe("columns_upper_domain",AABB(Vector3(1.1,0,0.2),Vector3(0.1,1,0.1)),Rect2(0,0,1,1),[],0,true)
	for offset: Vector3 in [Vector3(16,4,-8),Vector3(-16,-4,8)]:
		var moved := AABB(box.position+offset,box.size)
		var shifted := _column_probe("columns_shift_"+str(offset),moved,Rect2(space.position+Vector2(offset.x,offset.z),space.size),[AABB(wall.position+offset,wall.size)],0,true)
		_check("columns:translation_"+str(offset),shifted.get("translation")==Vector3(-1,0,0))
	_column_probe("columns_y_touch",box,space,[AABB(Vector3(-10,1,-10),Vector3(20,1,20))],0.25,true)
	_column_probe("columns_no_fit",box,space,[AABB(Vector3(-10,0,-10),Vector3(20,1,20))],0,false)
	_column_probe("columns_invalid_box",AABB(),space,[],0,false)
	_column_probe("columns_invalid_domain",box,Rect2(),[],0,false)
	_column_probe("columns_invalid_obstacle",box,space,[box,7],0,false)
	_column_probe("columns_invalid_late_bounds",box,space,[box,AABB()],0,false)
	for value in [-1.0,NAN,INF,10001.0]: _column_probe("columns_invalid_clearance_"+str(value),box,space,[],value,false)
	var successful_calls := [0]
	var traced := Placement.fit_columns(moving,domain,obstacles,0.25,func()->bool:
		successful_calls[0]+=1
		return true)
	_check("columns:observed_callback_success_exact",var_to_bytes(traced)==var_to_bytes(corridor))
	for stop_at in [1,3,8,15,int(successful_calls[0]/2),successful_calls[0]-1,successful_calls[0]]:
		var calls := [0]
		var stopped_result := Placement.fit_columns(moving,domain,obstacles,0.25,func()->bool:
			calls[0]+=1
			return calls[0]<stop_at)
		_check("columns:cancel_%d" % stop_at,not stopped_result.ready and stopped_result.reason=="cancelled" and calls[0]==stop_at and not stopped_result.has("placedBounds"))
	# External callback edits only its original container; captured membership
	# and the result must remain identical to the unchanged source invocation.
	var aliased := obstacles.duplicate()
	var called := [false]
	var alias_result := Placement.fit_columns(moving,domain,aliased,0.25,func()->bool:
		if not called[0]:
			called[0]=true
			aliased.clear()
		return true)
	_check("columns:callback_membership_isolated",aliased.is_empty() and var_to_bytes(alias_result)==var_to_bytes(corridor))
	var many: Array = []
	for index in range(10000): many.append(AABB(Vector3(0,2,0),Vector3.ONE))
	_column_probe("columns_inventory_10000",box,space,many,0,true)
	many.append(box)
	_column_probe("columns_inventory_over_limit",box,space,many,0,false)
	# Many genuine endpoint columns behind one full blocker. No-fit must not
	# conceal exhaustion of the total repeated-solver work budget.
	many.clear()
	many.append(AABB(Vector3(0,0,0),Vector3(100,1,10)))
	for index in range(9999): many.append(AABB(Vector3(float(index)*0.01,0,0),Vector3(0.005,1,10)))
	var exhausted := _column_probe("columns_explicit_work_limit",AABB(Vector3(0.35,0,0),Vector3(0.1,1,10)),Rect2(0,0,100,10),many,0,false)
	_check("columns:limit_not_no_fit",exhausted.get("reason")=="column_work_limit_exceeded" and exhausted.get("testedColumns",0)>0 and exhausted.get("workUpperBound",Placement.MAX_COLUMN_WORK+1)<=Placement.MAX_COLUMN_WORK)

func _column_pruning() -> void:
	# Explicit synthetic unpruned reference: identical candidate selection and
	# fixed-X implementation, but repeated fit receives ALL originals. Only its
	# work charge differs; final source scan and every geometric check remain.
	var source := FileAccess.get_file_as_string("res://scripts/buildings/BoundaryInfillPlacement.gd")
	var column_filter := "var column_relevant := _column_relevant(column,relevant,clearance,proceed)"
	var column_boxes := "var column_boxes: Array = column_relevant.boxes"
	var call_site := "fit(column,allowed,column_boxes,clearance,proceed)"
	var charge := "128+relevant.size()+column_boxes.size()*(64+8*int(ceil(log(float(2*column_boxes.size()+4))/log(2.0))))"
	_check("pruning:oracle_exact_patch_sites",source.count(column_filter)==1 and source.count(column_boxes)==1 and source.count(call_site)==1 and source.count(charge)==1)
	var oracle = GDScript.new()
	oracle.source_code=source.replace(column_filter,"var column_relevant := {\"ready\":true,\"boxes\":relevant}").replace(column_boxes,"var column_boxes: Array = relevant").replace(charge,"128+relevant.size()+relevant.size()*(64+8*int(ceil(log(float(2*relevant.size()+4))/log(2.0))))")
	var error: int = oracle.reload()
	_check("pruning:oracle_compiles",error==OK)
	if error!=OK: return
	var moving := AABB(Vector3(20,0,5),Vector3(12.604,2,13.2))
	var domain := Rect2(0,0,50.89,30)
	var local: Array = [AABB(Vector3(0,0,0),Vector3(37.52,2,30)),AABB(Vector3(50.92,0,0),Vector3(1,2,30))]
	var mixed := local.duplicate()
	for index in range(1711):
		match index%3:
			0: mixed.append(AABB(Vector3(200+float(index),0,5),Vector3.ONE))
			1: mixed.append(AABB(Vector3(20,0,200+float(index)),Vector3.ONE))
			2: mixed.append(AABB(Vector3(20,5,5),Vector3.ONE))
	var cases: Array = [
		{"name":"narrow","moving":moving,"domain":domain,"obstacles":mixed,"clearance":0.25,"ready":true},
		{"name":"clear","moving":AABB(Vector3.ZERO,Vector3.ONE),"domain":Rect2(-2,-2,4,4),"obstacles":[AABB(Vector3(50,0,0),Vector3.ONE),AABB(Vector3(0,1,0),Vector3.ONE)],"clearance":0.25,"ready":true},
		{"name":"no_fit","moving":AABB(Vector3.ZERO,Vector3.ONE),"domain":Rect2(0,0,2,2),"obstacles":[AABB(Vector3.ZERO,Vector3(2,1,2)),AABB(Vector3(0,0,50),Vector3.ONE)],"clearance":0.25,"ready":false},
		{"name":"clearance_reaches_domain","moving":AABB(Vector3(0.9,0,0),Vector3(0.1,1,1)),"domain":Rect2(0,0,1,1),"obstacles":[AABB(Vector3(1.1,0,0),Vector3(1,1,1)),AABB(Vector3(-20,0,0),Vector3.ONE)],"clearance":0.25,"ready":true}]
	for item: Dictionary in cases:
		var baseline := {}
		for reverse_order in [false,true]:
			var boxes: Array=item.obstacles.duplicate()
			if reverse_order: boxes.reverse()
			var label: String = "pruning_"+item.name+"_"+str(reverse_order)
			var result := _column_probe(label,item.moving,item.domain,boxes,item.clearance,item.ready)
			var original: Dictionary = oracle.fit_columns(item.moving,item.domain,boxes,item.clearance)
			var normalized := result.duplicate(true)
			var original_normalized := original.duplicate(true)
			normalized.erase("workUpperBound")
			original_normalized.erase("workUpperBound")
			_check(label+":unpruned_answer_and_order_exact",var_to_bytes(normalized)==var_to_bytes(original_normalized))
			if reverse_order: _check(label+":reversed_full_exact",var_to_bytes(result)==var_to_bytes(baseline))
			else: baseline=result
			if item.name=="narrow":
				_check(label+":counts",result.get("sourceObstacleCount")==1713 and result.get("relevantObstacleCount")==2)
				_check(label+":repeated_work_reduced",result.get("workUpperBound",INF)<original.get("workUpperBound",0))
			if item.name=="clearance_reaches_domain": _check(label+":expanded_outside_obstacle_retained",result.get("relevantObstacleCount")==1)
	# Even a box provably remote in X/Z/Y must be validated before pruning.
	for bad: AABB in [AABB(Vector3(500,500,500),Vector3(-1,1,1)),AABB(Vector3(500,500,500),Vector3(NAN,1,1)),AABB(Vector3(500,INF,500),Vector3.ONE)]:
		var invalid := mixed.duplicate()
		invalid.append(bad)
		var result := _column_probe("pruning_invalid_far_"+str(bad),moving,domain,invalid,0.25,false)
		_check("pruning:invalid_far_reason_"+str(bad),result.get("reason")=="invalid_boundary_infill_obstacle")

func _check(label: String,passed: bool) -> void:
	checks[label]=passed
