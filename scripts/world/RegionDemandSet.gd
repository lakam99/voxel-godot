extends RefCounted

## Pure sets of existing publication-grid units. These retain obligations;
## they never infer source geometry or acknowledge terrain/navigation readiness.
static func from_regions(regions: Array, step: int, limit: int, margin := 0) -> Dictionary:
	if step < 1 or step > 512 or limit < 1 or limit > 512 or margin < 0 or margin > 32:
		return {"status":"failed","reason":"invalid_demand_grid"}
	var keys: Dictionary = {}
	for value in regions:
		if not value is Rect2i or not valid_bounds(value):
			return {"status":"failed","reason":"invalid_dependency_bounds"}
		var bounds: Rect2i = value.grow(margin)
		var low: Vector2i = Vector2i(floori(float(bounds.position.x)/step),floori(float(bounds.position.y)/step))
		var high: Vector2i = Vector2i(floori(float(bounds.end.x-1)/step),floori(float(bounds.end.y-1)/step))
		for z: int in range(low.y,high.y+1):
			for x: int in range(low.x,high.x+1):
				keys[Vector2i(x,z)] = true
				if keys.size() > limit: return {"status":"pending","reason":"region_dependency_capacity"}
	return {"status":"ready","keys":keys,"regions":rectangles(keys,step)}

static func contains(held: Dictionary, required: Dictionary) -> bool:
	for key: Vector2i in required:
		if not held.has(key): return false
	return true

## Compress only exact occupied grid runs. Never fill a gap between islands.
## Each output remains compatible with the providers' 512-cell bounds limit.
static func rectangles(keys: Dictionary, step: int) -> Array[Rect2i]:
	var ordered: Array = keys.keys()
	ordered.sort_custom(func(a: Vector2i,b: Vector2i): return a.y<b.y if a.y!=b.y else a.x<b.x)
	var maximum: int = maxi(1,512/step)
	var runs: Array[Rect2i] = []
	for key: Vector2i in ordered:
		if not runs.is_empty():
			var last: Rect2i = runs.back()
			if last.position.y==key.y and last.end.x==key.x and last.size.x<maximum:
				last.size.x += 1
				runs[runs.size()-1] = last
				continue
		runs.append(Rect2i(key,Vector2i.ONE))
	var result: Array[Rect2i] = []
	var tails: Dictionary = {}
	for run: Rect2i in runs:
		var shape: Vector2i = Vector2i(run.position.x,run.size.x)
		var index: int = int(tails.get(shape,-1))
		if index>=0 and result[index].end.y==run.position.y and result[index].size.y<maximum:
			var rectangle: Rect2i = result[index]
			rectangle.size.y += 1
			result[index] = rectangle
		else:
			tails[shape] = result.size()
			result.append(run)
	for index: int in range(result.size()):
		result[index] = Rect2i(result[index].position*step,result[index].size*step)
	return result

static func valid_bounds(bounds: Rect2i) -> bool:
	return bounds.size.x>0 and bounds.size.y>0 and bounds.size.x<=512 and bounds.size.y<=512 \
		and bounds.position.x>=-999968 and bounds.position.y>=-999968 \
		and bounds.position.x<=999968-bounds.size.x and bounds.position.y<=999968-bounds.size.y
