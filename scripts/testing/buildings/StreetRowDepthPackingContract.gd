extends SceneTree
## Pure synthetic source-packing contract; no scene, source build or gameplay.
const Packing = preload("res://scripts/buildings/StreetRowDepthPacking.gd")
var checks := {}
var observations := {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("STREET_ROW_DEPTH_PACKING_OUTPUT")
	if not path.is_absolute_path() or FileAccess.file_exists(path): quit(2); return
	var actual: Array = [_row("row2",-20.56099,10.827,0.14),_row("row3",-10.22929,10.827,0.14)]
	var result := _probe("actual_numbers",actual)
	_check("actual_ready",result.ready)
	if result.ready:
		_check("actual_overlap_matches_reported_scale",absf(result.constraints[0].originalOverlap-0.7753)<0.00001)
		_check("actual_both_shrink_symmetrically",result.rowDepths.row2==result.rowDepths.row3 and result.rowDepths.row2<10.827)
		_check("actual_final_faces_clear",_independent_clear(actual,result.rowDepths))
		_check("actual_maximum_reduction_not_depth_half_deficit_bug",result.rowDepths.row2 <= 10.052)
	var reverse := actual.duplicate(true)
	reverse.reverse()
	var reversed := _probe("reverse",reverse)
	_check("reverse_complete_result_exact",var_to_bytes(result)==var_to_bytes(reversed))
	var repeat := _probe("repeat",actual)
	_check("repeat_complete_result_exact",var_to_bytes(result)==var_to_bytes(repeat))
	var three: Array = [_row("a",0,10),_row("b",8,10),_row("c",16,10)]
	var both := _probe("both_neighbors",three)
	_check("both_neighbors_ready",both.ready)
	if both.ready:
		_check("both_neighbors_max_not_sum",both.rowDepths=={"a":8.0,"b":8.0,"c":8.0})
		_check("both_neighbors_all_clear",_independent_clear(three,both.rowDepths))
	var clear: Array = [_row("left",0,10),_row("right",20,10)]
	var clear_result := _probe("clear",clear)
	_check("clear_rows_byte_exact",clear_result.ready and var_to_bytes(clear_result.rowDepths)==var_to_bytes({"left":10.0,"right":10.0}) and clear_result.changedRowIds.is_empty())
	var disjoint := actual.duplicate(true)
	disjoint[1].envelopes[0].minimumX=4.0
	disjoint[1].envelopes[0].maximumX=5.0
	var disjoint_result := _probe("disjoint_x",disjoint)
	_check("disjoint_x_unchanged",disjoint_result.ready and disjoint_result.constraints.is_empty() and disjoint_result.rowDepths.row2==actual[0].depth and disjoint_result.rowDepths.row3==actual[1].depth)
	var touching := actual.duplicate(true)
	touching[1].envelopes[0].minimumX=1.0
	touching[1].envelopes[0].maximumX=2.0
	var touch_result := _probe("touching_x",touching)
	_check("touching_x_no_positive_intersection",touch_result.ready and touch_result.constraints.is_empty())
	var multiple := actual.duplicate(true)
	for row: Dictionary in multiple:
		row.envelopes.append({"minimumX":0.0,"maximumX":1.0,"zOverhang":0.0})
	var multi := _probe("multiple_envelopes",multiple)
	for row: Dictionary in multiple: row.envelopes.reverse()
	var multi_reverse := _probe("envelopes_reverse",multiple)
	_check("envelope_order_exact",var_to_bytes(multi)==var_to_bytes(multi_reverse))
	_check("maximum_overhang_not_added_across_envelopes",multi.ready and result.ready and multi.rowDepths==result.rowDepths)
	var clear_tail := actual.duplicate(true)
	clear_tail.append(_row("tail",100,10.123456789))
	var tail := _probe("unaffected_tail",clear_tail)
	_check("unaffected_non_float32_depth_byte_exact",tail.ready and var_to_bytes(tail.rowDepths.tail)==var_to_bytes(clear_tail[2].depth))
	var rounded: Array = [_row("a",100.1,1.0),_row("b",101.1,1.0)]
	var round_result := _probe("represented_faces",rounded)
	_check("represented_boundary_clear",round_result.ready and _independent_clear(rounded,round_result.rowDepths))
	for mode: String in ["zero_depth","negative_depth","zero_minimum","negative_minimum","missing_minimum","minimum_above_depth","duplicate_id","empty_id","nan_center","infinite_depth","string_depth","negative_overhang","zero_x_width","reversed_x","missing_envelopes","bad_envelope","too_small","same_center","float32_overflow"]:
		var bad := actual.duplicate(true)
		match mode:
			"zero_depth": bad[0].depth=0.0
			"negative_depth": bad[0].depth=-1.0
			"zero_minimum": bad[0].minimumDepth=0.0
			"negative_minimum": bad[0].minimumDepth=-1.0
			"missing_minimum": bad[0].erase("minimumDepth")
			"minimum_above_depth": bad[0].minimumDepth=20.0
			"duplicate_id": bad[1].id=bad[0].id
			"empty_id": bad[0].id=""
			"nan_center": bad[0].centerZ=NAN
			"infinite_depth": bad[0].depth=INF
			"string_depth": bad[0].depth="10"
			"negative_overhang": bad[0].envelopes[0].zOverhang=-0.1
			"zero_x_width": bad[0].envelopes[0].maximumX=0.0
			"reversed_x": bad[0].envelopes[0].minimumX=2.0
			"missing_envelopes": bad[0].erase("envelopes")
			"bad_envelope": bad[0].envelopes=[7]
			"too_small": bad[0].minimumDepth=10.5
			"same_center": bad[1].centerZ=bad[0].centerZ
			"float32_overflow": bad[0].centerZ=1.0e100
		var rejected := _probe(mode,bad)
		_check(mode+"_reject_no_depth_output",not rejected.ready and not rejected.has("rowDepths") and not rejected.reason.is_empty())
	_check("empty_rows_rejected",not Packing.fit([]).ready)
	_check("non_dictionary_rejected",not Packing.fit([1]).ready)
	var maximum: Array = []
	for index in range(16):
		var row := _row("r%02d" % index,index*20.0,10)
		for extra in range(3): row.envelopes.append(row.envelopes[0].duplicate())
		maximum.append(row)
	_check("maximum_rows_envelopes_accepted",Packing.fit(maximum).ready)
	var over_envelopes := maximum.duplicate(true)
	over_envelopes[0].envelopes.append(over_envelopes[0].envelopes[0].duplicate())
	_check("envelope_cap_rejected",not Packing.fit(over_envelopes).ready)
	maximum.append(_row("extra",500,10))
	_check("row_cap_rejected",not Packing.fit(maximum).ready)
	_boundary_controls()
	var passed: bool = not checks.values().has(false)
	var report := {"passed":passed,"checkCount":checks.size(),"checks":checks,"observations":observations,"evidenceLevel":"synthetic_pure_source_packing_not_gameplay","helperSha256":FileAccess.get_sha256("res://scripts/buildings/StreetRowDepthPacking.gd")}
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("Street row depth packing ",checks.size()," checks passed=",passed)
	quit(0 if passed else 1)

func _row(id: String, center: float, depth: float, overhang := 0.0) -> Dictionary:
	return {"id":id,"centerZ":center,"depth":depth,"minimumDepth":1.0,"envelopes":[{"minimumX":0.0,"maximumX":1.0,"zOverhang":overhang}]}

func _probe(label: String, rows: Array) -> Dictionary:
	var before := var_to_bytes(rows)
	var result := Packing.fit(rows)
	_check(label+"_input_immutable",var_to_bytes(rows)==before)
	if result.ready:
		_check(label+"_never_grows_or_below_minimum",rows.all(func(row):return result.rowDepths[row.id]<=row.depth and result.rowDepths[row.id]>=row.minimumDepth))
	observations[label]=result
	return result

func _independent_clear(rows: Array, depths: Dictionary) -> bool:
	for i in range(rows.size()):
		for j in range(i+1,rows.size()):
			var a: Dictionary=rows[i]
			var b: Dictionary=rows[j]
			for ea: Dictionary in a.envelopes:
				for eb: Dictionary in b.envelopes:
					if minf(ea.maximumX,eb.maximumX)<=maxf(ea.minimumX,eb.minimumX): continue
					var ca:=Vector3(0,0,a.centerZ)
					var cb:=Vector3(0,0,b.centerZ)
					var sa:=Vector3(1,1,depths[a.id]+2.0*ea.zOverhang)
					var sb:=Vector3(1,1,depths[b.id]+2.0*eb.zOverhang)
					var ba:=AABB(ca-sa*0.5,sa)
					var bb:=AABB(cb-sb*0.5,sb)
					if minf(ba.end.z,bb.end.z)>maxf(ba.position.z,bb.position.z): return false
					if depths[a.id]*0.5+depths[b.id]*0.5+ea.zOverhang+eb.zOverhang>absf(float(ca.z)-float(cb.z)): return false
					for face_a: Dictionary in _constructed_sections(a, depths[a.id], ea):
						for face_b: Dictionary in _constructed_sections(b, depths[b.id], eb):
							if minf(face_a.high,face_b.high)>maxf(face_a.low,face_b.low): return false
	return true

func _constructed_sections(row: Dictionary, depth: float, envelope: Dictionary) -> Array[Dictionary]:
	# Independent construction of a whole box and the two separately stored
	# end slabs. Inspect both AABB and scalar faces of the represented geometry;
	# no calls to the packer's bounds/overlap/rounding implementation.
	var center := Vector3(0.0,0.0,float(row.centerZ))
	var specifications: Array = [[center,Vector3(1.0,1.0,depth+2.0*float(envelope.zOverhang))]]
	var thickness := float(envelope.get("boundaryThickness",0.0))
	if thickness>0.0:
		for side in [-1.0,1.0]:
			var slab_center := Vector3(0.0,0.0,float(center.z)+side*(depth*0.5+float(envelope.zOverhang)-thickness*0.5))
			specifications.append([slab_center,Vector3(1.0,1.0,thickness)])
	var faces: Array[Dictionary] = []
	for specification: Array in specifications:
		var position: Vector3 = specification[0]
		var size: Vector3 = specification[1]
		var box := AABB(position-size*0.5,size)
		faces.append({"low":minf(box.position.z,float(position.z)-float(size.z)*0.5),"high":maxf(box.end.z,float(position.z)+float(size.z)*0.5)})
	return faces

func _boundary_controls() -> void:
	# These stored centers straddle a float32 exponent boundary. Whole-depth
	# boxes touch, yet separately positioned 0.3m end slabs overlap by one ULP.
	var rows: Array = [_row("a",-261.295989990234375,10.75),_row("b",-250.545989990234375,10.75)]
	var omitted := _probe("boundary_omitted",rows)
	var zero := rows.duplicate(true)
	for row: Dictionary in zero: row.envelopes[0]["boundaryThickness"]=0.0
	var explicit_zero := _probe("boundary_zero",zero)
	_check("boundary_optional_zero_complete_result_exact",var_to_bytes(omitted)==var_to_bytes(explicit_zero))
	for row: Dictionary in rows: row.envelopes[0]["boundaryThickness"]=0.3
	var a_center := Vector3(0.0,0.0,float(rows[0].centerZ)+(10.75*0.5-0.3*0.5))
	var b_center := Vector3(0.0,0.0,float(rows[1].centerZ)-(10.75*0.5-0.3*0.5))
	var slab_size := Vector3(1.0,1.0,0.3)
	var a_box := AABB(a_center-slab_size*0.5,slab_size)
	var b_box := AABB(b_center-slab_size*0.5,slab_size)
	var original_overlap := minf(a_box.end.z,b_box.end.z)-maxf(a_box.position.z,b_box.position.z)
	observations["independent_original_slab_witness"]={"a":a_box,"b":b_box,"positiveOverlap":original_overlap}
	_check("independent_actual_slabs_positive_overlap",original_overlap>0.0)
	_check("whole_box_only_would_miss_slab_overlap",omitted.ready and omitted.changedRowIds.is_empty() and _independent_clear(zero,omitted.rowDepths) and not _independent_clear(rows,omitted.rowDepths))
	var packed := _probe("boundary_slabs",rows)
	_check("boundary_slabs_ready",packed.ready)
	if packed.ready:
		_check("boundary_slabs_both_shrink",packed.rowDepths.a<10.75 and packed.rowDepths.b<10.75)
		_check("boundary_slabs_constructed_clear",_independent_clear(rows,packed.rowDepths))
	var reversed := rows.duplicate(true)
	reversed.reverse()
	_check("boundary_rows_reverse_exact",var_to_bytes(packed)==var_to_bytes(_probe("boundary_reverse",reversed)))
	var clear := rows.duplicate(true)
	clear[1].centerZ=20.0
	var clear_result := _probe("boundary_clear",clear)
	_check("boundary_clear_rows_unchanged",clear_result.ready and clear_result.changedRowIds.is_empty() and var_to_bytes(clear_result.rowDepths)==var_to_bytes({"a":10.75,"b":10.75}) and _independent_clear(clear,clear_result.rowDepths))
	var mixed := rows.duplicate(true)
	for row: Dictionary in mixed:
		var extra: Dictionary = row.envelopes[0].duplicate(true)
		extra.boundaryThickness=0.2
		row.envelopes.append(extra)
	var mixed_result := _probe("boundary_mixed",mixed)
	for row: Dictionary in mixed: row.envelopes.reverse()
	mixed.reverse()
	_check("boundary_envelope_tiebreak_reverse_exact",var_to_bytes(mixed_result)==var_to_bytes(_probe("boundary_mixed_reverse",mixed)))
	_check("boundary_mixed_constructed_clear",mixed_result.ready and _independent_clear(mixed,mixed_result.rowDepths))
	var at_minimum := clear.duplicate(true)
	for row: Dictionary in at_minimum: row.minimumDepth=0.3
	_check("boundary_equal_minimum_allowed",_probe("boundary_equal_minimum",at_minimum).ready)
	for invalid: Dictionary in [{"id":"negative","value":-0.01},{"id":"above_minimum","value":1.0001},{"id":"nan","value":NAN},{"id":"infinite","value":INF},{"id":"string","value":"0.3"},{"id":"bool","value":true},{"id":"null","value":null}]:
		var bad := rows.duplicate(true)
		bad[0].envelopes[0].boundaryThickness=invalid.value
		var rejected := _probe("boundary_invalid_"+invalid.id,bad)
		_check("boundary_invalid_"+invalid.id+"_reject",not rejected.ready and rejected.reason=="invalid_boundary_thickness" and not rejected.has("rowDepths"))

func _check(label: String, passed: bool) -> void:
	checks[label]=passed
