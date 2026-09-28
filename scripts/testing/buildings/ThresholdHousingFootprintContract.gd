extends SceneTree

## Synthetic pure fitting and tiny actual-Part/Blueprint contract only.
## No source replay, scene publication, navigation or gameplay acceptance.
const Fitter = preload("res://scripts/buildings/ThresholdBearingFootprintFitter.gd")
const Housing = preload("res://scripts/buildings/ThresholdBearingHousingRecipe.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const REPORT_ENV := "THRESHOLD_HOUSING_FOOTPRINT_OUTPUT"
const HISTORICAL_REPORT := "artifacts/citadel-runtime-integration/candidate-threshold-05/report.json"
const HISTORICAL_SHA := "da9827876958977d2510e165c2a62c9879a74a8688ad8bc68c1483a30d8d75ca"
var checks: Dictionary = {}
var observations: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment(REPORT_ENV)
	if not path.is_absolute_path() or FileAccess.file_exists(path):
		quit(2)
		return
	_actual_numbers()
	_edges_and_transforms()
	_refusals()
	_actual_part_housing()
	var passed: bool = not checks.values().has(false)
	var report := {"passed":passed,"checkCount":checks.size(),"checks":checks,"observations":observations,
		"evidenceLevel":"synthetic_geometry_and_tiny_actual_part_not_gameplay",
		"historicalInputReport":HISTORICAL_REPORT,"historicalInputReportSha256":HISTORICAL_SHA,
		"sourceHashes":{}}
	for source_path: String in ["res://scripts/buildings/ThresholdBearingFootprintFitter.gd","res://scripts/buildings/ThresholdBearingHousingRecipe.gd","res://scripts/buildings/BuildingBlueprint.gd","res://scripts/testing/buildings/ThresholdHousingFootprintContract.gd"]:
		report.sourceHashes[source_path]=FileAccess.get_sha256(source_path)
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null:
		quit(2)
		return
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("Threshold housing footprint: ",checks.size()," checks passed=",passed)
	quit(0 if passed else 1)

func _case(center: Vector3, size: Vector3, seat_center := Vector3.ZERO, seat_size := Vector3(4,2,4), inset := 0.005) -> Dictionary:
	return {"center":center,"size":size,"seatCenter":seat_center,"seatSize":seat_size,"inset":inset}

func _probe(label: String, input: Dictionary, expected_ready: bool) -> Dictionary:
	var before := var_to_bytes(input)
	var result: Dictionary = Fitter.fit_seat_footprint(input.center,input.size,input.seatCenter,input.seatSize,input.inset)
	_check(label+":input_immutable",before==var_to_bytes(input))
	_check(label+":typed_status",result.get("ready") is bool)
	_check(label+":expected_status",result.get("ready")==expected_ready)
	observations[label]=result
	if result.get("ready") == true:
		var typed: bool = result.get("position") is Vector3 and result.get("size") is Vector3 and result.get("changed") is bool
		_check(label+":typed_geometry",typed)
		if not typed: return result
		_check(label+":independent_bounds",_contained(input,result))
		_check(label+":exact_y",var_to_bytes(result.position.y)==var_to_bytes(input.center.y) and var_to_bytes(result.size.y)==var_to_bytes(input.size.y))
		_check(label+":changed_truthful",result.changed==(result.position!=input.center or result.size!=input.size))
	else:
		_check(label+":no_partial_geometry",not result.has("position") and not result.has("size"))
	return result

func _contained(input: Dictionary, result: Dictionary) -> bool:
	var center: Vector3 = result.position
	var size: Vector3 = result.size
	if not center.is_finite() or not size.is_finite() or size.x<0.02 or size.y<0.02 or size.z<0.02: return false
	if size.x>input.size.x or size.z>input.size.z: return false
	# Independent eight scalar corners of the stored center/size, matching the
	# existing housing validator's authority (not rounded AABB endpoints).
	# Original footprint is closed; seat-minus-inset is strictly open.
	for axis in [0,2]:
		var original_low := float(input.center[axis])-float(input.size[axis])*0.5
		var original_high := float(input.center[axis])+float(input.size[axis])*0.5
		var seat_low := float(input.seatCenter[axis])-float(input.seatSize[axis])*0.5+float(input.inset)
		var seat_high := float(input.seatCenter[axis])+float(input.seatSize[axis])*0.5-float(input.inset)
		if float(center[axis])-float(size[axis])*0.5<original_low or float(center[axis])+float(size[axis])*0.5>original_high: return false
		if float(center[axis])-float(size[axis])*0.5<=seat_low or float(center[axis])+float(size[axis])*0.5>=seat_high: return false
		for x in [-1.0,1.0]:
			for y in [-1.0,1.0]:
				for z in [-1.0,1.0]:
					var signs := [x,y,z]
					var corner := float(center[axis])+float(size[axis])*float(signs[axis])*0.5
					if corner<original_low or corner>original_high or corner<=seat_low or corner>=seat_high: return false
	return true

func _actual_numbers() -> void:
	# Full-precision represented values reconstructed from report scalar bounds,
	# not its six-decimal Vector3 presentation strings. No artifact load required.
	var input := _case(Vector3(8.595182418823242,2.4213929176330566,-10.229287147521973),
		Vector3(0.9200000166893005,4.842785835266113,1.5800000429153442),
		Vector3(8.055000305175781,1.6200000047683716,-12.232000350952148),
		Vector3(10.810001373291016,2.0,5.300000190734863))
	var overhang := float(input.center.z)+float(input.size.z)*0.5-(float(input.seatCenter.z)+float(input.seatSize.z)*0.5-float(input.inset))
	observations["historical_overhang"]={"insetViolationMeters":overhang,"input":input}
	_check("historical:14_77cm_positive_overhang",overhang>0.1477 and overhang<0.1478)
	_check("historical:unfitted_geometry_rejected",not _contained(input,{"position":input.center,"size":input.size}))
	var result := _probe("historical_fit",input,true)
	if result.get("ready") == true:
		_check("historical:x_unchanged",result.position.x==input.center.x and result.size.x==input.size.x)
		_check("historical:z_trimmed",result.size.z<input.size.z and result.position.z<input.center.z)
		_check("historical:repeat_complete_exact",var_to_bytes(result)==var_to_bytes(_probe("historical_repeat",input,true)))
		var again := input.duplicate(true)
		again.center=result.position
		again.size=result.size
		var idempotent := _probe("historical_refit",again,true)
		_check("historical:refit_unchanged",idempotent.get("ready")==true and idempotent.position==result.position and idempotent.size==result.size and idempotent.changed==false)

func _edges_and_transforms() -> void:
	for axis in [0,2]:
		for sign_value in [-1.0,1.0]:
			for translation: Vector3 in [Vector3.ZERO,Vector3(32,-8,-16),Vector3(-32,8,16)]:
				var center := Vector3(0,3,0)+translation
				center[axis]+=sign_value*1.75
				var label := "edge_%d_%s_%s" % [axis,str(sign_value),str(translation)]
				_probe(label,_case(center,Vector3(1,0.5,1),translation,Vector3(4,2,4),0.25),true)
	for y in [-10.0,0.0,10.0]:
		var input := _case(Vector3(0,y,0),Vector3(1,0.5,1))
		var result := _probe("clear_y_"+str(y),input,true)
		_check("clear_y_"+str(y)+":byte_exact",result.get("ready")==true and result.changed==false and var_to_bytes([result.position,result.size])==var_to_bytes([input.center,input.size]))
	_probe("trim_both_axes",_case(Vector3(1.8,2,-1.8),Vector3(1,1,1)),true)
	_probe("seat_inside_original",_case(Vector3(0,5,0),Vector3(8,1,8)),true)
	_probe("zero_inset_strict",_case(Vector3(0,3,0),Vector3(4,1,4),Vector3.ZERO,Vector3(4,2,4),0.0),true)
	_probe("exact_inset_boundary_trim",_case(Vector3(0,3,0),Vector3(3.5,1,3.5),Vector3.ZERO,Vector3(4,2,4),0.25),true)

func _refusals() -> void:
	var good := _case(Vector3(0,3,0),Vector3(1,1,1))
	for field: String in ["center","size","seatCenter","seatSize"]:
		for axis in range(3):
			for value in [NAN,INF,-INF]:
				var bad := good.duplicate(true)
				var vector: Vector3 = bad[field]
				vector[axis]=value
				bad[field]=vector
				_probe("invalid_%s_%d_%s" % [field,axis,str(value)],bad,false)
	for field: String in ["size","seatSize"]:
		for axis in range(3):
			for value in [0.0,-1.0,0.01]:
				var bad := good.duplicate(true)
				var vector: Vector3 = bad[field]
				vector[axis]=value
				bad[field]=vector
				_probe("invalid_dimension_%s_%d_%s" % [field,axis,str(value)],bad,false)
	for value in [-0.01,NAN,INF,-INF,2.0,3.0]:
		var bad := good.duplicate(true)
		bad.inset=value
		_probe("invalid_inset_"+str(value),bad,false)
	for field: String in ["center","size","seatCenter","seatSize"]:
		for axis in range(3):
			var bad := good.duplicate(true)
			var vector: Vector3 = bad[field]
			vector[axis]=10001.0
			bad[field]=vector
			_probe("above_limit_%s_%d" % [field,axis],bad,false)
	_probe("disjoint_x",_case(Vector3(5,3,0),Vector3(1,1,1)),false)
	_probe("disjoint_z",_case(Vector3(0,3,-5),Vector3(1,1,1)),false)
	_probe("touching_only",_case(Vector3(2.5,3,0),Vector3(1,1,1),Vector3.ZERO,Vector3(4,2,4),0.0),false)
	_probe("positive_fragment_too_small",_case(Vector3(2.49,3,0),Vector3(1,1,1)),false)

func _actual_part_housing() -> void:
	var source = Blueprint.new("synthetic_fitted_housing",17,"stone")
	var root = source.add_part({"id":"root","kind":"foundation","collision":true,"physicalIntent":"structural_mass","position":Vector3(0,1.25,0),"size":Vector3(6,2.5,6)})
	var seat = source.add_part({"id":"seat","kind":"foundation","collision":true,"physicalIntent":"structural_mass","position":Vector3(0,2.5,0),"size":Vector3(4,0.24000000953674316,4),"recipe":{"physicalRequiredSeatPartIds":[root.id]}})
	var initial: Dictionary = source.validate_physical_integrity()
	_check("housing:ordinary_initial_proof",initial.get("passed")==true and source.has_rooted_support_chain(seat,{}))
	var before := var_to_bytes(source.snapshot())
	var fitted := _probe("housing_footprint",_case(Vector3(1.9,3,0),Vector3(1,1,0.8),seat.position,seat.size,Housing.INSET),true)
	if fitted.get("ready") != true: return
	const UPPER := 3.875730514526367
	var proposal: Dictionary = Housing.prepare(seat,UPPER,fitted.position,fitted.size)
	_check("housing:unchanged_validator_prepares",proposal.get("ready")==true)
	_check("housing:source_immutable_during_fit_prepare",before==var_to_bytes(source.snapshot()))
	if proposal.get("ready") != true: return
	var post = source.add_part({"id":"fitted_post","kind":"foundation","collision":true,"physicalIntent":"structural_mass","position":proposal.position,"size":proposal.size,"recipe":{"physicalRequiredSeatPartIds":[seat.id],"physicalRequiredSeatFacts":[proposal.seatFact]}})
	_check("housing:constructed_geometry_unclamped",post.position==proposal.position and post.size==proposal.size)
	_check("housing:exact_upper",float(post.position.y)+float(post.size.y)*0.5==UPPER)
	_check("housing:existing_actual_part_validator",Housing.validate(post,seat,proposal.seatFact).get("ready")==true)
	var final_proof: Dictionary = source.validate_physical_integrity()
	_check("housing:ordinary_rooted_final_proof",final_proof.get("passed")==true and source.has_rooted_support_chain(post,{}))

func _check(label: String, passed: bool) -> void:
	checks[label]=passed
