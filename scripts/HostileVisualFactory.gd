extends RefCounted
class_name HostileVisualFactory

var enemy_material: StandardMaterial3D
var eye_material: StandardMaterial3D
var frost_material: StandardMaterial3D
var frost_eye_material: StandardMaterial3D
var rift_material: StandardMaterial3D
var rift_eye_material: StandardMaterial3D

func _init() -> void:
    setup_materials()

func setup_materials() -> void:
    enemy_material = make_material(Color(0.13, 0.14, 0.25), Color(0.05, 0.08, 0.22), 0.72)
    eye_material = make_material(Color(0.66, 0.92, 1.0), Color(0.35, 0.75, 1.0), 0.5)
    frost_material = make_material(Color(0.18, 0.30, 0.38), Color(0.07, 0.18, 0.26), 0.66)
    frost_eye_material = make_material(Color(0.74, 0.95, 1.0), Color(0.32, 0.84, 1.0), 0.5)
    rift_material = make_material(Color(0.11, 0.08, 0.19), Color(0.23, 0.08, 0.37), 0.58)
    rift_eye_material = make_material(Color(1.0, 0.46, 0.94), Color(1.0, 0.28, 0.88), 0.5)

func make_material(albedo: Color, emission: Color, roughness: float) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = albedo
    material.emission_enabled = true
    material.emission = emission
    material.roughness = roughness
    return material

func variant_spec(variant: String) -> Dictionary:
    match variant:
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

    var shape := CapsuleShape3D.new()
    shape.radius = 0.42 * scale
    shape.height = 1.65 * scale
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.position.y = 0.82 * scale
    body.add_child(collider)
    return spec

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
