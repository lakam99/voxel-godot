extends RefCounted
class_name CaveInteriorBuilder

const GRID_SUBDIVISIONS := 3.0
const WALL_VERTICAL_SEGMENTS := 5
const FORMATION_SEGMENTS := 6
const WALL_OVERLAP := 0.46

var main
var cave_material: StandardMaterial3D
var support_material: StandardMaterial3D
var profile_cache := {}

func setup(main_node) -> void:
    main = main_node

func build(plan: Dictionary, rng: RandomNumberGenerator, metadata: Dictionary = {}) -> Node3D:
    if main == null or plan.is_empty():
        return null
    if cached_profile_points(plan).is_empty():
        return null
    var cave_id := String(plan.get("id", "cave"))
    var root := Node3D.new()
    root.name = "CaveInterior_%s" % cave_id.replace(":", "_").replace(",", "_")
    root.set_meta("generated", true)
    root.set_meta("generatedTier", "cave")
    root.set_meta("caveId", cave_id)
    root.set_meta("caveRole", "interior_shell")
    for key in metadata.keys():
        root.set_meta(String(key), metadata[key])

    var visual_mesh := build_visual_mesh(plan, rng)
    var collision_mesh := build_collision_mesh(plan)
    var visual := MeshInstance3D.new()
    visual.name = "CaveInteriorVisual"
    visual.mesh = visual_mesh
    visual.material_override = material()
    visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    root.add_child(visual)

    var body := StaticBody3D.new()
    body.name = "CaveInteriorBody"
    body.collision_layer = 2
    body.collision_mask = 0
    body.set_meta("kind", "terrain")
    body.set_meta("generated", true)
    body.set_meta("generatedTier", "cave")
    body.set_meta("caveId", cave_id)
    body.set_meta("caveRole", "interior_collision")
    var collision := CollisionShape3D.new()
    collision.name = "CaveInteriorCollision"
    collision.shape = collision_mesh.create_trimesh_shape()
    body.add_child(collision)
    root.add_child(body)
    add_support_frames(root, plan)

    var parent = main.get("block_root")
    if parent is Node:
        parent.add_child(root)
    elif main is Node:
        main.add_child(root)
    return root

func material() -> StandardMaterial3D:
    if cave_material != null:
        return cave_material
    cave_material = StandardMaterial3D.new()
    cave_material.vertex_color_use_as_albedo = true
    cave_material.roughness = 0.96
    cave_material.cull_mode = BaseMaterial3D.CULL_DISABLED
    return cave_material

func cave_support_material() -> StandardMaterial3D:
    if support_material != null:
        return support_material
    support_material = StandardMaterial3D.new()
    support_material.albedo_color = Color(0.34, 0.21, 0.12)
    support_material.roughness = 0.88
    return support_material

func build_visual_mesh(plan: Dictionary, rng: RandomNumberGenerator) -> ArrayMesh:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    add_carved_volume(st, plan, true)
    add_procedural_formations(st, plan, rng)
    st.generate_normals()
    return st.commit()

func build_collision_mesh(plan: Dictionary) -> ArrayMesh:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    add_carved_volume(st, plan, false)
    st.generate_normals()
    return st.commit()

func add_carved_volume(st: SurfaceTool, plan: Dictionary, detailed := true) -> void:
    var cell_size := float(main.CELL)
    var step := cell_size / (GRID_SUBDIVISIONS if detailed else 1.5)
    var bounds := cave_world_bounds(plan)
    var min_x := floori(float(bounds.get("minX", 0.0)) / step) - 1
    var max_x := ceili(float(bounds.get("maxX", 0.0)) / step) + 1
    var min_z := floori(float(bounds.get("minZ", 0.0)) / step) - 1
    var max_z := ceili(float(bounds.get("maxZ", 0.0)) / step) + 1
    var inside := {}

    for gx in range(min_x, max_x + 1):
        for gz in range(min_z, max_z + 1):
            var center := Vector2((float(gx) + 0.5) * step, (float(gz) + 0.5) * step)
            if cave_volume_value(plan, center) <= 1.08:
                inside[Vector2i(gx, gz)] = true

    for gx in range(min_x, max_x + 1):
        for gz in range(min_z, max_z + 1):
            var key := Vector2i(gx, gz)
            if not inside.has(key):
                continue
            var p00 := Vector2(float(gx) * step, float(gz) * step)
            var p10 := Vector2(float(gx + 1) * step, float(gz) * step)
            var p11 := Vector2(float(gx + 1) * step, float(gz + 1) * step)
            var p01 := Vector2(float(gx) * step, float(gz + 1) * step)
            add_floor_quad(st, plan, p00, p10, p11, p01)
            add_ceiling_quad(st, plan, p00, p01, p11, p10)
            add_boundary_walls(st, plan, inside, key, p00, p10, p11, p01, detailed)

func add_floor_quad(st: SurfaceTool, plan: Dictionary, p00: Vector2, p10: Vector2, p11: Vector2, p01: Vector2) -> void:
    add_quad(
        st,
        floor_point(plan, p00),
        floor_point(plan, p10),
        floor_point(plan, p11),
        floor_point(plan, p01),
        floor_color(world_cell(p00))
    )

func add_ceiling_quad(st: SurfaceTool, plan: Dictionary, p00: Vector2, p01: Vector2, p11: Vector2, p10: Vector2) -> void:
    add_quad(
        st,
        ceiling_point(plan, p00),
        ceiling_point(plan, p01),
        ceiling_point(plan, p11),
        ceiling_point(plan, p10),
        ceiling_color(world_cell(p00))
    )

func add_boundary_walls(st: SurfaceTool, plan: Dictionary, inside: Dictionary, key: Vector2i, p00: Vector2, p10: Vector2, p11: Vector2, p01: Vector2, detailed := true) -> void:
    var segments := WALL_VERTICAL_SEGMENTS if detailed else 2
    if not inside.has(key + Vector2i(0, -1)) and not is_entrance_mouth_edge(plan, (p00 + p10) * 0.5, Vector2i(0, -1)):
        add_wall_strip(st, plan, p10, p00, Vector2(0.0, -1.0), segments)
    if not inside.has(key + Vector2i(1, 0)) and not is_entrance_mouth_edge(plan, (p10 + p11) * 0.5, Vector2i(1, 0)):
        add_wall_strip(st, plan, p11, p10, Vector2(1.0, 0.0), segments)
    if not inside.has(key + Vector2i(0, 1)) and not is_entrance_mouth_edge(plan, (p11 + p01) * 0.5, Vector2i(0, 1)):
        add_wall_strip(st, plan, p01, p11, Vector2(0.0, 1.0), segments)
    if not inside.has(key + Vector2i(-1, 0)) and not is_entrance_mouth_edge(plan, (p01 + p00) * 0.5, Vector2i(-1, 0)):
        add_wall_strip(st, plan, p00, p01, Vector2(-1.0, 0.0), segments)

func add_wall_strip(st: SurfaceTool, plan: Dictionary, a2: Vector2, b2: Vector2, outward: Vector2, vertical_segments: int) -> void:
    var cell := world_cell((a2 + b2) * 0.5)
    var color := wall_color(cell)
    var rough_offset_a := boundary_offset(plan, a2, outward)
    var rough_offset_b := boundary_offset(plan, b2, outward)
    var a := a2 + outward * rough_offset_a
    var b := b2 + outward * rough_offset_b
    for segment in range(vertical_segments):
        var t0 := float(segment) / float(vertical_segments)
        var t1 := float(segment + 1) / float(vertical_segments)
        var a0 := wall_point(plan, a, t0)
        var b0 := wall_point(plan, b, t0)
        var b1 := wall_point(plan, b, t1)
        var a1 := wall_point(plan, a, t1)
        add_quad(st, a0, b0, b1, a1, color)

func wall_point(plan: Dictionary, point: Vector2, vertical_t: float) -> Vector3:
    var floor := floor_point(plan, point)
    var ceiling := ceiling_point(plan, point)
    var y := lerpf(floor.y - WALL_OVERLAP, ceiling.y + WALL_OVERLAP, vertical_t)
    var belly := sin(vertical_t * PI) * stable_signed(plan, "wall-belly", floori(point.x * 0.5), floori(point.y * 0.5)) * 0.18
    return Vector3(point.x, y + belly, point.y)

func boundary_offset(plan: Dictionary, point: Vector2, outward: Vector2) -> float:
    return 0.0

func floor_point(plan: Dictionary, point: Vector2) -> Vector3:
    var floor_y := float(plan.get("level", 0.0)) + 0.22
    var cell_size := float(main.CELL)
    var wave := stable_signed(plan, "floor-warp", floori(point.x / (cell_size * 0.5)), floori(point.y / (cell_size * 0.5))) * 0.20
    var center_lift := maxf(0.0, 1.0 - cave_volume_value(plan, point)) * 0.08
    return Vector3(point.x, floor_y + wave + center_lift, point.y)

func ceiling_point(plan: Dictionary, point: Vector2) -> Vector3:
    var ceiling_y := float(plan.get("ceilingLevel", float(plan.get("level", 0.0)) + float(main.CELL) * 3.0))
    var cell_size := float(main.CELL)
    var value := cave_volume_value(plan, point)
    var dome := maxf(0.0, 1.0 - value) * cell_size * 0.34
    var wave := stable_signed(plan, "ceiling-warp", floori(point.x / (cell_size * 0.5)), floori(point.y / (cell_size * 0.5))) * 0.34
    return Vector3(point.x, ceiling_y + dome + wave, point.y)

func cave_world_bounds(plan: Dictionary) -> Dictionary:
    var profiles := cached_profile_points(plan)
    var min_x := INF
    var min_z := INF
    var max_x := -INF
    var max_z := -INF
    var margin := float(main.CELL) * 1.6
    for profile_value in profiles:
        var profile: Dictionary = profile_value
        var center: Vector2 = profile.get("center", Vector2.ZERO)
        var radius := float(profile.get("radius", float(main.CELL) * 2.0)) + margin
        min_x = minf(min_x, center.x - radius)
        max_x = maxf(max_x, center.x + radius)
        min_z = minf(min_z, center.y - radius)
        max_z = maxf(max_z, center.y + radius)
    return {
        "minX": min_x,
        "maxX": max_x,
        "minZ": min_z,
        "maxZ": max_z
    }

func cached_profile_points(plan: Dictionary) -> Array[Dictionary]:
    var cache_key := "%s:%s" % [String(main.get("seed_text")), String(plan.get("id", "cave"))]
    if profile_cache.has(cache_key):
        return profile_cache[cache_key]
    var profiles := cave_profile_points(plan)
    profile_cache[cache_key] = profiles
    return profiles

func cave_profile_points(plan: Dictionary) -> Array[Dictionary]:
    var graph_nodes = plan.get("caveNodes", [])
    var graph_edges = plan.get("caveEdges", [])
    if graph_nodes is Array and graph_edges is Array and not (graph_nodes as Array).is_empty() and not (graph_edges as Array).is_empty():
        return cave_graph_profile_points(plan, graph_nodes, graph_edges)
    var profiles: Array[Dictionary] = []
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var path_length := int(plan.get("pathLength", 0))
    var cell_size := float(main.CELL)
    for depth in range(0, path_length + 1):
        var center_cell := path_center_cell(plan, depth)
        var half_width := path_half_width_cells(plan, depth, center_cell)
        var radius := maxf(cell_size * 2.10, (half_width + 1.15) * cell_size)
        if depth > path_length - 4:
            radius += cell_size * 0.55
        radius *= 0.92 + stable01(plan, "profile-radius", depth, 0) * 0.20
        profiles.append({
            "center": cell_world2(center_cell),
            "radius": radius,
            "kind": "tunnel"
        })
    var chamber_cell: Vector2i = plan.get("finalChamberCell", entrance)
    var chamber_radius := float(int(plan.get("chamberRadius", 4))) * cell_size
    profiles.append({
        "center": cell_world2(chamber_cell),
        "radius": chamber_radius * 1.55,
        "kind": "chamber"
    })
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    for offset in [right * 3, right * -3, inward * 3, inward * -2]:
        var lobe_cell: Vector2i = chamber_cell + offset
        profiles.append({
            "center": cell_world2(lobe_cell),
            "radius": chamber_radius * (0.70 + stable01(plan, "chamber-lobe", lobe_cell.x, lobe_cell.y) * 0.22),
            "kind": "chamber_lobe"
        })
    return profiles

func cave_graph_profile_points(plan: Dictionary, graph_nodes: Array, graph_edges: Array) -> Array[Dictionary]:
    var profiles: Array[Dictionary] = []
    var cell_size := float(main.CELL)
    var seen_edges := {}
    for edge_value in graph_edges:
        if not (edge_value is Dictionary):
            continue
        var edge: Dictionary = edge_value
        var edge_id := String(edge.get("id", "edge"))
        var radius := maxf(cell_size * 2.05, float(edge.get("radius", 1.7)) * cell_size * 1.34)
        var center_cells = edge.get("centerCells", [])
        if not (center_cells is Array):
            continue
        for cell_value in center_cells:
            var cell: Vector2i = cell_value
            var key := "%s:%d,%d" % [edge_id, cell.x, cell.y]
            if seen_edges.has(key):
                continue
            seen_edges[key] = true
            var profile_radius := radius * (0.92 + stable01(plan, "graph-edge-radius:%s" % edge_id, cell.x, cell.y) * 0.22)
            profiles.append({
                "center": cell_world2(cell),
                "radius": profile_radius,
                "kind": "tunnel"
            })
    for node_value in graph_nodes:
        if not (node_value is Dictionary):
            continue
        var node: Dictionary = node_value
        var node_id := String(node.get("id", "node"))
        var node_kind := String(node.get("kind", "chamber"))
        var node_cell: Vector2i = node.get("cell", Vector2i.ZERO)
        var radius_cells := float(node.get("radius", 3))
        var radius_scale := 1.16
        if node_kind == "final":
            radius_scale = 1.36
        elif node_kind == "entrance":
            radius_scale = 0.92
        elif node_kind == "junction":
            radius_scale = 1.22
        profiles.append({
            "center": cell_world2(node_cell),
            "radius": radius_cells * cell_size * radius_scale,
            "kind": node_kind
        })
        if node_kind == "entrance":
            continue
        for lobe_index in range(2):
            var lobe_angle := TAU * stable01(plan, "graph-node-lobe-angle:%s" % node_id, lobe_index, 0)
            var lobe_distance := radius_cells * cell_size * (0.34 + stable01(plan, "graph-node-lobe-distance:%s" % node_id, lobe_index, 0) * 0.24)
            var lobe_center := cell_world2(node_cell) + Vector2(cos(lobe_angle), sin(lobe_angle)) * lobe_distance
            var lobe_radius := radius_cells * cell_size * (0.42 + stable01(plan, "graph-node-lobe-radius:%s" % node_id, lobe_index, 0) * 0.20)
            profiles.append({
                "center": lobe_center,
                "radius": lobe_radius,
                "kind": "chamber_lobe"
            })
    return profiles

func cave_volume_value(plan: Dictionary, point: Vector2) -> float:
    var best := INF
    var cell_size := float(main.CELL)
    var noise_x := floori(point.x / (cell_size * 0.75))
    var noise_z := floori(point.y / (cell_size * 0.75))
    var edge_noise := 0.88 + stable01(plan, "volume-edge", noise_x, noise_z) * 0.24
    for profile_value in cached_profile_points(plan):
        var profile: Dictionary = profile_value
        var center: Vector2 = profile.get("center", Vector2.ZERO)
        var radius := float(profile.get("radius", cell_size * 2.0)) * edge_noise
        if radius <= 0.01:
            continue
        var value := center.distance_to(point) / radius
        best = minf(best, value)
    return best

func path_center_cell(plan: Dictionary, depth: int) -> Vector2i:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var cells_value = plan.get("pathCells", [])
    if not (cells_value is Array):
        return entrance + inward * depth
    var sum_x := 0.0
    var sum_z := 0.0
    var count := 0
    for cell_value in cells_value:
        var cell: Vector2i = cell_value
        if path_depth(plan, cell) != depth:
            continue
        sum_x += float(cell.x)
        sum_z += float(cell.y)
        count += 1
    if count <= 0:
        return entrance + inward * depth
    return Vector2i(roundi(sum_x / float(count)), roundi(sum_z / float(count)))

func path_half_width_cells(plan: Dictionary, depth: int, center_cell: Vector2i) -> float:
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    var cells_value = plan.get("pathCells", [])
    if not (cells_value is Array):
        return 1.5
    var half_width := 1.5
    for cell_value in cells_value:
        var cell: Vector2i = cell_value
        if path_depth(plan, cell) != depth:
            continue
        var delta := cell - center_cell
        var lateral := float(delta.x * right.x + delta.y * right.y)
        half_width = maxf(half_width, absf(lateral) + 0.5)
    return half_width

func path_depth(plan: Dictionary, cell: Vector2i) -> int:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var delta := cell - entrance
    return delta.x * inward.x + delta.y * inward.y

func is_entrance_mouth_edge(plan: Dictionary, point: Vector2, direction: Vector2i) -> bool:
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var outward := Vector2i(-inward.x, -inward.y)
    if direction != outward:
        return false
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    var cell_size := float(main.CELL)
    var delta := (point - cell_world2(entrance)) / cell_size
    var depth := delta.dot(Vector2(float(inward.x), float(inward.y)))
    var lateral := delta.dot(Vector2(float(right.x), float(right.y)))
    return depth <= 1.2 and absf(lateral) <= 2.4

func add_procedural_formations(st: SurfaceTool, plan: Dictionary, rng: RandomNumberGenerator) -> void:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var chest: Vector2i = plan.get("finalChestCell", plan.get("finalChamberCell", entrance))
    var cells := cave_walkable_cells(plan)
    var placed := 0
    for cell in cells:
        if placed >= 24:
            break
        if cell_distance(cell, entrance) < 5.0 or cell_distance(cell, chest) < 3.0:
            continue
        if rng.randf() > 0.42:
            continue
        var point := cell_world2(cell)
        if cave_volume_value(plan, point) > 0.92:
            continue
        point.x += rng.randf_range(-float(main.CELL) * 0.28, float(main.CELL) * 0.28)
        point.y += rng.randf_range(-float(main.CELL) * 0.28, float(main.CELL) * 0.28)
        var radius := rng.randf_range(float(main.CELL) * 0.10, float(main.CELL) * 0.26)
        var height := rng.randf_range(float(main.CELL) * 0.34, float(main.CELL) * 1.10)
        if rng.randf() < 0.52:
            add_cone(st, floor_point(plan, point), radius, height, false, formation_color(cell))
        else:
            add_cone(st, ceiling_point(plan, point), radius, height, true, formation_color(cell).darkened(0.12))
        placed += 1

func add_support_frames(root: Node3D, plan: Dictionary) -> void:
    var specs := cave_support_frame_specs(plan)
    for index in range(specs.size()):
        var spec: Dictionary = specs[index]
        var center: Vector2 = spec.get("center", Vector2.ZERO)
        var direction_2d: Vector2 = spec.get("direction", Vector2.RIGHT)
        if direction_2d.length() <= 0.01:
            direction_2d = Vector2.RIGHT
        direction_2d = direction_2d.normalized()
        var perp_2d := Vector2(-direction_2d.y, direction_2d.x)
        var floor := floor_point(plan, center)
        var ceiling := ceiling_point(plan, center)
        var height := maxf(1.4, ceiling.y - floor.y - 0.42)
        var width := float(main.CELL) * 1.32
        var frame := Node3D.new()
        frame.name = "CaveSupportFrame_%02d" % index
        frame.position = Vector3(center.x, floor.y + height * 0.5, center.y)
        frame.basis = Basis(
            Vector3(perp_2d.x, 0.0, perp_2d.y),
            Vector3.UP,
            Vector3(direction_2d.x, 0.0, direction_2d.y)
        ).orthonormalized()
        frame.set_meta("generated", true)
        frame.set_meta("generatedTier", "cave")
        frame.set_meta("caveId", String(plan.get("id", "")))
        frame.set_meta("caveRole", "support_frame")
        root.add_child(frame)
        add_support_beam(frame, Vector3(-width, 0.0, 0.0), Vector3(0.16, height, 0.16))
        add_support_beam(frame, Vector3(width, 0.0, 0.0), Vector3(0.16, height, 0.16))
        add_support_beam(frame, Vector3(0.0, height * 0.48, 0.0), Vector3(width * 2.0 + 0.34, 0.18, 0.18))

func add_support_beam(frame: Node3D, local_position: Vector3, size: Vector3) -> void:
    var mesh := BoxMesh.new()
    mesh.size = size
    var beam := MeshInstance3D.new()
    beam.name = "Beam"
    beam.mesh = mesh
    beam.material_override = cave_support_material()
    beam.position = local_position
    beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    frame.add_child(beam)

func cave_support_frame_specs(plan: Dictionary) -> Array[Dictionary]:
    var specs: Array[Dictionary] = []
    var edges_value = plan.get("caveEdges", [])
    if not (edges_value is Array):
        return specs
    var candidates: Array[Dictionary] = []
    for edge_value in edges_value:
        if not (edge_value is Dictionary):
            continue
        var edge: Dictionary = edge_value
        var center_cells_value = edge.get("centerCells", [])
        if not (center_cells_value is Array):
            continue
        var center_cells: Array = center_cells_value
        if center_cells.size() < 7:
            continue
        if String(edge.get("from", "")) == "entrance":
            continue
        var index := clampi(roundi(float(center_cells.size() - 1) * 0.46), 2, center_cells.size() - 3)
        var cell: Vector2i = center_cells[index]
        var previous: Vector2i = center_cells[maxi(0, index - 2)]
        var next: Vector2i = center_cells[mini(center_cells.size() - 1, index + 2)]
        var direction := Vector2(float(next.x - previous.x), float(next.y - previous.y))
        if direction.length() <= 0.01:
            direction = Vector2.RIGHT
        candidates.append({
            "edgeId": String(edge.get("id", "")),
            "center": cell_world2(cell),
            "direction": direction.normalized(),
            "length": center_cells.size()
        })
    candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        var score_a := int(a.get("length", 0)) + int(stable01(plan, "support-score:%s" % String(a.get("edgeId", "")), 0, 0) * 100.0)
        var score_b := int(b.get("length", 0)) + int(stable01(plan, "support-score:%s" % String(b.get("edgeId", "")), 0, 0) * 100.0)
        return score_a > score_b
    )
    for candidate in candidates:
        if specs.size() >= 2:
            break
        if specs.is_empty() or stable01(plan, "support-keep:%s" % String(candidate.get("edgeId", "")), specs.size(), 0) < 0.72:
            specs.append(candidate)
    return specs

func add_cone(st: SurfaceTool, center: Vector3, radius: float, height: float, hanging: bool, color: Color) -> void:
    var base_y := center.y
    var tip_y := center.y - height if hanging else center.y + height
    var tip := Vector3(center.x, tip_y, center.z)
    var ring: Array[Vector3] = []
    for i in range(FORMATION_SEGMENTS):
        var angle := TAU * float(i) / float(FORMATION_SEGMENTS)
        ring.append(Vector3(center.x + cos(angle) * radius, base_y, center.z + sin(angle) * radius))
    for i in range(FORMATION_SEGMENTS):
        var a: Vector3 = ring[i]
        var b: Vector3 = ring[(i + 1) % FORMATION_SEGMENTS]
        if hanging:
            add_triangle(st, a, tip, b, color)
        else:
            add_triangle(st, a, b, tip, color)

func add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
    add_triangle(st, a, b, c, color)
    add_triangle(st, a, c, d, color)

func add_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
    st.set_color(color)
    st.add_vertex(a)
    st.set_color(color)
    st.add_vertex(b)
    st.set_color(color)
    st.add_vertex(c)

func cave_walkable_cells(plan: Dictionary) -> Array[Vector2i]:
    var result: Array[Vector2i] = []
    for key in ["pathCells", "chamberCells"]:
        for cell_value in plan.get(key, []):
            var cell: Vector2i = cell_value
            result.append(cell)
    return result

func world_cell(point: Vector2) -> Vector2i:
    var cell_size := float(main.CELL)
    return Vector2i(roundi(point.x / cell_size), roundi(point.y / cell_size))

func cell_world2(cell: Vector2i) -> Vector2:
    var cell_size := float(main.CELL)
    return Vector2(float(cell.x) * cell_size, float(cell.y) * cell_size)

func cell_distance(a: Vector2i, b: Vector2i) -> float:
    return Vector2(float(a.x - b.x), float(a.y - b.y)).length()

func floor_color(cell: Vector2i) -> Color:
    var shade := stable_shade(cell, 0.78, 1.06)
    return Color(0.115, 0.122, 0.122) * shade

func wall_color(cell: Vector2i) -> Color:
    var shade := stable_shade(cell + Vector2i(-13, 29), 0.74, 1.04)
    return Color(0.16, 0.18, 0.18) * shade

func ceiling_color(cell: Vector2i) -> Color:
    var shade := stable_shade(cell + Vector2i(19, -31), 0.64, 0.94)
    return Color(0.046, 0.054, 0.056) * shade

func formation_color(cell: Vector2i) -> Color:
    var shade := stable_shade(cell + Vector2i(47, 13), 0.74, 1.02)
    return Color(0.24, 0.27, 0.25) * shade

func stable_shade(cell: Vector2i, low: float, high: float) -> float:
    var text := "%s:cave-shade:%d,%d" % [String(main.get("seed_text")), cell.x, cell.y]
    var h := int(main.hash_string(text)) if main != null and main.has_method("hash_string") else hash(text)
    var t := float(abs(h) % 1000) / 999.0
    return lerpf(low, high, t)

func stable01(plan: Dictionary, salt: String, x: int, z: int) -> float:
    var text := "%s:%s:%s:%d,%d" % [String(main.get("seed_text")), String(plan.get("id", "cave")), salt, x, z]
    var h := int(main.hash_string(text)) if main != null and main.has_method("hash_string") else hash(text)
    return float(abs(h) % 100000) / 99999.0

func stable_signed(plan: Dictionary, salt: String, x: int, z: int) -> float:
    return stable01(plan, salt, x, z) * 2.0 - 1.0
