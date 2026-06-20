extends Node3D

const PlayerController := preload("res://scripts/PlayerController.gd")

const CELL := 1.35
const CHUNK_SIZE := 24
const RENDER_DISTANCE := 2
const MIN_HEIGHT := 4.0
const MAX_HEIGHT := 120.0
const WATER_LEVEL := 11.1
const DAY_LENGTH := 260.0
const INTERACT_RANGE := 10.5

const BIOME_COLORS := {
    "ocean": Color(0.24, 0.58, 0.68),
    "beach": Color(0.82, 0.72, 0.46),
    "plains": Color(0.48, 0.76, 0.34),
    "forest": Color(0.31, 0.60, 0.31),
    "taiga": Color(0.28, 0.52, 0.43),
    "swamp": Color(0.34, 0.43, 0.25),
    "desert": Color(0.82, 0.66, 0.36),
    "savanna": Color(0.66, 0.67, 0.34),
    "alpine": Color(0.50, 0.55, 0.53),
    "tundra": Color(0.58, 0.66, 0.58),
    "snow": Color(0.86, 0.91, 0.90)
}

const HOTBAR := ["woodBlock", "stoneBlock", "dirtBlock", "glass", "cobblestonePath"]
const BLOCK_LABELS := {
    "woodBlock": "Wood",
    "stoneBlock": "Stone",
    "dirtBlock": "Dirt",
    "glass": "Glass",
    "cobblestonePath": "Path"
}

var seed_text := "atlas-1492"
var seed_hash := 1
var height_noise: FastNoiseLite
var ridge_noise: FastNoiseLite
var flat_noise: FastNoiseLite
var moisture_noise: FastNoiseLite
var temp_noise: FastNoiseLite

var chunk_root: Node3D
var block_root: Node3D
var prop_root: Node3D
var water: MeshInstance3D
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var player: CharacterBody3D

var terrain_material: StandardMaterial3D
var materials := {}
var chunks := {}
var height_edits := {}
var blocks := {}
var removed_props := {}
var inventory := {
    "woodBlock": 32,
    "stoneBlock": 32,
    "dirtBlock": 48,
    "glass": 16,
    "cobblestonePath": 24,
    "logs": 0,
    "stones": 0
}
var selected_slot := 0
var last_center_chunk := Vector2i(999999, 999999)
var time_of_day := 0.32

var hud_info: Label
var hud_hotbar: Label
var hud_target: Label

func _ready() -> void:
    seed_hash = hash_string(seed_text)
    setup_noise()
    setup_materials()
    setup_environment()

    chunk_root = Node3D.new()
    chunk_root.name = "Chunks"
    add_child(chunk_root)
    prop_root = Node3D.new()
    prop_root.name = "Props"
    add_child(prop_root)
    block_root = Node3D.new()
    block_root.name = "Blocks"
    add_child(block_root)

    setup_player()
    setup_hud()
    update_chunks(true)
    update_hud("Godot slice ready")

func setup_noise() -> void:
    height_noise = make_noise(17, 0.009, 5)
    ridge_noise = make_noise(43, 0.035, 4)
    flat_noise = make_noise(71, 0.004, 3)
    moisture_noise = make_noise(107, 0.006, 3)
    temp_noise = make_noise(131, 0.005, 3)

func make_noise(salt: int, frequency: float, octaves: int) -> FastNoiseLite:
    var noise := FastNoiseLite.new()
    noise.seed = int((seed_hash + salt * 7919) & 0x7fffffff)
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    noise.frequency = frequency
    noise.fractal_octaves = octaves
    noise.fractal_gain = 0.5
    noise.fractal_lacunarity = 2.0
    return noise

func setup_materials() -> void:
    terrain_material = StandardMaterial3D.new()
    terrain_material.vertex_color_use_as_albedo = true
    terrain_material.roughness = 0.86

    materials["woodBlock"] = make_material(Color(0.60, 0.36, 0.17), 0.82)
    materials["stoneBlock"] = make_material(Color(0.52, 0.57, 0.54), 0.90)
    materials["dirtBlock"] = make_material(Color(0.39, 0.27, 0.16), 0.92)
    materials["glass"] = make_material(Color(0.55, 0.82, 0.92, 0.42), 0.12, true)
    materials["cobblestonePath"] = make_material(Color(0.42, 0.46, 0.42), 0.88)
    materials["trunk"] = make_material(Color(0.33, 0.18, 0.10), 0.86)
    materials["leaf"] = make_material(Color(0.17, 0.45, 0.19), 0.78)
    materials["rock"] = make_material(Color(0.40, 0.45, 0.43), 0.92)
    materials["water"] = make_material(Color(0.30, 0.70, 0.78, 0.46), 0.20, true)

func make_material(color: Color, roughness: float = 0.82, transparent: bool = false) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = roughness
    if transparent:
        material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    return material

func setup_environment() -> void:
    var world_env := WorldEnvironment.new()
    var env := Environment.new()
    env.background_mode = Environment.BG_COLOR
    env.background_color = Color(0.66, 0.84, 0.87)
    env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    env.ambient_light_color = Color(0.78, 0.82, 0.76)
    env.ambient_light_energy = 0.52
    world_env.environment = env
    add_child(world_env)

    sun = DirectionalLight3D.new()
    sun.name = "Sun"
    sun.light_color = Color(1.0, 0.88, 0.62)
    sun.light_energy = 2.25
    sun.shadow_enabled = true
    add_child(sun)

    moon = DirectionalLight3D.new()
    moon.name = "Moon"
    moon.light_color = Color(0.58, 0.68, 1.0)
    moon.light_energy = 0.10
    moon.shadow_enabled = false
    add_child(moon)

    var plane := PlaneMesh.new()
    plane.size = Vector2(3000.0, 3000.0)
    water = MeshInstance3D.new()
    water.name = "Water"
    water.mesh = plane
    water.material_override = materials["water"]
    water.position.y = WATER_LEVEL
    add_child(water)
    update_sky(0.0)

func setup_player() -> void:
    player = CharacterBody3D.new()
    player.name = "Player"
    player.set_script(PlayerController)
    player.main = self
    player.position = Vector3(0.0, height_at_world(0.0, 28.0) + 4.0, 28.0)
    add_child(player)

func setup_hud() -> void:
    var layer := CanvasLayer.new()
    layer.name = "HUD"
    add_child(layer)

    var panel := VBoxContainer.new()
    panel.position = Vector2(16, 14)
    panel.custom_minimum_size = Vector2(360, 120)
    layer.add_child(panel)

    hud_info = Label.new()
    hud_info.add_theme_font_size_override("font_size", 16)
    panel.add_child(hud_info)

    hud_target = Label.new()
    hud_target.add_theme_font_size_override("font_size", 14)
    panel.add_child(hud_target)

    hud_hotbar = Label.new()
    hud_hotbar.add_theme_font_size_override("font_size", 16)
    hud_hotbar.position = Vector2(330, 664)
    layer.add_child(hud_hotbar)

    var help := Label.new()
    help.add_theme_font_size_override("font_size", 13)
    help.position = Vector2(16, 666)
    help.text = "WASD move | Space jump | Shift sprint | LMB destroy | RMB place | 1-5 hotbar | Esc mouse"
    layer.add_child(help)

func _process(delta: float) -> void:
    if player:
        update_chunks(false)
        water.position.x = player.position.x
        water.position.z = player.position.z
    update_sky(delta)
    update_hud()

func update_sky(delta: float) -> void:
    time_of_day = fposmod(time_of_day + delta / DAY_LENGTH, 1.0)
    var angle := time_of_day * TAU
    sun.rotation = Vector3(-sin(angle) * 1.1 - 0.45, angle, 0.0)
    moon.rotation = Vector3(sin(angle) * 1.1 + 0.45, angle + PI, 0.0)
    var day: float = clamp(sin(angle) * 0.5 + 0.5, 0.0, 1.0)
    sun.light_energy = lerp(0.08, 2.35, day)
    moon.light_energy = lerp(0.34, 0.04, day)

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
        player.handle_mouse_motion(event.relative)
    elif event is InputEventMouseButton and event.pressed:
        if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
            Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
            return
        if event.button_index == MOUSE_BUTTON_LEFT:
            destroy_target()
        elif event.button_index == MOUSE_BUTTON_RIGHT:
            place_selected_block()
    elif event is InputEventKey and event.pressed and not event.echo:
        if event.keycode == KEY_ESCAPE:
            Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
        elif event.keycode >= KEY_1 and event.keycode <= KEY_5:
            selected_slot = int(event.keycode - KEY_1)
            update_hud("Selected %s" % BLOCK_LABELS[HOTBAR[selected_slot]])

func update_hud(message: String = "") -> void:
    if not player:
        return
    var cell := Vector2i(world_to_cell(player.position.x), world_to_cell(player.position.z))
    var biome := biome_at_cell(cell.x, cell.y)
    hud_info.text = "Voxel Biome World Godot\nseed %s | %s | %d chunks\n%.0f, %.0f" % [
        seed_text,
        biome.capitalize(),
        chunks.size(),
        player.position.x,
        player.position.z
    ]
    if message != "":
        hud_target.text = message
    var parts: Array[String] = []
    for i in HOTBAR.size():
        var item: String = HOTBAR[i]
        var selected: String = "[" if i == selected_slot else " "
        var close: String = "]" if i == selected_slot else " "
        parts.append("%s%d %s x%d%s" % [selected, i + 1, BLOCK_LABELS[item], int(inventory[item]), close])
    hud_hotbar.text = "  ".join(parts)

func update_chunks(force: bool = false) -> void:
    var center := world_to_chunk(player.position.x, player.position.z)
    if not force and center == last_center_chunk:
        return
    last_center_chunk = center

    var needed := {}
    for dz in range(-RENDER_DISTANCE, RENDER_DISTANCE + 1):
        for dx in range(-RENDER_DISTANCE, RENDER_DISTANCE + 1):
            var chunk_key := Vector2i(center.x + dx, center.y + dz)
            needed[chunk_key] = true
            if not chunks.has(chunk_key):
                create_chunk(chunk_key.x, chunk_key.y)

    for key in chunks.keys():
        if not needed.has(key):
            chunks[key].queue_free()
            chunks.erase(key)

func create_chunk(cx: int, cz: int) -> void:
    var chunk := Node3D.new()
    chunk.name = "Chunk_%d_%d" % [cx, cz]
    chunk_root.add_child(chunk)

    var mesh := build_chunk_mesh(cx, cz)
    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "TerrainMesh"
    mesh_instance.mesh = mesh
    chunk.add_child(mesh_instance)

    var body := StaticBody3D.new()
    body.name = "TerrainBody"
    body.set_meta("kind", "terrain")
    body.set_meta("chunk", Vector2i(cx, cz))
    var collision := CollisionShape3D.new()
    collision.shape = mesh.create_trimesh_shape()
    body.add_child(collision)
    chunk.add_child(body)

    spawn_chunk_props(chunk, cx, cz)
    chunks[Vector2i(cx, cz)] = chunk

func rebuild_chunk(cx: int, cz: int) -> void:
    var key := Vector2i(cx, cz)
    if chunks.has(key):
        chunks[key].queue_free()
        chunks.erase(key)
    create_chunk(cx, cz)

func rebuild_chunks_around_cell(cell: Vector2i) -> void:
    var center := cell_to_chunk(cell.x, cell.y)
    for dz in range(-1, 2):
        for dx in range(-1, 2):
            var key := Vector2i(center.x + dx, center.y + dz)
            if chunks.has(key):
                rebuild_chunk(key.x, key.y)

func build_chunk_mesh(cx: int, cz: int) -> Mesh:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    st.set_material(terrain_material)
    var start_x := cx * CHUNK_SIZE
    var start_z := cz * CHUNK_SIZE
    for z in range(CHUNK_SIZE):
        for x in range(CHUNK_SIZE):
            var gx := start_x + x
            var gz := start_z + z
            var p00 := terrain_vertex(gx, gz)
            var p10 := terrain_vertex(gx + 1, gz)
            var p01 := terrain_vertex(gx, gz + 1)
            var p11 := terrain_vertex(gx + 1, gz + 1)
            add_vertex(st, p00)
            add_vertex(st, p01)
            add_vertex(st, p10)
            add_vertex(st, p10)
            add_vertex(st, p01)
            add_vertex(st, p11)
    st.generate_normals()
    return st.commit()

func add_vertex(st: SurfaceTool, point: Vector3) -> void:
    var cell := Vector2i(world_to_cell(point.x), world_to_cell(point.z))
    var color: Color = BIOME_COLORS.get(biome_at_cell(cell.x, cell.y), BIOME_COLORS["plains"])
    var shade := 0.88 + noise01(ridge_noise, cell.x + 400, cell.y - 200) * 0.18
    st.set_color(color * shade)
    st.add_vertex(point)

func terrain_vertex(cell_x: int, cell_z: int) -> Vector3:
    return Vector3(cell_x * CELL, terrain_height_cell(cell_x, cell_z), cell_z * CELL)

func spawn_chunk_props(chunk: Node3D, cx: int, cz: int) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = hash_string("%s:props:%d,%d" % [seed_text, cx, cz])
    var start_x := cx * CHUNK_SIZE
    var start_z := cz * CHUNK_SIZE
    for i in range(20):
        var x := start_x + 2 + rng.randi_range(0, CHUNK_SIZE - 4)
        var z := start_z + 2 + rng.randi_range(0, CHUNK_SIZE - 4)
        var prop_id := "%s:%d,%d:%d" % [seed_text, x, z, i]
        if removed_props.has(prop_id):
            continue
        var h := terrain_height_cell(x, z)
        if h < WATER_LEVEL + 1.0 or h > 92.0:
            continue
        var biome := biome_at_cell(x, z)
        if rng.randf() < rock_chance(biome, h):
            make_rock(chunk, prop_id, Vector3(x * CELL, h, z * CELL), rng)
        elif rng.randf() < tree_chance(biome):
            make_tree(chunk, prop_id, Vector3(x * CELL, h, z * CELL), biome, rng)

func make_tree(parent: Node, prop_id: String, position: Vector3, biome: String, rng: RandomNumberGenerator) -> void:
    var body := StaticBody3D.new()
    body.name = "Tree"
    body.position = position
    body.rotation.y = rng.randf() * TAU
    body.set_meta("kind", "prop")
    body.set_meta("prop_id", prop_id)
    body.set_meta("drop", "logs")

    var height := 3.0 + rng.randf() * 2.2
    if biome == "taiga" or biome == "snow" or biome == "tundra":
        height += 1.6

    var trunk_mesh := CylinderMesh.new()
    trunk_mesh.top_radius = 0.16
    trunk_mesh.bottom_radius = 0.28
    trunk_mesh.height = height
    trunk_mesh.radial_segments = 7
    var trunk := MeshInstance3D.new()
    trunk.mesh = trunk_mesh
    trunk.material_override = materials["trunk"]
    trunk.position.y = height * 0.5
    body.add_child(trunk)

    var trunk_shape := CylinderShape3D.new()
    trunk_shape.radius = 0.36
    trunk_shape.height = height
    var collider := CollisionShape3D.new()
    collider.shape = trunk_shape
    collider.position.y = height * 0.5
    body.add_child(collider)

    var clumps := 3 if biome == "taiga" or biome == "snow" or biome == "tundra" else 5
    for c in range(clumps):
        var leaf_mesh := SphereMesh.new()
        leaf_mesh.radius = 0.82 + rng.randf() * 0.35
        leaf_mesh.height = leaf_mesh.radius * 1.25
        var leaf := MeshInstance3D.new()
        leaf.mesh = leaf_mesh
        leaf.material_override = materials["leaf"]
        var angle := rng.randf() * TAU
        var spread := 0.0 if c == 0 else 0.42 + rng.randf() * 0.55
        leaf.position = Vector3(cos(angle) * spread, height + 0.3 + rng.randf() * 0.65, sin(angle) * spread)
        leaf.scale = Vector3(1.2 + rng.randf() * 0.4, 0.68 + rng.randf() * 0.22, 1.2 + rng.randf() * 0.4)
        body.add_child(leaf)

    parent.add_child(body)

func make_rock(parent: Node, prop_id: String, position: Vector3, rng: RandomNumberGenerator) -> void:
    var body := StaticBody3D.new()
    body.name = "Rock"
    body.position = position
    body.rotation.y = rng.randf() * TAU
    body.set_meta("kind", "prop")
    body.set_meta("prop_id", prop_id)
    body.set_meta("drop", "stones")

    var radius := 0.55 + rng.randf() * 0.7
    var rock_mesh := SphereMesh.new()
    rock_mesh.radius = radius
    rock_mesh.height = radius * (0.75 + rng.randf() * 0.8)
    var rock := MeshInstance3D.new()
    rock.mesh = rock_mesh
    rock.material_override = materials["rock"]
    rock.position.y = radius * 0.42
    rock.scale = Vector3(1.15 + rng.randf() * 0.6, 0.58 + rng.randf() * 0.72, 1.0 + rng.randf() * 0.5)
    body.add_child(rock)

    var shape := SphereShape3D.new()
    shape.radius = radius * 1.05
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.position.y = radius * 0.42
    body.add_child(collider)
    parent.add_child(body)

func place_selected_block() -> void:
    var hit: Dictionary = player.view_ray(INTERACT_RANGE)
    if hit.is_empty():
        update_hud("No placement target")
        return
    var block_type: String = HOTBAR[selected_slot]
    if inventory.get(block_type, 0) <= 0:
        update_hud("%s: none left" % BLOCK_LABELS[block_type])
        return
    var place_pos: Vector3 = hit["position"] + hit["normal"] * (CELL * 0.55)
    var cell := Vector3i(roundi(place_pos.x / CELL), roundi(place_pos.y / CELL), roundi(place_pos.z / CELL))
    if blocks.has(cell):
        update_hud("Blocked")
        return
    create_block(cell, block_type)
    inventory[block_type] -= 1
    update_hud("Placed %s" % BLOCK_LABELS[block_type])

func create_block(cell: Vector3i, block_type: String) -> void:
    var body := StaticBody3D.new()
    body.name = "Block_%s_%d_%d_%d" % [block_type, cell.x, cell.y, cell.z]
    body.position = Vector3(cell.x * CELL, cell.y * CELL, cell.z * CELL)
    body.set_meta("kind", "block")
    body.set_meta("cell", cell)
    body.set_meta("block_type", block_type)

    var mesh := BoxMesh.new()
    mesh.size = Vector3.ONE * CELL * 0.96
    var mesh_instance := MeshInstance3D.new()
    mesh_instance.mesh = mesh
    mesh_instance.material_override = materials[block_type]
    body.add_child(mesh_instance)

    var shape := BoxShape3D.new()
    shape.size = Vector3.ONE * CELL * 0.96
    var collider := CollisionShape3D.new()
    collider.shape = shape
    body.add_child(collider)

    block_root.add_child(body)
    blocks[cell] = body

func destroy_target() -> void:
    var hit: Dictionary = player.view_ray(INTERACT_RANGE)
    if hit.is_empty():
        return
    var collider: Node = hit["collider"]
    if not collider or not collider.has_meta("kind"):
        return
    var kind := String(collider.get_meta("kind"))
    if kind == "terrain":
        var sample_pos: Vector3 = hit.position - hit.normal * (CELL * 0.35)
        var cell := Vector2i(world_to_cell(sample_pos.x), world_to_cell(sample_pos.z))
        var old_height := terrain_height_cell(cell.x, cell.y)
        height_edits[cell] = max(MIN_HEIGHT, old_height - CELL)
        rebuild_chunks_around_cell(cell)
        update_hud("Dug %s" % biome_at_cell(cell.x, cell.y).capitalize())
    elif kind == "block":
        var block_cell: Vector3i = collider.get_meta("cell")
        var block_type: String = collider.get_meta("block_type")
        blocks.erase(block_cell)
        collider.queue_free()
        inventory[block_type] = inventory.get(block_type, 0) + 1
        update_hud("Recovered %s" % BLOCK_LABELS.get(block_type, block_type))
    elif kind == "prop":
        var prop_id: String = collider.get_meta("prop_id")
        var drop: String = collider.get_meta("drop")
        removed_props[prop_id] = true
        collider.queue_free()
        if drop == "logs":
            inventory["woodBlock"] += 4
            inventory["logs"] += 3
            update_hud("Tree dropped logs")
        else:
            inventory["stoneBlock"] += 3
            inventory["stones"] += 4
            update_hud("Rock dropped stones")

func height_at_world(x: float, z: float) -> float:
    return terrain_height_cell(world_to_cell(x), world_to_cell(z))

func terrain_height_cell(x: int, z: int) -> float:
    var key := Vector2i(x, z)
    if height_edits.has(key):
        return float(height_edits[key])
    return base_height_cell(x, z)

func base_height_cell(x: int, z: int) -> float:
    var continent: float = noise01(height_noise, x, z)
    var ridges: float = abs(noise01(ridge_noise, x - 200, z + 510) - 0.5) * 2.0
    var flat_mask: float = smoothstep_range(noise01(flat_noise, x - 8400, z + 7200), 0.50, 0.78)
    var mountain_mask: float = smoothstep_range(noise01(height_noise, x + 1800, z - 1500), 0.60, 0.88)
    var peak_mask: float = smoothstep_range(noise01(ridge_noise, x - 3900, z + 2600), 0.70, 0.93)
    var rugged: float = continent * 18.0 + pow(ridges, 1.55) * (11.0 + mountain_mask * 42.0) + pow(peak_mask, 2.0) * 28.0
    var flat: float = continent * 12.0 + noise01(height_noise, x + 12000, z - 12200) * 2.8
    var raw: float = MIN_HEIGHT + lerp(rugged, flat, flat_mask)
    var terrace: float = lerp(CELL, CELL * 2.5, flat_mask)
    return clamp(round(raw / terrace) * terrace, MIN_HEIGHT, MAX_HEIGHT)

func biome_at_cell(x: int, z: int) -> String:
    var h: float = terrain_height_cell(x, z)
    var moisture: float = noise01(moisture_noise, x - 1200, z + 800)
    var temp: float = clamp(0.42 + noise01(temp_noise, x + 1500, z - 900) * 0.46 - abs(z) / 1300.0 - max(0.0, h - 38.0) / 180.0, 0.0, 1.0)
    if h < WATER_LEVEL + 0.3:
        return "ocean"
    if h < WATER_LEVEL + 1.7:
        return "beach"
    if h > 78.0:
        return "snow"
    if h > 56.0:
        return "alpine" if temp < 0.48 else "tundra"
    if h > 42.0 and moisture < 0.5:
        return "alpine"
    if moisture > 0.78 and h < WATER_LEVEL + 6.0:
        return "swamp"
    if temp > 0.68 and moisture < 0.32:
        return "desert"
    if temp > 0.61 and moisture < 0.48:
        return "savanna"
    if temp < 0.33 and moisture > 0.42:
        return "taiga"
    if moisture > 0.64:
        return "forest"
    return "plains"

func tree_chance(biome: String) -> float:
    match biome:
        "forest":
            return 0.58
        "taiga":
            return 0.48
        "plains":
            return 0.22
        "swamp":
            return 0.26
        "savanna":
            return 0.10
        _:
            return 0.02

func rock_chance(biome: String, height: float) -> float:
    var base := 0.10
    match biome:
        "alpine", "tundra", "snow":
            base = 0.55
        "desert", "savanna":
            base = 0.36
        "plains":
            base = 0.16
        "forest", "taiga":
            base = 0.12
        _:
            base = 0.08
    if height > 42.0:
        base += 0.12
    return base

func noise01(noise: FastNoiseLite, x: float, z: float) -> float:
    return noise.get_noise_2d(x, z) * 0.5 + 0.5

func smoothstep_range(value: float, low: float, high: float) -> float:
    if high == low:
        return 1.0 if value >= high else 0.0
    var t: float = clamp((value - low) / (high - low), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)

func hash_string(text: String) -> int:
    var h := 2166136261
    for i in range(text.length()):
        h = int((h ^ text.unicode_at(i)) * 16777619) & 0xffffffff
    return h

func world_to_cell(value: float) -> int:
    return roundi(value / CELL)

func cell_to_chunk(x: int, z: int) -> Vector2i:
    return Vector2i(floori(float(x) / float(CHUNK_SIZE)), floori(float(z) / float(CHUNK_SIZE)))

func world_to_chunk(x: float, z: float) -> Vector2i:
    return cell_to_chunk(world_to_cell(x), world_to_cell(z))
