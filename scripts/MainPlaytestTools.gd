extends "res://scripts/MainRuntimeTools.gd"

func build_chunk_mesh(cx: int, cz: int) -> Mesh:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    st.set_material(terrain_material)
    var start_x: int = cx * CHUNK_SIZE
    var start_z: int = cz * CHUNK_SIZE
    var skirt_bottom: float = min(MIN_HEIGHT - CELL * 2.0, WATER_LEVEL - CELL * 7.0)
    var height_cache := {}
    var color_cache := {}
    var normal_cache := {}
    for vz in range(-1, CHUNK_SIZE + 2):
        for vx in range(-1, CHUNK_SIZE + 2):
            var cell_x: int = start_x + vx
            var cell_z: int = start_z + vz
            var key := Vector2i(cell_x, cell_z)
            height_cache[key] = terrain_height_cell(cell_x, cell_z)
            if vx < 0 or vx > CHUNK_SIZE or vz < 0 or vz > CHUNK_SIZE:
                continue
            var color: Color = terrain_color_for_cell(cell_x, cell_z)
            var shade := 0.88 + noise01(ridge_noise, cell_x + 400, cell_z - 200) * 0.18
            color_cache[key] = color * shade
    for vz in range(CHUNK_SIZE + 1):
        for vx in range(CHUNK_SIZE + 1):
            var cell_x: int = start_x + vx
            var cell_z: int = start_z + vz
            normal_cache[Vector2i(cell_x, cell_z)] = terrain_normal_for_cell_cached(height_cache, cell_x, cell_z)
    for z in range(CHUNK_SIZE):
        for x in range(CHUNK_SIZE):
            var gx: int = start_x + x
            var gz: int = start_z + z
            var p00: Vector3 = terrain_vertex_local_cached(height_cache, gx, gz, start_x, start_z)
            var p10: Vector3 = terrain_vertex_local_cached(height_cache, gx + 1, gz, start_x, start_z)
            var p01: Vector3 = terrain_vertex_local_cached(height_cache, gx, gz + 1, start_x, start_z)
            var p11: Vector3 = terrain_vertex_local_cached(height_cache, gx + 1, gz + 1, start_x, start_z)
            add_cached_vertex(st, p00, color_cache, normal_cache, gx, gz)
            add_cached_vertex(st, p01, color_cache, normal_cache, gx, gz + 1)
            add_cached_vertex(st, p10, color_cache, normal_cache, gx + 1, gz)
            add_cached_vertex(st, p10, color_cache, normal_cache, gx + 1, gz)
            add_cached_vertex(st, p01, color_cache, normal_cache, gx, gz + 1)
            add_cached_vertex(st, p11, color_cache, normal_cache, gx + 1, gz + 1)
    add_chunk_skirts(st, start_x, start_z, skirt_bottom)
    return st.commit()

func terrain_vertex_local_cached(height_cache: Dictionary, cell_x: int, cell_z: int, origin_cell_x: int, origin_cell_z: int) -> Vector3:
    var key := Vector2i(cell_x, cell_z)
    var y: float = float(height_cache[key]) if height_cache.has(key) else terrain_height_cell(cell_x, cell_z)
    return Vector3((cell_x - origin_cell_x) * CELL, y, (cell_z - origin_cell_z) * CELL)

func add_cached_vertex(st: SurfaceTool, point: Vector3, color_cache: Dictionary, normal_cache: Dictionary, cell_x: int, cell_z: int) -> void:
    var key := Vector2i(cell_x, cell_z)
    st.set_normal(normal_cache.get(key, Vector3.UP))
    st.set_color(color_cache.get(key, BIOME_COLORS["plains"]))
    st.add_vertex(point)

func add_vertex(st: SurfaceTool, point: Vector3, cell_x: int, cell_z: int) -> void:
    var color: Color = terrain_color_for_cell(cell_x, cell_z)
    var shade := 0.88 + noise01(ridge_noise, cell_x + 400, cell_z - 200) * 0.18
    st.set_normal(terrain_normal_for_cell(cell_x, cell_z))
    st.set_color(color * shade)
    st.add_vertex(point)

func terrain_color_for_cell(cell_x: int, cell_z: int) -> Color:
    if structure_system != null and structure_system.has_method("terrain_material_override_for_cell"):
        var override_id := String(structure_system.call("terrain_material_override_for_cell", cell_x, cell_z))
        if override_id == "stone":
            return Color(0.32, 0.37, 0.36)
    return BIOME_COLORS.get(biome_at_cell(cell_x, cell_z), BIOME_COLORS["plains"])

func terrain_normal_for_cell_cached(height_cache: Dictionary, cell_x: int, cell_z: int) -> Vector3:
    var left := terrain_height_from_cache(height_cache, cell_x - 1, cell_z)
    var right := terrain_height_from_cache(height_cache, cell_x + 1, cell_z)
    var back := terrain_height_from_cache(height_cache, cell_x, cell_z - 1)
    var forward := terrain_height_from_cache(height_cache, cell_x, cell_z + 1)
    return Vector3(left - right, CELL * 2.0, back - forward).normalized()

func terrain_normal_for_cell(cell_x: int, cell_z: int) -> Vector3:
    var left := terrain_height_cell(cell_x - 1, cell_z)
    var right := terrain_height_cell(cell_x + 1, cell_z)
    var back := terrain_height_cell(cell_x, cell_z - 1)
    var forward := terrain_height_cell(cell_x, cell_z + 1)
    return Vector3(left - right, CELL * 2.0, back - forward).normalized()

func terrain_height_from_cache(height_cache: Dictionary, cell_x: int, cell_z: int) -> float:
    var key := Vector2i(cell_x, cell_z)
    return float(height_cache[key]) if height_cache.has(key) else terrain_height_cell(cell_x, cell_z)

func terrain_vertex_local(cell_x: int, cell_z: int, origin_cell_x: int, origin_cell_z: int) -> Vector3:
    return Vector3((cell_x - origin_cell_x) * CELL, terrain_height_cell(cell_x, cell_z), (cell_z - origin_cell_z) * CELL)

func add_chunk_skirts(st: SurfaceTool, start_x: int, start_z: int, bottom_y: float) -> void:
    var end_x := start_x + CHUNK_SIZE
    var end_z := start_z + CHUNK_SIZE
    for x in range(start_x, end_x):
        add_skirt_quad(st, x, start_z, x + 1, start_z, start_x, start_z, bottom_y)
        add_skirt_quad(st, x + 1, end_z, x, end_z, start_x, start_z, bottom_y)
    for z in range(start_z, end_z):
        add_skirt_quad(st, start_x, z + 1, start_x, z, start_x, start_z, bottom_y)
        add_skirt_quad(st, end_x, z, end_x, z + 1, start_x, start_z, bottom_y)

func add_skirt_quad(
    st: SurfaceTool,
    ax: int,
    az: int,
    bx: int,
    bz: int,
    origin_x: int,
    origin_z: int,
    bottom_y: float
) -> void:
    var top_a := terrain_vertex_local(ax, az, origin_x, origin_z)
    var top_b := terrain_vertex_local(bx, bz, origin_x, origin_z)
    var bottom_a := Vector3((ax - origin_x) * CELL, bottom_y, (az - origin_z) * CELL)
    var bottom_b := Vector3((bx - origin_x) * CELL, bottom_y, (bz - origin_z) * CELL)
    var normal := skirt_outward_normal(ax, az, bx, bz, origin_x, origin_z)
    add_skirt_vertex(st, top_a, ax, az, normal)
    add_skirt_vertex(st, bottom_a, ax, az, normal)
    add_skirt_vertex(st, top_b, bx, bz, normal)
    add_skirt_vertex(st, top_b, bx, bz, normal)
    add_skirt_vertex(st, bottom_a, ax, az, normal)
    add_skirt_vertex(st, bottom_b, bx, bz, normal)

func add_skirt_vertex(st: SurfaceTool, point: Vector3, cell_x: int, cell_z: int, normal: Vector3) -> void:
    var color: Color = BIOME_COLORS.get(biome_at_cell(cell_x, cell_z), BIOME_COLORS["plains"])
    var shade := 0.88 + noise01(ridge_noise, cell_x + 400, cell_z - 200) * 0.18
    st.set_normal(normal)
    st.set_color(color * shade)
    st.add_vertex(point)

func skirt_outward_normal(ax: int, az: int, bx: int, bz: int, origin_x: int, origin_z: int) -> Vector3:
    var end_x := origin_x + CHUNK_SIZE
    var end_z := origin_z + CHUNK_SIZE
    if ax == origin_x and bx == origin_x:
        return Vector3.LEFT
    if ax == end_x and bx == end_x:
        return Vector3.RIGHT
    if az == origin_z and bz == origin_z:
        return Vector3.BACK
    if az == end_z and bz == end_z:
        return Vector3.FORWARD
    return Vector3.UP

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
        var h := terrain_height_cell(x, z)
        if h < WATER_LEVEL + 1.0 or h > 92.0:
            continue
        var biome := biome_at_cell(x, z)
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
        var h := terrain_height_cell(x, z)
        if h < WATER_LEVEL - 0.1 or h > 104.0:
            continue
        var biome := biome_at_cell(x, z)
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
    return biome_at_cell(world_to_cell(world_position.x), world_to_cell(world_position.z))

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
