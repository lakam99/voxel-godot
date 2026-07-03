extends "res://scripts/MainRuntimeTools.gd"

const VOLUME_CUBE_CORNER_OFFSETS := [
    Vector3i(0, 0, 0),
    Vector3i(1, 0, 0),
    Vector3i(1, 0, 1),
    Vector3i(0, 0, 1),
    Vector3i(0, 1, 0),
    Vector3i(1, 1, 0),
    Vector3i(1, 1, 1),
    Vector3i(0, 1, 1)
]
const VOLUME_TETRAHEDRA := [
    [0, 5, 1, 6],
    [0, 1, 2, 6],
    [0, 2, 3, 6],
    [0, 3, 7, 6],
    [0, 7, 4, 6],
    [0, 4, 5, 6]
]
const VOLUME_TETRAHEDRON_EDGES := [
    [0, 1],
    [0, 2],
    [0, 3],
    [1, 2],
    [1, 3],
    [2, 3]
]

func build_chunk_mesh(cx: int, cz: int) -> Mesh:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    st.set_material(terrain_material)
    var start_x: int = cx * CHUNK_SIZE
    var start_z: int = cz * CHUNK_SIZE
    var monitor = runtime_perf_monitor
    var cave_start: int = monitor.begin_section("chunk_cave_feature_query") if monitor != null else Time.get_ticks_usec()
    var cave_features := chunk_cave_features(start_x, start_z)
    if monitor != null:
        monitor.end_section("chunk_cave_feature_query", cave_start)
    if monitor != null and not cave_features.is_empty():
        monitor.increment_counter("chunk_cave_feature_chunks")
        monitor.increment_counter("chunk_cave_features", cave_features.size())
    if cave_features.is_empty():
        var exterior_start_no_caves: int = monitor.begin_section("chunk_exterior_surface_mesh") if monitor != null else Time.get_ticks_usec()
        var exterior_mesh := build_natural_exterior_array_mesh(start_x, start_z)
        if monitor != null:
            monitor.end_section("chunk_exterior_surface_mesh", exterior_start_no_caves)
        return exterior_mesh
    var exterior_start: int = monitor.begin_section("chunk_exterior_surface_mesh") if monitor != null else Time.get_ticks_usec()
    add_natural_exterior_surface(st, start_x, start_z, cave_features)
    if monitor != null:
        monitor.end_section("chunk_exterior_surface_mesh", exterior_start)
    var bounds := chunk_volume_y_bounds_from_features(start_x, start_z, cave_features)
    var min_y := int(bounds.get("minY", floori((MIN_HEIGHT - CELL * 4.0) / CELL))) - 1
    var max_y := int(bounds.get("maxY", ceili((MAX_HEIGHT + CELL * 2.0) / CELL))) + 1
    var sample_cache := {}
    if not cave_features.is_empty():
        var volume_start: int = monitor.begin_section("chunk_volume_mesh") if monitor != null else Time.get_ticks_usec()
        for z in range(start_z, start_z + CHUNK_SIZE):
            for x in range(start_x, start_x + CHUNK_SIZE):
                var cell_bounds := mesh_cell_volume_y_bounds(x, z, min_y, max_y, cave_features)
                var cell_min_y := int(cell_bounds.get("minY", min_y))
                var cell_max_y := int(cell_bounds.get("maxY", max_y))
                for y in range(cell_min_y, cell_max_y):
                    extract_volume_iso_cube(st, Vector3i(x, y, z), start_x, start_z, sample_cache)
        if monitor != null:
            monitor.end_section("chunk_volume_mesh", volume_start)
    var commit_start: int = monitor.begin_section("chunk_mesh_commit") if monitor != null else Time.get_ticks_usec()
    var mesh := st.commit()
    if monitor != null:
        monitor.end_section("chunk_mesh_commit", commit_start)
    return mesh

func build_natural_exterior_array_mesh(start_x: int, start_z: int) -> Mesh:
    var monitor = runtime_perf_monitor
    var border_size := CHUNK_SIZE + 3
    var surface_cache := PackedFloat32Array()
    surface_cache.resize(border_size * border_size)
    var height_start: int = monitor.begin_section("chunk_exterior_height_grid") if monitor != null else Time.get_ticks_usec()
    for vz in range(-1, CHUNK_SIZE + 2):
        var row_index := (vz + 1) * border_size
        for vx in range(-1, CHUNK_SIZE + 2):
            surface_cache[row_index + vx + 1] = exterior_surface_y_cell(start_x + vx, start_z + vz)
    if monitor != null:
        monitor.end_section("chunk_exterior_height_grid", height_start)

    var grid_size := CHUNK_SIZE + 1
    var vertex_count := grid_size * grid_size
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    vertices.resize(vertex_count)
    normals.resize(vertex_count)
    colors.resize(vertex_count)
    var vertex_start: int = monitor.begin_section("chunk_exterior_vertex_grid") if monitor != null else Time.get_ticks_usec()
    for vz in range(grid_size):
        var vertex_row := vz * grid_size
        var border_row := (vz + 1) * border_size
        for vx in range(grid_size):
            var vertex_index := vertex_row + vx
            var border_index := border_row + vx + 1
            var cell_x := start_x + vx
            var cell_z := start_z + vz
            vertices[vertex_index] = Vector3(float(vx) * CELL, float(surface_cache[border_index]), float(vz) * CELL)
            normals[vertex_index] = exterior_surface_normal_grid(surface_cache, border_index, border_size)
            var color: Color = exterior_surface_color_for_cell(cell_x, cell_z)
            var shade := 0.88 + noise01(ridge_noise, cell_x + 400, cell_z - 200) * 0.18
            colors[vertex_index] = color * shade
    if monitor != null:
        monitor.end_section("chunk_exterior_vertex_grid", vertex_start)

    var index_count := CHUNK_SIZE * CHUNK_SIZE * 6
    var indices := PackedInt32Array()
    indices.resize(index_count)
    var write_index := 0
    var index_start: int = monitor.begin_section("chunk_exterior_index_grid") if monitor != null else Time.get_ticks_usec()
    for z in range(CHUNK_SIZE):
        var row := z * grid_size
        var next_row := (z + 1) * grid_size
        for x in range(CHUNK_SIZE):
            var i00 := row + x
            var i10 := i00 + 1
            var i01 := next_row + x
            var i11 := i01 + 1
            indices[write_index] = i00
            indices[write_index + 1] = i01
            indices[write_index + 2] = i10
            indices[write_index + 3] = i10
            indices[write_index + 4] = i01
            indices[write_index + 5] = i11
            write_index += 6
    if monitor != null:
        monitor.end_section("chunk_exterior_index_grid", index_start)

    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_INDEX] = indices
    var commit_start: int = monitor.begin_section("chunk_mesh_commit") if monitor != null else Time.get_ticks_usec()
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, terrain_material)
    if monitor != null:
        monitor.end_section("chunk_mesh_commit", commit_start)
    return mesh

func add_natural_exterior_surface(st: SurfaceTool, start_x: int, start_z: int, cave_features: Array = []) -> void:
    var grid_size := CHUNK_SIZE + 3
    var surface_cache := PackedFloat32Array()
    surface_cache.resize(grid_size * grid_size)
    var color_cache: Array[Color] = []
    color_cache.resize(grid_size * grid_size)
    var normal_cache: Array[Vector3] = []
    normal_cache.resize(grid_size * grid_size)
    for vz in range(-1, CHUNK_SIZE + 2):
        var row_index := (vz + 1) * grid_size
        for vx in range(-1, CHUNK_SIZE + 2):
            var cell_x: int = start_x + vx
            var cell_z: int = start_z + vz
            var cache_index := row_index + vx + 1
            surface_cache[cache_index] = exterior_surface_y_cell(cell_x, cell_z)
            if vx < 0 or vx > CHUNK_SIZE or vz < 0 or vz > CHUNK_SIZE:
                continue
            var color: Color = exterior_surface_color_for_cell(cell_x, cell_z)
            var shade := 0.88 + noise01(ridge_noise, cell_x + 400, cell_z - 200) * 0.18
            color_cache[cache_index] = color * shade
    for vz in range(CHUNK_SIZE + 1):
        var row_index := (vz + 1) * grid_size
        for vx in range(CHUNK_SIZE + 1):
            var cache_index := row_index + vx + 1
            normal_cache[cache_index] = exterior_surface_normal_grid(surface_cache, cache_index, grid_size)
    for z in range(CHUNK_SIZE):
        for x in range(CHUNK_SIZE):
            var gx: int = start_x + x
            var gz: int = start_z + z
            var p00 := exterior_surface_vertex_grid(surface_cache, x, z, grid_size)
            var p10 := exterior_surface_vertex_grid(surface_cache, x + 1, z, grid_size)
            var p01 := exterior_surface_vertex_grid(surface_cache, x, z + 1, grid_size)
            var p11 := exterior_surface_vertex_grid(surface_cache, x + 1, z + 1, grid_size)
            var check_cave_air := exterior_cell_may_touch_cave(cave_features, gx, gz)
            add_exterior_surface_triangle_grid(st, p00, p01, p10, color_cache, normal_cache, x, z, x, z + 1, x + 1, z, grid_size, start_x, start_z, check_cave_air)
            add_exterior_surface_triangle_grid(st, p10, p01, p11, color_cache, normal_cache, x + 1, z, x, z + 1, x + 1, z + 1, grid_size, start_x, start_z, check_cave_air)

func exterior_surface_vertex_grid(surface_cache: PackedFloat32Array, vx: int, vz: int, grid_size: int) -> Vector3:
    var cache_index := (vz + 1) * grid_size + vx + 1
    return Vector3(float(vx) * CELL, float(surface_cache[cache_index]), float(vz) * CELL)

func exterior_surface_normal_grid(surface_cache: PackedFloat32Array, cache_index: int, grid_size: int) -> Vector3:
    var left := float(surface_cache[cache_index - 1])
    var right := float(surface_cache[cache_index + 1])
    var back := float(surface_cache[cache_index - grid_size])
    var forward := float(surface_cache[cache_index + grid_size])
    return Vector3(left - right, CELL * 2.0, back - forward).normalized()

func add_exterior_surface_vertex_grid(st: SurfaceTool, point: Vector3, color_cache: Array[Color], normal_cache: Array[Vector3], vx: int, vz: int, grid_size: int) -> void:
    var cache_index := (vz + 1) * grid_size + vx + 1
    st.set_normal(normal_cache[cache_index])
    st.set_color(color_cache[cache_index])
    st.add_vertex(point)

func add_exterior_surface_triangle_grid(
    st: SurfaceTool,
    a: Vector3,
    b: Vector3,
    c: Vector3,
    color_cache: Array[Color],
    normal_cache: Array[Vector3],
    cell_ax: int,
    cell_az: int,
    cell_bx: int,
    cell_bz: int,
    cell_cx: int,
    cell_cz: int,
    grid_size: int,
    origin_cell_x: int,
    origin_cell_z: int,
    check_cave_air := false
) -> void:
    if check_cave_air and exterior_surface_triangle_opens_to_cave_air(a, b, c, origin_cell_x, origin_cell_z):
        return
    add_exterior_surface_vertex_grid(st, a, color_cache, normal_cache, cell_ax, cell_az, grid_size)
    add_exterior_surface_vertex_grid(st, b, color_cache, normal_cache, cell_bx, cell_bz, grid_size)
    add_exterior_surface_vertex_grid(st, c, color_cache, normal_cache, cell_cx, cell_cz, grid_size)

func exterior_surface_vertex_cached(surface_cache: Dictionary, cell_x: int, cell_z: int, origin_cell_x: int, origin_cell_z: int) -> Vector3:
    var key := Vector2i(cell_x, cell_z)
    var y := float(surface_cache[key]) if surface_cache.has(key) else exterior_surface_y_cell(cell_x, cell_z)
    return Vector3((cell_x - origin_cell_x) * CELL, y, (cell_z - origin_cell_z) * CELL)

func add_exterior_surface_vertex(st: SurfaceTool, point: Vector3, color_cache: Dictionary, normal_cache: Dictionary, cell_x: int, cell_z: int) -> void:
    var key := Vector2i(cell_x, cell_z)
    st.set_normal(normal_cache.get(key, Vector3.UP))
    st.set_color(color_cache.get(key, BIOME_COLORS["plains"]))
    st.add_vertex(point)

func add_exterior_surface_triangle(
    st: SurfaceTool,
    a: Vector3,
    b: Vector3,
    c: Vector3,
    color_cache: Dictionary,
    normal_cache: Dictionary,
    cell_a: Vector2i,
    cell_b: Vector2i,
    cell_c: Vector2i,
    origin_cell_x: int,
    origin_cell_z: int,
    check_cave_air := false
) -> void:
    if check_cave_air and exterior_surface_triangle_opens_to_cave_air(a, b, c, origin_cell_x, origin_cell_z):
        return
    add_exterior_surface_vertex(st, a, color_cache, normal_cache, cell_a.x, cell_a.y)
    add_exterior_surface_vertex(st, b, color_cache, normal_cache, cell_b.x, cell_b.y)
    add_exterior_surface_vertex(st, c, color_cache, normal_cache, cell_c.x, cell_c.y)

func exterior_cell_may_touch_cave(cave_features: Array, cell_x: int, cell_z: int) -> bool:
    if cave_features.is_empty():
        return false
    for feature in cave_features:
        if cave_feature_may_touch_mesh_cell(feature, cell_x, cell_z):
            return true
    return false

func exterior_surface_triangle_opens_to_cave_air(a: Vector3, b: Vector3, c: Vector3, origin_cell_x: int, origin_cell_z: int) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_world"):
        return false
    var world_a := Vector3(a.x + float(origin_cell_x) * CELL, a.y, a.z + float(origin_cell_z) * CELL)
    var world_b := Vector3(b.x + float(origin_cell_x) * CELL, b.y, b.z + float(origin_cell_z) * CELL)
    var world_c := Vector3(c.x + float(origin_cell_x) * CELL, c.y, c.z + float(origin_cell_z) * CELL)
    var normal := (world_b - world_a).cross(world_c - world_a)
    if normal.length_squared() <= 0.0001:
        normal = Vector3.UP
    else:
        normal = normal.normalized()
    var center := (world_a + world_b + world_c) / 3.0
    for depth in [CELL * 0.32, CELL * 0.68, CELL * 1.05]:
        var inward_sample := volume_sample_world(center - normal * float(depth))
        if String(inward_sample.get("biome", "")) == "cave" and not bool(inward_sample.get("solid", true)):
            return true
    return false

func exterior_surface_y_cell(cell_x: int, cell_z: int) -> float:
    var edit_key := Vector2i(cell_x, cell_z)
    if volume_edit_markers.has(edit_key):
        return float(volume_edit_markers[edit_key])
    if world_generation_system != null:
        return world_generation_system.surface_y_for_cell(Vector3i(cell_x, 0, cell_z))
    return 0.0

func exterior_surface_color_for_cell(cell_x: int, cell_z: int) -> Color:
    if world_generation_system != null:
        return world_generation_system.surface_color_for_cell3(Vector3i(cell_x, 0, cell_z))
    return BIOME_COLORS.get(surface_biome_at_cell(Vector3i(cell_x, 0, cell_z)), BIOME_COLORS["plains"])

func exterior_surface_normal_cached(surface_cache: Dictionary, cell_x: int, cell_z: int) -> Vector3:
    var left := exterior_surface_y_from_cache(surface_cache, cell_x - 1, cell_z)
    var right := exterior_surface_y_from_cache(surface_cache, cell_x + 1, cell_z)
    var back := exterior_surface_y_from_cache(surface_cache, cell_x, cell_z - 1)
    var forward := exterior_surface_y_from_cache(surface_cache, cell_x, cell_z + 1)
    return Vector3(left - right, CELL * 2.0, back - forward).normalized()

func exterior_surface_y_from_cache(surface_cache: Dictionary, cell_x: int, cell_z: int) -> float:
    var key := Vector2i(cell_x, cell_z)
    return float(surface_cache[key]) if surface_cache.has(key) else exterior_surface_y_cell(cell_x, cell_z)

func chunk_volume_y_bounds(start_x: int, start_z: int) -> Dictionary:
    return chunk_volume_y_bounds_from_features(start_x, start_z, chunk_cave_features(start_x, start_z))

func chunk_volume_y_bounds_from_features(start_x: int, start_z: int, cave_features: Array) -> Dictionary:
    var min_height := INF
    var max_height := -INF
    for z in range(start_z - 2, start_z + CHUNK_SIZE + 3):
        for x in range(start_x - 2, start_x + CHUNK_SIZE + 3):
            var h := chunk_bound_surface_y_at_cell(Vector3i(x, 0, z))
            min_height = minf(min_height, h)
            max_height = maxf(max_height, h)
    if min_height == INF:
        min_height = MIN_HEIGHT
        max_height = MAX_HEIGHT
    var min_bound: float = min_height - CELL * 4.0
    var max_bound: float = max_height + CELL * 3.0
    for feature in cave_features:
        var radius := float(feature.get("radius", CELL * 2.0))
        var chamber_radius := float(feature.get("chamberRadius", radius * 1.8))
        var drop := float(feature.get("drop", CELL * 4.0))
        var entrance_surface := float(feature.get("entranceSurfaceY", min_height))
        var cave_extent := maxf(radius, chamber_radius)
        min_bound = minf(min_bound, entrance_surface - drop - cave_extent * 1.70 - CELL * 2.0)
        max_bound = maxf(max_bound, entrance_surface + cave_extent * 1.20 + CELL * 2.0)
    return {
        "minY": floori(min_bound / CELL),
        "maxY": ceili(max_bound / CELL)
    }

func column_volume_y_bounds(cell_x: int, cell_z: int, chunk_min_y: int, chunk_max_y: int, cave_features: Array) -> Dictionary:
    var surface := chunk_bound_surface_y_at_cell(Vector3i(cell_x, 0, cell_z))
    var min_bound := surface - CELL * 4.0
    var max_bound := surface + CELL * 3.0
    for feature in cave_features:
        if not cave_feature_may_touch_column(feature, cell_x, cell_z):
            continue
        var radius := float(feature.get("radius", CELL * 2.0))
        var chamber_radius := float(feature.get("chamberRadius", radius * 1.8))
        var drop := float(feature.get("drop", CELL * 4.0))
        var entrance_surface := float(feature.get("entranceSurfaceY", surface))
        var cave_extent := maxf(radius, chamber_radius)
        min_bound = minf(min_bound, entrance_surface - drop - cave_extent * 1.70 - CELL * 2.0)
        max_bound = maxf(max_bound, entrance_surface + cave_extent * 1.20 + CELL * 2.0)
    return {
        "minY": clampi(floori(min_bound / CELL), chunk_min_y, chunk_max_y),
        "maxY": clampi(ceili(max_bound / CELL), chunk_min_y, chunk_max_y)
    }

func mesh_cell_volume_y_bounds(cell_x: int, cell_z: int, chunk_min_y: int, chunk_max_y: int, cave_features: Array) -> Dictionary:
    var min_surface := INF
    var max_surface := -INF
    for dz in [0, 1]:
        for dx in [0, 1]:
            var surface := chunk_bound_surface_y_at_cell(Vector3i(cell_x + int(dx), 0, cell_z + int(dz)))
            min_surface = minf(min_surface, surface)
            max_surface = maxf(max_surface, surface)
    if min_surface == INF:
        min_surface = MIN_HEIGHT
        max_surface = MAX_HEIGHT
    var min_bound := min_surface - CELL * 4.0
    var max_bound := max_surface + CELL * 3.0
    for feature in cave_features:
        if not cave_feature_may_touch_mesh_cell(feature, cell_x, cell_z):
            continue
        var radius := float(feature.get("radius", CELL * 2.0))
        var chamber_radius := float(feature.get("chamberRadius", radius * 1.8))
        var drop := float(feature.get("drop", CELL * 4.0))
        var entrance_surface := float(feature.get("entranceSurfaceY", min_surface))
        var cave_extent := maxf(radius, chamber_radius)
        min_bound = minf(min_bound, entrance_surface - drop - cave_extent * 1.70 - CELL * 2.0)
        max_bound = maxf(max_bound, entrance_surface + cave_extent * 1.20 + CELL * 2.0)
    return {
        "minY": clampi(floori(min_bound / CELL) - 1, chunk_min_y, chunk_max_y),
        "maxY": clampi(ceili(max_bound / CELL) + 1, chunk_min_y, chunk_max_y)
    }

func cave_feature_may_touch_mesh_cell(feature: Dictionary, cell_x: int, cell_z: int) -> bool:
    if cave_feature_may_touch_column(feature, cell_x, cell_z):
        return true
    if cave_feature_may_touch_column(feature, cell_x + 1, cell_z):
        return true
    if cave_feature_may_touch_column(feature, cell_x, cell_z + 1):
        return true
    return cave_feature_may_touch_column(feature, cell_x + 1, cell_z + 1)

func chunk_bound_surface_y_at_cell(cell: Vector3i) -> float:
    if world_generation_system != null:
        return world_generation_system.terrain_reference_surface_y_for_cell(cell)
    return surface_y_at_cell(cell)

func chunk_cave_features(start_x: int, start_z: int) -> Array[Dictionary]:
    var features: Array[Dictionary] = []
    if world_generation_system == null or not world_generation_system.has_method("cave_features_near_world"):
        return features
    var seen := {}
    for dz in [-1, 0, 1]:
        for dx in [-1, 0, 1]:
            var sample_cell_x := start_x + CHUNK_SIZE / 2 + int(dx) * CHUNK_SIZE
            var sample_cell_z := start_z + CHUNK_SIZE / 2 + int(dz) * CHUNK_SIZE
            var sample_world := Vector3(float(sample_cell_x) * CELL, 0.0, float(sample_cell_z) * CELL)
            var nearby = world_generation_system.call("cave_features_near_world", sample_world)
            if not (nearby is Array):
                continue
            for feature_value in nearby:
                if not (feature_value is Dictionary):
                    continue
                var feature: Dictionary = feature_value
                var feature_id := String(feature.get("id", ""))
                if feature_id == "" or seen.has(feature_id):
                    continue
                if not cave_feature_may_touch_chunk(feature, start_x, start_z):
                    continue
                seen[feature_id] = true
                features.append(feature)
    return features

func cave_feature_may_touch_chunk(feature: Dictionary, start_x: int, start_z: int) -> bool:
    var entrance_cell: Vector2i = feature.get("entranceCell", Vector2i.ZERO)
    var inward_cell: Vector2i = feature.get("inward", Vector2i(0, 1))
    var right_cell: Vector2i = feature.get("right", Vector2i(1, 0))
    var inward := Vector2(float(inward_cell.x), float(inward_cell.y)).normalized()
    var right := Vector2(float(right_cell.x), float(right_cell.y)).normalized()
    var radius_cells := float(feature.get("radius", CELL * 2.0)) / maxf(0.001, CELL)
    var chamber_cells := float(feature.get("chamberRadius", CELL * 4.0)) / maxf(0.001, CELL)
    var length_cells := float(feature.get("length", CELL * 24.0)) / maxf(0.001, CELL)
    var branch_depth_cells := float(feature.get("branchDepth", CELL * 12.0)) / maxf(0.001, CELL)
    var branch_length_cells := float(feature.get("branchLength", CELL * 10.0)) / maxf(0.001, CELL)
    var branch_side := float(feature.get("branchSide", 1.0))
    var entrance := Vector2(float(entrance_cell.x), float(entrance_cell.y))
    var chamber := entrance + inward * length_cells
    var branch_origin := entrance + inward * branch_depth_cells
    var branch_dir := (inward * 0.34 + right * branch_side).normalized()
    var branch_end := branch_origin + branch_dir * branch_length_cells
    var margin := ceili(maxf(radius_cells, chamber_cells) + 4.0)
    var min_x := floori(minf(entrance.x, minf(chamber.x, minf(branch_origin.x, branch_end.x)))) - margin
    var max_x := ceili(maxf(entrance.x, maxf(chamber.x, maxf(branch_origin.x, branch_end.x)))) + margin
    var min_z := floori(minf(entrance.y, minf(chamber.y, minf(branch_origin.y, branch_end.y)))) - margin
    var max_z := ceili(maxf(entrance.y, maxf(chamber.y, maxf(branch_origin.y, branch_end.y)))) + margin
    var chunk_min_x := start_x - 1
    var chunk_max_x := start_x + CHUNK_SIZE + 1
    var chunk_min_z := start_z - 1
    var chunk_max_z := start_z + CHUNK_SIZE + 1
    return max_x >= chunk_min_x and min_x <= chunk_max_x and max_z >= chunk_min_z and min_z <= chunk_max_z

func cave_feature_may_touch_column(feature: Dictionary, cell_x: int, cell_z: int) -> bool:
    var entrance_cell: Vector2i = feature.get("entranceCell", Vector2i.ZERO)
    var inward_cell: Vector2i = feature.get("inward", Vector2i(0, 1))
    var right_cell: Vector2i = feature.get("right", Vector2i(1, 0))
    var inward := Vector2(float(inward_cell.x), float(inward_cell.y)).normalized()
    var right := Vector2(float(right_cell.x), float(right_cell.y)).normalized()
    var radius_cells := float(feature.get("radius", CELL * 2.0)) / maxf(0.001, CELL)
    var chamber_cells := float(feature.get("chamberRadius", CELL * 4.0)) / maxf(0.001, CELL)
    var length_cells := float(feature.get("length", CELL * 24.0)) / maxf(0.001, CELL)
    var branch_depth_cells := float(feature.get("branchDepth", CELL * 12.0)) / maxf(0.001, CELL)
    var branch_length_cells := float(feature.get("branchLength", CELL * 10.0)) / maxf(0.001, CELL)
    var branch_side := float(feature.get("branchSide", 1.0))
    var entrance := Vector2(float(entrance_cell.x), float(entrance_cell.y))
    var chamber := entrance + inward * length_cells
    var branch_origin := entrance + inward * branch_depth_cells
    var branch_dir := (inward * 0.34 + right * branch_side).normalized()
    var branch_end := branch_origin + branch_dir * branch_length_cells
    var column := Vector2(float(cell_x), float(cell_z))
    var margin := maxf(radius_cells, chamber_cells) + 4.0
    if column.distance_to(chamber) <= chamber_cells + 4.0:
        return true
    if point_segment_distance(column, entrance, chamber) <= margin:
        return true
    return point_segment_distance(column, branch_origin, branch_end) <= margin

func point_segment_distance(point: Vector2, a: Vector2, b: Vector2) -> float:
    var ab := b - a
    var ab_len_sq := ab.length_squared()
    if ab_len_sq <= 0.0001:
        return point.distance_to(a)
    var t := clampf((point - a).dot(ab) / ab_len_sq, 0.0, 1.0)
    return point.distance_to(a + ab * t)

func volume_grid_sample(grid_cell: Vector3i, sample_cache: Dictionary) -> Dictionary:
    if sample_cache.has(grid_cell):
        return sample_cache[grid_cell]
    var position := Vector3(float(grid_cell.x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z) * CELL)
    var sample := {}
    if world_generation_system != null and world_generation_system.has_method("sample_world"):
        sample = world_generation_system.call("sample_world", position)
    elif world_generation_system != null and world_generation_system.has_method("sample_cell"):
        sample = world_generation_system.call("sample_cell", grid_cell)
        sample["position"] = position
    else:
        var surface_y := surface_y_at_cell(Vector3i(grid_cell.x, 0, grid_cell.z))
        var density := surface_y - position.y
        sample = {
            "cell": grid_cell,
            "position": position,
            "solid": density >= 0.0,
            "biome": surface_biome_at_cell(Vector3i(grid_cell.x, 0, grid_cell.z)),
            "material": "air" if density < 0.0 else surface_material_at_cell(Vector3i(grid_cell.x, 0, grid_cell.z)),
            "density": density
        }
    sample_cache[grid_cell] = sample
    return sample

func extract_volume_iso_cube(st: SurfaceTool, base_cell: Vector3i, origin_x: int, origin_z: int, sample_cache: Dictionary) -> void:
    var corners := []
    var solid_count := 0
    for offset in VOLUME_CUBE_CORNER_OFFSETS:
        var grid_cell: Vector3i = base_cell + offset
        var sample := volume_grid_sample(grid_cell, sample_cache)
        var density := float(sample.get("density", 0.0))
        var solid := density > 0.0
        if solid:
            solid_count += 1
        corners.append({
            "grid": grid_cell,
            "local": Vector3(float(grid_cell.x - origin_x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z - origin_z) * CELL),
            "world": Vector3(float(grid_cell.x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z) * CELL),
            "density": density,
            "solid": solid,
            "sample": sample
        })
    if solid_count == 0 or solid_count == corners.size():
        return
    for tet in VOLUME_TETRAHEDRA:
        extract_volume_iso_tetrahedron(st, [
            corners[int(tet[0])],
            corners[int(tet[1])],
            corners[int(tet[2])],
            corners[int(tet[3])]
        ])

func extract_volume_iso_tetrahedron(st: SurfaceTool, tetra: Array) -> void:
    var solid_corners := []
    var air_corners := []
    for corner in tetra:
        if bool(corner.get("solid", false)):
            solid_corners.append(corner)
        else:
            air_corners.append(corner)
    if solid_corners.is_empty() or air_corners.is_empty():
        return
    if not volume_air_corners_need_iso_surface(air_corners):
        return
    if solid_corners.size() == 1:
        var solid: Dictionary = solid_corners[0]
        var desired := average_corner_world(air_corners) - (solid.get("world", Vector3.ZERO) as Vector3)
        add_volume_iso_triangle_oriented(
            st,
            interpolate_volume_iso_edge(solid, air_corners[0]),
            interpolate_volume_iso_edge(solid, air_corners[1]),
            interpolate_volume_iso_edge(solid, air_corners[2]),
            desired
        )
    elif solid_corners.size() == 3:
        var air: Dictionary = air_corners[0]
        var desired := (air.get("world", Vector3.ZERO) as Vector3) - average_corner_world(solid_corners)
        add_volume_iso_triangle_oriented(
            st,
            interpolate_volume_iso_edge(solid_corners[0], air),
            interpolate_volume_iso_edge(solid_corners[1], air),
            interpolate_volume_iso_edge(solid_corners[2], air),
            desired
        )
    elif solid_corners.size() == 2 and air_corners.size() == 2:
        var desired := average_corner_world(air_corners) - average_corner_world(solid_corners)
        var p00 := interpolate_volume_iso_edge(solid_corners[0], air_corners[0])
        var p10 := interpolate_volume_iso_edge(solid_corners[1], air_corners[0])
        var p11 := interpolate_volume_iso_edge(solid_corners[1], air_corners[1])
        var p01 := interpolate_volume_iso_edge(solid_corners[0], air_corners[1])
        add_volume_iso_triangle_oriented(st, p00, p10, p11, desired)
        add_volume_iso_triangle_oriented(st, p00, p11, p01, desired)

func average_corner_world(corners: Array) -> Vector3:
    var total := Vector3.ZERO
    for corner in corners:
        total += corner.get("world", Vector3.ZERO)
    return total / maxf(1.0, float(corners.size()))

func volume_air_corners_need_iso_surface(air_corners: Array) -> bool:
    for corner in air_corners:
        var sample: Dictionary = corner.get("sample", {})
        if String(sample.get("biome", "")) == "cave":
            return true
        var world: Vector3 = corner.get("world", Vector3.ZERO)
        var surface_y := chunk_bound_surface_y_at_cell(Vector3i(world_to_cell(world.x), 0, world_to_cell(world.z)))
        if world.y < surface_y - CELL * 0.35:
            return true
    return false

func interpolate_volume_iso_edge(a: Dictionary, b: Dictionary) -> Dictionary:
    var da := float(a.get("density", 0.0))
    var db := float(b.get("density", 0.0))
    var t := 0.5
    var denominator := da - db
    if absf(denominator) > 0.0001:
        t = clampf(da / denominator, 0.0, 1.0)
    var local: Vector3 = (a.get("local", Vector3.ZERO) as Vector3).lerp(b.get("local", Vector3.ZERO) as Vector3, t)
    var world: Vector3 = (a.get("world", Vector3.ZERO) as Vector3).lerp(b.get("world", Vector3.ZERO) as Vector3, t)
    var a_sample: Dictionary = a.get("sample", {})
    var b_sample: Dictionary = b.get("sample", {})
    var solid_sample := a_sample if bool(a.get("solid", false)) else b_sample
    var air_sample := b_sample if bool(a.get("solid", false)) else a_sample
    return {
        "local": local,
        "world": world,
        "solidSample": solid_sample,
        "airSample": air_sample
    }

func add_volume_iso_triangle_oriented(st: SurfaceTool, a: Dictionary, b: Dictionary, c: Dictionary, desired_normal: Vector3) -> void:
    var a_local: Vector3 = a.get("local", Vector3.ZERO)
    var b_local: Vector3 = b.get("local", Vector3.ZERO)
    var c_local: Vector3 = c.get("local", Vector3.ZERO)
    var cross := (b_local - a_local).cross(c_local - a_local)
    if cross.length_squared() <= 0.000001:
        return
    if desired_normal.length_squared() <= 0.0001:
        desired_normal = cross.normalized()
    else:
        desired_normal = desired_normal.normalized()
    if cross.normalized().dot(desired_normal) < 0.0:
        var swap := b
        b = c
        c = swap
        cross = -cross
    var normal := cross.normalized()
    add_volume_iso_vertex(st, a, normal)
    add_volume_iso_vertex(st, b, normal)
    add_volume_iso_vertex(st, c, normal)

func add_volume_iso_vertex(st: SurfaceTool, point: Dictionary, normal: Vector3) -> void:
    st.set_normal(normal)
    st.set_color(volume_iso_vertex_color(point, normal))
    st.add_vertex(point.get("local", Vector3.ZERO))

func volume_density_at_world(position: Vector3) -> float:
    if world_generation_system != null and world_generation_system.has_method("density_at"):
        return float(world_generation_system.call("density_at", position))
    return surface_y_at_position(position) - position.y

func volume_sample_world(position: Vector3) -> Dictionary:
    if world_generation_system != null and world_generation_system.has_method("sample_world"):
        return world_generation_system.call("sample_world", position)
    var density := volume_density_at_world(position)
    return {
        "cell": Vector3i(world_to_cell(position.x), world_to_cell(position.y), world_to_cell(position.z)),
        "position": position,
        "solid": density >= 0.0,
        "biome": surface_biome_at_cell(Vector3i(world_to_cell(position.x), 0, world_to_cell(position.z))),
        "material": "air" if density < 0.0 else surface_material_at_cell(Vector3i(world_to_cell(position.x), 0, world_to_cell(position.z))),
        "density": density
    }

func volume_iso_vertex_color(point: Dictionary, normal: Vector3) -> Color:
    var solid_sample: Dictionary = point.get("solidSample", {})
    var air_sample: Dictionary = point.get("airSample", {})
    var world: Vector3 = point.get("world", Vector3.ZERO)
    var material_id := String(solid_sample.get("material", "stone"))
    if material_id == "air":
        var inside_sample := volume_sample_world(world - normal * CELL * 0.18)
        material_id = String(inside_sample.get("material", "stone"))
        solid_sample = inside_sample
    var air_biome := String(air_sample.get("biome", ""))
    var biome := String(solid_sample.get("biome", surface_biome_at_cell(Vector3i(world_to_cell(world.x), 0, world_to_cell(world.z)))))
    var shade := 0.88 + hash01("volume-iso-shade:%d,%d,%d" % [roundi(world.x * 9.0), roundi(world.y * 9.0), roundi(world.z * 9.0)]) * 0.16
    if air_biome == "cave":
        if normal.y < -0.35:
            return Color(0.055, 0.060, 0.060) * shade
        if normal.y > 0.35:
            return Color(0.150, 0.158, 0.142) * shade
        return Color(0.170, 0.182, 0.170) * shade
    if normal.y > 0.42 and material_id in ["grass", "sand", "mud", "snow"]:
        return BIOME_COLORS.get(biome, BIOME_COLORS["plains"]) * shade
    match material_id:
        "sand":
            return Color(0.62, 0.57, 0.42) * shade
        "mud":
            return Color(0.30, 0.35, 0.25) * shade
        "snow":
            return Color(0.77, 0.82, 0.82) * shade
        "dirt":
            return Color(0.32, 0.27, 0.18) * shade
        "copperOre":
            return Color(0.48, 0.30, 0.20) * shade
        "ironOre":
            return Color(0.40, 0.39, 0.36) * shade
        _:
            return Color(0.36, 0.38, 0.35) * shade

func spawn_chunk_props(chunk: Node3D, cx: int, cz: int) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = hash_string("%s:props:%d,%d" % [seed_text, cx, cz])
    var start_x := cx * CHUNK_SIZE
    var start_z := cz * CHUNK_SIZE
    for i in range(28):
        var x := start_x + 2 + rng.randi_range(0, CHUNK_SIZE - 4)
        var z := start_z + 2 + rng.randi_range(0, CHUNK_SIZE - 4)
        var prop_id := "%s:%d,%d:%d" % [seed_text, x, z, i]
        if removed_props.has(prop_id):
            continue
        if natural_props_blocked_at_cell(x, z):
            continue
        var h := surface_y_at_cell(Vector3i(x, 0, z))
        if h < WATER_LEVEL + 1.0 or h > 92.0:
            continue
        var biome := surface_biome_at_cell(Vector3i(x, 0, z))
        if biome == "town":
            continue
        var rock_roll := rock_chance(biome, h)
        var tree_roll := tree_chance(biome) if h <= 70.0 else 0.0
        var forage_roll := forage_chance(biome)
        var wildlife_roll := wildlife_chance(biome, h)
        var prop_roll := rng.randf()
        var local_position := Vector3((x - start_x) * CELL, h, (z - start_z) * CELL)
        if prop_roll < rock_roll:
            var ore := ore_for_cell(biome, h, rng)
            if ore != "":
                make_ore_cluster(chunk, prop_id, local_position, ore, rng, 2)
            else:
                make_rock(chunk, prop_id, local_position, rng)
        elif prop_roll < rock_roll + tree_roll:
            make_tree(chunk, prop_id, local_position, biome, rng)
        elif prop_roll < rock_roll + tree_roll + forage_roll:
            make_forage(chunk, prop_id, local_position, biome, rng)
        elif prop_roll < rock_roll + tree_roll + forage_roll + wildlife_roll:
            make_wildlife(chunk, prop_id, local_position, biome, rng)
    spawn_chunk_detail_batches(chunk, cx, cz)

func spawn_chunk_detail_batches(chunk: Node3D, cx: int, cz: int) -> void:
    var density: float = clampf(float(visual_quality.get("decorativeDensity", 0.74)), 0.0, 1.0)
    if density <= 0.01:
        return
    var rng := RandomNumberGenerator.new()
    rng.seed = hash_string("%s:details:%d,%d" % [seed_text, cx, cz])
    var start_x: int = cx * CHUNK_SIZE
    var start_z: int = cz * CHUNK_SIZE
    var attempts: int = maxi(8, int(round(float(visual_quality.get("decorativeDetailCap", 72)) * density)))
    var batches := {}
    for i in range(attempts):
        var x := start_x + 1 + rng.randi_range(0, CHUNK_SIZE - 2)
        var z := start_z + 1 + rng.randi_range(0, CHUNK_SIZE - 2)
        if natural_props_blocked_at_cell(x, z):
            continue
        var h := surface_y_at_cell(Vector3i(x, 0, z))
        if h < WATER_LEVEL - 0.1 or h > 104.0:
            continue
        var biome := surface_biome_at_cell(Vector3i(x, 0, z))
        if biome == "town":
            continue
        var variation := height_variation_cell(x, z, 1)
        if variation > CELL * 1.35:
            continue
        var local_position := Vector3((x - start_x) * CELL + rng.randf_range(-0.42, 0.42), h, (z - start_z) * CELL + rng.randf_range(-0.42, 0.42))
        add_detail_for_biome(batches, local_position, biome, h, rng)
    if batches.is_empty():
        return
    var root := Node3D.new()
    root.name = "DecorBatches"
    root.set_meta("kind", "decor")
    chunk.add_child(root)
    for detail_type_variant in batches.keys():
        var detail_type := String(detail_type_variant)
        var transforms: Array = batches[detail_type_variant]
        if transforms.is_empty():
            continue
        spawn_detail_batch(root, detail_type, transforms)

func natural_props_blocked_at_cell(x: int, z: int) -> bool:
    if structure_system != null and structure_system.has_method("blocks_natural_prop_at_cell"):
        return bool(structure_system.call("blocks_natural_prop_at_cell", x, z))
    return false

func add_detail_for_biome(batches: Dictionary, local_position: Vector3, biome: String, height: float, rng: RandomNumberGenerator) -> void:
    var roll := rng.randf()
    if biome == "ocean":
        if height <= WATER_LEVEL + 0.25 and roll < 0.52:
            append_detail_transform(batches, "reed", local_position + Vector3(0.0, 0.36, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.75, 1.28))
        return
    if biome == "beach":
        if roll < 0.46:
            append_detail_transform(batches, "pebble", local_position + Vector3(0.0, 0.05, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.65, 1.35))
        elif roll < 0.70:
            append_detail_transform(batches, "reed", local_position + Vector3(0.0, 0.34, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.7, 1.15))
        return
    if biome == "snow" or biome == "tundra" or biome == "alpine":
        if roll < 0.56:
            append_detail_transform(batches, "snowClump", local_position + Vector3(0.0, 0.05, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.65, 1.35))
        else:
            append_detail_transform(batches, "pebble", local_position + Vector3(0.0, 0.05, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.55, 1.10))
        return
    if biome == "desert" or biome == "savanna":
        if roll < 0.44:
            append_detail_transform(batches, "scrub", local_position + Vector3(0.0, 0.17, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.65, 1.22))
        else:
            append_detail_transform(batches, "pebble", local_position + Vector3(0.0, 0.05, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.55, 1.28))
        return
    if biome == "swamp":
        if roll < 0.50:
            append_detail_transform(batches, "reed", local_position + Vector3(0.0, 0.36, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.75, 1.30))
        else:
            append_detail_transform(batches, "grass", local_position + Vector3(0.0, 0.19, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.65, 1.15))
        return
    if biome == "forest" or biome == "taiga":
        if roll < 0.34:
            append_detail_transform(batches, "leafLitter", local_position + Vector3(0.0, 0.015, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.70, 1.40))
        elif roll < 0.78:
            append_detail_transform(batches, "grass", local_position + Vector3(0.0, 0.19, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.65, 1.20))
        else:
            append_flower_detail(batches, local_position, rng)
        return
    if roll < 0.62:
        append_detail_transform(batches, "grass", local_position + Vector3(0.0, 0.19, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.62, 1.18))
    elif roll < 0.84:
        append_flower_detail(batches, local_position, rng)
    else:
        append_detail_transform(batches, "pebble", local_position + Vector3(0.0, 0.05, 0.0), rng.randf() * TAU, Vector3.ONE * rng.randf_range(0.5, 0.95))

func append_flower_detail(batches: Dictionary, local_position: Vector3, rng: RandomNumberGenerator) -> void:
    var yaw := rng.randf() * TAU
    var scale := rng.randf_range(0.82, 1.18)
    var offset := Vector3(cos(yaw + PI * 0.5), 0.0, sin(yaw + PI * 0.5)) * 0.08
    append_detail_transform(batches, "flowerStem", local_position + Vector3(0.0, 0.15, 0.0) - offset, yaw, Vector3.ONE * scale)
    append_detail_transform(batches, "flowerBloom", local_position + Vector3(0.0, 0.15, 0.0) + offset, yaw + PI * 0.62, Vector3.ONE * scale)

func append_detail_transform(batches: Dictionary, detail_type: String, origin: Vector3, yaw: float, scale: Vector3) -> void:
    if not batches.has(detail_type):
        batches[detail_type] = []
    var basis := Basis(Vector3.UP, yaw).scaled(scale)
    batches[detail_type].append(Transform3D(basis, origin))

func spawn_detail_batch(parent: Node3D, detail_type: String, transforms: Array) -> void:
    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.use_colors = true
    multimesh.use_custom_data = true
    multimesh.mesh = detail_mesh(detail_type)
    multimesh.instance_count = transforms.size()
    for i in range(transforms.size()):
        var transform: Transform3D = transforms[i]
        multimesh.set_instance_transform(i, transform)
        multimesh.set_instance_color(i, detail_instance_color(detail_type, transform, i))
        multimesh.set_instance_custom_data(i, Color(detail_instance_phase(detail_type, transform, i), 0.0, 0.0, 1.0))
    var instance := MultiMeshInstance3D.new()
    instance.name = "Detail_%s_%d" % [detail_type, transforms.size()]
    instance.multimesh = multimesh
    var override_material := detail_material(detail_type)
    if override_material != null:
        instance.material_override = override_material
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.visibility_range_end = detail_visibility_range(detail_type)
    instance.visibility_range_end_margin = 12.0
    instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
    instance.set_meta("kind", "decor")
    instance.set_meta("detail_type", detail_type)
    instance.set_meta("detail_visibility_end", instance.visibility_range_end)
    parent.add_child(instance)

func detail_material(detail_type: String) -> Material:
    match detail_type:
        "flowerStem", "flowerBloom":
            return null
        "grass":
            return materials["detailGrass"]
        "reed":
            return materials["detailReed"]
        "pebble":
            return materials["detailPebble"]
        "snowClump":
            return materials["detailSnow"]
        "scrub":
            return materials["detailScrub"]
        "leafLitter":
            return materials["detailLeaf"]
    return materials["detailGrass"]

func detail_mesh(detail_type: String) -> Mesh:
    if detail_meshes.has(detail_type):
        return detail_meshes[detail_type]
    var mesh: Mesh
    match detail_type:
        "grass":
            mesh = make_grass_cluster_mesh()
        "flowerStem":
            mesh = make_flower_cluster_mesh(0)
        "flowerBloom":
            mesh = make_flower_cluster_mesh(1)
        "reed":
            mesh = make_reed_cluster_mesh()
        "pebble":
            mesh = make_pebble_cluster_mesh()
        "snowClump":
            mesh = make_snow_clump_mesh()
        "scrub":
            mesh = make_scrub_cluster_mesh()
        "leafLitter":
            mesh = make_leaf_litter_mesh()
        _:
            mesh = make_grass_cluster_mesh()
    detail_meshes[detail_type] = mesh
    return mesh

func detail_visibility_range(detail_type: String) -> float:
    match detail_type:
        "reed", "scrub":
            return 82.0
        "grass", "flowerStem", "flowerBloom":
            return 64.0
        "pebble", "snowClump", "leafLitter":
            return 58.0
    return 64.0

func detail_instance_phase(detail_type: String, transform: Transform3D, index: int) -> float:
    return detail_hash_unit(detail_type, transform.origin, index, 19.71)

func detail_instance_color(detail_type: String, transform: Transform3D, index: int) -> Color:
    var warm := detail_hash_unit(detail_type, transform.origin, index, 3.17)
    var cool := detail_hash_unit(detail_type, transform.origin, index, 9.91)
    var light := detail_hash_unit(detail_type, transform.origin, index, 14.43)
    match detail_type:
        "pebble":
            return Color(0.88 + warm * 0.20, 0.90 + cool * 0.16, 0.86 + light * 0.18, 1.0)
        "snowClump":
            return Color(0.95 + warm * 0.10, 0.98 + cool * 0.08, 1.0 + light * 0.06, 1.0)
        "leafLitter":
            return Color(0.92 + warm * 0.18, 0.82 + cool * 0.14, 0.70 + light * 0.12, 1.0)
        "flowerBloom":
            return Color(1.02 + warm * 0.16, 0.92 + cool * 0.12, 0.86 + light * 0.16, 1.0)
        "reed", "scrub":
            return Color(0.86 + warm * 0.18, 0.94 + cool * 0.16, 0.78 + light * 0.16, 1.0)
    return Color(0.86 + warm * 0.18, 0.96 + cool * 0.18, 0.82 + light * 0.14, 1.0)

func detail_hash_unit(detail_type: String, origin: Vector3, index: int, salt: float) -> float:
    var type_seed := float(abs(hash_string(detail_type)) % 997)
    var value := sin(origin.x * 12.9898 + origin.z * 78.233 + origin.y * 5.913 + float(index) * 37.719 + type_seed + salt) * 43758.5453
    return fposmod(value, 1.0)

func make_grass_cluster_mesh() -> ArrayMesh:
    var st := begin_detail_surface(materials["detailGrass"])
    var blade_data := [
        [Vector3(-0.09, -0.19, -0.05), 0.38, 0.055, 0.10, 0.0],
        [Vector3(0.06, -0.19, 0.02), 0.46, 0.048, -0.08, 1.18],
        [Vector3(0.0, -0.19, -0.10), 0.34, 0.045, 0.06, 2.35],
        [Vector3(0.12, -0.19, -0.04), 0.31, 0.038, -0.04, 3.30],
        [Vector3(-0.02, -0.19, 0.10), 0.42, 0.050, 0.11, 4.28],
        [Vector3(-0.13, -0.19, 0.05), 0.30, 0.040, -0.05, 5.36],
    ]
    for row in blade_data:
        add_detail_blade(st, row[0], float(row[1]), float(row[2]), float(row[4]), float(row[3]))
    return commit_detail_surface(st)

func make_reed_cluster_mesh() -> ArrayMesh:
    var st := begin_detail_surface(materials["detailReed"])
    var reeds := [
        [Vector3(-0.06, -0.36, -0.03), 0.86, 0.032, 0.08, 0.15],
        [Vector3(0.04, -0.36, 0.02), 0.78, 0.026, -0.05, 1.50],
        [Vector3(0.10, -0.36, -0.04), 0.66, 0.024, 0.04, 2.60],
        [Vector3(-0.12, -0.36, 0.05), 0.72, 0.024, -0.08, 3.85],
    ]
    for row in reeds:
        add_detail_stem(st, row[0], float(row[1]), float(row[2]), float(row[4]), float(row[3]))
    add_detail_blade(st, Vector3(0.0, -0.36, 0.08), 0.58, 0.035, 4.8, 0.13)
    return commit_detail_surface(st)

func make_scrub_cluster_mesh() -> ArrayMesh:
    var st := begin_detail_surface(materials["detailScrub"])
    add_detail_blade(st, Vector3(-0.11, -0.17, -0.03), 0.36, 0.055, 0.2, 0.13)
    add_detail_blade(st, Vector3(0.08, -0.17, 0.01), 0.32, 0.048, 1.2, -0.10)
    add_detail_blade(st, Vector3(0.00, -0.17, 0.09), 0.30, 0.046, 2.5, 0.08)
    add_detail_blade(st, Vector3(0.13, -0.17, -0.08), 0.24, 0.040, 3.7, -0.05)
    add_detail_blade(st, Vector3(-0.06, -0.17, 0.04), 0.28, 0.044, 4.7, 0.12)
    return commit_detail_surface(st)

func make_flower_cluster_mesh(variant: int) -> ArrayMesh:
    var mesh := ArrayMesh.new()
    var stem_st := begin_detail_surface(materials["detailGrass"])
    add_detail_stem(stem_st, Vector3(0.0, -0.15, 0.0), 0.31 + float(variant) * 0.03, 0.018, 0.0, 0.018)
    add_detail_blade(stem_st, Vector3(-0.015, -0.08, 0.0), 0.13, 0.032, 2.0 + float(variant) * 0.4, 0.04)
    add_detail_blade(stem_st, Vector3(0.012, -0.07, 0.0), 0.12, 0.030, 4.6 + float(variant) * 0.3, -0.04)
    commit_detail_surface(stem_st, mesh)

    var bloom_st := begin_detail_surface(materials["detailFlower"])
    var center := Vector3(0.0, 0.17 + float(variant) * 0.03, 0.0)
    var petals := 5 + variant
    for i in range(petals):
        var angle := float(i) / float(petals) * TAU
        var petal_center := center + Vector3(cos(angle), 0.0, sin(angle)) * 0.025
        add_vertical_diamond(bloom_st, petal_center, 0.075, 0.042, angle)
    return commit_detail_surface(bloom_st, mesh)

func make_pebble_cluster_mesh() -> ArrayMesh:
    var st := begin_detail_surface(materials["detailPebble"])
    add_detail_octahedron(st, Vector3(-0.08, 0.0, -0.03), Vector3(0.11, 0.06, 0.08))
    add_detail_octahedron(st, Vector3(0.06, -0.005, 0.04), Vector3(0.085, 0.045, 0.065))
    add_detail_octahedron(st, Vector3(0.15, -0.01, -0.03), Vector3(0.055, 0.035, 0.045))
    return commit_detail_surface(st)

func make_snow_clump_mesh() -> ArrayMesh:
    var st := begin_detail_surface(materials["detailSnow"])
    add_detail_octahedron(st, Vector3(-0.07, 0.0, -0.03), Vector3(0.16, 0.055, 0.11))
    add_detail_octahedron(st, Vector3(0.08, -0.005, 0.02), Vector3(0.13, 0.045, 0.10))
    add_detail_octahedron(st, Vector3(0.0, 0.01, 0.10), Vector3(0.09, 0.04, 0.07))
    return commit_detail_surface(st)

func make_leaf_litter_mesh() -> ArrayMesh:
    var st := begin_detail_surface(materials["detailLeaf"])
    add_horizontal_diamond(st, Vector3(-0.08, -0.008, -0.04), 0.22, 0.075, 0.3)
    add_horizontal_diamond(st, Vector3(0.08, -0.006, 0.03), 0.18, 0.065, 1.6)
    add_horizontal_diamond(st, Vector3(0.00, -0.004, 0.10), 0.16, 0.055, 2.7)
    add_horizontal_diamond(st, Vector3(0.13, -0.007, -0.09), 0.14, 0.050, 4.1)
    return commit_detail_surface(st)

func begin_detail_surface(material: Material) -> SurfaceTool:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    st.set_material(material)
    return st

func commit_detail_surface(st: SurfaceTool, mesh: ArrayMesh = null) -> ArrayMesh:
    st.generate_normals()
    return st.commit(mesh)

func add_detail_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, wind_a: float, wind_b: float, wind_c: float) -> void:
    st.set_uv2(Vector2(wind_a, 0.0))
    st.add_vertex(a)
    st.set_uv2(Vector2(wind_b, 0.0))
    st.add_vertex(b)
    st.set_uv2(Vector2(wind_c, 0.0))
    st.add_vertex(c)

func add_detail_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, wind_bottom: float, wind_top: float) -> void:
    add_detail_triangle(st, a, b, c, wind_bottom, wind_top, wind_bottom)
    add_detail_triangle(st, c, b, d, wind_bottom, wind_top, wind_top)

func add_detail_blade(st: SurfaceTool, base: Vector3, height: float, width: float, yaw: float, lean: float) -> void:
    var right := Vector3(cos(yaw), 0.0, sin(yaw)) * width
    var forward := Vector3(-sin(yaw), 0.0, cos(yaw))
    var tip := base + Vector3(0.0, height, 0.0) + forward * lean
    add_detail_triangle(st, base - right, tip, base + right, 0.0, 1.0, 0.0)

func add_detail_stem(st: SurfaceTool, base: Vector3, height: float, width: float, yaw: float, lean: float) -> void:
    var right := Vector3(cos(yaw), 0.0, sin(yaw)) * width
    var forward := Vector3(-sin(yaw), 0.0, cos(yaw))
    var top := base + Vector3(0.0, height, 0.0) + forward * lean
    add_detail_quad(st, base - right, top - right * 0.45, base + right, top + right * 0.45, 0.0, 1.0)

func add_horizontal_diamond(st: SurfaceTool, center: Vector3, length: float, width: float, yaw: float) -> void:
    var forward := Vector3(cos(yaw), 0.0, sin(yaw)) * length * 0.5
    var right := Vector3(-sin(yaw), 0.0, cos(yaw)) * width * 0.5
    add_detail_triangle(st, center - forward, center + right, center + forward, 0.0, 0.0, 0.0)
    add_detail_triangle(st, center - forward, center + forward, center - right, 0.0, 0.0, 0.0)

func add_vertical_diamond(st: SurfaceTool, center: Vector3, height: float, width: float, yaw: float) -> void:
    var right := Vector3(cos(yaw), 0.0, sin(yaw)) * width * 0.5
    var top := center + Vector3(0.0, height * 0.5, 0.0)
    var bottom := center - Vector3(0.0, height * 0.5, 0.0)
    add_detail_triangle(st, bottom, center + right, top, 0.35, 0.65, 1.0)
    add_detail_triangle(st, bottom, top, center - right, 0.35, 1.0, 0.65)

func add_detail_octahedron(st: SurfaceTool, center: Vector3, radius: Vector3) -> void:
    var top := center + Vector3(0.0, radius.y, 0.0)
    var bottom := center - Vector3(0.0, radius.y, 0.0)
    var east := center + Vector3(radius.x, 0.0, 0.0)
    var west := center - Vector3(radius.x, 0.0, 0.0)
    var north := center - Vector3(0.0, 0.0, radius.z)
    var south := center + Vector3(0.0, 0.0, radius.z)
    add_detail_triangle(st, top, north, east, 0.0, 0.0, 0.0)
    add_detail_triangle(st, top, east, south, 0.0, 0.0, 0.0)
    add_detail_triangle(st, top, south, west, 0.0, 0.0, 0.0)
    add_detail_triangle(st, top, west, north, 0.0, 0.0, 0.0)
    add_detail_triangle(st, bottom, east, north, 0.0, 0.0, 0.0)
    add_detail_triangle(st, bottom, south, east, 0.0, 0.0, 0.0)
    add_detail_triangle(st, bottom, west, south, 0.0, 0.0, 0.0)
    add_detail_triangle(st, bottom, north, west, 0.0, 0.0, 0.0)

func tree_visual_spec(biome: String, rng: RandomNumberGenerator) -> Dictionary:
    var spec := {
        "rotation": rng.randf() * TAU,
        "height": 3.0 + rng.randf() * 2.2,
        "clumps": []
    }
    if biome == "taiga" or biome == "snow" or biome == "tundra":
        spec["height"] = float(spec["height"]) + 1.6
    var height := float(spec["height"])
    var clumps := 3 if biome == "taiga" or biome == "snow" or biome == "tundra" else 5
    for c in range(clumps):
        var radius := 0.82 + rng.randf() * 0.35
        var angle := rng.randf() * TAU
        var spread := 0.0 if c == 0 else 0.42 + rng.randf() * 0.55
        var y := height + 0.3 + rng.randf() * 0.65
        var scale := Vector3(
            1.2 + rng.randf() * 0.4,
            0.68 + rng.randf() * 0.22,
            1.2 + rng.randf() * 0.4
        )
        spec["clumps"].append({
            "radius": radius,
            "position": Vector3(cos(angle) * spread, y, sin(angle) * spread),
            "scale": scale
        })
    return spec

func add_tree_visual(body: StaticBody3D, prop_id: String, biome: String, spec: Dictionary) -> void:
    if add_generated_tree_visual(body, prop_id, biome, spec):
        return
    add_fallback_tree_visual(body, spec)

func add_generated_tree_visual(body: StaticBody3D, prop_id: String, biome: String, spec: Dictionary) -> bool:
    if visual_asset_registry == null or not visual_asset_registry.is_ready():
        return false
    var asset_id: String = visual_asset_registry.select_tree_asset_id(biome, prop_id)
    var visual: Node3D = visual_asset_registry.instantiate_asset(asset_id)
    if visual == null:
        return false
    var asset_size: Vector3 = visual_asset_registry.asset_size(asset_id)
    var source_height := maxf(0.1, asset_size.z)
    var target_height := maxf(0.1, float(spec.get("height", source_height)))
    var scale := clampf((target_height / source_height) * visual_asset_registry.tree_scale_for_biome(biome), 0.55, 1.55)
    visual.name = "GeneratedTreeVisual"
    visual.position = Vector3.ZERO
    visual.rotation = Vector3.ZERO
    visual.scale = Vector3.ONE * scale
    visual.set_meta("visual_source", "generated_asset")
    visual.set_meta("visual_asset_id", asset_id)
    body.add_child(visual)
    body.set_meta("visual_source", "generated_asset")
    body.set_meta("visual_asset_id", asset_id)
    return true

func add_fallback_tree_visual(body: StaticBody3D, spec: Dictionary) -> void:
    var height := float(spec.get("height", 4.0))
    var trunk_mesh := CylinderMesh.new()
    trunk_mesh.top_radius = 0.16
    trunk_mesh.bottom_radius = 0.28
    trunk_mesh.height = height
    trunk_mesh.radial_segments = 7
    var trunk := MeshInstance3D.new()
    trunk.name = "PrimitiveTreeTrunk"
    trunk.mesh = trunk_mesh
    trunk.material_override = materials["trunk"]
    trunk.position.y = height * 0.5
    trunk.set_meta("visual_source", "primitive_fallback")
    body.add_child(trunk)

    for leaf_spec in spec.get("clumps", []):
        var leaf_mesh := SphereMesh.new()
        leaf_mesh.radius = float(leaf_spec.get("radius", 0.95))
        leaf_mesh.height = leaf_mesh.radius * 1.25
        var leaf := MeshInstance3D.new()
        leaf.name = "PrimitiveTreeLeaf"
        leaf.mesh = leaf_mesh
        leaf.material_override = materials["leaf"]
        leaf.position = leaf_spec.get("position", Vector3(0.0, height + 0.5, 0.0))
        leaf.scale = leaf_spec.get("scale", Vector3.ONE)
        leaf.set_meta("visual_source", "primitive_fallback")
        body.add_child(leaf)
    body.set_meta("visual_source", "primitive_fallback")
    body.set_meta("visual_asset_id", "")

func make_tree(parent: Node, prop_id: String, position: Vector3, biome: String, rng: RandomNumberGenerator):
    var spec := tree_visual_spec(biome, rng)
    var body := StaticBody3D.new()
    body.name = "Tree"
    body.position = position
    body.rotation.y = float(spec.get("rotation", 0.0))
    body.set_meta("kind", "prop")
    body.set_meta("prop_id", prop_id)
    body.set_meta("drop", "logs")
    body.set_meta("material", "tree")
    body.set_meta("drop_count", 3)
    body.set_meta("visual_biome", biome)

    var height := float(spec.get("height", 4.0))
    add_tree_visual(body, prop_id, biome, spec)

    var trunk_shape := CylinderShape3D.new()
    trunk_shape.radius = 0.36
    trunk_shape.height = height
    var collider := CollisionShape3D.new()
    collider.shape = trunk_shape
    collider.position.y = height * 0.5
    body.add_child(collider)

    parent.add_child(body)
    if npc_system and npc_system.has_method("notify_navigation_prop_created"):
        npc_system.notify_navigation_prop_created(prop_id, body)
    return body

func rock_visual_spec(rng: RandomNumberGenerator) -> Dictionary:
    var rotation := rng.randf() * TAU
    var radius := 0.55 + rng.randf() * 0.7
    var height_factor := 0.75 + rng.randf() * 0.8
    var scale := Vector3(
        1.15 + rng.randf() * 0.6,
        0.58 + rng.randf() * 0.72,
        1.0 + rng.randf() * 0.5
    )
    return {
        "rotation": rotation,
        "radius": radius,
        "height_factor": height_factor,
        "scale": scale
    }

func add_rock_visual(body: StaticBody3D, prop_id: String, biome: String, spec: Dictionary) -> void:
    if add_generated_rock_visual(body, prop_id, biome, spec):
        return
    add_fallback_rock_visual(body, spec)

func add_generated_rock_visual(body: StaticBody3D, prop_id: String, biome: String, spec: Dictionary) -> bool:
    if visual_asset_registry == null or not visual_asset_registry.is_ready():
        return false
    var asset_id: String = visual_asset_registry.select_rock_asset_id(biome, prop_id)
    var visual: Node3D = visual_asset_registry.instantiate_asset(asset_id)
    if visual == null:
        return false
    var radius := float(spec.get("radius", 0.8))
    var height_factor := float(spec.get("height_factor", 1.0))
    var old_scale: Vector3 = spec.get("scale", Vector3.ONE)
    var asset_size: Vector3 = visual_asset_registry.asset_size(asset_id)
    var sx := (radius * 2.0 * old_scale.x) / maxf(0.1, asset_size.x)
    var sy := (radius * height_factor * old_scale.y) / maxf(0.1, asset_size.z)
    var sz := (radius * 2.0 * old_scale.z) / maxf(0.1, asset_size.y)
    var profile_scale: float = visual_asset_registry.rock_scale_for_biome(biome)
    visual.name = "GeneratedRockVisual"
    visual.position = Vector3.ZERO
    visual.rotation = Vector3.ZERO
    visual.scale = Vector3(sx, sy, sz) * profile_scale
    visual.set_meta("visual_source", "generated_asset")
    visual.set_meta("visual_asset_id", asset_id)
    body.add_child(visual)
    body.set_meta("visual_source", "generated_asset")
    body.set_meta("visual_asset_id", asset_id)
    return true

func add_fallback_rock_visual(body: StaticBody3D, spec: Dictionary) -> void:
    var radius := float(spec.get("radius", 0.8))
    var rock_mesh := SphereMesh.new()
    rock_mesh.radius = radius
    rock_mesh.height = radius * float(spec.get("height_factor", 1.0))
    var rock := MeshInstance3D.new()
    rock.name = "PrimitiveRockVisual"
    rock.mesh = rock_mesh
    rock.material_override = materials["rock"]
    rock.position.y = radius * 0.42
    rock.scale = spec.get("scale", Vector3.ONE)
    rock.set_meta("visual_source", "primitive_fallback")
    body.add_child(rock)
    body.set_meta("visual_source", "primitive_fallback")
    body.set_meta("visual_asset_id", "")

func prop_biome_for_position(parent: Node, position: Vector3) -> String:
    var world_position := position
    var parent_node := parent as Node3D
    if parent_node:
        world_position = parent_node.global_transform * position
    return surface_biome_at_cell(Vector3i(world_to_cell(world_position.x), world_to_cell(world_position.y), world_to_cell(world_position.z)))

func make_rock(parent: Node, prop_id: String, position: Vector3, rng: RandomNumberGenerator):
    var spec := rock_visual_spec(rng)
    var biome := prop_biome_for_position(parent, position)
    var body := StaticBody3D.new()
    body.name = "Rock"
    body.position = position
    body.rotation.y = float(spec.get("rotation", 0.0))
    body.set_meta("kind", "prop")
    body.set_meta("prop_id", prop_id)
    body.set_meta("drop", "stones")
    body.set_meta("material", "rock")
    body.set_meta("drop_count", 4)
    body.set_meta("visual_biome", biome)

    var radius := float(spec.get("radius", 0.8))
    add_rock_visual(body, prop_id, biome, spec)

    var shape := SphereShape3D.new()
    shape.radius = radius * 1.05
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.position.y = radius * 0.42
    body.add_child(collider)
    parent.add_child(body)
    if npc_system and npc_system.has_method("notify_navigation_prop_created"):
        npc_system.notify_navigation_prop_created(prop_id, body)
    return body

func make_ore_cluster(parent: Node, prop_id: String, position: Vector3, ore_type: String, rng: RandomNumberGenerator, count: int = 3) -> Array:
    var nodes := []
    var cluster_count: int = clampi(count, 1, 4)
    for i in range(cluster_count):
        var child_id := prop_id if i == 0 else "%s:cluster%d" % [prop_id, i]
        if removed_props.has(child_id):
            continue
        var angle: float = rng.randf() * TAU + float(i) * TAU / float(cluster_count)
        var spacing: float = 0.0 if i == 0 else CELL * (0.60 + rng.randf() * 0.42)
        var offset := Vector3(cos(angle) * spacing, rng.randf() * 0.08, sin(angle) * spacing)
        var node: Node = make_ore(parent, child_id, position + offset, ore_type, rng)
        if node:
            node.set_meta("cluster_size", cluster_count)
            nodes.append(node)
    return nodes
