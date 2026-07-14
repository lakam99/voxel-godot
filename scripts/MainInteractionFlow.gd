extends "res://scripts/MainPlaytestTools.gd"

var forage_mesh_cache := {}

func forage_sphere_mesh(key: String, radius: float, height: float) -> SphereMesh:
    if forage_mesh_cache.has(key):
        return forage_mesh_cache[key] as SphereMesh
    var mesh := SphereMesh.new()
    mesh.radius = radius
    mesh.height = height
    forage_mesh_cache[key] = mesh
    return mesh

func forage_cylinder_mesh(key: String, bottom_radius: float, top_radius: float, height: float, radial_segments: int) -> CylinderMesh:
    if forage_mesh_cache.has(key):
        return forage_mesh_cache[key] as CylinderMesh
    var mesh := CylinderMesh.new()
    mesh.bottom_radius = bottom_radius
    mesh.top_radius = top_radius
    mesh.height = height
    mesh.radial_segments = radial_segments
    forage_mesh_cache[key] = mesh
    return mesh

func make_ore(parent: Node, prop_id: String, position: Vector3, ore_type: String, rng: RandomNumberGenerator):
    if ore_type == "":
        ore_type = "copperOre"
    var body := StaticBody3D.new()
    body.name = "Ore_%s" % ore_type
    body.position = position
    body.rotation.y = rng.randf() * TAU
    body.set_meta("kind", "prop")
    body.set_meta("prop_id", prop_id)
    body.set_meta("drop", ore_type)
    body.set_meta("material", ore_type)
    body.set_meta("ore_type", ore_type)
    body.set_meta("required_tool", ItemCatalogScript.material_required_tool(ore_type))
    body.set_meta("required_tier", ItemCatalogScript.material_required_tier(ore_type))
    body.set_meta("drop_count", rng.randi_range(1, 2 if ore_type == "ironOre" else 3))

    var radius := 0.58 + rng.randf() * 0.82
    var ore_mesh := SphereMesh.new()
    ore_mesh.radius = radius
    ore_mesh.height = radius * (0.70 + rng.randf() * 0.56)
    ore_mesh.radial_segments = 9
    ore_mesh.rings = 5
    var ore := MeshInstance3D.new()
    ore.name = "OreStone"
    ore.mesh = ore_mesh
    ore.material_override = materials.get("oreBase", materials["rock"])
    ore.position.y = radius * 0.40
    ore.scale = Vector3(1.15 + rng.randf() * 0.5, 0.62 + rng.randf() * 0.45, 1.0 + rng.randf() * 0.42)
    body.add_child(ore)

    var vein_mesh := BoxMesh.new()
    vein_mesh.size = Vector3(radius * 0.78, radius * 0.12, radius * 0.18)
    for i in range(5):
        var vein := MeshInstance3D.new()
        vein.name = "OreSeam"
        vein.mesh = vein_mesh
        vein.material_override = materials.get(ore_type, materials["rock"])
        vein.position = Vector3((rng.randf() - 0.5) * radius * 0.95, radius * (0.38 + rng.randf() * 0.48), -radius * (0.44 + rng.randf() * 0.18))
        vein.rotation = Vector3(rng.randf() * 0.7, rng.randf() * TAU, rng.randf() * 0.7)
        body.add_child(vein)

    var glow_key := "ironOreGlow" if ore_type == "ironOre" else "copperOreGlow"
    var glint_mesh := SphereMesh.new()
    glint_mesh.radius = radius * 0.13
    glint_mesh.height = radius * 0.18
    glint_mesh.radial_segments = 6
    glint_mesh.rings = 3
    for i in range(3):
        var glint := MeshInstance3D.new()
        glint.name = "OreGlint"
        glint.mesh = glint_mesh
        glint.material_override = materials.get(glow_key, materials.get(ore_type, materials["rock"]))
        glint.position = Vector3((rng.randf() - 0.5) * radius * 0.72, radius * (0.58 + rng.randf() * 0.28), -radius * 0.58)
        glint.scale = Vector3(1.0, 0.72 + rng.randf() * 0.38, 1.0)
        body.add_child(glint)

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

func make_forage(parent: Node, prop_id: String, position: Vector3, biome: String, rng: RandomNumberGenerator):
    var spec := forage_for_biome(biome)
    if spec.is_empty():
        return null
    var material_id := String(spec.get("material", "berryBush"))
    var body := StaticBody3D.new()
    body.name = "Forage_%s" % material_id
    body.position = position
    body.rotation.y = rng.randf() * TAU
    body.set_meta("kind", "prop")
    body.set_meta("prop_id", prop_id)
    body.set_meta("drop", String(spec.get("drop", "berries")))
    body.set_meta("material", material_id)
    body.set_meta("drop_count", rng.randi_range(int(spec.get("drop_min", 1)), int(spec.get("drop_max", 1))))

    match material_id:
        "aloePatch":
            var leaf_mesh := forage_cylinder_mesh("aloe_leaf", 0.14, 0.0, 0.68, 5)
            for i in range(6):
                var leaf := MeshInstance3D.new()
                leaf.mesh = leaf_mesh
                leaf.material_override = materials["aloePatch"]
                leaf.position = Vector3((rng.randf() - 0.5) * 0.38, 0.24, (rng.randf() - 0.5) * 0.38)
                leaf.rotation = Vector3(0.35 + rng.randf() * 0.35, rng.randf() * TAU, 0.0)
                leaf.scale = Vector3(0.86 + rng.randf() * 0.28, 0.82 + rng.randf() * 0.35, 0.86 + rng.randf() * 0.28)
                body.add_child(leaf)
        "mushroomCluster":
            var stem_mesh := forage_cylinder_mesh("mushroom_stem", 0.055, 0.04, 0.36, 5)
            var cap_mesh := forage_sphere_mesh("mushroom_cap", 0.16, 0.13)
            for i in range(4):
                var stem := MeshInstance3D.new()
                stem.mesh = stem_mesh
                stem.material_override = materials["mushroomCluster"]
                var stem_height_scale := 0.72 + rng.randf() * 0.55
                stem.position = Vector3((rng.randf() - 0.5) * 0.52, 0.18 * stem_height_scale, (rng.randf() - 0.5) * 0.52)
                stem.scale = Vector3(1.0, stem_height_scale, 1.0)
                body.add_child(stem)
                var cap := MeshInstance3D.new()
                cap.mesh = cap_mesh
                cap.material_override = materials["mushroomCap"]
                cap.position = stem.position + Vector3(0.0, 0.21 * stem_height_scale, 0.0)
                cap.scale = Vector3(1.0 + rng.randf() * 0.34, 0.48 + rng.randf() * 0.16, 1.0 + rng.randf() * 0.34)
                body.add_child(cap)
        "frostHerbPatch":
            var blade_mesh := forage_cylinder_mesh("frost_blade", 0.055, 0.0, 0.52, 4)
            for i in range(5):
                var blade := MeshInstance3D.new()
                blade.mesh = blade_mesh
                blade.material_override = materials["frostHerbPatch"]
                blade.position = Vector3((rng.randf() - 0.5) * 0.44, 0.22, (rng.randf() - 0.5) * 0.44)
                blade.rotation = Vector3(0.18 + rng.randf() * 0.28, rng.randf() * TAU, 0.0)
                blade.scale = Vector3(0.9 + rng.randf() * 0.22, 0.82 + rng.randf() * 0.42, 0.9 + rng.randf() * 0.22)
                body.add_child(blade)
        _:
            var bush_mesh := forage_sphere_mesh("berry_bush", 0.48, 0.50)
            var bush := MeshInstance3D.new()
            bush.mesh = bush_mesh
            bush.material_override = materials["berryBush"]
            bush.position.y = 0.38
            bush.scale = Vector3(1.02 + rng.randf() * 0.28, 0.62 + rng.randf() * 0.18, 0.96 + rng.randf() * 0.22)
            body.add_child(bush)
            var berry_mesh := forage_sphere_mesh("berry_fruit", 0.055, 0.11)
            for i in range(7):
                var berry := MeshInstance3D.new()
                berry.mesh = berry_mesh
                berry.material_override = materials["berryFruit"]
                var angle := rng.randf() * TAU
                var spread := 0.20 + rng.randf() * 0.22
                berry.position = Vector3(cos(angle) * spread, 0.40 + rng.randf() * 0.20, sin(angle) * spread)
                body.add_child(berry)

    var shape := SphereShape3D.new()
    shape.radius = float(spec.get("radius", 0.50))
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.position.y = shape.radius * 0.45
    body.add_child(collider)
    parent.add_child(body)
    if npc_system and npc_system.has_method("notify_navigation_prop_created"):
        npc_system.notify_navigation_prop_created(prop_id, body)
    return body

func make_wildlife(parent: Node, prop_id: String, position: Vector3, biome: String, rng: RandomNumberGenerator):
    var profile := wildlife_profile(biome, rng)
    var cold := bool(profile.get("cold", false))
    var body := StaticBody3D.new()
    body.name = "Wildlife_%s" % String(profile.get("variant", "boar"))
    body.position = position
    body.rotation.y = rng.randf() * TAU
    body.set_meta("kind", "prop")
    body.set_meta("prop_id", prop_id)
    body.set_meta("drop", "rawMeat")
    body.set_meta("material", "wildlife")
    body.set_meta("wildlife_variant", String(profile.get("variant", "boar")))
    body.set_meta("wildlife_speed_multiplier", float(profile.get("speed_multiplier", 1.0)))
    body.set_meta("drop_count", rng.randi_range(1, int(profile.get("drop_max", 2 if cold else 3))))
    body.set_meta("extra_drop", "hide")
    body.set_meta("extra_drop_count", rng.randi_range(1, int(profile.get("extra_drop_max", 2))))

    if add_animated_wildlife_visual(body, profile, rng) == null:
        add_procedural_wildlife_visual(body, profile, rng)

    var shape := BoxShape3D.new()
    shape.size = profile.get("collider_size", Vector3(1.18, 1.05, 0.78))
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.position.y = float(profile.get("collider_y", 0.52))
    body.add_child(collider)
    parent.add_child(body)
    if npc_system and npc_system.has_method("notify_navigation_prop_created"):
        npc_system.notify_navigation_prop_created(prop_id, body)
    register_wildlife(body, rng, cold)
    return body

func wildlife_profile(biome: String, rng: RandomNumberGenerator) -> Dictionary:
    var cold := biome == "snow" or biome == "tundra" or biome == "alpine" or biome == "taiga"
    var roll := rng.randf()
    var variant := "boar"
    if cold:
        variant = "hare" if roll < 0.62 else "deer"
    elif biome == "forest" or biome == "plains":
        variant = "deer" if roll < 0.42 else ("hare" if roll < 0.68 else "boar")
    elif biome == "savanna" or biome == "desert" or biome == "beach":
        variant = "hare" if roll < 0.70 else "boar"
    elif biome == "swamp":
        variant = "boar" if roll < 0.70 else "hare"
    var profiles := {
        "boar": {
            "variant": "boar",
            "asset": "boar_idle_walk",
            "animation": "boar_idle_walk",
            "scale": 0.72,
            "speed_multiplier": 0.92,
            "drop_max": 3,
            "extra_drop_max": 2,
            "collider_size": Vector3(1.18, 1.05, 0.78),
            "collider_y": 0.52,
            "cold": cold
        },
        "deer": {
            "variant": "deer",
            "asset": "deer_idle_walk",
            "animation": "deer_idle_walk",
            "scale": 0.66,
            "speed_multiplier": 1.10,
            "drop_max": 3,
            "extra_drop_max": 2,
            "collider_size": Vector3(0.94, 1.52, 0.72),
            "collider_y": 0.76,
            "cold": cold
        },
        "hare": {
            "variant": "hare",
            "asset": "hare_idle_walk",
            "animation": "hare_idle_walk",
            "scale": 0.92,
            "speed_multiplier": 1.34,
            "drop_max": 1,
            "extra_drop_max": 1,
            "collider_size": Vector3(0.62, 0.74, 0.52),
            "collider_y": 0.34,
            "cold": cold
        }
    }
    return profiles.get(variant, profiles["boar"]).duplicate(true)

func add_animated_wildlife_visual(body: Node3D, profile: Dictionary, rng: RandomNumberGenerator) -> Node3D:
    if animated_asset_registry == null:
        return null
    var asset_id := String(profile.get("asset", ""))
    if asset_id == "" or not animated_asset_registry.has_method("instantiate_asset"):
        return null
    var visual: Node3D = animated_asset_registry.instantiate_asset(asset_id)
    if visual == null:
        return null
    visual.name = "AnimatedWildlife_%s" % String(profile.get("variant", "animal"))
    visual.scale = Vector3.ONE * float(profile.get("scale", 1.0)) * rng.randf_range(0.92, 1.08)
    visual.rotation.y = PI
    visual.set_meta("visual_role", "wildlife")
    body.add_child(visual)

    var anim_player: AnimationPlayer = animated_asset_registry.find_animation_player(visual)
    var animation_name := String(profile.get("animation", ""))
    if anim_player != null and animation_name != "":
        var animation := anim_player.get_animation(animation_name)
        if animation != null:
            animation.loop_mode = Animation.LOOP_LINEAR
        anim_player.play(animation_name)
        anim_player.speed_scale = rng.randf_range(0.75, 1.10)
        body.set_meta("wildlife_animation_player_path", String(body.get_path_to(anim_player)))
        body.set_meta("wildlife_animation_name", animation_name)
        body.set_meta("wildlife_animated", true)
    return visual

func add_procedural_wildlife_visual(body: Node3D, profile: Dictionary, rng: RandomNumberGenerator) -> void:
    var root := Node3D.new()
    root.name = "ProceduralWildlifeVisual"
    root.scale = Vector3.ONE * float(profile.get("scale", 1.0))
    body.add_child(root)
    var body_mesh := SphereMesh.new()
    body_mesh.radius = 0.42 + rng.randf() * 0.08
    body_mesh.height = 0.72 + rng.randf() * 0.10
    var torso := MeshInstance3D.new()
    torso.mesh = body_mesh
    torso.material_override = materials["wildlife"]
    torso.position = Vector3(0.0, 0.56, 0.0)
    torso.scale = Vector3(1.38, 0.80, 0.82)
    root.add_child(torso)

    var head_mesh := SphereMesh.new()
    head_mesh.radius = 0.20
    head_mesh.height = 0.30
    var head := MeshInstance3D.new()
    head.mesh = head_mesh
    head.material_override = materials["wildlife"]
    head.position = Vector3(0.48, 0.74, 0.0)
    head.scale = Vector3(1.0, 0.86, 0.86)
    root.add_child(head)

    var leg_mesh := CylinderMesh.new()
    leg_mesh.top_radius = 0.045
    leg_mesh.bottom_radius = 0.055
    leg_mesh.height = 0.52
    leg_mesh.radial_segments = 5
    for x_offset in [-0.28, 0.28]:
        for z_offset in [-0.18, 0.18]:
            var leg := MeshInstance3D.new()
            leg.mesh = leg_mesh
            leg.material_override = materials["wildlifeDark"]
            leg.position = Vector3(x_offset, 0.24, z_offset)
            root.add_child(leg)

    var ear_mesh := CylinderMesh.new()
    ear_mesh.bottom_radius = 0.06
    ear_mesh.top_radius = 0.0
    ear_mesh.height = 0.20
    ear_mesh.radial_segments = 4
    for z_offset in [-0.09, 0.09]:
        var ear := MeshInstance3D.new()
        ear.mesh = ear_mesh
        ear.material_override = materials["wildlifeDark"]
        ear.position = Vector3(0.53, 0.94, z_offset)
        ear.rotation.z = -0.45
        root.add_child(ear)

func place_selected_block() -> void:
    var hit: Dictionary = player.view_ray(PLACEMENT_RANGE)
    if hit.is_empty():
        hit = fallback_ground_placement_hit(PLACEMENT_RANGE)
        if hit.is_empty():
            update_hud("No placement target")
            return
    var active: Dictionary = inventory_system.active_stack()
    var block_type := String(active.get("item", ""))
    if block_type == "":
        update_hud("Active slot is empty")
        return
    if not ItemCatalogScript.is_placeable(block_type):
        update_hud("%s is not placeable" % ItemCatalogScript.label(block_type))
        return
    var placement := placement_from_hit(hit, block_type)
    if placement.is_empty():
        update_hud("No placement target")
        return
    if not placement_within_action_reach(placement):
        update_hud("Too far away")
        return
    var cell: Vector3i = placement["cell"]
    if blocks.has(cell):
        update_hud("Blocked")
        return
    var block_options := {
        "player_placed": true,
        "world_y": float(placement["world_y"]),
        "deferWorldEditFollowup": true
    }
    if should_face_player(block_type):
        block_options["facing"] = snapped_player_yaw()
    var block := create_block(cell, block_type, block_options)
    if block == null or not is_instance_valid(block) or not blocks.has(cell):
        update_hud("Blocked")
        return
    inventory_system.consume_active(1)
    if held_item:
        held_item.play_use("place")
    play_feedback("place", block.global_position, feedback_color_for_material(block_type), 5)
    if block_type == "workbench":
        objective_system.complete("place_workbench")
    award_place_xp(block_type)
    if tutorial_system and tutorial_system.has_method("on_block_placed") and bool(tutorial_system.on_block_placed(block)):
        show_action_message(tutorial_system.last_message)
    else:
        show_action_message("Placed %s" % ItemCatalogScript.label(block_type))

func should_face_player(block_type: String) -> bool:
    return block_type in ["door", "bed", "chest", "furnace", "anvil", "workbench", "traderStall"]

func snapped_player_yaw() -> float:
    if player == null:
        return 0.0
    return roundf(player.rotation.y / (PI * 0.5)) * PI * 0.5

func fallback_ground_placement_hit(max_distance: float) -> Dictionary:
    if player == null or player.camera == null:
        return {}
    var origin: Vector3 = player.camera.global_position
    var forward: Vector3 = -player.camera.global_transform.basis.z.normalized()
    if forward.y > -0.04:
        return {}
    var previous_delta: float = origin.y - surface_y_at_position(origin)
    var steps := 18
    for i in range(1, steps + 1):
        var distance := max_distance * float(i) / float(steps)
        var sample: Vector3 = origin + forward * distance
        var ground_y := surface_y_at_position(sample)
        var delta := sample.y - ground_y
        if previous_delta >= 0.0 and delta <= 0.08:
            return {
                "position": Vector3(sample.x, ground_y, sample.z),
                "normal": Vector3.UP,
                "collider": null
            }
        previous_delta = delta
    return {}

func placement_from_hit(hit: Dictionary, block_type: String) -> Dictionary:
    var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
    var normal: Vector3 = hit.get("normal", Vector3.UP)
    if normal.length_squared() < 0.001:
        normal = Vector3.UP
    normal = normal.normalized()
    var profile := block_collision_profile(block_type)
    var collider_size: Vector3 = profile.get("size", Vector3.ONE * CELL * 0.96)
    var collider_offset: Vector3 = profile.get("offset", Vector3.ZERO)
    var hit_collider := hit.get("collider") as Node

    if hit_collider and hit_collider.has_meta("kind") and String(hit_collider.get_meta("kind")) == "block" and hit_collider.has_meta("cell"):
        var target_cell: Vector3i = hit_collider.get_meta("cell")
        var offset_cell := dominant_cell_offset(normal)
        var cell := target_cell + offset_cell
        var world_y := float(cell.y) * CELL
        if offset_cell.y > 0:
            world_y = hit_position.y - collider_offset.y + collider_size.y * 0.5
        elif offset_cell.y < 0:
            world_y = hit_position.y - collider_offset.y - collider_size.y * 0.5
        elif hit_collider is Node3D:
            world_y = (hit_collider as Node3D).global_position.y
        return {
            "cell": cell,
            "world_y": world_y
        }

    var planar_normal := Vector3(normal.x, 0.0, normal.z)
    var xz_position := hit_position
    if planar_normal.length_squared() > 0.001:
        xz_position += planar_normal.normalized() * CELL * 0.18
    var ground_y := placement_surface_height(xz_position.x, xz_position.z, block_type)
    var world_y := ground_y - collider_offset.y + collider_size.y * 0.5
    return {
        "cell": Vector3i(world_to_cell(xz_position.x), floori(world_y / CELL) + 1, world_to_cell(xz_position.z)),
        "world_y": world_y
    }

func placement_within_action_reach(placement: Dictionary) -> bool:
    if player == null or not placement.has("cell"):
        return false
    var cell: Vector3i = placement["cell"]
    var target_flat := Vector2(float(cell.x) * CELL, float(cell.z) * CELL)
    var player_flat := Vector2(player.global_position.x, player.global_position.z)
    return player_flat.distance_to(target_flat) <= ACTION_REACH

func hit_within_action_reach(hit: Dictionary) -> bool:
    if player == null or not hit.has("position"):
        return false
    var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
    var target_flat := Vector2(hit_position.x, hit_position.z)
    var player_flat := Vector2(player.global_position.x, player.global_position.z)
    return player_flat.distance_to(target_flat) <= ACTION_REACH

func focused_interaction_hit() -> Dictionary:
    if player == null:
        return {}
    var hit: Dictionary = player.view_ray(INTERACT_RANGE, true)
    if hit.is_empty() or not hit_within_action_reach(hit):
        return {}
    return hit

func placement_surface_height(x: float, z: float, block_type: String) -> float:
    var profile := block_collision_profile(block_type)
    var size: Vector3 = profile.get("size", Vector3.ONE * CELL * 0.96)
    var radius_x: float = clampf(size.x * 0.42, CELL * 0.22, CELL * 0.54)
    var radius_z: float = clampf(size.z * 0.42, CELL * 0.22, CELL * 0.54)
    var samples := [
        Vector2.ZERO,
        Vector2(radius_x, 0.0),
        Vector2(-radius_x, 0.0),
        Vector2(0.0, radius_z),
        Vector2(0.0, -radius_z),
        Vector2(radius_x, radius_z),
        Vector2(-radius_x, radius_z),
        Vector2(radius_x, -radius_z),
        Vector2(-radius_x, -radius_z)
    ]
    var center_height := surface_y_at_position(Vector3(x, 0.0, z))
    var min_height := center_height
    var max_height := center_height
    for sample in samples:
        var h := surface_y_at_position(Vector3(x + sample.x, 0.0, z + sample.y))
        min_height = minf(min_height, h)
        max_height = maxf(max_height, h)
    var variation := max_height - min_height
    var support_tolerance := CELL * (0.92 if block_type in ["workbench", "anvil", "chest", "furnace"] else 0.72)
    return max_height if variation <= support_tolerance else center_height

func dominant_cell_offset(normal: Vector3) -> Vector3i:
    var abs_normal := Vector3(absf(normal.x), absf(normal.y), absf(normal.z))
    if abs_normal.y >= abs_normal.x and abs_normal.y >= abs_normal.z:
        return Vector3i(0, 1 if normal.y >= 0.0 else -1, 0)
    if abs_normal.x >= abs_normal.z:
        return Vector3i(1 if normal.x >= 0.0 else -1, 0, 0)
    return Vector3i(0, 0, 1 if normal.z >= 0.0 else -1)

func block_collision_profile(block_type: String) -> Dictionary:
    var size := Vector3.ONE * CELL * 0.96
    var offset := Vector3.ZERO
    if block_type == "workbench":
        size = Vector3(CELL * 1.12, CELL * 0.72, CELL * 0.88)
        offset.y = CELL * 0.02
    elif block_type == "chest":
        size = Vector3(CELL * 1.02, CELL * 0.68, CELL * 0.78)
        offset.y = -CELL * 0.06
    elif block_type == "bed":
        size = Vector3(CELL * 1.20, CELL * 0.44, CELL * 0.82)
        offset.y = -CELL * 0.25
    elif block_type == "anvil":
        size = Vector3(CELL * 1.00, CELL * 0.74, CELL * 0.58)
        offset.y = -CELL * 0.10
    elif block_type == "furnace":
        size = Vector3(CELL * 0.98, CELL * 0.94, CELL * 0.84)
        offset.y = -CELL * 0.02
    elif block_type == "cobblestonePath":
        size = Vector3(CELL * 0.96, CELL * 0.045, CELL * 0.96)
    elif block_type == "door":
        size = Vector3(CELL * 0.92, CELL * 1.72, CELL * 0.16)
        offset.y = CELL * 0.38
    elif block_type == "torch":
        size = Vector3(CELL * 0.18, CELL * 0.82, CELL * 0.18)
        offset.y = CELL * 0.10
    elif block_type == "spikeTrap":
        size = Vector3(CELL * 0.82, CELL * 0.30, CELL * 0.82)
        offset.y = -CELL * 0.28
    elif block_type == "campfire":
        size = Vector3(CELL * 0.70, CELL * 0.32, CELL * 0.70)
        offset.y = -CELL * 0.28
    elif block_type == "traderStall":
        size = Vector3(CELL * 1.12, CELL * 0.74, CELL * 0.82)
        offset.y = -CELL * 0.14
    return {
        "size": size,
        "offset": offset
    }
