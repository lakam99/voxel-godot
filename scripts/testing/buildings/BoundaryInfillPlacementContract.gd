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

func _check(label: String,passed: bool) -> void:
	checks[label]=passed
