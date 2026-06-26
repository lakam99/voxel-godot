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
var last_stats := {}

func setup(nav_world = null) -> void:
	navigation_world = nav_world

func clear() -> void:
	active_jobs.clear()
	active_job_order.clear()
	local_cost_cache.clear()
	local_cost_cache_order.clear()
	last_stats.clear()

func plan_route(request, max_expansions := 4096):
	if request == null:
		return RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_FAILED_INTERNAL, &"missing_request")
	if int(request.get("cancelled_generation")) == int(request.get("cancellation_generation")):
		return _base_result(request, NpcEnumsScript.ROUTE_STATUS_CANCELLED, NpcEnumsScript.ROUTE_REASON_CANCELLED)
	var profile = _profile_for_request(request)
	var graph: Dictionary = request.get("goal_spec").get("_graph", {}) if request.get("goal_spec") is Dictionary else {}
	if graph.is_empty():
		graph = build_graph(profile)
	var start_key := resolve_start_key(graph, request, profile)
	if start_key == "":
		return _base_result(request, NpcEnumsScript.ROUTE_STATUS_UNREACHABLE, &"no_start_span")
	var goal_keys := resolve_goal_keys(graph, request, profile)
	if goal_keys.is_empty():
		return _base_result(request, NpcEnumsScript.ROUTE_STATUS_UNREACHABLE, &"no_goal_span")
	var hierarchy := build_hierarchy(graph, profile)
	var start_tile := String((graph.get("spanTiles", {}) as Dictionary).get(start_key, ""))
	var goal_tiles: Array = []
	for goal_key in goal_keys:
		var goal_tile := String((graph.get("spanTiles", {}) as Dictionary).get(String(goal_key), ""))
		if goal_tile != "" and not goal_tiles.has(goal_tile):
			goal_tiles.append(goal_tile)
	goal_tiles.sort()
	var allowed_tiles := abstract_tile_path(hierarchy, start_tile, goal_tiles)
	if allowed_tiles.is_empty() and (not goal_tiles.is_empty() and not goal_tiles.has(start_tile)):
		return _base_result(request, NpcEnumsScript.ROUTE_STATUS_UNREACHABLE, NpcEnumsScript.ROUTE_REASON_NO_ROUTE, {
			"hierarchy": hierarchy,
			"abstractReason": "no_tile_path"
		})
	var request_id := String(request.get("request_id"))
	if request_id == "":
		request_id = "route:%s:%s" % [String(request.get("owner_npc_id")), str(Time.get_ticks_usec())]
		request.set("request_id", request_id)
	var job_key := "%s:%d" % [request_id, int(request.get("cancellation_generation"))]
	if not active_jobs.has(job_key):
		active_jobs[job_key] = local_planner.start_job(graph, start_key, goal_keys, cost_model, request, profile, allowed_tiles)
		_touch_active_job(job_key)
	var search: Dictionary = local_planner.step(active_jobs[job_key], max_expansions)
	last_stats = {
		"lastExpansions": int(search.get("expansions", local_planner.stats().get("lastExpansions", 0))),
		"activeJobs": active_jobs.size(),
		"cacheEntries": local_cost_cache.size(),
		"hierarchy": hierarchy
	}
	var status: StringName = search.get("status")
	if status == NpcEnumsScript.ROUTE_STATUS_PENDING:
		_touch_active_job(job_key)
		var pending = _base_result(request, NpcEnumsScript.ROUTE_STATUS_PENDING, &"pending_budget", { "hierarchy": hierarchy })
		return pending
	active_jobs.erase(job_key)
	active_job_order.erase(job_key)
	if status == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE and not allowed_tiles.is_empty() and _goal_spec(request).has("_graph"):
		var fallback_job := local_planner.start_job(graph, start_key, goal_keys, cost_model, request, profile, [])
		var fallback_search: Dictionary = local_planner.step(fallback_job, max_expansions)
		last_stats["abstractFallback"] = "unrestricted_local"
		last_stats["lastFallbackExpansions"] = int(fallback_search.get("expansions", local_planner.stats().get("lastExpansions", 0)))
		if fallback_search.get("status") != NpcEnumsScript.ROUTE_STATUS_UNREACHABLE:
			search = fallback_search
			status = search.get("status")
	if status == NpcEnumsScript.ROUTE_STATUS_PENDING:
		var fallback_pending = _base_result(request, NpcEnumsScript.ROUTE_STATUS_PENDING, &"pending_budget", { "hierarchy": hierarchy, "fallback": "unrestricted_local" })
		return fallback_pending
	if status == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE:
		return _base_result(request, NpcEnumsScript.ROUTE_STATUS_UNREACHABLE, search.get("reason", NpcEnumsScript.ROUTE_REASON_NO_ROUTE), { "hierarchy": hierarchy })
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

func plan_legacy_route(entry: Dictionary, intent: Dictionary, legacy_world, max_expansions := 200000) -> Dictionary:
	var request = legacy_request(entry, intent, legacy_world)
	var result = plan_route(request, max_expansions)
	_record_route_result(entry, result)
	return compatibility_dictionary(result, intent, legacy_world)

func route_cost_for_legacy(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := NpcConstantsScript.CELL_SIZE * 0.85, approach_cells: Array = [], legacy_world = null) -> float:
	if legacy_world == null:
		return INF
	var body := entry.get("body") as Node3D
	var start_position: Vector3 = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
	var target_cell: Vector2i = legacy_world.world_cell(target)
	var start_cell: Vector2i = legacy_world.world_cell(start_position)
	var snapshot: Dictionary = legacy_world.build_snapshot(entry, allow_outside, moving_home)
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
	var target_cells: Dictionary = _legacy_target_cells(entry, intent, legacy_world, snapshot, target_cell, start_cell)
	if target_cells.is_empty():
		return INF
	var best := INF
	for cell in target_cells.keys():
		if not (cell is Vector2i):
			continue
		var delta := Vector2(float(cell.x - start_cell.x), float(cell.y - start_cell.y))
		var cost := delta.length()
		cost += _legacy_line_blocker_penalty(entry, legacy_world, snapshot, start_cell, cell)
		best = minf(best, cost)
	return best

func compatibility_dictionary(result, intent: Dictionary, legacy_world) -> Dictionary:
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

func legacy_request(entry: Dictionary, intent: Dictionary, legacy_world):
	var request = RouteRequestScript.new()
	request.request_id = "legacy:%s:%s:%s" % [String(entry.get("id", "npc")), String(intent.get("kind", "move")), str(intent.get("targetCell", Vector2i.ZERO))]
	request.owner_npc_id = String(entry.get("id", "npc"))
	var body := entry.get("body") as Node3D
	request.start_position = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
	request.start_span = _legacy_span_key(legacy_world.world_cell(request.start_position))
	request.goal_kind = StringName(String(intent.get("kind", "move")))
	request.priority_class = int(intent.get("priority", 0))
	request.allow_partial = bool(intent.get("allowPartial", false))
	request.maximum_acceptable_goal_distance = float(intent.get("arrivalRadius", NpcConstantsScript.CELL_SIZE * 0.75))
	var target: Vector3 = intent.get("target", request.start_position)
	request.goal_spec = {
		"kind": "point_region",
		"center": target,
		"radius": request.maximum_acceptable_goal_distance,
		"verticalTolerance": NpcConstantsScript.DEFAULT_NPC_STEP_UP,
		"_graph": _build_legacy_graph(entry, intent, legacy_world, request.start_position)
	}
	var blackboard = entry.get("blackboard")
	if blackboard != null and blackboard.has_method("next_route_generation"):
		request.cancellation_generation = blackboard.next_route_generation()
	else:
		request.next_generation()
	return request

func _build_legacy_graph(entry: Dictionary, intent: Dictionary, legacy_world, start_position: Vector3) -> Dictionary:
	var graph := _empty_graph()
	if legacy_world == null:
		return graph
	var allow_outside := bool(intent.get("allowOutside", false))
	var moving_home := bool(intent.get("movingHome", false))
	var snapshot: Dictionary = legacy_world.build_snapshot(entry, allow_outside, moving_home)
	var start_cell: Vector2i = legacy_world.world_cell(start_position)
	var target_cell: Vector2i = intent.get("targetCell", legacy_world.world_cell(intent.get("target", start_position)))
	var target_cells: Dictionary = _legacy_target_cells(entry, intent, legacy_world, snapshot, target_cell, start_cell)
	if target_cells.is_empty():
		target_cells[target_cell] = true
	var margin := _legacy_margin_for_intent(intent)
	var candidate_cells: Dictionary = _legacy_graph_cells(start_cell, target_cell, target_cells, margin)
	var cells := candidate_cells.keys()
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y)
	)
	for cell: Vector2i in cells:
		if not _legacy_cell_can_be_node(entry, legacy_world, snapshot, cell, start_cell, target_cells):
			continue
		var span = _legacy_span_for_cell(legacy_world, snapshot, cell)
		_add_node(graph, span, NavigationChangeBusScript.tile_key_for_cell(cell))
	var node_keys := (graph.get("nodes", {}) as Dictionary).keys()
	node_keys.sort()
	var target_lookup := {}
	for cell in target_cells.keys():
		target_lookup[cell] = true
	for from_key in node_keys:
		var from_span = (graph.get("nodes", {}) as Dictionary)[from_key]
		var from_cell3: Vector3i = from_span.get("cell")
		var from_cell: Vector2i = Vector2i(from_cell3.x, from_cell3.z)
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
			var to_cell: Vector2i = from_cell + offset
			var to_key := _legacy_span_key(to_cell)
			if not (graph.get("nodes", {}) as Dictionary).has(to_key):
				continue
			if offset.x != 0 and offset.y != 0 and (_legacy_step_blocked(entry, legacy_world, snapshot, from_cell, Vector2i(offset.x, 0), target_lookup) or _legacy_step_blocked(entry, legacy_world, snapshot, from_cell, Vector2i(0, offset.y), target_lookup)):
				continue
			if _legacy_step_blocked(entry, legacy_world, snapshot, from_cell, offset, target_lookup):
				continue
			var to_span = (graph.get("nodes", {}) as Dictionary)[to_key]
			var kind := NpcEnumsScript.TRAVERSAL_KIND_WALK
			var cost := 1.414 if offset.x != 0 and offset.y != 0 else 1.0
			var door: Node = legacy_world.door_at(snapshot, to_cell)
			if door != null:
				kind = NpcEnumsScript.TRAVERSAL_KIND_DOOR
				cost += 1.0
			elif legacy_world.is_path_cell(snapshot, to_cell):
				cost *= 0.78
			var edge = NavEdgeDataScript.make(from_key, to_key, kind, cost)
			if door != null:
				edge.portal_id = "door:%s" % String(door.name)
				edge.action_id = "open"
				edge.required_capabilities.append(&"open_doors")
				edge.metadata = { "door": door }
			_add_edge_record(graph, from_key, to_key, edge, NavigationChangeBusScript.tile_key_for_cell(from_cell), NavigationChangeBusScript.tile_key_for_cell(to_cell))
	return graph

func _empty_graph() -> Dictionary:
	return {
		"nodes": {},
		"edges": {},
		"spanTiles": {},
		"tiles": []
	}

func _legacy_graph_cells(start_cell: Vector2i, target_cell: Vector2i, target_cells: Dictionary, margin: int) -> Dictionary:
	var cells := {}
	_legacy_add_cell_radius(cells, start_cell, margin)
	_legacy_add_cell_radius(cells, target_cell, margin)
	_legacy_add_line_corridor(cells, start_cell, target_cell, margin)
	for target in target_cells.keys():
		if target is Vector2i:
			_legacy_add_cell_radius(cells, target, margin)
			_legacy_add_line_corridor(cells, start_cell, target, margin)
	return cells

func _legacy_add_cell_radius(cells: Dictionary, center: Vector2i, radius: int) -> void:
	for z in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			cells[Vector2i(x, z)] = true

func _legacy_add_line_corridor(cells: Dictionary, start_cell: Vector2i, end_cell: Vector2i, radius: int) -> void:
	var x := start_cell.x
	var z := start_cell.y
	var dx := absi(end_cell.x - start_cell.x)
	var dz := absi(end_cell.y - start_cell.y)
	var sx := 1 if start_cell.x < end_cell.x else -1
	var sz := 1 if start_cell.y < end_cell.y else -1
	var err := dx - dz
	while true:
		_legacy_add_cell_radius(cells, Vector2i(x, z), radius)
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
		(graph["tiles"] as Array).sort()

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

func _legacy_target_cells(entry: Dictionary, intent: Dictionary, legacy_world, snapshot: Dictionary, target_cell: Vector2i, start_cell: Vector2i) -> Dictionary:
	var target_cells := {}
	var arrival_radius := float(intent.get("arrivalRadius", NpcConstantsScript.CELL_SIZE * 0.75))
	var strict_arrival := bool(intent.get("strictArrival", false)) or String(intent.get("kind", "")) == "scripted"
	var radius: int = 0 if strict_arrival else clampi(ceili(arrival_radius / NpcConstantsScript.CELL_SIZE), 0, 3)
	for cell_value in intent.get("approachCells", []):
		if cell_value is Vector2i and _legacy_cell_can_be_goal(entry, legacy_world, snapshot, cell_value, start_cell):
			target_cells[cell_value] = true
	if not target_cells.is_empty():
		return target_cells
	var search_radius := radius if strict_arrival else maxi(1, radius)
	if bool(intent.get("movingHome", false)):
		search_radius = maxi(search_radius, 2)
	for cell in legacy_world.candidate_cells_near(entry, target_cell, bool(intent.get("allowOutside", false)), bool(intent.get("movingHome", false)), search_radius):
		if _legacy_cell_can_be_goal(entry, legacy_world, snapshot, cell, start_cell):
			target_cells[cell] = true
	for cell_value in intent.get("fallbackCells", []):
		if cell_value is Vector2i and _legacy_cell_can_be_goal(entry, legacy_world, snapshot, cell_value, start_cell):
			target_cells[cell_value] = true
	return target_cells

func _legacy_margin_for_intent(intent: Dictionary) -> int:
	var kind := String(intent.get("kind", "move"))
	if bool(intent.get("movingHome", false)):
		return 26
	if kind == "scripted":
		return 16
	if bool(intent.get("allowOutside", false)):
		return 12
	return 8

func _legacy_cell_can_be_goal(entry: Dictionary, legacy_world, snapshot: Dictionary, cell: Vector2i, start_cell: Vector2i) -> bool:
	if cell == start_cell:
		return true
	if legacy_world.static_blocker(snapshot, cell) != null:
		return false
	var height: float = legacy_world.height_for_cell(cell)
	var main = legacy_world.get("main")
	return main == null or height >= main.WATER_LEVEL + 0.45

func _legacy_cell_can_be_node(entry: Dictionary, legacy_world, snapshot: Dictionary, cell: Vector2i, start_cell: Vector2i, target_cells: Dictionary) -> bool:
	if cell == start_cell or target_cells.has(cell):
		return true
	if not legacy_world.cell_allowed_area(entry, cell, bool(snapshot.get("allowOutside", false)), bool(snapshot.get("movingHome", false))):
		return false
	if legacy_world.static_blocker(snapshot, cell) != null and legacy_world.door_at(snapshot, cell) == null:
		return false
	var main = legacy_world.get("main")
	if main != null and legacy_world.height_for_cell(cell) < main.WATER_LEVEL + 0.45:
		return false
	return true

func _legacy_step_blocked(entry: Dictionary, legacy_world, snapshot: Dictionary, from_cell: Vector2i, offset: Vector2i, target_lookup: Dictionary) -> bool:
	var to_cell := from_cell + offset
	var allowed: Dictionary = legacy_world.cell_pathable(entry, snapshot, from_cell, to_cell, target_lookup, true)
	return not bool(allowed.get("ok", false))

func _legacy_line_blocker_penalty(entry: Dictionary, legacy_world, snapshot: Dictionary, start_cell: Vector2i, end_cell: Vector2i) -> float:
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
		if _legacy_step_blocked(entry, legacy_world, snapshot, previous, offset, target_lookup):
			penalty += 8.0
		previous = previous + offset
	return penalty

func _legacy_span_for_cell(legacy_world, snapshot: Dictionary, cell: Vector2i):
	var surface := {
		"cell": Vector3i(cell.x, 0, cell.y),
		"worldPosition": legacy_world.cell_position(cell),
		"headroom": 2.4,
		"lateralClearance": 1.0,
		"floorNormal": Vector3.UP,
		"semanticRegionIds": [],
		"traversalTags": ["terrain"]
	}
	if legacy_world.is_path_cell(snapshot, cell):
		surface["semanticRegionIds"] = ["road"]
	if legacy_world.door_at(snapshot, cell) != null:
		surface["semanticRegionIds"] = ["door"]
	return NavSpanDataScript.from_surface(NavigationChangeBusScript.tile_key_for_cell(cell), surface, 0)

func _legacy_span_key(cell: Vector2i) -> String:
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
