extends RefCounted
class_name TutorialSceneBuilder

const NpcVisualFactoryScript := preload("res://scripts/NpcVisualFactory.gd")
const LocalLightRigScript := preload("res://scripts/LocalLightRig.gd")
const CELL := 1.35
const SAFE_RADIUS_CELLS := 24
const FENCE_RADIUS_CELLS := 25

var system
var main
var npc_visual_factory

func setup(tutorial_system) -> void:
    system = tutorial_system
    main = system.main
    npc_visual_factory = NpcVisualFactoryScript.new()
    npc_visual_factory.setup(main)
    system.npc_root = Node3D.new()
    system.npc_root.name = "TutorialNPCs"
    system.add_child(system.npc_root)
    system.light_root = Node3D.new()
    system.light_root.name = "TutorialLights"
    system.add_child(system.light_root)

func ensure_town_generated() -> void:
    if main == null or system.town.is_empty() or main.structure_system == null:
        return
    main.structure_system.update_around(Vector2i(int(system.town.get("centerX", 0)), int(system.town.get("centerZ", 0))))

func ensure_starter_bed() -> void:
    if main == null or system.town.is_empty() or main.structure_system == null:
        return
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    var bed_cell := Vector2i(center_x - 14, center_z - 8)
    clear_overlapping_starter_beds(bed_cell, level)
    main.structure_system.place_utility(bed_cell.x, bed_cell.y, level, "bed", {
        "generatedTier": "town",
        "cacheKey": "%s:tutorial-bed:%d,%d" % [main.seed_text, center_x, center_z]
    })

func clear_overlapping_starter_beds(center_cell: Vector2i, level: float) -> void:
    if main == null:
        return
    var tutorial_key_prefix := "%s:tutorial-bed:" % main.seed_text
    var expected_world_y: float = level + float(main.CELL) * 0.48
    for key in main.blocks.keys().duplicate():
        var body := main.blocks[key] as Node3D
        if body == null or not is_instance_valid(body) or not body.has_meta("block_type"):
            continue
        if String(body.get_meta("block_type", "")) != "bed" or bool(body.get_meta("player_placed", false)):
            continue
        var cell: Vector3i = body.get_meta("cell", Vector3i.ZERO)
        var same_footprint: bool = abs(cell.x - center_cell.x) <= 1 and abs(cell.z - center_cell.y) <= 1
        var same_level: bool = absf(body.global_position.y - expected_world_y) <= float(main.CELL) * 1.2
        var is_tutorial_bed := String(body.get_meta("cacheKey", "")).begins_with(tutorial_key_prefix)
        if (same_footprint and same_level) or is_tutorial_bed:
            main.blocks.erase(key)
            body.queue_free()

func ensure_starter_shelter() -> void:
    if main == null or system.town.is_empty() or main.structure_system == null:
        return
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    reserve_starter_shelter_volume(center_x, center_z, level)
    var roof_center := Vector2i(center_x - 13, center_z - 10)
    for dz in range(-1, 2):
        for dx in range(-1, 2):
            var cell := roof_center + Vector2i(dx, dz)
            main.structure_system.place_structure_block(cell.x, cell.y, level, 3, "woodBlock", {
                "generatedTier": "town",
                "cacheKey": "%s:tutorial-starter-roof:%d,%d" % [main.seed_text, cell.x, cell.y]
            })

func reserve_starter_shelter_volume(center_x: int, center_z: int, level: float) -> void:
    if main == null or main.structure_system == null:
        return
    if not main.structure_system.has_method("reserve_structure_terrain_footprint"):
        return
    var base_x := center_x - 16
    var base_z := center_z - 14
    var width := 7
    var depth := 8
    main.structure_system.reserve_structure_terrain_footprint(
        base_x,
        base_z,
        level,
        width,
        depth,
        4,
        "tutorial_starter_shelter",
        "stone"
    )
    refresh_starter_shelter_terrain(base_x, base_z, width, depth)

func refresh_starter_shelter_terrain(base_x: int, base_z: int, width: int, depth: int) -> void:
    if main == null or not main.has_method("rebuild_chunks_for_cells"):
        return
    if main.has_method("queue_dirty_terrain_volume_chunk_refreshes"):
        main.queue_dirty_terrain_volume_chunk_refreshes()
    main.rebuild_chunks_for_cells([
        Vector2i(base_x, base_z),
        Vector2i(base_x + width, base_z),
        Vector2i(base_x, base_z + depth),
        Vector2i(base_x + width, base_z + depth),
        Vector2i(base_x + int(width / 2), base_z + int(depth / 2))
    ], 0, true)

func ensure_village_perimeter() -> void:
    if main == null or system.town.is_empty() or main.structure_system == null:
        return
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    var gate_cells := {}
    for offset in [0, 1]:
        gate_cells[Vector2i(center_x + offset, center_z - FENCE_RADIUS_CELLS)] = { "side": 2, "secondary": offset == 1 }
        gate_cells[Vector2i(center_x + offset, center_z + FENCE_RADIUS_CELLS)] = { "side": 0, "secondary": offset == 1 }
        gate_cells[Vector2i(center_x - FENCE_RADIUS_CELLS, center_z + offset)] = { "side": 3, "secondary": offset == 1 }
        gate_cells[Vector2i(center_x + FENCE_RADIUS_CELLS, center_z + offset)] = { "side": 1, "secondary": offset == 1 }
    for offset in range(-FENCE_RADIUS_CELLS, FENCE_RADIUS_CELLS + 1):
        place_perimeter_cell(center_x + offset, center_z - FENCE_RADIUS_CELLS, level, gate_cells)
        place_perimeter_cell(center_x + offset, center_z + FENCE_RADIUS_CELLS, level, gate_cells)
        place_perimeter_cell(center_x - FENCE_RADIUS_CELLS, center_z + offset, level, gate_cells)
        place_perimeter_cell(center_x + FENCE_RADIUS_CELLS, center_z + offset, level, gate_cells)

func place_perimeter_cell(cell_x: int, cell_z: int, level: float, gate_cells: Dictionary) -> void:
    var cell := Vector2i(cell_x, cell_z)
    if gate_cells.has(cell):
        var gate: Dictionary = gate_cells[cell]
        main.structure_system.place_door(cell_x, cell_z, level, int(gate.get("side", 0)), bool(gate.get("secondary", false)), "public_gate")
        return
    main.structure_system.place_structure_block(cell_x, cell_z, level, 0, "woodBlock", {
        "generatedTier": "town",
        "cacheKey": "%s:tutorial-fence:%d,%d" % [main.seed_text, cell_x, cell_z]
    })

func ensure_village_lights() -> void:
    if main == null or system.town.is_empty() or main.structure_system == null:
        return
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    for cell in [
        Vector2i(center_x, center_z - 7), Vector2i(center_x - 8, center_z),
        Vector2i(center_x + 8, center_z), Vector2i(center_x, center_z + 8),
        Vector2i(center_x - 14, center_z - 9), Vector2i(center_x + 14, center_z + 9)
    ]:
        main.structure_system.place_utility(cell.x, cell.y, level, "torch", {
            "generatedTier": "town",
            "cacheKey": "%s:tutorial-light:%d,%d" % [main.seed_text, cell.x, cell.y]
        })
        add_warm_light(Vector3(float(cell.x) * CELL, level + CELL * 1.25, float(cell.y) * CELL), 9.0, 1.15)

    for offset in range(-FENCE_RADIUS_CELLS, FENCE_RADIUS_CELLS + 1, 5):
        for cell in [
            Vector2i(center_x + offset, center_z - FENCE_RADIUS_CELLS),
            Vector2i(center_x + offset, center_z + FENCE_RADIUS_CELLS),
            Vector2i(center_x - FENCE_RADIUS_CELLS, center_z + offset),
            Vector2i(center_x + FENCE_RADIUS_CELLS, center_z + offset)
        ]:
            main.structure_system.place_structure_block(cell.x, cell.y, level, 1, "torch", {
                "generatedTier": "town",
                "cacheKey": "%s:tutorial-perimeter-light:%d,%d" % [main.seed_text, cell.x, cell.y]
            })
            add_warm_light(Vector3(float(cell.x) * CELL, level + CELL * 2.25, float(cell.y) * CELL), 9.0, 1.15)

func place_player_in_starter_house() -> void:
    if main == null or system.town.is_empty() or main.player == null:
        return
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    system.start_cell = Vector2i(center_x - 13, center_z - 10)
    var spawn := Vector3(float(system.start_cell.x) * CELL, level + 0.12, float(system.start_cell.y) * CELL)
    main.player.global_position = spawn
    main.player.velocity = Vector3.ZERO
    main.player.rotation.y = PI
    main.player.set("pitch", 0.0)
    main.player.set("terrain_grounded", true)
    var camera := main.player.get("camera") as Camera3D
    if camera:
        camera.rotation.x = 0.0
    main.respawn_point = spawn

func force_stormy_night() -> void:
    if main == null or main.player == null:
        return
    main.time_of_day = 0.86
    if main.weather_system:
        main.weather_system.force_weather("rain", 0.86, 0.94, main.player.global_position)
    if main.has_method("update_sky"):
        main.update_sky(0.0)

func spawn_tutorial_npcs() -> void:
    clear_npcs()
    if main == null or system.town.is_empty():
        return
    var cx := int(system.town.get("centerX", 0))
    var cz := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    var north_home: Dictionary = system.tutorial_home_record(1, Vector2i(cx + 12, cz - 10), Vector2i(cx + 12, cz - 15))
    var west_home: Dictionary = system.tutorial_home_record(2, Vector2i(cx - 13, cz + 12), Vector2i(cx - 13, cz + 17))
    var elder_home: Dictionary = system.tutorial_home_record(3, Vector2i(cx + 13, cz + 12), Vector2i(cx + 13, cz + 17))
    for spec in tutorial_npc_specs(cx, cz, north_home, west_home, elder_home):
        spawn_npc(spec, level, Vector3(float(cx) * CELL, level, float(cz) * CELL))

func tutorial_npc_specs(cx: int, cz: int, north_home: Dictionary, west_home: Dictionary, elder_home: Dictionary) -> Array:
    return [
        npc_spec("mira", "Mira", "Elder", Vector2i(cx - 13, cz - 15), elder_home, Color(0.70, 0.46, 0.34), Color(0.92, 0.76, 0.42), ["Storms bring the dark close. Start by meeting Rowan near the workbench.", "The lights mark the safe ground. Beyond them, shadows notice you."], { "holdIntroDoor": true }),
        npc_spec("rowan", "Rowan", "Carpenter", north_home.get("homeCell", Vector2i(cx, cz - 6)), north_home, Color(0.48, 0.32, 0.18), Color(0.73, 0.52, 0.28), ["Workbench first. Logs become blocks, blocks become shelter.", "Bring me wood when you're ready and we'll turn it into something sturdy."], { "job": "wood", "startInsideHome": true }),
        npc_spec("niko", "Niko", "Forager", west_home.get("homeCell", Vector2i(cx - 5, cz + 5)), west_home, Color(0.31, 0.50, 0.28), Color(0.82, 0.42, 0.35), ["Food keeps your hands steady. Berries, fish, and cooked meat all matter.", "Stay near the path while the rain is heavy."], { "job": "forage", "startInsideHome": true }),
        npc_spec("sera", "Sera", "Watch", Vector2i(cx + 7, cz), north_home, Color(0.30, 0.34, 0.42), Color(0.66, 0.72, 0.86), ["Do not cross the last lantern unarmed. Hostiles gather outside the village lights.", "Craft a blade or bow before you brave the wilds."], { "job": "guard", "guardCell": Vector2i(cx + FENCE_RADIUS_CELLS - 3, cz), "canFight": true, "nightGuard": true, "weapon": "hunterBow" }),
        npc_spec("toma", "Toma", "Gate Watch", Vector2i(cx, cz - FENCE_RADIUS_CELLS + 4), north_home, Color(0.34, 0.34, 0.30), Color(0.78, 0.66, 0.38), ["The fence slows them. Arrows finish the rest.", "Stay behind the lantern line when the gate splinters."], { "job": "guard", "guardCell": Vector2i(cx, cz - FENCE_RADIUS_CELLS + 2), "canFight": true, "nightGuard": true, "weapon": "hunterBow" }),
        npc_spec("lyra", "Lyra", "Lantern Archer", Vector2i(cx - FENCE_RADIUS_CELLS + 4, cz), west_home, Color(0.28, 0.38, 0.44), Color(0.68, 0.78, 0.88), ["If a rail breaks, we hold the gap.", "Watch their movement. They hate the light."], { "job": "guard", "guardCell": Vector2i(cx - FENCE_RADIUS_CELLS + 2, cz), "canFight": true, "nightGuard": true, "weapon": "hunterBow" })
    ]

func npc_spec(id: String, npc_name: String, role: String, cell: Vector2i, home: Dictionary, color: Color, accent: Color, dialogue: Array, extra := {}) -> Dictionary:
    var result := extra.duplicate(true)
    result.merge({
        "id": id,
        "name": npc_name,
        "role": role,
        "cell": cell,
        "homeCell": home.get("homeCell", cell),
        "porchCell": home.get("porchCell", cell),
        "doorCell": home.get("doorCell", home.get("porchCell", cell)),
        "interiorLandingCell": home.get("interiorLandingCell", home.get("homeCell", cell)),
        "homeRouteCells": home.get("homeRouteCells", [home.get("porchCell", cell), home.get("homeCell", cell)]),
        "interiorMinCell": home.get("interiorMinCell", home.get("homeCell", cell)),
        "interiorMaxCell": home.get("interiorMaxCell", home.get("homeCell", cell)),
        "color": color,
        "accent": accent,
        "dialogue": dialogue
    }, true)
    return result

func spawn_npc(spec: Dictionary, level: float, look_target: Vector3) -> CharacterBody3D:
    if main == null or main.npc_system == null or not main.npc_system.has_method("create_npc_body"):
        return null
    var body := main.npc_system.create_npc_body("TutorialNPC_%s" % String(spec.get("id", "villager")), "tutorial_npc") as CharacterBody3D
    if body == null:
        return null
    var cell: Vector2i = spec.get("cell", Vector2i.ZERO)
    body.set_meta("npc_id", String(spec.get("id", "")))
    body.set_meta("npc_name", String(spec.get("name", "Villager")))
    body.set_meta("npc_role", String(spec.get("role", "")))
    body.set_meta("dialogue", spec.get("dialogue", []))
    body.set_meta("dialogue_index", 0)
    add_npc_visual(body, spec.get("color", Color(0.55, 0.42, 0.31)), spec.get("accent", Color(0.80, 0.66, 0.42)), String(spec.get("name", "Villager")), String(spec.get("role", "")))
    add_npc_collider(body)
    system.npc_root.add_child(body)
    place_tutorial_npc(body, cell, level, String(spec.get("id", "")))
    register_with_npc_system(body, spec, level, cell)
    if body.global_position.distance_to(look_target) > 0.2:
        body.look_at(look_target, Vector3.UP)
    return body

func place_tutorial_npc(body: CharacterBody3D, requested_cell: Vector2i, level: float, npc_id: String) -> Dictionary:
    if body == null or main == null or main.npc_system == null or not main.npc_system.has_method("safe_place_npc"):
        return { "ok": false, "reason": "missing_safe_placement" }
    body.set_meta("npc_spawn_requested_cell", requested_cell)
    var requested_position := Vector3(float(requested_cell.x) * CELL, level + 0.02, float(requested_cell.y) * CELL)
    var initial: Dictionary = main.npc_system.safe_place_npc(body, requested_position, null, "tutorial_spawn")
    if bool(initial.get("ok", false)):
        body.set_meta("npc_spawn_fallback_used", false)
        body.set_meta("npc_spawn_placement", initial)
        return initial
    var max_radius := 10
    for radius in range(1, max_radius + 1):
        for dx in range(-radius, radius + 1):
            for dz in range(-radius, radius + 1):
                if maxi(absi(dx), absi(dz)) != radius:
                    continue
                var candidate_cell := requested_cell + Vector2i(dx, dz)
                var candidate_position := Vector3(float(candidate_cell.x) * CELL, level + 0.02, float(candidate_cell.y) * CELL)
                var placement: Dictionary = main.npc_system.safe_place_npc(body, candidate_position, null, "tutorial_spawn_fallback")
                if not bool(placement.get("ok", false)):
                    continue
                placement["fallbackCell"] = candidate_cell
                placement["requestedCell"] = requested_cell
                placement["fallbackRadius"] = radius
                body.set_meta("npc_spawn_fallback_used", true)
                body.set_meta("npc_spawn_placement", placement)
                return placement
    var failed := {
        "ok": false,
        "position": requested_position,
        "reason": String(initial.get("reason", "placement_failed")),
        "requestedCell": requested_cell,
        "npcId": npc_id
    }
    body.set_meta("npc_spawn_fallback_used", false)
    body.set_meta("npc_spawn_placement", failed)
    return failed

func register_with_npc_system(body: Node3D, spec: Dictionary, level: float, cell: Vector2i) -> void:
    if main == null or main.npc_system == null or not main.npc_system.has_method("register_npc"):
        return
    main.npc_system.register_npc(body, {
        "id": String(spec.get("id", "")),
        "name": String(spec.get("name", "Villager")),
        "role": String(spec.get("role", "")),
        "townKey": system.tutorial_town_key(),
        "townCenter": Vector2i(int(system.town.get("centerX", 0)), int(system.town.get("centerZ", 0))),
        "townRadius": int(system.town.get("radius", SAFE_RADIUS_CELLS)),
        "level": level,
        "cell": cell,
        "homeCell": spec.get("homeCell", cell),
        "porchCell": spec.get("porchCell", cell),
        "doorCell": spec.get("doorCell", spec.get("porchCell", cell)),
        "interiorLandingCell": spec.get("interiorLandingCell", spec.get("homeCell", cell)),
        "homeRouteCells": spec.get("homeRouteCells", [spec.get("porchCell", cell), spec.get("homeCell", cell)]),
        "interiorMinCell": spec.get("interiorMinCell", spec.get("homeCell", cell)),
        "interiorMaxCell": spec.get("interiorMaxCell", spec.get("homeCell", cell)),
        "guardCell": spec.get("guardCell", spec.get("porchCell", cell)),
        "canFight": bool(spec.get("canFight", false)),
        "nightGuard": bool(spec.get("nightGuard", false)),
        "weapon": String(spec.get("weapon", "")),
        "job": String(spec.get("job", "")),
        "holdIntroDoor": bool(spec.get("holdIntroDoor", false)),
        "tutorial": true,
        "requiredVisibleScripted": true
    })

func add_npc_collider(body: Node3D) -> void:
    if npc_visual_factory != null:
        npc_visual_factory.add_collider(body)

func add_npc_visual(parent: Node3D, color: Color, accent: Color, npc_name: String, role: String) -> void:
    var body_material := make_material(color, 0.82)
    var accent_material := make_material(accent, 0.74)
    if npc_visual_factory != null:
        npc_visual_factory.add_visual(parent, body_material, accent_material, npc_name, role)
        return
    var skin_material := make_material(Color(0.76, 0.55, 0.39), 0.70)
    var torso_mesh := CylinderMesh.new()
    torso_mesh.top_radius = 0.26
    torso_mesh.bottom_radius = 0.34
    torso_mesh.height = 0.92
    torso_mesh.radial_segments = 8
    add_mesh(parent, torso_mesh, body_material, Vector3(0.0, 0.72, 0.0), Vector3.ONE)
    var cloak_mesh := BoxMesh.new()
    cloak_mesh.size = Vector3(0.48, 0.48, 0.10)
    add_mesh(parent, cloak_mesh, accent_material, Vector3(0.0, 0.83, -0.28), Vector3.ONE)
    var head_mesh := SphereMesh.new()
    head_mesh.radius = 0.23
    head_mesh.height = 0.30
    head_mesh.radial_segments = 10
    head_mesh.rings = 6
    add_mesh(parent, head_mesh, skin_material, Vector3(0.0, 1.34, 0.0), Vector3.ONE)
    var hood_mesh := SphereMesh.new()
    hood_mesh.radius = 0.26
    hood_mesh.height = 0.20
    hood_mesh.radial_segments = 9
    hood_mesh.rings = 4
    add_mesh(parent, hood_mesh, accent_material, Vector3(0.0, 1.44, -0.03), Vector3(1.0, 0.54, 1.0))
    var arm_mesh := CylinderMesh.new()
    arm_mesh.top_radius = 0.055
    arm_mesh.bottom_radius = 0.065
    arm_mesh.height = 0.64
    arm_mesh.radial_segments = 6
    for side in [-1.0, 1.0]:
        var arm := MeshInstance3D.new()
        arm.mesh = arm_mesh
        arm.material_override = body_material
        arm.position = Vector3(side * 0.34, 0.78, 0.0)
        arm.rotation.z = side * 0.22
        parent.add_child(arm)
    var label := Label3D.new()
    label.text = "%s\n%s" % [npc_name, role]
    label.font_size = 28
    label.position.y = 1.88
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label.no_depth_test = true
    parent.add_child(label)

func add_mesh(parent: Node3D, mesh: Mesh, material: Material, position: Vector3, scale: Vector3) -> void:
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.material_override = material
    instance.position = position
    instance.scale = scale
    parent.add_child(instance)

func add_warm_light(position: Vector3, radius: float, energy: float) -> void:
    if system.light_root == null:
        return
    var cast_shadows := main != null and bool(main.get("shadows_enabled"))
    var fill_position := position
    if main != null and main.has_method("surface_y_at_position"):
        fill_position.y = float(main.call("surface_y_at_position", position)) + CELL * 0.36
    else:
        fill_position.y = position.y - CELL * 0.85
    LocalLightRigScript.add_rig(system.light_root, "tutorial_lantern", {
        "context": "placed",
        "scale": CELL,
        "source_position": position,
        "terrain_position": fill_position,
        "bounce_position": fill_position + Vector3(0.0, CELL * 0.72, 0.0),
        "source_energy": energy,
        "source_range": radius,
        "terrain_energy": energy * 0.70,
        "terrain_range": radius * 0.85,
        "bounce_energy": energy * 0.38,
        "bounce_range": radius * 1.05,
        "shadows": cast_shadows,
        "day_suppressed": true
    })

func make_material(color: Color, roughness: float) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = roughness
    return material

func make_emissive_material(color: Color, energy: float) -> StandardMaterial3D:
    var material := make_material(color, 0.48)
    material.emission_enabled = true
    material.emission = color
    material.emission_energy_multiplier = energy
    return material

func clear_scene() -> void:
    system.clear_speech_bubbles()
    system.clear_rescue_torch()
    clear_npcs()
    clear_lights()
    system.clear_repair_markers()

func clear_npcs() -> void:
    if system.npc_root == null:
        return
    for child in system.npc_root.get_children():
        if main and main.npc_system and main.npc_system.has_method("unregister_npc"):
            main.npc_system.unregister_npc(child)
        system.npc_root.remove_child(child)
        child.queue_free()

func clear_lights() -> void:
    if system.light_root == null:
        return
    for child in system.light_root.get_children():
        system.light_root.remove_child(child)
        child.queue_free()

func npc_count() -> int:
    if system.npc_root == null:
        return 0
    return system.npc_root.get_child_count()
