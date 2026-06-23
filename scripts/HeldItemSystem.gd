extends Node3D
class_name HeldItemSystem

const ItemVisualFactoryScript := preload("res://scripts/ItemVisualFactory.gd")

var inventory
var item_root: Node3D
var current_item := ""
var use_action := ""
var use_time := 0.0
var use_duration := 0.28
var base_position := Vector3(0.46, -0.46, -0.78)
var base_rotation := Vector3(deg_to_rad(-9.0), deg_to_rad(20.0), deg_to_rad(-8.0))
var materials := {}
var visual_factory
var sway_enabled := true
var sway_time := 0.0
var local_light_shadows_enabled := true

func setup(inventory_system, static_asset_registry = null) -> void:
    inventory = inventory_system
    position = base_position
    rotation = base_rotation
    visual_factory = ItemVisualFactoryScript.new()
    if visual_factory and visual_factory.has_method("set_static_asset_registry"):
        visual_factory.set_static_asset_registry(static_asset_registry)
    setup_materials()
    item_root = Node3D.new()
    item_root.name = "HeldItemRoot"
    add_child(item_root)
    if inventory:
        inventory.changed.connect(refresh_active)
    refresh_active()
    set_process(true)

func setup_materials() -> void:
    materials["wood"] = make_material(Color(0.62, 0.39, 0.19), 0.82)
    materials["stone"] = make_material(Color(0.52, 0.56, 0.53), 0.90)
    materials["dirt"] = make_material(Color(0.38, 0.25, 0.15), 0.94)
    materials["glass"] = make_material(Color(0.55, 0.82, 0.92, 0.45), 0.12, true)
    materials["grass"] = make_material(Color(0.32, 0.62, 0.30), 0.84)
    materials["fish"] = make_material(Color(0.42, 0.72, 0.78), 0.56)
    materials["cooked"] = make_material(Color(0.78, 0.42, 0.24), 0.74)
    materials["metal"] = make_material(Color(0.68, 0.69, 0.66), 0.66)
    materials["accent"] = make_material(Color(0.86, 0.68, 0.34), 0.58)

func make_material(color: Color, roughness: float, transparent := false) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = roughness
    if transparent:
        material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    return material

func refresh_active() -> void:
    if not inventory or not item_root:
        return
    var stack: Dictionary = inventory.active_stack()
    var item_id := String(stack.get("item", ""))
    if item_id == current_item:
        return
    current_item = item_id
    clear_children(item_root)
    if current_item == "":
        visible = false
        return
    visible = true
    var visual: Node3D = visual_factory.make_held_item(current_item) if visual_factory else null
    if visual:
        item_root.add_child(visual)
        apply_local_light_shadows(item_root)
    else:
        visible = false

func _process(delta: float) -> void:
    sway_time += delta
    if use_time > 0.0:
        use_time = max(0.0, use_time - delta)
    apply_pose()

func set_sway_enabled(enabled: bool) -> void:
    sway_enabled = enabled
    apply_pose()

func set_local_light_shadows_enabled(enabled: bool) -> void:
    local_light_shadows_enabled = enabled
    apply_local_light_shadows(item_root)

func apply_local_light_shadows(node: Node) -> void:
    if node == null:
        return
    if node is Light3D and bool(node.get_meta("casts_shadow_when_enabled", false)):
        (node as Light3D).shadow_enabled = local_light_shadows_enabled
    for child in node.get_children():
        apply_local_light_shadows(child)

func play_use(action: String) -> void:
    use_action = action
    use_duration = 0.56 if action == "cast" else 0.48 if is_bow(current_item) else 0.28
    use_time = use_duration
    apply_pose()

func apply_pose() -> void:
    if current_item == "":
        return
    var t := 0.0
    if use_duration > 0.0:
        t = 1.0 - clamp(use_time / use_duration, 0.0, 1.0)
    position = base_position
    rotation = base_rotation
    if sway_enabled:
        var slow := sin(sway_time * 1.7)
        var quick := sin(sway_time * 3.4)
        position += Vector3(slow * 0.010, quick * 0.006, slow * 0.006)
        rotation.z += deg_to_rad(slow * 0.7)
    if use_time <= 0.0:
        return
    var arc := sin(t * PI)
    if use_action == "place":
        position += Vector3(-0.06 * arc, 0.03 * arc, -0.16 * arc)
        rotation.x += deg_to_rad(-8.0 * arc)
    elif is_bow(current_item):
        position += Vector3(-0.05 * arc, -0.02 * arc, 0.08 * arc)
        rotation.y += deg_to_rad(-12.0 * arc)
        rotation.z += deg_to_rad(9.0 * arc)
    elif use_action == "cast":
        position += Vector3(-0.12 * arc, 0.02 * arc, -0.20 * arc)
        rotation.x += deg_to_rad(-28.0 * arc)
        rotation.y += deg_to_rad(-10.0 * arc)
    else:
        position += Vector3(0.08 * arc, -0.03 * arc, -0.08 * arc)
        rotation.x += deg_to_rad(-36.0 * arc)
        rotation.z += deg_to_rad(18.0 * arc)

func build_block(item_id: String) -> void:
    var mesh := BoxMesh.new()
    mesh.size = Vector3(0.34, 0.34, 0.34)
    var block := MeshInstance3D.new()
    block.mesh = mesh
    block.material_override = material_for(item_id)
    block.rotation = Vector3(deg_to_rad(10.0), deg_to_rad(-18.0), deg_to_rad(6.0))
    item_root.add_child(block)

func build_resource(item_id: String) -> void:
    var mesh := SphereMesh.new()
    mesh.radius = 0.18
    mesh.height = 0.28
    mesh.radial_segments = 8
    mesh.rings = 4
    var resource := MeshInstance3D.new()
    resource.mesh = mesh
    resource.material_override = material_for(item_id)
    resource.scale = Vector3(1.2, 0.8, 1.0)
    item_root.add_child(resource)

func build_tool(item_id: String) -> void:
    var handle_mesh := CylinderMesh.new()
    handle_mesh.top_radius = 0.035
    handle_mesh.bottom_radius = 0.045
    handle_mesh.height = 0.68
    handle_mesh.radial_segments = 6
    var handle := MeshInstance3D.new()
    handle.mesh = handle_mesh
    handle.material_override = materials["wood"]
    handle.rotation.z = deg_to_rad(22.0)
    handle.position = Vector3(0.05, -0.02, 0.0)
    item_root.add_child(handle)

    var head_mesh := BoxMesh.new()
    if item_id.ends_with("Pickaxe"):
        head_mesh.size = Vector3(0.46, 0.09, 0.10)
    elif item_id.ends_with("Shovel"):
        head_mesh.size = Vector3(0.18, 0.24, 0.08)
    elif item_id.ends_with("Sword") or item_id == "nightBlade":
        head_mesh.size = Vector3(0.10, 0.54, 0.06)
    else:
        head_mesh.size = Vector3(0.30, 0.22, 0.08)
    var head := MeshInstance3D.new()
    head.mesh = head_mesh
    head.material_override = material_for(item_id)
    head.position = Vector3(-0.08, 0.31, 0.0)
    head.rotation.z = deg_to_rad(22.0)
    item_root.add_child(head)

func build_bow(item_id: String) -> void:
    var limb_mesh := CylinderMesh.new()
    limb_mesh.top_radius = 0.025
    limb_mesh.bottom_radius = 0.025
    limb_mesh.height = 0.62
    limb_mesh.radial_segments = 6
    for side in [-1, 1]:
        var limb := MeshInstance3D.new()
        limb.mesh = limb_mesh
        limb.material_override = materials["wood"] if item_id == "hunterBow" else materials["metal"]
        limb.position = Vector3(0.0, side * 0.16, 0.0)
        limb.rotation.z = deg_to_rad(16.0 * side)
        item_root.add_child(limb)
    var string_mesh := CylinderMesh.new()
    string_mesh.top_radius = 0.008
    string_mesh.bottom_radius = 0.008
    string_mesh.height = 0.70
    string_mesh.radial_segments = 5
    var string := MeshInstance3D.new()
    string.mesh = string_mesh
    string.material_override = materials["accent"]
    string.rotation.x = deg_to_rad(90.0)
    string.position.z = 0.02
    item_root.add_child(string)

func build_fishing_rod() -> void:
    var rod_mesh := CylinderMesh.new()
    rod_mesh.top_radius = 0.018
    rod_mesh.bottom_radius = 0.035
    rod_mesh.height = 0.96
    rod_mesh.radial_segments = 6
    var rod := MeshInstance3D.new()
    rod.mesh = rod_mesh
    rod.material_override = materials["wood"]
    rod.rotation.z = deg_to_rad(-28.0)
    rod.position = Vector3(0.06, 0.04, 0.0)
    item_root.add_child(rod)

    var line_mesh := CylinderMesh.new()
    line_mesh.top_radius = 0.004
    line_mesh.bottom_radius = 0.004
    line_mesh.height = 0.64
    line_mesh.radial_segments = 4
    var line := MeshInstance3D.new()
    line.mesh = line_mesh
    line.material_override = materials["accent"]
    line.rotation.x = deg_to_rad(88.0)
    line.position = Vector3(-0.15, 0.40, -0.18)
    item_root.add_child(line)

func is_block_like(item_id: String) -> bool:
    return item_id.ends_with("Block") or item_id in ["glass", "cobblestonePath", "workbench", "anvil", "door", "bed", "chest", "furnace", "campfire", "torch", "spikeTrap", "wardLantern", "sanctuaryBeacon", "riftAnchor"]

func is_tool(item_id: String) -> bool:
    return item_id.ends_with("Axe") or item_id.ends_with("Pickaxe") or item_id.ends_with("Shovel") or item_id.ends_with("Sword") or item_id == "nightBlade"

func is_bow(item_id: String) -> bool:
    return item_id == "hunterBow" or item_id == "ironCrossbow"

func material_for(item_id: String) -> Material:
    if item_id.find("wood") >= 0 or item_id in ["logs", "workbench", "door", "chest", "campfire", "torch"]:
        return materials["wood"]
    if item_id.find("stone") >= 0 or item_id in ["stones", "cobblestonePath", "furnace", "anvil"]:
        return materials["stone"]
    if item_id.find("iron") >= 0 or item_id.find("copper") >= 0 or item_id == "nightBlade":
        return materials["metal"]
    if item_id in ["dirt", "dirtBlock", "mud"]:
        return materials["dirt"]
    if item_id in ["glass", "sand"]:
        return materials["glass"]
    if item_id in ["grass", "berries", "aloe", "mirecap", "frostHerb"]:
        return materials["grass"]
    if item_id == "rawFish":
        return materials["fish"]
    if item_id == "cookedFish" or item_id == "cookedMeat" or item_id == "cookedBerries":
        return materials["cooked"]
    return materials["accent"]

func clear_children(node: Node) -> void:
    for child in node.get_children():
        child.queue_free()
