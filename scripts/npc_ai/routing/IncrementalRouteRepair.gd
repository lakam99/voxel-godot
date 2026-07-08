extends RefCounted
class_name IncrementalRouteRepair

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const RouteResultScript := preload("res://scripts/npc_ai/contracts/RouteResult.gd")
const RouteCostModelScript := preload("res://scripts/npc_ai/routing/RouteCostModel.gd")
const RouteCorridorBuilderScript := preload("res://scripts/npc_ai/routing/RouteCorridorBuilder.gd")

const INF_COST := 1.0e20

var planner = null
var cost_model = RouteCostModelScript.new()
var corridor_builder = RouteCorridorBuilderScript.new()
var active_routes := {}
var index_by_tile := {}
var index_by_edge := {}
var index_by_portal := {}
var index_by_object := {}
var failure_counts := {}
var failure_order: Array[String] = []
var last_stats := {}

func setup(route_planner = null) -> void:
	planner = route_planner

func clear() -> void:
	active_routes.clear()
	index_by_tile.clear()
	index_by_edge.clear()
	index_by_portal.clear()
	index_by_object.clear()
	failure_counts.clear()
	failure_order.clear()
	last_stats.clear()

func register_route(route_id: String, graph: Dictionary, start_key: String, goal_keys: Array, request, corridor = null, initial_changes: Array = []) -> Dictionary:
	var state := {
		"routeId": route_id,
		"graph": graph,
		"start": start_key,
		"lastStart": start_key,
		"goals": _goal_lookup(goal_keys),
		"goalKeys": _string_array(goal_keys),
		"request": request,
		"generation": int(request.get("cancellation_generation")) if request != null else 0,
		"g": {},
		"rhs": {},
		"queue": {},
		"km": 0.0,
		"predecessors": _build_predecessors(graph),
		"edgeOverrides": {},
		"blockedEdges": {},
		"dependencies": _dependencies_from_corridor(corridor, graph),
		"metrics": {
			"repairCount": 0,
			"fullReplans": 0,
			"lastExpansions": 0,
			"changedVertices": 0,
			"reusedState": false
		}
	}
	_add_target_dependency(state["dependencies"], request)
	active_routes[route_id] = state
	_apply_edge_changes(state, initial_changes)
	for goal_key in state["goalKeys"]:
		_set_rhs(state, String(goal_key), 0.0)
		_queue_insert(state, String(goal_key))
	_compute_shortest_path(state, NpcConstantsScript.ROUTE_SEARCH_COMPATIBILITY_EXPANSIONS)
	_reindex_route(route_id)
	return state_summary(route_id)

func index_result(route_id: String, result) -> void:
	if result == null:
		return
	var deps := {}
	if result.get("corridor") != null:
		deps = result.get("corridor").dependencies.duplicate(true)
	else:
		var metrics = result.get("metrics")
		if metrics is Dictionary:
			deps = (metrics as Dictionary).get("dependencies", {})
	_add_target_dependency(deps, result.get("repair_request"))
	active_routes[route_id] = {
		"routeId": route_id,
		"dependencies": deps,
		"generation": int(result.get("generation")),
		"indexedOnly": true
	}
	_reindex_route(route_id)

func unregister_route(route_id: String) -> void:
	active_routes.erase(route_id)
	_remove_from_indexes(route_id)

func classify_event(route_id: String, event: Dictionary) -> StringName:
	var state: Dictionary = active_routes.get(route_id, {})
	if state.is_empty():
		return NpcEnumsScript.REPAIR_CLASS_IRRELEVANT
	return _classify_for_state(state, event)

func routes_for_event(event: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var tile_key: String = String(event.get("tileKey", ""))
	if tile_key != "":
		for route_id in index_by_tile.get(tile_key, []):
			if not result.has(String(route_id)):
				result.append(String(route_id))
	for object_id in event.get("objectIds", []):
		var object_text: String = String(object_id)
		for route_id in index_by_portal.get(object_text, []):
			if not result.has(String(route_id)):
				result.append(String(route_id))
		for route_id in index_by_object.get(object_text, []):
			if not result.has(String(route_id)):
				result.append(String(route_id))
	for edge_id in event.get("edgeIds", []):
		for route_id in index_by_edge.get(String(edge_id), []):
			if not result.has(String(route_id)):
				result.append(String(route_id))
	result.sort()
	return result

func repair_after_event(route_id: String, event: Dictionary, changes := {}, max_expansions := 128) -> Dictionary:
	var state: Dictionary = active_routes.get(route_id, {})
	if state.is_empty():
		return _response(route_id, NpcEnumsScript.REPAIR_STATUS_UNCHANGED, NpcEnumsScript.REPAIR_CLASS_IRRELEVANT, &"missing_route")
	if bool(state.get("indexedOnly", false)):
		return _response(route_id, NpcEnumsScript.REPAIR_STATUS_WAITING, classify_event(route_id, event), &"indexed_only")
	var event_generation: int = int(changes.get("generation", state.get("generation", 0)))
	if event_generation != int(state.get("generation", 0)):
		return _response(route_id, NpcEnumsScript.REPAIR_STATUS_FAILED, classify_event(route_id, event), NpcEnumsScript.ROUTE_REASON_STALE_GENERATION, {
			"staleGenerationRejected": true
		})
	var classification: StringName = _classify_for_state(state, event)
	if classification == NpcEnumsScript.REPAIR_CLASS_IRRELEVANT:
		return _response(route_id, NpcEnumsScript.REPAIR_STATUS_UNCHANGED, classification, NpcEnumsScript.ROUTE_REASON_NONE, {
			"generation": int(state.get("generation", 0)),
			"fullReplans": int((state.get("metrics", {}) as Dictionary).get("fullReplans", 0))
		})
	if classification == NpcEnumsScript.REPAIR_CLASS_ACTION_PREMISE:
		return _response(route_id, NpcEnumsScript.REPAIR_STATUS_ACTION_REVISION, classification, NpcEnumsScript.ROUTE_REASON_TARGET_GONE, {
			"actionPremiseInvalid": true,
			"safeStopRequired": true
		})
	if classification == NpcEnumsScript.REPAIR_CLASS_TOPOLOGY_UNAVAILABLE:
		return _response(route_id, NpcEnumsScript.REPAIR_STATUS_WAITING, classification, NpcEnumsScript.ROUTE_REASON_TOPOLOGY_UNAVAILABLE, {
			"safeStopRequired": true
		})
	var edge_changes: Array = changes.get("edgeChanges", [])
	if edge_changes.is_empty():
		edge_changes = changes_for_event(route_id, event)
	var changed_vertices: Array[String] = _apply_edge_changes(state, edge_changes)
	var move_start: String = String(changes.get("moveStart", ""))
	if move_start != "" and move_start != String(state.get("start", "")):
		var last_start: String = String(state.get("lastStart", state.get("start", "")))
		state["km"] = float(state.get("km", 0.0)) + _heuristic(state, last_start, move_start)
		state["lastStart"] = String(state.get("start", ""))
		state["start"] = move_start
	for vertex in changed_vertices:
		_update_vertex(state, vertex)
		for predecessor in (state.get("predecessors", {}) as Dictionary).get(vertex, []):
			_update_vertex(state, String(predecessor))
	var expansions: int = _compute_shortest_path(state, max_expansions)
	var metrics: Dictionary = state.get("metrics", {})
	metrics["repairCount"] = int(metrics.get("repairCount", 0)) + 1
	metrics["lastExpansions"] = expansions
	metrics["changedVertices"] = changed_vertices.size()
	metrics["reusedState"] = true
	metrics["fullReplans"] = int(metrics.get("fullReplans", 0))
	metrics["gCount"] = (state.get("g", {}) as Dictionary).size()
	metrics["rhsCount"] = (state.get("rhs", {}) as Dictionary).size()
	metrics["km"] = float(state.get("km", 0.0))
	state["metrics"] = metrics
	if not (state.get("queue", {}) as Dictionary).is_empty() and expansions >= max_expansions:
		return _response(route_id, NpcEnumsScript.REPAIR_STATUS_WAITING, classification, NpcEnumsScript.ROUTE_REASON_PENDING_BUDGET, _repair_metrics(state, changed_vertices, expansions, true))
	var start_key: String = String(state.get("start", ""))
	if _g(state, start_key) >= INF_COST * 0.5:
		var failure_key: String = _failure_key(route_id, event, classification)
		var count: int = _increment_failure(failure_key)
		var reason: StringName = NpcEnumsScript.ROUTE_REASON_REPAIR_LOOP_BOUND if count >= NpcConstantsScript.ROUTE_REPAIR_FAILURE_LIMIT else NpcEnumsScript.ROUTE_REASON_NO_ROUTE
		var status: StringName = NpcEnumsScript.REPAIR_STATUS_FAILED if count >= NpcConstantsScript.ROUTE_REPAIR_FAILURE_LIMIT else NpcEnumsScript.REPAIR_STATUS_WAITING
		return _response(route_id, status, classification, reason, _repair_metrics(state, changed_vertices, expansions, false, count))
	var route_result = _build_route_result(state)
	state["dependencies"] = route_result.corridor.dependencies.duplicate(true) if route_result.corridor != null else state.get("dependencies", {})
	_reindex_route(route_id)
	return _response(route_id, NpcEnumsScript.REPAIR_STATUS_REPAIRED, classification, NpcEnumsScript.ROUTE_REASON_NONE, _repair_metrics(state, changed_vertices, expansions, false), route_result)

func fresh_oracle(route_id: String) -> Dictionary:
	var state: Dictionary = active_routes.get(route_id, {})
	if state.is_empty():
		return { "status": String(NpcEnumsScript.ROUTE_STATUS_FAILED_INTERNAL), "cost": INF_COST, "path": [] }
	var start_key: String = String(state.get("start", ""))
	var goals: Dictionary = state.get("goals", {})
	var open: Array[String] = [start_key]
	var came_from := {}
	var cost_so_far := { start_key: 0.0 }
	var closed := {}
	while not open.is_empty():
		var current: String = _pop_oracle_open(state, open, cost_so_far, goals)
		if goals.has(current):
			var path: Array[String] = _reconstruct_path(start_key, current, came_from)
			return { "status": String(NpcEnumsScript.ROUTE_STATUS_COMPLETE), "cost": float(cost_so_far[current]), "path": path }
		closed[current] = true
		for edge_record in _successors(state, current):
			var to_key: String = String((edge_record as Dictionary).get("toKey", ""))
			if to_key == "" or closed.has(to_key):
				continue
			var new_cost: float = float(cost_so_far[current]) + _edge_cost(state, edge_record)
			if not cost_so_far.has(to_key) or new_cost < float(cost_so_far[to_key]):
				cost_so_far[to_key] = new_cost
				came_from[to_key] = current
				if not open.has(to_key):
					open.append(to_key)
	return { "status": String(NpcEnumsScript.ROUTE_STATUS_UNREACHABLE), "cost": INF_COST, "path": [] }

func edge_changes_for_node(route_id: String, node_key: String, blocked: bool) -> Array:
	var state: Dictionary = active_routes.get(route_id, {})
	if state.is_empty():
		return []
	var graph: Dictionary = state.get("graph", {})
	var result: Array = []
	for edge_record in (graph.get("edges", {}) as Dictionary).get(node_key, []):
		result.append({ "from": node_key, "to": String((edge_record as Dictionary).get("toKey", "")), "blocked": blocked })
	for from_key in (graph.get("edges", {}) as Dictionary).keys():
		for edge_record in (graph.get("edges", {}) as Dictionary)[from_key]:
			if String((edge_record as Dictionary).get("toKey", "")) == node_key:
				result.append({ "from": String(from_key), "to": node_key, "blocked": blocked })
	return result

func edge_changes_for_portal(route_id: String, portal_id: String, blocked: bool) -> Array:
	var state: Dictionary = active_routes.get(route_id, {})
	if state.is_empty():
		return []
	var graph: Dictionary = state.get("graph", {})
	var result: Array = []
	for from_key in (graph.get("edges", {}) as Dictionary).keys():
		for edge_record in (graph.get("edges", {}) as Dictionary)[from_key]:
			if String((edge_record as Dictionary).get("portalId", "")) == portal_id:
				result.append({
					"from": String((edge_record as Dictionary).get("fromKey", "")),
					"to": String((edge_record as Dictionary).get("toKey", "")),
					"blocked": blocked
				})
	return result

func changes_for_event(route_id: String, event: Dictionary) -> Array:
	var kinds: Array = event.get("changeKinds", [])
	if _has_any_kind(kinds, ["block_created"]):
		var node_key: String = _node_key_for_block_event(event)
		return edge_changes_for_node(route_id, node_key, true) if node_key != "" else []
	if _has_any_kind(kinds, ["block_removed"]):
		var node_key: String = _node_key_for_block_event(event)
		return edge_changes_for_node(route_id, node_key, false) if node_key != "" else []
	if _has_any_kind(kinds, ["door_locked"]):
		return _portal_changes_from_event(route_id, event, true)
	if _has_any_kind(kinds, ["door_unlocked", "door_state"]):
		return _portal_changes_from_event(route_id, event, false)
	return []

func state_summary(route_id: String) -> Dictionary:
	var state: Dictionary = active_routes.get(route_id, {})
	if state.is_empty():
		return {}
	return {
		"routeId": route_id,
		"generation": int(state.get("generation", 0)),
		"start": String(state.get("start", "")),
		"goalKeys": (state.get("goalKeys", []) as Array).duplicate(),
		"gCount": (state.get("g", {}) as Dictionary).size(),
		"rhsCount": (state.get("rhs", {}) as Dictionary).size(),
		"queueCount": (state.get("queue", {}) as Dictionary).size(),
		"km": float(state.get("km", 0.0)),
		"dependencies": (state.get("dependencies", {}) as Dictionary).duplicate(true),
		"metrics": (state.get("metrics", {}) as Dictionary).duplicate(true)
	}

func stats() -> Dictionary:
	return {
		"activeRoutes": active_routes.size(),
		"indexedTiles": index_by_tile.size(),
		"indexedEdges": index_by_edge.size(),
		"indexedPortals": index_by_portal.size(),
		"indexedObjects": index_by_object.size(),
		"failureCauses": failure_counts.size(),
		"last": last_stats.duplicate(true)
	}

func _goal_lookup(goal_keys: Array) -> Dictionary:
	var result := {}
	for goal_key in goal_keys:
		result[String(goal_key)] = true
	return result

func _string_array(values: Array) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(String(value))
	result.sort()
	return result

func _dependencies_from_corridor(corridor, graph: Dictionary) -> Dictionary:
	if corridor != null:
		var deps: Dictionary = corridor.dependencies.duplicate(true)
		return deps
	var tiles: Array = (graph.get("tiles", []) as Array).duplicate()
	tiles.sort()
	return { "tiles": tiles, "edges": [], "portals": [], "semantics": [] }

func _add_target_dependency(dependencies: Dictionary, request) -> void:
	var target_id: String = _target_object_id(request)
	if target_id == "":
		return
	if not dependencies.has("objects"):
		dependencies["objects"] = []
	if not (dependencies["objects"] as Array).has(target_id):
		(dependencies["objects"] as Array).append(target_id)
		(dependencies["objects"] as Array).sort()

func _build_predecessors(graph: Dictionary) -> Dictionary:
	var result := {}
	var edges: Dictionary = graph.get("edges", {})
	var from_keys := edges.keys()
	from_keys.sort()
	for from_key_value in from_keys:
		var from_key: String = String(from_key_value)
		for edge_record in edges[from_key_value]:
			var to_key: String = String((edge_record as Dictionary).get("toKey", ""))
			if not result.has(to_key):
				result[to_key] = []
			if not (result[to_key] as Array).has(from_key):
				(result[to_key] as Array).append(from_key)
	for key in result.keys():
		(result[key] as Array).sort()
	return result

func _classify_for_state(state: Dictionary, event: Dictionary) -> StringName:
	var dependencies: Dictionary = state.get("dependencies", {})
	var tile_key: String = String(event.get("tileKey", ""))
	var tile_hit: bool = tile_key != "" and (dependencies.get("tiles", []) as Array).has(tile_key)
	var portal_hit := false
	for object_id in event.get("objectIds", []):
		if (dependencies.get("portals", []) as Array).has(String(object_id)):
			portal_hit = true
			break
	var target_id: String = _target_object_id(state.get("request"))
	var target_hit := target_id != "" and (event.get("objectIds", []) as Array).has(target_id)
	var kinds: Array = event.get("changeKinds", [])
	if target_hit and _has_any_kind(kinds, ["prop_removed", "resource_removed", "smart_object_removed"]):
		return NpcEnumsScript.REPAIR_CLASS_ACTION_PREMISE
	if tile_hit and _has_any_kind(kinds, ["chunk_unloaded"]):
		return NpcEnumsScript.REPAIR_CLASS_TOPOLOGY_UNAVAILABLE
	if portal_hit or (tile_hit and _has_any_kind(kinds, ["door_state", "door_registered", "door_locked", "door_unlocked"])):
		return NpcEnumsScript.REPAIR_CLASS_ABSTRACT_PORTAL
	if tile_hit and _has_any_kind(kinds, ["block_created", "block_removed", "terrain_edit"]):
		return NpcEnumsScript.REPAIR_CLASS_LOCAL_EDGE
	if tile_hit and _has_any_kind(kinds, ["semantic_changed", "cost_changed", "hazard_changed"]):
		return NpcEnumsScript.REPAIR_CLASS_COST_ONLY
	return NpcEnumsScript.REPAIR_CLASS_IRRELEVANT

func _has_any_kind(kinds: Array, candidates: Array) -> bool:
	for kind in kinds:
		if candidates.has(String(kind)):
			return true
	return false

func _target_object_id(request) -> String:
	if request == null:
		return ""
	var spec = request.get("goal_spec")
	if spec is Dictionary:
		return String((spec as Dictionary).get("objectId", (spec as Dictionary).get("targetObjectId", "")))
	return ""

func _node_key_for_block_event(event: Dictionary) -> String:
	for object_id in event.get("objectIds", []):
		var text: String = String(object_id)
		if not text.begins_with("block:"):
			continue
		var remainder: String = text.substr(6)
		var cell_text: String = remainder.split(":")[0]
		var parts: PackedStringArray = cell_text.split(",")
		if parts.size() < 3:
			continue
		var cell := Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
		var tile_key: String = String(event.get("tileKey", ""))
		if tile_key == "":
			tile_key = _tile_key_for_cell(cell)
		# Runtime route graph nodes are flattened to the walkable XZ span at y=0.
		# Block events carry their authored block height, so using cell.y here
		# misses the node actually indexed by HierarchicalRoutePlanner.
		return "%s:%d,%d,%d:0" % [tile_key, cell.x, 0, cell.z]
	return ""

func _portal_changes_from_event(route_id: String, event: Dictionary, blocked: bool) -> Array:
	for object_id in event.get("objectIds", []):
		var portal_id: String = String(object_id)
		var changes: Array = edge_changes_for_portal(route_id, portal_id, blocked)
		if not changes.is_empty():
			return changes
	return []

func _tile_key_for_cell(cell: Vector3i) -> String:
	return "%d,%d" % [floori(float(cell.x) / float(NpcConstantsScript.NAV_TILE_CELL_SIZE)), floori(float(cell.z) / float(NpcConstantsScript.NAV_TILE_CELL_SIZE))]

func _apply_edge_changes(state: Dictionary, changes: Array) -> Array[String]:
	var changed: Array[String] = []
	for change in changes:
		var record: Dictionary = change
		var from_key: String = String(record.get("from", record.get("fromKey", "")))
		var to_key: String = String(record.get("to", record.get("toKey", "")))
		if from_key == "" or to_key == "":
			continue
		var key: String = _edge_key(from_key, to_key)
		if bool(record.get("blocked", false)):
			(state["blockedEdges"] as Dictionary)[key] = true
		else:
			(state["blockedEdges"] as Dictionary).erase(key)
		if record.has("cost"):
			(state["edgeOverrides"] as Dictionary)[key] = maxf(0.001, float(record.get("cost")))
		elif not bool(record.get("blocked", false)):
			(state["edgeOverrides"] as Dictionary).erase(key)
		if not changed.has(from_key):
			changed.append(from_key)
		if not changed.has(to_key):
			changed.append(to_key)
	changed.sort()
	return changed

func _compute_shortest_path(state: Dictionary, max_expansions: int) -> int:
	var expansions := 0
	var start_key: String = String(state.get("start", ""))
	var budget: int = maxi(1, max_expansions)
	while expansions < budget:
		var top_key: String = _queue_top(state)
		if top_key == "":
			break
		var top_priority: Array = (state.get("queue", {}) as Dictionary).get(top_key, [INF_COST, INF_COST])
		var start_priority: Array = _calculate_key(state, start_key)
		if not _key_less(top_priority, start_priority) and is_equal_approx(_rhs(state, start_key), _g(state, start_key)):
			break
		_queue_remove(state, top_key)
		var old_g: float = _g(state, top_key)
		var current_rhs: float = _rhs(state, top_key)
		if old_g > current_rhs:
			_set_g(state, top_key, current_rhs)
			for predecessor in (state.get("predecessors", {}) as Dictionary).get(top_key, []):
				_update_vertex(state, String(predecessor))
		else:
			_set_g(state, top_key, INF_COST)
			_update_vertex(state, top_key)
			for predecessor in (state.get("predecessors", {}) as Dictionary).get(top_key, []):
				_update_vertex(state, String(predecessor))
		expansions += 1
	return expansions

func _update_vertex(state: Dictionary, key: String) -> void:
	if not (state.get("goals", {}) as Dictionary).has(key):
		var best := INF_COST
		for edge_record in _successors(state, key):
			var to_key: String = String((edge_record as Dictionary).get("toKey", ""))
			best = minf(best, _edge_cost(state, edge_record) + _g(state, to_key))
		_set_rhs(state, key, best)
	_queue_remove(state, key)
	if not is_equal_approx(_g(state, key), _rhs(state, key)):
		_queue_insert(state, key)

func _queue_insert(state: Dictionary, key: String) -> void:
	(state["queue"] as Dictionary)[key] = _calculate_key(state, key)

func _queue_remove(state: Dictionary, key: String) -> void:
	(state["queue"] as Dictionary).erase(key)

func _queue_top(state: Dictionary) -> String:
	var queue: Dictionary = state.get("queue", {})
	var best := ""
	var best_key: Array = [INF_COST, INF_COST]
	var keys := queue.keys()
	keys.sort()
	for key_value in keys:
		var key: String = String(key_value)
		var candidate: Array = queue[key_value]
		if best == "" or _key_less(candidate, best_key):
			best = key
			best_key = candidate
	return best

func _calculate_key(state: Dictionary, key: String) -> Array:
	var value: float = minf(_g(state, key), _rhs(state, key))
	return [value + _heuristic(state, String(state.get("start", "")), key) + float(state.get("km", 0.0)), value]

func _key_less(a: Array, b: Array) -> bool:
	if float(a[0]) < float(b[0]) - 0.0001:
		return true
	if float(a[0]) > float(b[0]) + 0.0001:
		return false
	return float(a[1]) < float(b[1]) - 0.0001

func _successors(state: Dictionary, key: String) -> Array:
	var graph: Dictionary = state.get("graph", {})
	var result: Array = []
	for edge_record in (graph.get("edges", {}) as Dictionary).get(key, []):
		if _edge_cost(state, edge_record) < INF_COST * 0.5:
			result.append(edge_record)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("toKey", "")) < String(b.get("toKey", ""))
	)
	return result

func _edge_cost(state: Dictionary, edge_record: Dictionary) -> float:
	var from_key: String = String(edge_record.get("fromKey", ""))
	var to_key: String = String(edge_record.get("toKey", ""))
	var key: String = _edge_key(from_key, to_key)
	if (state.get("blockedEdges", {}) as Dictionary).has(key):
		return INF_COST
	if (state.get("edgeOverrides", {}) as Dictionary).has(key):
		return float((state.get("edgeOverrides", {}) as Dictionary)[key])
	var breakdown: Dictionary = cost_model.edge_cost(edge_record, state.get("request"), null)
	return float(breakdown.get("total", edge_record.get("baseCost", 1.0)))

func _edge_breakdown(state: Dictionary, edge_record: Dictionary) -> Dictionary:
	var breakdown: Dictionary = cost_model.edge_cost(edge_record, state.get("request"), null)
	var key: String = _edge_key(String(edge_record.get("fromKey", "")), String(edge_record.get("toKey", "")))
	if (state.get("edgeOverrides", {}) as Dictionary).has(key):
		var old_base: float = float(breakdown.get("base", 0.0))
		var new_base: float = float((state.get("edgeOverrides", {}) as Dictionary)[key])
		breakdown["base"] = new_base
		breakdown["total"] = maxf(0.0, float(breakdown.get("total", 0.0)) - old_base + new_base)
	return breakdown

func _edge_record_between(state: Dictionary, from_key: String, to_key: String) -> Dictionary:
	var graph: Dictionary = state.get("graph", {})
	for edge_record in (graph.get("edges", {}) as Dictionary).get(from_key, []):
		if String((edge_record as Dictionary).get("toKey", "")) == to_key:
			return (edge_record as Dictionary).duplicate(true)
	return {}

func _build_route_result(state: Dictionary):
	var start_key: String = String(state.get("start", ""))
	var goals: Dictionary = state.get("goals", {})
	var path: Array[String] = [start_key]
	var edges: Array = []
	var breakdowns: Array = []
	var cursor: String = start_key
	var visited := { cursor: true }
	var guard := 0
	var graph: Dictionary = state.get("graph", {})
	var nodes: Dictionary = graph.get("nodes", {})
	while not goals.has(cursor) and guard < nodes.size() + 1:
		var best_to := ""
		var best_cost := INF_COST
		var best_edge := {}
		for edge_record in _successors(state, cursor):
			var to_key: String = String((edge_record as Dictionary).get("toKey", ""))
			var candidate: float = _edge_cost(state, edge_record) + _g(state, to_key)
			if candidate < best_cost - 0.0001 or (is_equal_approx(candidate, best_cost) and to_key < best_to):
				best_to = to_key
				best_cost = candidate
				best_edge = edge_record
		if best_to == "" or visited.has(best_to):
			break
		visited[best_to] = true
		path.append(best_to)
		edges.append(best_edge)
		breakdowns.append(_edge_breakdown(state, best_edge))
		cursor = best_to
		guard += 1
	var request = state.get("request")
	var corridor = corridor_builder.build(state.get("graph", {}), path, edges, breakdowns, request, true)
	var result = RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_COMPLETE, NpcEnumsScript.ROUTE_REASON_NONE, int(state.get("generation", 0)))
	result.owner_npc_id = String(request.get("owner_npc_id")) if request != null else ""
	result.request_id = String(request.get("request_id")) if request != null else String(state.get("routeId", ""))
	result.cost = float(corridor.total_cost)
	result.metrics = {
		"repair": (state.get("metrics", {}) as Dictionary).duplicate(true),
		"dependencies": corridor.dependencies.duplicate(true),
		"path": path.duplicate()
	}
	result.corridor = corridor
	result.arrival_contract = corridor.arrival_contract
	return result

func _pop_oracle_open(state: Dictionary, open: Array[String], cost_so_far: Dictionary, goals: Dictionary) -> String:
	var best_index := 0
	var best_key := open[0]
	var best_score := INF_COST
	for i in range(open.size()):
		var key: String = open[i]
		var score: float = float(cost_so_far.get(key, INF_COST)) + _goal_distance(state, key, goals)
		if score < best_score - 0.0001 or (is_equal_approx(score, best_score) and key < best_key):
			best_index = i
			best_key = key
			best_score = score
	open.remove_at(best_index)
	return best_key

func _goal_distance(state: Dictionary, key: String, goals: Dictionary) -> float:
	var best := INF_COST
	for goal_key in goals.keys():
		best = minf(best, _heuristic(state, key, String(goal_key)))
	return best

func _reconstruct_path(start_key: String, goal_key: String, came_from: Dictionary) -> Array[String]:
	var result: Array[String] = [goal_key]
	var cursor: String = goal_key
	while cursor != start_key and came_from.has(cursor):
		cursor = String(came_from[cursor])
		result.push_front(cursor)
	return result

func _heuristic(state: Dictionary, from_key: String, to_key: String) -> float:
	var graph: Dictionary = state.get("graph", {})
	var nodes: Dictionary = graph.get("nodes", {})
	if not nodes.has(from_key) or not nodes.has(to_key):
		return 0.0
	var from_cell: Vector3i = nodes[from_key].get("cell")
	var to_cell: Vector3i = nodes[to_key].get("cell")
	return Vector2(float(to_cell.x - from_cell.x), float(to_cell.z - from_cell.z)).length()

func _g(state: Dictionary, key: String) -> float:
	return float((state.get("g", {}) as Dictionary).get(key, INF_COST))

func _rhs(state: Dictionary, key: String) -> float:
	return float((state.get("rhs", {}) as Dictionary).get(key, INF_COST))

func _set_g(state: Dictionary, key: String, value: float) -> void:
	(state["g"] as Dictionary)[key] = value

func _set_rhs(state: Dictionary, key: String, value: float) -> void:
	(state["rhs"] as Dictionary)[key] = value

func _edge_key(from_key: String, to_key: String) -> String:
	return "%s->%s" % [from_key, to_key]

func _response(route_id: String, status: StringName, classification: StringName, reason: StringName, metrics := {}, route_result = null) -> Dictionary:
	var response := {
		"routeId": route_id,
		"status": status,
		"classification": classification,
		"reason": reason,
		"routeResult": route_result,
		"metrics": metrics
	}
	last_stats = response.duplicate(true)
	return response

func _repair_metrics(state: Dictionary, changed_vertices: Array, expansions: int, pending: bool, failure_count := 0) -> Dictionary:
	var metrics: Dictionary = (state.get("metrics", {}) as Dictionary).duplicate(true)
	metrics["changedVertices"] = changed_vertices.duplicate()
	metrics["changedVertexCount"] = changed_vertices.size()
	metrics["expansions"] = expansions
	metrics["pending"] = pending
	metrics["failureCount"] = failure_count
	metrics["safeStopRequired"] = changed_vertices.size() > 0
	metrics["reusedState"] = true
	metrics["fullReplans"] = int(metrics.get("fullReplans", 0))
	return metrics

func _failure_key(route_id: String, event: Dictionary, classification: StringName) -> String:
	return "%s:%s:%s:%s" % [route_id, String(classification), String(event.get("tileKey", "")), str(event.get("revision", 0))]

func _increment_failure(key: String) -> int:
	var count: int = int(failure_counts.get(key, 0)) + 1
	failure_counts[key] = count
	failure_order.erase(key)
	failure_order.append(key)
	while failure_order.size() > NpcConstantsScript.ROUTE_REPAIR_FAILURE_HISTORY_CAPACITY:
		var evicted: String = String(failure_order.pop_front())
		failure_counts.erase(evicted)
	return count

func _reindex_route(route_id: String) -> void:
	_remove_from_indexes(route_id)
	var state: Dictionary = active_routes.get(route_id, {})
	var dependencies: Dictionary = state.get("dependencies", {})
	for tile in dependencies.get("tiles", []):
		_index(index_by_tile, String(tile), route_id)
	for edge in dependencies.get("edges", []):
		_index(index_by_edge, String(edge), route_id)
	for portal in dependencies.get("portals", []):
		_index(index_by_portal, String(portal), route_id)
	for object_id in dependencies.get("objects", []):
		_index(index_by_object, String(object_id), route_id)

func _remove_from_indexes(route_id: String) -> void:
	for index in [index_by_tile, index_by_edge, index_by_portal, index_by_object]:
		for key in index.keys():
			(index[key] as Array).erase(route_id)

func _index(index: Dictionary, key: String, route_id: String) -> void:
	if key == "":
		return
	if not index.has(key):
		index[key] = []
	if not (index[key] as Array).has(route_id):
		(index[key] as Array).append(route_id)
		(index[key] as Array).sort()
