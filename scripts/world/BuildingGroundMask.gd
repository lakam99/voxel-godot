extends RefCounted
## Source-worker raster of actual support faces and declared access clearance.
## Decorative extents never enter this calculation. Sample-node padding is the
## diagonal of one grid cell, so bilinear terrain samples enclose source faces.
const MAX_SAMPLES := 262144
const FAR := 1e12

static func build(manifest: Dictionary, apron: int, cell_size: float) -> Dictionary:
	var support_polygons: Array[PackedVector2Array] = []
	var clearance_polygons: Array[PackedVector2Array] = []
	for root: Dictionary in manifest.groundRoots:
		var polygon := PackedVector2Array()
		for point: Vector3 in root.corners: polygon.append(Vector2(point.x,point.z) / cell_size)
		support_polygons.append(polygon)
	for access in manifest.get("accessReservations", []):
		if not access is AABB or not access.position.is_finite() or not access.size.is_finite() or access.position.y < -0.0001:
			return {"ready":false,"reason":"unsupported_below_ground_clearance"}
		clearance_polygons.append(_rectangle(Vector2(access.position.x,access.position.z) / cell_size,Vector2(access.end.x,access.end.z) / cell_size))
	for tree: Dictionary in manifest.get("trees", []):
		# Raised recipe trees stand on published structure/planter surfaces, not
		# generated ground. Their visual elevation cannot lift/fill terrain.
		if tree.position.y > 0.06: continue
		if tree.position.y < -0.06 or not tree.get("trunkRadius") is float or tree.trunkRadius <= 0.0:
			return {"ready":false,"reason":"missing_tree_ground_support"}
		var center := Vector2(tree.position.x,tree.position.z) / cell_size
		support_polygons.append(_circle(center,float(tree.trunkRadius) / cell_size))
		for root: Dictionary in tree.rootButtressFootprints:
			# Convex hull of two circumscribed circles encloses the declared tapered
			# buttress footprint without inheriting its canopy's reservation bounds.
			var points := _circle(Vector2(root.start.x,root.start.z) / cell_size,float(root.radiusStart) / cell_size)
			points.append_array(_circle(Vector2(root.end.x,root.end.z) / cell_size,float(root.radiusEnd) / cell_size))
			support_polygons.append(Geometry2D.convex_hull(points))
	var minimum := Vector2(INF,INF)
	var maximum := Vector2(-INF,-INF)
	for polygons in [support_polygons,clearance_polygons]:
		for polygon in polygons:
			for point: Vector2 in polygon:
				if not point.is_finite() or absf(point.x) > 1000000.0 or absf(point.y) > 1000000.0:
					return {"ready":false,"reason":"unsupported_ground_mask_coordinates"}
				minimum = minimum.min(point)
				maximum = maximum.max(point)
	var low := Vector2i(floori(minimum.x),floori(minimum.y)) - Vector2i.ONE * 2
	var high := Vector2i(ceili(maximum.x),ceili(maximum.y)) + Vector2i.ONE * 3
	var core := Rect2i(low,high-low)
	var envelope := core.grow(apron)
	if envelope.size.x <= 0 or envelope.size.y <= 0 or int(envelope.size.x) * int(envelope.size.y) > MAX_SAMPLES:
		return {"ready":false,"reason":"ground_mask_sample_limit"}
	var support := PackedByteArray()
	support.resize(envelope.size.x * envelope.size.y)
	for polygon in support_polygons: _stamp(polygon,envelope,support)
	var grading := support.duplicate()
	for polygon in clearance_polygons: _stamp(polygon,envelope,grading)
	var distance := _distance_field(grading,envelope.size)
	return {"ready":true,"coreCells":core,"envelopeCells":envelope,"supportMask":support,"distanceCells":distance}

static func _rectangle(low: Vector2, high: Vector2) -> PackedVector2Array:
	return PackedVector2Array([low,Vector2(high.x,low.y),high,Vector2(low.x,high.y)])

static func _circle(center: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in range(16): points.append(center + Vector2.from_angle(TAU * index / 16.0) * radius / cos(PI / 16.0))
	return points

static func _stamp(polygon: PackedVector2Array, envelope: Rect2i, mask: PackedByteArray) -> void:
	var low := Vector2(INF,INF)
	var high := Vector2(-INF,-INF)
	for point in polygon:
		low = low.min(point)
		high = high.max(point)
	for z in range(maxi(envelope.position.y,floori(low.y)-2),mini(envelope.end.y,ceili(high.y)+3)):
		for x in range(maxi(envelope.position.x,floori(low.x)-2),mini(envelope.end.x,ceili(high.x)+3)):
			var point := Vector2(x,z)
			var covered := Geometry2D.is_point_in_polygon(point,polygon)
			if not covered:
				for edge in range(polygon.size()):
					if point.distance_squared_to(Geometry2D.get_closest_point_to_segment(point,polygon[edge],polygon[(edge+1)%polygon.size()])) <= 2.00001:
						covered = true
						break
			if covered: mask[(z-envelope.position.y)*envelope.size.x+x-envelope.position.x] = 1

static func _distance_field(mask: PackedByteArray, size: Vector2i) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(mask.size())
	var line := PackedFloat64Array()
	line.resize(size.x)
	for z in range(size.y):
		for x in range(size.x): line[x] = 0.0 if mask[z*size.x+x] != 0 else FAR
		var row := _squared_distance(line)
		for x in range(size.x): values[z*size.x+x] = row[x]
	line.resize(size.y)
	for x in range(size.x):
		for z in range(size.y): line[z] = values[z*size.x+x]
		var column := _squared_distance(line)
		for z in range(size.y): values[z*size.x+x] = sqrt(column[z])
	return values

static func _squared_distance(values: PackedFloat64Array) -> PackedFloat64Array:
	# Lower envelope of equal-curvature parabolas; two separable passes yield
	# exact Euclidean distance to marked grid nodes in linear time.
	var n := values.size()
	var sites := PackedInt32Array()
	sites.resize(n)
	var boundaries := PackedFloat64Array()
	boundaries.resize(n+1)
	boundaries[0] = -INF
	boundaries[1] = INF
	var last := 0
	for q in range(1,n):
		var crossing := ((values[q]+q*q)-(values[sites[last]]+sites[last]*sites[last])) / float(2*(q-sites[last]))
		while crossing <= boundaries[last]:
			last -= 1
			crossing = ((values[q]+q*q)-(values[sites[last]]+sites[last]*sites[last])) / float(2*(q-sites[last]))
		last += 1
		sites[last] = q
		boundaries[last] = crossing
		boundaries[last+1] = INF
	var output := PackedFloat64Array()
	output.resize(n)
	last = 0
	for q in range(n):
		while boundaries[last+1] < q: last += 1
		output[q] = (q-sites[last])*(q-sites[last]) + values[sites[last]]
	return output
