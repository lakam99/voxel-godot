extends RefCounted
class_name NpcSemanticGoalPlanner

const HomeInteriorServiceScript := preload("res://scripts/npc_ai/behavior/HomeInteriorService.gd")

const CELL := 1.35
const MAX_ROUTE_SCORED_CANDIDATES := 16
const MAX_HOME_INTERIOR_GOAL_CELLS := 64
const RESOURCE_SCAN_NODE_LIMIT := 1200
const RESOURCE_SCAN_CANDIDATE_LIMIT := 16

var system
var main
var world
var planner

func setup(system_node, main_node, navigation_world, route_planner) -> void:
    system = system_node
    main = main_node
    world = navigation_world
    planner = route_planner

func surface_y_at_position(position: Vector3) -> float:
    if main != null and main.has_method("surface_y_at_position"):
        return float(main.call("surface_y_at_position", position))
    return position.y

func navigation_snapshot(entry: Dictionary, allow_outside := false, moving_home := false) -> Dictionary:
    if world == null:
        return {}
    if world.has_method("cached_validation_snapshot"):
        return world.cached_validation_snapshot(entry, allow_outside, moving_home)
    return world.build_snapshot(entry, allow_outside, moving_home) if world.has_method("build_snapshot") else {}

func make_intent(entry: Dictionary, target: Vector3, max_distance: float, moving_home := false, allow_outside := false) -> Dictionary:
    var body := entry.get("body") as Node3D
    var kind: String = String(entry.get("routeIntentKind", entry.get("activeGoalKind", entry.get("goal", "move"))))
    if moving_home:
        kind = "home"
    elif body != null and body.has_meta("npc_scripted_target"):
        kind = "scripted"
    elif not (kind in ["work", "forage", "guard", "job"]):
        var job_phase := String(entry.get("jobPhase", "idle"))
        var job := String(entry.get("job", ""))
        if job_phase in ["outbound", "searching", "gathering", "returning", "stall"] and job != "":
            kind = "forage" if job == "forage" else "work"
        elif allow_outside and job != "":
            kind = "job"
    var target_cell: Vector2i = world.world_cell(target) if world != null else Vector2i(roundi(target.x / CELL), roundi(target.z / CELL))
    var fallback_cells: Array[Vector2i] = []
    var arrival_radius := CELL * 0.72
    var strict_home_route := moving_home
    var strict_scripted_route := false
    var allow_home_partial := false
    if moving_home:
        arrival_radius = CELL * 0.35 if strict_home_route else CELL * 0.82
        if body != null and actor_inside_home(entry, body.global_position):
            fallback_cells = home_interior_goal_cells(entry)
        if body != null:
            var home_cell: Vector2i = entry.get("homeCell", target_cell)
            var porch_cell: Vector2i = entry.get("porchCell", home_cell)
            var current_cell: Vector2i = world.world_cell(body.global_position) if world != null else Vector2i(roundi(body.global_position.x / CELL), roundi(body.global_position.z / CELL))
            var near_home_edge: bool = current_cell == porch_cell \
                or current_cell == home_cell \
                or actor_inside_home(entry, body.global_position) \
                or body.global_position.distance_to(entry.get("porchPosition", target)) <= CELL * 2.0
            allow_home_partial = not near_home_edge and body.global_position.distance_to(target) > CELL * 4.0
    elif kind == "scripted":
        arrival_radius = float(body.get_meta("npc_scripted_arrival_radius", CELL * 0.45)) if body != null else CELL * 0.45
        strict_scripted_route = arrival_radius < CELL * 0.95
    var priority := int(entry.get("routePriority", 0))
    if moving_home:
        priority = maxi(priority, 100)
    elif kind == "scripted":
        priority = maxi(priority, 180)
    elif kind == "guard":
        priority = maxi(priority, 130)
    elif priority <= 0:
        priority = 50
    return {
        "kind": kind,
        "target": target,
        "targetCell": target_cell,
        "allowOutside": allow_outside,
        "movingHome": moving_home,
        "arrivalRadius": arrival_radius,
        "priority": priority,
        "action": "",
        "interruptible": not moving_home,
        "allowPartial": allow_home_partial or kind == "guard",
        "generatedBridgeCritical": kind == "guard" and bool(entry.get("guardRouteCritical", false)),
        "strictArrival": strict_home_route or strict_scripted_route or kind in ["job", "work", "forage"],
        "fallbackCells": fallback_cells
    }

func home_interior_goal_cells(entry: Dictionary) -> Array[Vector2i]:
    var result: Array[Vector2i] = []
    var home_cell: Vector2i = entry.get("homeCell", Vector2i.ZERO)
    var interior_min: Vector2i = entry.get("interiorMinCell", home_cell)
    var interior_max: Vector2i = entry.get("interiorMaxCell", home_cell)
    var min_x := mini(interior_min.x, interior_max.x)
    var max_x := maxi(interior_min.x, interior_max.x)
    var min_z := mini(interior_min.y, interior_max.y)
    var max_z := maxi(interior_min.y, interior_max.y)
    for z in range(min_z, max_z + 1):
        for x in range(min_x, max_x + 1):
            var cell := Vector2i(x, z)
            if world != null and world.has_method("cell_is_standable_goal") and not bool(world.cell_is_standable_goal(entry, cell, false, true)):
                continue
            result.append(cell)
    result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        var a_home := Vector2(float(a.x - home_cell.x), float(a.y - home_cell.y)).length_squared()
        var b_home := Vector2(float(b.x - home_cell.x), float(b.y - home_cell.y)).length_squared()
        if not is_equal_approx(a_home, b_home):
            return a_home < b_home
        if a.x != b.x:
            return a.x < b.x
        return a.y < b.y
    )
    if result.size() > MAX_HOME_INTERIOR_GOAL_CELLS:
        result.resize(MAX_HOME_INTERIOR_GOAL_CELLS)
    return result

func actor_inside_home(entry: Dictionary, position: Vector3) -> bool:
    var portal = null
    if system != null and system.get("autonomy_system") != null:
        var autonomy = system.get("autonomy_system")
        if autonomy.get("door_portals") != null:
            portal = HomeInteriorServiceScript.portal_for_entry(entry, autonomy.get("door_portals"))
    return bool(HomeInteriorServiceScript.status(entry, position, portal).get("strictInside", false))

func choose_day_target(entry: Dictionary) -> Vector3:
    if world == null or planner == null:
        return entry.get("porchPosition", Vector3.ZERO)
    var candidates: Array[Vector3] = town_anchor_candidates(entry)
    var reachable := choose_best_reachable_position(entry, candidates, false, false, CELL * 0.85, MAX_ROUTE_SCORED_CANDIDATES)
    if reachable != Vector3.INF:
        clear_goal_fallback(entry)
        return reachable
    set_goal_fallback(entry, "blocked", "no_reachable_wander_anchor")
    return entry.get("porchPosition", Vector3.ZERO)

func choose_job_target(entry: Dictionary) -> Vector3:
    if world == null or planner == null:
        return entry.get("porchPosition", Vector3.ZERO)
    var job := String(entry.get("job", ""))
    var outside_town_job := resource_job_uses_outside_work_area(job)
    if job == "forage" and forager_prefers_search_anchor(entry):
        var early_search := choose_forage_search_target(entry)
        if early_search != Vector3.INF:
            clear_goal_fallback(entry)
            return early_search
    var resource_candidates: Array[Vector3] = []
    add_resource_prop_candidates(resource_candidates, entry, job)
    var resource_reachable := choose_best_reachable_position(entry, resource_candidates, outside_town_job, false, CELL * 0.85, MAX_ROUTE_SCORED_CANDIDATES)
    if resource_reachable != Vector3.INF and job_position_allowed(entry, resource_reachable, outside_town_job):
        clear_goal_fallback(entry)
        return resource_reachable
    if job == "forage":
        var forage_search := choose_forage_search_target(entry)
        if forage_search != Vector3.INF:
            clear_goal_fallback(entry)
            return forage_search
    var candidates: Array[Vector3] = job_anchor_candidates(entry, outside_town_job)
    var reachable := choose_best_reachable_position(entry, candidates, outside_town_job, false, CELL * 0.85, MAX_ROUTE_SCORED_CANDIDATES)
    if reachable != Vector3.INF and job_position_allowed(entry, reachable, outside_town_job):
        clear_goal_fallback(entry)
        return reachable
    set_goal_fallback(entry, "blocked", "no_reachable_job_anchor")
    var fallback_candidates: Array[Vector3] = [
        entry.get("porchPosition", Vector3.ZERO),
        entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO))
    ]
    var fallback := choose_best_reachable_position(entry, fallback_candidates, false, false, CELL * 0.85, 4)
    return fallback if fallback != Vector3.INF else entry.get("porchPosition", Vector3.ZERO)

func forager_prefers_search_anchor(entry: Dictionary) -> bool:
    if String(entry.get("job", "")) != "forage":
        return false
    if String(entry.get("jobObjectId", "")) != "":
        return false
    var phase := String(entry.get("jobPhase", ""))
    if phase == "searching":
        return true
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body) or world == null:
        return false
    return world.point_inside_town(entry, body.global_position)

func choose_guard_target(entry: Dictionary, target_hostile: Node3D = null, melee := false) -> Vector3:
    if world == null or planner == null:
        return entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO))
    var candidates: Array[Vector3] = []
    if target_hostile != null and is_instance_valid(target_hostile):
        candidates = hostile_intercept_candidates(entry, target_hostile, melee)
        var intercept := choose_best_reachable_position(entry, candidates, true, false, CELL * 0.72, MAX_ROUTE_SCORED_CANDIDATES)
        if intercept != Vector3.INF:
            clear_goal_fallback(entry)
            return intercept
    var assigned_guard_post: Vector3 = entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO))
    if position_can_be_goal(entry, assigned_guard_post, false, false):
        clear_goal_fallback(entry)
        return assigned_guard_post
    candidates = guard_post_candidates(entry)
    var guard_target := choose_best_reachable_position(entry, candidates, false, false, CELL * 0.85, 10)
    if guard_target != Vector3.INF:
        clear_goal_fallback(entry)
        return guard_target
    set_goal_fallback(entry, "blocked", "no_reachable_guard_anchor")
    return entry.get("porchPosition", Vector3.ZERO)

func choose_best_forage(entry: Dictionary, candidates: Array[Node3D]) -> Node3D:
    if world == null:
        return candidates[0] if not candidates.is_empty() else null
    var body := entry.get("body") as Node3D
    var origin: Vector3 = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
    candidates.sort_custom(func(a: Node3D, b: Node3D) -> bool:
        if a == null or b == null:
            return a != null
        var a_distance := a.global_position.distance_squared_to(origin)
        var b_distance := b.global_position.distance_squared_to(origin)
        if is_equal_approx(a_distance, b_distance):
            return stable_node_id(a) < stable_node_id(b)
        return a_distance < b_distance
    )
    for node in candidates:
        if node == null or not is_instance_valid(node):
            continue
        var approach_cells: Array[Vector2i] = world.approach_cells_for_target(entry, node.global_position, true)
        var approach_positions: Array[Vector3] = []
        for cell in approach_cells:
            approach_positions.append(world.cell_position(cell))
        var reachable := choose_best_reachable_position(entry, approach_positions, true, false, CELL * 0.85, mini(approach_positions.size(), 6), true)
        if reachable != Vector3.INF:
            return node
    return null

func forage_target_position(entry: Dictionary, node: Node3D) -> Vector3:
    if node == null or world == null:
        return node.global_position if node != null else Vector3.ZERO
    var approach_cells: Array[Vector2i] = world.approach_cells_for_target(entry, node.global_position, true)
    var approach_positions: Array[Vector3] = []
    for cell in approach_cells:
        approach_positions.append(world.cell_position(cell))
    var reachable := choose_best_reachable_position(entry, approach_positions, true, false, CELL * 0.85, approach_positions.size(), true)
    return reachable if reachable != Vector3.INF else node.global_position

func choose_forage_search_target(entry: Dictionary) -> Vector3:
    if world == null:
        return Vector3.INF
    var candidates: Array[Vector3] = []
    add_nearest_forage_exit_candidates(candidates, entry)
    add_path_candidates(candidates, entry, true)
    var outward := outward_work_anchor(entry)
    if outward != Vector3.INF:
        candidates.append(outward)
    add_forage_search_sweep_candidates(candidates, entry)
    add_deterministic_ring_candidates(candidates, entry, true)
    var reachable := choose_best_reachable_position(entry, candidates, true, false, CELL * 0.85, MAX_ROUTE_SCORED_CANDIDATES, true)
    if reachable != Vector3.INF and job_position_allowed(entry, reachable, true):
        return reachable
    for candidate in unique_positions(candidates):
        if candidate == Vector3.INF:
            continue
        if not job_position_allowed(entry, candidate, true):
            continue
        if surface_y_at_position(candidate) < main.WATER_LEVEL + 0.45:
            continue
        return candidate
    return Vector3.INF

func add_nearest_forage_exit_candidates(candidates: Array[Vector3], entry: Dictionary) -> void:
    if world == null or main == null:
        return
    var center_cell: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var center := Vector3(float(center_cell.x) * CELL, 0.0, float(center_cell.y) * CELL)
    var origins: Array[Vector3] = []
    var body := entry.get("body") as Node3D
    if body != null and is_instance_valid(body):
        origins.append(body.global_position)
    origins.append(entry.get("porchPosition", entry.get("homePosition", center)))
    origins.append(entry.get("homePosition", entry.get("porchPosition", center)))
    var base_radius := maxf(float(entry.get("townRadius", 18)) + 4.0, 22.0)
    var seen := {}
    for origin in origins:
        var direction := origin - center
        direction.y = 0.0
        if direction.length_squared() < 0.001:
            continue
        direction = direction.normalized()
        for extra in [0.0, 4.0, 8.0]:
            var position := center + direction * (base_radius + float(extra)) * CELL
            var key := position_key(position)
            if seen.has(key):
                continue
            seen[key] = true
            var ground_y := surface_y_at_position(position)
            if ground_y < main.WATER_LEVEL + 0.5:
                continue
            position.y = ground_y + 0.04
            if world.point_inside_work_area(entry, position) and not world.point_inside_town(entry, position):
                candidates.append(position)

func stable_node_id(node: Node) -> String:
    if node == null:
        return ""
    if node.has_meta("prop_id"):
        return String(node.get_meta("prop_id"))
    if node.has_meta("smart_object_id"):
        return String(node.get_meta("smart_object_id"))
    return String(node.name)

func choose_best_reachable_position(entry: Dictionary, candidates: Array[Vector3], allow_outside := false, moving_home := false, _arrival_radius := CELL * 0.85, max_checked := 8, force_route_cost := false) -> Vector3:
    var body := entry.get("body") as Node3D
    var origin: Vector3 = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
    var unique_candidates := unique_positions(candidates)
    unique_candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool:
        var a_distance := a.distance_squared_to(origin)
        var b_distance := b.distance_squared_to(origin)
        if is_equal_approx(a_distance, b_distance):
            return position_key(a) < position_key(b)
        return a_distance < b_distance
    )
    var score_with_route_cost := force_route_cost or moving_home or OS.get_environment("VOXEL_NPC_ROUTE_SCORE_TARGETS") == "1"
    var checked: int = 0
    for candidate in unique_candidates:
        if not position_can_be_goal(entry, candidate, allow_outside, moving_home):
            continue
        checked += 1
        if checked > max_checked:
            break
        if not score_with_route_cost:
            return candidate
        var cost: float = INF
        if planner != null and planner.has_method("route_cost"):
            cost = float(planner.route_cost(entry, candidate, allow_outside, moving_home, _arrival_radius, [], force_route_cost))
        if cost < INF:
            return candidate
    return Vector3.INF

func town_anchor_candidates(entry: Dictionary) -> Array[Vector3]:
    var candidates: Array[Vector3] = []
    candidates.append(entry.get("porchPosition", Vector3.ZERO))
    candidates.append(entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO)))
    add_path_candidates(candidates, entry, false)
    add_utility_anchor_candidates(candidates, entry)
    return candidates

func job_anchor_candidates(entry: Dictionary, outside_town := true) -> Array[Vector3]:
    var candidates: Array[Vector3] = []
    if outside_town:
        add_resource_prop_candidates(candidates, entry, String(entry.get("job", "")))
        add_path_candidates(candidates, entry, true)
        var outward := outward_work_anchor(entry)
        if outward != Vector3.INF:
            candidates.append(outward)
        add_deterministic_ring_candidates(candidates, entry, true)
    else:
        add_path_candidates(candidates, entry, false)
        add_utility_anchor_candidates(candidates, entry)
        add_deterministic_ring_candidates(candidates, entry, false)
    candidates.append(entry.get("porchPosition", Vector3.ZERO))
    return candidates

func outward_work_anchor(entry: Dictionary) -> Vector3:
    if world == null or main == null:
        return Vector3.INF
    var center_cell: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var center := Vector3(float(center_cell.x) * CELL, 0.0, float(center_cell.y) * CELL)
    var porch: Vector3 = entry.get("porchPosition", center)
    var direction := porch - center
    direction.y = 0.0
    if direction.length_squared() < 0.001:
        var rng := deterministic_rng(entry, "work_anchor")
        var angle := rng.randf() * TAU
        direction = Vector3(cos(angle), 0.0, sin(angle))
    direction = direction.normalized()
    var radius := (maxf(32.0, float(entry.get("townRadius", 18))) + 4.0) * CELL
    var position := center + direction * radius
    var ground_y: float = surface_y_at_position(position)
    if ground_y < main.WATER_LEVEL + 0.55:
        return Vector3.INF
    position.y = ground_y + 0.04
    if world.point_inside_work_area(entry, position) and not world.point_inside_town(entry, position):
        return position
    return Vector3.INF

func add_path_candidates(candidates: Array[Vector3], entry: Dictionary, outside_only := false) -> void:
    if world == null:
        return
    var center: Vector2i = entry.get("townCenter", entry.get("homeCell", Vector2i.ZERO))
    var radius := maxi(6, int(entry.get("townRadius", 18)))
    var offsets: Array[int] = []
    if outside_only:
        offsets = [radius + 3, -(radius + 3)]
    else:
        var near_step := maxi(3, radius / 4)
        var far_step := maxi(near_step + 2, radius / 2)
        offsets = [0, near_step, -near_step, far_step, -far_step]
    var seen := {}
    for offset in offsets:
        for cell in [center + Vector2i(offset, 0), center + Vector2i(0, offset)]:
            var key := "%d,%d" % [cell.x, cell.y]
            if seen.has(key):
                continue
            seen[key] = true
            var pos: Vector3 = world.cell_position(cell)
            if outside_only and world.point_inside_town(entry, pos):
                continue
            if not outside_only and not world.point_inside_town(entry, pos):
                continue
            if not world.point_inside_work_area(entry, pos):
                continue
            candidates.append(pos)

func add_utility_anchor_candidates(candidates: Array[Vector3], entry: Dictionary) -> void:
    if main == null or world == null:
        return
    var blocks: Dictionary = main.get("blocks")
    var utility_types := ["traderStall", "workbench", "furnace", "chest", "bed", "campfire", "anvil"]
    var body := entry.get("body") as Node3D
    var origin: Vector3 = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
    var utility_nodes: Array[Node3D] = []
    for value in blocks.values():
        var node := value as Node3D
        if node == null or not is_instance_valid(node):
            continue
        if not (String(node.get_meta("block_type", "")) in utility_types):
            continue
        if not world.point_inside_town(entry, node.global_position):
            continue
        utility_nodes.append(node)
    utility_nodes.sort_custom(func(a: Node3D, b: Node3D) -> bool:
        return a.global_position.distance_squared_to(origin) < b.global_position.distance_squared_to(origin)
    )
    var added := 0
    for node in utility_nodes:
        for cell in world.approach_cells_for_target(entry, node.global_position, false):
            var pos: Vector3 = world.cell_position(cell)
            if world.point_inside_town(entry, pos):
                candidates.append(pos)
                added += 1
                break
        if added >= 8:
            break

func add_resource_prop_candidates(candidates: Array[Vector3], entry: Dictionary, job: String) -> void:
    if main == null or world == null or not (job in ["wood", "stone", "forage"]):
        return
    var body := entry.get("body") as Node3D
    var origin: Vector3 = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
    var outside_town_job := resource_job_uses_outside_work_area(job)
    var props: Array[Node3D] = indexed_resource_props(entry, job)
    var indexed_count := props.size()
    props = filter_job_props(entry, job, props)
    var filtered_indexed_count := props.size()
    var scanned_nodes := 0
    var scanned_props_before := props.size()
    if props.is_empty() and allow_resource_scan_fallback():
        var remaining_scan_nodes := RESOURCE_SCAN_NODE_LIMIT
        for root_value in [main.get("prop_root"), main.get("chunk_root")]:
            remaining_scan_nodes = collect_job_props(root_value as Node, entry, job, props, remaining_scan_nodes, RESOURCE_SCAN_CANDIDATE_LIMIT)
            if remaining_scan_nodes <= 0 or props.size() >= RESOURCE_SCAN_CANDIDATE_LIMIT:
                break
        scanned_nodes = RESOURCE_SCAN_NODE_LIMIT - remaining_scan_nodes
    props.sort_custom(func(a: Node3D, b: Node3D) -> bool:
        return a.global_position.distance_squared_to(origin) < b.global_position.distance_squared_to(origin)
    )
    var checked := 0
    var approach_hits := 0
    for prop in props:
        checked += 1
        if checked > 10:
            break
        var approach_cells: Array[Vector2i] = world.approach_cells_for_target(entry, prop.global_position, true)
        var added_for_prop := false
        for cell in approach_cells:
            var pos: Vector3 = world.cell_position(cell)
            if job_position_allowed(entry, pos, outside_town_job):
                candidates.append(pos)
                added_for_prop = true
                approach_hits += 1
                break
        if not added_for_prop:
            continue
    entry["lastResourceCandidateDebug"] = {
        "job": job,
        "outsideTown": outside_town_job,
        "indexed": indexed_count,
        "filteredIndexed": filtered_indexed_count,
        "scannedNodes": scanned_nodes,
        "scanAdded": props.size() - scanned_props_before,
        "checked": checked,
        "approachHits": approach_hits,
        "positions": candidates.size()
    }

func indexed_resource_props(entry: Dictionary, job: String) -> Array[Node3D]:
    var service = smart_object_service()
    if service == null or not service.has_method("query_resource_nodes"):
        return []
    var options := {
        "limit": RESOURCE_SCAN_CANDIDATE_LIMIT,
        "outsideTown": resource_job_uses_outside_work_area(job),
        "workAreaOnly": true,
        "chunkRadius": 2,
        "cacheFrames": 30
    }
    if job == "forage":
        options["drops"] = ["berries"]
    return service.query_resource_nodes(entry, resource_kinds_for_job(job), options)

func resource_job_uses_outside_work_area(job: String) -> bool:
    return job == "forage"

func filter_job_props(entry: Dictionary, job: String, props: Array[Node3D]) -> Array[Node3D]:
    var filtered: Array[Node3D] = []
    for prop in props:
        if prop_matches_job(prop, entry, job):
            filtered.append(prop)
    return filtered

func smart_object_service():
    if system == null or not system.has_method("smart_object_service"):
        return null
    return system.smart_object_service()

func resource_kinds_for_job(job: String) -> Array:
    if job == "wood":
        return ["tree_source"]
    if job == "stone":
        return ["stone_source"]
    if job == "forage":
        return ["forage_source"]
    return []

func allow_resource_scan_fallback() -> bool:
    return OS.get_environment("VOXEL_NPC_ALLOW_RESOURCE_SCAN") == "1"

func collect_job_props(root: Node, entry: Dictionary, job: String, props: Array[Node3D], max_nodes: int, max_props: int) -> int:
    if root == null or max_nodes <= 0 or props.size() >= max_props:
        return max_nodes
    var stack: Array[Node] = [root]
    var scanned := 0
    while not stack.is_empty() and scanned < max_nodes and props.size() < max_props:
        var node := stack.pop_back() as Node
        scanned += 1
        if node == null:
            continue
        if node is Node3D and prop_matches_job(node as Node3D, entry, job):
            props.append(node as Node3D)
        for child in node.get_children():
            stack.append(child)
    return max_nodes - scanned

func prop_matches_job(prop: Node3D, entry: Dictionary, job: String) -> bool:
    if not is_instance_valid(prop) or bool(prop.get_meta("npc_harvested", false)):
        return false
    if String(prop.get_meta("kind", "")) != "prop":
        return false
    if not world.point_inside_work_area(entry, prop.global_position):
        return false
    if surface_y_at_position(prop.global_position) < main.WATER_LEVEL + 0.45:
        return false
    var material := String(prop.get_meta("material", ""))
    var drop := String(prop.get_meta("drop", ""))
    if job == "wood":
        return material == "tree" or drop == "logs"
    if job == "stone":
        return material in ["rock", "copperOre", "ironOre"] or drop in ["stones", "copperOre", "ironOre"]
    if job == "forage":
        return material == "berryBush" or drop == "berries"
    return false

func job_position_allowed(entry: Dictionary, position: Vector3, outside_town_job: bool) -> bool:
    if not world.point_inside_work_area(entry, position):
        return false
    if outside_town_job:
        return not world.point_inside_town(entry, position)
    return world.point_inside_town(entry, position)

func guard_post_candidates(entry: Dictionary) -> Array[Vector3]:
    var assigned_guard_post: Vector3 = entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO))
    var candidates: Array[Vector3] = [
        assigned_guard_post,
        entry.get("porchPosition", Vector3.ZERO)
    ]
    if world != null and assigned_guard_post != Vector3.INF:
        var guard_cell: Vector2i = world.world_cell(assigned_guard_post)
        for radius in range(1, 3):
            for dx in range(-radius, radius + 1):
                for dz in range(-radius, radius + 1):
                    if max(absi(dx), absi(dz)) != radius:
                        continue
                    candidates.append(world.cell_position(guard_cell + Vector2i(dx, dz)))
    add_path_candidates(candidates, entry, false)
    add_utility_anchor_candidates(candidates, entry)
    return candidates

func hostile_intercept_candidates(entry: Dictionary, hostile: Node3D, melee := false) -> Array[Vector3]:
    var candidates: Array[Vector3] = []
    var hostile_cell: Vector2i = world.world_cell(hostile.global_position)
    var min_radius := 1 if melee else 3
    var max_radius := 2 if melee else 6
    var snapshot: Dictionary = navigation_snapshot(entry, true, false)
    for radius in range(min_radius, max_radius + 1):
        for dx in range(-radius, radius + 1):
            for dz in range(-radius, radius + 1):
                if max(abs(dx), abs(dz)) != radius:
                    continue
                var cell: Vector2i = hostile_cell + Vector2i(dx, dz)
                var pos: Vector3 = world.cell_position(cell)
                if not world.point_inside_work_area(entry, pos):
                    continue
                if surface_y_at_position(pos) < main.WATER_LEVEL + 0.45:
                    continue
                if not line_of_sight_cells_clear(entry, snapshot, pos, hostile.global_position):
                    continue
                candidates.append(pos)
    return candidates

func line_of_sight_cells_clear(_entry: Dictionary, snapshot: Dictionary, from_pos: Vector3, to_pos: Vector3) -> bool:
    var from_cell: Vector2i = world.world_cell(from_pos)
    var to_cell: Vector2i = world.world_cell(to_pos)
    var delta := to_pos - from_pos
    delta.y = 0.0
    var samples := clampi(ceili(delta.length() / (CELL * 0.65)), 1, 24)
    for i in range(1, samples):
        var t := float(i) / float(samples)
        var sample := from_pos.lerp(to_pos, t)
        var cell: Vector2i = world.world_cell(sample)
        if cell == from_cell or cell == to_cell:
            continue
        if world.static_blocker(snapshot, cell) != null:
            return false
    return true

func position_can_be_goal(entry: Dictionary, position: Vector3, allow_outside := false, moving_home := false) -> bool:
    if position == Vector3.INF:
        return false
    if not world.point_allowed(entry, position, allow_outside, moving_home):
        return false
    if world.has_method("cell_is_standable_goal"):
        var cell: Vector2i = world.world_cell(position) if world.has_method("world_cell") else Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))
        if not bool(world.cell_is_standable_goal(entry, cell, allow_outside, moving_home)):
            return false
    return surface_y_at_position(position) >= main.WATER_LEVEL + 0.45

func unique_positions(candidates: Array[Vector3]) -> Array[Vector3]:
    var result: Array[Vector3] = []
    var seen := {}
    for pos in candidates:
        if pos == Vector3.INF:
            continue
        var key := position_key(pos)
        if seen.has(key):
            continue
        seen[key] = true
        result.append(pos)
    return result

func position_key(pos: Vector3) -> String:
    return "%d,%d" % [roundi(pos.x / CELL), roundi(pos.z / CELL)]

func set_goal_fallback(entry: Dictionary, status: String, reason: String) -> void:
    entry["routeStatus"] = status
    entry["routeReason"] = reason
    var body := entry.get("body") as Node
    if body:
        body.set_meta("npc_route_status", status)
        body.set_meta("npc_route_reason", reason)

func clear_goal_fallback(entry: Dictionary) -> void:
    if String(entry.get("routeReason", "")).begins_with("no_reachable_"):
        entry["routeReason"] = ""
        var body := entry.get("body") as Node
        if body:
            body.set_meta("npc_route_reason", "")

func add_deterministic_ring_candidates(candidates: Array[Vector3], entry: Dictionary, outside_town := false) -> void:
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var town_radius: float = maxf(32.0, float(entry.get("townRadius", 18))) if outside_town else float(entry.get("townRadius", 18))
    var job: String = String(entry.get("job", "wander"))
    var rng: RandomNumberGenerator = deterministic_rng(entry, "job" if outside_town else "wander")
    for attempt in range(10):
        var base_radius: float = town_radius + rng.randf_range(5.0, 16.0) if outside_town else rng.randf_range(2.5, maxf(4.5, town_radius - 4.0))
        if outside_town and job == "stone":
            base_radius += rng.randf_range(4.0, 9.0)
        var angle: float = rng.randf() * TAU + float(attempt) * 0.29
        var position: Vector3 = Vector3(float(center.x) * CELL + cos(angle) * base_radius * CELL, 0.0, float(center.y) * CELL + sin(angle) * base_radius * CELL)
        var ground_y: float = surface_y_at_position(position)
        if ground_y < main.WATER_LEVEL + 0.5:
            continue
        position.y = ground_y + 0.04
        if outside_town:
            if world.point_inside_work_area(entry, position) and not world.point_inside_town(entry, position):
                candidates.append(position)
        elif world.point_inside_town(entry, position):
            candidates.append(position)

func add_forage_search_sweep_candidates(candidates: Array[Vector3], entry: Dictionary) -> void:
    if world == null or main == null:
        return
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var center_position := Vector3(float(center.x) * CELL, 0.0, float(center.y) * CELL)
    var home: Vector3 = entry.get("homePosition", entry.get("porchPosition", center_position))
    var search_serial := int(entry.get("forageSearchSerial", 0))
    var direction := home - center_position
    direction.y = 0.0
    if direction.length_squared() < 0.001:
        var fallback_rng := deterministic_rng(entry, "forage_search_direction")
        var fallback_angle := fallback_rng.randf() * TAU
        direction = Vector3(cos(fallback_angle), 0.0, sin(fallback_angle))
    direction = direction.normalized()
    var base_radius := maxf(float(entry.get("townRadius", 18)) + 7.0, 24.0)
    var angles := [
        0.0,
        0.58,
        -0.58,
        1.15,
        -1.15,
        PI
    ]
    for index in range(angles.size()):
        var serial_turn := float((search_serial + index) % angles.size()) * 0.41
        var angle := atan2(direction.z, direction.x) + float(angles[index]) + serial_turn
        var radius_cells := base_radius + float((search_serial + index * 3) % 10)
        var position := Vector3(float(center.x) * CELL + cos(angle) * radius_cells * CELL, 0.0, float(center.y) * CELL + sin(angle) * radius_cells * CELL)
        var ground_y := surface_y_at_position(position)
        if ground_y < main.WATER_LEVEL + 0.5:
            continue
        position.y = ground_y + 0.04
        if world.point_inside_work_area(entry, position) and not world.point_inside_town(entry, position):
            candidates.append(position)

func deterministic_rng(entry: Dictionary, goal_kind: String) -> RandomNumberGenerator:
    var rng := RandomNumberGenerator.new()
    var seed_text: String = ""
    if main != null:
        seed_text = String(main.get("seed_text"))
        if seed_text == "":
            seed_text = String(main.get("world_seed"))
    var search_serial := int(entry.get("forageSearchSerial", 0)) if String(entry.get("job", "")) == "forage" else 0
    var key: String = "%s:%s:%s:%s:%d" % [
        seed_text,
        String(entry.get("id", "npc")),
        goal_kind,
        String(entry.get("jobPhase", "")),
        int(entry.get("jobRuns", 0)) + search_serial
    ]
    rng.seed = hash(key)
    return rng
