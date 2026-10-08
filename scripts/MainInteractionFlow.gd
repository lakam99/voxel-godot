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

func build_ore_source_value(prop_id: String, position: Vector3, ore_type: String,
        rng: RandomNumberGenerator) -> Dictionary:
    if ore_type.is_empty():
        ore_type = "copperOre"
    var body_rotation := Vector3(0.0, rng.randf() * TAU, 0.0)
    var drop_count := rng.randi_range(1, 2 if ore_type == "ironOre" else 3)
    var radius := 0.58 + rng.randf() * 0.82
    var ore_height := radius * (0.70 + rng.randf() * 0.56)
    var members: Array[Dictionary] = []
    var fingerprint_cache := {"mesh":{}, "material":{}, "stats":{"meshHits":0,
        "meshMisses":0, "materialHits":0, "materialMisses":0}}
    var stone_mesh := _primitive_recipe("ore_stone", "sphere", {
        "radius": radius, "height": ore_height, "radialSegments": 9, "rings": 5})
    var stone_transform := _source_transform(
        Vector3(0.0, radius * 0.40, 0.0), Vector3.ZERO,
        Vector3(1.15 + rng.randf() * 0.5, 0.62 + rng.randf() * 0.45,
            1.0 + rng.randf() * 0.42))
    members.append(_source_render_member("ore_stone", "OreStone", stone_mesh,
        stone_transform, "oreBase", ["rock"], "opaque", fingerprint_cache))

    var vein_mesh := _primitive_recipe("ore_seam", "box", {
        "size": Vector3(radius * 0.78, radius * 0.12, radius * 0.18)})
    for i in range(5):
        var vein_position := Vector3((rng.randf() - 0.5) * radius * 0.95,
            radius * (0.38 + rng.randf() * 0.48),
            -radius * (0.44 + rng.randf() * 0.18))
        var vein_rotation := Vector3(rng.randf() * 0.7, rng.randf() * TAU,
            rng.randf() * 0.7)
        members.append(_source_render_member("ore_seam_%d" % i, "OreSeam",
            vein_mesh, _source_transform(vein_position, vein_rotation, Vector3.ONE),
            ore_type, ["rock"], "opaque", fingerprint_cache))

    var glow_key := "ironOreGlow" if ore_type == "ironOre" else "copperOreGlow"
    var glint_mesh := _primitive_recipe("ore_glint", "sphere", {
        "radius": radius * 0.13, "height": radius * 0.18,
        "radialSegments": 6, "rings": 3})
    for i in range(3):
        var glint_position := Vector3((rng.randf() - 0.5) * radius * 0.72,
            radius * (0.58 + rng.randf() * 0.28), -radius * 0.58)
        var glint_scale := Vector3(1.0, 0.72 + rng.randf() * 0.38, 1.0)
        members.append(_source_render_member("ore_glint_%d" % i, "OreGlint",
            glint_mesh, _source_transform(glint_position, Vector3.ZERO, glint_scale),
            glow_key, [ore_type, "rock"], "opaque", fingerprint_cache))

    var source_value := {
        "status": "ready", "schema": "ecology.ore_source_value.v1",
        "propId": prop_id, "sourceKind": "ore", "position": position,
        "bodyRotation": body_rotation,
        "gameplay": {"kind": "prop", "drop": ore_type, "material": ore_type,
            "ore_type": ore_type,
            "required_tool": ItemCatalogScript.material_required_tool(ore_type),
            "required_tier": ItemCatalogScript.material_required_tier(ore_type),
            "drop_count": drop_count},
        "collision": {"shape": "sphere", "radius": radius * 1.05,
            "position": Vector3(0.0, radius * 0.42, 0.0)},
        "radius": radius, "renderMembers": members
    }
    _trace_ecology_fingerprint_cache("ore", prop_id, fingerprint_cache)
    return source_value


func make_ore(parent: Node, prop_id: String, position: Vector3, ore_type: String, rng: RandomNumberGenerator):
    var descriptor := build_ore_source_value(prop_id, position, ore_type, rng)
    if parent == null:
        return descriptor
    return make_ore_from_source_value(parent, descriptor)


func make_ore_from_source_value(parent: Node, descriptor: Dictionary):
    if parent == null:
        return descriptor
    if not is_instance_valid(parent) or descriptor.get("status") != "ready" \
            or descriptor.get("sourceKind") != "ore" \
            or String(descriptor.get("propId", "")).is_empty() \
            or not descriptor.get("gameplay", {}) is Dictionary \
            or not descriptor.get("collision", {}) is Dictionary \
            or not descriptor.get("renderMembers", []) is Array:
        return null
    var prop_id := String(descriptor.propId)
    var horizon_only := bool(parent.get_meta("horizon_visual_only", false))
    var body := StaticBody3D.new()
    body.name = "Ore_%s" % String(descriptor.gameplay.ore_type)
    body.position = descriptor.position
    body.rotation = descriptor.bodyRotation
    for key: String in descriptor.gameplay:
        body.set_meta(key, descriptor.gameplay[key])
    body.set_meta("prop_id", prop_id)
    var ecology_members := _materialize_source_render_members(body, descriptor.renderMembers)
    if not horizon_only:
        var collision: Dictionary = descriptor.collision
        var shape := SphereShape3D.new()
        shape.radius = float(collision.radius)
        var collider := CollisionShape3D.new()
        collider.shape = shape
        collider.position = collision.position
        body.add_child(collider)
    parent.add_child(body)
    if not horizon_only and npc_system and npc_system.has_method("notify_navigation_prop_created"):
        npc_system.notify_navigation_prop_created(prop_id, body)
    _record_realized_ecology_prop(parent, body, "ore", ecology_members)
    return body


func build_forage_source_value(prop_id: String, position: Vector3, biome: String,
        rng: RandomNumberGenerator) -> Dictionary:
    var spec := forage_for_biome(biome)
    if spec.is_empty():
        return {"status": "failed", "reason": "forage_biome_recipe_unavailable"}
    var material_id := String(spec.get("material", "berryBush"))
    var body_rotation := Vector3(0.0, rng.randf() * TAU, 0.0)
    var drop_count := rng.randi_range(int(spec.get("drop_min", 1)),
        int(spec.get("drop_max", 1)))
    var members: Array[Dictionary] = []
    var fingerprint_cache := {"mesh":{}, "material":{}, "stats":{"meshHits":0,
        "meshMisses":0, "materialHits":0, "materialMisses":0}}
    match material_id:
        "aloePatch":
            var leaf_mesh := _primitive_recipe("aloe_leaf", "cylinder", {
                "bottomRadius": 0.14, "topRadius": 0.0, "height": 0.68,
                "radialSegments": 5})
            for i in range(6):
                var leaf_position := Vector3((rng.randf() - 0.5) * 0.38, 0.24,
                    (rng.randf() - 0.5) * 0.38)
                var leaf_rotation := Vector3(0.35 + rng.randf() * 0.35,
                    rng.randf() * TAU, 0.0)
                var leaf_scale := Vector3(0.86 + rng.randf() * 0.28,
                    0.82 + rng.randf() * 0.35, 0.86 + rng.randf() * 0.28)
                members.append(_source_render_member("aloe_leaf_%d" % i, "", leaf_mesh,
                    _source_transform(leaf_position, leaf_rotation, leaf_scale),
                    "aloePatch", [], "opaque", fingerprint_cache))
        "mushroomCluster":
            var stem_mesh := _primitive_recipe("mushroom_stem", "cylinder", {
                "bottomRadius": 0.055, "topRadius": 0.04, "height": 0.36,
                "radialSegments": 5})
            var cap_mesh := _primitive_recipe("mushroom_cap", "sphere", {
                "radius": 0.16, "height": 0.13})
            for i in range(4):
                var stem_height_scale := 0.72 + rng.randf() * 0.55
                var stem_position := Vector3((rng.randf() - 0.5) * 0.52,
                    0.18 * stem_height_scale, (rng.randf() - 0.5) * 0.52)
                var stem_transform := _source_transform(stem_position, Vector3.ZERO,
                    Vector3(1.0, stem_height_scale, 1.0))
                members.append(_source_render_member("mushroom_stem_%d" % i, "", stem_mesh,
                    stem_transform, "mushroomCluster", [], "opaque", fingerprint_cache))
                var cap_position := stem_position + Vector3(0.0, 0.21 * stem_height_scale, 0.0)
                var cap_scale := Vector3(1.0 + rng.randf() * 0.34,
                    0.48 + rng.randf() * 0.16, 1.0 + rng.randf() * 0.34)
                members.append(_source_render_member("mushroom_cap_%d" % i, "", cap_mesh,
                    _source_transform(cap_position, Vector3.ZERO, cap_scale),
                    "mushroomCap", [], "opaque", fingerprint_cache))
        "frostHerbPatch":
            var blade_mesh := _primitive_recipe("frost_blade", "cylinder", {
                "bottomRadius": 0.055, "topRadius": 0.0, "height": 0.52,
                "radialSegments": 4})
            for i in range(5):
                var blade_position := Vector3((rng.randf() - 0.5) * 0.44, 0.22,
                    (rng.randf() - 0.5) * 0.44)
                var blade_rotation := Vector3(0.18 + rng.randf() * 0.28,
                    rng.randf() * TAU, 0.0)
                var blade_scale := Vector3(0.9 + rng.randf() * 0.22,
                    0.82 + rng.randf() * 0.42, 0.9 + rng.randf() * 0.22)
                members.append(_source_render_member("frost_blade_%d" % i, "", blade_mesh,
                    _source_transform(blade_position, blade_rotation, blade_scale),
                    "frostHerbPatch", [], "opaque", fingerprint_cache))
        _:
            var bush_mesh := _primitive_recipe("berry_bush", "sphere", {
                "radius": 0.48, "height": 0.50})
            var bush_scale := Vector3(1.02 + rng.randf() * 0.28,
                0.62 + rng.randf() * 0.18, 0.96 + rng.randf() * 0.22)
            members.append(_source_render_member("berry_bush", "", bush_mesh,
                _source_transform(Vector3(0.0, 0.38, 0.0), Vector3.ZERO, bush_scale),
                "berryBush", [], "opaque", fingerprint_cache))
            var berry_mesh := _primitive_recipe("berry_fruit", "sphere", {
                "radius": 0.055, "height": 0.11})
            for i in range(7):
                var angle := rng.randf() * TAU
                var spread := 0.20 + rng.randf() * 0.22
                var berry_position := Vector3(cos(angle) * spread,
                    0.40 + rng.randf() * 0.20, sin(angle) * spread)
                members.append(_source_render_member("berry_%d" % i, "", berry_mesh,
                    _source_transform(berry_position, Vector3.ZERO, Vector3.ONE),
                    "berryFruit", [], "opaque", fingerprint_cache))

    var source_value := {
        "status": "ready", "schema": "ecology.forage_source_value.v1",
        "propId": prop_id, "sourceKind": "forage", "position": position,
        "bodyRotation": body_rotation,
        "gameplay": {"kind": "prop", "drop": String(spec.get("drop", "berries")),
            "material": material_id, "drop_count": drop_count},
        "collision": {"shape": "sphere", "radius": float(spec.get("radius", 0.50)),
            "positionYScale": 0.45},
        "biome": biome, "renderMembers": members
    }
    _trace_ecology_fingerprint_cache("forage", prop_id, fingerprint_cache)
    return source_value


func make_forage(parent: Node, prop_id: String, position: Vector3, biome: String, rng: RandomNumberGenerator):
    var descriptor := build_forage_source_value(prop_id, position, biome, rng)
    if parent == null:
        return descriptor
    return make_forage_from_source_value(parent, descriptor)


func make_forage_from_source_value(parent: Node, descriptor: Dictionary):
    if parent == null:
        return descriptor
    if not is_instance_valid(parent) or descriptor.get("status") != "ready" \
            or descriptor.get("sourceKind") != "forage" \
            or String(descriptor.get("propId", "")).is_empty() \
            or not descriptor.get("gameplay", {}) is Dictionary \
            or not descriptor.get("collision", {}) is Dictionary \
            or not descriptor.get("renderMembers", []) is Array:
        return null
    var prop_id := String(descriptor.propId)
    var horizon_only := bool(parent.get_meta("horizon_visual_only", false))
    var body := StaticBody3D.new()
    var material_id := String(descriptor.gameplay.material)
    body.name = "Forage_%s" % material_id
    body.position = descriptor.position
    body.rotation = descriptor.bodyRotation
    for key: String in descriptor.gameplay:
        body.set_meta(key, descriptor.gameplay[key])
    body.set_meta("prop_id", prop_id)
    var ecology_members := _materialize_source_render_members(body, descriptor.renderMembers)
    if not horizon_only:
        var collision: Dictionary = descriptor.collision
        var shape := SphereShape3D.new()
        shape.radius = float(collision.radius)
        var collider := CollisionShape3D.new()
        collider.shape = shape
        collider.position.y = shape.radius * float(collision.positionYScale)
        body.add_child(collider)
    parent.add_child(body)
    if not horizon_only and npc_system and npc_system.has_method("notify_navigation_prop_created"):
        npc_system.notify_navigation_prop_created(prop_id, body)
    _record_realized_ecology_prop(parent, body, "forage", ecology_members)
    return body


func _source_transform(origin: Vector3, rotation: Vector3, scale: Vector3) -> Transform3D:
    return Transform3D(Basis.from_euler(rotation).scaled(scale), origin)


func _materialize_source_mesh_cached(mesh_recipe: Dictionary,
        fingerprint_cache: Dictionary) -> Variant:
    var recipe_cache: Dictionary = fingerprint_cache.get("meshRecipes", {}) \
        if fingerprint_cache.get("meshRecipes", {}) is Dictionary else {}
    var recipe_key := Marshalls.raw_to_base64(var_to_bytes(mesh_recipe)).sha256_text()
    var entry: Variant = recipe_cache.get(recipe_key, null)
    if entry is Dictionary and entry.get("recipe", {}) == mesh_recipe:
        var cached_mesh: Variant = entry.get("mesh", null)
        if cached_mesh is Mesh and is_instance_valid(cached_mesh):
            return cached_mesh
    var mesh_value: Variant = _materialize_source_mesh(mesh_recipe)
    if mesh_value is Mesh and is_instance_valid(mesh_value):
        recipe_cache[recipe_key] = {"recipe":mesh_recipe.duplicate(true),
            "mesh":mesh_value}
        fingerprint_cache["meshRecipes"] = recipe_cache
    return mesh_value


func _primitive_recipe(identity: String, primitive: String, parameters: Dictionary) -> Dictionary:
    return {"identity": identity, "version": 1, "primitive": primitive,
        "parameters": parameters}


func _source_render_member(member_id: String, node_name: String, mesh_recipe: Dictionary,
        transform: Transform3D, material_key: String, fallback_material_keys: Array,
        render_layer: String, fingerprint_cache: Dictionary = {}) -> Dictionary:
    var mesh_value: Variant = _materialize_source_mesh_cached(mesh_recipe, fingerprint_cache)
    var selected_material_key := material_key
    var material_value: Variant = materials.get(selected_material_key) \
        if materials is Dictionary else null
    if not material_value is Material:
        for fallback_value: Variant in fallback_material_keys:
            var fallback_key := String(fallback_value)
            var fallback_material: Variant = materials.get(fallback_key) \
                if materials is Dictionary else null
            if fallback_material is Material:
                selected_material_key = fallback_key
                material_value = fallback_material
                break
    var render_identity: Dictionary = {}
    if mesh_value is Mesh and material_value is Material:
        render_identity = ecology_render_member(member_id, mesh_value,
            transform, material_key, render_layer, material_value, fingerprint_cache)
    var identity_ready := String(render_identity.get("status", "")) == "ready"
    var mesh_bounds: Variant = render_identity.get("meshBounds", null)
    if not mesh_bounds is AABB:
        mesh_bounds = _recipe_mesh_bounds(mesh_recipe)
    var transformed_bounds := transform * (mesh_bounds as AABB)
    return {"memberId": member_id, "nodeName": node_name,
        "meshIdentity": String(mesh_recipe.identity), "meshVersion": int(mesh_recipe.version),
        "meshRecipe": mesh_recipe, "materialKey": material_key,
        "resolvedMaterialKey": selected_material_key,
        "meshContentDigest":String(render_identity.get("meshContentDigest", "")),
        "materialContentDigest":String(render_identity.get("materialContentDigest", "")),
        "resourceContentIdentitySchema":"ecology-render-member-content/v1",
        "contentIdentityStatus":"ready" if identity_ready else "pending",
        "contentIdentityReason":String(render_identity.get("reason", "")),
        "fallbackMaterialKeys": fallback_material_keys, "renderLayer": render_layer,
        "transform": transform, "meshBounds": mesh_bounds,
        "localBounds": transformed_bounds}


func _recipe_mesh_bounds(mesh_recipe: Dictionary) -> AABB:
    var parameters: Dictionary = mesh_recipe.parameters
    match String(mesh_recipe.primitive):
        "sphere":
            var radius := float(parameters.radius)
            var height := float(parameters.get("height", radius * 2.0))
            return AABB(Vector3(-radius, -height * 0.5, -radius),
                Vector3(radius * 2.0, height, radius * 2.0))
        "box":
            var size: Vector3 = parameters.size
            return AABB(-size * 0.5, size)
        "cylinder":
            var radius := maxf(float(parameters.bottomRadius), float(parameters.topRadius))
            var height := float(parameters.height)
            return AABB(Vector3(-radius, -height * 0.5, -radius),
                Vector3(radius * 2.0, height, radius * 2.0))
    return AABB()


func _materialize_source_render_members(body: StaticBody3D, members: Array) -> Array:
    var ecology_members: Array = []
    var mesh_cache: Dictionary = {}
    for member_value: Variant in members:
        if not member_value is Dictionary:
            continue
        var member: Dictionary = member_value
        var mesh_recipe: Dictionary = member.meshRecipe
        var mesh_identity := String(member.meshIdentity)
        var mesh: Mesh = mesh_cache.get(mesh_identity) as Mesh
        if mesh == null:
            mesh = _materialize_source_mesh(mesh_recipe)
            mesh_cache[mesh_identity] = mesh
        if mesh == null:
            ecology_members.append({"status": "pending",
                "reason": "source_member_mesh_unavailable",
                "memberId": String(member.memberId)})
            continue
        var material_key := String(member.materialKey)
        var material: Material = materials.get(material_key) as Material
        if material == null:
            for fallback_key_value: Variant in member.fallbackMaterialKeys:
                material = materials.get(String(fallback_key_value)) as Material
                if material != null:
                    break
        if material == null:
            ecology_members.append({"status": "pending",
                "reason": "source_member_material_unavailable",
                "memberId": String(member.memberId)})
            continue
        var instance := MeshInstance3D.new()
        var node_name := String(member.nodeName)
        if not node_name.is_empty():
            instance.name = node_name
        instance.mesh = mesh
        instance.material_override = material
        instance.transform = member.transform
        body.add_child(instance)
        ecology_members.append(ecology_render_member(String(member.memberId), mesh,
            instance.transform, material_key, String(member.renderLayer), material))
    return ecology_members


func _materialize_source_mesh(recipe: Dictionary) -> Mesh:
    var parameters: Dictionary = recipe.parameters
    var identity := String(recipe.identity)
    match identity:
        "aloe_leaf":
            return forage_cylinder_mesh(identity, float(parameters.bottomRadius),
                float(parameters.topRadius), float(parameters.height),
                int(parameters.radialSegments))
        "mushroom_stem", "frost_blade":
            return forage_cylinder_mesh(identity, float(parameters.bottomRadius),
                float(parameters.topRadius), float(parameters.height),
                int(parameters.radialSegments))
        "mushroom_cap", "berry_bush", "berry_fruit":
            return forage_sphere_mesh(identity, float(parameters.radius),
                float(parameters.height))
    match String(recipe.primitive):
        "sphere":
            var mesh := SphereMesh.new()
            mesh.radius = float(parameters.radius)
            mesh.height = float(parameters.get("height", mesh.radius * 2.0))
            mesh.radial_segments = int(parameters.get("radialSegments", 16))
            mesh.rings = int(parameters.get("rings", 8))
            return mesh
        "box":
            var mesh := BoxMesh.new()
            mesh.size = parameters.size
            return mesh
        "cylinder":
            var mesh := CylinderMesh.new()
            mesh.bottom_radius = float(parameters.bottomRadius)
            mesh.top_radius = float(parameters.topRadius)
            mesh.height = float(parameters.height)
            mesh.radial_segments = int(parameters.radialSegments)
            return mesh
    return null

func make_wildlife(parent: Node, prop_id: String, position: Vector3, biome: String, rng: RandomNumberGenerator):
    var horizon_only := bool(parent.get_meta("horizon_visual_only", false))
    var profile := wildlife_profile(biome, rng)
    var cold := bool(profile.get("cold", false))
    var body := StaticBody3D.new()
    if not horizon_only:
        body.add_to_group(&"world_moving_physics_actor")
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

    if not horizon_only:
        var shape := BoxShape3D.new()
        shape.size = profile.get("collider_size", Vector3(1.18, 1.05, 0.78))
        var collider := CollisionShape3D.new()
        collider.shape = shape
        collider.position.y = float(profile.get("collider_y", 0.52))
        body.add_child(collider)
    parent.add_child(body)
    if not horizon_only and npc_system and npc_system.has_method("notify_navigation_prop_created"):
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


## Captures the deterministic wildlife spawn intent without making an actor
## Node. This consumes the same seeded draws as make_wildlife, including the
## presentation-dependent draws, so later static producers keep their stream.
func build_wildlife_actor_intent(prop_id: String, position: Vector3,
        biome: String, rng: RandomNumberGenerator,
        animated_owner_receipt: Dictionary = {}) -> Dictionary:
    if rng == null or prop_id.is_empty():
        return {"status":"failed", "reason":"wildlife_actor_intent_inputs_invalid"}
    var profile := wildlife_profile(biome, rng)
    var body_rotation := rng.randf() * TAU
    var drop_count := rng.randi_range(1,
        int(profile.get("drop_max", 2 if bool(profile.get("cold", false)) else 3)))
    var extra_drop_count := rng.randi_range(1, int(profile.get("extra_drop_max", 2)))
    var presentation_mode := "procedural"
    var descriptor: Dictionary = {}
    var presentation_scale := 1.0
    var animation_speed := 1.0
    if animated_asset_registry != null \
            and animated_asset_registry.has_method("instantiate_asset"):
        if animated_owner_receipt.is_empty() \
                or not animated_asset_registry.has_method(
                    "presentation_descriptor_for_publication"):
            return _wildlife_actor_intent_failure(prop_id, biome, profile,
                "wildlife_presentation_descriptor_api_unavailable", {})
        descriptor = animated_asset_registry.call(
            "presentation_descriptor_for_publication", animated_owner_receipt,
            String(profile.get("asset", "")))
        if not bool(descriptor.get("branchProofAvailable", false)) \
                or not bool(descriptor.get("rootNode3DCompatible", false)):
            return _wildlife_actor_intent_failure(prop_id, biome, profile,
                String(descriptor.get("reason", "wildlife_presentation_branch_unproven")),
                descriptor)
        if descriptor.get("status", "") == "failed":
            # A valid Node3D scene can still instantiate when its expected clip
            # is absent; the live path still attaches the scene. Keep the empty
            # animation name from playing, while preserving the live path's
            # animation-speed draw whenever an AnimationPlayer exists.
            pass
        elif descriptor.get("status", "") != "ready" \
                or String(descriptor.get("reason", "")) == "stale":
            return _wildlife_actor_intent_failure(prop_id, biome, profile,
                "wildlife_presentation_descriptor_stale_or_pending", descriptor)
        presentation_mode = "animated_scene"
        presentation_scale = float(profile.get("scale", 1.0)) * rng.randf_range(0.92, 1.08)
        if bool(descriptor.get("animationPlayerPresent", false)):
            animation_speed = rng.randf_range(0.75, 1.10)
    else:
        # Matches the procedural fallback's only seeded presentation draws.
        var body_radius := 0.42 + rng.randf() * 0.08
        var body_height := 0.72 + rng.randf() * 0.10
        descriptor = {"presentation":presentation_mode,
            "bodyRadius":body_radius, "bodyHeight":body_height}
    var direction_angle := rng.randf() * TAU
    var timer := rng.randf_range(0.8, 2.6)
    var speed := rng.randf_range(0.42, 0.74) \
        * (0.86 if bool(profile.get("cold", false)) else 1.0) \
        * float(profile.get("speed_multiplier", 1.0))
    return {"status":"ready", "schema":"ecology-wildlife-actor-intent/v1",
        "propId":prop_id, "position":position, "biome":biome,
        "variant":String(profile.get("variant", "boar")),
        "profile":profile, "bodyRotationY":body_rotation,
        "dropCount":drop_count, "extraDropCount":extra_drop_count,
        "presentationMode":presentation_mode,
        "presentationScale":presentation_scale,
        "animationSpeed":animation_speed,
        "presentationDescriptor":_wildlife_descriptor_intent_value(descriptor),
        "wildlifeDirection":Vector3(cos(direction_angle), 0.0, sin(direction_angle)).normalized(),
        "wildlifeTimer":timer, "wildlifeSpeed":speed}


func _wildlife_actor_intent_failure(prop_id: String, biome: String,
        profile: Dictionary, reason: String, descriptor: Dictionary) -> Dictionary:
    var descriptor_details: Dictionary = {}
    for field: String in ["assetId", "status", "reason", "schemaVersion",
            "sceneResourcePath", "sceneInstanceId", "sceneStateDigest",
            "semanticSceneStateDigest", "rootNodeType", "animationPlayerPath",
            "expectedClip", "expectedClipAvailable", "failureStage",
            "failureNodePath", "failureNodeType"]:
        if descriptor.has(field):
            descriptor_details[field] = descriptor[field]
    var clips: Array[String] = []
    var clips_value: Variant = descriptor.get("availableClips", [])
    if clips_value is Array:
        for clip_value: Variant in clips_value:
            if clips.size() >= 8:
                break
            if clip_value is String:
                clips.append(String(clip_value))
    if not clips.is_empty():
        descriptor_details["availableClips"] = clips
    var diagnostic_value: Variant = descriptor.get("diagnostic", null)
    if diagnostic_value is Dictionary:
        var diagnostic: Dictionary = {}
        for field: String in ["stage", "reason", "assetPath", "sceneStatePath",
                "nodePath", "nodeType", "propertyName", "propertyVariantType",
                "propertyClass", "animationLibraryKey"]:
            var value: Variant = diagnostic_value.get(field, null)
            if value is String or value is int or value is bool:
                diagnostic[field] = value
        if not diagnostic.is_empty():
            descriptor_details["diagnostic"] = diagnostic
    var registry_receipt: Variant = descriptor.get("registryReceipt", null)
    if registry_receipt is Dictionary:
        descriptor_details["registryReceipt"] = {
            "ownerInstanceId":int(registry_receipt.get("ownerInstanceId", 0)),
            "revision":int(registry_receipt.get("revision", 0)),
            "ready":bool(registry_receipt.get("ready", false))}
    var asset_id := String(profile.get("asset", descriptor.get("assetId", "")))
    var variant := String(profile.get("variant", ""))
    var failure_details := {"stage":"wildlife_actor_intent",
        "reason":reason, "sourceId":prop_id, "propId":prop_id,
        "biome":biome, "variant":variant, "assetId":asset_id,
        "descriptor":descriptor_details}
    return {"status":"failed", "reason":reason, "propId":prop_id,
        "biome":biome, "variant":variant, "assetId":asset_id,
        "failureDetails":failure_details}


func _wildlife_descriptor_intent_value(descriptor: Dictionary) -> Dictionary:
    if descriptor.has("presentation"):
        return descriptor.duplicate(true)
    var path := String(descriptor.get("sceneResourcePath", ""))
    var resource_digest := FileAccess.get_sha256(ProjectSettings.globalize_path(path)) \
        if not path.is_empty() and FileAccess.file_exists(ProjectSettings.globalize_path(path)) else ""
    return {"assetId":String(descriptor.get("assetId", "")),
        "sceneResourcePath":path, "sceneContentDigest":resource_digest,
        "rootNodeType":String(descriptor.get("rootNodeType", "")),
        "animationPlayerPresent":bool(descriptor.get("animationPlayerPresent", false)),
        "animationPlayerPath":String(descriptor.get("animationPlayerPath", "")),
        "availableClips":descriptor.get("availableClips", []).duplicate(),
        "expectedClip":String(descriptor.get("expectedClip", "")),
        "expectedClipAvailable":bool(descriptor.get("expectedClipAvailable", false))}


func _wildlife_descriptor_identity_matches(descriptor: Dictionary,
        current_descriptor: Dictionary) -> bool:
    if not bool(descriptor.get("branchProofAvailable", false)) \
            or not bool(current_descriptor.get("branchProofAvailable", false)):
        return false
    for field: String in ["registryReceipt", "assetId", "sceneResourcePath",
            "sceneInstanceId", "sceneStateDigest", "rootNodeType",
            "animationPlayerPresent", "animationPlayerPath", "availableClips",
            "expectedClip", "expectedClipAvailable", "dependencies"]:
        if descriptor.get(field, null) != current_descriptor.get(field, null):
            return false
    return true

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
    return player_flat.distance_to(target_flat) <= placement_action_reach_distance()

func placement_action_reach_distance() -> float:
    return ACTION_REACH

func hit_within_action_reach(hit: Dictionary) -> bool:
    if player == null or not hit.has("position"):
        return false
    var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
    var target_flat := Vector2(hit_position.x, hit_position.z)
    var player_flat := Vector2(player.global_position.x, player.global_position.z)
    var allowed_reach := ACTION_REACH
    var collider := hit.get("collider") as Node
    # Monumental tree bodies keep real trunk collision.  Their bark may be
    # farther from the player's center than a small prop, so permit a tool to
    # reach the visible collision surface without extending placement, combat,
    # terrain, or ordinary-prop interaction range.
    if collider != null and String(collider.get_meta("kind", "")) == "prop" and String(collider.get_meta("material", "")) == "tree":
        var trunk_radius := maxf(0.12, float(collider.get_meta("tree_trunk_radius", 0.36)))
        allowed_reach = maxf(allowed_reach, minf(monumental_tree_melee_ray_range(), trunk_radius + CELL * 1.20))
    return player_flat.distance_to(target_flat) <= allowed_reach

func monumental_tree_melee_ray_range() -> float:
    # This is a ray ceiling, not a global melee-range increase.  The collision
    # and material checks in hit_within_action_reach still reject every
    # non-tree target beyond ACTION_REACH.
    return maxf(MELEE_RANGE, CELL * 7.20)

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
