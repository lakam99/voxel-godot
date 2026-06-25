extends RefCounted
class_name LocalAStarPlanner

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var last_expansions := 0

func start_job(graph: Dictionary, start_key: String, goal_keys: Array, cost_model, request, profile = null, allowed_tiles: Array = []) -> Dictionary:
	var goal_lookup := {}
	for goal_key in goal_keys:
		goal_lookup[String(goal_key)] = true
	return {
		"graph": graph,
		"start": start_key,
		"goals": goal_lookup,
		"allowedTiles": allowed_tiles.duplicate(),
		"open": [start_key],
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

func step(job: Dictionary, max_expansions := 128) -> Dictionary:
	last_expansions = 0
	var graph: Dictionary = job.get("graph", {})
	var open: Array = job.get("open", [])
	var goals: Dictionary = job.get("goals", {})
	if open.is_empty():
		return _finish_without_open(job)
	var budget := maxi(1, max_expansions)
	while not open.is_empty() and last_expansions < budget:
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
				if not open.has(to_key):
					open.append(to_key)
	if open.is_empty():
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
		return result
	return {
		"status": NpcEnumsScript.ROUTE_STATUS_UNREACHABLE,
		"reason": NpcEnumsScript.ROUTE_REASON_NO_ROUTE,
		"path": [],
		"edges": [],
		"breakdowns": [],
		"expansions": last_expansions
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
	var open: Array = job.get("open", [])
	var graph: Dictionary = job.get("graph", {})
	var goals: Dictionary = job.get("goals", {})
	var best_index := -1
	var best_score := INF
	var best_cost := INF
	var best_key := ""
	for i in range(open.size()):
		var key := String(open[i])
		var cost := float((job.get("costSoFar", {}) as Dictionary).get(key, INF))
		var heuristic := 0.0
		var score := cost + heuristic
		if score < best_score or (is_equal_approx(score, best_score) and (cost < best_cost or (is_equal_approx(cost, best_cost) and key < best_key))):
			best_index = i
			best_score = score
			best_cost = cost
			best_key = key
	if best_index < 0:
		return ""
	open.remove_at(best_index)
	return best_key

func _sorted_edges(graph: Dictionary, from_key: String) -> Array:
	var edges: Array = (graph.get("edges", {}) as Dictionary).get(from_key, [])
	edges.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_key := "%s:%s" % [String(a.get("toKey", "")), String(a.get("kind", ""))]
		var b_key := "%s:%s" % [String(b.get("toKey", "")), String(b.get("kind", ""))]
		return a_key < b_key
	)
	return edges

func _tile_allowed(job: Dictionary, edge_record: Dictionary) -> bool:
	var allowed: Array = job.get("allowedTiles", [])
	if allowed.is_empty():
		return true
	var to_tile := String(edge_record.get("toTile", ""))
	var from_tile := String(edge_record.get("fromTile", ""))
	return allowed.has(to_tile) and allowed.has(from_tile)

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

func stats() -> Dictionary:
	return { "lastExpansions": last_expansions }
