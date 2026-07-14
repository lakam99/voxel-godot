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
const UNDERGROUND_VOLUME_MESH_STEP_CELLS := 16
const UNDERGROUND_VOLUME_COARSE_STEP_CELLS := 16
const UNDERGROUND_VOLUME_EXTERIOR_LOD_STEP_CELLS := 8
const UNDERGROUND_VOLUME_FINE_FOCUS_STEP_CELLS := 2
const UNDERGROUND_VOLUME_FOCUS_STEP_CELLS := 12
const UNDERGROUND_VOLUME_DEBUG_STEP_CELLS := 16
const UNDERGROUND_VOLUME_FOCUS_RADIUS_CELLS := 9
const UNDERGROUND_VOLUME_DEBUG_RADIUS_CELLS := 84
const UNDERGROUND_VOLUME_SURFACE_EXPOSURE_DEPTH_CELLS := 6
const UNDERGROUND_VOLUME_SURFACE_EXPOSURE_VERTICAL_STEP_CELLS := 2
const UNDERGROUND_VOLUME_Y_PADDING := CELL * 0.85

var full_exterior_indices_cache := PackedInt32Array()
var underground_focus_cache_cell := Vector3i(999999, 999999, 999999)
var underground_focus_cache_revision := -1
var underground_focus_cache_seed := ""
var underground_focus_cache_debug := false
var underground_focus_cache_result := false
var underground_chunk_exposure_cache := {}

func generated_volume_exposure_cache_metadata(start_x: int, start_z: int) -> Dictionary:
    var chunk_key := Vector2i(floori(float(start_x) / float(CHUNK_SIZE)), floori(float(start_z) / float(CHUNK_SIZE)))
    var revision := int(world_generation_system.call("terrain_volume_revision")) if world_generation_system != null and world_generation_system.has_method("terrain_volume_revision") else 0
    return {
        "chunk": chunk_key,
        "revision": revision,
        "seed": seed_text
    }

func cached_generated_surface_volume_exposure(start_x: int, start_z: int) -> Dictionary:
    var metadata := generated_volume_exposure_cache_metadata(start_x, start_z)
    var chunk_key: Vector2i = metadata.get("chunk", Vector2i.ZERO)
    if underground_chunk_exposure_cache.has(chunk_key):
        var cached_value = underground_chunk_exposure_cache[chunk_key]
        if cached_value is Dictionary:
            var cached: Dictionary = cached_value
            if int(cached.get("revision", -1)) == int(metadata.get("revision", -1)) and String(cached.get("seed", "")) == String(metadata.get("seed", "")):
                return {
                    "known": true,
                    "result": bool(cached.get("result", false))
                }
    return {
        "known": false,
        "result": false
    }

func cache_generated_surface_volume_exposure(start_x: int, start_z: int, result: bool) -> void:
    var metadata := generated_volume_exposure_cache_metadata(start_x, start_z)
    var chunk_key: Vector2i = metadata.get("chunk", Vector2i.ZERO)
    underground_chunk_exposure_cache[chunk_key] = {
        "revision": int(metadata.get("revision", 0)),
        "seed": String(metadata.get("seed", "")),
        "result": result
    }

func build_chunk_mesh(cx: int, cz: int) -> Mesh:
    var start_x: int = cx * CHUNK_SIZE
    var start_z: int = cz * CHUNK_SIZE
    var monitor = runtime_perf_monitor
    var volume_scan_start: int = monitor.begin_section("chunk_volume_boundary_scan") if monitor != null else Time.get_ticks_usec()
    var has_excavation := chunk_has_excavation_overlap(start_x, start_z)
    var has_volume_edits := chunk_has_terrain_volume_edits(start_x, start_z)
    var generated_volume_required := chunk_needs_generated_underground_volume_mesh(start_x, start_z)
    var full_generated_volume_required := generated_volume_required and not has_volume_edits
    var local_volume_required := has_excavation or has_volume_edits
    var volume_required := local_volume_required or full_generated_volume_required
    if monitor != null:
        monitor.end_section("chunk_volume_boundary_scan", volume_scan_start)
    if not volume_required:
        var exterior_start_fast: int = monitor.begin_section("chunk_exterior_surface_mesh") if monitor != null else Time.get_ticks_usec()
        var exterior_mesh := build_two_sided_exterior_array_mesh(start_x, start_z)
        if monitor != null:
            monitor.end_section("chunk_exterior_surface_mesh", exterior_start_fast)
        return exterior_mesh
    var mesh := ArrayMesh.new()
    var exterior_start: int = monitor.begin_section("chunk_exterior_surface_mesh") if monitor != null else Time.get_ticks_usec()
    var volume_context := {}
    var exterior_arrays := empty_terrain_surface_arrays() if (full_generated_volume_required and not local_volume_required) or has_volume_edits else build_natural_exterior_arrays(start_x, start_z)
    if monitor != null:
        monitor.end_section("chunk_exterior_surface_mesh", exterior_start)
    var bounds := chunk_volume_y_bounds(start_x, start_z) if full_generated_volume_required or has_volume_edits else excavation_volume_y_bounds_for_chunk(start_x, start_z)
    var min_y := int(bounds.get("minY", floori((MIN_HEIGHT - CELL * 4.0) / CELL))) - 1
    var max_y := int(bounds.get("maxY", ceili((MAX_HEIGHT + CELL * 2.0) / CELL))) + 1
    var volume_arrays := {}
    var volume_start: int = monitor.begin_section("chunk_volume_mesh") if monitor != null else Time.get_ticks_usec()
    if full_generated_volume_required or has_volume_edits:
        volume_arrays = build_volume_iso_arrays(start_x, start_z, min_y, max_y, volume_context)
    else:
        volume_arrays = build_excavation_volume_iso_arrays(start_x, start_z, min_y, max_y, volume_context)
    if monitor != null:
        monitor.increment_counter("chunk_volume_columns", int(volume_arrays.get("columns", 0)))
        monitor.increment_counter("chunk_volume_cubes", int(volume_arrays.get("cubes", 0)))
        monitor.increment_counter("chunk_volume_faces", int(volume_arrays.get("faces", 0)))
        monitor.end_section("chunk_volume_mesh", volume_start)
    var combine_start: int = monitor.begin_section("chunk_combine_surface_arrays") if monitor != null else Time.get_ticks_usec()
    var exterior_vertices: PackedVector3Array = exterior_arrays.get("vertices", PackedVector3Array())
    var combined_arrays := volume_arrays if exterior_vertices.is_empty() else combine_terrain_surface_arrays(exterior_arrays, volume_arrays)
    if monitor != null:
        monitor.end_section("chunk_combine_surface_arrays", combine_start)
    add_terrain_array_surface(mesh, combined_arrays, terrain_material)
    mesh.set_meta("chunk_volume_faces", int(volume_arrays.get("faces", 0)))
    mesh.set_meta("chunk_volume_vertices", (volume_arrays.get("vertices", PackedVector3Array()) as PackedVector3Array).size())
    return mesh

func build_chunk_fluid_mesh(cx: int, cz: int) -> Mesh:
    var mesh := ArrayMesh.new()
    if world_generation_system == null or not world_generation_system.has_method("sample_world"):
        return mesh
    var start_x: int = cx * CHUNK_SIZE
    var start_z: int = cz * CHUNK_SIZE
    var has_excavation := chunk_has_excavation_overlap(start_x, start_z)
    var has_volume_edits := chunk_has_terrain_volume_edits(start_x, start_z)
    var generated_volume_required := chunk_needs_generated_underground_volume_mesh(start_x, start_z)
    var full_generated_volume_required := generated_volume_required and not has_volume_edits
    if not has_excavation and not full_generated_volume_required:
        return mesh
    var bounds := chunk_volume_y_bounds(start_x, start_z) if full_generated_volume_required else excavation_volume_y_bounds_for_chunk(start_x, start_z)
    var min_y := int(bounds.get("minY", floori((MIN_HEIGHT - CELL * 4.0) / CELL))) - 1
    var max_y := int(bounds.get("maxY", ceili((MAX_HEIGHT + CELL * 2.0) / CELL))) + 1
    var sample_cache := {}
    var volume_context := {}
    var step_cells := 1 if bool(get("force_underground_volume_fine_focus")) else maxi(2, mini(4, underground_volume_mesh_step_for_chunk(start_x, start_z)))
    var water_arrays := empty_terrain_surface_arrays()
    var lava_arrays := empty_terrain_surface_arrays()
    var water_faces := 0
    var lava_faces := 0
    for z in range(start_z, start_z + CHUNK_SIZE, step_cells):
        for x in range(start_x, start_x + CHUNK_SIZE, step_cells):
            for y in range(min_y, max_y + 1, step_cells):
                var cell := Vector3i(x, y, z)
                var sample := volume_cell_center_sample(cell, sample_cache, volume_context)
                var fluid_id := String(sample.get("fluid", ""))
                if fluid_id == "" or bool(sample.get("solid", false)):
                    continue
                if fluid_id == "lava":
                    lava_faces += append_fluid_cell_faces(lava_arrays, cell, step_cells, start_x, start_z, sample_cache, volume_context, fluid_id)
                else:
                    water_faces += append_fluid_cell_faces(water_arrays, cell, step_cells, start_x, start_z, sample_cache, volume_context, fluid_id)
    add_terrain_array_surface(mesh, water_arrays, materials.get("water", terrain_material) as Material)
    add_terrain_array_surface(mesh, lava_arrays, materials.get("lava", terrain_material) as Material)
    mesh.set_meta("chunk_fluid_faces", water_faces + lava_faces)
    mesh.set_meta("chunk_water_faces", water_faces)
    mesh.set_meta("chunk_lava_faces", lava_faces)
    var monitor = runtime_perf_monitor
    if monitor != null:
        monitor.increment_counter("chunk_fluid_faces", water_faces + lava_faces)
        monitor.increment_counter("chunk_water_faces", water_faces)
        monitor.increment_counter("chunk_lava_faces", lava_faces)
    return mesh

func append_fluid_cell_faces(
    arrays: Dictionary,
    cell: Vector3i,
    step_cells: int,
    origin_x: int,
    origin_z: int,
    sample_cache: Dictionary,
    volume_context: Dictionary,
    fluid_id: String
) -> int:
    var directions := [
        Vector3i(1, 0, 0),
        Vector3i(-1, 0, 0),
        Vector3i(0, 1, 0),
        Vector3i(0, -1, 0),
        Vector3i(0, 0, 1),
        Vector3i(0, 0, -1)
    ]
    var face_count := 0
    for direction: Vector3i in directions:
        var neighbor_cell := cell + direction * step_cells
        var neighbor_sample := volume_cell_center_sample(neighbor_cell, sample_cache, volume_context)
        if String(neighbor_sample.get("fluid", "")) == fluid_id and not bool(neighbor_sample.get("solid", false)):
            continue
        append_fluid_boundary_face(arrays, cell, direction, step_cells, origin_x, origin_z, fluid_id)
        face_count += 1
    return face_count

func append_fluid_boundary_face(
    arrays: Dictionary,
    cell: Vector3i,
    direction: Vector3i,
    step_cells: int,
    origin_x: int,
    origin_z: int,
    fluid_id: String
) -> void:
    var corners := fluid_boundary_face_corners(cell, direction, step_cells)
    var normal := Vector3(float(direction.x), float(direction.y), float(direction.z)).normalized()
    var color := fluid_vertex_color(fluid_id, corners[0], normal)
    var vertices: PackedVector3Array = arrays.get("vertices", PackedVector3Array())
    var normals: PackedVector3Array = arrays.get("normals", PackedVector3Array())
    var colors: PackedColorArray = arrays.get("colors", PackedColorArray())
    append_density_boundary_triangle(vertices, normals, colors, corners[0], corners[1], corners[2], normal, color, origin_x, origin_z)
    append_density_boundary_triangle(vertices, normals, colors, corners[0], corners[2], corners[3], normal, color, origin_x, origin_z)
    arrays["vertices"] = vertices
    arrays["normals"] = normals
    arrays["colors"] = colors

func fluid_boundary_face_corners(cell: Vector3i, direction: Vector3i, step_cells: int) -> Array[Vector3]:
    var step := maxi(1, step_cells)
    var x0 := float(cell.x) * CELL
    var x1 := float(cell.x + step) * CELL
    var y0 := float(cell.y) * CELL
    var y1 := float(cell.y + step) * CELL
    var z0 := float(cell.z) * CELL
    var z1 := float(cell.z + step) * CELL
    if direction == Vector3i(1, 0, 0):
        return [Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0)]
    if direction == Vector3i(-1, 0, 0):
        return [Vector3(x0, y0, z1), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x0, y1, z1)]
    if direction == Vector3i(0, 1, 0):
        return [Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1)]
    if direction == Vector3i(0, -1, 0):
        return [Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y0, z0)]
    if direction == Vector3i(0, 0, 1):
        return [Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3(x0, y0, z1)]
    return [Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y0, z0)]

func fluid_vertex_color(fluid_id: String, world: Vector3, normal: Vector3) -> Color:
    var shade := 0.88 + noise01(ridge_noise, world_to_cell(world.x) + 917, world_to_cell(world.z) - 613) * 0.10
    if normal.y < -0.35:
        shade *= 0.72
    elif absf(normal.y) < 0.35:
        shade *= 0.84
    if fluid_id == "lava":
        return Color(1.0, 0.34, 0.08, 0.92) * shade
    return Color(0.22, 0.58, 0.68, 0.62) * shade

func empty_terrain_surface_arrays() -> Dictionary:
    return {
        "vertices": PackedVector3Array(),
        "normals": PackedVector3Array(),
        "colors": PackedColorArray(),
        "indices": PackedInt32Array()
    }

func align_down_to_step(value: int, step: int) -> int:
    if step <= 1:
        return value
    return floori(float(value) / float(step)) * step

func align_up_to_step(value: int, step: int) -> int:
    if step <= 1:
        return value
    return ceili(float(value) / float(step)) * step

func chunk_compatible_volume_step(preferred_step: int) -> int:
    var preferred := maxi(1, preferred_step)
    for candidate in [preferred, 14, 7, 4, 2, 1]:
        var step := int(candidate)
        if step > 0 and step <= CHUNK_SIZE and CHUNK_SIZE % step == 0:
            return step
    return 1

func underground_volume_mesh_step_for_chunk(_start_x: int, _start_z: int) -> int:
    if chunk_has_terrain_volume_edits(_start_x, _start_z):
        return 1
    if chunk_has_town_surface_volume_edge(_start_x, _start_z):
        return chunk_compatible_volume_step(4)
    var preferred_step := 8
    if chunk_has_underground_focus_overlap(_start_x, _start_z):
        if bool(get("force_underground_volume_fine_focus")):
            preferred_step = UNDERGROUND_VOLUME_FINE_FOCUS_STEP_CELLS
        elif force_underground_volume_debug:
            preferred_step = UNDERGROUND_VOLUME_DEBUG_STEP_CELLS
        else:
            preferred_step = UNDERGROUND_VOLUME_FOCUS_STEP_CELLS
    return chunk_compatible_volume_step(preferred_step)

func underground_volume_focus_radius_cells() -> int:
    if bool(get("force_underground_volume_fine_focus")):
        return CHUNK_SIZE * 3
    if force_underground_volume_debug:
        return UNDERGROUND_VOLUME_DEBUG_RADIUS_CELLS
    return UNDERGROUND_VOLUME_FOCUS_RADIUS_CELLS

func build_natural_exterior_array_mesh(start_x: int, start_z: int) -> Mesh:
    var monitor = runtime_perf_monitor
    var border_size := CHUNK_SIZE + 3
    var surface_cache := PackedFloat32Array()
    surface_cache.resize(border_size * border_size)
    var surface_context := exterior_surface_chunk_context(start_x, start_z)
    var plain_context := exterior_surface_context_is_plain(surface_context)
    var use_volume_surface_fast_path: bool = (
        plain_context
        and world_generation_system != null
        and world_generation_system.has_method("surface_y_for_cell")
    )
    var height_start: int = monitor.begin_section("chunk_exterior_height_grid") if monitor != null else Time.get_ticks_usec()
    for vz in range(-1, CHUNK_SIZE + 2):
        var row_index := (vz + 1) * border_size
        for vx in range(-1, CHUNK_SIZE + 2):
            var cell_x := start_x + vx
            var cell_z := start_z + vz
            if use_volume_surface_fast_path:
                surface_cache[row_index + vx + 1] = float(world_generation_system.call("surface_y_for_cell", Vector3i(cell_x, 0, cell_z)))
            else:
                surface_cache[row_index + vx + 1] = natural_exterior_surface_y_cell(cell_x, cell_z) if plain_context else exterior_surface_y_cell_from_context(cell_x, cell_z, surface_context)
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
            var color: Color = natural_exterior_surface_color_for_cell(cell_x, cell_z, float(surface_cache[border_index])) if plain_context else exterior_surface_color_for_cell_from_context(cell_x, cell_z, float(surface_cache[border_index]), surface_context)
            var shade := 0.88 + noise01(ridge_noise, cell_x + 400, cell_z - 200) * 0.18
            colors[vertex_index] = color * shade
    if monitor != null:
        monitor.end_section("chunk_exterior_vertex_grid", vertex_start)

    var index_start: int = monitor.begin_section("chunk_exterior_index_grid") if monitor != null else Time.get_ticks_usec()
    var indices := full_exterior_indices()
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

func build_two_sided_exterior_array_mesh(start_x: int, start_z: int) -> Mesh:
    var arrays := build_natural_exterior_arrays(start_x, start_z)
    var vertices: PackedVector3Array = arrays.get("vertices", PackedVector3Array())
    var normals: PackedVector3Array = arrays.get("normals", PackedVector3Array())
    var colors: PackedColorArray = arrays.get("colors", PackedColorArray())
    var indices: PackedInt32Array = arrays.get("indices", PackedInt32Array())
    streaming_append_reversed_indexed_surface(vertices, normals, colors, indices)
    arrays["vertices"] = vertices
    arrays["normals"] = normals
    arrays["colors"] = colors
    arrays["indices"] = indices
    var mesh := ArrayMesh.new()
    add_terrain_array_surface(mesh, arrays, terrain_material)
    mesh.set_meta("terrainMeshingBackend", "two_sided_exterior")
    mesh.set_meta("terrainVisualUndersideClosed", true)
    return mesh

func build_natural_exterior_arrays(start_x: int, start_z: int) -> Dictionary:
    var monitor = runtime_perf_monitor
    var border_size := CHUNK_SIZE + 3
    var surface_cache := PackedFloat32Array()
    surface_cache.resize(border_size * border_size)
    var surface_context := exterior_surface_chunk_context(start_x, start_z)
    var plain_context := exterior_surface_context_is_plain(surface_context)
    var use_volume_surface_fast_path: bool = (
        plain_context
        and world_generation_system != null
        and world_generation_system.has_method("surface_y_for_cell")
    )
    var height_start: int = monitor.begin_section("chunk_exterior_height_grid") if monitor != null else Time.get_ticks_usec()
    for vz in range(-1, CHUNK_SIZE + 2):
        var row_index := (vz + 1) * border_size
        for vx in range(-1, CHUNK_SIZE + 2):
            var cell_x := start_x + vx
            var cell_z := start_z + vz
            if use_volume_surface_fast_path:
                surface_cache[row_index + vx + 1] = float(world_generation_system.call("surface_y_for_cell", Vector3i(cell_x, 0, cell_z)))
            else:
                surface_cache[row_index + vx + 1] = natural_exterior_surface_y_cell(cell_x, cell_z) if plain_context else exterior_surface_y_cell_from_context(cell_x, cell_z, surface_context)
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
            var color: Color = natural_exterior_surface_color_for_cell(cell_x, cell_z, float(surface_cache[border_index])) if plain_context else exterior_surface_color_for_cell_from_context(cell_x, cell_z, float(surface_cache[border_index]), surface_context)
            var shade := 0.88 + noise01(ridge_noise, cell_x + 400, cell_z - 200) * 0.18
            colors[vertex_index] = color * shade
    if monitor != null:
        monitor.end_section("chunk_exterior_vertex_grid", vertex_start)

    var indices := PackedInt32Array()
    var index_start: int = monitor.begin_section("chunk_exterior_index_grid") if monitor != null else Time.get_ticks_usec()
    indices = exterior_indices_for_surface(
        start_x,
        start_z,
        surface_cache,
        border_size,
        active_volume_excavation_brushes(),
        edited_volume_boundary_cells_for_chunk(start_x, start_z, -999999, 999999)
    )
    if monitor != null:
        monitor.end_section("chunk_exterior_index_grid", index_start)
    return {
        "vertices": vertices,
        "normals": normals,
        "colors": colors,
        "indices": indices
    }

func build_natural_exterior_arrays_lod(start_x: int, start_z: int, step_cells: int) -> Dictionary:
    var step := maxi(1, step_cells)
    var local_xs: Array[int] = []
    var local_zs: Array[int] = []
    var local_x := 0
    while local_x < CHUNK_SIZE:
        local_xs.append(local_x)
        local_x += step
    if local_xs.is_empty() or local_xs[local_xs.size() - 1] != CHUNK_SIZE:
        local_xs.append(CHUNK_SIZE)
    var local_z := 0
    while local_z < CHUNK_SIZE:
        local_zs.append(local_z)
        local_z += step
    if local_zs.is_empty() or local_zs[local_zs.size() - 1] != CHUNK_SIZE:
        local_zs.append(CHUNK_SIZE)
    var surface_context := exterior_surface_chunk_context(start_x, start_z)
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var vertex_count := local_xs.size() * local_zs.size()
    vertices.resize(vertex_count)
    normals.resize(vertex_count)
    colors.resize(vertex_count)
    for z_index in range(local_zs.size()):
        var vz: int = local_zs[z_index]
        for x_index in range(local_xs.size()):
            var vx: int = local_xs[x_index]
            var vertex_index := z_index * local_xs.size() + x_index
            var cell_x := start_x + vx
            var cell_z := start_z + vz
            var surface_y := exterior_surface_y_cell_from_context(cell_x, cell_z, surface_context)
            vertices[vertex_index] = Vector3(float(vx) * CELL, surface_y, float(vz) * CELL)
            normals[vertex_index] = exterior_surface_normal_lod(cell_x, cell_z, surface_context, step)
            var color: Color = exterior_surface_color_for_cell_from_context(cell_x, cell_z, surface_y, surface_context)
            var shade := 0.88 + noise01(ridge_noise, cell_x + 400, cell_z - 200) * 0.18
            colors[vertex_index] = color * shade
    var indices := PackedInt32Array()
    for z_index in range(local_zs.size() - 1):
        var row := z_index * local_xs.size()
        var next_row := (z_index + 1) * local_xs.size()
        for x_index in range(local_xs.size() - 1):
            var i00 := row + x_index
            var i10 := i00 + 1
            var i01 := next_row + x_index
            var i11 := i01 + 1
            indices.append(i00)
            indices.append(i01)
            indices.append(i10)
            indices.append(i10)
            indices.append(i01)
            indices.append(i11)
    return {
        "vertices": vertices,
        "normals": normals,
        "colors": colors,
        "indices": indices
    }

func exterior_surface_normal_lod(cell_x: int, cell_z: int, context: Dictionary, step_cells: int) -> Vector3:
    var step := maxi(1, step_cells)
    var left := exterior_surface_y_cell_from_context(cell_x - step, cell_z, context)
    var right := exterior_surface_y_cell_from_context(cell_x + step, cell_z, context)
    var back := exterior_surface_y_cell_from_context(cell_x, cell_z - step, context)
    var forward := exterior_surface_y_cell_from_context(cell_x, cell_z + step, context)
    return Vector3(left - right, CELL * float(step) * 2.0, back - forward).normalized()

func build_volume_iso_arrays(start_x: int, start_z: int, min_y: int, max_y: int, volume_context: Dictionary) -> Dictionary:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var sample_cache := {}
    var volume_columns := 0
    var volume_cubes := 0
    var iso_triangles := 0
    var step_cells := underground_volume_mesh_step_for_chunk(start_x, start_z)
    for z in range(start_z, start_z + CHUNK_SIZE, step_cells):
        for x in range(start_x, start_x + CHUNK_SIZE, step_cells):
            if not volume_block_may_touch_underground_boundary(x, z, step_cells, min_y, max_y, sample_cache, volume_context):
                continue
            var fine_result := append_volume_iso_block_arrays(
                vertices,
                normals,
                colors,
                x,
                z,
                step_cells,
                start_x,
                start_z,
                min_y,
                max_y,
                volume_context,
                sample_cache
            )
            volume_columns += int(fine_result.get("columns", 0))
            volume_cubes += int(fine_result.get("cubes", 0))
            iso_triangles += int(fine_result.get("faces", 0))
    var boundary_faces := append_excavation_boundary_arrays(vertices, normals, colors, start_x, start_z, min_y, max_y, volume_context)
    iso_triangles += boundary_faces
    return {
        "vertices": vertices,
        "normals": normals,
        "colors": colors,
        "columns": volume_columns,
        "cubes": volume_cubes,
        "faces": iso_triangles
    }

func build_excavation_volume_iso_arrays(start_x: int, start_z: int, min_y: int, max_y: int, volume_context: Dictionary) -> Dictionary:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var boundary_faces := append_excavation_boundary_arrays(vertices, normals, colors, start_x, start_z, min_y, max_y, volume_context)
    return {
        "vertices": vertices,
        "normals": normals,
        "colors": colors,
        "columns": 0,
        "cubes": 0,
        "faces": boundary_faces
    }

func append_excavation_boundary_arrays(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    start_x: int,
    start_z: int,
    min_y: int,
    max_y: int,
    volume_context: Dictionary
) -> int:
    var brushes := active_volume_excavation_brushes()
    var iso_triangles := 0
    var iso_sample_cache := {}
    var chunk_min_x := start_x - 1
    var chunk_max_x := start_x + CHUNK_SIZE + 1
    var chunk_min_z := start_z - 1
    var chunk_max_z := start_z + CHUNK_SIZE + 1
    var visited := {}
    for brush_value in brushes:
        if not (brush_value is Dictionary):
            continue
        var brush: Dictionary = brush_value
        var center: Vector3 = brush.get("center", Vector3.ZERO)
        var radius := float(brush.get("radius", 0.0))
        if radius <= 0.0:
            continue
        var center_cell := Vector3i(world_to_cell(center.x), world_to_cell(center.y), world_to_cell(center.z))
        var cell_radius := ceili(radius / CELL) + 2
        for z in range(center_cell.z - cell_radius, center_cell.z + cell_radius + 1):
            if z < chunk_min_z or z > chunk_max_z:
                continue
            for x in range(center_cell.x - cell_radius, center_cell.x + cell_radius + 1):
                if x < chunk_min_x or x > chunk_max_x:
                    continue
                for y in range(maxi(min_y, center_cell.y - cell_radius), mini(max_y, center_cell.y + cell_radius) + 1):
                    var cell := Vector3i(x, y, z)
                    if visited.has(cell):
                        continue
                    var cube_center := Vector3((float(x) + 0.5) * CELL, (float(y) + 0.5) * CELL, (float(z) + 0.5) * CELL)
                    if center.distance_to(cube_center) > radius + CELL * 1.65:
                        continue
                    visited[cell] = true
                    var before_vertices := vertices.size()
                    extract_volume_iso_cube_arrays(
                        vertices,
                        normals,
                        colors,
                        cell,
                        start_x,
                        start_z,
                        iso_sample_cache,
                        volume_context,
                        1
                    )
                    iso_triangles += int((vertices.size() - before_vertices) / 3)
    for edited_cell in edited_volume_boundary_cells_for_chunk(start_x, start_z, min_y, max_y):
        for dz in range(-1, 2):
            for dy in range(-1, 2):
                for dx in range(-1, 2):
                    var edited_cube_cell := edited_cell + Vector3i(dx, dy, dz)
                    if edited_cube_cell.x < chunk_min_x or edited_cube_cell.x > chunk_max_x:
                        continue
                    if edited_cube_cell.z < chunk_min_z or edited_cube_cell.z > chunk_max_z:
                        continue
                    if edited_cube_cell.y < min_y or edited_cube_cell.y > max_y:
                        continue
                    if visited.has(edited_cube_cell):
                        continue
                    visited[edited_cube_cell] = true
                    var edited_before_vertices := vertices.size()
                    extract_volume_iso_cube_arrays(
                        vertices,
                        normals,
                        colors,
                        edited_cube_cell,
                        start_x,
                        start_z,
                        iso_sample_cache,
                        volume_context,
                        1
                    )
                    iso_triangles += int((vertices.size() - edited_before_vertices) / 3)
    return iso_triangles

func append_volume_iso_block_arrays(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    x: int,
    z: int,
    step_cells: int,
    start_x: int,
    start_z: int,
    min_y: int,
    max_y: int,
    volume_context: Dictionary,
    sample_cache: Dictionary
) -> Dictionary:
    var cell_min_y := align_down_to_step(min_y, step_cells)
    var cell_max_y := align_up_to_step(max_y, step_cells)
    if cell_max_y <= cell_min_y:
        return {
            "columns": 0,
            "cubes": 0,
            "faces": 0
        }
    var volume_cubes := 0
    var iso_triangles := 0
    for y in range(cell_min_y, cell_max_y, step_cells):
        volume_cubes += 1
        var before_vertices := vertices.size()
        extract_volume_iso_cube_arrays(
            vertices,
            normals,
            colors,
            Vector3i(x, y, z),
            start_x,
            start_z,
            sample_cache,
            volume_context,
            step_cells
        )
        iso_triangles += int((vertices.size() - before_vertices) / 3)
    return {
        "columns": 1,
        "cubes": volume_cubes,
        "faces": iso_triangles
    }

func volume_block_may_touch_underground_boundary(cell_x: int, cell_z: int, step_cells: int, min_y: int, max_y: int, sample_cache: Dictionary, volume_context := {}) -> bool:
    var step := maxi(1, step_cells)
    for y in range(min_y, max_y, step):
        if volume_cube_has_density_boundary(Vector3i(cell_x, y, cell_z), step, sample_cache, volume_context):
            return true
    return false

func volume_cube_has_density_boundary(origin_cell: Vector3i, step_cells: int, sample_cache: Dictionary, volume_context := {}) -> bool:
    var solid_count := 0
    var surface_ys := PackedFloat32Array()
    var densities := PackedFloat32Array()
    var world_positions: Array[Vector3] = []
    surface_ys.resize(8)
    densities.resize(8)
    world_positions.resize(8)
    for index in range(8):
        var offset: Vector3i = VOLUME_CUBE_CORNER_OFFSETS[index]
        var grid_cell := origin_cell + offset * step_cells
        var sample := volume_grid_sample_numeric(grid_cell, sample_cache, volume_context)
        var density := sample.x
        densities[index] = density
        surface_ys[index] = sample.z
        world_positions[index] = Vector3(float(grid_cell.x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z) * CELL)
        if density > 0.0:
            solid_count += 1
    if solid_count <= 0 or solid_count >= 8:
        return false
    for index in range(8):
        if densities[index] <= 0.0 and world_positions[index].y < surface_ys[index] - CELL * 0.35:
            return true
    return false

func combine_terrain_surface_arrays(exterior_arrays: Dictionary, volume_arrays: Dictionary) -> Dictionary:
    var exterior_vertices: PackedVector3Array = exterior_arrays.get("vertices", PackedVector3Array())
    var exterior_normals: PackedVector3Array = exterior_arrays.get("normals", PackedVector3Array())
    var exterior_colors: PackedColorArray = exterior_arrays.get("colors", PackedColorArray())
    var exterior_indices: PackedInt32Array = exterior_arrays.get("indices", PackedInt32Array())
    var vertices := PackedVector3Array(exterior_vertices)
    var normals := PackedVector3Array(exterior_normals)
    var colors := PackedColorArray(exterior_colors)
    var indices := PackedInt32Array(exterior_indices)
    if indices.is_empty() and not exterior_vertices.is_empty():
        indices.resize(exterior_vertices.size())
        for i in range(exterior_vertices.size()):
            indices[i] = i
    if volume_arrays.is_empty():
        return {
            "vertices": vertices,
            "normals": normals,
            "colors": colors,
            "indices": indices
        }
    var volume_vertices: PackedVector3Array = volume_arrays.get("vertices", PackedVector3Array())
    if volume_vertices.is_empty():
        return {
            "vertices": vertices,
            "normals": normals,
            "colors": colors,
            "indices": indices
        }
    var volume_normals: PackedVector3Array = volume_arrays.get("normals", PackedVector3Array())
    var volume_colors: PackedColorArray = volume_arrays.get("colors", PackedColorArray())
    var volume_offset := vertices.size()
    vertices.append_array(volume_vertices)
    if volume_normals.size() == volume_vertices.size():
        normals.append_array(volume_normals)
    else:
        for i in range(volume_vertices.size()):
            normals.append(Vector3.UP)
    if volume_colors.size() == volume_vertices.size():
        colors.append_array(volume_colors)
    else:
        for i in range(volume_vertices.size()):
            colors.append(Color(0.36, 0.38, 0.35))
    var volume_indices: PackedInt32Array = volume_arrays.get("indices", PackedInt32Array())
    if volume_indices.is_empty():
        for i in range(volume_vertices.size()):
            indices.append(volume_offset + i)
    else:
        for index in volume_indices:
            indices.append(volume_offset + int(index))
    return {
        "vertices": vertices,
        "normals": normals,
        "colors": colors,
        "indices": indices
    }

func full_exterior_indices() -> PackedInt32Array:
    if not full_exterior_indices_cache.is_empty():
        return PackedInt32Array(full_exterior_indices_cache)
    var grid_size := CHUNK_SIZE + 1
    full_exterior_indices_cache.resize(CHUNK_SIZE * CHUNK_SIZE * 6)
    var write_index := 0
    for z in range(CHUNK_SIZE):
        var row := z * grid_size
        var next_row := (z + 1) * grid_size
        for x in range(CHUNK_SIZE):
            var i00 := row + x
            var i10 := i00 + 1
            var i01 := next_row + x
            var i11 := i01 + 1
            full_exterior_indices_cache[write_index] = i00
            full_exterior_indices_cache[write_index + 1] = i01
            full_exterior_indices_cache[write_index + 2] = i10
            full_exterior_indices_cache[write_index + 3] = i10
            full_exterior_indices_cache[write_index + 4] = i01
            full_exterior_indices_cache[write_index + 5] = i11
            write_index += 6
    return PackedInt32Array(full_exterior_indices_cache)

func exterior_indices_for_surface(start_x: int, start_z: int, surface_cache: PackedFloat32Array, border_size: int, brushes: Array, edited_cells: Array[Vector3i] = []) -> PackedInt32Array:
    if brushes.is_empty() and edited_cells.is_empty():
        return full_exterior_indices()
    var grid_size := CHUNK_SIZE + 1
    var indices := PackedInt32Array()
    for z in range(CHUNK_SIZE):
        var row := z * grid_size
        var next_row := (z + 1) * grid_size
        for x in range(CHUNK_SIZE):
            if exterior_surface_quad_cut_by_excavation(start_x, start_z, x, z, surface_cache, border_size, brushes, edited_cells):
                continue
            var i00 := row + x
            var i10 := i00 + 1
            var i01 := next_row + x
            var i11 := i01 + 1
            indices.append(i00)
            indices.append(i01)
            indices.append(i10)
            indices.append(i10)
            indices.append(i01)
            indices.append(i11)
    return indices

func exterior_surface_quad_cut_by_excavation(start_x: int, start_z: int, local_x: int, local_z: int, surface_cache: PackedFloat32Array, border_size: int, brushes: Array, edited_cells: Array[Vector3i] = []) -> bool:
    var cell_x := start_x + local_x
    var cell_z := start_z + local_z
    var center_x := (float(cell_x) + 0.5) * CELL
    var center_z := (float(cell_z) + 0.5) * CELL
    var surface_y := exterior_surface_quad_average_y(surface_cache, local_x, local_z, border_size)
    for brush_value in brushes:
        if not (brush_value is Dictionary):
            continue
        var brush: Dictionary = brush_value
        var brush_center: Vector3 = brush.get("center", Vector3.ZERO)
        var brush_radius := float(brush.get("radius", 0.0))
        if brush_radius <= 0.0:
            continue
        var horizontal_distance := Vector2(brush_center.x - center_x, brush_center.z - center_z).length()
        if horizontal_distance > brush_radius + CELL * 0.35:
            continue
        if absf(brush_center.y - surface_y) > brush_radius + CELL * 0.95:
            continue
        return true
    if exterior_surface_quad_has_surface_deformation(center_x, center_z, surface_y):
        return false
    if exterior_surface_quad_has_volume_surface_projection_edit(start_x, start_z, local_x, local_z):
        return false
    for edited_cell in edited_cells:
        var edit_center_x := (float(edited_cell.x) + 0.5) * CELL
        var edit_center_z := (float(edited_cell.z) + 0.5) * CELL
        if Vector2(edit_center_x - center_x, edit_center_z - center_z).length() > CELL * 1.85:
            continue
        var edit_center_y := (float(edited_cell.y) + 0.5) * CELL
        if absf(edit_center_y - surface_y) > CELL * 2.75:
            continue
        return true
    return false

func exterior_surface_quad_has_volume_surface_projection_edit(start_x: int, start_z: int, local_x: int, local_z: int) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("terrain_volume_column_has_surface_projection_affecting_edits"):
        return false
    for dz in range(2):
        for dx in range(2):
            var column_cell := Vector3i(start_x + local_x + dx, 0, start_z + local_z + dz)
            if bool(world_generation_system.call("terrain_volume_column_has_surface_projection_affecting_edits", column_cell)):
                return true
    return false

func exterior_surface_quad_has_surface_deformation(center_x: float, center_z: float, surface_y: float) -> bool:
    if world_generation_system == null:
        return false
    var brush_values = world_generation_system.get("excavation_brushes")
    if not (brush_values is Array):
        return false
    for brush_value in brush_values:
        if not (brush_value is Dictionary):
            continue
        var brush: Dictionary = brush_value
        if not excavation_brush_is_surface_deformation(brush):
            continue
        var brush_center: Vector3 = brush.get("center", Vector3.ZERO)
        var radius := float(brush.get("deformRadius", brush.get("radius", 0.0)))
        if radius <= 0.0:
            continue
        if Vector2(brush_center.x - center_x, brush_center.z - center_z).length() > radius + CELL * 0.35:
            continue
        if absf(float(brush.get("surfaceY", brush_center.y)) - surface_y) > radius + CELL:
            continue
        return true
    return false

func exterior_surface_quad_average_y(surface_cache: PackedFloat32Array, local_x: int, local_z: int, border_size: int) -> float:
    var i00 := (local_z + 1) * border_size + local_x + 1
    var i10 := i00 + 1
    var i01 := i00 + border_size
    var i11 := i01 + 1
    return (float(surface_cache[i00]) + float(surface_cache[i10]) + float(surface_cache[i01]) + float(surface_cache[i11])) * 0.25

func append_density_boundary_faces_for_cell(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    cell: Vector3i,
    origin_x: int,
    origin_z: int,
    sample_cache: Dictionary,
    volume_context: Dictionary
) -> int:
    var air_sample := volume_cell_center_sample(cell, sample_cache, volume_context)
    if not volume_sample_is_subtracted_air(air_sample):
        return 0
    var face_count := 0
    var directions := [
        Vector3i(1, 0, 0),
        Vector3i(-1, 0, 0),
        Vector3i(0, 1, 0),
        Vector3i(0, -1, 0),
        Vector3i(0, 0, 1),
        Vector3i(0, 0, -1)
    ]
    for direction in directions:
        var neighbor_cell: Vector3i = cell + direction
        var solid_sample := volume_cell_center_sample(neighbor_cell, sample_cache, volume_context)
        if float(solid_sample.get("density", 0.0)) < 0.0:
            continue
        append_density_boundary_face(vertices, normals, colors, cell, direction, origin_x, origin_z, air_sample, solid_sample, volume_context)
        face_count += 1
    return face_count

func volume_cell_center_sample(cell: Vector3i, sample_cache: Dictionary, volume_context: Dictionary) -> Dictionary:
    if sample_cache.has(cell):
        return sample_cache[cell]
    var position := Vector3((float(cell.x) + 0.5) * CELL, (float(cell.y) + 0.5) * CELL, (float(cell.z) + 0.5) * CELL)
    var sample := volume_sample_from_context(position, cell, volume_context) if not volume_context.is_empty() else volume_sample_world(position)
    sample_cache[cell] = sample
    return sample

func volume_sample_is_subtracted_air(sample: Dictionary) -> bool:
    if float(sample.get("density", 0.0)) >= 0.0:
        return false
    if String(sample.get("biome", "")) == "underground_air":
        return true
    var position: Vector3 = sample.get("position", Vector3.ZERO)
    var surface_y := float(sample.get("surfaceY", position.y))
    return position.y < surface_y - CELL * 0.20

func append_density_boundary_face(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    cell: Vector3i,
    direction: Vector3i,
    origin_x: int,
    origin_z: int,
    air_sample: Dictionary,
    solid_sample: Dictionary,
    volume_context: Dictionary
) -> void:
    var corners := density_boundary_face_corners(cell, direction)
    var normal := Vector3(-float(direction.x), -float(direction.y), -float(direction.z)).normalized()
    var color := volume_boundary_face_color(corners[0], air_sample, solid_sample, normal, volume_context)
    append_density_boundary_triangle(vertices, normals, colors, corners[0], corners[1], corners[2], normal, color, origin_x, origin_z)
    append_density_boundary_triangle(vertices, normals, colors, corners[0], corners[2], corners[3], normal, color, origin_x, origin_z)

func density_boundary_face_corners(cell: Vector3i, direction: Vector3i) -> Array[Vector3]:
    var x0 := float(cell.x) * CELL
    var x1 := float(cell.x + 1) * CELL
    var y0 := float(cell.y) * CELL
    var y1 := float(cell.y + 1) * CELL
    var z0 := float(cell.z) * CELL
    var z1 := float(cell.z + 1) * CELL
    if direction == Vector3i(1, 0, 0):
        return [Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1)]
    if direction == Vector3i(-1, 0, 0):
        return [Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3(x0, y0, z0)]
    if direction == Vector3i(0, 1, 0):
        return [Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0), Vector3(x0, y1, z0)]
    if direction == Vector3i(0, -1, 0):
        return [Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1)]
    if direction == Vector3i(0, 0, 1):
        return [Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3(x0, y0, z1)]
    return [Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y0, z0)]

func append_density_boundary_triangle(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    a_world: Vector3,
    b_world: Vector3,
    c_world: Vector3,
    normal: Vector3,
    color: Color,
    origin_x: int,
    origin_z: int
) -> void:
    var a_local := Vector3(a_world.x - float(origin_x) * CELL, a_world.y, a_world.z - float(origin_z) * CELL)
    var b_local := Vector3(b_world.x - float(origin_x) * CELL, b_world.y, b_world.z - float(origin_z) * CELL)
    var c_local := Vector3(c_world.x - float(origin_x) * CELL, c_world.y, c_world.z - float(origin_z) * CELL)
    var cross := (b_local - a_local).cross(c_local - a_local)
    if cross.length_squared() <= 0.000001:
        return
    if cross.normalized().dot(normal) < 0.0:
        var swap := b_local
        b_local = c_local
        c_local = swap
    vertices.append(a_local)
    vertices.append(b_local)
    vertices.append(c_local)
    normals.append(normal)
    normals.append(normal)
    normals.append(normal)
    colors.append(color)
    colors.append(color)
    colors.append(color)

func volume_boundary_face_color(world: Vector3, air_sample: Dictionary, solid_sample: Dictionary, normal: Vector3, volume_context: Dictionary) -> Color:
    var shade := volume_iso_shade(world)
    if String(air_sample.get("biome", "")) == "underground_air":
        shade *= underground_wall_visual_shade(world)
        var underground_material := String(solid_sample.get("material", "stone"))
        var underground_biome := String(solid_sample.get("biome", "underground"))
        return volume_material_surface_color(underground_material, underground_biome, normal, shade, true)
    var solid_cell: Vector3i = solid_sample.get("cell", Vector3i(world_to_cell(world.x), world_to_cell(world.y), world_to_cell(world.z)))
    var surface_y := float(solid_sample.get("surfaceY", volume_context_surface_y_at_cell(solid_cell.x, solid_cell.z, volume_context) if not volume_context.is_empty() else chunk_bound_surface_y_at_cell(Vector3i(solid_cell.x, 0, solid_cell.z))))
    var density := float(solid_sample.get("density", surface_y - world.y))
    var biome := volume_context_surface_biome_at_cell(solid_cell.x, solid_cell.z, volume_context) if not volume_context.is_empty() else surface_biome_at_cell(Vector3i(solid_cell.x, 0, solid_cell.z))
    var material_id := volume_material_from_components(world, solid_cell, density, surface_y, biome)
    return volume_material_surface_color(material_id, biome, normal, shade, false)

func volume_material_surface_color(material_id: String, biome: String, normal: Vector3, shade: float, underground: bool) -> Color:
    if underground:
        if normal.y < -0.35:
            return Color(0.045, 0.047, 0.045) * shade
        if normal.y > 0.35:
            return Color(0.120, 0.125, 0.112) * shade
        if material_id == "copperOre":
            return Color(0.34, 0.20, 0.13) * shade
        if material_id == "ironOre":
            return Color(0.30, 0.30, 0.27) * shade
        if material_id == "bedrock":
            return Color(0.070, 0.075, 0.075) * shade
        if material_id == "deepStone":
            return Color(0.130, 0.145, 0.140) * shade
        if material_id == "sand":
            return Color(0.135, 0.120, 0.085) * shade
        if material_id == "dirt":
            return Color(0.100, 0.080, 0.060) * shade
        return Color(0.125, 0.135, 0.125) * shade
    if normal.y > 0.42 and material_id in ["grass", "mud", "snow"]:
        return BIOME_COLORS.get(biome, BIOME_COLORS["plains"]) * shade
    match material_id:
        "sand":
            return Color(0.76, 0.67, 0.42) * shade
        "mud":
            return Color(0.28, 0.39, 0.22) * shade
        "snow":
            return Color(0.77, 0.82, 0.82) * shade
        "dirt":
            return Color(0.43, 0.27, 0.15) * shade
        "bedrock":
            return Color(0.10, 0.11, 0.11) * shade
        "deepStone":
            return Color(0.22, 0.23, 0.21) * shade
        "copperOre":
            return Color(0.48, 0.30, 0.20) * shade
        "ironOre":
            return Color(0.38, 0.35, 0.31) * shade
        _:
            return Color(0.34, 0.35, 0.31) * shade

func add_terrain_array_surface(mesh: ArrayMesh, surface_data: Dictionary, material: Material = null) -> void:
    var vertices: PackedVector3Array = surface_data.get("vertices", PackedVector3Array())
    if vertices.is_empty():
        return
    var monitor = runtime_perf_monitor
    var pack_start: int = monitor.begin_section("chunk_surface_array_pack") if monitor != null else Time.get_ticks_usec()
    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = surface_data.get("normals", PackedVector3Array())
    arrays[Mesh.ARRAY_COLOR] = surface_data.get("colors", PackedColorArray())
    var indices: PackedInt32Array = surface_data.get("indices", PackedInt32Array())
    if not indices.is_empty():
        arrays[Mesh.ARRAY_INDEX] = indices
    if monitor != null:
        monitor.end_section("chunk_surface_array_pack", pack_start)
    var commit_start: int = monitor.begin_section("chunk_mesh_commit") if monitor != null else Time.get_ticks_usec()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(mesh.get_surface_count() - 1, material if material != null else terrain_material)
    if monitor != null:
        monitor.end_section("chunk_mesh_commit", commit_start)

func add_natural_exterior_surface(st: SurfaceTool, start_x: int, start_z: int) -> void:
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
            add_exterior_surface_triangle_grid(st, p00, p01, p10, color_cache, normal_cache, x, z, x, z + 1, x + 1, z, grid_size)
            add_exterior_surface_triangle_grid(st, p10, p01, p11, color_cache, normal_cache, x + 1, z, x, z + 1, x + 1, z + 1, grid_size)

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
    grid_size: int
) -> void:
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
    cell_c: Vector2i
) -> void:
    add_exterior_surface_vertex(st, a, color_cache, normal_cache, cell_a.x, cell_a.y)
    add_exterior_surface_vertex(st, b, color_cache, normal_cache, cell_b.x, cell_b.y)
    add_exterior_surface_vertex(st, c, color_cache, normal_cache, cell_c.x, cell_c.y)

func exterior_surface_y_cell(cell_x: int, cell_z: int) -> float:
    var edit_key := Vector2i(cell_x, cell_z)
    if volume_edit_markers.has(edit_key):
        return float(volume_edit_markers[edit_key])
    if world_generation_system != null:
        return float(world_generation_system.surface_y_for_cell(Vector3i(cell_x, 0, cell_z)))
    return 0.0

func exterior_surface_chunk_context(start_x: int, start_z: int) -> Dictionary:
    var context := {
        "towns": [],
        "hasSurfaceDeformation": world_generation_system != null and world_generation_system.has_method("has_surface_deformation") and bool(world_generation_system.call("has_surface_deformation"))
    }
    if world_generation_system == null or not world_generation_system.has_method("town_slope_apron_cells"):
        return context
    var min_x := start_x - 1
    var max_x := start_x + CHUNK_SIZE + 1
    var min_z := start_z - 1
    var max_z := start_z + CHUNK_SIZE + 1
    var region_min_x := floori(float(min_x) / float(TOWN_REGION_CELLS)) - 1
    var region_max_x := floori(float(max_x) / float(TOWN_REGION_CELLS)) + 1
    var region_min_z := floori(float(min_z) / float(TOWN_REGION_CELLS)) - 1
    var region_max_z := floori(float(max_z) / float(TOWN_REGION_CELLS)) + 1
    var towns: Array[Dictionary] = []
    for rz in range(region_min_z, region_max_z + 1):
        for rx in range(region_min_x, region_max_x + 1):
            var town: Dictionary = town_region(rx, rz)
            if town.is_empty():
                continue
            var center_x := float(town.get("centerX", 0))
            var center_z := float(town.get("centerZ", 0))
            var radius := float(town.get("radius", TOWN_RADIUS_CELLS))
            var apron := float(world_generation_system.call("town_slope_apron_cells", town))
            var influence_radius := radius + apron
            var nearest_x := clampf(center_x, float(min_x), float(max_x))
            var nearest_z := clampf(center_z, float(min_z), float(max_z))
            var distance := Vector2(center_x - nearest_x, center_z - nearest_z).length()
            if distance > influence_radius + 1.0:
                continue
            towns.append({
                "centerX": center_x,
                "centerZ": center_z,
                "radius": radius,
                "apron": apron,
                "level": float(town.get("level", float(WATER_LEVEL) + 3.0))
            })
    context["towns"] = towns
    return context

func exterior_surface_context_is_plain(context: Dictionary) -> bool:
    if not volume_edit_markers.is_empty():
        return false
    if bool(context.get("hasSurfaceDeformation", false)):
        return false
    var towns_value = context.get("towns", [])
    return (towns_value is Array and (towns_value as Array).is_empty()) or not (towns_value is Array)

func exterior_surface_y_cell_from_context(cell_x: int, cell_z: int, context: Dictionary) -> float:
    var edit_key := Vector2i(cell_x, cell_z)
    if volume_edit_markers.has(edit_key):
        return float(volume_edit_markers[edit_key])
    if bool(context.get("hasSurfaceDeformation", false)) and world_generation_system != null and world_generation_system.has_method("surface_y_for_cell"):
        return float(world_generation_system.surface_y_for_cell(Vector3i(cell_x, 0, cell_z)))
    var towns_value = context.get("towns", [])
    var towns: Array = towns_value if towns_value is Array else []
    var best_town := {}
    var best_distance := INF
    for town_value in towns:
        if not (town_value is Dictionary):
            continue
        var town: Dictionary = town_value
        var center_x := float(town.get("centerX", 0.0))
        var center_z := float(town.get("centerZ", 0.0))
        var distance := Vector2(float(cell_x) - center_x, float(cell_z) - center_z).length()
        var max_distance := float(town.get("radius", TOWN_RADIUS_CELLS)) + float(town.get("apron", 18.0))
        if distance <= max_distance and distance < best_distance:
            best_town = town
            best_distance = distance
    if best_town.is_empty():
        return natural_exterior_surface_y_cell(cell_x, cell_z)
    var radius := float(best_town.get("radius", TOWN_RADIUS_CELLS))
    var level := float(best_town.get("level", float(WATER_LEVEL) + 3.0))
    if best_distance <= radius:
        return level
    var apron := float(best_town.get("apron", 18.0))
    var delta := Vector2(float(cell_x) - float(best_town.get("centerX", 0.0)), float(cell_z) - float(best_town.get("centerZ", 0.0)))
    var natural := natural_exterior_surface_y_cell(cell_x, cell_z)
    if delta.length() > 0.001:
        var direction := delta.normalized()
        var sample_distance := radius + apron
        var sample_x := int(round(float(best_town.get("centerX", 0.0)) + direction.x * sample_distance))
        var sample_z := int(round(float(best_town.get("centerZ", 0.0)) + direction.y * sample_distance))
        natural = natural_exterior_surface_y_cell(sample_x, sample_z)
    var blend := clampf((best_distance - radius) / maxf(1.0, apron), 0.0, 1.0)
    var eased := blend * blend * (3.0 - 2.0 * blend)
    return lerp(level, natural, eased)

func natural_exterior_surface_y_cell(cell_x: int, cell_z: int) -> float:
    if world_generation_system != null:
        if world_generation_system.has_method("surface_y_for_cell"):
            return float(world_generation_system.surface_y_for_cell(Vector3i(cell_x, 0, cell_z)))
    return 0.0

func exterior_surface_color_for_cell(cell_x: int, cell_z: int) -> Color:
    if world_generation_system != null:
        return world_generation_system.surface_color_for_cell3(Vector3i(cell_x, 0, cell_z))
    return BIOME_COLORS.get(surface_biome_at_cell(Vector3i(cell_x, 0, cell_z)), BIOME_COLORS["plains"])

func exterior_surface_color_for_cell_from_context(cell_x: int, cell_z: int, surface_y: float, context: Dictionary) -> Color:
    if exterior_surface_context_contains_town_cell(cell_x, cell_z, context):
        return Color(0.43, 0.53, 0.32)
    return natural_exterior_surface_color_for_cell(cell_x, cell_z, surface_y)

func natural_exterior_surface_color_for_cell(cell_x: int, cell_z: int, surface_y: float) -> Color:
    var moisture: float = noise01(moisture_noise, cell_x - 1200, cell_z + 800)
    var temp: float = clampf(0.42 + noise01(temp_noise, cell_x + 1500, cell_z - 900) * 0.46 - abs(cell_z) / 1300.0 - maxf(0.0, surface_y - 38.0) / 180.0, 0.0, 1.0)
    if surface_y < float(WATER_LEVEL) + 1.7:
        return Color(0.76, 0.67, 0.42)
    if surface_y > 78.0:
        return Color(0.77, 0.82, 0.82)
    if surface_y > 56.0:
        return Color(0.34, 0.35, 0.31)
    if surface_y > 42.0 and moisture < 0.5:
        return Color(0.34, 0.35, 0.31)
    if moisture > 0.78 and surface_y < float(WATER_LEVEL) + 6.0:
        return Color(0.28, 0.39, 0.22)
    if temp > 0.68 and moisture < 0.32:
        return Color(0.76, 0.67, 0.42)
    if temp > 0.61 and moisture < 0.48:
        return Color(0.55, 0.58, 0.29)
    if moisture > 0.64:
        return Color(0.34, 0.53, 0.29)
    return Color(0.43, 0.62, 0.32)

func exterior_surface_context_contains_town_cell(cell_x: int, cell_z: int, context: Dictionary) -> bool:
    var towns_value = context.get("towns", [])
    var towns: Array = towns_value if towns_value is Array else []
    for town_value in towns:
        if not (town_value is Dictionary):
            continue
        var town: Dictionary = town_value
        var center_x := float(town.get("centerX", 0.0))
        var center_z := float(town.get("centerZ", 0.0))
        var radius := float(town.get("radius", TOWN_RADIUS_CELLS))
        if Vector2(float(cell_x) - center_x, float(cell_z) - center_z).length() <= radius:
            return true
    return false

func exterior_surface_normal_cached(surface_cache: Dictionary, cell_x: int, cell_z: int) -> Vector3:
    var left := exterior_surface_y_from_cache(surface_cache, cell_x - 1, cell_z)
    var right := exterior_surface_y_from_cache(surface_cache, cell_x + 1, cell_z)
    var back := exterior_surface_y_from_cache(surface_cache, cell_x, cell_z - 1)
    var forward := exterior_surface_y_from_cache(surface_cache, cell_x, cell_z + 1)
    return Vector3(left - right, CELL * 2.0, back - forward).normalized()

func exterior_surface_normal_for_cell(cell_x: int, cell_z: int) -> Vector3:
    var left := natural_exterior_surface_y_cell(cell_x - 1, cell_z)
    var right := natural_exterior_surface_y_cell(cell_x + 1, cell_z)
    var back := natural_exterior_surface_y_cell(cell_x, cell_z - 1)
    var forward := natural_exterior_surface_y_cell(cell_x, cell_z + 1)
    return Vector3(left - right, CELL * 2.0, back - forward).normalized()

func chunk_has_town_surface_volume_edge(start_x: int, start_z: int) -> bool:
    var context := exterior_surface_chunk_context(start_x, start_z)
    var towns_value = context.get("towns", [])
    if not (towns_value is Array) or (towns_value as Array).is_empty():
        return false
    var step := 4
    var edge_threshold := CELL * 0.65
    var slope_threshold := CELL * 1.25
    var offsets: Array[Vector2i] = [Vector2i(step, 0), Vector2i(0, step)]
    for local_z in range(-step, CHUNK_SIZE + step + 1, step):
        for local_x in range(-step, CHUNK_SIZE + step + 1, step):
            var cell_x := start_x + local_x
            var cell_z := start_z + local_z
            var in_town := exterior_surface_context_contains_town_cell(cell_x, cell_z, context)
            var surface_y := exterior_surface_y_cell_from_context(cell_x, cell_z, context)
            for offset in offsets:
                var neighbor_x := cell_x + offset.x
                var neighbor_z := cell_z + offset.y
                var neighbor_in_town := exterior_surface_context_contains_town_cell(neighbor_x, neighbor_z, context)
                var neighbor_y := exterior_surface_y_cell_from_context(neighbor_x, neighbor_z, context)
                var delta_y := absf(surface_y - neighbor_y)
                if in_town != neighbor_in_town and delta_y >= edge_threshold:
                    return true
                if (in_town or neighbor_in_town) and delta_y >= slope_threshold:
                    return true
    return false

func project_chunk_surface_normals(mesh: Mesh, cx: int, cz: int) -> Mesh:
    if mesh == null or not (mesh is ArrayMesh):
        return mesh
    var array_mesh := mesh as ArrayMesh
    if array_mesh.get_surface_count() <= 0:
        return mesh
    var start_x := cx * CHUNK_SIZE
    var start_z := cz * CHUNK_SIZE
    var projected_surfaces: Array = []
    var surface_materials: Array = []
    var changed_any := false
    for surface_index in range(array_mesh.get_surface_count()):
        var arrays := array_mesh.surface_get_arrays(surface_index)
        var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
        var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
        var changed_surface := false
        if not vertices.is_empty() and normals.size() == vertices.size():
            for vertex_index in range(vertices.size()):
                var normal := normals[vertex_index]
                if normal.y <= 0.20:
                    continue
                var vertex := vertices[vertex_index]
                var cell_x := roundi((float(start_x) * CELL + vertex.x) / CELL)
                var cell_z := roundi((float(start_z) * CELL + vertex.z) / CELL)
                var surface_y := natural_exterior_surface_y_cell(cell_x, cell_z)
                if absf(vertex.y - surface_y) > CELL * 2.25:
                    continue
                var projected_normal := exterior_surface_normal_for_cell(cell_x, cell_z)
                if projected_normal.length_squared() <= 0.0001:
                    continue
                normals[vertex_index] = projected_normal
                changed_surface = true
            if changed_surface:
                arrays[Mesh.ARRAY_NORMAL] = normals
                changed_any = true
        projected_surfaces.append(arrays)
        surface_materials.append(array_mesh.surface_get_material(surface_index))
    if not changed_any:
        return mesh
    var projected_mesh := ArrayMesh.new()
    for surface_index in range(projected_surfaces.size()):
        projected_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, projected_surfaces[surface_index])
        var material = surface_materials[surface_index]
        if material is Material:
            projected_mesh.surface_set_material(surface_index, material as Material)
    for meta_name in mesh.get_meta_list():
        projected_mesh.set_meta(String(meta_name), mesh.get_meta(String(meta_name)))
    projected_mesh.set_meta("terrainSurfaceNormalsProjected", true)
    return projected_mesh

func exterior_surface_y_from_cache(surface_cache: Dictionary, cell_x: int, cell_z: int) -> float:
    var key := Vector2i(cell_x, cell_z)
    return float(surface_cache[key]) if surface_cache.has(key) else exterior_surface_y_cell(cell_x, cell_z)

func chunk_needs_generated_underground_volume_mesh(start_x: int, start_z: int) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_world"):
        return false
    if chunk_has_terrain_volume_edits(start_x, start_z):
        return true
    var focus_is_underground := player != null and position_is_near_underground_air_focus(player.global_position)
    if focus_is_underground and chunk_has_underground_focus_overlap(start_x, start_z):
        return true
    if chunk_has_town_surface_volume_edge(start_x, start_z):
        return true
    if has_method("should_use_cached_generated_volume_exposure_only") and bool(call("should_use_cached_generated_volume_exposure_only")):
        var cached_value = cached_generated_surface_volume_exposure(start_x, start_z)
        if cached_value is Dictionary:
            var cached: Dictionary = cached_value
            if bool(cached.get("known", false)):
                return bool(cached.get("result", false))
        if has_method("queue_generated_volume_exposure_scan_for_region"):
            call("queue_generated_volume_exposure_scan_for_region", start_x, start_z)
        return false
    if has_method("should_defer_generated_volume_exposure_scan") and bool(call("should_defer_generated_volume_exposure_scan")):
        if has_method("note_deferred_generated_volume_exposure_scan"):
            call("note_deferred_generated_volume_exposure_scan")
        return false
    if chunk_has_generated_surface_volume_exposure(start_x, start_z):
        return true
    if adjacent_chunk_requires_generated_underground_volume_mesh(start_x, start_z, focus_is_underground):
        return true
    return false

func adjacent_chunk_requires_generated_underground_volume_mesh(start_x: int, start_z: int, focus_is_underground: bool) -> bool:
    var offsets: Array[Vector2i] = [
        Vector2i(1, 0),
        Vector2i(-1, 0),
        Vector2i(0, 1),
        Vector2i(0, -1)
    ]
    for offset: Vector2i in offsets:
        var neighbor_start_x: int = start_x + offset.x * CHUNK_SIZE
        var neighbor_start_z: int = start_z + offset.y * CHUNK_SIZE
        if chunk_has_terrain_volume_edits(neighbor_start_x, neighbor_start_z):
            return true
        if focus_is_underground and chunk_has_underground_focus_overlap(neighbor_start_x, neighbor_start_z):
            return true
        if chunk_has_town_surface_volume_edge(neighbor_start_x, neighbor_start_z):
            return true
        if chunk_has_generated_surface_volume_exposure(neighbor_start_x, neighbor_start_z):
            return true
    return false

func chunk_has_terrain_volume_edits(start_x: int, start_z: int) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("terrain_volume_chunk_has_edits"):
        return false
    var chunk_key := Vector2i(floori(float(start_x) / float(CHUNK_SIZE)), floori(float(start_z) / float(CHUNK_SIZE)))
    return bool(world_generation_system.call("terrain_volume_chunk_has_edits", chunk_key, CHUNK_SIZE))

func edited_volume_boundary_cells_for_chunk(start_x: int, start_z: int, min_y: int, max_y: int) -> Array[Vector3i]:
    if world_generation_system == null or not world_generation_system.has_method("terrain_volume_edited_mesh_cells_for_chunk"):
        return []
    var chunk_key := Vector2i(floori(float(start_x) / float(CHUNK_SIZE)), floori(float(start_z) / float(CHUNK_SIZE)))
    var cells_value = world_generation_system.call("terrain_volume_edited_mesh_cells_for_chunk", chunk_key, CHUNK_SIZE)
    if not (cells_value is Array):
        return []
    var cells: Array[Vector3i] = []
    for value in cells_value:
        if not (value is Vector3i):
            continue
        var cell: Vector3i = value
        if cell.y < min_y - 2 or cell.y > max_y + 2:
            continue
        cells.append(cell)
    return cells

func underground_air_column_reaches_open_surface(cell_x: int, air_y: int, cell_z: int, surface_cell_y: int) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_world"):
        return false
    for y in range(air_y + 1, surface_cell_y + 2):
        var sample_position := Vector3(float(cell_x) * CELL, float(y) * CELL, float(cell_z) * CELL)
        var sample: Dictionary = world_generation_system.call("sample_world", sample_position)
        if bool(sample.get("solid", false)):
            return false
    return true

func chunk_has_generated_surface_volume_exposure(start_x: int, start_z: int) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_world"):
        return false
    var cached_value = cached_generated_surface_volume_exposure(start_x, start_z)
    if cached_value is Dictionary:
        var cached: Dictionary = cached_value
        if bool(cached.get("known", false)):
            return bool(cached.get("result", false))
    var step := maxi(4, int(UNDERGROUND_VOLUME_EXTERIOR_LOD_STEP_CELLS))
    var vertical_step := maxi(1, int(UNDERGROUND_VOLUME_SURFACE_EXPOSURE_VERTICAL_STEP_CELLS))
    var max_depth_cells := mini(
        generated_volume_scan_depth_for_chunk(start_x, start_z, step),
        int(UNDERGROUND_VOLUME_SURFACE_EXPOSURE_DEPTH_CELLS)
    )
    var result := false
    var sample_cache := {}
    for z in range(start_z - step, start_z + CHUNK_SIZE + step + 1, step):
        for x in range(start_x - step, start_x + CHUNK_SIZE + step + 1, step):
            var surface_y := chunk_reference_surface_y_for_volume_scan(x, z)
            var surface_cell_y := floori(surface_y / CELL)
            for depth in range(1, max_depth_cells + 1, vertical_step):
                var y := surface_cell_y - depth
                var numeric_sample := volume_grid_sample_numeric(Vector3i(x, y, z), sample_cache)
                if numeric_sample.x < 0.0 and numeric_sample.y <= 0.0:
                    if underground_air_column_reaches_open_surface(x, y, z, surface_cell_y):
                        result = true
                        break
            if result:
                break
        if result:
            break
    cache_generated_surface_volume_exposure(start_x, start_z, result)
    return result

func generated_volume_scan_depth_for_chunk(start_x: int, start_z: int, step_cells: int) -> int:
    var bottom_y := int(world_generation_system.call("world_bottom_cell_y")) if world_generation_system != null and world_generation_system.has_method("world_bottom_cell_y") else floori((MIN_HEIGHT - CELL * 64.0) / CELL)
    var max_surface_cell_y := floori(MAX_HEIGHT / CELL)
    var step := maxi(1, int(step_cells))
    for z in range(start_z - step, start_z + CHUNK_SIZE + step + 1, step):
        for x in range(start_x - step, start_x + CHUNK_SIZE + step + 1, step):
            var surface_cell_y := floori(chunk_reference_surface_y_for_volume_scan(x, z) / CELL)
            max_surface_cell_y = maxi(max_surface_cell_y, surface_cell_y)
    return maxi(1, max_surface_cell_y - bottom_y - 1)

func chunk_reference_surface_y_for_volume_scan(cell_x: int, cell_z: int) -> float:
    if world_generation_system != null and world_generation_system.has_method("surface_y_for_cell"):
        return float(world_generation_system.call("surface_y_for_cell", Vector3i(cell_x, 0, cell_z)))
    return chunk_bound_surface_y_at_cell(Vector3i(cell_x, 0, cell_z))

func chunk_has_underground_focus_overlap(start_x: int, start_z: int) -> bool:
    if player == null:
        return false
    var focus := player.global_position
    if not position_is_near_underground_air_focus(focus):
        return false
    var radius := float(maxi(underground_volume_focus_radius_cells(), UNDERGROUND_VOLUME_FOCUS_STEP_CELLS)) * CELL
    var min_x := float(start_x) * CELL - radius
    var max_x := float(start_x + CHUNK_SIZE) * CELL + radius
    var min_z := float(start_z) * CELL - radius
    var max_z := float(start_z + CHUNK_SIZE) * CELL + radius
    return focus.x >= min_x and focus.x <= max_x and focus.z >= min_z and focus.z <= max_z

func position_is_near_underground_air_focus(position: Vector3) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_world"):
        return force_underground_volume_debug
    var focus_cell := Vector3i(world_to_cell(position.x), world_to_cell(position.y), world_to_cell(position.z))
    var revision := int(world_generation_system.call("terrain_volume_revision")) if world_generation_system.has_method("terrain_volume_revision") else 0
    var seed_key := seed_text
    var cache_matches := focus_cell == underground_focus_cache_cell
    cache_matches = cache_matches and revision == underground_focus_cache_revision
    cache_matches = cache_matches and seed_key == underground_focus_cache_seed
    cache_matches = cache_matches and force_underground_volume_debug == underground_focus_cache_debug
    if cache_matches:
        return underground_focus_cache_result
    if force_underground_volume_debug:
        return remember_underground_focus_result(focus_cell, revision, seed_key, true)
    var surface_y := chunk_bound_surface_y_at_cell(Vector3i(focus_cell.x, 0, focus_cell.z))
    if position.y >= surface_y - CELL * 0.35:
        return remember_underground_focus_result(focus_cell, revision, seed_key, false)
    var offsets: Array[Vector3i] = [
        Vector3i.ZERO,
        Vector3i(0, -1, 0),
        Vector3i(0, 1, 0),
        Vector3i(1, 0, 0),
        Vector3i(-1, 0, 0),
        Vector3i(0, 0, 1),
        Vector3i(0, 0, -1)
    ]
    for offset: Vector3i in offsets:
        var sample_cell: Vector3i = focus_cell + offset
        if world_generation_system.has_method("volume_numeric_sample_at_grid_cell"):
            var numeric_sample: Vector3 = world_generation_system.call("volume_numeric_sample_at_grid_cell", sample_cell)
            if numeric_sample.x < 0.0 and numeric_sample.y <= 0.0:
                return remember_underground_focus_result(focus_cell, revision, seed_key, true)
            continue
        var sample_position := Vector3(float(sample_cell.x) * CELL, float(sample_cell.y) * CELL, float(sample_cell.z) * CELL)
        var sample: Dictionary = world_generation_system.call("sample_world", sample_position)
        if String(sample.get("biome", "")) == "underground_air" and not bool(sample.get("solid", false)):
            return remember_underground_focus_result(focus_cell, revision, seed_key, true)
    return remember_underground_focus_result(focus_cell, revision, seed_key, false)

func remember_underground_focus_result(cell: Vector3i, revision: int, seed_key: String, result: bool) -> bool:
    underground_focus_cache_cell = cell
    underground_focus_cache_revision = revision
    underground_focus_cache_seed = seed_key
    underground_focus_cache_debug = force_underground_volume_debug
    underground_focus_cache_result = result
    return result

func chunk_has_excavation_overlap(start_x: int, start_z: int) -> bool:
    var brushes := active_volume_excavation_brushes()
    if brushes.is_empty():
        return false
    var min_x := float(start_x) * CELL - CELL
    var max_x := float(start_x + CHUNK_SIZE) * CELL + CELL
    var min_z := float(start_z) * CELL - CELL
    var max_z := float(start_z + CHUNK_SIZE) * CELL + CELL
    for brush_value in brushes:
        if not (brush_value is Dictionary):
            continue
        var brush: Dictionary = brush_value
        var center: Vector3 = brush.get("center", Vector3.ZERO)
        var radius := float(brush.get("radius", 0.0))
        if radius <= 0.0:
            continue
        if center.x + radius < min_x or center.x - radius > max_x:
            continue
        if center.z + radius < min_z or center.z - radius > max_z:
            continue
        return true
    return false

func excavation_volume_y_bounds_for_chunk(start_x: int, start_z: int) -> Dictionary:
    var min_y := 999999
    var max_y := -999999
    var found := false
    var chunk_min_x := float(start_x) * CELL - CELL
    var chunk_max_x := float(start_x + CHUNK_SIZE) * CELL + CELL
    var chunk_min_z := float(start_z) * CELL - CELL
    var chunk_max_z := float(start_z + CHUNK_SIZE) * CELL + CELL
    for brush_value in active_volume_excavation_brushes():
        if not (brush_value is Dictionary):
            continue
        var brush: Dictionary = brush_value
        var center: Vector3 = brush.get("center", Vector3.ZERO)
        var radius := float(brush.get("radius", 0.0))
        if radius <= 0.0:
            continue
        if center.x + radius < chunk_min_x or center.x - radius > chunk_max_x:
            continue
        if center.z + radius < chunk_min_z or center.z - radius > chunk_max_z:
            continue
        var center_y := world_to_cell(center.y)
        var radius_cells := ceili(radius / CELL) + 3
        min_y = mini(min_y, center_y - radius_cells)
        max_y = maxi(max_y, center_y + radius_cells)
        found = true
    if not found:
        return {
            "minY": 0,
            "maxY": 0
        }
    return {
        "minY": min_y,
        "maxY": max_y
    }

func chunk_volume_y_bounds(start_x: int, start_z: int) -> Dictionary:
    if player != null and chunk_has_underground_focus_overlap(start_x, start_z):
        var radius_world := float(underground_volume_focus_radius_cells() + 3) * CELL
        return {
            "minY": floori((player.global_position.y - radius_world) / CELL),
            "maxY": ceili((player.global_position.y + radius_world) / CELL)
        }
    if world_generation_system != null and world_generation_system.has_method("terrain_meshing_y_bounds_for_chunk"):
        var authoritative_bounds_value = world_generation_system.call(
            "terrain_meshing_y_bounds_for_chunk",
            start_x,
            start_z,
            CHUNK_SIZE,
            UNDERGROUND_VOLUME_SURFACE_EXPOSURE_DEPTH_CELLS + 4,
            2,
            2
        )
        if authoritative_bounds_value is Dictionary:
            return authoritative_bounds_value
    var chunk_key := Vector2i(floori(float(start_x) / float(CHUNK_SIZE)), floori(float(start_z) / float(CHUNK_SIZE)))
    var edited_bounds := {}
    if world_generation_system != null and world_generation_system.has_method("terrain_volume_chunk_edited_y_bounds"):
        edited_bounds = world_generation_system.call("terrain_volume_chunk_edited_y_bounds", chunk_key, CHUNK_SIZE)
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
    var fallback_depth_cells := 64
    var bottom_world := float(world_generation_system.call("world_bottom_cell_y")) * CELL if world_generation_system != null and world_generation_system.has_method("world_bottom_cell_y") else min_height - float(fallback_depth_cells) * CELL
    var shallow_surface_depth := float(UNDERGROUND_VOLUME_SURFACE_EXPOSURE_DEPTH_CELLS + 4) * CELL
    var min_bound: float = maxf(bottom_world, min_height - shallow_surface_depth)
    var max_bound: float = max_height + CELL * 2.0
    if bool(edited_bounds.get("found", false)):
        min_bound = maxf(bottom_world, float(int(edited_bounds.get("minY", floori(bottom_world / CELL))) - 3) * CELL)
        max_bound = maxf(max_bound, float(int(edited_bounds.get("maxY", ceili(max_height / CELL))) + 3) * CELL)
    return {
        "minY": floori(min_bound / CELL),
        "maxY": ceili(max_bound / CELL)
    }

func column_volume_y_bounds(cell_x: int, cell_z: int, chunk_min_y: int, chunk_max_y: int) -> Dictionary:
    var surface := chunk_bound_surface_y_at_cell(Vector3i(cell_x, 0, cell_z))
    var min_bound := float(chunk_min_y) * CELL
    var max_bound := surface + CELL * 2.0
    return {
        "minY": clampi(floori(min_bound / CELL), chunk_min_y, chunk_max_y),
        "maxY": clampi(ceili(max_bound / CELL), chunk_min_y, chunk_max_y)
    }

func mesh_block_volume_y_bounds(cell_x: int, cell_z: int, step_cells: int, chunk_min_y: int, chunk_max_y: int) -> Dictionary:
    var min_bound := chunk_max_y
    var max_bound := chunk_min_y
    var found := false
    var step := maxi(1, step_cells)
    for dz in range(step):
        for dx in range(step):
            var bounds := column_volume_y_bounds(cell_x + dx, cell_z + dz, chunk_min_y, chunk_max_y)
            var bound_min := int(bounds.get("minY", chunk_min_y))
            var bound_max := int(bounds.get("maxY", chunk_min_y))
            if bound_max <= bound_min:
                continue
            min_bound = mini(min_bound, bound_min)
            max_bound = maxi(max_bound, bound_max)
            found = true
    if not found:
        return {
            "minY": chunk_min_y,
            "maxY": chunk_min_y
        }
    return {
        "minY": min_bound,
        "maxY": max_bound
    }

func chunk_bound_surface_y_at_cell(cell: Vector3i) -> float:
    if world_generation_system != null:
        return world_generation_system.surface_y_for_cell(cell)
    return surface_y_at_cell(cell)

func volume_grid_sample(grid_cell: Vector3i, sample_cache: Dictionary, volume_context := {}) -> Dictionary:
    if sample_cache.has(grid_cell):
        return sample_cache[grid_cell]
    var position := Vector3(float(grid_cell.x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z) * CELL)
    var sample := {}
    if not volume_context.is_empty():
        sample = volume_sample_from_context(position, grid_cell, volume_context)
    elif world_generation_system != null and world_generation_system.has_method("sample_world"):
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

func volume_grid_sample_numeric(grid_cell: Vector3i, sample_cache: Dictionary, volume_context := {}) -> Vector3:
    if sample_cache.has(grid_cell):
        var cached = sample_cache[grid_cell]
        if cached is Vector3:
            return cached
    if world_generation_system != null and world_generation_system.has_method("volume_numeric_sample_at_grid_cell"):
        var fast_result: Vector3 = world_generation_system.call("volume_numeric_sample_at_grid_cell", grid_cell)
        sample_cache[grid_cell] = fast_result
        return fast_result
    var position := Vector3(float(grid_cell.x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z) * CELL)
    var surface_y := 0.0
    var generated_air_value := INF
    var density := 0.0
    if world_generation_system != null and world_generation_system.has_method("sample_world"):
        var sample: Dictionary = world_generation_system.call("sample_world", position)
        density = float(sample.get("density", 0.0))
        generated_air_value = 0.0 if String(sample.get("biome", "")) == "underground_air" and not bool(sample.get("solid", true)) else INF
        surface_y = float(sample.get("surfaceY", chunk_bound_surface_y_at_cell(Vector3i(grid_cell.x, 0, grid_cell.z))))
    else:
        surface_y = surface_y_at_cell(Vector3i(grid_cell.x, 0, grid_cell.z))
        density = surface_y - position.y
    var result := Vector3(density, generated_air_value, surface_y)
    sample_cache[grid_cell] = result
    return result

func native_terrain_numeric_sample_at_grid_cell(grid_cell: Vector3i) -> Vector3:
    if world_generation_system != null and world_generation_system.has_method("volume_numeric_sample_at_grid_cell"):
        return world_generation_system.call("volume_numeric_sample_at_grid_cell", grid_cell)
    return volume_grid_sample_numeric(grid_cell, {})

func extract_volume_iso_cube_arrays(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    base_cell: Vector3i,
    origin_x: int,
    origin_z: int,
    sample_cache: Dictionary,
    volume_context := {},
    step_cells := 1
) -> void:
    var local_positions: Array[Vector3] = []
    var world_positions: Array[Vector3] = []
    var densities := PackedFloat32Array()
    var generated_air_values := PackedFloat32Array()
    var surface_ys := PackedFloat32Array()
    var solids: Array[bool] = []
    local_positions.resize(8)
    world_positions.resize(8)
    densities.resize(8)
    generated_air_values.resize(8)
    surface_ys.resize(8)
    solids.resize(8)
    var solid_count := 0
    for index in range(VOLUME_CUBE_CORNER_OFFSETS.size()):
        var offset: Vector3i = VOLUME_CUBE_CORNER_OFFSETS[index]
        offset = Vector3i(offset.x * step_cells, offset.y * step_cells, offset.z * step_cells)
        var grid_cell: Vector3i = base_cell + offset
        var sample := volume_grid_sample_numeric(grid_cell, sample_cache, volume_context)
        var density := sample.x
        var solid := density > 0.0
        if solid:
            solid_count += 1
        local_positions[index] = Vector3(float(grid_cell.x - origin_x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z - origin_z) * CELL)
        world_positions[index] = Vector3(float(grid_cell.x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z) * CELL)
        densities[index] = density
        generated_air_values[index] = sample.y
        surface_ys[index] = sample.z
        solids[index] = solid
    if solid_count == 0 or solid_count == local_positions.size():
        return
    extract_volume_iso_tetrahedron_indices_numeric(vertices, normals, colors, 0, 5, 1, 6, local_positions, world_positions, densities, generated_air_values, surface_ys, solids, volume_context)
    extract_volume_iso_tetrahedron_indices_numeric(vertices, normals, colors, 0, 1, 2, 6, local_positions, world_positions, densities, generated_air_values, surface_ys, solids, volume_context)
    extract_volume_iso_tetrahedron_indices_numeric(vertices, normals, colors, 0, 2, 3, 6, local_positions, world_positions, densities, generated_air_values, surface_ys, solids, volume_context)
    extract_volume_iso_tetrahedron_indices_numeric(vertices, normals, colors, 0, 3, 7, 6, local_positions, world_positions, densities, generated_air_values, surface_ys, solids, volume_context)
    extract_volume_iso_tetrahedron_indices_numeric(vertices, normals, colors, 0, 7, 4, 6, local_positions, world_positions, densities, generated_air_values, surface_ys, solids, volume_context)
    extract_volume_iso_tetrahedron_indices_numeric(vertices, normals, colors, 0, 4, 5, 6, local_positions, world_positions, densities, generated_air_values, surface_ys, solids, volume_context)

func extract_volume_iso_tetrahedron_indices_numeric(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    i0: int,
    i1: int,
    i2: int,
    i3: int,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    generated_air_values: PackedFloat32Array,
    surface_ys: PackedFloat32Array,
    solids: Array[bool],
    volume_context := {}
) -> void:
    var solid0 := -1
    var solid1 := -1
    var solid2 := -1
    var air0 := -1
    var air1 := -1
    var air2 := -1
    var solid_count := 0
    var air_count := 0
    if bool(solids[i0]):
        solid0 = i0
        solid_count += 1
    else:
        air0 = i0
        air_count += 1
    if bool(solids[i1]):
        if solid_count == 0:
            solid0 = i1
        elif solid_count == 1:
            solid1 = i1
        else:
            solid2 = i1
        solid_count += 1
    else:
        if air_count == 0:
            air0 = i1
        elif air_count == 1:
            air1 = i1
        else:
            air2 = i1
        air_count += 1
    if bool(solids[i2]):
        if solid_count == 0:
            solid0 = i2
        elif solid_count == 1:
            solid1 = i2
        else:
            solid2 = i2
        solid_count += 1
    else:
        if air_count == 0:
            air0 = i2
        elif air_count == 1:
            air1 = i2
        else:
            air2 = i2
        air_count += 1
    if bool(solids[i3]):
        if solid_count == 0:
            solid0 = i3
        elif solid_count == 1:
            solid1 = i3
        else:
            solid2 = i3
        solid_count += 1
    else:
        if air_count == 0:
            air0 = i3
        elif air_count == 1:
            air1 = i3
        else:
            air2 = i3
        air_count += 1
    if solid_count == 0 or air_count == 0:
        return
    if not volume_air_indices_need_iso_surface_numeric(air0, air1, air2, air_count, generated_air_values, surface_ys, world_positions):
        return
    if solid_count == 1:
        var desired := average_world_positions_fast(air0, air1, air2, air_count, world_positions) - world_positions[solid0]
        add_volume_iso_triangle_edges_numeric(
            vertices,
            normals,
            colors,
            solid0,
            air0,
            solid0,
            air1,
            solid0,
            air2,
            local_positions,
            world_positions,
            densities,
            generated_air_values,
            desired,
            volume_context
        )
    elif solid_count == 3:
        var desired := world_positions[air0] - average_world_positions_fast(solid0, solid1, solid2, solid_count, world_positions)
        add_volume_iso_triangle_edges_numeric(
            vertices,
            normals,
            colors,
            solid0,
            air0,
            solid1,
            air0,
            solid2,
            air0,
            local_positions,
            world_positions,
            densities,
            generated_air_values,
            desired,
            volume_context
        )
    elif solid_count == 2 and air_count == 2:
        var desired := average_world_positions_fast(air0, air1, -1, air_count, world_positions) - average_world_positions_fast(solid0, solid1, -1, solid_count, world_positions)
        add_volume_iso_triangle_edges_numeric(vertices, normals, colors, solid0, air0, solid1, air0, solid1, air1, local_positions, world_positions, densities, generated_air_values, desired, volume_context)
        add_volume_iso_triangle_edges_numeric(vertices, normals, colors, solid0, air0, solid1, air1, solid0, air1, local_positions, world_positions, densities, generated_air_values, desired, volume_context)

func volume_air_indices_need_iso_surface_numeric(
    air0: int,
    air1: int,
    air2: int,
    air_count: int,
    generated_air_values: PackedFloat32Array,
    surface_ys: PackedFloat32Array,
    world_positions: Array[Vector3]
) -> bool:
    if air_count >= 1 and volume_air_index_needs_iso_surface_numeric(air0, generated_air_values, surface_ys, world_positions):
        return true
    if air_count >= 2 and volume_air_index_needs_iso_surface_numeric(air1, generated_air_values, surface_ys, world_positions):
        return true
    if air_count >= 3 and volume_air_index_needs_iso_surface_numeric(air2, generated_air_values, surface_ys, world_positions):
        return true
    return false

func volume_air_index_needs_iso_surface_numeric(index: int, generated_air_values: PackedFloat32Array, surface_ys: PackedFloat32Array, world_positions: Array[Vector3]) -> bool:
    if index < 0:
        return false
    if float(generated_air_values[index]) <= 0.0:
        return true
    return world_positions[index].y < float(surface_ys[index]) - CELL * 0.35

func interpolate_volume_iso_edge_numeric(
    solid_index: int,
    air_index: int,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    generated_air_values: PackedFloat32Array
) -> Array:
    var da := float(densities[solid_index])
    var db := float(densities[air_index])
    var t := 0.5
    var denominator := da - db
    if absf(denominator) > 0.0001:
        t = clampf(da / denominator, 0.0, 1.0)
    return [
        local_positions[solid_index].lerp(local_positions[air_index], t),
        world_positions[solid_index].lerp(world_positions[air_index], t),
        float(generated_air_values[air_index])
    ]

func add_volume_iso_triangle_edges_numeric(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    solid_a: int,
    air_a: int,
    solid_b: int,
    air_b: int,
    solid_c: int,
    air_c: int,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    generated_air_values: PackedFloat32Array,
    desired_normal: Vector3,
    volume_context := {}
) -> void:
    var da := float(densities[solid_a])
    var db := float(densities[air_a])
    var ta := 0.5
    var denominator := da - db
    if absf(denominator) > 0.0001:
        ta = clampf(da / denominator, 0.0, 1.0)
    da = float(densities[solid_b])
    db = float(densities[air_b])
    var tb := 0.5
    denominator = da - db
    if absf(denominator) > 0.0001:
        tb = clampf(da / denominator, 0.0, 1.0)
    da = float(densities[solid_c])
    db = float(densities[air_c])
    var tc := 0.5
    denominator = da - db
    if absf(denominator) > 0.0001:
        tc = clampf(da / denominator, 0.0, 1.0)
    add_volume_iso_triangle_values_numeric(
        vertices,
        normals,
        colors,
        local_positions[solid_a].lerp(local_positions[air_a], ta),
        world_positions[solid_a].lerp(world_positions[air_a], ta),
        float(generated_air_values[air_a]),
        local_positions[solid_b].lerp(local_positions[air_b], tb),
        world_positions[solid_b].lerp(world_positions[air_b], tb),
        float(generated_air_values[air_b]),
        local_positions[solid_c].lerp(local_positions[air_c], tc),
        world_positions[solid_c].lerp(world_positions[air_c], tc),
        float(generated_air_values[air_c]),
        desired_normal,
        volume_context
    )

func add_volume_iso_triangle_values_numeric(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    a_local: Vector3,
    a_world: Vector3,
    a_air_value: float,
    b_local: Vector3,
    b_world: Vector3,
    b_air_value: float,
    c_local: Vector3,
    c_world: Vector3,
    c_air_value: float,
    desired_normal: Vector3,
    volume_context := {}
) -> void:
    var cross := (b_local - a_local).cross(c_local - a_local)
    if cross.length_squared() <= 0.000001:
        return
    if desired_normal.length_squared() <= 0.0001:
        desired_normal = cross.normalized()
    else:
        desired_normal = desired_normal.normalized()
    if cross.normalized().dot(desired_normal) < 0.0:
        var swap_local := b_local
        var swap_world := b_world
        var swap_air_value := b_air_value
        b_local = c_local
        b_world = c_world
        b_air_value = c_air_value
        c_local = swap_local
        c_world = swap_world
        c_air_value = swap_air_value
        cross = -cross
    var normal := cross.normalized()
    var face_world := (a_world + b_world + c_world) / 3.0
    var face_air_value := minf(a_air_value, minf(b_air_value, c_air_value))
    var face_color := volume_iso_vertex_color_numeric(face_world, face_air_value, normal, volume_context)
    vertices.append(a_local)
    normals.append(normal)
    colors.append(face_color)
    vertices.append(b_local)
    normals.append(normal)
    colors.append(face_color)
    vertices.append(c_local)
    normals.append(normal)
    colors.append(face_color)

func add_volume_iso_triangle_oriented_arrays_numeric(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    a: Array,
    b: Array,
    c: Array,
    desired_normal: Vector3,
    volume_context := {}
) -> void:
    var a_local: Vector3 = a[0]
    var b_local: Vector3 = b[0]
    var c_local: Vector3 = c[0]
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
    append_volume_iso_vertex_arrays_numeric(vertices, normals, colors, a, normal, volume_context)
    append_volume_iso_vertex_arrays_numeric(vertices, normals, colors, b, normal, volume_context)
    append_volume_iso_vertex_arrays_numeric(vertices, normals, colors, c, normal, volume_context)

func append_volume_iso_vertex_arrays_numeric(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    point: Array,
    normal: Vector3,
    volume_context := {}
) -> void:
    var world: Vector3 = point[1]
    var air_value := float(point[2])
    vertices.append(point[0])
    normals.append(normal)
    colors.append(volume_iso_vertex_color_numeric(world, air_value, normal, volume_context))

func volume_iso_vertex_color_numeric(world: Vector3, air_value: float, normal: Vector3, volume_context := {}) -> Color:
    var shade := volume_iso_shade(world)
    if air_value <= 0.0:
        shade *= underground_wall_visual_shade(world)
        if normal.y < -0.35:
            return Color(0.055, 0.060, 0.060) * shade
        if normal.y > 0.35:
            return Color(0.150, 0.158, 0.142) * shade
        return Color(0.170, 0.182, 0.170) * shade
    var cell := Vector3i(world_to_cell(world.x), world_to_cell(world.y), world_to_cell(world.z))
    var surface_y := volume_context_surface_y_at_cell(cell.x, cell.z, volume_context) if not volume_context.is_empty() else chunk_bound_surface_y_at_cell(Vector3i(cell.x, 0, cell.z))
    var biome := volume_context_surface_biome_at_cell(cell.x, cell.z, volume_context) if not volume_context.is_empty() else surface_biome_at_cell(Vector3i(cell.x, 0, cell.z))
    var density := surface_y - world.y
    var material_id := volume_material_from_components(world, cell, density, surface_y, biome)
    if normal.y > 0.42 and material_id in ["grass", "mud", "snow"]:
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

func extract_volume_iso_tetrahedron_indices(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    i0: int,
    i1: int,
    i2: int,
    i3: int,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    solids: Array[bool],
    samples: Array[Dictionary],
    volume_context := {}
) -> void:
    var solid0 := -1
    var solid1 := -1
    var solid2 := -1
    var air0 := -1
    var air1 := -1
    var air2 := -1
    var solid_count := 0
    var air_count := 0
    if bool(solids[i0]):
        solid0 = i0
        solid_count += 1
    else:
        air0 = i0
        air_count += 1
    if bool(solids[i1]):
        if solid_count == 0:
            solid0 = i1
        elif solid_count == 1:
            solid1 = i1
        else:
            solid2 = i1
        solid_count += 1
    else:
        if air_count == 0:
            air0 = i1
        elif air_count == 1:
            air1 = i1
        else:
            air2 = i1
        air_count += 1
    if bool(solids[i2]):
        if solid_count == 0:
            solid0 = i2
        elif solid_count == 1:
            solid1 = i2
        else:
            solid2 = i2
        solid_count += 1
    else:
        if air_count == 0:
            air0 = i2
        elif air_count == 1:
            air1 = i2
        else:
            air2 = i2
        air_count += 1
    if bool(solids[i3]):
        if solid_count == 0:
            solid0 = i3
        elif solid_count == 1:
            solid1 = i3
        else:
            solid2 = i3
        solid_count += 1
    else:
        if air_count == 0:
            air0 = i3
        elif air_count == 1:
            air1 = i3
        else:
            air2 = i3
        air_count += 1
    if solid_count == 0 or air_count == 0:
        return
    if not volume_air_indices_need_iso_surface_fast(air0, air1, air2, air_count, samples, world_positions):
        return
    if solid_count == 1:
        var desired := average_world_positions_fast(air0, air1, air2, air_count, world_positions) - world_positions[solid0]
        add_volume_iso_triangle_oriented_arrays(
            vertices,
            normals,
            colors,
            interpolate_volume_iso_edge_fast(solid0, air0, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid0, air1, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid0, air2, local_positions, world_positions, densities, samples),
            desired,
            volume_context
        )
    elif solid_count == 3:
        var desired := world_positions[air0] - average_world_positions_fast(solid0, solid1, solid2, solid_count, world_positions)
        add_volume_iso_triangle_oriented_arrays(
            vertices,
            normals,
            colors,
            interpolate_volume_iso_edge_fast(solid0, air0, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid1, air0, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid2, air0, local_positions, world_positions, densities, samples),
            desired,
            volume_context
        )
    elif solid_count == 2 and air_count == 2:
        var desired := average_world_positions_fast(air0, air1, -1, air_count, world_positions) - average_world_positions_fast(solid0, solid1, -1, solid_count, world_positions)
        var p00 := interpolate_volume_iso_edge_fast(solid0, air0, local_positions, world_positions, densities, samples)
        var p10 := interpolate_volume_iso_edge_fast(solid1, air0, local_positions, world_positions, densities, samples)
        var p11 := interpolate_volume_iso_edge_fast(solid1, air1, local_positions, world_positions, densities, samples)
        var p01 := interpolate_volume_iso_edge_fast(solid0, air1, local_positions, world_positions, densities, samples)
        add_volume_iso_triangle_oriented_arrays(vertices, normals, colors, p00, p10, p11, desired, volume_context)
        add_volume_iso_triangle_oriented_arrays(vertices, normals, colors, p00, p11, p01, desired, volume_context)

func volume_air_indices_need_iso_surface_fast(air0: int, air1: int, air2: int, air_count: int, samples: Array[Dictionary], world_positions: Array[Vector3]) -> bool:
    if air_count >= 1 and volume_air_index_needs_iso_surface(air0, samples, world_positions):
        return true
    if air_count >= 2 and volume_air_index_needs_iso_surface(air1, samples, world_positions):
        return true
    if air_count >= 3 and volume_air_index_needs_iso_surface(air2, samples, world_positions):
        return true
    return false

func volume_air_index_needs_iso_surface(index: int, samples: Array[Dictionary], world_positions: Array[Vector3]) -> bool:
    if index < 0:
        return false
    var sample: Dictionary = samples[index]
    if String(sample.get("biome", "")) == "underground_air":
        return true
    var world := world_positions[index]
    var surface_y := float(sample.get("surfaceY", chunk_bound_surface_y_at_cell(Vector3i(world_to_cell(world.x), 0, world_to_cell(world.z)))))
    return world.y < surface_y - CELL * 0.35

func average_world_positions_fast(i0: int, i1: int, i2: int, count: int, world_positions: Array[Vector3]) -> Vector3:
    var total := Vector3.ZERO
    if count >= 1 and i0 >= 0:
        total += world_positions[i0]
    if count >= 2 and i1 >= 0:
        total += world_positions[i1]
    if count >= 3 and i2 >= 0:
        total += world_positions[i2]
    return total / maxf(1.0, float(count))

func extract_volume_iso_tetrahedron_arrays(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    tet: Array,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    solids: Array[bool],
    samples: Array[Dictionary],
    volume_context := {}
) -> void:
    var solid_indices: Array[int] = []
    var air_indices: Array[int] = []
    for index_value in tet:
        var index := int(index_value)
        if bool(solids[index]):
            solid_indices.append(index)
        else:
            air_indices.append(index)
    if solid_indices.is_empty() or air_indices.is_empty():
        return
    if not volume_air_indices_need_iso_surface(air_indices, samples, world_positions):
        return
    if solid_indices.size() == 1:
        var solid_index := solid_indices[0]
        var desired := average_world_positions(air_indices, world_positions) - world_positions[solid_index]
        add_volume_iso_triangle_oriented_arrays(
            vertices,
            normals,
            colors,
            interpolate_volume_iso_edge_fast(solid_index, air_indices[0], local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_index, air_indices[1], local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_index, air_indices[2], local_positions, world_positions, densities, samples),
            desired,
            volume_context
        )
    elif solid_indices.size() == 3:
        var air_index := air_indices[0]
        var desired := world_positions[air_index] - average_world_positions(solid_indices, world_positions)
        add_volume_iso_triangle_oriented_arrays(
            vertices,
            normals,
            colors,
            interpolate_volume_iso_edge_fast(solid_indices[0], air_index, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_indices[1], air_index, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_indices[2], air_index, local_positions, world_positions, densities, samples),
            desired,
            volume_context
        )
    elif solid_indices.size() == 2 and air_indices.size() == 2:
        var desired := average_world_positions(air_indices, world_positions) - average_world_positions(solid_indices, world_positions)
        var p00 := interpolate_volume_iso_edge_fast(solid_indices[0], air_indices[0], local_positions, world_positions, densities, samples)
        var p10 := interpolate_volume_iso_edge_fast(solid_indices[1], air_indices[0], local_positions, world_positions, densities, samples)
        var p11 := interpolate_volume_iso_edge_fast(solid_indices[1], air_indices[1], local_positions, world_positions, densities, samples)
        var p01 := interpolate_volume_iso_edge_fast(solid_indices[0], air_indices[1], local_positions, world_positions, densities, samples)
        add_volume_iso_triangle_oriented_arrays(vertices, normals, colors, p00, p10, p11, desired, volume_context)
        add_volume_iso_triangle_oriented_arrays(vertices, normals, colors, p00, p11, p01, desired, volume_context)

func add_volume_iso_triangle_oriented_arrays(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    a: Array,
    b: Array,
    c: Array,
    desired_normal: Vector3,
    volume_context := {}
) -> void:
    var a_local: Vector3 = a[0]
    var b_local: Vector3 = b[0]
    var c_local: Vector3 = c[0]
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
    append_volume_iso_vertex_arrays(vertices, normals, colors, a, normal, volume_context)
    append_volume_iso_vertex_arrays(vertices, normals, colors, b, normal, volume_context)
    append_volume_iso_vertex_arrays(vertices, normals, colors, c, normal, volume_context)

func append_volume_iso_vertex_arrays(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    point: Array,
    normal: Vector3,
    volume_context := {}
) -> void:
    var world: Vector3 = point[1]
    var solid_sample: Dictionary = point[2]
    var air_sample: Dictionary = point[3]
    vertices.append(point[0])
    normals.append(normal)
    colors.append(volume_iso_vertex_color_fast(world, solid_sample, air_sample, normal, volume_context))

func extract_volume_iso_cube(st: SurfaceTool, base_cell: Vector3i, origin_x: int, origin_z: int, sample_cache: Dictionary, volume_context := {}, step_cells := 1) -> void:
    var local_positions: Array[Vector3] = []
    var world_positions: Array[Vector3] = []
    var samples: Array[Dictionary] = []
    var densities := PackedFloat32Array()
    var solids: Array[bool] = []
    local_positions.resize(8)
    world_positions.resize(8)
    samples.resize(8)
    densities.resize(8)
    solids.resize(8)
    var solid_count := 0
    for index in range(VOLUME_CUBE_CORNER_OFFSETS.size()):
        var offset: Vector3i = VOLUME_CUBE_CORNER_OFFSETS[index]
        offset = Vector3i(offset.x * step_cells, offset.y * step_cells, offset.z * step_cells)
        var grid_cell: Vector3i = base_cell + offset
        var sample := volume_grid_sample(grid_cell, sample_cache, volume_context)
        var density := float(sample.get("density", 0.0))
        var solid := density > 0.0
        if solid:
            solid_count += 1
        local_positions[index] = Vector3(float(grid_cell.x - origin_x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z - origin_z) * CELL)
        world_positions[index] = Vector3(float(grid_cell.x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z) * CELL)
        samples[index] = sample
        densities[index] = density
        solids[index] = solid
    if solid_count == 0 or solid_count == local_positions.size():
        return
    for tet in VOLUME_TETRAHEDRA:
        extract_volume_iso_tetrahedron_fast(st, tet, local_positions, world_positions, densities, solids, samples, volume_context)

func extract_volume_iso_tetrahedron_fast(
    st: SurfaceTool,
    tet: Array,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    solids: Array[bool],
    samples: Array[Dictionary],
    volume_context := {}
) -> void:
    var solid_indices: Array[int] = []
    var air_indices: Array[int] = []
    for index_value in tet:
        var index := int(index_value)
        if bool(solids[index]):
            solid_indices.append(index)
        else:
            air_indices.append(index)
    if solid_indices.is_empty() or air_indices.is_empty():
        return
    if not volume_air_indices_need_iso_surface(air_indices, samples, world_positions):
        return
    if solid_indices.size() == 1:
        var solid_index := solid_indices[0]
        var desired := average_world_positions(air_indices, world_positions) - world_positions[solid_index]
        add_volume_iso_triangle_oriented_fast(
            st,
            interpolate_volume_iso_edge_fast(solid_index, air_indices[0], local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_index, air_indices[1], local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_index, air_indices[2], local_positions, world_positions, densities, samples),
            desired,
            volume_context
        )
    elif solid_indices.size() == 3:
        var air_index := air_indices[0]
        var desired := world_positions[air_index] - average_world_positions(solid_indices, world_positions)
        add_volume_iso_triangle_oriented_fast(
            st,
            interpolate_volume_iso_edge_fast(solid_indices[0], air_index, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_indices[1], air_index, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_indices[2], air_index, local_positions, world_positions, densities, samples),
            desired,
            volume_context
        )
    elif solid_indices.size() == 2 and air_indices.size() == 2:
        var desired := average_world_positions(air_indices, world_positions) - average_world_positions(solid_indices, world_positions)
        var p00 := interpolate_volume_iso_edge_fast(solid_indices[0], air_indices[0], local_positions, world_positions, densities, samples)
        var p10 := interpolate_volume_iso_edge_fast(solid_indices[1], air_indices[0], local_positions, world_positions, densities, samples)
        var p11 := interpolate_volume_iso_edge_fast(solid_indices[1], air_indices[1], local_positions, world_positions, densities, samples)
        var p01 := interpolate_volume_iso_edge_fast(solid_indices[0], air_indices[1], local_positions, world_positions, densities, samples)
        add_volume_iso_triangle_oriented_fast(st, p00, p10, p11, desired, volume_context)
        add_volume_iso_triangle_oriented_fast(st, p00, p11, p01, desired, volume_context)

func volume_air_indices_need_iso_surface(air_indices: Array[int], samples: Array[Dictionary], world_positions: Array[Vector3]) -> bool:
    for index in air_indices:
        var sample: Dictionary = samples[index]
        if String(sample.get("biome", "")) == "underground_air":
            return true
        var world := world_positions[index]
        var surface_y := float(sample.get("surfaceY", chunk_bound_surface_y_at_cell(Vector3i(world_to_cell(world.x), 0, world_to_cell(world.z)))))
        if world.y < surface_y - CELL * 0.35:
            return true
    return false

func average_world_positions(indices: Array[int], world_positions: Array[Vector3]) -> Vector3:
    var total := Vector3.ZERO
    for index in indices:
        total += world_positions[index]
    return total / maxf(1.0, float(indices.size()))

func interpolate_volume_iso_edge_fast(
    solid_index: int,
    air_index: int,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    samples: Array[Dictionary]
) -> Array:
    var da := float(densities[solid_index])
    var db := float(densities[air_index])
    var t := 0.5
    var denominator := da - db
    if absf(denominator) > 0.0001:
        t = clampf(da / denominator, 0.0, 1.0)
    return [
        local_positions[solid_index].lerp(local_positions[air_index], t),
        world_positions[solid_index].lerp(world_positions[air_index], t),
        samples[solid_index],
        samples[air_index]
    ]

func add_volume_iso_triangle_oriented_fast(st: SurfaceTool, a: Array, b: Array, c: Array, desired_normal: Vector3, volume_context := {}) -> void:
    var a_local: Vector3 = a[0]
    var b_local: Vector3 = b[0]
    var c_local: Vector3 = c[0]
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
    add_volume_iso_vertex_fast(st, a, normal, volume_context)
    add_volume_iso_vertex_fast(st, b, normal, volume_context)
    add_volume_iso_vertex_fast(st, c, normal, volume_context)

func add_volume_iso_vertex_fast(st: SurfaceTool, point: Array, normal: Vector3, volume_context := {}) -> void:
    var world: Vector3 = point[1]
    var solid_sample: Dictionary = point[2]
    var air_sample: Dictionary = point[3]
    st.set_normal(normal)
    st.set_color(volume_iso_vertex_color_fast(world, solid_sample, air_sample, normal, volume_context))
    st.add_vertex(point[0])

func volume_iso_vertex_color_fast(world: Vector3, solid_sample: Dictionary, air_sample: Dictionary, normal: Vector3, volume_context := {}) -> Color:
    var shade := volume_iso_shade(world)
    var air_biome_is_underground := String(air_sample.get("biome", "")) == "underground_air"
    if air_biome_is_underground:
        shade *= underground_wall_visual_shade(world)
        if normal.y < -0.35:
            return Color(0.055, 0.060, 0.060) * shade
        if normal.y > 0.35:
            return Color(0.150, 0.158, 0.142) * shade
        return Color(0.170, 0.182, 0.170) * shade
    var solid_cell: Vector3i = solid_sample.get("cell", Vector3i(world_to_cell(world.x), world_to_cell(world.y), world_to_cell(world.z)))
    var surface_cell := Vector3i(solid_cell.x, 0, solid_cell.z)
    var solid_surface_y := float(solid_sample.get("surfaceY", volume_context_surface_y_at_cell(solid_cell.x, solid_cell.z, volume_context) if not volume_context.is_empty() else chunk_bound_surface_y_at_cell(surface_cell)))
    var solid_density := float(solid_sample.get("density", solid_surface_y - world.y))
    var biome := String(solid_sample.get("biome", ""))
    if biome == "":
        biome = volume_context_surface_biome_at_cell(solid_cell.x, solid_cell.z, volume_context) if not volume_context.is_empty() else surface_biome_at_cell(surface_cell)
    var material_id := String(solid_sample.get("material", ""))
    if material_id == "":
        material_id = volume_material_from_components(world, solid_cell, solid_density, solid_surface_y, biome)
    if material_id == "air":
        var inside_sample := volume_sample_world(world - normal * CELL * 0.18, volume_context)
        var inside_cell: Vector3i = inside_sample.get("cell", solid_cell)
        var inside_surface_cell := Vector3i(inside_cell.x, 0, inside_cell.z)
        var inside_surface_y := float(inside_sample.get("surfaceY", volume_context_surface_y_at_cell(inside_cell.x, inside_cell.z, volume_context) if not volume_context.is_empty() else chunk_bound_surface_y_at_cell(inside_surface_cell)))
        var inside_density := float(inside_sample.get("density", inside_surface_y - world.y))
        biome = String(inside_sample.get("biome", ""))
        if biome == "":
            biome = volume_context_surface_biome_at_cell(inside_cell.x, inside_cell.z, volume_context) if not volume_context.is_empty() else surface_biome_at_cell(inside_surface_cell)
        material_id = String(inside_sample.get("material", ""))
        if material_id == "":
            material_id = volume_material_from_components(world, inside_cell, inside_density, inside_surface_y, biome)
    if normal.y > 0.42 and material_id in ["grass", "mud", "snow"]:
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

func volume_iso_shade(world: Vector3) -> float:
    var key := Vector3i(roundi(world.x * 9.0), roundi(world.y * 9.0), roundi(world.z * 9.0))
    return 0.88 + float(absi(hash(key)) % 100000) / 100000.0 * 0.16

func underground_wall_visual_shade(world: Vector3) -> float:
    if ridge_noise == null:
        return 1.0
    var broad := ridge_noise.get_noise_3d(world.x * 5.5 + 4100.0, world.y * 7.0 - 2300.0, world.z * 5.5 + 1700.0)
    var fine := ridge_noise.get_noise_3d(world.x * 13.0 - 7200.0, world.y * 11.0 + 3300.0, world.z * 13.0 - 5100.0)
    return clampf(0.96 + broad * 0.08 + fine * 0.035, 0.82, 1.12)

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
        if String(sample.get("biome", "")) == "underground_air":
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

func active_volume_excavation_brushes() -> Array:
    if world_generation_system == null:
        return []
    if world_generation_system.get("terrain_volume_service") != null:
        return []
    var brush_values = world_generation_system.get("excavation_brushes")
    if not (brush_values is Array):
        return []
    var result := []
    for brush_value in brush_values:
        if not (brush_value is Dictionary):
            continue
        var brush: Dictionary = brush_value
        if excavation_brush_is_surface_deformation(brush):
            continue
        result.append(brush)
    return result

func excavation_brush_is_surface_deformation(brush: Dictionary) -> bool:
    var mode := String(brush.get("mode", ""))
    if mode == "surface_deform":
        return true
    if mode == "volume":
        return false
    if brush.has("surfaceTargetY") or brush.has("deformRadius"):
        return true
    if world_generation_system != null and world_generation_system.has_method("brush_is_surface_deformation"):
        return bool(world_generation_system.call("brush_is_surface_deformation", brush))
    return false

func volume_sample_from_context(position: Vector3, sample_cell: Vector3i, volume_context: Dictionary) -> Dictionary:
    if world_generation_system != null and world_generation_system.has_method("sample_world"):
        return world_generation_system.call("sample_world", position)
    var surface_y := volume_context_surface_y_at_cell(sample_cell.x, sample_cell.z, volume_context)
    var density := surface_y - position.y
    return {
        "cell": sample_cell,
        "position": position,
        "solid": density >= 0.0,
        "density": density,
        "surface": absf(density) <= CELL * 0.75,
        "biome": surface_biome_at_cell(Vector3i(sample_cell.x, 0, sample_cell.z)),
        "material": "air" if density < 0.0 else surface_material_at_cell(Vector3i(sample_cell.x, 0, sample_cell.z)),
        "surfaceY": surface_y
    }

func volume_context_surface_y_at_cell(cell_x: int, cell_z: int, volume_context: Dictionary) -> float:
    var cache_value = volume_context.get("surfaceY", null)
    if not (cache_value is Dictionary):
        cache_value = {}
        volume_context["surfaceY"] = cache_value
    var cache: Dictionary = cache_value
    var key := Vector2i(cell_x, cell_z)
    if cache.has(key):
        return float(cache[key])
    var value := chunk_bound_surface_y_at_cell(Vector3i(cell_x, 0, cell_z))
    cache[key] = value
    return value

func volume_context_surface_biome_at_cell(cell_x: int, cell_z: int, volume_context: Dictionary) -> String:
    var cache_value = volume_context.get("surfaceBiome", null)
    if not (cache_value is Dictionary):
        cache_value = {}
        volume_context["surfaceBiome"] = cache_value
    var cache: Dictionary = cache_value
    var key := Vector2i(cell_x, cell_z)
    if cache.has(key):
        return String(cache[key])
    var biome := surface_biome_at_cell(Vector3i(cell_x, 0, cell_z))
    cache[key] = biome
    return biome

func volume_material_from_components(position: Vector3, sample_cell: Vector3i, density: float, surface_y: float, biome: String) -> String:
    if density < 0.0:
        return "air"
    var depth := maxf(0.0, surface_y - position.y)
    if depth <= CELL * 1.20:
        return volume_top_material_for_biome(biome)
    if depth <= CELL * 4.65:
        return volume_subsoil_material_for_biome(biome)
    var deep_ore := volume_ore_material_at(sample_cell, depth)
    return deep_ore if deep_ore != "" else "stone"

func volume_top_material_for_biome(biome: String) -> String:
    if biome == "beach" or biome == "desert":
        return "sand"
    if biome == "swamp":
        return "mud"
    if biome == "snow":
        return "snow"
    if biome == "alpine" or biome == "tundra":
        return "stone"
    return "grass"

func volume_subsoil_material_for_biome(biome: String) -> String:
    if biome == "beach" or biome == "desert":
        return "sand"
    if biome == "swamp":
        return "mud"
    if biome == "snow":
        return "snow"
    return "dirt"

func volume_ore_material_at(sample_cell: Vector3i, depth: float) -> String:
    var depth_cells := depth / maxf(0.001, CELL)
    var copper_noise := hash01("subsurface-copper:%s:%d,%d,%d" % [
        String(seed_text),
        int(sample_cell.x / 3),
        int(sample_cell.y / 3),
        int(sample_cell.z / 3)
    ])
    if depth_cells >= 8.0 and copper_noise > 0.985:
        return "copperOre"
    var iron_noise := hash01("subsurface-iron:%s:%d,%d,%d" % [
        String(seed_text),
        int(sample_cell.x / 4),
        int(sample_cell.y / 4),
        int(sample_cell.z / 4)
    ])
    if depth_cells >= 15.0 and iron_noise > 0.992:
        return "ironOre"
    return ""

func volume_density_at_world(position: Vector3) -> float:
    if world_generation_system != null and world_generation_system.has_method("density_at"):
        return float(world_generation_system.call("density_at", position))
    return surface_y_at_position(position) - position.y

func volume_sample_world(position: Vector3, volume_context := {}) -> Dictionary:
    if not volume_context.is_empty():
        var cell := Vector3i(world_to_cell(position.x), world_to_cell(position.y), world_to_cell(position.z))
        return volume_sample_from_context(position, cell, volume_context)
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
    var shade := volume_iso_shade(world)
    if air_biome == "underground_air":
        shade *= underground_wall_visual_shade(world)
        return volume_material_surface_color(material_id, biome, normal, shade, true)
    return volume_material_surface_color(material_id, biome, normal, shade, false)

func spawn_chunk_props(chunk: Node3D, cx: int, cz: int) -> void:
    var state := begin_chunk_prop_spawn_state(chunk, cx, cz)
    while not process_chunk_prop_spawn_state(state, 28, 999999):
        pass

func begin_chunk_prop_spawn_state(chunk: Node3D, cx: int, cz: int) -> Dictionary:
    var rng := RandomNumberGenerator.new()
    rng.seed = hash_string("%s:props:%d,%d" % [seed_text, cx, cz])
    var underground_rng := RandomNumberGenerator.new()
    underground_rng.seed = hash_string("%s:underground-props:%d,%d" % [seed_text, cx, cz])
    var detail_rng := RandomNumberGenerator.new()
    detail_rng.seed = hash_string("%s:details:%d,%d" % [seed_text, cx, cz])
    return {
        "chunk": chunk,
        "cx": cx,
        "cz": cz,
        "startX": cx * CHUNK_SIZE,
        "startZ": cz * CHUNK_SIZE,
        "rng": rng,
        "undergroundRng": underground_rng,
        "propIndex": 0,
        "undergroundIndex": 0,
        "undergroundCandidates": [],
        "undergroundScanColumn": 0,
        "undergroundScanY": 0,
        "undergroundScanColumnStarted": false,
        "undergroundScanComplete": false,
        "phase": "props",
        "detailRng": detail_rng,
        "detailIndex": 0,
        "detailAttempts": -1,
        "detailBatches": {},
        "detailBatchKeys": [],
        "detailBatchIndex": 0,
        "detailBatchRoot": null
    }

func process_chunk_prop_spawn_state(
    state: Dictionary,
    prop_attempt_budget: int,
    detail_attempt_budget: int,
    time_budget_ms := -1.0,
    budget_start_usec := 0
) -> bool:
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    if chunk == null or not is_instance_valid(chunk):
        return true
    var start_usec := budget_start_usec if budget_start_usec > 0 else Time.get_ticks_usec()
    var phase := String(state.get("phase", "props"))
    if phase == "props":
        var rng := state.get("rng") as RandomNumberGenerator
        if rng == null:
            return true
        var processed := 0
        var prop_index := int(state.get("propIndex", 0))
        while prop_index < 28 and processed < maxi(1, prop_attempt_budget):
            if processed > 0 and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
                break
            var prop_attempt_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_attempt") if runtime_perf_monitor != null else Time.get_ticks_usec()
            spawn_chunk_prop_attempt(state, prop_index, rng)
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_surface_prop_attempt", prop_attempt_start)
            prop_index += 1
            processed += 1
        state["propIndex"] = prop_index
        if prop_index < 28:
            return false
        if chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            return false
        state["phase"] = "details"
    if String(state.get("phase", "")) == "details":
        if not process_chunk_detail_spawn_state(state, detail_attempt_budget, time_budget_ms, start_usec):
            return false
        if chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            return false
        state["phase"] = "underground_props"
    if String(state.get("phase", "")) == "detail_batches":
        if not process_chunk_detail_batch_spawn_state(state, time_budget_ms, start_usec):
            return false
        if chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            return false
        state["phase"] = "underground_props"
    if String(state.get("phase", "")) == "underground_props":
        if not process_underground_chunk_prop_spawn_state(state, prop_attempt_budget, time_budget_ms, start_usec):
            return false
        if chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            return false
    return true

func chunk_prop_spawn_budget_elapsed(start_usec: int, time_budget_ms: float) -> bool:
    if time_budget_ms <= 0.0:
        return false
    return float(Time.get_ticks_usec() - start_usec) / 1000.0 >= time_budget_ms

func spawn_chunk_prop_attempt(state: Dictionary, i: int, rng: RandomNumberGenerator) -> void:
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    if chunk == null or not is_instance_valid(chunk):
        return
    var start_x := int(state.get("startX", int(state.get("cx", 0)) * CHUNK_SIZE))
    var start_z := int(state.get("startZ", int(state.get("cz", 0)) * CHUNK_SIZE))
    var x := start_x + 2 + rng.randi_range(0, CHUNK_SIZE - 4)
    var z := start_z + 2 + rng.randi_range(0, CHUNK_SIZE - 4)
    var prop_id := "%s:%d,%d:%d" % [seed_text, x, z, i]
    if removed_props.has(prop_id):
        return
    var block_check_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_block_check") if runtime_perf_monitor != null else Time.get_ticks_usec()
    if natural_props_blocked_at_cell(x, z):
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_surface_prop_block_check", block_check_start)
        return
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("chunk_surface_prop_block_check", block_check_start)
    var sample_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_sample") if runtime_perf_monitor != null else Time.get_ticks_usec()
    var surface_sample := surface_volume_spawn_sample_at_cell(x, z)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("chunk_surface_prop_sample", sample_start)
    if surface_sample.is_empty() or not bool(surface_sample.get("found", false)):
        return
    var h := float(surface_sample.get("height", 0.0))
    if h < WATER_LEVEL + 1.0 or h > 92.0:
        return
    var biome := String(surface_sample.get("biome", "plains"))
    if biome == "town":
        return
    var rock_roll := rock_chance(biome, h)
    var tree_roll := tree_chance(biome) if h <= 70.0 else 0.0
    var forage_roll := forage_chance(biome)
    var wildlife_roll := wildlife_chance(biome, h)
    var prop_roll := rng.randf()
    var local_position := Vector3((x - start_x) * CELL, h, (z - start_z) * CELL)
    if prop_roll < rock_roll:
        var ore := ore_for_cell(biome, h, rng)
        var rock_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_make_rock") if runtime_perf_monitor != null else Time.get_ticks_usec()
        if ore != "":
            make_ore_cluster(chunk, prop_id, local_position, ore, rng, 2)
        else:
            make_rock(chunk, prop_id, local_position, rng)
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_surface_prop_make_rock", rock_start)
    elif prop_roll < rock_roll + tree_roll:
        var tree_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_make_tree") if runtime_perf_monitor != null else Time.get_ticks_usec()
        make_tree(chunk, prop_id, local_position, biome, rng)
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_surface_prop_make_tree", tree_start)
    elif prop_roll < rock_roll + tree_roll + forage_roll:
        var forage_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_make_forage") if runtime_perf_monitor != null else Time.get_ticks_usec()
        make_forage(chunk, prop_id, local_position, biome, rng)
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_surface_prop_make_forage", forage_start)
    elif prop_roll < rock_roll + tree_roll + forage_roll + wildlife_roll:
        var wildlife_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_make_wildlife") if runtime_perf_monitor != null else Time.get_ticks_usec()
        make_wildlife(chunk, prop_id, local_position, biome, rng)
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_surface_prop_make_wildlife", wildlife_start)

func process_underground_chunk_prop_spawn_state(
    state: Dictionary,
    attempt_budget: int,
    time_budget_ms := -1.0,
    budget_start_usec := 0
) -> bool:
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    if chunk == null or not is_instance_valid(chunk):
        return true
    if state.get("undergroundCandidates", null) == null:
        state["undergroundCandidates"] = []
    var start_usec := budget_start_usec if budget_start_usec > 0 else Time.get_ticks_usec()
    if not bool(state.get("undergroundScanComplete", false)):
        var scan_budget := maxi(8, maxi(1, attempt_budget) * 8)
        var scan_start: int = runtime_perf_monitor.begin_section("chunk_underground_prop_scan") if runtime_perf_monitor != null else Time.get_ticks_usec()
        if not scan_underground_prop_candidates(state, scan_budget, time_budget_ms, start_usec):
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_underground_prop_scan", scan_start)
            return false
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_underground_prop_scan", scan_start)
        if chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            return false
    var candidates: Array = state.get("undergroundCandidates", []) if state.get("undergroundCandidates", []) is Array else []
    if candidates.is_empty():
        return true
    var rng := state.get("undergroundRng") as RandomNumberGenerator
    if rng == null:
        return true
    var processed := 0
    var index := int(state.get("undergroundIndex", 0))
    while index < candidates.size() and processed < maxi(1, attempt_budget):
        if processed > 0 and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            break
        var cell_value = candidates[index]
        if cell_value is Vector3i:
            var underground_attempt_start: int = runtime_perf_monitor.begin_section("chunk_underground_prop_attempt") if runtime_perf_monitor != null else Time.get_ticks_usec()
            spawn_underground_prop_attempt(state, cell_value, rng)
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_underground_prop_attempt", underground_attempt_start)
        index += 1
        processed += 1
    state["undergroundIndex"] = index
    return index >= candidates.size()

func underground_prop_candidate_cells(cx: int, cz: int) -> Array[Vector3i]:
    var scan_state := {
        "cx": cx,
        "cz": cz,
        "startX": cx * CHUNK_SIZE,
        "startZ": cz * CHUNK_SIZE,
        "undergroundCandidates": [],
        "undergroundScanColumn": 0,
        "undergroundScanY": 0,
        "undergroundScanColumnStarted": false,
        "undergroundScanComplete": false
    }
    while not scan_underground_prop_candidates(scan_state, CHUNK_SIZE * CHUNK_SIZE * 96, -1.0, 0):
        pass
    var candidates: Array = scan_state.get("undergroundCandidates", []) if scan_state.get("undergroundCandidates", []) is Array else []
    var result: Array[Vector3i] = []
    for cell_value in candidates:
        if cell_value is Vector3i:
            result.append(cell_value)
    return result

func scan_underground_prop_candidates(
    state: Dictionary,
    sample_budget: int,
    time_budget_ms := -1.0,
    budget_start_usec := 0
) -> bool:
    if world_generation_system != null and world_generation_system.has_method("advance_exposed_underground_floor_scan"):
        return scan_underground_prop_candidates_from_volume_service(state, sample_budget, time_budget_ms, budget_start_usec)
    if world_generation_system == null or not world_generation_system.has_method("sample_cell"):
        state["undergroundScanComplete"] = true
        return true
    var candidates: Array = state.get("undergroundCandidates", []) if state.get("undergroundCandidates", []) is Array else []
    var max_candidates := 36
    if candidates.size() >= max_candidates:
        state["undergroundScanComplete"] = true
        state["undergroundCandidates"] = candidates
        return true
    var start_x := int(state.get("startX", int(state.get("cx", 0)) * CHUNK_SIZE))
    var start_z := int(state.get("startZ", int(state.get("cz", 0)) * CHUNK_SIZE))
    var start_usec := budget_start_usec if budget_start_usec > 0 else Time.get_ticks_usec()
    var total_columns := CHUNK_SIZE * CHUNK_SIZE
    var column_index := int(state.get("undergroundScanColumn", 0))
    var y := int(state.get("undergroundScanY", 0))
    var column_started := bool(state.get("undergroundScanColumnStarted", false))
    var bottom_y := int(world_generation_system.call("world_bottom_cell_y")) if world_generation_system.has_method("world_bottom_cell_y") else floori((MIN_HEIGHT - CELL * 4.0) / CELL)
    var processed := 0
    var found_count_before := candidates.size()
    while column_index < total_columns and candidates.size() < max_candidates and processed < maxi(1, sample_budget):
        if processed > 0 and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            break
        var lx := column_index % CHUNK_SIZE
        var lz := floori(float(column_index) / float(CHUNK_SIZE))
        var cell_x := start_x + lx
        var cell_z := start_z + lz
        if not column_started:
            var surface_y := chunk_reference_surface_y_for_volume_scan(cell_x, cell_z)
            y = floori(surface_y / CELL) + 1
            column_started = true
        var finished_column := false
        while y > bottom_y and processed < maxi(1, sample_budget):
            if processed > 0 and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
                break
            var air_cell := Vector3i(cell_x, y, cell_z)
            processed += 1
            if underground_air_floor_cell_is_valid(air_cell):
                var floor_cell := air_cell + Vector3i(0, -1, 0)
                var roll := hash01("underground-prop-candidate:%d,%d,%d" % [floor_cell.x, floor_cell.y, floor_cell.z])
                if roll <= 0.18:
                    candidates.append(floor_cell)
                finished_column = true
                break
            y -= 1
        if finished_column or y <= bottom_y:
            column_index += 1
            y = 0
            column_started = false
        else:
            break
    state["undergroundCandidates"] = candidates
    state["undergroundScanColumn"] = column_index
    state["undergroundScanY"] = y
    state["undergroundScanColumnStarted"] = column_started
    if column_index >= total_columns or candidates.size() >= max_candidates:
        state["undergroundScanComplete"] = true
    if runtime_perf_monitor != null and processed > 0:
        runtime_perf_monitor.increment_counter("underground_prop_cells_scanned", processed)
        var found_delta := candidates.size() - found_count_before
        if found_delta > 0:
            runtime_perf_monitor.increment_counter("underground_prop_candidates_found", found_delta)
    return bool(state.get("undergroundScanComplete", false))

func scan_underground_prop_candidates_from_volume_service(
    state: Dictionary,
    sample_budget: int,
    time_budget_ms := -1.0,
    budget_start_usec := 0
) -> bool:
    var candidates: Array = state.get("undergroundCandidates", []) if state.get("undergroundCandidates", []) is Array else []
    var max_candidates := 36
    if candidates.size() >= max_candidates:
        state["undergroundScanComplete"] = true
        state["undergroundCandidates"] = candidates
        return true
    var scan_state: Dictionary = state.get("undergroundVolumeFloorScan", {}) if state.get("undergroundVolumeFloorScan", {}) is Dictionary else {}
    if scan_state.is_empty():
        var chunk_key := Vector2i(int(state.get("cx", 0)), int(state.get("cz", 0)))
        if world_generation_system.has_method("begin_exposed_underground_floor_scan"):
            scan_state = world_generation_system.call("begin_exposed_underground_floor_scan", chunk_key, CHUNK_SIZE)
        else:
            state["undergroundScanComplete"] = true
            state["undergroundCandidates"] = candidates
            return true
    var found_count_before := candidates.size()
    var result: Dictionary = world_generation_system.call(
        "advance_exposed_underground_floor_scan",
        scan_state,
        maxi(1, int(sample_budget)),
        time_budget_ms,
        budget_start_usec
    )
    scan_state = result.get("state", scan_state) if result.get("state", scan_state) is Dictionary else scan_state
    state["undergroundVolumeFloorScan"] = scan_state
    var new_candidates: Array = result.get("newCandidates", []) if result.get("newCandidates", []) is Array else []
    for cell_value in new_candidates:
        if candidates.size() >= max_candidates:
            break
        if not (cell_value is Vector3i):
            continue
        var floor_cell: Vector3i = cell_value
        var roll := hash01("underground-prop-candidate:%d,%d,%d" % [floor_cell.x, floor_cell.y, floor_cell.z])
        if roll <= 0.18:
            candidates.append(floor_cell)
    state["undergroundCandidates"] = candidates
    if bool(result.get("complete", false)) or candidates.size() >= max_candidates:
        state["undergroundScanComplete"] = true
    if runtime_perf_monitor != null:
        var processed := int(result.get("processed", 0))
        if processed > 0:
            runtime_perf_monitor.increment_counter("underground_prop_cells_scanned", processed)
            runtime_perf_monitor.increment_counter("underground_prop_volume_service_scans")
            var found_delta := candidates.size() - found_count_before
            if found_delta > 0:
                runtime_perf_monitor.increment_counter("underground_prop_candidates_found", found_delta)
    return bool(state.get("undergroundScanComplete", false))

func underground_air_floor_cell_is_valid(air_cell: Vector3i) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_cell"):
        return false
    var air_sample: Dictionary = world_generation_system.call("sample_cell", air_cell)
    if bool(air_sample.get("solid", true)):
        return false
    if String(air_sample.get("biome", "")) != "underground_air":
        return false
    if String(air_sample.get("fluid", "")) != "":
        return false
    var head_sample: Dictionary = world_generation_system.call("sample_cell", air_cell + Vector3i(0, 1, 0))
    if bool(head_sample.get("solid", false)):
        return false
    return underground_prop_cell_is_valid(air_cell + Vector3i(0, -1, 0))

func underground_prop_cell_is_valid(solid_cell: Vector3i) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_cell"):
        return false
    var air_cell := solid_cell + Vector3i(0, 1, 0)
    var air_sample: Dictionary = world_generation_system.call("sample_cell", air_cell)
    if bool(air_sample.get("solid", true)):
        return false
    if String(air_sample.get("biome", "")) != "underground_air":
        return false
    if String(air_sample.get("fluid", "")) != "":
        return false
    var solid_sample: Dictionary = world_generation_system.call("sample_cell", solid_cell)
    var material := String(solid_sample.get("material", ""))
    if material == "" or material == "air" or material == "water" or material == "lava":
        return false
    return true

func spawn_underground_prop_attempt(state: Dictionary, solid_cell: Vector3i, rng: RandomNumberGenerator) -> void:
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    if chunk == null or not is_instance_valid(chunk):
        return
    var start_x := int(state.get("startX", int(state.get("cx", 0)) * CHUNK_SIZE))
    var start_z := int(state.get("startZ", int(state.get("cz", 0)) * CHUNK_SIZE))
    var prop_id := "%s:underground:%d,%d,%d" % [seed_text, solid_cell.x, solid_cell.y, solid_cell.z]
    if removed_props.has(prop_id):
        return
    var solid_sample: Dictionary = world_generation_system.call("sample_cell", solid_cell) if world_generation_system != null and world_generation_system.has_method("sample_cell") else {}
    var material := String(solid_sample.get("material", "stone"))
    var air_cell := solid_cell + Vector3i(0, 1, 0)
    var local_position := Vector3((float(solid_cell.x - start_x) + 0.5) * CELL, float(air_cell.y) * CELL + CELL * 0.04, (float(solid_cell.z - start_z) + 0.5) * CELL)
    var roll := rng.randf()
    if material in ["copperOre", "ironOre"]:
        make_ore_cluster(chunk, prop_id, local_position, material, rng, 1)
        return
    if roll < 0.12 and material in ["stone", "deepStone", "bedrock"]:
        var ore := "ironOre" if solid_cell.y < -22 and rng.randf() < 0.38 else "copperOre"
        make_ore_cluster(chunk, prop_id, local_position, ore, rng, 1)
    elif roll < 0.36:
        make_rock(chunk, prop_id, local_position, rng)
    elif roll < 0.48:
        make_forage(chunk, prop_id, local_position, "swamp", rng)

func process_chunk_detail_spawn_state(
    state: Dictionary,
    detail_attempt_budget: int,
    time_budget_ms := -1.0,
    budget_start_usec := 0
) -> bool:
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    if chunk == null or not is_instance_valid(chunk):
        return true
    var density: float = clampf(float(visual_quality.get("decorativeDensity", 0.74)), 0.0, 1.0)
    if density <= 0.01:
        return true
    if int(state.get("detailAttempts", -1)) < 0:
        state["detailAttempts"] = maxi(8, int(round(float(visual_quality.get("decorativeDetailCap", 72)) * density)))
    var rng := state.get("detailRng") as RandomNumberGenerator
    if rng == null:
        return true
    var batches: Dictionary = state.get("detailBatches", {}) if state.get("detailBatches", {}) is Dictionary else {}
    var attempts := int(state.get("detailAttempts", 0))
    var detail_index := int(state.get("detailIndex", 0))
    var processed := 0
    var start_usec := budget_start_usec if budget_start_usec > 0 else Time.get_ticks_usec()
    while detail_index < attempts and processed < maxi(1, detail_attempt_budget):
        if processed > 0 and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            break
        var detail_attempt_start: int = runtime_perf_monitor.begin_section("chunk_detail_prop_attempt") if runtime_perf_monitor != null else Time.get_ticks_usec()
        spawn_chunk_detail_attempt(state, detail_index, rng, batches)
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_detail_prop_attempt", detail_attempt_start)
        detail_index += 1
        processed += 1
    state["detailIndex"] = detail_index
    state["detailBatches"] = batches
    if detail_index < attempts:
        return false
    state["phase"] = "detail_batches"
    state["detailBatchKeys"] = batches.keys()
    state["detailBatchIndex"] = 0
    if chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
        return false
    return process_chunk_detail_batch_spawn_state(state, time_budget_ms, start_usec)

func process_chunk_detail_batch_spawn_state(state: Dictionary, time_budget_ms := -1.0, budget_start_usec := 0) -> bool:
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    if chunk == null or not is_instance_valid(chunk):
        return true
    var batches: Dictionary = state.get("detailBatches", {}) if state.get("detailBatches", {}) is Dictionary else {}
    if batches.is_empty():
        return true
    var keys: Array = state.get("detailBatchKeys", []) if state.get("detailBatchKeys", []) is Array else []
    if keys.is_empty():
        keys = batches.keys()
        state["detailBatchKeys"] = keys
    var root := valid_node3d_from_variant(state.get("detailBatchRoot"))
    if root == null or not is_instance_valid(root):
        root = Node3D.new()
        root.name = "DecorBatches"
        root.set_meta("kind", "decor")
        chunk.add_child(root)
        state["detailBatchRoot"] = root
    var start_usec := budget_start_usec if budget_start_usec > 0 else Time.get_ticks_usec()
    var batch_index := int(state.get("detailBatchIndex", 0))
    var processed := 0
    while batch_index < keys.size():
        if processed > 0 and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            state["detailBatchIndex"] = batch_index
            return false
        var detail_type_variant = keys[batch_index]
        var transforms: Array = batches.get(detail_type_variant, [])
        if not transforms.is_empty():
            var batch_start: int = runtime_perf_monitor.begin_section("chunk_detail_batch_spawn") if runtime_perf_monitor != null else Time.get_ticks_usec()
            spawn_detail_batch(root, String(detail_type_variant), transforms)
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_detail_batch_spawn", batch_start)
        batch_index += 1
        processed += 1
    state["detailBatchIndex"] = batch_index
    return true

func spawn_chunk_detail_attempt(state: Dictionary, _index: int, rng: RandomNumberGenerator, batches: Dictionary) -> void:
    var start_x := int(state.get("startX", int(state.get("cx", 0)) * CHUNK_SIZE))
    var start_z := int(state.get("startZ", int(state.get("cz", 0)) * CHUNK_SIZE))
    var x := start_x + 1 + rng.randi_range(0, CHUNK_SIZE - 2)
    var z := start_z + 1 + rng.randi_range(0, CHUNK_SIZE - 2)
    if natural_props_blocked_at_cell(x, z):
        return
    var surface_sample := surface_volume_spawn_sample_at_cell(x, z)
    if surface_sample.is_empty() or not bool(surface_sample.get("found", false)):
        return
    var h := float(surface_sample.get("height", 0.0))
    if h < WATER_LEVEL - 0.1 or h > 104.0:
        return
    var biome := String(surface_sample.get("biome", "plains"))
    if biome == "town":
        return
    var variation := height_variation_cell(x, z, 1)
    if variation > CELL * 1.35:
        return
    var local_position := Vector3((x - start_x) * CELL + rng.randf_range(-0.42, 0.42), h, (z - start_z) * CELL + rng.randf_range(-0.42, 0.42))
    add_detail_for_biome(batches, local_position, biome, h, rng)

func spawn_chunk_detail_batches_from_transforms(chunk: Node3D, batches: Dictionary) -> void:
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
        var surface_sample := surface_volume_spawn_sample_at_cell(x, z)
        if surface_sample.is_empty() or not bool(surface_sample.get("found", false)):
            continue
        var h := float(surface_sample.get("height", 0.0))
        if h < WATER_LEVEL - 0.1 or h > 104.0:
            continue
        var biome := String(surface_sample.get("biome", "plains"))
        if biome == "town":
            continue
        var variation := height_variation_cell(x, z, 1)
        if variation > CELL * 1.35:
            continue
        var local_position := Vector3((x - start_x) * CELL + rng.randf_range(-0.42, 0.42), h, (z - start_z) * CELL + rng.randf_range(-0.42, 0.42))
        add_detail_for_biome(batches, local_position, biome, h, rng)
    spawn_chunk_detail_batches_from_transforms(chunk, batches)

func natural_props_blocked_at_cell(x: int, z: int) -> bool:
    if structure_system != null and structure_system.has_method("blocks_natural_prop_at_cell"):
        return bool(structure_system.call("blocks_natural_prop_at_cell", x, z))
    return false

func surface_volume_spawn_sample_at_cell(cell_x: int, cell_z: int) -> Dictionary:
    var column_cell := Vector3i(cell_x, 0, cell_z)
    var fallback_height := surface_y_at_cell(column_cell)
    var fallback_biome := surface_biome_at_cell(column_cell)
    if world_generation_system == null or not world_generation_system.has_method("surface_projection_for_cell"):
        return {
            "found": true,
            "height": fallback_height,
            "biome": fallback_biome,
            "material": world_material_at_cell(Vector3i(cell_x, floori(fallback_height / CELL), cell_z)) if has_method("world_material_at_cell") else "",
            "authority": "height_compat"
        }
    if world_generation_system.has_method("terrain_volume_column_has_surface_projection_affecting_edits") \
        and not bool(world_generation_system.call("terrain_volume_column_has_surface_projection_affecting_edits", column_cell)):
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("surface_prop_generated_surface_fast_queries")
        return {
            "found": true,
            "height": fallback_height,
            "biome": fallback_biome,
            "material": surface_material_at_cell(column_cell) if has_method("surface_material_at_cell") else "",
            "solidCell": Vector3i(cell_x, floori(fallback_height / CELL), cell_z),
            "airCell": Vector3i(cell_x, floori(fallback_height / CELL) + 1, cell_z),
            "authority": "generated_surface_fast"
        }
    var start_cell := Vector3i(cell_x, floori(fallback_height / CELL), cell_z)
    var projection_start: int = runtime_perf_monitor.begin_section("surface_prop_volume_projection") if runtime_perf_monitor != null else Time.get_ticks_usec()
    var projection: Dictionary = world_generation_system.call("surface_projection_for_cell", start_cell, 24, 96)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("surface_prop_volume_projection", projection_start)
    if projection.is_empty() or not bool(projection.get("found", false)):
        return {
            "found": false,
            "height": fallback_height,
            "biome": fallback_biome,
            "authority": "terrain_volume_projection"
        }
    var solid_state: Dictionary = projection.get("solidState", {}) if projection.get("solidState", {}) is Dictionary else {}
    var air_state: Dictionary = projection.get("airState", {}) if projection.get("airState", {}) is Dictionary else {}
    var material := String(solid_state.get("material", ""))
    if material == "" or material == "air" or material == "water" or material == "lava":
        return {
            "found": false,
            "height": fallback_height,
            "biome": fallback_biome,
            "authority": "terrain_volume_projection"
        }
    if String(air_state.get("fluid", "")) != "":
        return {
            "found": false,
            "height": fallback_height,
            "biome": fallback_biome,
            "authority": "terrain_volume_projection"
        }
    var air_cell: Vector3i = projection.get("airCell", start_cell + Vector3i(0, 1, 0))
    var biome := String(solid_state.get("biome", fallback_biome))
    if biome == "" or biome == "underground" or biome == "deep_underground":
        biome = fallback_biome
    if runtime_perf_monitor != null:
        runtime_perf_monitor.increment_counter("surface_prop_volume_projection_queries")
    return {
        "found": true,
        "height": float(air_cell.y) * CELL,
        "biome": biome,
        "material": material,
        "solidCell": projection.get("solidCell", start_cell),
        "airCell": air_cell,
        "authority": "terrain_volume_projection"
    }

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
    var setup_started: int = runtime_perf_monitor.begin_section("rock_setup") if runtime_perf_monitor != null else Time.get_ticks_usec()
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
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("rock_setup", setup_started)

    var radius := float(spec.get("radius", 0.8))
    var visual_started: int = runtime_perf_monitor.begin_section("rock_visual") if runtime_perf_monitor != null else Time.get_ticks_usec()
    add_rock_visual(body, prop_id, biome, spec)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("rock_visual", visual_started)

    var collision_started: int = runtime_perf_monitor.begin_section("rock_collision") if runtime_perf_monitor != null else Time.get_ticks_usec()
    var shape := SphereShape3D.new()
    shape.radius = radius * 1.05
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.position.y = radius * 0.42
    body.add_child(collider)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("rock_collision", collision_started)
    var tree_started: int = runtime_perf_monitor.begin_section("rock_tree_attach") if runtime_perf_monitor != null else Time.get_ticks_usec()
    parent.add_child(body)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("rock_tree_attach", tree_started)
    if npc_system and npc_system.has_method("notify_navigation_prop_created"):
        var navigation_started: int = runtime_perf_monitor.begin_section("rock_navigation_notify") if runtime_perf_monitor != null else Time.get_ticks_usec()
        npc_system.notify_navigation_prop_created(prop_id, body)
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("rock_navigation_notify", navigation_started)
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
