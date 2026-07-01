extends RefCounted
class_name StructureSystem

const StructureDoorRulesScript := preload("res://scripts/StructureDoorRules.gd")
const StructureLootScript := preload("res://scripts/StructureLoot.gd")
const CaveInteriorBuilderScript := preload("res://scripts/CaveInteriorBuilder.gd")
const CAVE_SPAWN_CHANCE := 0.18
const CAVE_SEARCH_ATTEMPTS := 72
const CAVE_CLIFF_VARIATION_MIN := 1.15
const CAVE_UNDERGROUND_VARIATION_MAX := 1.95

var main
var loot
var generated_towns := {}
var generated_structures := {}
var generated_caves := {}
var generated_building_count := 0
var generated_town_count := 0
var generated_mine_count := 0
var generated_ruin_count := 0
var generated_shrine_count := 0
var generated_camp_count := 0
var generated_cave_count := 0
var generated_path_count := 0
var generated_door_count := 0
var generated_utility_count := 0
var town_home_records := {}
var cave_records := {}
var cave_interior_nodes := {}
var cave_terrain_cells := {}
var cave_prop_exclusion_cells := {}
var cave_navigation_records := {}
var cave_navigation_cells := {}
var cave_interior_builder

func setup(main_node) -> void:
    main = main_node
    loot = StructureLootScript.new()
    cave_interior_builder = CaveInteriorBuilderScript.new()
    cave_interior_builder.setup(main)

func reset() -> void:
    generated_towns.clear()
    generated_structures.clear()
    generated_caves.clear()
    generated_building_count = 0
    generated_town_count = 0
    generated_mine_count = 0
    generated_ruin_count = 0
    generated_shrine_count = 0
    generated_camp_count = 0
    generated_cave_count = 0
    generated_path_count = 0
    generated_door_count = 0
    generated_utility_count = 0
    town_home_records.clear()
    clear_generated_cave_runtime_state(false)

func clear_generated_cave_runtime_state(remove_blocks := true) -> void:
    cave_records.clear()
    cave_terrain_cells.clear()
    cave_prop_exclusion_cells.clear()
    cave_navigation_records.clear()
    cave_navigation_cells.clear()
    for node in cave_interior_nodes.values():
        if node is Node and is_instance_valid(node):
            (node as Node).queue_free()
    cave_interior_nodes.clear()
    if remove_blocks and main != null:
        var blocks_value = main.get("blocks")
        if blocks_value is Dictionary:
            var blocks: Dictionary = blocks_value
            for key in blocks.keys().duplicate():
                var block := blocks[key] as Node
                if block == null or String(block.get_meta("generatedTier", "")) != "cave":
                    continue
                if main.get("npc_system") != null and main.get("npc_system").has_method("notify_navigation_block_removed") and block.has_meta("cell"):
                    main.get("npc_system").notify_navigation_block_removed(block.get_meta("cell"), String(block.get_meta("block_type", "")), block)
                block.queue_free()
                blocks.erase(key)

func update_around(center_cell: Vector2i) -> void:
    if main == null:
        return
    update_towns(center_cell)
    update_standalone_structures(center_cell)
    update_caves(center_cell)

func update_towns(center_cell: Vector2i) -> void:
    var center_region := Vector2i(floori(float(center_cell.x) / float(main.TOWN_REGION_CELLS)), floori(float(center_cell.y) / float(main.TOWN_REGION_CELLS)))
    for rz in range(center_region.y - 1, center_region.y + 2):
        for rx in range(center_region.x - 1, center_region.x + 2):
            var key := Vector2i(rx, rz)
            if generated_towns.has(key):
                continue
            var town: Dictionary = main.town_region(rx, rz)
            if town.is_empty():
                continue
            var distance := Vector2(float(center_cell.x - int(town["centerX"])), float(center_cell.y - int(town["centerZ"]))).length()
            var active_render_distance: int = int(main.get("render_distance"))
            if active_render_distance <= 0:
                active_render_distance = main.RENDER_DISTANCE
            var activation_range: float = float(main.TOWN_RADIUS_CELLS + main.CHUNK_SIZE * active_render_distance + 20)
            if distance > activation_range:
                continue
            generated_towns[key] = true
            build_town(town)

func update_standalone_structures(center_cell: Vector2i) -> void:
    var center_region := Vector2i(floori(float(center_cell.x) / float(main.STRUCTURE_REGION_CELLS)), floori(float(center_cell.y) / float(main.STRUCTURE_REGION_CELLS)))
    for rz in range(center_region.y - 1, center_region.y + 2):
        for rx in range(center_region.x - 1, center_region.x + 2):
            var key := Vector2i(rx, rz)
            if generated_structures.has(key):
                continue
            var roll: float = main.hash01("structure:%d,%d" % [rx, rz])
            if roll > main.STRUCTURE_SPAWN_CHANCE:
                continue
            var rng := RandomNumberGenerator.new()
            rng.seed = main.hash_string("%s:structure:%d,%d" % [main.seed_text, rx, rz])
            var base_x: int = rx * main.STRUCTURE_REGION_CELLS + rng.randi_range(16, main.STRUCTURE_REGION_CELLS - 18)
            var base_z: int = rz * main.STRUCTURE_REGION_CELLS + rng.randi_range(16, main.STRUCTURE_REGION_CELLS - 18)
            var structure_type := standalone_structure_type(rng)
            var dimensions := structure_dimensions_for_type(structure_type, rng)
            var level := flat_level_for_footprint(base_x, base_z, dimensions.x, dimensions.y)
            if is_nan(level):
                generated_structures[key] = false
                continue
            generated_structures[key] = true
            if structure_type == "mine":
                build_mine(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            elif structure_type == "ruin":
                build_ruin(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            elif structure_type == "shrine":
                build_shrine(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            elif structure_type == "camp":
                build_camp(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            else:
                var wall_type := "woodBlock" if rng.randf() < 0.5 else "stoneBlock"
                var roof_type := "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
                build_building(base_x, base_z, level, dimensions.x, dimensions.y, rng.randi_range(4, 5), wall_type, roof_type, rng.randi_range(0, 3), rng, false)

func update_caves(center_cell: Vector2i) -> void:
    var center_region := Vector2i(floori(float(center_cell.x) / float(main.STRUCTURE_REGION_CELLS)), floori(float(center_cell.y) / float(main.STRUCTURE_REGION_CELLS)))
    for rz in range(center_region.y - 1, center_region.y + 2):
        for rx in range(center_region.x - 1, center_region.x + 2):
            var key := Vector2i(rx, rz)
            if generated_caves.has(key):
                continue
            var plan := cave_plan_for_region(rx, rz, "", true)
            if plan.is_empty():
                generated_caves[key] = false
                continue
            generated_caves[key] = true
            var rng := RandomNumberGenerator.new()
            rng.seed = main.hash_string("%s:cave-build:%d,%d" % [main.seed_text, rx, rz])
            build_cave(plan, rng)

func cave_plan_for_region(region_x: int, region_z: int, preferred_kind := "", require_spawn_roll := true) -> Dictionary:
    if main == null:
        return {}
    if require_spawn_roll:
        var roll: float = main.hash01("cave:%d,%d" % [region_x, region_z])
        if roll > CAVE_SPAWN_CHANCE:
            return {}
    var rng := RandomNumberGenerator.new()
    rng.seed = main.hash_string("%s:cave:%d,%d" % [main.seed_text, region_x, region_z])
    var kind := preferred_kind.strip_edges().to_lower()
    if kind == "":
        kind = "cliff" if rng.randf() < 0.76 else "underground"
    var plan := best_cave_plan_candidate(region_x, region_z, kind, rng)
    if plan.is_empty() and kind == "cliff":
        rng.seed = main.hash_string("%s:cave-underground-fallback:%d,%d" % [main.seed_text, region_x, region_z])
        plan = best_cave_plan_candidate(region_x, region_z, "underground", rng)
    return plan

func find_cave_plan_sample(preferred_kind := "", search_radius_regions := 8, require_spawn_roll := false) -> Dictionary:
    for radius in range(0, search_radius_regions + 1):
        var best_plan := {}
        var best_score := INF
        for rz in range(-radius, radius + 1):
            for rx in range(-radius, radius + 1):
                if radius > 0 and absi(rx) != radius and absi(rz) != radius:
                    continue
                var plan := cave_plan_for_region(rx, rz, preferred_kind, require_spawn_roll)
                if plan.is_empty():
                    continue
                var distance_score := Vector2(float(rx), float(rz)).length()
                var plan_score: float = distance_score + main.hash01("cave-sample:%d,%d:%s" % [rx, rz, String(plan.get("kind", ""))])
                if plan_score < best_score:
                    best_score = plan_score
                    best_plan = plan
        if not best_plan.is_empty():
            return best_plan
    return {}

func best_cave_plan_candidate(region_x: int, region_z: int, kind: String, rng: RandomNumberGenerator) -> Dictionary:
    var best_data := {}
    var best_score := -INF
    var region_size := int(main.STRUCTURE_REGION_CELLS)
    var margin := 18
    for attempt in range(CAVE_SEARCH_ATTEMPTS):
        var entrance_x := region_x * region_size + rng.randi_range(margin, region_size - margin)
        var entrance_z := region_z * region_size + rng.randi_range(margin, region_size - margin)
        var entrance := Vector2i(entrance_x, entrance_z)
        var height := float(main.terrain_height_cell(entrance.x, entrance.y))
        if height <= float(main.WATER_LEVEL) + main.CELL * 6.0:
            continue
        var variation := float(main.height_variation_cell(entrance.x, entrance.y, 3)) / float(main.CELL)
        if kind == "cliff" and variation < CAVE_CLIFF_VARIATION_MIN:
            continue
        if kind == "underground" and variation > CAVE_UNDERGROUND_VARIATION_MAX:
            continue
        var side := rng.randi_range(0, 3)
        var path_length := rng.randi_range(14, 20)
        var chamber_radius := rng.randi_range(3, 4)
        var score := height * 0.12 + variation * (4.0 if kind == "cliff" else -2.0) - float(attempt) * 0.01
        if kind == "underground":
            score += maxf(0.0, 2.0 - variation) * 2.0
        if score <= best_score:
            continue
        best_score = score
        best_data = {
            "entrance": entrance,
            "side": side,
            "pathLength": path_length,
            "chamberRadius": chamber_radius,
            "height": height,
            "variation": variation
        }
    if best_data.is_empty():
        return {}
    return make_cave_plan(
        region_x,
        region_z,
        best_data.get("entrance", Vector2i.ZERO),
        int(best_data.get("side", 0)),
        int(best_data.get("pathLength", 16)),
        int(best_data.get("chamberRadius", 3)),
        kind,
        float(best_data.get("height", 0.0)),
        float(best_data.get("variation", 0.0))
    )

func make_cave_plan(region_x: int, region_z: int, entrance: Vector2i, side: int, path_length: int, chamber_radius: int, kind: String, level: float, entrance_variation: float) -> Dictionary:
    var inward := inward_for_side(side)
    var right := Vector2i(-inward.y, inward.x)
    var id := "cave:%d,%d:%d,%d" % [region_x, region_z, entrance.x, entrance.y]
    var floor_drop: float = main.CELL * (5.35 if kind == "cliff" else 6.1)
    var floor_level := maxf(float(main.WATER_LEVEL) + main.CELL * 2.0, level - floor_drop)
    var desired_clearance: float = main.CELL * (3.15 + main.hash01("cave-clearance:%s" % id) * 0.72)
    var ceiling_level := minf(level - main.CELL * 1.15, floor_level + desired_clearance)
    if ceiling_level < floor_level + main.CELL * 2.65:
        ceiling_level = floor_level + main.CELL * 2.65
    var approach_cells: Array[Vector2i] = []
    for z in range(-5, 0):
        for x in range(-1, 2):
            approach_cells.append(entrance + right * x + inward * z)
    var graph := make_cave_graph(id, entrance, inward, right, path_length, chamber_radius)
    var final_chamber_id := String(graph.get("finalChamberId", "final"))
    var final_chamber_cell := cave_graph_node_cell(graph.get("nodes", []), final_chamber_id, entrance + inward * path_length)
    var chest_cell: Vector2i = graph.get("finalChestCell", final_chamber_cell + inward * maxi(1, chamber_radius - 1))
    return {
        "id": id,
        "region": Vector2i(region_x, region_z),
        "kind": kind,
        "entranceSide": side,
        "entranceCell": entrance,
        "inward": inward,
        "right": right,
        "surfaceLevel": level,
        "level": floor_level,
        "ceilingLevel": ceiling_level,
        "entranceOpenDepth": 4,
        "entranceVariation": entrance_variation,
        "pathLength": path_length,
        "chamberRadius": chamber_radius,
        "approachCells": approach_cells,
        "pathCells": graph.get("pathCells", []),
        "chamberCells": graph.get("chamberCells", []),
        "caveNodes": graph.get("nodes", []),
        "caveEdges": graph.get("edges", []),
        "branchChamberIds": graph.get("branchChamberIds", []),
        "deadEndChamberIds": graph.get("deadEndChamberIds", []),
        "finalChamberId": final_chamber_id,
        "finalChamberCell": final_chamber_cell,
        "finalChestCell": chest_cell
    }

func make_cave_graph(id: String, entrance: Vector2i, inward: Vector2i, right: Vector2i, path_length: int, chamber_radius: int) -> Dictionary:
    var final_depth: int = path_length + chamber_radius + 4 + int(main.hash01("cave-graph-final-depth:%s" % id) * 5.0)
    var main_count: int = 3 + int(main.hash01("cave-graph-main-count:%s" % id) * 3.0)
    var dead_end_count: int = 1 + int(main.hash01("cave-graph-dead-end-count:%s" % id) * 3.0)
    var side_chamber_count: int = 1 + int(main.hash01("cave-graph-side-chamber-count:%s" % id) * 2.0)
    var nodes: Array[Dictionary] = [cave_graph_node("entrance", "entrance", entrance, 2)]
    var edges: Array[Dictionary] = []
    var main_node_ids: Array[String] = []
    var main_depths: Array[int] = []
    var main_laterals: Array[int] = []
    var last_depth := 0
    for i in range(1, main_count + 1):
        var node_id := "main_%d" % i
        var progress := float(i) / float(main_count + 1)
        var jitter: int = roundi(lerpf(-2.0, 2.0, main.hash01("cave-graph-main-depth-jitter:%s:%d" % [id, i])))
        var depth: int = clampi(roundi(lerpf(5.0, float(final_depth - 4), progress)) + jitter, last_depth + 4, final_depth - 3)
        var lateral_range: int = 2 + i
        var lateral := cave_graph_lateral(id, node_id, lateral_range)
        var radius := 3 + int(main.hash01("cave-graph-main-radius:%s:%d" % [id, i]) * 2.0)
        var kind := "junction" if i == 1 else "chamber"
        nodes.append(cave_graph_node(node_id, kind, cave_axis_cell(entrance, inward, right, depth, lateral), radius))
        main_node_ids.append(node_id)
        main_depths.append(depth)
        main_laterals.append(lateral)
        last_depth = depth
    var final_lateral := cave_graph_lateral(id, "final", maxi(4, main_count + 2))
    nodes.append(cave_graph_node("final", "final", cave_axis_cell(entrance, inward, right, final_depth, final_lateral), chamber_radius + 2))
    var previous_id := "entrance"
    for node_id in main_node_ids:
        var main_edge_id := "%s_to_%s" % [previous_id, node_id]
        var base_radius: float = 1.72 + main.hash01("cave-graph-main-edge:%s:%s" % [id, node_id]) * 0.35
        edges.append(cave_graph_edge(main_edge_id, previous_id, node_id, cave_edge_radius(id, main_edge_id, base_radius)))
        previous_id = node_id
    var final_edge_id := "%s_to_final" % previous_id
    edges.append(cave_graph_edge(final_edge_id, previous_id, "final", cave_edge_radius(id, final_edge_id, 1.86)))
    for i in range(dead_end_count):
        var anchor_index: int = int(main.hash01("cave-graph-dead-anchor:%s:%d" % [id, i]) * float(main_node_ids.size()))
        anchor_index = clampi(anchor_index, 0, main_node_ids.size() - 1)
        var anchor_id := main_node_ids[anchor_index]
        var anchor_depth := main_depths[anchor_index]
        var anchor_lateral := main_laterals[anchor_index]
        var side_sign := -1 if main.hash01("cave-graph-dead-side:%s:%d" % [id, i]) < 0.5 else 1
        var depth_offset: int = roundi(lerpf(-1.0, 3.0, main.hash01("cave-graph-dead-depth:%s:%d" % [id, i])))
        var lateral_offset: int = side_sign * (5 + int(main.hash01("cave-graph-dead-lateral:%s:%d" % [id, i]) * 5.0) + i)
        var dead_id := "dead_end_%d" % (i + 1)
        var dead_depth: int = clampi(anchor_depth + depth_offset, 4, final_depth - 2)
        var dead_lateral := anchor_lateral + lateral_offset
        nodes.append(cave_graph_node(dead_id, "dead_end", cave_axis_cell(entrance, inward, right, dead_depth, dead_lateral), 3))
        var dead_edge_id := "%s_to_%s" % [anchor_id, dead_id]
        edges.append(cave_graph_edge(dead_edge_id, anchor_id, dead_id, cave_edge_radius(id, dead_edge_id, 1.45)))
    for i in range(side_chamber_count):
        var anchor_index: int = int(main.hash01("cave-graph-side-anchor:%s:%d" % [id, i]) * float(main_node_ids.size()))
        anchor_index = clampi(anchor_index, 0, main_node_ids.size() - 1)
        var target_index: int = clampi(anchor_index + 1 + int(main.hash01("cave-graph-side-target:%s:%d" % [id, i]) * 2.0), 0, main_node_ids.size())
        var anchor_id := main_node_ids[anchor_index]
        var target_id := "final" if target_index >= main_node_ids.size() else main_node_ids[target_index]
        if target_id == anchor_id:
            target_id = "final"
        var anchor_depth := main_depths[anchor_index]
        var target_depth := final_depth if target_id == "final" else main_depths[target_index]
        var anchor_lateral := main_laterals[anchor_index]
        var target_lateral := final_lateral if target_id == "final" else main_laterals[target_index]
        var side_sign := -1 if main.hash01("cave-graph-loop-side:%s:%d" % [id, i]) < 0.5 else 1
        var side_id := "side_chamber_%d" % (i + 1)
        var side_depth: int = clampi(roundi((float(anchor_depth) + float(target_depth)) * 0.5) + roundi(lerpf(-2.0, 2.0, main.hash01("cave-graph-loop-depth:%s:%d" % [id, i]))), anchor_depth + 2, target_depth - 1)
        var side_lateral: int = roundi((float(anchor_lateral) + float(target_lateral)) * 0.5) + side_sign * (4 + int(main.hash01("cave-graph-loop-lateral:%s:%d" % [id, i]) * 4.0))
        nodes.append(cave_graph_node(side_id, "side_chamber", cave_axis_cell(entrance, inward, right, side_depth, side_lateral), 3))
        var edge_to_side_id := "%s_to_%s" % [anchor_id, side_id]
        var edge_from_side_id := "%s_to_%s" % [side_id, target_id]
        edges.append(cave_graph_edge(edge_to_side_id, anchor_id, side_id, cave_edge_radius(id, edge_to_side_id, 1.48)))
        edges.append(cave_graph_edge(edge_from_side_id, side_id, target_id, cave_edge_radius(id, edge_from_side_id, 1.48)))
    if main_node_ids.is_empty():
        edges.append(cave_graph_edge("entrance_to_final", "entrance", "final", cave_edge_radius(id, "entrance_to_final", 1.85)))
    var path_lookup := {}
    var chamber_lookup := {}
    for node_value in nodes:
        var node: Dictionary = node_value
        cave_add_chamber_cells(chamber_lookup, node, id)
    for index in range(edges.size()):
        var edge: Dictionary = edges[index]
        var from_cell := cave_graph_node_cell(nodes, String(edge.get("from", "")), entrance)
        var to_cell := cave_graph_node_cell(nodes, String(edge.get("to", "")), entrance)
        var center_cells := cave_edge_center_cells(from_cell, to_cell)
        edge["centerCells"] = center_cells
        edges[index] = edge
        cave_add_tunnel_cells(path_lookup, center_cells, float(edge.get("radius", 1.6)), id, String(edge.get("id", "")))
    var degree := {}
    for edge_value in edges:
        var edge: Dictionary = edge_value
        var from_id := String(edge.get("from", ""))
        var to_id := String(edge.get("to", ""))
        degree[from_id] = int(degree.get(from_id, 0)) + 1
        degree[to_id] = int(degree.get(to_id, 0)) + 1
    var branch_ids: Array[String] = []
    var dead_end_ids: Array[String] = []
    for node_value in nodes:
        var node: Dictionary = node_value
        var node_id := String(node.get("id", ""))
        if node_id == "entrance":
            continue
        var node_degree := int(degree.get(node_id, 0))
        if node_degree >= 3:
            branch_ids.append(node_id)
        if String(node.get("kind", "")) == "dead_end" or (node_degree <= 1 and node_id != "final"):
            dead_end_ids.append(node_id)
    var final_cell := cave_graph_node_cell(nodes, "final", entrance + inward * final_depth)
    return {
        "nodes": nodes,
        "edges": edges,
        "branchChamberIds": branch_ids,
        "deadEndChamberIds": dead_end_ids,
        "finalChamberId": "final",
        "finalChestCell": final_cell + inward * maxi(1, chamber_radius - 1),
        "pathCells": sorted_cave_cells_from_lookup(path_lookup),
        "chamberCells": sorted_cave_cells_from_lookup(chamber_lookup)
    }

func cave_axis_cell(entrance: Vector2i, inward: Vector2i, right: Vector2i, depth: int, lateral: int) -> Vector2i:
    return entrance + inward * depth + right * lateral

func cave_graph_lateral(id: String, salt: String, max_abs: int) -> int:
    return roundi(lerpf(float(-max_abs), float(max_abs), main.hash01("cave-graph-lateral:%s:%s" % [id, salt])))

func cave_graph_node(node_id: String, kind: String, cell: Vector2i, radius: int) -> Dictionary:
    return {
        "id": node_id,
        "kind": kind,
        "cell": cell,
        "radius": radius
    }

func cave_graph_edge(edge_id: String, from_id: String, to_id: String, radius: float) -> Dictionary:
    return {
        "id": edge_id,
        "from": from_id,
        "to": to_id,
        "radius": radius
    }

func cave_edge_radius(cave_id: String, edge_id: String, base_radius: float) -> float:
    var roll: float = main.hash01("cave-edge-tightness:%s:%s" % [cave_id, edge_id])
    if roll < 0.42:
        return maxf(0.86, base_radius * 0.58)
    if roll < 0.72:
        return maxf(1.05, base_radius * 0.78)
    return base_radius

func cave_graph_node_cell(nodes: Array, node_id: String, fallback: Vector2i) -> Vector2i:
    for node_value in nodes:
        if not (node_value is Dictionary):
            continue
        var node: Dictionary = node_value
        if String(node.get("id", "")) == node_id:
            return node.get("cell", fallback)
    return fallback

func cave_edge_center_cells(from_cell: Vector2i, to_cell: Vector2i) -> Array[Vector2i]:
    var result: Array[Vector2i] = []
    var steps: int = maxi(absi(to_cell.x - from_cell.x), absi(to_cell.y - from_cell.y))
    if steps <= 0:
        return [from_cell]
    var used := {}
    for i in range(steps + 1):
        var t := float(i) / float(steps)
        var cell := Vector2i(roundi(lerpf(float(from_cell.x), float(to_cell.x), t)), roundi(lerpf(float(from_cell.y), float(to_cell.y), t)))
        if used.has(cell):
            continue
        used[cell] = true
        result.append(cell)
    return result

func cave_add_tunnel_cells(lookup: Dictionary, center_cells: Array[Vector2i], radius: float, id: String, edge_id: String) -> void:
    var expanded := ceili(radius + 1.0)
    for center in center_cells:
        for dz in range(-expanded, expanded + 1):
            for dx in range(-expanded, expanded + 1):
                var offset := Vector2(float(dx), float(dz))
                var rough: float = radius + main.hash01("cave-tunnel-rough:%s:%s:%d,%d" % [id, edge_id, center.x + dx, center.y + dz]) * 0.46
                if offset.length() <= rough:
                    lookup[center + Vector2i(dx, dz)] = true

func cave_add_chamber_cells(lookup: Dictionary, node: Dictionary, id: String) -> void:
    var center: Vector2i = node.get("cell", Vector2i.ZERO)
    var radius := int(node.get("radius", 3))
    var expanded := radius + 2
    var stretch_x: float = 0.86 + main.hash01("cave-chamber-stretch-x:%s:%s" % [id, String(node.get("id", ""))]) * 0.34
    var stretch_z: float = 0.86 + main.hash01("cave-chamber-stretch-z:%s:%s" % [id, String(node.get("id", ""))]) * 0.34
    for dz in range(-expanded, expanded + 1):
        for dx in range(-expanded, expanded + 1):
            var rough: float = float(radius) + main.hash01("cave-chamber-rough:%s:%s:%d,%d" % [id, String(node.get("id", "")), dx, dz]) * 1.15
            var shaped: float = Vector2(float(dx) / stretch_x, float(dz) / stretch_z).length()
            if shaped <= rough:
                lookup[center + Vector2i(dx, dz)] = true

func sorted_cave_cells_from_lookup(lookup: Dictionary) -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    for key in lookup.keys():
        var cell: Vector2i = key
        cells.append(cell)
    cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        if a.x == b.x:
            return a.y < b.y
        return a.x < b.x
    )
    return cells

func inward_for_side(side: int) -> Vector2i:
    if side == 0:
        return Vector2i(0, -1)
    if side == 1:
        return Vector2i(-1, 0)
    if side == 2:
        return Vector2i(0, 1)
    return Vector2i(1, 0)

func standalone_structure_type(rng: RandomNumberGenerator) -> String:
    var roll := rng.randf()
    if roll < 0.12:
        return "shrine"
    if roll < 0.32:
        return "mine"
    if roll < 0.58:
        return "ruin"
    if roll < 0.74:
        return "camp"
    return "cabin"

func structure_dimensions_for_type(structure_type: String, rng: RandomNumberGenerator) -> Vector2i:
    if structure_type == "shrine":
        return Vector2i(9, 9)
    if structure_type == "mine":
        return Vector2i(rng.randi_range(10, 12), rng.randi_range(12, 14))
    if structure_type == "camp":
        return Vector2i(rng.randi_range(11, 13), rng.randi_range(10, 12))
    return Vector2i(rng.randi_range(7, 10), rng.randi_range(7, 10))

func build_town(town: Dictionary) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = main.hash_string("%s:town-build:%d,%d" % [main.seed_text, int(town["regionX"]), int(town["regionZ"])])
    var center_x := int(town["centerX"])
    var center_z := int(town["centerZ"])
    var level := float(town["level"])
    var town_key := town_key_for(town)
    town_home_records[town_key] = []
    generated_town_count += 1
    build_town_paths(center_x, center_z, int(town["radius"]), level)
    build_town_perimeter(center_x, center_z, int(town["radius"]), level, town_key)
    var desired_home_count := town_home_count(town)
    var sites := town_home_sites(town, rng)
    var built_home_count := 0
    for i in range(sites.size()):
        if built_home_count >= desired_home_count:
            break
        var site: Dictionary = sites[i]
        var base_x := center_x + int(site["dx"])
        var base_z := center_z + int(site["dz"])
        var side := int(site["side"])
        if town_home_site_excluded(town, base_x, base_z, 10, 10, side):
            continue
        var width := rng.randi_range(7, 9)
        var depth := rng.randi_range(7, 9)
        var wall_height := rng.randi_range(4, 5)
        var wall_type := "woodBlock" if i % 2 == 0 else "stoneBlock"
        if rng.randf() < 0.35:
            wall_type = "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        var roof_type := "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        if town_home_site_excluded(town, base_x, base_z, width, depth, side):
            continue
        build_building(base_x, base_z, level, width, depth, wall_height, wall_type, roof_type, side, rng, true)
        record_town_home(town_key, town, base_x, base_z, width, depth, side, built_home_count)
        built_home_count += 1
    build_town_market(center_x, center_z, level, rng)
    place_utility(center_x - 2, center_z + 1, level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "town"),
        "generatedTier": "town",
        "cacheKey": "%s:town-cache:%d,%d" % [main.seed_text, center_x, center_z]
    })
    place_utility(center_x + 2, center_z + 1, level, "furnace")
    place_utility(center_x, center_z - 3, level, "workbench")

func build_town_paths(center_x: int, center_z: int, radius: int, level: float) -> void:
    var path_span: int = max(10, radius - 2)
    for offset in range(-path_span, path_span + 1):
        place_path(center_x + offset, center_z, level)
        place_path(center_x, center_z + offset, level)
        if offset % 4 == 0:
            place_path(center_x + offset, center_z + 1, level)
            place_path(center_x + 1, center_z + offset, level)

func town_home_count(town: Dictionary) -> int:
    var radius := int(town.get("radius", main.TOWN_RADIUS_CELLS))
    var extra_from_radius: int = clampi(floori(float(radius - main.TOWN_RADIUS_CELLS) * 0.75), 0, 7)
    var bonus := int(main.hash01("town-home-count:%d,%d" % [int(town.get("regionX", 0)), int(town.get("regionZ", 0))]) * 3.0)
    return clampi(4 + extra_from_radius + bonus, 4, 12)

func town_home_sites(town: Dictionary, _rng: RandomNumberGenerator) -> Array:
    var radius := int(town.get("radius", main.TOWN_RADIUS_CELLS))
    var candidates := [
        { "dx": -16, "dz": -13, "side": 2 },
        { "dx": 8, "dz": -14, "side": 2 },
        { "dx": -17, "dz": 8, "side": 0 },
        { "dx": 9, "dz": 9, "side": 0 },
        { "dx": -5, "dz": -25, "side": 2 },
        { "dx": 22, "dz": -4, "side": 1 },
        { "dx": -29, "dz": -4, "side": 3 },
        { "dx": -5, "dz": 20, "side": 0 },
        { "dx": 18, "dz": 18, "side": 0 },
        { "dx": -24, "dz": 18, "side": 0 },
        { "dx": 18, "dz": -24, "side": 2 },
        { "dx": -24, "dz": -24, "side": 2 }
    ]
    var sites := []
    for candidate_value in candidates:
        var candidate: Dictionary = candidate_value
        var dx := int(candidate.get("dx", 0))
        var dz := int(candidate.get("dz", 0))
        if maxi(absi(dx), absi(dz)) > radius - 4:
            continue
        sites.append(candidate)
    return sites

func town_home_site_excluded(town: Dictionary, base_x: int, base_z: int, width: int, depth: int, door_side: int) -> bool:
    var rings_value = town.get("homeExclusionRings", [])
    if not (rings_value is Array):
        return false
    var min_x := base_x - 1
    var max_x := base_x + width
    var min_z := base_z - 1
    var max_z := base_z + depth
    var door_entries := StructureDoorRulesScript.door_cells(width, depth, door_side)
    for entry_value in door_entries:
        var entry: Dictionary = entry_value
        var door_x := base_x + int(entry.get("x", 0))
        var door_z := base_z + int(entry.get("z", 0))
        if door_side == 0:
            max_z = maxi(max_z, door_z + 1)
        elif door_side == 2:
            min_z = mini(min_z, door_z - 1)
        elif door_side == 1:
            max_x = maxi(max_x, door_x + 1)
        elif door_side == 3:
            min_x = mini(min_x, door_x - 1)
    var center_x := int(town.get("centerX", 0))
    var center_z := int(town.get("centerZ", 0))
    for ring_value in rings_value:
        if not (ring_value is Dictionary):
            continue
        var ring: Dictionary = ring_value
        var radius := int(ring.get("radius", 0))
        if radius <= 0:
            continue
        var margin := maxi(0, int(ring.get("margin", 0)))
        if rect_intersects_town_ring(min_x, max_x, min_z, max_z, center_x, center_z, radius, margin):
            return true
    return false

func rect_intersects_town_ring(min_x: int, max_x: int, min_z: int, max_z: int, center_x: int, center_z: int, radius: int, margin: int) -> bool:
    var west := center_x - radius
    var east := center_x + radius
    var north := center_z - radius
    var south := center_z + radius
    var min_ring_x := west - margin
    var max_ring_x := east + margin
    var min_ring_z := north - margin
    var max_ring_z := south + margin
    if ranges_intersect(min_z, max_z, north - margin, north + margin) and ranges_intersect(min_x, max_x, min_ring_x, max_ring_x):
        return true
    if ranges_intersect(min_z, max_z, south - margin, south + margin) and ranges_intersect(min_x, max_x, min_ring_x, max_ring_x):
        return true
    if ranges_intersect(min_x, max_x, west - margin, west + margin) and ranges_intersect(min_z, max_z, min_ring_z, max_ring_z):
        return true
    if ranges_intersect(min_x, max_x, east - margin, east + margin) and ranges_intersect(min_z, max_z, min_ring_z, max_ring_z):
        return true
    return false

func ranges_intersect(a_min: int, a_max: int, b_min: int, b_max: int) -> bool:
    return a_min <= b_max and b_min <= a_max

func build_town_perimeter(center_x: int, center_z: int, radius: int, level: float, town_key: String) -> void:
    var gate_cells := {}
    for offset in [0, 1]:
        gate_cells[Vector2i(center_x + offset, center_z - radius)] = { "side": 2, "secondary": offset == 1, "axis": "x" }
        gate_cells[Vector2i(center_x + offset, center_z + radius)] = { "side": 0, "secondary": offset == 1, "axis": "x" }
        gate_cells[Vector2i(center_x - radius, center_z + offset)] = { "side": 3, "secondary": offset == 1, "axis": "z" }
        gate_cells[Vector2i(center_x + radius, center_z + offset)] = { "side": 1, "secondary": offset == 1, "axis": "z" }
    for offset in range(-radius, radius + 1):
        place_town_perimeter_cell(center_x + offset, center_z - radius, level, gate_cells, "x", town_key)
        place_town_perimeter_cell(center_x + offset, center_z + radius, level, gate_cells, "x", town_key)
        place_town_perimeter_cell(center_x - radius, center_z + offset, level, gate_cells, "z", town_key)
        place_town_perimeter_cell(center_x + radius, center_z + offset, level, gate_cells, "z", town_key)

func place_town_perimeter_cell(cell_x: int, cell_z: int, level: float, gate_cells: Dictionary, axis: String, town_key: String) -> void:
    var cell := Vector2i(cell_x, cell_z)
    if gate_cells.has(cell):
        var gate: Dictionary = gate_cells[cell]
        place_path(cell_x, cell_z, level, { "generatedTier": "town", "cacheKey": "%s:town-gate-path:%s:%d,%d" % [main.seed_text, town_key, cell_x, cell_z] })
        place_door(cell_x, cell_z, level, int(gate.get("side", 0)), bool(gate.get("secondary", false)), "public_gate")
        return
    place_structure_block(cell_x, cell_z, level, 0, "woodBlock", {
        "generatedTier": "town",
        "accentRole": "fencePost",
        "fenceAxis": axis,
        "cacheKey": "%s:town-fence:%s:%d,%d" % [main.seed_text, town_key, cell_x, cell_z]
    })

func build_town_market(center_x: int, center_z: int, level: float, rng: RandomNumberGenerator) -> void:
    var stalls := [
        { "dx": -5, "dz": -5, "facing": PI * 0.5 },
        { "dx": 5, "dz": -5, "facing": -PI * 0.5 },
        { "dx": -5, "dz": 5, "facing": PI * 0.5 },
        { "dx": 5, "dz": 5, "facing": -PI * 0.5 }
    ]
    var count := 2 + rng.randi_range(0, 1)
    for i in range(count):
        var stall: Dictionary = stalls[i]
        place_utility(center_x + int(stall["dx"]), center_z + int(stall["dz"]), level, "traderStall", {
            "facing": float(stall["facing"]),
            "generatedTier": "town"
        })

func town_key_for(town: Dictionary) -> String:
    return "%d,%d" % [int(town.get("centerX", 0)), int(town.get("centerZ", 0))]

func record_town_home(town_key: String, town: Dictionary, base_x: int, base_z: int, width: int, depth: int, door_side: int, index: int) -> void:
    if town_key == "":
        return
    if not town_home_records.has(town_key):
        town_home_records[town_key] = []
    var center_cell := Vector2i(base_x + int(width / 2), base_z + int(depth / 2))
    var home_cell := center_cell
    var porch_cell := home_cell
    var guard_cell := home_cell
    var home_route_cells: Array[Vector2i] = []
    var interior_min_cell := Vector2i(base_x + 1, base_z + 1)
    var interior_max_cell := Vector2i(base_x + width - 2, base_z + depth - 2)
    var door_entries := StructureDoorRulesScript.door_cells(width, depth, door_side)
    if not door_entries.is_empty():
        var entry: Dictionary = door_entries[0]
        var door_cell := Vector2i(base_x + int(entry.get("x", 0)), base_z + int(entry.get("z", 0)))
        var interior_landing := door_cell
        var inward := Vector2i.ZERO
        porch_cell = door_cell
        if door_side == 0:
            porch_cell.y += 1
            guard_cell = Vector2i(porch_cell.x, porch_cell.y + 4)
            inward = Vector2i(0, -1)
        elif door_side == 2:
            porch_cell.y -= 1
            guard_cell = Vector2i(porch_cell.x, porch_cell.y - 4)
            inward = Vector2i(0, 1)
        elif door_side == 1:
            porch_cell.x += 1
            guard_cell = Vector2i(porch_cell.x + 4, porch_cell.y)
            inward = Vector2i(-1, 0)
        else:
            porch_cell.x -= 1
            guard_cell = Vector2i(porch_cell.x - 4, porch_cell.y)
            inward = Vector2i(1, 0)
        interior_landing = door_cell + inward
        home_cell = door_cell + inward * 3
        var lateral := Vector2i(-inward.y, inward.x)
        if lateral != Vector2i.ZERO:
            var center_delta := (center_cell.x - door_cell.x) * lateral.x + (center_cell.y - door_cell.y) * lateral.y
            var lateral_sign := 1 if center_delta >= 0 else -1
            home_cell += lateral * lateral_sign * 2
        interior_landing.x = clampi(interior_landing.x, interior_min_cell.x, interior_max_cell.x)
        interior_landing.y = clampi(interior_landing.y, interior_min_cell.y, interior_max_cell.y)
        home_cell.x = clampi(home_cell.x, interior_min_cell.x, interior_max_cell.x)
        home_cell.y = clampi(home_cell.y, interior_min_cell.y, interior_max_cell.y)
        var exterior_approach := porch_cell - inward
        if exterior_approach != porch_cell:
            home_route_cells.append(exterior_approach)
        home_route_cells.append(porch_cell)
        if interior_landing != porch_cell:
            home_route_cells.append(interior_landing)
        if home_cell != interior_landing:
            home_route_cells.append(home_cell)
    var record := {
        "id": "%s:home:%d" % [town_key, index],
        "townKey": town_key,
        "townCenter": Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0))),
        "townRadius": int(town.get("radius", main.TOWN_RADIUS_CELLS)),
        "level": float(town.get("level", 16.0)),
        "homeCell": home_cell,
        "porchCell": porch_cell,
        "guardCell": guard_cell,
        "interiorMinCell": interior_min_cell,
        "interiorMaxCell": interior_max_cell,
        "homeRouteCells": home_route_cells,
        "buildingIndex": index
    }
    town_home_records[town_key].append(record)

func town_home_records_snapshot() -> Dictionary:
    return town_home_records.duplicate(true)

func build_building(base_x: int, base_z: int, level: float, width: int, depth: int, wall_height: int, wall_type: String, roof_type: String, door_side: int, rng: RandomNumberGenerator, town_building: bool) -> void:
    generated_building_count += 1
    var doors := StructureDoorRulesScript.door_cells(width, depth, door_side)
    for dy in range(wall_height):
        for x in range(width):
            for z in range(depth):
                var perimeter := x == 0 or z == 0 or x == width - 1 or z == depth - 1
                if not perimeter:
                    continue
                var door_entry: Dictionary = StructureDoorRulesScript.door_entry_at(doors, x, z)
                if not door_entry.is_empty():
                    if dy == 0:
                        place_door(base_x + x, base_z + z, level, door_side, bool(door_entry.get("secondary", false)))
                    if dy <= 1:
                        continue
                var block_type := wall_type
                var window_line := dy == 2 and door_entry.is_empty() and wall_height >= 4
                var window_axis_match := z % 3 == 1 if (x == 0 or x == width - 1) else x % 3 == 1
                if window_line and window_axis_match:
                    block_type = "glass"
                place_structure_block(base_x + x, base_z + z, level, dy, block_type, wall_visual_options(x, z, width, depth, dy, block_type, wall_type))
    for x in range(-1, width + 1):
        for z in range(-1, depth + 1):
            place_structure_block(base_x + x, base_z + z, level, wall_height, roof_type, roof_visual_options(x, z, width, depth, roof_type))
    place_porch(base_x, base_z, level, width, depth, door_side)
    if town_building and rng.randf() > 0.35:
        place_loot_chest(base_x, base_z, level, width, depth, door_side, rng, "town")
    elif not town_building and rng.randf() > 0.25:
        place_loot_chest(base_x, base_z, level, width, depth, door_side, rng, "cabin")
    if town_building and rng.randf() > 0.55:
        place_utility(base_x + 1, base_z + depth - 2, level, "bed")

func wall_visual_options(x: int, z: int, width: int, depth: int, dy: int, block_type: String, wall_type: String) -> Dictionary:
    var trim_key := "trimStone" if wall_type == "stoneBlock" else "trimWood"
    if block_type == "glass":
        var axis := "x" if (x == 0 or x == width - 1) else "z"
        var side := -1 if (x == 0 or z == 0) else 1
        if axis == "z":
            side = -1 if z == 0 else 1
        return {
            "accentRole": "windowFrame",
            "windowAxis": axis,
            "windowSide": side,
            "windowTrimMaterial": trim_key
        }
    var corner := (x == 0 or x == width - 1) and (z == 0 or z == depth - 1)
    if corner and dy <= 2:
        return {
            "accentRole": "cornerTimber",
            "cornerX": -1 if x == 0 else 1,
            "cornerZ": -1 if z == 0 else 1,
            "cornerTrimMaterial": trim_key
        }
    return {}

func roof_visual_options(x: int, z: int, width: int, depth: int, roof_type: String) -> Dictionary:
    var axis := "x" if width >= depth else "z"
    var cross_value := z if axis == "x" else x
    var cross_min := -1
    var cross_max := depth if axis == "x" else width
    var center := float(cross_min + cross_max) * 0.5
    var distance_to_center := absf(float(cross_value) - center)
    var role := "ridge" if distance_to_center <= 0.52 else "slope"
    var side := -1 if float(cross_value) < center else 1
    var edge_x := 0
    var edge_z := 0
    if x == -1:
        edge_x = -1
    elif x == width:
        edge_x = 1
    if z == -1:
        edge_z = -1
    elif z == depth:
        edge_z = 1
    if edge_x != 0 or edge_z != 0:
        role = "eave" if role != "ridge" else role
    var options := {
        "roofRole": role,
        "roofAxis": axis,
        "roofSide": side,
        "roofMaterial": "roofStone" if roof_type == "stoneBlock" else "roofWood",
        "roofTrimMaterial": "trimStone" if roof_type == "stoneBlock" else "trimWood",
        "roofEdgeX": edge_x,
        "roofEdgeZ": edge_z
    }
    var chimney_x: int = clampi(width - 2, 1, width - 2)
    var chimney_z: int = clampi(2, 1, depth - 2)
    if x == chimney_x and z == chimney_z:
        options["roofAccent"] = "chimney"
    return options

func camp_fence_options(base_options: Dictionary, axis: String) -> Dictionary:
    var options := base_options.duplicate()
    options["accentRole"] = "fencePost"
    options["fenceAxis"] = axis
    options["fenceTrimMaterial"] = "trimWood"
    return options

func build_ruin(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_ruin_count += 1
    var cache_key := "%s:ruin:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "ruin", "cacheKey": cache_key }
    var wall_height := rng.randi_range(2, 5)
    for x in range(width):
        for z in range(depth):
            var edge := x == 0 or z == 0 or x == width - 1 or z == depth - 1
            if not edge:
                continue
            var corner := (x == 0 or x == width - 1) and (z == 0 or z == depth - 1)
            if rng.randf() < (0.14 if corner else 0.42):
                continue
            var height := clampi(1 + rng.randi_range(0, wall_height), 1, wall_height)
            for dy in range(height):
                place_structure_block(base_x + x, base_z + z, level, dy, "stoneBlock", tier_options)
    place_loot_chest(base_x, base_z, level, width, depth, -1, rng, "ruin", cache_key)
    for i in range(rng.randi_range(3, 6)):
        var rubble_x := base_x + rng.randi_range(1, width - 2)
        var rubble_z := base_z + rng.randi_range(1, depth - 2)
        place_structure_block(rubble_x, rubble_z, level, 0, "stoneBlock", tier_options)

func build_camp(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_camp_count += 1
    var cache_key := "%s:camp:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "camp", "cacheKey": cache_key }
    var center_x := int(width / 2)
    var center_z := int(depth / 2)
    for x in range(width):
        for z in range(depth):
            var offset := Vector2(float(x - center_x), float(z - center_z))
            if offset.length() <= 4.2 or x == center_x or z == center_z or rng.randf() > 0.72:
                place_path(base_x + x, base_z + z, level, tier_options)
    for z in range(-5, 0):
        for lane in range(-1, 2):
            place_path(base_x + center_x + lane, base_z + z, level, tier_options)
    place_utility(base_x + center_x, base_z + center_z, level, "campfire", tier_options)
    place_utility(base_x + max(1, center_x - 3), base_z + max(1, center_z - 2), level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "camp"),
        "generatedTier": "camp",
        "cacheKey": cache_key
    })
    var torch_cells := [
        Vector2i(1, 1),
        Vector2i(width - 2, 1),
        Vector2i(1, depth - 2),
        Vector2i(width - 2, depth - 2)
    ]
    for cell in torch_cells:
        place_utility(base_x + cell.x, base_z + cell.y, level, "torch", tier_options)
    for x in range(1, width - 1):
        if x % 3 == 0:
            place_structure_block(base_x + x, base_z, level, 0, "woodBlock", camp_fence_options(tier_options, "x"))
            place_structure_block(base_x + x, base_z + depth - 1, level, 0, "woodBlock", camp_fence_options(tier_options, "x"))
    for z in range(1, depth - 1):
        if z % 3 == 1:
            place_structure_block(base_x, base_z + z, level, 0, "woodBlock", camp_fence_options(tier_options, "z"))
            place_structure_block(base_x + width - 1, base_z + z, level, 0, "woodBlock", camp_fence_options(tier_options, "z"))
    var trap_cells := [
        Vector2i(center_x - 1, -2),
        Vector2i(center_x + 1, -2),
        Vector2i(1, center_z),
        Vector2i(width - 2, center_z)
    ]
    for cell in trap_cells:
        place_utility(base_x + cell.x, base_z + cell.y, level, "spikeTrap", tier_options)

func build_mine(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_mine_count += 1
    var cache_key := "%s:mine:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "mine", "cacheKey": cache_key }
    var center_x := int(width / 2)
    for z in range(depth):
        for x in range(1, width - 1):
            if x == 1 or x == width - 2 or z % 2 == 0:
                place_path(base_x + x, base_z + z, level, tier_options)
    for z in range(-5, 0):
        for lane in range(-1, 2):
            place_path(base_x + center_x + lane, base_z + z, level, tier_options)
    for torch_offset in [Vector2i(center_x - 2, -1), Vector2i(center_x + 2, -1), Vector2i(1, 2), Vector2i(width - 2, 2)]:
        place_structure_block(base_x + torch_offset.x, base_z + torch_offset.y, level, 0, "torch", tier_options)
    for z in range(2, depth):
        for x in [0, width - 1]:
            place_structure_block(base_x + x, base_z + z, level, 0, "stoneBlock", tier_options)
            if z > 4 and z < depth - 1 and rng.randf() > 0.42:
                place_structure_block(base_x + x, base_z + z, level, 1, mine_vein_type(rng), tier_options)
            elif z % 3 == 0:
                place_structure_block(base_x + x, base_z + z, level, 1, "stoneBlock", tier_options)
    for x in range(width):
        place_structure_block(base_x + x, base_z + depth - 1, level, 0, "stoneBlock", tier_options)
        if x > 1 and x < width - 2:
            place_structure_block(base_x + x, base_z + depth - 1, level, 1, mine_vein_type(rng), tier_options)
            if rng.randf() > 0.62:
                place_structure_block(base_x + x, base_z + depth - 1, level, 2, mine_vein_type(rng), tier_options)
        else:
            place_structure_block(base_x + x, base_z + depth - 1, level, 1, "stoneBlock", tier_options)
    for z in [2, 6, depth - 3]:
        for x in [2, width - 3]:
            for dy in range(3):
                place_structure_block(base_x + x, base_z + z, level, dy, "woodBlock", tier_options)
            place_structure_block(base_x + x, base_z + z + 1, level, 0, "torch", tier_options)
        for x in range(2, width - 2):
            place_structure_block(base_x + x, base_z + z, level, 3, "woodBlock", tier_options)
    place_utility(base_x + center_x, base_z + 3, level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "mine"),
        "generatedTier": "mine",
        "cacheKey": cache_key
    })

func build_shrine(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_shrine_count += 1
    var cache_key := "%s:shrine:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "shrine", "cacheKey": cache_key }
    var center_x := int(width / 2)
    var center_z := int(depth / 2)
    for x in range(width):
        for z in range(depth):
            place_path(base_x + x, base_z + z, level, tier_options)
    for xz in [
        Vector2i(1, 1),
        Vector2i(width - 2, 1),
        Vector2i(1, depth - 2),
        Vector2i(width - 2, depth - 2)
    ]:
        for dy in range(5):
            place_structure_block(base_x + xz.x, base_z + xz.y, level, dy, "stoneBlock", tier_options)
    for x in range(1, width - 1):
        place_structure_block(base_x + x, base_z + 1, level, 5, "stoneBlock", tier_options)
        place_structure_block(base_x + x, base_z + depth - 2, level, 5, "stoneBlock", tier_options)
    for z in range(1, depth - 1):
        place_structure_block(base_x + 1, base_z + z, level, 5, "stoneBlock", tier_options)
        place_structure_block(base_x + width - 2, base_z + z, level, 5, "stoneBlock", tier_options)
    place_structure_block(base_x + center_x, base_z + center_z, level, 0, "stoneBlock", tier_options)
    place_structure_block(base_x + center_x, base_z + center_z, level, 2, "glass", tier_options)
    place_structure_block(base_x + center_x, base_z + center_z, level, 3, "glass", tier_options)
    for offset in [Vector2i(0, -3), Vector2i(3, 0), Vector2i(0, 3), Vector2i(-3, 0)]:
        place_structure_block(base_x + center_x + offset.x, base_z + center_z + offset.y, level, 1, "torch", tier_options)
    place_utility(base_x + center_x, base_z + center_z + 2, level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "shrine"),
        "generatedTier": "shrine",
        "cacheKey": cache_key
    })

func build_cave(plan: Dictionary, rng: RandomNumberGenerator = null) -> void:
    if plan.is_empty():
        return
    var cave_rng := rng
    if cave_rng == null:
        cave_rng = RandomNumberGenerator.new()
        cave_rng.seed = main.hash_string("%s:%s" % [main.seed_text, String(plan.get("id", "cave"))])
    generated_cave_count += 1
    var cave_id := String(plan.get("id", "cave:%d" % generated_cave_count))
    var level := float(plan.get("level", 0.0))
    var kind := String(plan.get("kind", "underground"))
    var cache_key := "%s:%s" % [main.seed_text, cave_id]
    var base_options := {
        "generatedTier": "cave",
        "cacheKey": cache_key,
        "caveId": cave_id,
        "caveKind": kind
    }
    apply_cave_terrain_edits(plan)
    if cave_interior_builder != null:
        var interior: Node3D = cave_interior_builder.build(plan, cave_rng, base_options)
        if interior != null:
            cave_interior_nodes[cave_id] = interior
    build_cave_supports(plan, level, base_options)
    var chest_cell: Vector2i = plan.get("finalChestCell", plan.get("finalChamberCell", Vector2i.ZERO))
    place_utility(chest_cell.x, chest_cell.y, level, "chest", cave_options(base_options, "final_chest", int(plan.get("pathLength", 0)), {
        "storageSlots": loot.make_cave_final_loot_slots(cave_rng),
        "caveFinalLoot": true
    }))
    cave_records[cave_id] = cave_record_from_plan(plan, cache_key)
    cave_navigation_records[cave_id] = cave_navigation_record_from_plan(plan, cache_key)
    for cell_value in cave_walkable_cells(plan, false):
        var cell: Vector2i = cell_value
        cave_navigation_cells[cell] = cave_id
    var region: Vector2i = plan.get("region", Vector2i.ZERO)
    generated_caves[region] = true

func apply_cave_terrain_edits(plan: Dictionary) -> void:
    if main == null:
        return
    var edits = main.get("height_edits")
    if not (edits is Dictionary):
        return
    var npc_system = main.get("npc_system")
    var level := float(plan.get("level", 0.0))
    var cells := cave_terrain_opening_cells(plan)
    var shaping_cells := cave_shaping_cells(plan)
    for cell_value in shaping_cells:
        var stone_cell: Vector2i = cell_value
        cave_terrain_cells[stone_cell] = true
        cave_prop_exclusion_cells[stone_cell] = true
    var edited := {}
    for cell_value in cells:
        var cell: Vector2i = cell_value
        if edited.has(cell):
            continue
        edited[cell] = true
        var old_height := float(main.terrain_height_cell(cell.x, cell.y))
        var target_height := cave_opening_height_for_cell(plan, cell)
        edits[cell] = target_height
        if npc_system != null and npc_system.has_method("notify_navigation_terrain_edited"):
            npc_system.notify_navigation_terrain_edited(cell, old_height, target_height)
    rebuild_loaded_chunks_for_cells(shaping_cells)

func terrain_material_override_for_cell(x: int, z: int) -> String:
    return "stone" if cave_terrain_cells.has(Vector2i(x, z)) else ""

func blocks_natural_prop_at_cell(x: int, z: int) -> bool:
    return cave_prop_exclusion_cells.has(Vector2i(x, z))

func cave_navigation_id_for_cell(x: int, z: int) -> String:
    return String(cave_navigation_cells.get(Vector2i(x, z), ""))

func rebuild_loaded_chunks_for_cells(cells: Array[Vector2i]) -> void:
    if main == null or not main.has_method("cell_to_chunk") or not main.has_method("rebuild_chunk"):
        return
    var chunks_value = main.get("chunks")
    if not (chunks_value is Dictionary):
        return
    var chunks: Dictionary = chunks_value
    if chunks.is_empty():
        return
    var touched_chunks := {}
    for cell in cells:
        var chunk_key: Vector2i = main.call("cell_to_chunk", cell.x, cell.y)
        touched_chunks[chunk_key] = true
    for key_value in touched_chunks.keys():
        var key: Vector2i = key_value
        if chunks.has(key):
            main.call("rebuild_chunk", key.x, key.y)

func cave_navigation_records_snapshot() -> Dictionary:
    return cave_navigation_records.duplicate(true)

func snapshot_caves() -> Array:
    var result := []
    var ids: Array = cave_records.keys()
    ids.sort()
    for id_value in ids:
        var cave_id := String(id_value)
        var record: Dictionary = cave_records.get(cave_id, {})
        if record.is_empty():
            continue
        result.append({
            "id": cave_id,
            "kind": String(record.get("kind", "")),
            "region": vector2i_to_save(record.get("region", Vector2i.ZERO)),
            "entranceCell": vector2i_to_save(record.get("entranceCell", Vector2i.ZERO)),
            "finalChestCell": vector2i_to_save(record.get("finalChestCell", Vector2i.ZERO)),
            "finalChestSlots": cave_final_chest_slots_snapshot(cave_id)
        })
    return result

func restore_caves(entries) -> void:
    clear_generated_cave_runtime_state(true)
    generated_caves.clear()
    generated_cave_count = 0
    if not (entries is Array):
        return
    for entry_value in entries:
        if not (entry_value is Dictionary):
            continue
        var entry: Dictionary = entry_value
        var region := save_to_vector2i(entry.get("region", {}), Vector2i(999999, 999999))
        if region == Vector2i(999999, 999999):
            continue
        var kind := String(entry.get("kind", ""))
        var plan := cave_plan_for_region(region.x, region.y, kind, false)
        if plan.is_empty():
            continue
        var expected_id := String(entry.get("id", ""))
        if expected_id != "" and String(plan.get("id", "")) != expected_id:
            continue
        var rng := RandomNumberGenerator.new()
        rng.seed = main.hash_string("%s:cave-build:%d,%d" % [main.seed_text, region.x, region.y])
        build_cave(plan, rng)
        apply_saved_cave_final_chest_slots(String(plan.get("id", "")), entry.get("finalChestSlots", []))

func cave_final_chest_slots_snapshot(cave_id: String) -> Array:
    if main == null:
        return []
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return []
    for block_value in (blocks_value as Dictionary).values():
        var block := block_value as Node
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("generatedTier", "")) != "cave":
            continue
        if String(block.get_meta("caveId", "")) != cave_id:
            continue
        if String(block.get_meta("caveRole", "")) != "final_chest":
            continue
        return cave_serialize_slots(block.get_meta("storage_slots", []))
    return []

func apply_saved_cave_final_chest_slots(cave_id: String, slots_value) -> void:
    if main == null or not (slots_value is Array):
        return
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return
    var slots := cave_restore_slots(slots_value)
    for block_value in (blocks_value as Dictionary).values():
        var block := block_value as Node
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("generatedTier", "")) == "cave" \
            and String(block.get_meta("caveId", "")) == cave_id \
            and String(block.get_meta("caveRole", "")) == "final_chest":
            block.set_meta("storage_slots", slots)
            return

func cave_serialize_slots(slots_value) -> Array:
    var result := []
    if not (slots_value is Array):
        return result
    for slot_value in slots_value:
        if not (slot_value is Dictionary):
            continue
        result.append({
            "item": String(slot_value.get("item", "")),
            "count": int(slot_value.get("count", 0))
        })
    return result

func cave_restore_slots(slots_value) -> Array:
    var result := []
    if not (slots_value is Array):
        return result
    for slot_value in slots_value:
        if not (slot_value is Dictionary):
            continue
        result.append({
            "item": String(slot_value.get("item", "")),
            "count": maxi(0, int(slot_value.get("count", 0)))
        })
    return result

func vector2i_to_save(value) -> Dictionary:
    if value is Vector2i:
        return { "x": value.x, "z": value.y }
    return { "x": 0, "z": 0 }

func save_to_vector2i(value, fallback := Vector2i.ZERO) -> Vector2i:
    if value is Vector2i:
        return value
    if value is Dictionary:
        return Vector2i(int(value.get("x", fallback.x)), int(value.get("z", fallback.y)))
    if value is Array and value.size() >= 2:
        return Vector2i(int(value[0]), int(value[1]))
    return fallback

func cave_walkable_cells(plan: Dictionary, include_approach := false) -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    if include_approach:
        for cell in plan.get("approachCells", []):
            cells.append(cell)
    for cell in plan.get("pathCells", []):
        cells.append(cell)
    for cell in plan.get("chamberCells", []):
        cells.append(cell)
    return cells

func cave_floor_lookup(plan: Dictionary) -> Dictionary:
    var lookup := {}
    for cell in cave_walkable_cells(plan, false):
        lookup[cell] = true
    return lookup

func cave_shaping_cells(plan: Dictionary) -> Array[Vector2i]:
    var lookup := {}
    for cell_value in cave_walkable_cells(plan, true):
        var cell: Vector2i = cell_value
        for dz in range(-2, 3):
            for dx in range(-2, 3):
                if Vector2(float(dx), float(dz)).length() > 2.25:
                    continue
                lookup[cell + Vector2i(dx, dz)] = true
    var cells: Array[Vector2i] = []
    for key in lookup.keys():
        cells.append(key)
    return cells

func cave_terrain_opening_cells(plan: Dictionary) -> Array[Vector2i]:
    var lookup := {}
    for cell_value in cave_walkable_cells(plan, true):
        var cell: Vector2i = cell_value
        for dz in range(-1, 2):
            for dx in range(-1, 2):
                if Vector2(float(dx), float(dz)).length() > 1.45:
                    continue
                lookup[cell + Vector2i(dx, dz)] = true
    var cells: Array[Vector2i] = []
    for key in lookup.keys():
        cells.append(key)
    return cells

func cave_opening_height_for_cell(plan: Dictionary, cell: Vector2i) -> float:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var surface_level := float(plan.get("surfaceLevel", plan.get("level", 0.0)))
    var floor_level := float(plan.get("level", surface_level))
    var delta := cell - entrance
    var depth := delta.x * inward.x + delta.y * inward.y
    if depth < 0:
        var ramp_t := clampf(float(depth + 5) / 5.0, 0.0, 1.0)
        return lerpf(surface_level, floor_level, ramp_t)
    return floor_level

func build_cave_boundary_walls(floor_lookup: Dictionary, level: float, base_options: Dictionary, rng: RandomNumberGenerator) -> void:
    var wall_cells := {}
    var directions := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
    for cell_value in floor_lookup.keys():
        var cell: Vector2i = cell_value
        for direction in directions:
            var neighbor: Vector2i = cell + direction
            if floor_lookup.has(neighbor) or wall_cells.has(neighbor):
                continue
            wall_cells[neighbor] = true
            place_structure_block(neighbor.x, neighbor.y, level, 0, "stoneBlock", cave_options(base_options, "wall", 0))
            if rng.randf() < 0.64:
                place_structure_block(neighbor.x, neighbor.y, level, 1, "stoneBlock", cave_options(base_options, "wall", 1))
            elif rng.randf() < 0.5:
                place_structure_block(neighbor.x, neighbor.y, level, 1, mine_vein_type(rng), cave_options(base_options, "ore_vein", 1))

func build_cave_entrance_arch(plan: Dictionary, level: float, base_options: Dictionary) -> void:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    for side_offset in [-2, 2]:
        var pillar_cell: Vector2i = entrance + right * side_offset
        for dy in range(3):
            place_structure_block(pillar_cell.x, pillar_cell.y, level, dy, "stoneBlock", cave_options(base_options, "entrance_arch", dy))
    for top_offset in range(-1, 2):
        var cap_cell: Vector2i = entrance + right * top_offset
        place_structure_block(cap_cell.x, cap_cell.y, level, 3, "stoneBlock", cave_options(base_options, "entrance_arch", 3))
    for torch_cell in [entrance + right * -2, entrance + right * 2]:
        place_cave_wall_torch(plan, torch_cell, level, base_options, "entrance_torch", 1)

func build_cave_supports(plan: Dictionary, level: float, base_options: Dictionary) -> void:
    if cave_has_graph(plan):
        build_graph_cave_supports(plan, level, base_options)
        return
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    var path_length := int(plan.get("pathLength", 12))
    var torch_depths := [3, maxi(5, int(path_length / 2)), maxi(6, path_length - 3)]
    var used_depths := {}
    for depth in torch_depths:
        if depth >= path_length:
            continue
        if used_depths.has(depth):
            continue
        used_depths[depth] = true
        var torch_side := -1 if depth % 2 == 0 else 1
        var torch: Vector2i = entrance + inward * depth + right * torch_side
        place_cave_wall_torch(plan, torch, level, base_options, "tunnel_torch", depth)
    var chamber_center: Vector2i = plan.get("finalChamberCell", entrance + inward * path_length)
    for offset in [Vector2i(2, 0), Vector2i(-2, 0)]:
        var torch_cell: Vector2i = chamber_center + right * offset.x + inward * offset.y
        place_cave_wall_torch(plan, torch_cell, level, base_options, "chamber_torch", path_length)

func cave_has_graph(plan: Dictionary) -> bool:
    var nodes = plan.get("caveNodes", [])
    var edges = plan.get("caveEdges", [])
    return nodes is Array and edges is Array and not (nodes as Array).is_empty() and not (edges as Array).is_empty()

func build_graph_cave_supports(plan: Dictionary, level: float, base_options: Dictionary) -> void:
    var used_cells := {}
    var edges: Array = plan.get("caveEdges", [])
    var branch_ids: Array = plan.get("branchChamberIds", [])
    var torch_candidates: Array[Dictionary] = []
    for edge_value in edges:
        if not (edge_value is Dictionary):
            continue
        var edge: Dictionary = edge_value
        var center_cells = edge.get("centerCells", [])
        if not (center_cells is Array) or (center_cells as Array).size() < 5:
            continue
        var samples: Array = center_cells
        var sample_index := clampi(roundi(float(samples.size() - 1) * 0.52), 2, samples.size() - 3)
        var torch_cell: Vector2i = samples[sample_index]
        torch_candidates.append({
            "cell": torch_cell,
            "role": "tunnel_torch",
            "depth": sample_index,
            "score": int(samples.size()) + int(main.hash01("cave-torch-edge:%s:%s" % [String(plan.get("id", "")), String(edge.get("id", ""))]) * 100.0)
        })
    var nodes: Array = plan.get("caveNodes", [])
    var final_id := String(plan.get("finalChamberId", "final"))
    for node_value in nodes:
        if not (node_value is Dictionary):
            continue
        var node: Dictionary = node_value
        var node_id := String(node.get("id", ""))
        if node_id == "entrance":
            continue
        if String(node.get("kind", "")) == "dead_end" or node_id == final_id or branch_ids.has(node_id):
            var cell: Vector2i = node.get("cell", Vector2i.ZERO)
            torch_candidates.append({
                "cell": cell,
                "role": "chamber_torch",
                "depth": int(node.get("radius", 3)),
                "score": 160 if node_id == final_id else 80 + int(main.hash01("cave-torch-node:%s:%s" % [String(plan.get("id", "")), node_id]) * 90.0)
            })
    torch_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return int(a.get("score", 0)) > int(b.get("score", 0))
    )
    var torch_budget := clampi(2 + int(edges.size() / 5), 3, 5)
    var placed := 0
    for candidate in torch_candidates:
        if placed >= torch_budget:
            break
        var cell: Vector2i = candidate.get("cell", Vector2i.ZERO)
        if used_cells.has(cell):
            continue
        used_cells[cell] = true
        placed += 1
        place_cave_wall_torch(plan, cell, level, base_options, String(candidate.get("role", "cave_torch")), int(candidate.get("depth", 0)))

func place_cave_wall_torch(plan: Dictionary, preferred_cell: Vector2i, level: float, base_options: Dictionary, role: String, depth_index := -1) -> void:
    var anchor := cave_wall_torch_anchor(plan, preferred_cell)
    var cell: Vector2i = anchor.get("cell", preferred_cell)
    var normal: Vector2i = anchor.get("normal", Vector2i.ZERO)
    var options := cave_options(base_options, role, depth_index, {
        "torchWallMount": true,
        "torchWallNormalX": normal.x,
        "torchWallNormalZ": normal.y,
        "facing": torch_wall_facing(normal)
    })
    place_structure_block(cell.x, cell.y, level, 0, "torch", options)

func cave_wall_torch_anchor(plan: Dictionary, preferred_cell: Vector2i) -> Dictionary:
    var floor_lookup := cave_floor_lookup(plan)
    var directions := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
    var best := {
        "cell": preferred_cell,
        "normal": Vector2i.ZERO,
        "score": 999999
    }
    for radius in range(0, 9):
        for dx in range(-radius, radius + 1):
            for dz in range(-radius, radius + 1):
                if maxi(abs(dx), abs(dz)) != radius:
                    continue
                var walk_cell: Vector2i = preferred_cell + Vector2i(dx, dz)
                if not floor_lookup.has(walk_cell):
                    continue
                for dir in directions:
                    var wall_cell: Vector2i = walk_cell + dir
                    if floor_lookup.has(wall_cell):
                        continue
                    var distance_score: int = abs(walk_cell.x - preferred_cell.x) + abs(walk_cell.y - preferred_cell.y)
                    var score: int = radius * 10 + distance_score
                    if score < int(best.get("score", 999999)):
                        best["cell"] = walk_cell
                        best["normal"] = -dir
                        best["score"] = score
    return best

func torch_wall_facing(normal: Vector2i) -> float:
    if normal == Vector2i.ZERO:
        return 0.0
    return atan2(-float(normal.x), -float(normal.y))

func cave_options(base_options: Dictionary, role: String, depth_index := -1, extra_options: Dictionary = {}) -> Dictionary:
    var options := base_options.duplicate()
    options["caveRole"] = role
    if role.contains("torch"):
        options["torchVisualScale"] = 0.35
    if depth_index >= 0:
        options["caveDepthIndex"] = depth_index
    for key in extra_options.keys():
        options[key] = extra_options[key]
    return options

func cave_record_from_plan(plan: Dictionary, cache_key: String) -> Dictionary:
    return {
        "id": String(plan.get("id", "")),
        "cacheKey": cache_key,
        "kind": String(plan.get("kind", "")),
        "region": plan.get("region", Vector2i.ZERO),
        "entranceCell": plan.get("entranceCell", Vector2i.ZERO),
        "finalChamberCell": plan.get("finalChamberCell", Vector2i.ZERO),
        "finalChestCell": plan.get("finalChestCell", Vector2i.ZERO),
        "level": float(plan.get("level", 0.0)),
        "surfaceLevel": float(plan.get("surfaceLevel", plan.get("level", 0.0))),
        "ceilingLevel": float(plan.get("ceilingLevel", plan.get("level", 0.0))),
        "entranceVariation": float(plan.get("entranceVariation", 0.0)),
        "pathLength": int(plan.get("pathLength", 0)),
        "chamberRadius": int(plan.get("chamberRadius", 0)),
        "chamberCount": cave_array_size(plan, "caveNodes"),
        "edgeCount": cave_array_size(plan, "caveEdges"),
        "branchChamberCount": cave_array_size(plan, "branchChamberIds"),
        "deadEndChamberCount": cave_array_size(plan, "deadEndChamberIds"),
        "walkableCellCount": cave_walkable_cells(plan, false).size(),
        "approachCellCount": cave_array_size(plan, "approachCells")
    }

func cave_records_snapshot() -> Dictionary:
    return cave_records.duplicate(true)

func cave_navigation_record_from_plan(plan: Dictionary, cache_key: String) -> Dictionary:
    return {
        "id": String(plan.get("id", "")),
        "cacheKey": cache_key,
        "kind": String(plan.get("kind", "")),
        "region": plan.get("region", Vector2i.ZERO),
        "entranceCell": plan.get("entranceCell", Vector2i.ZERO),
        "finalChamberCell": plan.get("finalChamberCell", Vector2i.ZERO),
        "finalChestCell": plan.get("finalChestCell", Vector2i.ZERO),
        "level": float(plan.get("level", 0.0)),
        "surfaceLevel": float(plan.get("surfaceLevel", plan.get("level", 0.0))),
        "ceilingLevel": float(plan.get("ceilingLevel", plan.get("level", 0.0))),
        "walkableCells": cave_walkable_cells(plan, false),
        "approachCells": plan.get("approachCells", []),
        "pathCells": plan.get("pathCells", []),
        "chamberCells": plan.get("chamberCells", []),
        "graphNodes": plan.get("caveNodes", []),
        "graphEdges": plan.get("caveEdges", []),
        "branchChamberIds": plan.get("branchChamberIds", []),
        "deadEndChamberIds": plan.get("deadEndChamberIds", []),
        "finalChamberId": String(plan.get("finalChamberId", "final"))
    }

func cave_plan_is_contiguous(plan: Dictionary) -> bool:
    var cells := cave_walkable_cells(plan, false)
    if cells.is_empty():
        return false
    var lookup := {}
    for cell in cells:
        lookup[cell] = true
    var start: Vector2i = plan.get("entranceCell", cells[0])
    var goal: Vector2i = plan.get("finalChestCell", plan.get("finalChamberCell", cells.back()))
    if not lookup.has(start):
        start = cells[0]
    var open := [start]
    var visited := { start: true }
    var directions := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
    while not open.is_empty():
        var current: Vector2i = open.pop_front()
        if current == goal or Vector2(float(current.x - goal.x), float(current.y - goal.y)).length() <= 1.5:
            return true
        for direction in directions:
            var next: Vector2i = current + direction
            if not lookup.has(next) or visited.has(next):
                continue
            visited[next] = true
            open.append(next)
    return false

func cave_array_size(plan: Dictionary, key: String) -> int:
    var value = plan.get(key, [])
    return value.size() if value is Array else 0

func mine_vein_type(rng: RandomNumberGenerator) -> String:
    return "ironVein" if rng.randf() > 0.76 else "copperVein"

func place_loot_chest(base_x: int, base_z: int, level: float, width: int, depth: int, door_side: int, rng: RandomNumberGenerator, tier: String, cache_key: String = "") -> bool:
    if width < 4 or depth < 4:
        return false
    var cell := loot_chest_cell(width, depth, door_side, rng)
    var key := cache_key
    if key == "":
        key = "%s:%s-cache:%d,%d" % [main.seed_text, tier, base_x + int(cell.get("x", 0)), base_z + int(cell.get("z", 0))]
    return place_utility(base_x + int(cell.get("x", 0)), base_z + int(cell.get("z", 0)), level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, tier),
        "generatedTier": tier,
        "cacheKey": key
    }) != null

func loot_chest_cell(width: int, depth: int, door_side: int, rng: RandomNumberGenerator) -> Dictionary:
    var side_x := 1 if rng.randf() < 0.5 else width - 2
    var side_z := 1 if rng.randf() < 0.5 else depth - 2
    if door_side == 0:
        return { "x": side_x, "z": depth - 2 }
    if door_side == 1:
        return { "x": 1, "z": side_z }
    if door_side == 2:
        return { "x": side_x, "z": 1 }
    if door_side == 3:
        return { "x": width - 2, "z": side_z }
    return { "x": side_x, "z": side_z }

func flat_level_for_footprint(base_x: int, base_z: int, width: int, depth: int) -> float:
    var samples := []
    for x in range(base_x, base_x + width):
        samples.append(main.terrain_height_cell(x, base_z))
        samples.append(main.terrain_height_cell(x, base_z + depth - 1))
    for z in range(base_z, base_z + depth):
        samples.append(main.terrain_height_cell(base_x, z))
        samples.append(main.terrain_height_cell(base_x + width - 1, z))
    var min_h := 999999.0
    var max_h := -999999.0
    for h in samples:
        min_h = min(min_h, float(h))
        max_h = max(max_h, float(h))
    if max_h - min_h > main.CELL * 0.65 or max_h <= main.WATER_LEVEL + 1.2:
        return NAN
    return (min_h + max_h) * 0.5

func place_structure_block(cell_x: int, cell_z: int, level: float, dy: int, block_type: String, extra_options: Dictionary = {}) -> void:
    var world_y: float = level + main.CELL * 0.48 + float(dy) * main.CELL
    var cell_y: int = floori(world_y / main.CELL) + 1
    var options := {
        "generated": true,
        "world_y": world_y,
        "structureDy": dy,
        "structureLevel": level
    }
    for key in extra_options.keys():
        options[key] = extra_options[key]
    main.create_block(Vector3i(cell_x, cell_y, cell_z), block_type, options)

func place_path(cell_x: int, cell_z: int, level: float, extra_options: Dictionary = {}) -> void:
    var cell_y: int = roundi(level / main.CELL)
    var options := {
        "generated": true,
        "world_y": level + main.CELL * 0.024
    }
    for key in extra_options.keys():
        options[key] = extra_options[key]
    var block = main.create_block(Vector3i(cell_x, cell_y, cell_z), "cobblestonePath", options)
    if block:
        generated_path_count += 1

func place_utility(cell_x: int, cell_z: int, level: float, block_type: String, extra_options: Dictionary = {}) -> StaticBody3D:
    var world_y: float = level + main.CELL * 0.48
    var cell_y: int = floori(world_y / main.CELL) + 1
    var options := {
        "generated": true,
        "world_y": world_y
    }
    for key in extra_options.keys():
        options[key] = extra_options[key]
    var block = main.create_block(Vector3i(cell_x, cell_y, cell_z), block_type, options)
    if block:
        generated_utility_count += 1
    return block

func place_door(cell_x: int, cell_z: int, level: float, side: int, secondary: bool, door_policy := "private_home") -> void:
    var world_y: float = level + main.CELL * 0.48
    var cell_y: int = floori(world_y / main.CELL) + 1
    var facing: float = StructureDoorRulesScript.door_facing(side)
    var group_x := cell_x
    var group_z := cell_z
    if secondary:
        if side == 0 or side == 2:
            group_x -= 1
        elif side == 1 or side == 3:
            group_z -= 1
    var group_id := "door-group:%d,%d,%d:%d" % [group_x, cell_y, group_z, side]
    var block = main.create_block(Vector3i(cell_x, cell_y, cell_z), "door", {
        "generated": true,
        "world_y": world_y,
        "facing": facing,
        "secondary": secondary,
        "doorSide": side,
        "doorLeafIndex": 1 if secondary else 0,
        "doorGroupId": group_id,
        "doorPortalId": "door:%s" % group_id,
        "doorPublicAccess": true,
        "doorPolicy": door_policy,
        "door": true,
        "accentRole": "doorFrame",
        "doorTrimMaterial": "trimWood"
    })
    if block:
        generated_door_count += 1

func place_porch(base_x: int, base_z: int, level: float, width: int, depth: int, side: int) -> void:
    var doors := StructureDoorRulesScript.door_cells(width, depth, side)
    for entry in doors:
        var x := base_x + int(entry["x"])
        var z := base_z + int(entry["z"])
        if side == 0:
            place_path(x, z + 1, level)
        elif side == 2:
            place_path(x, z - 1, level)
        elif side == 1:
            place_path(x + 1, z, level)
        else:
            place_path(x - 1, z, level)

func counts() -> Dictionary:
    return {
        "towns": generated_town_count,
        "buildings": generated_building_count,
        "mines": generated_mine_count,
        "ruins": generated_ruin_count,
        "shrines": generated_shrine_count,
        "camps": generated_camp_count,
        "caves": generated_cave_count,
        "paths": generated_path_count,
        "doors": generated_door_count,
        "utilities": generated_utility_count
    }
