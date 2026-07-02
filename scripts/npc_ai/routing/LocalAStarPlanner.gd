extends RefCounted
class_name LocalAStarPlanner

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var last_expansions := 0

func start_job(graph: Dictionary, start_key: String, goal_keys: Array, cost_model, request, profile = null, allowed_tiles: Array = []) -> Dictionary:
	var goal_lookup := {}
	for goal_key in goal_keys:
		goal_lookup[String(goal_key)] = true
	var allowed_tile_lookup := {}
	for tile_value in allowed_tiles:
		allowed_tile_lookup[String(tile_value)] = true
	var job := {
		"graph": graph,
		"start": start_key,
		"goals": goal_lookup,
		"allowedTiles": allowed_tiles.duplicate(),
		"allowedTileLookup": allowed_tile_lookup,
		"open": [],
		"openHeap": [],
		"closed": {},
		"cameFrom": {},
		"cameEdge": {},
		"cameBreakdown": {},
		"costSoFar": { start_key: 0.0 },
		"bestKey": start_key,
		"bestGoalDistance": _goal_distance(graph, start_key, goal_lookup),
		"costModel": cost_model,
		"request": request,
		"profile": profile,
		"expansions": 0
	}
	_heap_push(job, start_key, 0.0, 0.0)
	return job

func step(job: Dictionary, max_expansions := 128, max_usec := 0) -> Dictionary:
	last_expansions = 0
	var graph: Dictionary = job.get("graph", {})
	var goals: Dictionary = job.get("goals", {})
	if _open_empty(job):
		return _finish_without_open(job)
	var budget := maxi(1, max_expansions)
	var step_start_usec := Time.get_ticks_usec()
	while not _open_empty(job) and last_expansions < budget:
		var current := _pop_best_open(job)
		if current == "":
			break
		if goals.has(current):
			return _complete(job, current)
		(job["closed"] as Dictionary)[current] = true
		last_expansions += 1
		job["expansions"] = int(job.get("expansions", 0)) + 1
		var distance := _goal_distance(graph, current, goals)
		var previous_best := float(job.get("bestGoalDistance", INF))
		if distance < previous_best or (is_equal_approx(distance, previous_best) and current < String(job.get("bestKey", ""))):
			job["bestGoalDistance"] = distance
			job["bestKey"] = current
		for edge_record in _sorted_edges(graph, current):
			var to_key := String(edge_record.get("toKey", ""))
			if to_key == "" or (job["closed"] as Dictionary).has(to_key):
				continue
			if not _tile_allowed(job, edge_record):
				continue
			var breakdown: Dictionary = job.get("costModel").edge_cost(edge_record, job.get("request"), job.get("profile"))
			var new_cost := float((job["costSoFar"] as Dictionary).get(current, 0.0)) + float(breakdown.get("total", 0.0))
			if not (job["costSoFar"] as Dictionary).has(to_key) or new_cost < float((job["costSoFar"] as Dictionary).get(to_key, INF)):
				(job["costSoFar"] as Dictionary)[to_key] = new_cost
				(job["cameFrom"] as Dictionary)[to_key] = current
				(job["cameEdge"] as Dictionary)[to_key] = edge_record
				(job["cameBreakdown"] as Dictionary)[to_key] = breakdown
				_heap_push(job, to_key, new_cost, new_cost)
		if max_usec > 0 and last_expansions > 0 and Time.get_ticks_usec() - step_start_usec >= max_usec:
			break
	if _open_empty(job):
		return _finish_without_open(job)
	return {
		"status": NpcEnumsScript.ROUTE_STATUS_PENDING,
		"reason": &"pending_budget",
		"expansions": last_expansions
	}

func _finish_without_open(job: Dictionary) -> Dictionary:
	var request = job.get("request")
	var allow_partial := bool(request.get("allow_partial")) if request != null else false
	var best_key := String(job.get("bestKey", ""))
	if allow_partial and best_key != "" and best_key != String(job.get("start", "")) and (job.get("cameFrom", {}) as Dictionary).has(best_key):
		var result := _complete(job, best_key)
		result["status"] = NpcEnumsScript.ROUTE_STATUS_PARTIAL
		result["reason"] = NpcEnumsScript.ROUTE_REASON_PARTIAL_ONLY
		result["closedCount"] = (job.get("closed", {}) as Dictionary).size()
		result["bestKey"] = best_key
		result["bestGoalDistance"] = _report_distance(float(job.get("bestGoalDistance", INF)))
		return result
	return {
		"status": NpcEnumsScript.ROUTE_STATUS_UNREACHABLE,
		"reason": NpcEnumsScript.ROUTE_REASON_NO_ROUTE,
		"path": [],
		"edges": [],
		"breakdowns": [],
		"expansions": last_expansions,
		"closedCount": (job.get("closed", {}) as Dictionary).size(),
		"bestKey": best_key,
		"bestGoalDistance": _report_distance(float(job.get("bestGoalDistance", INF)))
	}

func _complete(job: Dictionary, goal_key: String) -> Dictionary:
	var path: Array[String] = [goal_key]
	var edges: Array = []
	var breakdowns: Array = []
	var cursor := goal_key
	var came_from: Dictionary = job.get("cameFrom", {})
	while came_from.has(cursor):
		edges.push_front((job.get("cameEdge", {}) as Dictionary).get(cursor, {}))
		breakdowns.push_front((job.get("cameBreakdown", {}) as Dictionary).get(cursor, {}))
		cursor = String(came_from[cursor])
		path.push_front(cursor)
	return {
		"status": NpcEnumsScript.ROUTE_STATUS_COMPLETE,
		"reason": NpcEnumsScript.ROUTE_REASON_NONE,
		"path": path,
		"edges": edges,
		"breakdowns": breakdowns,
		"cost": float((job.get("costSoFar", {}) as Dictionary).get(goal_key, 0.0)),
		"expansions": last_expansions
	}

func _pop_best_open(job: Dictionary) -> String:
	var heap: Array = job.get("openHeap", [])
	while not heap.is_empty():
		var item: Dictionary = _heap_pop(job)
		var key := String(item.get("key", ""))
		if key == "" or (job["closed"] as Dictionary).has(key):
			continue
		var item_cost := float(item.get("cost", INF))
		var current_cost := float((job.get("costSoFar", {}) as Dictionary).get(key, INF))
		if item_cost > current_cost + 0.0001:
			continue
		return key
	return ""

func _open_empty(job: Dictionary) -> bool:
	var heap: Array = job.get("openHeap", [])
	return heap.is_empty()

func _heap_push(job: Dictionary, key: String, score: float, cost: float) -> void:
	var heap: Array = job.get("openHeap", [])
	heap.append({
		"key": key,
		"score": score,
		"cost": cost
	})
	job["openHeap"] = heap
	var index := heap.size() - 1
	while index > 0:
		var parent := int((index - 1) / 2)
		if not _heap_less(heap[index], heap[parent]):
			break
		_heap_swap(heap, index, parent)
		index = parent

func _heap_pop(job: Dictionary) -> Dictionary:
	var heap: Array = job.get("openHeap", [])
	if heap.is_empty():
		return {}
	var result: Dictionary = heap[0]
	var tail = heap.pop_back()
	if not heap.is_empty():
		heap[0] = tail
		var index := 0
		while true:
			var left := index * 2 + 1
			var right := left + 1
			var smallest := index
			if left < heap.size() and _heap_less(heap[left], heap[smallest]):
				smallest = left
			if right < heap.size() and _heap_less(heap[right], heap[smallest]):
				smallest = right
			if smallest == index:
				break
			_heap_swap(heap, index, smallest)
			index = smallest
	job["openHeap"] = heap
	return result

func _heap_less(a, b) -> bool:
	var a_score := float((a as Dictionary).get("score", INF))
	var b_score := float((b as Dictionary).get("score", INF))
	if not is_equal_approx(a_score, b_score):
		return a_score < b_score
	var a_cost := float((a as Dictionary).get("cost", INF))
	var b_cost := float((b as Dictionary).get("cost", INF))
	if not is_equal_approx(a_cost, b_cost):
		return a_cost < b_cost
	return String((a as Dictionary).get("key", "")) < String((b as Dictionary).get("key", ""))

func _heap_swap(heap: Array, a: int, b: int) -> void:
	var value = heap[a]
	heap[a] = heap[b]
	heap[b] = value

func _sorted_edges(graph: Dictionary, from_key: String) -> Array:
	var edges: Array = (graph.get("edges", {}) as Dictionary).get(from_key, [])
	edges.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_key := "%s:%s" % [String(a.get("toKey", "")), String(a.get("kind", ""))]
		var b_key := "%s:%s" % [String(b.get("toKey", "")), String(b.get("kind", ""))]
		return a_key < b_key
	)
	return edges

func _tile_allowed(job: Dictionary, edge_record: Dictionary) -> bool:
	var allowed_lookup: Dictionary = job.get("allowedTileLookup", {})
	if allowed_lookup.is_empty():
		return true
	var to_tile := String(edge_record.get("toTile", ""))
	var from_tile := String(edge_record.get("fromTile", ""))
	return allowed_lookup.has(to_tile) and allowed_lookup.has(from_tile)

func _goal_distance(graph: Dictionary, key: String, goals: Dictionary) -> float:
	var nodes: Dictionary = graph.get("nodes", {})
	if not nodes.has(key):
		return INF
	var from_span = nodes[key]
	var from_pos: Vector3 = from_span.get("world_position")
	var best := INF
	for goal_key in goals.keys():
		if not nodes.has(goal_key):
			continue
		var goal_span = nodes[goal_key]
		var goal_pos: Vector3 = goal_span.get("world_position")
		best = minf(best, from_pos.distance_to(goal_pos))
	return best

func _report_distance(value: float) -> float:
	return value if value < INF else -1.0

func stats() -> Dictionary:
	return { "lastExpansions": last_expansions }
