extends RefCounted
class_name HostileVisualFactory

const CharacterAssetRegistryScript := preload("res://scripts/visual/CharacterAssetRegistry.gd")

var character_assets
var enemy_material: StandardMaterial3D
var eye_material: StandardMaterial3D
var frost_material: StandardMaterial3D
var frost_eye_material: StandardMaterial3D
var rift_material: StandardMaterial3D
var rift_eye_material: StandardMaterial3D
var wolf_material: StandardMaterial3D
var wolf_accent_material: StandardMaterial3D
var wolf_eye_material: StandardMaterial3D

func _init() -> void:
    setup_materials()
    character_assets = CharacterAssetRegistryScript.new()
    if not character_assets.setup():
        push_warning("Character visual registry loaded with hostile fallbacks: %s" % str(character_assets.last_errors))

func setup_materials() -> void:
    enemy_material = make_material(Color(0.13, 0.14, 0.25), Color(0.05, 0.08, 0.22), 0.72)
    eye_material = make_material(Color(0.66, 0.92, 1.0), Color(0.35, 0.75, 1.0), 0.5)
    frost_material = make_material(Color(0.18, 0.30, 0.38), Color(0.07, 0.18, 0.26), 0.66)
    frost_eye_material = make_material(Color(0.74, 0.95, 1.0), Color(0.32, 0.84, 1.0), 0.5)
    rift_material = make_material(Color(0.11, 0.08, 0.19), Color(0.23, 0.08, 0.37), 0.58)
    rift_eye_material = make_material(Color(1.0, 0.46, 0.94), Color(1.0, 0.28, 0.88), 0.5)
    wolf_material = make_material(Color(0.29, 0.31, 0.30), Color(0.035, 0.045, 0.04), 0.88)
    wolf_accent_material = make_material(Color(0.18, 0.20, 0.18), Color(0.02, 0.025, 0.02), 0.92)
    wolf_eye_material = make_material(Color(0.98, 0.75, 0.26), Color(0.76, 0.39, 0.05), 0.36)

func make_material(albedo: Color, emission: Color, roughness: float) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = albedo
    material.emission_enabled = true
    material.emission = emission
    material.roughness = roughness
    return material

func variant_spec(variant: String) -> Dictionary:
    match variant:
        "wolf":
            return {
                "health": 74.0,
                "scale": 1.0,
                "colliderRadius": 0.34,
                "colliderHeight": 0.94,
                "colliderCenterY": 0.47,
                "material": wolf_material,
                "accentMaterial": wolf_accent_material,
                "eyeMaterial": wolf_eye_material
            }
        "seer":
            return {
                "health": 20.0,
                "scale": 0.92,
                "material": enemy_material,
                "eyeMaterial": rift_eye_material
            }
        "frost":
            return {
                "health": 22.0,
                "scale": 1.0,
                "material": frost_material,
                "eyeMaterial": frost_eye_material
            }
        "rift":
            return {
                "health": 92.0,
                "scale": 1.55,
                "material": rift_material,
                "eyeMaterial": rift_eye_material
            }
    return {
        "health": 18.0,
        "scale": 1.0,
        "material": enemy_material,
        "eyeMaterial": eye_material
    }

func build_visual(body: Node3D, variant: String) -> Dictionary:
    var spec := variant_spec(variant)
    var scale: float = float(spec.get("scale", 1.0))
    var visual_material: StandardMaterial3D = spec.get("material", enemy_material)
    var visual_eye_material: StandardMaterial3D = spec.get("eyeMaterial", eye_material)

    if variant == "wolf":
        add_wolf_visual(body, scale, visual_material, spec.get("accentMaterial", wolf_accent_material), visual_eye_material)
    elif not add_generated_visual(body, variant, scale, visual_material, visual_eye_material):
        add_primitive_visual(body, variant, scale, visual_material, visual_eye_material)

    var shape := CapsuleShape3D.new()
    shape.radius = float(spec.get("colliderRadius", 0.42)) * scale
    shape.height = float(spec.get("colliderHeight", 1.65)) * scale
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.position.y = float(spec.get("colliderCenterY", 0.82)) * scale
    body.add_child(collider)
    return spec

func add_generated_visual(body: Node3D, variant: String, scale: float, visual_material: StandardMaterial3D, visual_eye_material: StandardMaterial3D) -> bool:
    if character_assets == null or not character_assets.is_ready():
        return false
    var visual_variant := variant if variant in ["shadow", "frost", "seer", "rift", "skitter"] else "shadow"
    var material_map := {
        "hostile": visual_material,
        "frost": visual_material,
        "hostile_accent": visual_eye_material,
        "hostile_eye": visual_eye_material,
        "rift_core": visual_eye_material
    }
    var torso: Node3D = character_assets.instantiate_exact_or_family("hostile_torso_%s" % visual_variant, "hostile_torso", "%s:torso" % visual_variant)
    var head: Node3D = character_assets.instantiate_exact_or_family("hostile_head_%s" % visual_variant, "hostile_head", "%s:head" % visual_variant)
    var eyes: Node3D = character_assets.instantiate_family("hostile_eye", "%s:eyes" % visual_variant)
    var parts: Array = [torso, head, eyes]
    var core: Node3D = null
    var shards: Array = []
    if variant == "rift":
        core = character_assets.instantiate_family("hostile_core", "rift:core")
        parts.append(core)
        for i in range(5):
            var shard: Node3D = character_assets.instantiate_family("hostile_shard", "rift:shard:%d" % i)
            shards.append(shard)
            parts.append(shard)
    for part in parts:
        if part == null:
            for cleanup in parts:
                if cleanup != null:
                    cleanup.queue_free()
            return false

    add_character_part(body, torso, "HostileTorso", Vector3(0.0, 0.02 * scale, 0.0), Vector3.ZERO, Vector3.ONE * scale, material_map)
    add_character_part(body, head, "HostileHead", Vector3(0.0, 1.22 * scale, -0.01 * scale), Vector3.ZERO, Vector3.ONE * scale, material_map)
    add_character_part(body, eyes, "HostileEyes", Vector3(0.0, 1.48 * scale, -0.24 * scale), Vector3.ZERO, Vector3.ONE * scale, material_map)
    if core != null:
        add_character_part(body, core, "HostileRiftCore", Vector3(0.0, 0.92 * scale, -0.30 * scale), Vector3.ZERO, Vector3.ONE * scale, material_map)
        for i in range(shards.size()):
            var shard_node := shards[i] as Node3D
            var shard_angle: float = (float(i) / float(maxi(1, shards.size()))) * TAU
            add_character_part(
                body,
                shard_node,
                "HostileRiftShard_%d" % i,
                Vector3(cos(shard_angle) * 0.54 * scale, 1.78 * scale, sin(shard_angle) * 0.54 * scale),
                Vector3(0.0, -shard_angle, PI * 0.16),
                Vector3.ONE * scale,
                material_map
            )
    body.set_meta("visual_source", "character_asset")
    body.set_meta("character_asset_parts", character_asset_ids(parts))
    return true

func add_character_part(body: Node3D, part: Node3D, part_name: String, position: Vector3, rotation: Vector3, scale: Vector3, material_map: Dictionary) -> void:
    part.name = part_name
    part.position = position
    part.rotation = rotation
    part.scale = scale
    character_assets.apply_material_map(part, material_map)
    body.add_child(part)

func character_asset_ids(parts: Array) -> Array[String]:
    var result: Array[String] = []
    for part in parts:
        if part != null:
            result.append(String(part.get_meta("visual_asset_id", "")))
    return result

func add_primitive_visual(body: Node3D, variant: String, scale: float, visual_material: StandardMaterial3D, visual_eye_material: StandardMaterial3D) -> void:
    var body_mesh := CylinderMesh.new()
    body_mesh.top_radius = 0.34 * scale
    body_mesh.bottom_radius = 0.46 * scale
    body_mesh.height = 1.25 * scale
    body_mesh.radial_segments = 8
    var body_instance := MeshInstance3D.new()
    body_instance.mesh = body_mesh
    body_instance.material_override = visual_material
    body_instance.position.y = 0.64 * scale
    body.add_child(body_instance)

    var head_mesh := SphereMesh.new()
    head_mesh.radius = 0.34 * scale
    head_mesh.height = 0.52 * scale
    head_mesh.radial_segments = 8
    head_mesh.rings = 4
    var head := MeshInstance3D.new()
    head.mesh = head_mesh
    head.material_override = visual_material
    head.position.y = 1.45 * scale
    body.add_child(head)

    for x in [-0.13, 0.13]:
        var eye_mesh := SphereMesh.new()
        eye_mesh.radius = 0.045 * scale
        eye_mesh.height = 0.07 * scale
        var eye := MeshInstance3D.new()
        eye.mesh = eye_mesh
        eye.material_override = visual_eye_material
        eye.position = Vector3(x * scale, 1.50 * scale, -0.29 * scale)
        body.add_child(eye)

    if variant == "seer":
        add_seer_halo(body, scale, visual_eye_material)
    elif variant == "rift":
        add_rift_core(body, scale, visual_eye_material)
    body.set_meta("visual_source", "primitive_fallback")
    body.set_meta("character_asset_parts", [])

func add_wolf_visual(body: Node3D, scale: float, fur_material: Material, accent_material: Material, eye_material_override: Material) -> void:
    # The authored wolf stays in the normal hostile visual factory rather than
    # being an arena-only mesh. Its intentionally chunky construction keeps the
    # existing cozy voxel silhouette while presenting a low, readable predator.
    add_box_part(body, "WolfBody", Vector3(0.82, 0.50, 1.34) * scale, Vector3(0.0, 0.66, 0.05) * scale, fur_material)
    add_box_part(body, "WolfShoulders", Vector3(0.72, 0.38, 0.52) * scale, Vector3(0.0, 0.83, -0.48) * scale, accent_material)
    add_box_part(body, "WolfHead", Vector3(0.56, 0.48, 0.54) * scale, Vector3(0.0, 1.00, -0.72) * scale, fur_material)
    add_box_part(body, "WolfMuzzle", Vector3(0.36, 0.26, 0.32) * scale, Vector3(0.0, 0.91, -1.05) * scale, accent_material)
    for x in [-0.21, 0.21]:
        add_cone_part(body, "WolfEar", 0.17 * scale, 0.0, 0.42 * scale, Vector3(x * scale, 1.37, -0.72) * scale, fur_material)
        add_box_part(body, "WolfEye", Vector3(0.075, 0.075, 0.05) * scale, Vector3(x * scale, 1.06, -1.01) * scale, eye_material_override)
    for x in [-0.28, 0.28]:
        for z in [-0.38, 0.50]:
            add_box_part(body, "WolfLeg", Vector3(0.16, 0.52, 0.18) * scale, Vector3(x * scale, 0.27, z) * scale, fur_material)
            add_box_part(body, "WolfPaw", Vector3(0.20, 0.11, 0.30) * scale, Vector3(x * scale, 0.055, (z + 0.05)) * scale, accent_material)
    var tail := CylinderMesh.new()
    tail.top_radius = 0.10 * scale
    tail.bottom_radius = 0.18 * scale
    tail.height = 0.92 * scale
    tail.radial_segments = 5
    var tail_instance := MeshInstance3D.new()
    tail_instance.name = "WolfTail"
    tail_instance.mesh = tail
    tail_instance.material_override = fur_material
    tail_instance.position = Vector3(0.0, 0.86, 0.86) * scale
    tail_instance.rotation_degrees = Vector3(0.0, 0.0, -54.0)
    body.add_child(tail_instance)
    body.set_meta("visual_source", "authored_wolf_factory")
    body.set_meta("character_asset_parts", [])

func add_box_part(body: Node3D, part_name: String, size: Vector3, position: Vector3, material: Material) -> void:
    var mesh := BoxMesh.new()
    mesh.size = size
    var instance := MeshInstance3D.new()
    instance.name = part_name
    instance.mesh = mesh
    instance.material_override = material
    instance.position = position
    body.add_child(instance)

func add_cone_part(body: Node3D, part_name: String, bottom_radius: float, top_radius: float, height: float, position: Vector3, material: Material) -> void:
    var mesh := CylinderMesh.new()
    mesh.bottom_radius = bottom_radius
    mesh.top_radius = top_radius
    mesh.height = height
    mesh.radial_segments = 4
    var instance := MeshInstance3D.new()
    instance.name = part_name
    instance.mesh = mesh
    instance.material_override = material
    instance.position = position
    body.add_child(instance)

func add_seer_halo(body: Node3D, scale: float, material: Material) -> void:
    var halo_mesh := TorusMesh.new()
    halo_mesh.inner_radius = 0.28 * scale
    halo_mesh.outer_radius = 0.34 * scale
    var halo := MeshInstance3D.new()
    halo.mesh = halo_mesh
    halo.material_override = material
    halo.position.y = 1.73 * scale
    halo.rotation.x = PI * 0.5
    body.add_child(halo)

func add_rift_core(body: Node3D, scale: float, material: Material) -> void:
    var core_mesh := SphereMesh.new()
    core_mesh.radius = 0.28 * scale
    core_mesh.height = 0.42 * scale
    core_mesh.radial_segments = 8
    core_mesh.rings = 4
    var core := MeshInstance3D.new()
    core.mesh = core_mesh
    core.material_override = material
    core.position.y = 1.16 * scale
    body.add_child(core)
    for i in range(5):
        var shard_mesh := CylinderMesh.new()
        shard_mesh.top_radius = 0.0
        shard_mesh.bottom_radius = 0.07 * scale
        shard_mesh.height = 0.46 * scale
        shard_mesh.radial_segments = 5
        var shard := MeshInstance3D.new()
        var shard_angle: float = (float(i) / 5.0) * TAU
        shard.mesh = shard_mesh
        shard.material_override = material
        shard.position = Vector3(cos(shard_angle) * 0.55 * scale, 1.86 * scale, sin(shard_angle) * 0.55 * scale)
        shard.rotation.y = -shard_angle
        shard.rotation.z = PI * 0.16
        body.add_child(shard)
