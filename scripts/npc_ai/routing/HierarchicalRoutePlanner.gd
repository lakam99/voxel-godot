extends RefCounted
class_name HierarchicalRoutePlanner

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const TraversalProfileScript := preload("res://scripts/npc_ai/contracts/TraversalProfile.gd")
const RouteRequestScript := preload("res://scripts/npc_ai/contracts/RouteRequest.gd")
const RouteResultScript := preload("res://scripts/npc_ai/contracts/RouteResult.gd")
const NavSpanDataScript := preload("res://scripts/npc_ai/contracts/NavSpanData.gd")
const NavEdgeDataScript := preload("res://scripts/npc_ai/contracts/NavEdgeData.gd")
const LocalAStarPlannerScript := preload("res://scripts/npc_ai/routing/LocalAStarPlanner.gd")
const RouteCostModelScript := preload("res://scripts/npc_ai/routing/RouteCostModel.gd")
const RouteCorridorBuilderScript := preload("res://scripts/npc_ai/routing/RouteCorridorBuilder.gd")
const TraversalCapabilityServiceScript := preload("res://scripts/npc_ai/routing/TraversalCapabilityService.gd")
const NavigationChangeBusScript := preload("res://scripts/npc_ai/navigation/NavigationChangeBus.gd")

var navigation_world = null
var local_planner = LocalAStarPlannerScript.new()
var cost_model = RouteCostModelScript.new()
var corridor_builder = RouteCorridorBuilderScript.new()
var capability_service = TraversalCapabilityServiceScript.new()
var active_jobs := {}
var active_job_order: Array[String] = []
var local_cost_cache := {}
var local_cost_cache_order: Array[String] = []
var runtime_graph_cache := {}
var runtime_graph_cache_order: Array[String] = []
var runtime_graph_build_jobs := {}
var last_stats := {}

const RUNTIME_GRAPH_CACHE_LIMIT := 48
const RUNTIME_GRAPH_SYNC_CELL_LIMIT := 16
const RUNTIME_GRAPH_BUILD_CELLS_INITIAL_CALL := 4
const RUNTIME_GRAPH_BUILD_CELLS_RESUME_CALL := 16
const RUNTIME_GRAPH_STEP_USEC_BUDGET := 1600
const RUNTIME_SEARCH_STEP_USEC_BUDGET := 1400
const EXTERNAL_DIRECT_GRAPH_STEP_USEC_BUDGET := 10000
const EXTERNAL_DIRECT_GRAPH_BUILD_CELLS_INITIAL_CALL := 16
const EXTERNAL_DIRECT_GRAPH_BUILD_CELLS_RESUME_CALL := 768
const FOREGROUND_RUNTIME_GRAPH_BUILD_UNITS := 8192
const RUNTIME_CARDINAL_EDGE_OFFSETS := [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1)
]
const RUNTIME_EDGE_OFFSETS := [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
	Vector2i(1, 1),
	Vector2i(1, -1),
	Vector2i(-1, 1),
	Vector2i(-1, -1)
]

func setup(nav_world = null) -> void:
	navigation_world = nav_world

func clear() -> void:
	active_jobs.clear()
	active_job_order.clear()
	local_cost_cache.clear()
	local_cost_cache_order.clear()
	runtime_graph_cache.clear()
	runtime_graph_cache_order.clear()
	runtime_graph_build_jobs.clear()
	last_stats.clear()

func plan_route(request, max_expansions := 4096):
	if request == null:
		return RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_FAILED_INTERNAL, &"missing_request")
	if int(request.get("cancelled_generation")) == int(request.get("cancellation_generation")):
		return _base_result(request, NpcEnumsScript.ROUTE_STATUS_CANCELLED, NpcEnumsScript.ROUTE_REASON_CANCELLED)
	var profile = _profile_for_request(request)
	var request_id := String(request.get("request_id"))
	if request_id == "":
		request_id = "route:%s:%s" % [String(request.get("owner_npc_id")), str(Time.get_ticks_usec())]
		request.set("request_id", request_id)
	var job_key := "%s:%d" % [request_id, int(request.get("cancellation_generation"))]
	if active_jobs.has(job_key):
		var active_job: Dictionary = active_jobs[job_key]
		var active_goal_lookup: Dictionary = active_job.get("goals", {})
		var active_goal_keys := []
		for goal_key_value in active_goal_lookup.keys():
			active_goal_keys.append(String(goal_key_value))
		return _step_route_job(
			request,
			job_key,
			active_job.get("graph", {}),
			String(active_job.get("start", "")),
			active_goal_keys,
			active_job.get("allowedTiles", []),
			{},
			profile,
			max_expansions
		)
	var graph: Dictionary = request.get("goal_spec").get("_graph", {}) if request.get("goal_spec") is Dictionary else {}
	if bool(graph.get("_pending", false)):
		return _base_result(request, NpcEnumsScript.ROUTE_STATUS_PENDING, &"pending_graph_build", {
			"graph": _route_pending_graph_metrics(graph, "", [], [])
		})
	if bool(graph.get("_yieldAfterBuild", false)):
		graph.erase("_yieldAfterBuild")
		return _base_result(request, NpcEnumsScript.ROUTE_STATUS_PENDING, &"pending_graph_build", {
			"graph": _route_pending_graph_metrics(graph, "", [], [])
		})
	if graph.is_empty():
		graph = build_graph(profile)
	var start_key := resolve_start_key(graph, request, profile)
	if start_key == "":
		return _base_result(request, NpcEnumsScript.ROUTE_STATUS_UNREACHABLE, &"no_start_span")
	var goal_keys := resolve_goal_keys(graph, request, profile)
	if goal_keys.is_empty():
		return _base_result(request, NpcEnumsScript.ROUTE_STATUS_UNREACHABLE, &"no_goal_span")
	var runtime_graph_request := _goal_spec(request).has("_graph")
	var hierarchy := {
		"tileCount": (graph.get("tiles", []) as Array).size(),
		"entranceCount": 0,
		"entrances": [],
		"tileEdges": {},
		"runtimeLocal": true
	} if runtime_graph_request else build_hierarchy(graph, profile)
	var start_tile := String((graph.get("spanTiles", {}) as Dictionary).get(start_key, ""))
	var goal_tiles: Array = []
	for goal_key in goal_keys:
		var goal_tile := String((graph.get("spanTiles", {}) as Dictionary).get(String(goal_key), ""))
		if goal_tile != "" and not goal_tiles.has(goal_tile):
			goal_tiles.append(goal_tile)
	goal_tiles.sort()
	var allowed_tiles := [] if runtime_graph_request else abstract_tile_path(hierarchy, start_tile, goal_tiles)
	if not runtime_graph_request and allowed_tiles.is_empty() and (not goal_tiles.is_empty() and not goal_tiles.has(start_tile)):
		return _base_result(request, NpcEnumsScript.ROUTE_STATUS_UNREACHABLE, NpcEnumsScript.ROUTE_REASON_NO_ROUTE, {
			"hierarchy": hierarchy,
			"abstractReason": "no_tile_path",
			"graph": _route_graph_metrics(graph, start_key, goal_keys, allowed_tiles)
		})
	if not active_jobs.has(job_key):
		active_jobs[job_key] = local_planner.start_job(graph, start_key, goal_keys, cost_model, request, profile, allowed_tiles)
		_touch_active_job(job_key)
	return _step_route_job(request, job_key, graph, start_key, goal_keys, allowed_tiles, hierarchy, profile, max_expansions)

func _step_route_job(request, job_key: String, graph: Dictionary, start_key: String, goal_keys: Array, allowed_tiles: Array, hierarchy: Dictionary, profile, max_expansions: int):
	var search_budget_usec := _local_search_usec_budget(request)
	var search: Dictionary = local_planner.step(active_jobs[job_key], max_expansions, search_budget_usec)
	last_stats = {
		"lastExpansions": int(search.get("expansions", local_planner.stats().get("lastExpansions", 0))),
		"activeJobs": active_jobs.size(),
		"cacheEntries": local_cost_cache.size(),
		"hierarchy": hierarchy
	}
	var status: StringName = search.get("status")
	if status == NpcEnumsScript.ROUTE_STATUS_PENDING:
		_touch_active_job(job_key)
		var pending = _base_result(request, NpcEnumsScript.ROUTE_STATUS_PENDING, &"pending_budget", {
			"hierarchy": hierarchy,
			"graph": _route_pending_graph_metrics(graph, start_key, goal_keys, allowed_tiles)
		})
		return pending
	active_jobs.erase(job_key)
	active_job_order.erase(job_key)
	if status == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE and not allowed_tiles.is_empty() and _goal_spec(request).has("_graph"):
		var fallback_job := local_planner.start_job(graph, start_key, goal_keys, cost_model, request, profile, [])
		var fallback_search: Dictionary = local_planner.step(fallback_job, max_expansions, search_budget_usec)
		last_stats["abstractFallback"] = "unrestricted_local"
		last_stats["lastFallbackExpansions"] = int(fallback_search.get("expansions", local_planner.stats().get("lastExpansions", 0)))
		if fallback_search.get("status") != NpcEnumsScript.ROUTE_STATUS_UNREACHABLE:
			search = fallback_search
			status = search.get("status")
	if status == NpcEnumsScript.ROUTE_STATUS_PENDING:
		var fallback_pending = _base_result(request, NpcEnumsScript.ROUTE_STATUS_PENDING, &"pending_budget", {
			"hierarchy": hierarchy,
			"fallback": "unrestricted_local",
			"graph": _route_pending_graph_metrics(graph, start_key, goal_keys, [])
		})
		return fallback_pending
	if status == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE:
		return _base_result(request, NpcEnumsScript.ROUTE_STATUS_UNREACHABLE, search.get("reason", NpcEnumsScript.ROUTE_REASON_NO_ROUTE), {
			"hierarchy": hierarchy,
			"graph": _route_graph_metrics(graph, start_key, goal_keys, allowed_tiles),
			"search": {
				"expansions": int(search.get("expansions", 0)),
				"closedCount": int(search.get("closedCount", 0)),
				"bestKey": String(search.get("bestKey", "")),
				"bestGoalDistance": float(search.get("bestGoalDistance", INF))
			}
		})
	var corridor = corridor_builder.build(graph, search.get("path", []), search.get("edges", []), search.get("breakdowns", []), request, true)
	var result = _base_result(request, status, search.get("reason", NpcEnumsScript.ROUTE_REASON_NONE), {
		"hierarchy": hierarchy,
		"costBreakdown": cost_model.path_cost_breakdown(search.get("breakdowns", [])),
		"dependencies": corridor.dependencies.duplicate(true),
		"path": search.get("path", [])
	})
	result.cost = float(search.get("cost", corridor.total_cost))
	result.corridor = corridor
	result.arrival_contract = corridor.arrival_contract
	result.repair_graph = graph
	result.repair_start_key = start_key
	result.repair_goal_keys = goal_keys.duplicate()
	result.repair_request = request
	return result

func _route_graph_metrics(graph: Dictionary, start_key: String, goal_keys: Array, allowed_tiles: Array) -> Dictionary:
	var edges: Dictionary = graph.get("edges", {})
	return {
		"nodeCount": (graph.get("nodes", {}) as Dictionary).size(),
		"edgeCount": int(graph.get("edgeCount", -1)),
		"startKey": start_key,
		"startEdgeCount": (edges.get(start_key, []) as Array).size(),
		"goalKeys": goal_keys.duplicate(),
		"allowedTileCount": allowed_tiles.size()
	}

func _route_pending_graph_metrics(graph: Dictionary, start_key: String, goal_keys: Array, allowed_tiles: Array) -> Dictionary:
	return {
		"nodeCount": (graph.get("nodes", {}) as Dictionary).size(),
		"edgeCount": -1,
		"startKey": start_key,
		"goalKeys": goal_keys.duplicate(),
		"allowedTileCount": allowed_tiles.size()
	}

func plan_runtime_route(entry: Dictionary, intent: Dictionary, world_adapter, max_expansions := 200000) -> Dictionary:
	var monitor = world_adapter.performance_monitor() if world_adapter != null and world_adapter.has_method("performance_monitor") else null
	var request_start: int = monitor.begin_section("route_runtime_request") if monitor != null else Time.get_ticks_usec()
	var request = runtime_request(entry, intent, world_adapter)
	if monitor != null:
		monitor.end_section("route_runtime_request", request_start)
	var plan_start: int = monitor.begin_section("route_search_step") if monitor != null else Time.get_ticks_usec()
	var result = plan_route(request, max_expansions)
	if monitor != null:
		monitor.end_section("route_search_step", plan_start)
	var record_start: int = monitor.begin_section("route_record_result") if monitor != null else Time.get_ticks_usec()
	_record_route_result(entry, result)
	if monitor != null:
		monitor.end_section("route_record_result", record_start)
	var convert_start: int = monitor.begin_section("route_result_convert") if monitor != null else Time.get_ticks_usec()
	var route: Dictionary = route_dictionary_from_result(result, intent, world_adapter)
	if monitor != null:
		monitor.end_section("route_result_convert", convert_start)
	return route

func route_cost_for_runtime(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := NpcConstantsScript.CELL_SIZE * 0.85, approach_cells: Array = [], world_adapter = null) -> float:
	if world_adapter == null:
		return INF
	var body := entry.get("body") as Node3D
	var start_position: Vector3 = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
	var target_cell: Vector2i = world_adapter.world_cell(target)
	var start_cell: Vector2i = world_adapter.world_cell(start_position)
	var snapshot: Dictionary = world_adapter.build_snapshot(entry, allow_outside, moving_home)
	var intent := {
		"kind": "cost",
		"target": target,
		"targetCell": target_cell,
		"allowOutside": allow_outside,
		"movingHome": moving_home,
		"arrivalRadius": arrival_radius,
		"priority": 0,
		"action": "",
		"interruptible": true,
		"approachCells": approach_cells
	}
	var target_cells: Dictionary = _runtime_target_cells(entry, intent, world_adapter, snapshot, target_cell, start_cell)
	if target_cells.is_empty():
		return INF
	var best := INF
	for cell in target_cells.keys():
		if not (cell is Vector2i):
			continue
		var delta := Vector2(float(cell.x - start_cell.x), float(cell.y - start_cell.y))
		var cost := delta.length()
		cost += _runtime_line_blocker_penalty(entry, world_adapter, snapshot, start_cell, cell)
		best = minf(best, cost)
	return best

func route_dictionary_from_result(result, intent: Dictionary, world_adapter) -> Dictionary:
	var target_cell: Vector2i = intent.get("targetCell", Vector2i(999999, 999999))
	if result == null:
		return _route_failure("blocked", "missing_result", target_cell)
	var status: StringName = result.get("status")
	if status == NpcEnumsScript.ROUTE_STATUS_PENDING:
		return _route_failure("pending", str(result.get("reason")), target_cell)
	if status == NpcEnumsScript.ROUTE_STATUS_COMPLETE:
		var corridor = result.get("corridor")
		if corridor == null or corridor.steps.is_empty():
			return {
				"ok": true,
				"status": "arrived",
				"reason": "",
				"cells": [],
				"waypoints": [],
				"actions": {},
				"targetCell": target_cell,
				"fallbackCell": target_cell,
				"snapshotRevision": str(result.get("topology_revision")),
				"typedResult": result,
				"corridor": corridor
			}
		return {
			"ok": true,
			"status": "routed",
			"reason": "",
			"cells": corridor.cells_2d(),
			"waypoints": corridor.waypoints.duplicate(),
			"actions": corridor.actions_by_cell(),
			"targetCell": target_cell,
			"fallbackCell": _last_corridor_cell(corridor, target_cell),
			"snapshotRevision": str(result.get("topology_revision")),
			"typedResult": result,
			"corridor": corridor
		}
	if status == NpcEnumsScript.ROUTE_STATUS_PARTIAL:
		var partial_corridor = result.get("corridor")
		return {
			"ok": partial_corridor != null and not partial_corridor.steps.is_empty(),
			"status": "partial",
			"reason": str(result.get("reason")),
			"cells": partial_corridor.cells_2d() if partial_corridor != null else [],
			"waypoints": partial_corridor.waypoints.duplicate() if partial_corridor != null else [],
			"actions": partial_corridor.actions_by_cell() if partial_corridor != null else {},
			"targetCell": target_cell,
			"fallbackCell": _last_corridor_cell(partial_corridor, target_cell) if partial_corridor != null else target_cell,
			"snapshotRevision": str(result.get("topology_revision")),
			"typedResult": result,
			"corridor": partial_corridor
		}
	return _route_failure("blocked", str(result.get("reason")), target_cell, result)

func build_graph(profile = null) -> Dictionary:
	var graph := _empty_graph()
	if navigation_world == null:
		return graph
	var tiles: Dictionary = navigation_world.get("tiles_by_key")
	var tile_keys := tiles.keys()
	tile_keys.sort()
	for tile_key_value in tile_keys:
		var tile = tiles[tile_key_value]
		if tile == null or bool(tile.get("unloaded")) or bool(tile.get("stale")):
			continue
		var spans: Dictionary = tile.get("spans_by_key")
		var span_keys := spans.keys()
		span_keys.sort()
		for span_key_value in span_keys:
			var span = spans[span_key_value]
			if not capability_service.span_supported(profile, span):
				continue
			_add_node(graph, span, String(tile_key_value))
		var edges_by_from: Dictionary = tile.get("edges_by_from")
		for from_key in edges_by_from.keys():
			var targets: Dictionary = edges_by_from[from_key]
			for to_key in targets.keys():
				var edge = targets[to_key]
				if capability_service.edge_supported(profile, edge):
					_add_edge_record(graph, String(from_key), String(to_key), edge, String(tile_key_value), String(tile_key_value))
	_add_cross_tile_edges(graph, profile)
	return graph

func build_hierarchy(graph: Dictionary, profile = null) -> Dictionary:
	var tile_edges := {}
	var entrances: Array = []
	for from_key in (graph.get("edges", {}) as Dictionary).keys():
		for edge_record in (graph.get("edges", {}) as Dictionary)[from_key]:
			var from_tile := String(edge_record.get("fromTile", ""))
			var to_tile := String(edge_record.get("toTile", ""))
			var is_entrance := from_tile != to_tile or String(edge_record.get("kind", "")) in ["door", "special"] or String(edge_record.get("portalId", "")) != ""
			if not is_entrance:
				continue
			entrances.append({
				"from": String(from_key),
				"to": String(edge_record.get("toKey", "")),
				"fromTile": from_tile,
				"toTile": to_tile,
				"kind": String(edge_record.get("kind", "")),
				"portalId": String(edge_record.get("portalId", ""))
			})
			if from_tile != "" and to_tile != "":
				if not tile_edges.has(from_tile):
					tile_edges[from_tile] = []
				if not (tile_edges[from_tile] as Array).has(to_tile):
					(tile_edges[from_tile] as Array).append(to_tile)
				_cache_local_cost(edge_record, profile)
	for key in tile_edges.keys():
		(tile_edges[key] as Array).sort()
	entrances.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return "%s:%s:%s" % [String(a.get("fromTile", "")), String(a.get("toTile", "")), String(a.get("from", ""))] < "%s:%s:%s" % [String(b.get("fromTile", "")), String(b.get("toTile", "")), String(b.get("from", ""))]
	)
	return {
		"tileCount": (graph.get("tiles", []) as Array).size(),
		"entranceCount": entrances.size(),
		"entrances": entrances,
		"tileEdges": tile_edges,
		"cacheEntries": local_cost_cache.size()
	}

func abstract_tile_path(hierarchy: Dictionary, start_tile: String, goal_tiles: Array) -> Array:
	if start_tile == "":
		return []
	if goal_tiles.has(start_tile):
		return [start_tile]
	var tile_edges: Dictionary = hierarchy.get("tileEdges", {})
	var open: Array = [start_tile]
	var came_from := {}
	var visited := {}
	while not open.is_empty():
		open.sort()
		var current := String(open.pop_front())
		if visited.has(current):
			continue
		visited[current] = true
		if goal_tiles.has(current):
			return _reconstruct_tile_path(start_tile, current, came_from)
		for neighbor in tile_edges.get(current, []):
			var neighbor_key := String(neighbor)
			if visited.has(neighbor_key):
				continue
			if not came_from.has(neighbor_key):
				came_from[neighbor_key] = current
			open.append(neighbor_key)
	return []

func resolve_start_key(graph: Dictionary, request, profile = null) -> String:
	var start_span = request.get("start_span")
	var nodes: Dictionary = graph.get("nodes", {})
	if start_span is String and nodes.has(String(start_span)):
		return String(start_span)
	if start_span != null and start_span.has_method("key_string") and nodes.has(start_span.key_string()):
		return start_span.key_string()
	return _nearest_span(graph, request.get("start_position"), float(_goal_spec(request).get("maxStartSnap", NpcConstantsScript.CELL_SIZE * 0.60)), request.get("start_position").y, float(_goal_spec(request).get("verticalTolerance", NpcConstantsScript.DEFAULT_NPC_STEP_UP)))

func resolve_goal_keys(graph: Dictionary, request, profile = null) -> Array:
	var spec: Dictionary = _goal_spec(request)
	var kind := String(spec.get("kind", "point_region"))
	var nodes: Dictionary = graph.get("nodes", {})
	var result: Array = []
	if kind == "exact_span":
		var key := String(spec.get("spanKey", ""))
		if nodes.has(key):
			result.append(key)
	elif kind == "smart_object_slot_set":
		for key_value in spec.get("spanKeys", []):
			var key := String(key_value)
			if nodes.has(key) and not result.has(key):
				result.append(key)
	elif kind == "portal_side":
		var portal_id := String(spec.get("portalId", ""))
		var side := String(spec.get("side", "to"))
		for edges in (graph.get("edges", {}) as Dictionary).values():
			for edge_record in edges:
				if String((edge_record as Dictionary).get("portalId", "")) != portal_id:
					continue
				var key := String((edge_record as Dictionary).get("toKey" if side != "from" else "fromKey", ""))
				if nodes.has(key) and not result.has(key):
					result.append(key)
	elif kind == "semantic_region":
		var region_id := String(spec.get("regionId", ""))
		var kind_filter := String(spec.get("kindFilter", spec.get("semanticKind", "")))
		for key in nodes.keys():
			var span = nodes[key]
			for semantic_id in span.get("semantic_region_ids"):
				var semantic_text := String(semantic_id)
				if (region_id != "" and semantic_text == region_id) or (kind_filter != "" and semantic_text.begins_with(kind_filter)):
					result.append(String(key))
					break
	else:
		var center: Vector3 = spec.get("center", request.get("start_position"))
		var radius := float(spec.get("radius", request.get("maximum_acceptable_goal_distance")))
		if radius <= 0.0:
			radius = NpcConstantsScript.CELL_SIZE * 0.75
		var vertical_tolerance := float(spec.get("verticalTolerance", NpcConstantsScript.DEFAULT_NPC_STEP_UP))
		for key in nodes.keys():
			var span = nodes[key]
			var pos: Vector3 = span.get("world_position")
			if Vector2(pos.x - center.x, pos.z - center.z).length() <= radius and absf(pos.y - center.y) <= vertical_tolerance:
				result.append(String(key))
	if result.is_empty() and kind in ["point_region", "point"]:
		var center: Vector3 = spec.get("center", request.get("start_position"))
		var nearest := _nearest_span(graph, center, float(spec.get("maxGoalSnap", NpcConstantsScript.CELL_SIZE * 1.2)), center.y, float(spec.get("verticalTolerance", NpcConstantsScript.DEFAULT_NPC_STEP_UP)))
		if nearest != "":
			result.append(nearest)
	result.sort()
	return result

func runtime_request(entry: Dictionary, intent: Dictionary, world_adapter):
	var request = RouteRequestScript.new()
	var target_cell_value: Vector2i = intent.get("targetCell", Vector2i.ZERO)
	var revision_key := "0"
	if world_adapter != null:
		revision_key = str(int(world_adapter.get("static_snapshot_revision")))
	request.request_id = "runtime:%s:%s:%d,%d:%s:%s:%s:%s" % [
		String(entry.get("id", "npc")),
		String(intent.get("kind", "move")),
		target_cell_value.x,
		target_cell_value.y,
		str(bool(intent.get("allowOutside", false))),
		str(bool(intent.get("movingHome", false))),
		String(intent.get("action", "")),
		revision_key
	]
	request.owner_npc_id = String(entry.get("id", "npc"))
	var body := entry.get("body") as Node3D
	request.start_position = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
	request.start_span = _runtime_span_key(world_adapter.world_cell(request.start_position))
	request.goal_kind = StringName(String(intent.get("kind", "move")))
	request.priority_class = int(intent.get("priority", 0))
	request.allow_partial = bool(intent.get("allowPartial", false))
	request.maximum_acceptable_goal_distance = float(intent.get("arrivalRadius", NpcConstantsScript.CELL_SIZE * 0.75))
	var target: Vector3 = intent.get("target", request.start_position)
	if String(entry.get("activeRuntimeRouteRequestId", "")) != request.request_id:
		entry["activeRuntimeRouteRequestId"] = request.request_id
		entry["activeRuntimeRouteGeneration"] = int(entry.get("activeRuntimeRouteGeneration", 0)) + 1
	request.cancellation_generation = int(entry.get("activeRuntimeRouteGeneration", 1))
	var active_job_key := "%s:%d" % [request.request_id, request.cancellation_generation]
	var graph := {}
	if not active_jobs.has(active_job_key):
		graph = _build_runtime_graph(entry, intent, world_adapter, request.start_position)
	var target_center: Vector3 = world_adapter.cell_position(target_cell_value) if world_adapter != null else target
	var target_span_keys: Array = []
	if graph.has("_targetSpanKeys"):
		target_span_keys = (graph.get("_targetSpanKeys", []) as Array).duplicate()
	var goal_spec := {
		"kind": "point_region",
		"center": target_center,
		"radius": request.maximum_acceptable_goal_distance,
		"_graph": graph
	}
	if not target_span_keys.is_empty():
		goal_spec["kind"] = "smart_object_slot_set"
		goal_spec["spanKeys"] = target_span_keys
	request.goal_spec = goal_spec
	var preferences := {}
	if entry.has("_externalDirectMoveFrame"):
		preferences["externalDirectRoute"] = true
	if _runtime_graph_foreground_route(entry, intent):
		preferences["foregroundRoute"] = true
	if not preferences.is_empty():
		request.semantic_preferences = preferences
	return request

func _local_search_usec_budget(request) -> int:
	if request == null or not _goal_spec(request).has("_graph"):
		return 0
	var preferences: Dictionary = request.get("semantic_preferences") if request.get("semantic_preferences") is Dictionary else {}
	if bool(preferences.get("externalDirectRoute", false)):
		return 0
	if bool(preferences.get("foregroundRoute", false)):
		return 0
	return RUNTIME_SEARCH_STEP_USEC_BUDGET

func _build_runtime_graph(entry: Dictionary, intent: Dictionary, world_adapter, start_position: Vector3) -> Dictionary:
	var graph := _empty_graph()
	if world_adapter == null:
		return graph
	var monitor = world_adapter.performance_monitor() if world_adapter.has_method("performance_monitor") else null
	var graph_start: int = monitor.begin_section("runtime_graph_build") if monitor != null else Time.get_ticks_usec()
	var allow_outside := bool(intent.get("allowOutside", false))
	var moving_home := bool(intent.get("movingHome", false))
	var snapshot_start: int = monitor.begin_section("runtime_graph_snapshot") if monitor != null else Time.get_ticks_usec()
	var snapshot: Dictionary = world_adapter.build_snapshot(entry, allow_outside, moving_home)
	if monitor != null:
		monitor.end_section("runtime_graph_snapshot", snapshot_start)
	var start_cell: Vector2i = world_adapter.world_cell(start_position)
	var target_cell: Vector2i = intent.get("targetCell", world_adapter.world_cell(intent.get("target", start_position)))
	var margin := _runtime_margin_for_intent(intent, entry)
	var cache_key := _runtime_graph_cache_key(entry, intent, world_adapter, start_cell, target_cell, margin)
	var foreground_route := _runtime_graph_foreground_route(entry, intent)
	if runtime_graph_build_jobs.has(cache_key):
		var continue_existing_start: int = monitor.begin_section("runtime_graph_continue") if monitor != null else Time.get_ticks_usec()
		var existing_pending_graph: Dictionary = _continue_runtime_graph_build_job(cache_key, entry, intent, world_adapter, snapshot, start_cell, {}, [], {}, _runtime_graph_resume_units(entry, intent), foreground_route)
		if monitor != null:
			monitor.end_section("runtime_graph_continue", continue_existing_start)
			monitor.end_section("runtime_graph_build", graph_start)
		return existing_pending_graph
	var target_start: int = monitor.begin_section("runtime_graph_targets") if monitor != null else Time.get_ticks_usec()
	var target_cells: Dictionary = _runtime_target_cells(entry, intent, world_adapter, snapshot, target_cell, start_cell)
	if monitor != null:
		monitor.end_section("runtime_graph_targets", target_start)
	if target_cells.is_empty():
		target_cells[target_cell] = true
	if runtime_graph_cache.has(cache_key):
		var cached_graph: Dictionary = runtime_graph_cache[cache_key]
		if _runtime_graph_covers(cached_graph, start_cell, target_cells):
			runtime_graph_cache_order.erase(cache_key)
			runtime_graph_cache_order.append(cache_key)
			if monitor != null:
				monitor.increment_counter("runtime_graph_cache_hits")
				monitor.end_section("runtime_graph_build", graph_start)
			return cached_graph
	if monitor != null:
		monitor.increment_counter("runtime_graph_cache_misses")
	var candidates_start: int = monitor.begin_section("runtime_graph_candidates") if monitor != null else Time.get_ticks_usec()
	var candidate_cells: Dictionary = _runtime_graph_cells(start_cell, target_cell, target_cells, margin)
	var cells := candidate_cells.keys()
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y)
	)
	var target_lookup := {}
	for cell in target_cells.keys():
		target_lookup[cell] = true
	if monitor != null:
		monitor.end_section("runtime_graph_candidates", candidates_start)
	if cells.size() > RUNTIME_GRAPH_SYNC_CELL_LIMIT:
		var continue_start: int = monitor.begin_section("runtime_graph_continue") if monitor != null else Time.get_ticks_usec()
		var pending_graph: Dictionary = _continue_runtime_graph_build_job(cache_key, entry, intent, world_adapter, snapshot, start_cell, target_cells, cells, target_lookup, _runtime_graph_initial_units(entry, intent), foreground_route)
		if monitor != null:
			monitor.end_section("runtime_graph_continue", continue_start)
		if monitor != null:
			monitor.end_section("runtime_graph_build", graph_start)
		return pending_graph
	var sync_start: int = monitor.begin_section("runtime_graph_sync_nodes") if monitor != null else Time.get_ticks_usec()
	for cell: Vector2i in cells:
		if not _runtime_cell_can_be_node(entry, world_adapter, snapshot, cell, start_cell, target_cells):
			continue
		var span = _runtime_span_for_cell(world_adapter, snapshot, cell)
		_add_node(graph, span, NavigationChangeBusScript.tile_key_for_cell(cell))
	if monitor != null:
		monitor.end_section("runtime_graph_sync_nodes", sync_start)
	var node_keys := (graph.get("nodes", {}) as Dictionary).keys()
	node_keys.sort()
	var edge_start: int = monitor.begin_section("runtime_graph_sync_edges") if monitor != null else Time.get_ticks_usec()
	for from_key in node_keys:
		_add_runtime_edges_for_key(graph, String(from_key), entry, intent, world_adapter, snapshot, target_lookup)
	if monitor != null:
		monitor.end_section("runtime_graph_sync_edges", edge_start)
	if monitor != null:
		monitor.end_section("runtime_graph_build", graph_start)
	graph["_targetSpanKeys"] = _runtime_target_span_keys(target_cells)
	_store_runtime_graph_cache(cache_key, graph)
	return graph

func _empty_graph() -> Dictionary:
	return {
		"nodes": {},
		"edges": {},
		"spanTiles": {},
		"tiles": [],
		"edgeCount": 0
	}

func _runtime_graph_cells(start_cell: Vector2i, target_cell: Vector2i, target_cells: Dictionary, margin: int) -> Dictionary:
	var cells := {}
	_runtime_add_cell_radius(cells, start_cell, margin)
	_runtime_add_cell_radius(cells, target_cell, margin)
	_runtime_add_line_corridor(cells, start_cell, target_cell, margin)
	for target in target_cells.keys():
		if target is Vector2i:
			if maxi(absi(target.x - target_cell.x), absi(target.y - target_cell.y)) <= margin:
				cells[target] = true
				continue
			_runtime_add_cell_radius(cells, target, margin)
			_runtime_add_line_corridor(cells, start_cell, target, margin)
	return cells

func _runtime_graph_cache_key(entry: Dictionary, intent: Dictionary, world_adapter, start_cell: Vector2i, target_cell: Vector2i, margin: int) -> String:
	var static_revision := 0
	if world_adapter != null:
		static_revision = int(world_adapter.get("static_snapshot_revision"))
	var profile_id := "adult_npc"
	var context = entry.get("agentContext")
	if context != null and context.get("traversal_profile_id") != null:
		profile_id = String(context.get("traversal_profile_id"))
	var start_tile := NavigationChangeBusScript.tile_key_for_cell(start_cell)
	var target_tile := NavigationChangeBusScript.tile_key_for_cell(target_cell)
	return "%s|%d|%s|%s|%s|%d|%s|%s" % [
		profile_id,
		static_revision,
		start_tile,
		target_tile,
		String(intent.get("kind", "move")),
		margin,
		str(bool(intent.get("allowOutside", false))),
		str(bool(intent.get("movingHome", false)))
	]

func _runtime_graph_covers(graph: Dictionary, start_cell: Vector2i, target_cells: Dictionary) -> bool:
	var nodes: Dictionary = graph.get("nodes", {})
	if not nodes.has(_runtime_span_key(start_cell)):
		return false
	for cell_value in target_cells.keys():
		if cell_value is Vector2i and nodes.has(_runtime_span_key(cell_value)):
			return true
	return false

func _store_runtime_graph_cache(cache_key: String, graph: Dictionary) -> void:
	if cache_key == "" or graph.is_empty():
		return
	var cached_graph := graph.duplicate(false)
	cached_graph.erase("_pending")
	cached_graph.erase("_yieldAfterBuild")
	runtime_graph_cache[cache_key] = cached_graph
	runtime_graph_cache_order.erase(cache_key)
	runtime_graph_cache_order.append(cache_key)
	while runtime_graph_cache_order.size() > RUNTIME_GRAPH_CACHE_LIMIT:
		var evicted := String(runtime_graph_cache_order.pop_front())
		runtime_graph_cache.erase(evicted)

func _continue_runtime_graph_build_job(cache_key: String, entry: Dictionary, intent: Dictionary, world_adapter, snapshot: Dictionary, start_cell: Vector2i, target_cells: Dictionary, cells: Array, target_lookup: Dictionary, max_units := RUNTIME_GRAPH_BUILD_CELLS_RESUME_CALL, ignore_time_budget := false) -> Dictionary:
	var step_start_usec := Time.get_ticks_usec()
	var job: Dictionary = runtime_graph_build_jobs.get(cache_key, {})
	if job.is_empty():
		job = {
			"graph": _empty_graph(),
			"cells": cells.duplicate(),
			"targetCells": target_cells.duplicate(),
			"targetLookup": target_lookup.duplicate(),
			"targetSpanKeys": _runtime_target_span_keys(target_cells),
			"cellIndex": 0,
			"edgeKeys": [],
			"edgeIndex": 0,
			"edgeOffsets": _runtime_edge_offsets_for_entry(entry, intent),
			"phase": "nodes"
		}
	runtime_graph_build_jobs[cache_key] = job
	var graph: Dictionary = job.get("graph", _empty_graph())
	var job_cells: Array = job.get("cells", cells)
	var job_target_cells: Dictionary = job.get("targetCells", target_cells)
	var job_target_lookup: Dictionary = job.get("targetLookup", target_lookup)
	graph.erase("_pending")
	var processed := 0
	var unit_budget := maxi(1, max_units)
	var phase := String(job.get("phase", "nodes"))
	if phase == "nodes":
		var cell_index := int(job.get("cellIndex", 0))
		while cell_index < job_cells.size() and processed < unit_budget:
			var cell: Vector2i = job_cells[cell_index]
			if _runtime_cell_can_be_node(entry, world_adapter, snapshot, cell, start_cell, job_target_cells):
				var span = _runtime_span_for_cell(world_adapter, snapshot, cell)
				_add_node(graph, span, NavigationChangeBusScript.tile_key_for_cell(cell))
			cell_index += 1
			processed += 1
			if _runtime_graph_step_time_exhausted(entry, step_start_usec, processed, ignore_time_budget):
				break
		job["cellIndex"] = cell_index
		if cell_index >= job_cells.size():
			var edge_keys := (graph.get("nodes", {}) as Dictionary).keys()
			edge_keys.sort()
			job["edgeKeys"] = edge_keys
			job["edgeIndex"] = 0
			job["edgeOffsetIndex"] = 0
			phase = "edges"
			job["phase"] = phase
	if phase == "edges" and processed < unit_budget and not _runtime_graph_step_time_exhausted(entry, step_start_usec, processed, ignore_time_budget):
		var edge_keys: Array = job.get("edgeKeys", [])
		var edge_offsets: Array = job.get("edgeOffsets", _runtime_edge_offsets_for_entry(entry, intent))
		if edge_offsets.is_empty():
			edge_offsets = RUNTIME_CARDINAL_EDGE_OFFSETS
		var edge_index := int(job.get("edgeIndex", 0))
		var edge_offset_index := int(job.get("edgeOffsetIndex", 0))
		while edge_index < edge_keys.size() and processed < unit_budget:
			_add_runtime_edge_offset_for_key(graph, String(edge_keys[edge_index]), edge_offsets[edge_offset_index], entry, world_adapter, snapshot, job_target_lookup)
			edge_offset_index += 1
			if edge_offset_index >= edge_offsets.size():
				edge_offset_index = 0
				edge_index += 1
			processed += 1
			if _runtime_graph_step_time_exhausted(entry, step_start_usec, processed, ignore_time_budget):
				break
		job["edgeIndex"] = edge_index
		job["edgeOffsetIndex"] = edge_offset_index
		if edge_index >= edge_keys.size():
			runtime_graph_build_jobs.erase(cache_key)
			graph.erase("_pending")
			graph["_targetSpanKeys"] = job.get("targetSpanKeys", [])
			_store_runtime_graph_cache(cache_key, graph)
			if not entry.has("_externalDirectMoveFrame"):
				graph["_yieldAfterBuild"] = true
			return graph
	job["graph"] = graph
	runtime_graph_build_jobs[cache_key] = job
	graph["_pending"] = true
	graph["_targetSpanKeys"] = job.get("targetSpanKeys", [])
	return graph

func _runtime_graph_step_time_exhausted(entry: Dictionary, step_start_usec: int, processed: int, ignore_time_budget := false) -> bool:
	if ignore_time_budget:
		return false
	var budget := EXTERNAL_DIRECT_GRAPH_STEP_USEC_BUDGET if entry.has("_externalDirectMoveFrame") else RUNTIME_GRAPH_STEP_USEC_BUDGET
	return processed > 0 and Time.get_ticks_usec() - step_start_usec >= budget

func _runtime_target_span_keys(target_cells: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for cell_value in target_cells.keys():
		if cell_value is Vector2i:
			result.append(_runtime_span_key(cell_value))
	result.sort()
	return result

func _runtime_graph_initial_units(entry: Dictionary, intent: Dictionary = {}) -> int:
	if _runtime_graph_foreground_route(entry, intent):
		return FOREGROUND_RUNTIME_GRAPH_BUILD_UNITS
	return EXTERNAL_DIRECT_GRAPH_BUILD_CELLS_INITIAL_CALL if entry.has("_externalDirectMoveFrame") else RUNTIME_GRAPH_BUILD_CELLS_INITIAL_CALL

func _runtime_graph_resume_units(entry: Dictionary, intent: Dictionary = {}) -> int:
	if _runtime_graph_foreground_route(entry, intent):
		return FOREGROUND_RUNTIME_GRAPH_BUILD_UNITS
	if entry.has("_externalDirectMoveFrame"):
		return EXTERNAL_DIRECT_GRAPH_BUILD_CELLS_RESUME_CALL
	if String(intent.get("kind", "")) == "scripted":
		return 1
	var job := String(entry.get("job", ""))
	if job in ["forage", "wood", "stone"]:
		return RUNTIME_GRAPH_BUILD_CELLS_RESUME_CALL
	return 1

func _runtime_graph_foreground_route(entry: Dictionary, intent: Dictionary = {}) -> bool:
	if bool(entry.get("tutorial", false)):
		return true
	if bool(intent.get("movingHome", false)):
		return true
	var kind := String(intent.get("kind", ""))
	if kind in ["scripted", "home"]:
		return true
	return int(entry.get("routePriority", 0)) >= 140

func _runtime_edge_offsets_for_entry(entry: Dictionary, intent: Dictionary = {}) -> Array:
	if entry.has("_externalDirectMoveFrame"):
		return RUNTIME_EDGE_OFFSETS
	if String(intent.get("kind", "")) == "scripted":
		return RUNTIME_CARDINAL_EDGE_OFFSETS
	var job := String(entry.get("job", ""))
	if job in ["forage", "wood", "stone"]:
		return RUNTIME_EDGE_OFFSETS
	return RUNTIME_CARDINAL_EDGE_OFFSETS

func _add_runtime_edges_for_key(graph: Dictionary, from_key: String, entry: Dictionary, intent: Dictionary, world_adapter, snapshot: Dictionary, target_lookup: Dictionary) -> void:
	for offset in _runtime_edge_offsets_for_entry(entry, intent):
		_add_runtime_edge_offset_for_key(graph, from_key, offset, entry, world_adapter, snapshot, target_lookup)

func _add_runtime_edge_offset_for_key(graph: Dictionary, from_key: String, offset: Vector2i, entry: Dictionary, world_adapter, snapshot: Dictionary, target_lookup: Dictionary) -> void:
	var nodes: Dictionary = graph.get("nodes", {})
	if not nodes.has(from_key):
		return
	var from_span = nodes[from_key]
	var from_cell3: Vector3i = from_span.get("cell")
	var from_cell: Vector2i = Vector2i(from_cell3.x, from_cell3.z)
	var to_cell: Vector2i = from_cell + offset
	var to_key := _runtime_span_key(to_cell)
	if not nodes.has(to_key):
		return
	var blocked := false
	if offset.x != 0 and offset.y != 0:
		blocked = _runtime_step_blocked(entry, world_adapter, snapshot, from_cell, Vector2i(offset.x, 0), target_lookup) or _runtime_step_blocked(entry, world_adapter, snapshot, from_cell, Vector2i(0, offset.y), target_lookup)
	if not blocked:
		blocked = _runtime_step_blocked(entry, world_adapter, snapshot, from_cell, offset, target_lookup)
	if blocked:
		return
	var kind := NpcEnumsScript.TRAVERSAL_KIND_WALK
	var cost := 1.414 if offset.x != 0 and offset.y != 0 else 1.0
	var door: Node = world_adapter.door_at(snapshot, to_cell)
	if door != null:
		kind = NpcEnumsScript.TRAVERSAL_KIND_DOOR
		cost += 1.0
	elif world_adapter.is_path_cell(snapshot, to_cell):
		cost *= 0.78
	var edge := {
		"from_key": from_key,
		"to_key": to_key,
		"traversal_kind": kind,
		"cost": cost,
		"bidirectional": true,
		"portal_id": "",
		"action_id": "",
		"required_capabilities": [],
		"metadata": {}
	}
	if door != null:
		edge["portal_id"] = "door:%s" % String(door.name)
		edge["action_id"] = "open"
		edge["required_capabilities"] = [&"open_doors"]
		edge["metadata"] = { "door": door }
	_add_edge_record(graph, from_key, to_key, edge, NavigationChangeBusScript.tile_key_for_cell(from_cell), NavigationChangeBusScript.tile_key_for_cell(to_cell))

func _runtime_add_cell_radius(cells: Dictionary, center: Vector2i, radius: int) -> void:
	for z in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			cells[Vector2i(x, z)] = true

func _runtime_add_line_corridor(cells: Dictionary, start_cell: Vector2i, end_cell: Vector2i, radius: int) -> void:
	var x := start_cell.x
	var z := start_cell.y
	var dx := absi(end_cell.x - start_cell.x)
	var dz := absi(end_cell.y - start_cell.y)
	var sx := 1 if start_cell.x < end_cell.x else -1
	var sz := 1 if start_cell.y < end_cell.y else -1
	var err := dx - dz
	while true:
		_runtime_add_cell_radius(cells, Vector2i(x, z), radius)
		if x == end_cell.x and z == end_cell.y:
			break
		var e2 := err * 2
		if e2 > -dz:
			err -= dz
			x += sx
		if e2 < dx:
			err += dx
			z += sz

func _add_node(graph: Dictionary, span, tile_key: String) -> void:
	var key: String = span.key_string()
	(graph["nodes"] as Dictionary)[key] = span
	(graph["spanTiles"] as Dictionary)[key] = tile_key
	if not (graph["tiles"] as Array).has(tile_key):
		(graph["tiles"] as Array).append(tile_key)

func _add_edge_record(graph: Dictionary, from_key: String, to_key: String, edge, from_tile: String, to_tile: String) -> void:
	if from_key == "" or to_key == "" or not (graph["nodes"] as Dictionary).has(from_key) or not (graph["nodes"] as Dictionary).has(to_key):
		return
	if not (graph["edges"] as Dictionary).has(from_key):
		(graph["edges"] as Dictionary)[from_key] = []
	var record := {
		"fromKey": from_key,
		"toKey": to_key,
		"from": (graph["nodes"] as Dictionary)[from_key],
		"to": (graph["nodes"] as Dictionary)[to_key],
		"edge": edge,
		"kind": String(edge.get("traversal_kind")),
		"baseCost": float(edge.get("cost")),
		"fromTile": from_tile,
		"toTile": to_tile,
		"portalId": String(edge.get("portal_id")),
		"bottleneck": edge.get("traversal_kind") in [NpcEnumsScript.TRAVERSAL_KIND_DOOR, NpcEnumsScript.TRAVERSAL_KIND_SPECIAL],
		"metadata": edge.get("metadata").duplicate(true)
	}
	((graph["edges"] as Dictionary)[from_key] as Array).append(record)
	graph["edgeCount"] = int(graph.get("edgeCount", 0)) + 1

func _add_cross_tile_edges(graph: Dictionary, profile = null) -> void:
	var keys := (graph.get("nodes", {}) as Dictionary).keys()
	keys.sort()
	for from_key in keys:
		var from_tile := String((graph.get("spanTiles", {}) as Dictionary).get(from_key, ""))
		var from_span = (graph.get("nodes", {}) as Dictionary)[from_key]
		var from_cell: Vector3i = from_span.get("cell")
		for to_key in keys:
			var to_tile := String((graph.get("spanTiles", {}) as Dictionary).get(to_key, ""))
			if from_key == to_key or from_tile == to_tile:
				continue
			var to_span = (graph.get("nodes", {}) as Dictionary)[to_key]
			var to_cell: Vector3i = to_span.get("cell")
			if maxi(abs(to_cell.x - from_cell.x), abs(to_cell.z - from_cell.z)) != 1:
				continue
			var edge = _edge_for_spans(from_key, to_key, from_span, to_span, profile)
			if edge != null:
				_add_edge_record(graph, from_key, to_key, edge, from_tile, to_tile)

func _edge_for_spans(from_key: String, to_key: String, from_span, to_span, profile = null):
	var vertical_delta: float = float(to_span.get("world_position").y) - float(from_span.get("world_position").y)
	var step_up := float(profile.get("step_up_height")) if profile != null else NpcConstantsScript.DEFAULT_NPC_STEP_UP
	var safe_drop := float(profile.get("safe_step_drop_height")) if profile != null else NpcConstantsScript.DEFAULT_NPC_SAFE_DROP
	var kind: StringName = NpcEnumsScript.TRAVERSAL_KIND_WALK
	if vertical_delta > 0.05:
		if vertical_delta > step_up:
			return null
		kind = NpcEnumsScript.TRAVERSAL_KIND_STEP
	elif vertical_delta < -0.05:
		if absf(vertical_delta) > safe_drop:
			return null
		kind = NpcEnumsScript.TRAVERSAL_KIND_DROP
	var from_cell: Vector3i = from_span.get("cell")
	var to_cell: Vector3i = to_span.get("cell")
	var flat_distance := Vector2(float(to_cell.x - from_cell.x), float(to_cell.z - from_cell.z)).length()
	return NavEdgeDataScript.make(from_key, to_key, kind, maxf(0.001, flat_distance + absf(vertical_delta) * 0.25))

func _profile_for_request(request):
	var spec: Dictionary = _goal_spec(request)
	if spec.has("profile"):
		return spec.get("profile")
	return TraversalProfileScript.default_adult_npc()

func _goal_spec(request) -> Dictionary:
	if request != null and request.get("goal_spec") is Dictionary:
		return request.get("goal_spec")
	return {}

func _nearest_span(graph: Dictionary, position: Vector3, max_distance: float, desired_y: float, vertical_tolerance: float) -> String:
	var best_key := ""
	var best_distance := INF
	var keys := (graph.get("nodes", {}) as Dictionary).keys()
	keys.sort()
	for key in keys:
		var span = (graph.get("nodes", {}) as Dictionary)[key]
		var pos: Vector3 = span.get("world_position")
		var flat := Vector2(pos.x - position.x, pos.z - position.z).length()
		if flat > max_distance or absf(pos.y - desired_y) > vertical_tolerance:
			continue
		if flat < best_distance:
			best_key = String(key)
			best_distance = flat
	return best_key

func _base_result(request, status: StringName, reason: StringName, metrics := {}):
	var result = RouteResultScript.make(status, reason, int(request.get("cancellation_generation")) if request != null else 0)
	if request != null:
		result.owner_npc_id = String(request.get("owner_npc_id"))
		result.request_id = String(request.get("request_id"))
		result.topology_revision = int(request.get("topology_revision"))
		result.dynamic_revision = int(request.get("dynamic_revision"))
	result.metrics = metrics.duplicate(true)
	return result

func _runtime_target_cells(entry: Dictionary, intent: Dictionary, world_adapter, snapshot: Dictionary, target_cell: Vector2i, start_cell: Vector2i) -> Dictionary:
	var target_cells := {}
	var arrival_radius := float(intent.get("arrivalRadius", NpcConstantsScript.CELL_SIZE * 0.75))
	var strict_arrival := bool(intent.get("strictArrival", false)) or String(intent.get("kind", "")) == "scripted"
	var radius: int = 0 if strict_arrival else clampi(ceili(arrival_radius / NpcConstantsScript.CELL_SIZE), 0, 3)
	for cell_value in intent.get("approachCells", []):
		if cell_value is Vector2i and _runtime_cell_can_be_goal(entry, world_adapter, snapshot, cell_value, start_cell):
			target_cells[cell_value] = true
	if not target_cells.is_empty():
		return target_cells
	var search_radius := radius if strict_arrival else maxi(1, radius)
	if bool(intent.get("movingHome", false)):
		search_radius = maxi(search_radius, 2)
	for cell in world_adapter.candidate_cells_near(entry, target_cell, bool(intent.get("allowOutside", false)), bool(intent.get("movingHome", false)), search_radius):
		if _runtime_cell_can_be_goal(entry, world_adapter, snapshot, cell, start_cell):
			target_cells[cell] = true
	for cell_value in intent.get("fallbackCells", []):
		if cell_value is Vector2i and _runtime_cell_can_be_goal(entry, world_adapter, snapshot, cell_value, start_cell):
			target_cells[cell_value] = true
	return target_cells

func _runtime_margin_for_intent(intent: Dictionary, entry: Dictionary = {}) -> int:
	var kind := String(intent.get("kind", "move"))
	var external_direct := entry.has("_externalDirectMoveFrame")
	if bool(intent.get("movingHome", false)):
		return 8 if external_direct else 4
	if kind == "scripted":
		return 4 if external_direct else 1
	if bool(intent.get("allowOutside", false)):
		return 3 if external_direct else 2
	return 3 if external_direct else 2

func _runtime_cell_can_be_goal(entry: Dictionary, world_adapter, snapshot: Dictionary, cell: Vector2i, start_cell: Vector2i) -> bool:
	if cell == start_cell:
		return true
	if world_adapter.static_blocker(snapshot, cell) != null:
		return false
	var height: float = world_adapter.height_for_cell(cell)
	var main = world_adapter.get("main")
	return main == null or height >= main.WATER_LEVEL + 0.45

func _runtime_cell_can_be_node(entry: Dictionary, world_adapter, snapshot: Dictionary, cell: Vector2i, start_cell: Vector2i, target_cells: Dictionary) -> bool:
	if cell == start_cell or target_cells.has(cell):
		return true
	if not world_adapter.cell_allowed_area(entry, cell, bool(snapshot.get("allowOutside", false)), bool(snapshot.get("movingHome", false))):
		return false
	if world_adapter.static_blocker(snapshot, cell) != null and world_adapter.door_at(snapshot, cell) == null:
		return false
	var main = world_adapter.get("main")
	if main != null and world_adapter.height_for_cell(cell) < main.WATER_LEVEL + 0.45:
		return false
	return true

func _runtime_step_blocked(entry: Dictionary, world_adapter, snapshot: Dictionary, from_cell: Vector2i, offset: Vector2i, target_lookup: Dictionary) -> bool:
	var to_cell := from_cell + offset
	var allowed: Dictionary = world_adapter.cell_pathable(entry, snapshot, from_cell, to_cell, target_lookup, true)
	return not bool(allowed.get("ok", false))

func _runtime_line_blocker_penalty(entry: Dictionary, world_adapter, snapshot: Dictionary, start_cell: Vector2i, end_cell: Vector2i) -> float:
	var dx := end_cell.x - start_cell.x
	var dz := end_cell.y - start_cell.y
	var samples := clampi(maxi(absi(dx), absi(dz)), 1, 48)
	var penalty := 0.0
	var previous := start_cell
	var target_lookup := { end_cell: true }
	for i in range(1, samples + 1):
		var t := float(i) / float(samples)
		var cell := Vector2i(roundi(lerpf(float(start_cell.x), float(end_cell.x), t)), roundi(lerpf(float(start_cell.y), float(end_cell.y), t)))
		if cell == previous:
			continue
		var offset := cell - previous
		offset.x = clampi(offset.x, -1, 1)
		offset.y = clampi(offset.y, -1, 1)
		if _runtime_step_blocked(entry, world_adapter, snapshot, previous, offset, target_lookup):
			penalty += 8.0
		previous = previous + offset
	return penalty

func _runtime_span_for_cell(world_adapter, snapshot: Dictionary, cell: Vector2i):
	var surface := {
		"cell": Vector3i(cell.x, 0, cell.y),
		"worldPosition": world_adapter.cell_position(cell),
		"headroom": 2.4,
		"lateralClearance": 1.0,
		"floorNormal": Vector3.UP,
		"semanticRegionIds": [],
		"traversalTags": ["terrain"]
	}
	if world_adapter.is_path_cell(snapshot, cell):
		surface["semanticRegionIds"] = ["road"]
	if world_adapter.door_at(snapshot, cell) != null:
		surface["semanticRegionIds"] = ["door"]
	return NavSpanDataScript.from_surface(NavigationChangeBusScript.tile_key_for_cell(cell), surface, 0)

func _runtime_span_key(cell: Vector2i) -> String:
	return "%s:%d,%d,%d:0" % [NavigationChangeBusScript.tile_key_for_cell(cell), cell.x, 0, cell.y]

func _cache_local_cost(edge_record: Dictionary, profile = null) -> void:
	var profile_class := capability_service.profile_class(profile)
	var key := "%s:%s:%s:%s" % [String(edge_record.get("fromTile", "")), String(edge_record.get("toTile", "")), String(edge_record.get("fromKey", "")), profile_class]
	local_cost_cache[key] = float(edge_record.get("baseCost", 1.0))
	local_cost_cache_order.erase(key)
	local_cost_cache_order.append(key)
	var capacity := maxi(1, NpcConstantsScript.ROUTE_LOCAL_COST_CACHE_CAPACITY)
	while local_cost_cache_order.size() > capacity:
		var evicted := String(local_cost_cache_order.pop_front())
		local_cost_cache.erase(evicted)

func _touch_active_job(job_key: String) -> void:
	active_job_order.erase(job_key)
	active_job_order.append(job_key)
	var capacity := maxi(1, NpcConstantsScript.ROUTE_ACTIVE_JOB_CAPACITY)
	while active_job_order.size() > capacity:
		var evicted := String(active_job_order.pop_front())
		active_jobs.erase(evicted)

func _reconstruct_tile_path(start_tile: String, end_tile: String, came_from: Dictionary) -> Array:
	var result: Array = [end_tile]
	var cursor := end_tile
	while cursor != start_tile and came_from.has(cursor):
		cursor = String(came_from[cursor])
		result.push_front(cursor)
	return result

func _last_corridor_cell(corridor, fallback: Vector2i) -> Vector2i:
	if corridor == null or corridor.steps.is_empty():
		return fallback
	var last_step = corridor.steps[corridor.steps.size() - 1]
	var cell: Vector3i = last_step.get("cell")
	return Vector2i(cell.x, cell.z)

func _route_failure(status: String, reason: String, target_cell: Vector2i, typed_result = null) -> Dictionary:
	return {
		"ok": false,
		"status": status,
		"reason": reason,
		"cells": [],
		"waypoints": [],
		"actions": {},
		"targetCell": target_cell,
		"fallbackCell": Vector2i(999999, 999999),
		"snapshotRevision": "",
		"typedResult": typed_result
	}

func _record_route_result(entry: Dictionary, result) -> void:
	if result == null:
		return
	var blackboard = entry.get("blackboard")
	if blackboard != null:
		blackboard.set("current_route_result", result)
		blackboard.set("terminal_status", result.get("status") if result.call("is_terminal") else &"none")
	entry["typedRouteResult"] = result
	if result.get("corridor") != null:
		entry["routeCorridor"] = result.get("corridor")

func stats() -> Dictionary:
	return last_stats.duplicate(true)
