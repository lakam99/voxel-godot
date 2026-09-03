extends RefCounted
class_name StreetRowDepthPacking

## Pure source packing. No source objects, RNG, shifts, growth or exemptions.
## Pair deficits are FULL-depth units: half of each deficit is removed from
## each member's depth. Every reduction is computed from the original layout.
const MAX_ROWS := 16
const MAX_ENVELOPES := 64
const MAX_ROUNDING_STEPS := 32

static func fit(rows: Array) -> Dictionary:
	if rows.is_empty() or rows.size() > MAX_ROWS: return _fail("invalid_row_count")
	var ordered: Array[Dictionary] = []
	var ids := {}
	var envelope_count := 0
	for value: Variant in rows:
		if not value is Dictionary: return _fail("invalid_row")
		if not value.get("id") is String or value.id.is_empty() or ids.has(value.id): return _fail("invalid_or_duplicate_row_id")
		for key: String in ["centerZ", "depth", "minimumDepth"]:
			if not _number(value.get(key)): return _fail("invalid_row_scalar")
		if value.depth <= 0.0 or value.minimumDepth <= 0.0 or value.minimumDepth > value.depth: return _fail("invalid_depth_range")
		if not value.get("envelopes") is Array or value.envelopes.is_empty(): return _fail("invalid_envelopes")
		envelope_count += value.envelopes.size()
		if envelope_count > MAX_ENVELOPES: return _fail("envelope_limit")
		var envelopes: Array[Dictionary] = []
		for envelope: Variant in value.envelopes:
			if not envelope is Dictionary: return _fail("invalid_envelope")
			for key: String in ["minimumX", "maximumX", "zOverhang"]:
				if not _number(envelope.get(key)): return _fail("invalid_envelope_scalar")
			if envelope.minimumX >= envelope.maximumX or envelope.zOverhang < 0.0: return _fail("invalid_envelope_bounds")
			var boundary: Variant = envelope.get("boundaryThickness",0.0)
			if not _number(boundary) or boundary < 0.0 or boundary > value.minimumDepth: return _fail("invalid_boundary_thickness")
			var low := _f32(envelope.minimumX)
			var high := _f32(envelope.maximumX)
			if not is_finite(low) or not is_finite(high) or low >= high: return _fail("unrepresentable_envelope")
			envelopes.append({"minimumX":minf(low,envelope.minimumX), "maximumX":maxf(high,envelope.maximumX), "zOverhang":float(envelope.zOverhang),"boundaryThickness":float(boundary)})
		envelopes.sort_custom(func(a: Dictionary,b: Dictionary)->bool:
			if a.minimumX != b.minimumX: return a.minimumX < b.minimumX
			if a.maximumX != b.maximumX: return a.maximumX < b.maximumX
			if a.zOverhang != b.zOverhang: return a.zOverhang < b.zOverhang
			return a.boundaryThickness < b.boundaryThickness)
		var row := {"id":value.id,"centerZ":_f32(value.centerZ),"depth":float(value.depth),"minimumDepth":float(value.minimumDepth),"envelopes":envelopes}
		if not is_finite(row.centerZ): return _fail("unrepresentable_center")
		for envelope: Dictionary in envelopes:
			if _bounds(row,row.depth,envelope.zOverhang,envelope.boundaryThickness).is_empty(): return _fail("unrepresentable_depth")
		ordered.append(row)
		ids[row.id] = true
	ordered.sort_custom(func(a: Dictionary,b: Dictionary)->bool:return a.id < b.id)
	var constraints: Array[Dictionary] = []
	var reductions := {}
	var depths := {}
	for row: Dictionary in ordered:
		reductions[row.id] = 0.0
		depths[row.id] = row.depth
	for i in range(ordered.size()):
		for j in range(i+1,ordered.size()):
			var a: Dictionary = ordered[i]
			var b: Dictionary = ordered[j]
			for ea: Dictionary in a.envelopes:
				for eb: Dictionary in b.envelopes:
					if minf(ea.maximumX,eb.maximumX) <= maxf(ea.minimumX,eb.minimumX): continue
					var overlap := _overlap(a,b,a.depth,b.depth,ea.zOverhang,eb.zOverhang,ea.boundaryThickness,eb.boundaryThickness)
					var deficit := 2.0 * maxf(0.0,overlap)
					reductions[a.id] = maxf(reductions[a.id],deficit*0.5)
					reductions[b.id] = maxf(reductions[b.id],deficit*0.5)
					constraints.append({"a":i,"b":j,"rowA":a.id,"rowB":b.id,"overhangA":ea.zOverhang,"overhangB":eb.zOverhang,"boundaryA":ea.boundaryThickness,"boundaryB":eb.boundaryThickness,"representedCenterGap":absf(a.centerZ-b.centerZ),"originalOverlap":overlap,"pairDeficit":deficit})
	for row: Dictionary in ordered:
		if reductions[row.id] > 0.0:
			depths[row.id] = _inward(row.depth-reductions[row.id])
		if depths[row.id] < row.minimumDepth or depths[row.id] <= 0.0: return _fail("minimum_depth_unavailable",row.id)
	# Recheck actual stored float32 size and both scalar and vector/AABB faces.
	# Simultaneous one-ULP inward steps cannot introduce a new intersection.
	var rounding_steps := 0
	for iteration in range(MAX_ROUNDING_STEPS+1):
		var shrink := {}
		for constraint: Dictionary in constraints:
			var a: Dictionary = ordered[constraint.a]
			var b: Dictionary = ordered[constraint.b]
			if _overlap(a,b,depths[a.id],depths[b.id],constraint.overhangA,constraint.overhangB,constraint.boundaryA,constraint.boundaryB) > 0.0:
				shrink[a.id] = true
				shrink[b.id] = true
		if shrink.is_empty(): break
		if iteration == MAX_ROUNDING_STEPS: return _fail("unrepresentable_clearance")
		for row: Dictionary in ordered:
			if not shrink.has(row.id): continue
			depths[row.id] = _previous_positive_float(depths[row.id])
			if depths[row.id] < row.minimumDepth or depths[row.id] <= 0.0: return _fail("minimum_depth_unavailable",row.id)
		rounding_steps += 1
	var changed: Array[String] = []
	for row: Dictionary in ordered:
		if depths[row.id] > row.depth: return _fail("depth_growth")
		if depths[row.id] != row.depth: changed.append(row.id)
	for constraint: Dictionary in constraints:
		var a: Dictionary = ordered[constraint.a]
		var b: Dictionary = ordered[constraint.b]
		constraint["finalOverlap"] = _overlap(a,b,depths[a.id],depths[b.id],constraint.overhangA,constraint.overhangB,constraint.boundaryA,constraint.boundaryB)
		constraint.erase("a")
		constraint.erase("b")
	return {"ready":true,"rowDepths":depths,"constraints":constraints,"changedRowIds":changed,"originalDepthReductions":reductions,"roundingSteps":rounding_steps,"rowCount":ordered.size(),"envelopeCount":envelope_count}

static func _bounds(row: Dictionary, depth: float, overhang: float, boundary_thickness := 0.0) -> Array:
	var size := _f32(depth+2.0*overhang)
	if not is_finite(size) or size <= 0.0: return []
	var center: float = row.centerZ
	var scalar_low := center-size*0.5
	var scalar_high := center+size*0.5
	var position := Vector3(0,0,center)-Vector3(0,0,size)*0.5
	var box := AABB(position,Vector3(1,1,size))
	var low := minf(center-depth*0.5-overhang,minf(scalar_low,position.z))
	var high := maxf(center+depth*0.5+overhang,maxf(scalar_high,box.end.z))
	# End slabs round their centers separately from a full-depth wall. Include
	# those actual represented faces, not an epsilon or an arbitrary margin.
	if boundary_thickness > 0.0:
		var stored_thickness := _f32(boundary_thickness)
		if not is_finite(stored_thickness) or stored_thickness <= 0.0: return []
		for side in [-1.0,1.0]:
			var end_center := _f32(center+side*(depth*0.5+overhang-boundary_thickness*0.5))
			if not is_finite(end_center): return []
			var end_box := AABB(Vector3(0,0,end_center)-Vector3(0,0,stored_thickness)*0.5,Vector3(1,1,stored_thickness))
			low=minf(low,minf(end_center-stored_thickness*0.5,end_box.position.z))
			high=maxf(high,maxf(end_center+stored_thickness*0.5,end_box.end.z))
	return [low,high]

static func _overlap(a: Dictionary,b: Dictionary,da: float,db: float,oa: float,ob: float,ta := 0.0,tb := 0.0) -> float:
	var ba := _bounds(a,da,oa,ta)
	var bb := _bounds(b,db,ob,tb)
	if ba.is_empty() or bb.is_empty(): return INF
	return ba[1]-bb[0] if a.centerZ <= b.centerZ else bb[1]-ba[0]

static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

static func _f32(value: float) -> float:
	return float(Vector3(0,0,value).z)

static func _inward(value: float) -> float:
	if value <= 0.0: return value
	var represented := _f32(value)
	return _previous_positive_float(represented) if represented > value else represented

static func _previous_positive_float(value: float) -> float:
	if value <= 0.0 or not is_finite(value): return 0.0
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0,value)
	var bits := bytes.decode_u32(0)
	if bits == 0: return 0.0
	bytes.encode_u32(0,bits-1)
	return bytes.decode_float(0)

static func _fail(reason: String, row_id := "") -> Dictionary:
	return {"ready":false,"reason":reason,"rowId":row_id}
