extends RefCounted
class_name CaveInteriorBuilder

const GRID_SUBDIVISIONS := 3.0
const WALL_VERTICAL_SEGMENTS := 5
const FORMATION_SEGMENTS := 6
const WALL_OVERLAP := 0.46
const CAVE_VISUAL_LAYER := 1 << 1

var main
var cave_material: StandardMaterial3D
var cave_shadow_material: StandardMaterial3D
var formation_material: StandardMaterial3D
var support_material: StandardMaterial3D
var profile_cache := {}
var cover_drop_cache := {}

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
    var formation_mesh := build_formation_mesh(plan, rng)
    var collision_mesh := build_collision_mesh(plan)
    var visual := MeshInstance3D.new()
    visual.name = "CaveInteriorVisual"
    visual.mesh = visual_mesh
    visual.material_override = material()
    visual.layers = CAVE_VISUAL_LAYER
    visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    root.add_child(visual)

    var shadow := MeshInstance3D.new()
    shadow.name = "CaveInteriorShadow"
    shadow.mesh = visual_mesh
    shadow.material_override = shadow_only_material()
    shadow.layers = CAVE_VISUAL_LAYER
    shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
    root.add_child(shadow)

    var formations := MeshInstance3D.new()
    formations.name = "CaveInteriorFormations"
    formations.mesh = formation_mesh
    formations.material_override = cave_formation_material()
    formations.layers = CAVE_VISUAL_LAYER
    formations.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    root.add_child(formations)
    add_mouth_arch_visual(root, plan)

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

func add_mouth_arch_visual(root: Node3D, plan: Dictionary) -> void:
    if root == null or main == null:
        return
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward_cell: Vector2i = plan.get("inward", Vector2i(0, 1))
    var right_cell: Vector2i = plan.get("right", Vector2i(1, 0))
    var inward := Vector2(float(inward_cell.x), float(inward_cell.y)).normalized()
    var right := Vector2(float(right_cell.x), float(right_cell.y)).normalized()
    if inward.length() <= 0.01:
        inward = Vector2(0.0, 1.0)
    if right.length() <= 0.01:
        right = Vector2(1.0, 0.0)
    var cell_size := float(main.CELL)
    var origin := cell_world2(entrance) - inward * cell_size * 0.12
    var floor_y := floor_point(plan, cell_world2(entrance)).y - 0.02
    var inner_radius := maxf(float(plan.get("entranceMouthHalfWidth", 3.85)) * cell_size * 0.98, cell_size * 3.55)
    var outer_radius := inner_radius + cell_size * 0.72
    var color := Color(0.34, 0.37, 0.35)
    var segments := 24
    for index in range(segments):
        var a0 := PI - (float(index) / float(segments)) * PI
        var a1 := PI - (float(index + 1) / float(segments)) * PI
        var outer0 := mouth_arch_vertex(origin, right, floor_y, outer_radius, a0)
        var outer1 := mouth_arch_vertex(origin, right, floor_y, outer_radius, a1)
        var inner1 := mouth_arch_vertex(origin, right, floor_y, inner_radius, a1)
        var inner0 := mouth_arch_vertex(origin, right, floor_y, inner_radius, a0)
        add_quad(st, outer0, outer1, inner1, inner0, color)
    st.generate_normals()
    var mesh := st.commit()
    if mesh == null:
        return
    var arch := MeshInstance3D.new()
    arch.name = "CaveMouthSemicircle"
    arch.mesh = mesh
    arch.material_override = material()
    arch.layers = CAVE_VISUAL_LAYER
    arch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    arch.set_meta("generated", true)
    arch.set_meta("generatedTier", "cave")
    arch.set_meta("caveRole", "mouth_semicircle")
    arch.set_meta("caveId", String(plan.get("id", "")))
    root.add_child(arch)

func mouth_arch_vertex(origin: Vector2, right: Vector2, floor_y: float, radius: float, angle: float) -> Vector3:
    var lateral := cos(angle) * radius
    var y := floor_y + sin(angle) * radius
    var point := origin + right * lateral
    return Vector3(point.x, y, point.y)

func material() -> StandardMaterial3D:
    if cave_material != null:
        return cave_material
    cave_material = StandardMaterial3D.new()
    cave_material.vertex_color_use_as_albedo = true
    cave_material.albedo_color = Color(0.40, 0.43, 0.42)
    cave_material.roughness = 0.96
    cave_material.cull_mode = BaseMaterial3D.CULL_DISABLED
    cave_material.set("disable_ambient_light", true)
    return cave_material

func shadow_only_material() -> StandardMaterial3D:
    if cave_shadow_material != null:
        return cave_shadow_material
    cave_shadow_material = StandardMaterial3D.new()
    cave_shadow_material.vertex_color_use_as_albedo = true
    cave_shadow_material.albedo_color = Color(0.08, 0.09, 0.09)
    cave_shadow_material.roughness = 1.0
    cave_shadow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
    cave_shadow_material.set("disable_ambient_light", true)
    return cave_shadow_material

func cave_formation_material() -> StandardMaterial3D:
    if formation_material != null:
        return formation_material
    formation_material = StandardMaterial3D.new()
    formation_material.vertex_color_use_as_albedo = true
    formation_material.albedo_color = Color(0.32, 0.35, 0.33)
    formation_material.roughness = 0.96
    formation_material.cull_mode = BaseMaterial3D.CULL_DISABLED
    formation_material.set("disable_ambient_light", true)
    return formation_material

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
    st.generate_normals()
    return st.commit()

func build_formation_mesh(plan: Dictionary, rng: RandomNumberGenerator) -> ArrayMesh:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
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
    var route_drop := cave_depth_drop_at_point(plan, point)
    var base_ceiling_y := float(plan.get("ceilingLevel", float(plan.get("level", 0.0)) + float(main.CELL) * 3.0)) - route_drop
    var cover_drop := cave_cover_drop_at_point(plan, point, base_ceiling_y)
    var floor_y := cave_base_floor_y(plan, route_drop, cover_drop, base_ceiling_y - cover_drop)
    var cell_size := float(main.CELL)
    var variation_scale := cave_floor_variation_scale(plan, point)
    var phase_x := stable_signed(plan, "floor-phase-x", 0, 0) * PI * 2.0
    var phase_z := stable_signed(plan, "floor-phase-z", 1, 0) * PI * 2.0
    var micro := stable_signed(plan, "floor-warp", floori(point.x / (cell_size * 0.5)), floori(point.y / (cell_size * 0.5))) * 0.08 * variation_scale
    var broad_roll := (sin(point.x * 0.105 + phase_x) + cos(point.y * 0.098 + phase_z)) * cell_size * 0.16 * variation_scale
    var diagonal := sin((point.x + point.y) * 0.075 + phase_x * 0.5) * cell_size * 0.10 * variation_scale
    var ridge := sin(point.x * 0.18 + phase_z) * cos(point.y * 0.16 + phase_x) * cell_size * 0.10 * variation_scale
    var center_lift := maxf(0.0, 1.0 - cave_volume_value(plan, point)) * 0.08 * variation_scale
    return Vector3(point.x, floor_y + micro + broad_roll + diagonal + ridge + center_lift, point.y)

func cave_floor_variation_scale(plan: Dictionary, point: Vector2) -> float:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward_cell: Vector2i = plan.get("inward", Vector2i(0, 1))
    var inward := Vector2(float(inward_cell.x), float(inward_cell.y))
    if inward.length() <= 0.01:
        return 1.0
    inward = inward.normalized()
    var depth := (point - cell_world2(entrance)).dot(inward) / float(main.CELL)
    return smoothstep(1.4, 7.0, depth)

func ceiling_point(plan: Dictionary, point: Vector2) -> Vector3:
    var route_drop := cave_depth_drop_at_point(plan, point)
    var base_ceiling_y := float(plan.get("ceilingLevel", float(plan.get("level", 0.0)) + float(main.CELL) * 3.0)) - route_drop
    var cover_drop := cave_cover_drop_at_point(plan, point, base_ceiling_y)
    var ceiling_y := base_ceiling_y - cover_drop
    var floor_y := cave_base_floor_y(plan, route_drop, cover_drop, ceiling_y)
    var mouth_arch_blend := cave_mouth_arch_blend(plan, point)
    if mouth_arch_blend > 0.001:
        ceiling_y = lerpf(ceiling_y, cave_mouth_arch_ceiling_y(plan, point, floor_y), mouth_arch_blend)
    var cell_size := float(main.CELL)
    var value := cave_volume_value(plan, point)
    var dome := maxf(0.0, 1.0 - value) * cell_size * 0.34 * (1.0 - mouth_arch_blend * 0.85)
    var wave := stable_signed(plan, "ceiling-warp", floori(point.x / (cell_size * 0.5)), floori(point.y / (cell_size * 0.5))) * 0.34 * (1.0 - mouth_arch_blend)
    return Vector3(point.x, ceiling_y + dome + wave, point.y)

func cave_mouth_depth_lateral(plan: Dictionary, point: Vector2) -> Vector2:
    var cell_size := float(main.CELL)
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward_cell: Vector2i = plan.get("inward", Vector2i(0, 1))
    var right_cell: Vector2i = plan.get("right", Vector2i(1, 0))
    var inward := Vector2(float(inward_cell.x), float(inward_cell.y))
    var right := Vector2(float(right_cell.x), float(right_cell.y))
    if inward.length() <= 0.01:
        inward = Vector2(0.0, 1.0)
    if right.length() <= 0.01:
        right = Vector2(1.0, 0.0)
    inward = inward.normalized()
    right = right.normalized()
    var delta := (point - cell_world2(entrance)) / cell_size
    return Vector2(delta.dot(inward), delta.dot(right))

func cave_mouth_width_at_depth(plan: Dictionary, depth_cells: float) -> float:
    var interior_depth := float(maxi(1, int(plan.get("entranceOpenDepth", 7))))
    var mouth_width := maxf(3.75, float(plan.get("entranceMouthHalfWidth", 3.85)))
    if depth_cells < 0.0 or depth_cells > interior_depth + 1.75:
        return 0.0
    if depth_cells <= 2.0:
        return mouth_width
    var taper_t := smoothstep(2.0, interior_depth + 1.75, depth_cells)
    return lerpf(mouth_width, 2.45, taper_t)

func cave_mouth_arch_blend(plan: Dictionary, point: Vector2) -> float:
    var axes := cave_mouth_depth_lateral(plan, point)
    var depth_cells := axes.x
    var width := cave_mouth_width_at_depth(plan, depth_cells)
    if width <= 0.0:
        return 0.0
    var lateral_t := absf(axes.y) / maxf(0.001, width)
    if lateral_t > 1.08:
        return 0.0
    var interior_depth := float(maxi(1, int(plan.get("entranceOpenDepth", 7))))
    var depth_blend := 1.0 - smoothstep(3.0, interior_depth + 1.5, depth_cells)
    var front_blend := smoothstep(-0.65, 0.0, depth_cells)
    return clampf(depth_blend * front_blend, 0.0, 1.0)

func cave_mouth_arch_ceiling_y(plan: Dictionary, point: Vector2, floor_y: float) -> float:
    var axes := cave_mouth_depth_lateral(plan, point)
    var width := cave_mouth_width_at_depth(plan, axes.x)
    if width <= 0.0:
        return float(plan.get("ceilingLevel", floor_y + float(main.CELL) * 3.0))
    var lateral_t := clampf(absf(axes.y) / maxf(0.001, width), 0.0, 1.0)
    var arch := sqrt(maxf(0.0, 1.0 - lateral_t * lateral_t))
    var arch_height := clampf(width * float(main.CELL) * 0.98, float(main.CELL) * 2.70, float(main.CELL) * 4.65)
    return floor_y + maxf(float(main.CELL) * 0.55, arch_height * arch)

func cave_base_floor_y(plan: Dictionary, route_drop: float, cover_drop: float, ceiling_y: float) -> float:
    var floor_y := float(plan.get("level", 0.0)) + 0.22 - route_drop - cover_drop * 0.68
    var minimum_clearance := float(main.CELL) * 2.45
    if ceiling_y != INF:
        floor_y = minf(floor_y, ceiling_y - minimum_clearance)
    return floor_y

func cave_depth_drop_at_point(plan: Dictionary, point: Vector2) -> float:
    var max_drop := cave_max_vertical_drop(plan)
    if max_drop <= 0.01:
        return 0.0
    var progress := cave_depth_progress(plan, point)
    var route_drop := smoothstep(0.03, 1.0, progress) * max_drop
    var cell_size := float(main.CELL)
    var local_extra := maxf(
        0.0,
        stable_signed(
            plan,
            "depth-local-dip",
            floori(point.x / (cell_size * 1.5)),
            floori(point.y / (cell_size * 1.5))
        )
    ) * cell_size * 0.16 * smoothstep(0.12, 0.95, progress)
    return clampf(route_drop + local_extra, 0.0, max_drop + cell_size * 0.18)

func cave_cover_drop_at_point(plan: Dictionary, point: Vector2, base_ceiling_y: float) -> float:
    if main == null:
        return 0.0
    var cell_size := float(main.CELL)
    var cell_x := roundi(point.x / cell_size)
    var cell_z := roundi(point.y / cell_size)
    var cache_key := "%s:%d,%d:%d" % [String(plan.get("id", "cave")), cell_x, cell_z, roundi(base_ceiling_y * 10.0)]
    if cover_drop_cache.has(cache_key):
        return float(cover_drop_cache[cache_key])
    var progress := cave_depth_progress(plan, point)
    var mouth_clear_t := smoothstep(0.08, 0.24, progress)
    if mouth_clear_t <= 0.001:
        cover_drop_cache[cache_key] = 0.0
        return 0.0
    var required_cover := float(main.CELL) * 0.82
    var max_deficit := 0.0
    var weighted_deficit := 0.0
    var total_weight := 0.0
    for dz in range(-2, 3):
        for dx in range(-2, 3):
            var distance := Vector2(float(dx), float(dz)).length()
            if distance > 2.35:
                continue
            var sample_point := point + Vector2(float(dx) * cell_size, float(dz) * cell_size)
            var terrain_y := cave_surface_height_at_point(sample_point)
            var deficit := maxf(0.0, base_ceiling_y - (terrain_y - required_cover))
            var weight := 1.0 - smoothstep(0.0, 2.35, distance)
            max_deficit = maxf(max_deficit, deficit * maxf(0.35, weight))
            weighted_deficit += deficit * weight
            total_weight += weight
    var smoothed_deficit := maxf(max_deficit, weighted_deficit / maxf(0.001, total_weight))
    if smoothed_deficit <= 0.0:
        cover_drop_cache[cache_key] = 0.0
        return 0.0
    var drop := (smoothed_deficit + float(main.CELL) * 0.16) * mouth_clear_t
    cover_drop_cache[cache_key] = drop
    return drop

func cave_surface_height_at_point(point: Vector2) -> float:
    var cell_x := roundi(point.x / float(main.CELL))
    var cell_z := roundi(point.y / float(main.CELL))
    if main != null and main.has_method("base_height_cell"):
        return float(main.call("base_height_cell", cell_x, cell_z))
    if main != null and main.has_method("terrain_height_cell"):
        return float(main.call("terrain_height_cell", cell_x, cell_z))
    return 0.0

func cave_max_vertical_drop(plan: Dictionary) -> float:
    if main == null:
        return 0.0
    var cell_size := float(main.CELL)
    var tier := String(plan.get("caveTier", "normal"))
    var tier_bonus := 0.0
    if tier == "rare_long":
        tier_bonus = 2.45
    elif tier == "deep":
        tier_bonus = 1.35
    var desired := cell_size * (5.75 + tier_bonus)
    if String(plan.get("kind", "")) == "underground":
        desired += cell_size * 0.55
    var safe_floor := float(main.WATER_LEVEL) + cell_size * 1.45
    var available := maxf(0.0, float(plan.get("level", 0.0)) + 0.22 - safe_floor)
    return minf(desired, available * 0.90)

func cave_depth_progress(plan: Dictionary, point: Vector2) -> float:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var final_cell: Vector2i = plan.get("finalChamberCell", entrance)
    var inward_cell: Vector2i = plan.get("inward", Vector2i(0, 1))
    var inward := Vector2(float(inward_cell.x), float(inward_cell.y))
    if inward.length() <= 0.01:
        inward = Vector2(0.0, 1.0)
    inward = inward.normalized()
    var entrance_world := cell_world2(entrance)
    var final_world := cell_world2(final_cell)
    var final_depth := maxf(float(main.CELL) * 8.0, (final_world - entrance_world).dot(inward))
    var point_depth := (point - entrance_world).dot(inward)
    return clampf(point_depth / final_depth, 0.0, 1.0)

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
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    var mouth_width := float(plan.get("entranceMouthHalfWidth", 3.85))
    var mouth_depth := int(plan.get("entranceOpenDepth", 7))
    for depth in range(-1, 4):
        var width_t := clampf(float(depth + 1) / 4.0, 0.0, 1.0)
        var radius_cells := lerpf(mouth_width * 0.92, mouth_width * 1.08, 1.0 - absf(width_t - 0.42))
        profiles.append({
            "center": cell_world2(entrance + inward * depth),
            "radius": radius_cells * cell_size,
            "kind": "mouth"
        })
    var seen_edges := {}
    for edge_value in graph_edges:
        if not (edge_value is Dictionary):
            continue
        var edge: Dictionary = edge_value
        var edge_id := String(edge.get("id", "edge"))
        var radius := maxf(cell_size * 1.18, float(edge.get("radius", 1.7)) * cell_size * 1.05)
        var center_cells = edge.get("centerCells", [])
        if not (center_cells is Array):
            continue
        for cell_value in center_cells:
            var cell: Vector2i = cell_value
            var key := "%s:%d,%d" % [edge_id, cell.x, cell.y]
            if seen_edges.has(key):
                continue
            seen_edges[key] = true
            if cell_inside_mouth_corridor(plan, cell, mouth_depth, mouth_width, inward, right):
                continue
            var profile_radius := radius * (0.88 + stable01(plan, "graph-edge-radius:%s" % edge_id, cell.x, cell.y) * 0.20)
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
        if node_kind == "entrance":
            continue
        var radius_cells := float(node.get("radius", 3))
        var radius_scale := 1.16
        if node_kind == "final":
            radius_scale = 1.36
        elif node_kind == "junction":
            radius_scale = 1.22
        profiles.append({
            "center": cell_world2(node_cell),
            "radius": radius_cells * cell_size * radius_scale,
            "kind": node_kind
        })
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

func cell_inside_mouth_corridor(plan: Dictionary, cell: Vector2i, mouth_depth: int, mouth_width: float, inward: Vector2i, right: Vector2i) -> bool:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var delta := cell - entrance
    var depth := delta.x * inward.x + delta.y * inward.y
    if depth < 0:
        return true
    if depth > mouth_depth + 1:
        return false
    var lateral := delta.x * right.x + delta.y * right.y
    var width_at_depth := cave_mouth_width_at_depth(plan, float(depth))
    if width_at_depth <= 0.0:
        width_at_depth = mouth_width
    return absf(float(lateral)) <= width_at_depth + 1.25

func cave_volume_value(plan: Dictionary, point: Vector2) -> float:
    var best := cave_mouth_volume_value(plan, point)
    var cell_size := float(main.CELL)
    var noise_x := floori(point.x / (cell_size * 0.75))
    var noise_z := floori(point.y / (cell_size * 0.75))
    var edge_noise := 0.88 + stable01(plan, "volume-edge", noise_x, noise_z) * 0.24
    for profile_value in cached_profile_points(plan):
        var profile: Dictionary = profile_value
        if String(profile.get("kind", "")) == "mouth":
            continue
        var center: Vector2 = profile.get("center", Vector2.ZERO)
        var radius := float(profile.get("radius", cell_size * 2.0)) * edge_noise
        if radius <= 0.01:
            continue
        var value := center.distance_to(point) / radius
        best = minf(best, value)
    return best

func cave_mouth_volume_value(plan: Dictionary, point: Vector2) -> float:
    var axes := cave_mouth_depth_lateral(plan, point)
    var depth_cells := axes.x
    var width := cave_mouth_width_at_depth(plan, depth_cells)
    if width <= 0.0:
        return INF
    var lateral_value := absf(axes.y) / maxf(0.001, width)
    var interior_depth := float(maxi(1, int(plan.get("entranceOpenDepth", 7))))
    var back_cap := maxf(0.0, (depth_cells - (interior_depth + 1.75)) / 1.0)
    return maxf(lateral_value, back_cap)

func wall_mount_sample(plan: Dictionary, walk_cell: Vector2i, wall_normal: Vector2i) -> Dictionary:
    if main == null:
        return {}
    var cell_size := float(main.CELL)
    var inward := Vector2(float(wall_normal.x), float(wall_normal.y))
    if inward.length() <= 0.01:
        inward = Vector2(0.0, 1.0)
    inward = inward.normalized()
    var outward_base := -inward
    var origin := rendered_shell_inside_point(plan, cell_world2(walk_cell), inward)
    var best := {}
    var ray_count := 17
    var angle_span := deg_to_rad(36.0)
    var base_angle := outward_base.angle()
    for index in range(ray_count):
        var t := 0.0 if ray_count <= 1 else float(index) / float(ray_count - 1)
        var outward := Vector2.RIGHT.rotated(base_angle - angle_span * 0.5 + angle_span * t).normalized()
        if outward.dot(outward_base) < 0.90:
            continue
        var hit := rendered_shell_wall_ray_hit(plan, origin, outward, cell_size * 5.0)
        if hit.is_empty():
            continue
        var surface: Vector2 = hit.get("surface", origin)
        var hit_inward: Vector2 = hit.get("normalWorld", -outward)
        if hit_inward.length() <= 0.01:
            hit_inward = -outward
        hit_inward = hit_inward.normalized()
        var distance := origin.distance_to(surface)
        var alignment_penalty := (1.0 - outward.dot(outward_base)) * cell_size * 0.22
        var score := distance + alignment_penalty
        if best.is_empty() or score < float(best.get("score", INF)):
            best = {
                "surface": surface - hit_inward * cell_size * 0.055,
                "normalWorld": hit_inward,
                "score": score
            }
    return best

func rendered_shell_inside_point(plan: Dictionary, center: Vector2, inward: Vector2) -> Vector2:
    var step := float(main.CELL) * 0.10
    if rendered_shell_inside_at_point(plan, center):
        return center
    for index in range(1, 18):
        var point := center + inward * step * float(index)
        if rendered_shell_inside_at_point(plan, point):
            return point
    return center

func rendered_shell_wall_ray_hit(plan: Dictionary, origin: Vector2, outward: Vector2, max_distance: float) -> Dictionary:
    if not rendered_shell_inside_at_point(plan, origin):
        return {}
    var previous := origin
    var step := float(main.CELL) / (GRID_SUBDIVISIONS * 3.0)
    var steps := ceili(max_distance / step)
    for index in range(1, steps + 1):
        var distance := minf(max_distance, float(index) * step)
        var point := origin + outward * distance
        if not rendered_shell_inside_at_point(plan, point):
            var low := previous
            var high := point
            for _i in range(12):
                var mid := (low + high) * 0.5
                if rendered_shell_inside_at_point(plan, mid):
                    low = mid
                else:
                    high = mid
            var surface := (low + high) * 0.5
            return {
                "surface": surface,
                "normalWorld": rendered_shell_wall_inward_normal(plan, surface, -outward)
            }
        previous = point
    return {}

func rendered_shell_inside_at_point(plan: Dictionary, point: Vector2) -> bool:
    var step := float(main.CELL) / GRID_SUBDIVISIONS
    var gx := floori(point.x / step)
    var gz := floori(point.y / step)
    var center := Vector2((float(gx) + 0.5) * step, (float(gz) + 0.5) * step)
    return cave_volume_value(plan, center) <= 1.08

func rendered_shell_wall_inward_normal(plan: Dictionary, surface: Vector2, fallback_inward: Vector2) -> Vector2:
    var sample_step := float(main.CELL) / GRID_SUBDIVISIONS
    var inside_x_plus := rendered_shell_inside_at_point(plan, surface + Vector2(sample_step, 0.0))
    var inside_x_minus := rendered_shell_inside_at_point(plan, surface - Vector2(sample_step, 0.0))
    var inside_z_plus := rendered_shell_inside_at_point(plan, surface + Vector2(0.0, sample_step))
    var inside_z_minus := rendered_shell_inside_at_point(plan, surface - Vector2(0.0, sample_step))
    var inward := Vector2.ZERO
    if inside_x_plus != inside_x_minus:
        inward.x = 1.0 if inside_x_plus else -1.0
    if inside_z_plus != inside_z_minus:
        inward.y = 1.0 if inside_z_plus else -1.0
    if inward.length() <= 0.01:
        inward = fallback_inward
    if inward.length() <= 0.01:
        inward = Vector2(0.0, 1.0)
    return inward.normalized()

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
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    var cell_size := float(main.CELL)
    var delta := (point - cell_world2(entrance)) / cell_size
    var depth := delta.dot(Vector2(float(inward.x), float(inward.y)))
    var lateral := delta.dot(Vector2(float(right.x), float(right.y)))
    var mouth_width := float(plan.get("entranceMouthHalfWidth", 3.85))
    if depth >= -0.35 and depth <= 4.25 and absf(lateral) <= mouth_width + 0.80:
        return true
    return direction == outward and depth <= 2.8 and depth >= -1.2 and absf(lateral) <= mouth_width + 0.65

func is_entrance_mouth_visual_opening(plan: Dictionary, point: Vector2) -> bool:
    var axes := cave_mouth_depth_lateral(plan, point)
    var depth := axes.x
    if depth < -0.05 or depth > 2.75:
        return false
    var width := cave_mouth_width_at_depth(plan, depth)
    if width <= 0.0:
        width = float(plan.get("entranceMouthHalfWidth", 3.85))
    return absf(axes.y) <= width + 0.35

func add_procedural_formations(st: SurfaceTool, plan: Dictionary, rng: RandomNumberGenerator) -> void:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var chest: Vector2i = plan.get("finalChestCell", plan.get("finalChamberCell", entrance))
    var cells := cave_walkable_cells(plan)
    var placed := 0
    for cell in cells:
        if placed >= 24:
            break
        if cell_distance(cell, entrance) < 9.0 or cell_distance(cell, chest) < 3.0:
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
    beam.layers = CAVE_VISUAL_LAYER
    beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    frame.add_child(beam)

func floor_variation_summary(plan: Dictionary) -> Dictionary:
    var cells := cave_walkable_cells(plan)
    if cells.is_empty():
        return { "sampleCount": 0, "minY": 0.0, "maxY": 0.0, "range": 0.0, "maxNeighborStep": 0.0 }
    var heights := {}
    var min_y := INF
    var max_y := -INF
    for cell in cells:
        var y := floor_point(plan, cell_world2(cell)).y
        heights[cell] = y
        min_y = minf(min_y, y)
        max_y = maxf(max_y, y)
    var max_step := 0.0
    for cell in cells:
        var height := float(heights.get(cell, 0.0))
        for direction in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
            var next: Vector2i = cell + direction
            if heights.has(next):
                max_step = maxf(max_step, absf(height - float(heights.get(next, height))))
    return {
        "sampleCount": cells.size(),
        "minY": snappedf(min_y, 0.001),
        "maxY": snappedf(max_y, 0.001),
        "range": snappedf(max_y - min_y, 0.001),
        "maxNeighborStep": snappedf(max_step, 0.001)
    }

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
