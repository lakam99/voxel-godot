extends RefCounted
## Read-only query acceleration for one selection. Boxes and paving arithmetic
## retain the existing source-space interpretation, including ignored rotation.
const CELL := 8.0
var paving: Array = []
var sites := {"cells":{},"overflow":[],"all":[],"references":0}
var samples := {"cells":{},"overflow":[],"all":[],"references":0}

func add_bounds(index: Dictionary, bounds: AABB) -> void:
	index.all.append(bounds)
	if not _bounded(bounds) or bounds.size.x<0 or bounds.size.z<0:
		index.overflow.append(bounds); return
	var low := Vector2i(floori(bounds.position.x/CELL),floori(bounds.position.z/CELL))
	var high := Vector2i(floori(bounds.end.x/CELL),floori(bounds.end.z/CELL))
	var count := (high.x-low.x+1)*(high.y-low.y+1)
	if count>4096 or index.references+count>500000:
		index.overflow.append(bounds); return
	for x in range(low.x,high.x+1):
		for z in range(low.y,high.y+1):
			var key := Vector2i(x,z)
			if not index.cells.has(key): index.cells[key]=[]
			index.cells[key].append(bounds)
	index.references+=count

func open_bounds(index: Dictionary, query: AABB) -> bool:
	if not _bounded(query):
		for bounds: AABB in index.all:
			if bounds.intersects(query): return false
		return true
	for bounds: AABB in index.overflow:
		if bounds.intersects(query): return false
	var low := Vector2i(floori(query.position.x/CELL),floori(query.position.z/CELL))
	var high := Vector2i(floori(query.end.x/CELL),floori(query.end.z/CELL))
	for x in range(low.x,high.x+1):
		for z in range(low.y,high.y+1):
			for bounds: AABB in index.cells.get(Vector2i(x,z),[]):
				if bounds.intersects(query): return false
	return true

func _bounded(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.end.is_finite() and absf(bounds.position.x)<=1000000 and absf(bounds.position.z)<=1000000 and absf(bounds.end.x)<=1000000 and absf(bounds.end.z)<=1000000

func site_open(position: Vector3) -> bool:
	return open_bounds(sites,AABB(position-Vector3(1.90,0.05,1.90),Vector3(3.80,8.0,3.80)))

func sample_open(point: Vector3) -> bool:
	return open_bounds(samples,AABB(point-Vector3(0.72,0.02,0.72),Vector3(1.44,2.40,1.44)))

func surface_at(point: Vector3) -> Vector3:
	for part: Dictionary in paving:
		var half: Vector3=part.size*0.5
		if point.x<part.position.x-half.x or point.x>part.position.x+half.x or point.z<part.position.z-half.z or point.z>part.position.z+half.z: continue
		return Vector3(point.x,part.position.y+half.y+0.04,point.z)
	return Vector3.INF

func clear_run(position: Vector3) -> bool:
	for direction in [Vector3(-1,0,0),Vector3(1,0,0),Vector3(0,0,-1),Vector3(0,0,1)]:
		var shaded := surface_at(position+direction*2.1)
		var open := surface_at(position+direction*6.2)
		if shaded!=Vector3.INF and open!=Vector3.INF and sample_open(shaded) and sample_open(open): return true
	return false
