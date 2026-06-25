extends RefCounted
class_name NpcVisualFactory

const CharacterAssetRegistryScript := preload("res://scripts/visual/CharacterAssetRegistry.gd")

var main
var character_assets
var cloth_materials: Array[StandardMaterial3D] = []
var accent_materials: Array[StandardMaterial3D] = []
var skin_material: StandardMaterial3D
var arrow_material: StandardMaterial3D

func setup(main_node) -> void:
    main = main_node
    cloth_materials = [
        make_material(Color(0.45, 0.31, 0.22), 0.82),
        make_material(Color(0.30, 0.39, 0.34), 0.82),
        make_material(Color(0.42, 0.36, 0.50), 0.80),
        make_material(Color(0.48, 0.42, 0.28), 0.84)
    ]
    accent_materials = [
        make_material(Color(0.82, 0.63, 0.34), 0.72),
        make_material(Color(0.64, 0.78, 0.70), 0.74),
        make_material(Color(0.72, 0.48, 0.38), 0.76),
        make_material(Color(0.66, 0.70, 0.86), 0.72)
    ]
    skin_material = make_material(Color(0.76, 0.55, 0.39), 0.70)
    arrow_material = StandardMaterial3D.new()
    arrow_material.albedo_color = Color(0.93, 0.78, 0.42, 0.90)
    arrow_material.emission_enabled = true
    arrow_material.emission = Color(0.62, 0.38, 0.10)
    arrow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    arrow_material.roughness = 0.68
    character_assets = CharacterAssetRegistryScript.new()
    if not character_assets.setup():
        push_warning("Character visual registry loaded with NPC fallbacks: %s" % str(character_assets.last_errors))

func body_material(index: int) -> StandardMaterial3D:
    return cloth_materials[posmod(index, cloth_materials.size())]

func accent_material(index: int) -> StandardMaterial3D:
    return accent_materials[posmod(index, accent_materials.size())]

func npc_weapon_is_ranged(weapon_id: String) -> bool:
    return weapon_id in ["hunterBow", "ironCrossbow"]

func npc_weapon_is_melee(weapon_id: String) -> bool:
    return weapon_id.ends_with("Sword") or weapon_id == "nightBlade"

func ensure_held_item(entry: Dictionary) -> void:
    var body := entry.get("body") as Node3D
    var weapon_id := String(entry.get("weaponId", ""))
    if body == null or weapon_id == "":
        return
    for child in body.get_children():
        if child.name == "NpcHeldItemAnchor":
            body.remove_child(child)
            child.queue_free()
    var anchor := Node3D.new()
    anchor.name = "NpcHeldItemAnchor"
    anchor.position = held_rest_position(weapon_id)
    anchor.rotation = held_rest_rotation(weapon_id)
    var visual: Node3D = null
    var factory = main.get("item_visual_factory") if main != null else null
    if factory != null and factory.has_method("make_held_item"):
        visual = factory.make_held_item(weapon_id)
    if visual == null:
        visual = make_fallback_weapon_visual(weapon_id)
    if visual != null:
        anchor.add_child(visual)
    body.add_child(anchor)
    entry["heldAnchor"] = anchor
    entry["heldVisual"] = visual
    entry["heldRestPosition"] = anchor.position
    entry["heldRestRotation"] = anchor.rotation
    body.set_meta("npc_weapon_visible", visual != null)

func make_fallback_weapon_visual(weapon_id: String) -> Node3D:
    var root := Node3D.new()
    root.name = "NpcFallbackWeapon_%s" % weapon_id
    var mesh := BoxMesh.new()
    mesh.size = Vector3(0.08, 0.72, 0.08) if npc_weapon_is_melee(weapon_id) else Vector3(0.08, 0.52, 0.08)
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.material_override = accent_materials[0] if accent_materials.size() > 0 else null
    root.add_child(instance)
    return root

func held_rest_position(weapon_id: String) -> Vector3:
    if npc_weapon_is_ranged(weapon_id):
        return Vector3(0.42, 0.88, -0.20)
    if npc_weapon_is_melee(weapon_id):
        return Vector3(0.43, 0.78, -0.06)
    return Vector3(0.40, 0.78, -0.12)

func held_rest_rotation(weapon_id: String) -> Vector3:
    if npc_weapon_is_ranged(weapon_id):
        return Vector3(deg_to_rad(-8.0), deg_to_rad(4.0), deg_to_rad(-14.0))
    if npc_weapon_is_melee(weapon_id):
        return Vector3(deg_to_rad(18.0), deg_to_rad(0.0), deg_to_rad(-28.0))
    return Vector3.ZERO

func update_held_animation(entry: Dictionary, delta: float) -> void:
    var anchor := entry.get("heldAnchor") as Node3D
    if anchor == null or not is_instance_valid(anchor):
        return
    var weapon_id := String(entry.get("weaponId", ""))
    var rest_position: Vector3 = entry.get("heldRestPosition", held_rest_position(weapon_id))
    var rest_rotation: Vector3 = entry.get("heldRestRotation", held_rest_rotation(weapon_id))
    var duration := maxf(0.001, float(entry.get("useDuration", 0.0)))
    var remaining := maxf(0.0, float(entry.get("useAnim", 0.0)) - delta)
    entry["useAnim"] = remaining
    anchor.position = rest_position
    anchor.rotation = rest_rotation
    if remaining <= 0.0:
        return
    var progress := clampf(1.0 - remaining / duration, 0.0, 1.0)
    var pulse := sin(progress * PI)
    var action := String(entry.get("useAction", ""))
    if action == "shoot":
        anchor.position += Vector3(0.0, 0.02 * pulse, -0.16 * pulse)
        anchor.rotation.x += deg_to_rad(-13.0 * pulse)
        anchor.rotation.y += deg_to_rad(5.0 * pulse)
        anchor.rotation.z += deg_to_rad(-10.0 * pulse)
    elif action == "strike":
        anchor.position += Vector3(-0.05 * pulse, 0.05 * pulse, -0.06 * pulse)
        anchor.rotation.x += deg_to_rad(-38.0 * pulse)
        anchor.rotation.y += deg_to_rad(20.0 * pulse)
        anchor.rotation.z += deg_to_rad(-66.0 * pulse)
    else:
        anchor.position += Vector3(0.0, 0.02 * pulse, -0.04 * pulse)

func add_collider(parent: Node3D) -> void:
    if parent == null:
        return
    if parent.get_node_or_null("NpcCollider") != null:
        return
    var capsule := CapsuleShape3D.new()
    capsule.radius = 0.34
    capsule.height = 1.62
    var collider := CollisionShape3D.new()
    collider.name = "NpcCollider"
    collider.shape = capsule
    collider.position.y = 0.84
    parent.add_child(collider)

func add_visual(parent: Node3D, body_material: StandardMaterial3D, accent: StandardMaterial3D, npc_name: String, role: String) -> void:
    if add_generated_visual(parent, body_material, accent, npc_name, role):
        return
    add_primitive_visual(parent, body_material, accent, npc_name, role)

func add_generated_visual(parent: Node3D, body_material: StandardMaterial3D, accent: StandardMaterial3D, npc_name: String, role: String) -> bool:
    if character_assets == null or not character_assets.is_ready():
        return false
    var key := "%s:%s" % [npc_name, role]
    var material_map := {
        "cloth": body_material,
        "accent": accent,
        "skin": skin_material,
        "hair": accent
    }
    var torso: Node3D = character_assets.instantiate_family("npc_torso", key)
    var head: Node3D = character_assets.instantiate_family("npc_head", key)
    var headwear: Node3D = character_assets.instantiate_family("npc_headwear", "%s:headwear" % key)
    var arm_left: Node3D = character_assets.instantiate_family("npc_arm", "%s:left" % key)
    var arm_right: Node3D = character_assets.instantiate_family("npc_arm", "%s:right" % key)
    var parts: Array = [torso, head, headwear, arm_left, arm_right]
    for part in parts:
        if part == null:
            for cleanup in parts:
                if cleanup != null:
                    cleanup.queue_free()
            return false

    add_character_part(parent, torso, "NpcTorso", Vector3(0.0, 0.25, 0.0), Vector3.ZERO, Vector3.ONE, material_map)
    add_character_part(parent, head, "NpcHead", Vector3(0.0, 1.16, -0.01), Vector3.ZERO, Vector3.ONE, material_map)
    add_character_part(parent, headwear, "NpcHeadwear", Vector3(0.0, 1.34, -0.02), Vector3.ZERO, Vector3.ONE, material_map)
    add_character_part(parent, arm_left, "NpcArmLeft", Vector3(-0.31, 0.48, 0.0), Vector3(0.0, 0.0, -0.30), Vector3.ONE, material_map)
    add_character_part(parent, arm_right, "NpcArmRight", Vector3(0.31, 0.48, 0.0), Vector3(0.0, 0.0, 0.30), Vector3.ONE, material_map)
    add_name_label(parent, npc_name, role)
    parent.set_meta("visual_source", "character_asset")
    parent.set_meta("character_asset_parts", [
        String(torso.get_meta("visual_asset_id", "")),
        String(head.get_meta("visual_asset_id", "")),
        String(headwear.get_meta("visual_asset_id", "")),
        String(arm_left.get_meta("visual_asset_id", "")),
        String(arm_right.get_meta("visual_asset_id", ""))
    ])
    return true

func add_character_part(parent: Node3D, part: Node3D, part_name: String, position: Vector3, rotation: Vector3, scale: Vector3, material_map: Dictionary) -> void:
    part.name = part_name
    part.position = position
    part.rotation = rotation
    part.scale = scale
    character_assets.apply_material_map(part, material_map)
    parent.add_child(part)

func add_primitive_visual(parent: Node3D, body_material: StandardMaterial3D, accent: StandardMaterial3D, npc_name: String, role: String) -> void:
    var torso_mesh := CylinderMesh.new()
    torso_mesh.top_radius = 0.26
    torso_mesh.bottom_radius = 0.34
    torso_mesh.height = 0.92
    torso_mesh.radial_segments = 8
    var torso := MeshInstance3D.new()
    torso.mesh = torso_mesh
    torso.material_override = body_material
    torso.position.y = 0.72
    parent.add_child(torso)

    var head_mesh := SphereMesh.new()
    head_mesh.radius = 0.23
    head_mesh.height = 0.30
    head_mesh.radial_segments = 10
    head_mesh.rings = 6
    var head := MeshInstance3D.new()
    head.name = "PrimitiveNpcHead"
    head.mesh = head_mesh
    head.material_override = skin_material
    head.position.y = 1.34
    parent.add_child(head)

    var hood_mesh := SphereMesh.new()
    hood_mesh.radius = 0.26
    hood_mesh.height = 0.20
    hood_mesh.radial_segments = 9
    hood_mesh.rings = 4
    var hood := MeshInstance3D.new()
    hood.mesh = hood_mesh
    hood.material_override = accent
    hood.position = Vector3(0.0, 1.44, -0.03)
    hood.scale = Vector3(1.0, 0.54, 1.0)
    parent.add_child(hood)

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
    add_name_label(parent, npc_name, role)
    parent.set_meta("visual_source", "primitive_fallback")
    parent.set_meta("character_asset_parts", [])

func add_name_label(parent: Node3D, npc_name: String, role: String) -> void:
    var label := Label3D.new()
    label.name = "NpcNameLabel"
    label.text = "%s\n%s" % [npc_name, role]
    label.font_size = 26
    label.position.y = 1.88
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label.no_depth_test = false
    label.visible = false
    parent.add_child(label)

func make_material(color: Color, roughness: float) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = roughness
    return material
