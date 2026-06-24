extends RefCounted
class_name ItemVisualFactory

const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")
const LocalLightRigScript := preload("res://scripts/LocalLightRig.gd")

var materials := {}
var static_item_asset_registry = null

func _init() -> void:
    setup_materials()

func set_static_asset_registry(registry) -> void:
    static_item_asset_registry = registry

func setup_materials() -> void:
    materials["wood"] = make_material(Color(0.66, 0.40, 0.20), 0.78)
    materials["wood_dark"] = make_material(Color(0.34, 0.18, 0.08), 0.86)
    materials["stone"] = make_material(Color(0.56, 0.60, 0.56), 0.88)
    materials["stone_dark"] = make_material(Color(0.30, 0.34, 0.32), 0.94)
    materials["dirt"] = make_material(Color(0.42, 0.28, 0.16), 0.94)
    materials["grass"] = make_material(Color(0.42, 0.72, 0.34), 0.84)
    materials["sand"] = make_material(Color(0.82, 0.70, 0.42), 0.88)
    materials["snow"] = make_material(Color(0.88, 0.92, 0.92), 0.70)
    materials["glass"] = make_material(Color(0.56, 0.86, 0.96, 0.42), 0.10, true)
    materials["copper"] = make_material(Color(0.78, 0.42, 0.20), 0.38, false, Color.BLACK, 0.0, 0.36)
    materials["iron"] = make_material(Color(0.78, 0.84, 0.80), 0.32, false, Color.BLACK, 0.0, 0.52)
    materials["night"] = make_material(Color(0.22, 0.26, 0.72), 0.34, false, Color(0.18, 0.26, 1.0), 0.85, 0.14)
    materials["ward"] = make_material(Color(0.36, 0.78, 0.92), 0.34, false, Color(0.18, 0.58, 0.95), 0.65, 0.10)
    materials["rift"] = make_material(Color(0.78, 0.34, 0.96), 0.26, false, Color(0.55, 0.08, 0.95), 1.15, 0.12)
    materials["gold"] = make_material(Color(0.92, 0.70, 0.32), 0.42, false, Color.BLACK, 0.0, 0.18)
    materials["leather"] = make_material(Color(0.50, 0.30, 0.16), 0.88)
    materials["cloth_red"] = make_material(Color(0.68, 0.20, 0.18), 0.82)
    materials["cloth_teal"] = make_material(Color(0.26, 0.46, 0.42), 0.78)
    materials["berry"] = make_material(Color(0.76, 0.16, 0.28), 0.58)
    materials["fish"] = make_material(Color(0.44, 0.74, 0.82), 0.48, false, Color.BLACK, 0.0, 0.05)
    materials["cooked"] = make_material(Color(0.72, 0.34, 0.18), 0.76)
    materials["herb"] = make_material(Color(0.48, 0.78, 0.44), 0.72)
    materials["frost"] = make_material(Color(0.72, 0.92, 0.96), 0.46, false, Color(0.28, 0.66, 0.78), 0.22)
    materials["flame"] = make_material(Color(1.0, 0.73, 0.42, 0.92), 0.30, true, Color(1.0, 0.68, 0.38), 1.10)
    materials["string"] = make_material(Color(0.92, 0.82, 0.62), 0.58)

func make_material(color: Color, roughness := 0.82, transparent := false, emission := Color.BLACK, emission_energy := 0.0, metalness := 0.0) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = roughness
    material.metallic = metalness
    if transparent:
        material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
    if emission_energy > 0.0:
        material.emission_enabled = true
        material.emission = emission
        material.emission_energy_multiplier = emission_energy
    return material

func make_pickup(item_id: String) -> Node3D:
    var root := Node3D.new()
    root.name = "ItemPickupVisual_%s" % item_id
    build_item(root, item_id, false)
    root.rotation = pickup_rotation(item_id)
    return root

func make_held_item(item_id: String) -> Node3D:
    var root := Node3D.new()
    root.name = "ItemHeldVisual_%s" % item_id
    build_item(root, item_id, true)
    apply_held_item_render_policy(root)
    root.rotation = held_rotation(item_id)
    var scale_value := held_scale(item_id)
    root.scale = Vector3(-scale_value, scale_value, scale_value) if should_mirror_right_hand_item(item_id) else Vector3.ONE * scale_value
    return root

func build_item(root: Node3D, item_id: String, held: bool) -> void:
    if item_id == "":
        return
    if try_build_static_item(root, item_id, held):
        return
    if item_id == "torch":
        build_torch(root, held)
    elif item_id == "campfire":
        build_campfire(root, held)
    elif item_id == "workbench":
        build_workbench(root, held)
    elif item_id == "anvil":
        build_anvil(root, held)
    elif item_id == "door":
        build_door(root, held)
    elif item_id == "bed":
        build_bed(root, held)
    elif item_id == "chest":
        build_chest(root, held)
    elif item_id == "furnace":
        build_furnace(root, held)
    elif item_id == "spikeTrap":
        build_spike_trap(root, held)
    elif item_id in ["wardLantern", "sanctuaryBeacon", "riftAnchor"]:
        build_ward_object(root, item_id, held)
    elif item_id == "hunterBow" or item_id == "ironCrossbow":
        build_bow(root, item_id, held)
    elif item_id == "fishingRod":
        build_fishing_rod(root, held)
    elif is_tool(item_id):
        build_tool(root, item_id, held)
    elif item_id in ["hideVest", "stoneArmor", "copperArmor", "ironArmor", "wardArmor"]:
        build_armor(root, item_id, held)
    elif item_id in ["trailPack", "expeditionPack"]:
        build_pack(root, item_id, held)
    elif item_id in ["trailCharm", "wardAmulet", "compass", "surveyLens"]:
        build_trinket(root, item_id, held)
    elif item_id.ends_with("Block") or item_id in ["glass", "cobblestonePath"]:
        build_block(root, item_id, held)
    elif item_id in ["logs", "stones", "dirt", "sand", "grass", "mud", "snow"]:
        build_basic_resource(root, item_id, held)
    elif item_id in ["berries", "cookedBerries", "aloe", "mirecap", "frostHerb"]:
        build_forage(root, item_id, held)
    elif item_id in ["rawFish", "cookedFish", "rawMeat", "cookedMeat", "fieldRation", "hunterStew", "aloeSalve", "wardTonic"]:
        build_food(root, item_id, held)
    elif item_id in ["copperOre", "ironOre", "copperVein", "ironVein", "copperIngot", "ironIngot", "nightShard", "relicFragment", "riftCore", "arrows"]:
        build_crafting_resource(root, item_id, held)
    else:
        build_generic(root, item_id, held)

func try_build_static_item(root: Node3D, item_id: String, held: bool) -> bool:
    if static_item_asset_registry == null:
        return false
    if not static_item_asset_registry.has_method("has_asset") or not static_item_asset_registry.has_asset(item_id):
        return false
    var visual: Node3D = static_item_asset_registry.instantiate_item(item_id)
    if visual == null:
        return false
    visual.name = "GeneratedStaticItem_%s" % item_id
    var scale_value := generated_item_scale(item_id, held)
    visual.scale = Vector3.ONE * scale_value
    root.add_child(visual)
    add_generated_item_extras(root, item_id, held, scale_value)
    return true

func apply_held_item_render_policy(node: Node) -> void:
    if node == null:
        return
    if node is MeshInstance3D:
        (node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    for child in node.get_children():
        apply_held_item_render_policy(child)

func generated_item_scale(item_id: String, held: bool) -> float:
    if item_id in ["workbench", "anvil", "chest", "furnace", "bed", "campfire", "spikeTrap", "wardLantern", "sanctuaryBeacon", "riftAnchor", "traderStall"]:
        return 0.48 if held else 0.62
    if item_id == "torch":
        return 0.62 if held else 0.72
    if item_id in ["door", "hideVest", "stoneArmor", "copperArmor", "ironArmor", "wardArmor", "trailPack", "expeditionPack"]:
        return 0.54 if held else 0.66
    if item_id in ["trailCharm", "wardAmulet", "compass", "surveyLens"]:
        return 0.68 if held else 0.78
    if item_id == "arrows":
        return 0.76 if held else 0.86
    if item_id in ["hunterBow", "ironCrossbow", "fishingRod"] or is_tool(item_id):
        return 0.72 if held else 0.82
    return 0.78 if held else 0.88

func add_generated_item_extras(root: Node3D, item_id: String, held: bool, scale_value: float) -> void:
    if item_id == "campfire":
        add_item_light_rig(root, "campfire", held, scale_value, Vector3(0.0, 0.22 * scale_value, 0.0))
    elif item_id == "torch":
        add_item_light_rig(root, "torch", held, scale_value, Vector3(0.0, 0.62 * scale_value, -0.18 * scale_value))
    elif item_id == "riftAnchor":
        add_item_light_rig(root, "riftAnchor", held, scale_value, Vector3(0.0, 0.50 * scale_value, -0.12 * scale_value))
    elif item_id == "sanctuaryBeacon":
        add_item_light_rig(root, "sanctuaryBeacon", held, scale_value, Vector3(0.0, 0.52 * scale_value, -0.12 * scale_value))
    elif item_id == "wardLantern":
        add_item_light_rig(root, "wardLantern", held, scale_value, Vector3(0.0, 0.52 * scale_value, -0.12 * scale_value))

func add_box(parent: Node3D, size: Vector3, material: Material, position := Vector3.ZERO, rotation := Vector3.ZERO) -> MeshInstance3D:
    var mesh := BoxMesh.new()
    mesh.size = size
    return add_mesh(parent, mesh, material, position, rotation)

func add_cylinder(parent: Node3D, radius: float, height: float, material: Material, position := Vector3.ZERO, rotation := Vector3.ZERO, segments := 8, top_radius := -1.0) -> MeshInstance3D:
    var mesh := CylinderMesh.new()
    mesh.bottom_radius = radius
    mesh.top_radius = radius if top_radius < 0.0 else top_radius
    mesh.height = height
    mesh.radial_segments = segments
    return add_mesh(parent, mesh, material, position, rotation)

func add_sphere(parent: Node3D, radius: float, material: Material, position := Vector3.ZERO, scale := Vector3.ONE) -> MeshInstance3D:
    var mesh := SphereMesh.new()
    mesh.radius = radius
    mesh.height = radius * 2.0
    mesh.radial_segments = 10
    mesh.rings = 5
    var instance := add_mesh(parent, mesh, material, position)
    instance.scale = scale
    return instance

func add_mesh(parent: Node3D, mesh: Mesh, material: Material, position := Vector3.ZERO, rotation := Vector3.ZERO) -> MeshInstance3D:
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.material_override = material
    instance.position = position
    instance.rotation = rotation
    instance.cast_shadow = shadow_policy_for_material(material)
    parent.add_child(instance)
    return instance

func shadow_policy_for_material(material: Material) -> int:
    var base := material as BaseMaterial3D
    if base != null:
        if base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
            return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        if base.emission_enabled:
            return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func add_item_light_rig(parent: Node3D, item_id: String, held: bool, scale_value: float, source_position: Vector3) -> Dictionary:
    return LocalLightRigScript.add_rig(parent, item_id, {
        "context": "held" if held else "pickup",
        "scale": scale_value,
        "source_position": source_position,
        "shadows": true
    })

func build_block(root: Node3D, item_id: String, held: bool) -> void:
    var size := Vector3.ONE * (0.36 if held else 0.42)
    if item_id == "cobblestonePath":
        size.y *= 0.34
    add_box(root, size, material_for(item_id))
    if item_id == "woodBlock":
        for x in [-0.13, 0.13]:
            add_box(root, Vector3(0.025, size.y * 1.04, size.z * 1.05), materials["wood_dark"], Vector3(x, 0.0, 0.0))
    elif item_id == "stoneBlock" or item_id == "cobblestonePath":
        add_box(root, Vector3(size.x * 1.04, 0.018, size.z * 1.04), materials["stone_dark"], Vector3(0.0, size.y * 0.18, 0.0))
        add_box(root, Vector3(0.018, size.y * 1.04, size.z * 1.02), materials["stone_dark"], Vector3(-size.x * 0.18, 0.0, 0.0))
    elif item_id == "dirtBlock":
        add_box(root, Vector3(size.x * 1.03, size.y * 0.18, size.z * 1.03), materials["grass"], Vector3(0.0, size.y * 0.42, 0.0))
    elif item_id == "glass":
        add_box(root, Vector3(size.x * 0.82, 0.018, size.z * 0.82), materials["ward"], Vector3(0.0, size.y * 0.52, 0.0))

func build_workbench(root: Node3D, held: bool) -> void:
    var scale := 0.88 if held else 1.0
    add_box(root, Vector3(0.50, 0.12, 0.42) * scale, materials["wood"], Vector3(0.0, 0.12 * scale, 0.0))
    add_box(root, Vector3(0.54, 0.04, 0.46) * scale, materials["wood_dark"], Vector3(0.0, 0.20 * scale, 0.0))
    for x in [-0.18, 0.18]:
        for z in [-0.14, 0.14]:
            add_box(root, Vector3(0.055, 0.26, 0.055) * scale, materials["wood_dark"], Vector3(x * scale, -0.04 * scale, z * scale))

func build_anvil(root: Node3D, held: bool) -> void:
    var scale := 0.82 if held else 1.0
    add_box(root, Vector3(0.50, 0.12, 0.26) * scale, materials["iron"], Vector3(0.0, -0.12 * scale, 0.0))
    add_box(root, Vector3(0.24, 0.18, 0.20) * scale, materials["stone_dark"], Vector3(0.0, 0.02 * scale, 0.0))
    add_box(root, Vector3(0.62, 0.14, 0.30) * scale, materials["iron"], Vector3(0.0, 0.18 * scale, 0.0))
    add_box(root, Vector3(0.22, 0.10, 0.26) * scale, materials["iron"], Vector3(0.34 * scale, 0.20 * scale, 0.0))

func build_door(root: Node3D, held: bool) -> void:
    var scale := 0.84 if held else 1.0
    add_box(root, Vector3(0.16, 0.72, 0.44) * scale, materials["wood_dark"])
    add_box(root, Vector3(0.018, 0.60, 0.38) * scale, materials["wood"], Vector3(-0.09 * scale, 0.0, 0.0))
    add_sphere(root, 0.035 * scale, materials["gold"], Vector3(-0.10 * scale, -0.04 * scale, 0.18 * scale), Vector3(1.0, 1.0, 1.0))

func build_bed(root: Node3D, held: bool) -> void:
    var scale := 0.88 if held else 1.0
    add_box(root, Vector3(0.58, 0.10, 0.42) * scale, materials["wood_dark"], Vector3(0.0, -0.08 * scale, 0.0))
    add_box(root, Vector3(0.52, 0.10, 0.36) * scale, materials["cloth_red"], Vector3(0.0, 0.00, 0.0))
    add_box(root, Vector3(0.18, 0.08, 0.34) * scale, materials["snow"], Vector3(-0.17 * scale, 0.06 * scale, 0.0))

func build_chest(root: Node3D, held: bool) -> void:
    var scale := 0.88 if held else 1.0
    add_box(root, Vector3(0.50, 0.28, 0.38) * scale, materials["wood"], Vector3(0.0, -0.02 * scale, 0.0))
    add_box(root, Vector3(0.52, 0.08, 0.40) * scale, materials["wood_dark"], Vector3(0.0, 0.16 * scale, 0.0))
    add_box(root, Vector3(0.08, 0.10, 0.04) * scale, materials["gold"], Vector3(0.0, 0.02 * scale, 0.21 * scale))

func build_furnace(root: Node3D, held: bool) -> void:
    var scale := 0.88 if held else 1.0
    add_box(root, Vector3.ONE * 0.44 * scale, materials["stone"])
    add_box(root, Vector3(0.25, 0.16, 0.026) * scale, materials["stone_dark"], Vector3(0.0, 0.02 * scale, 0.23 * scale))
    add_box(root, Vector3(0.18, 0.04, 0.03) * scale, materials["flame"], Vector3(0.0, -0.04 * scale, 0.245 * scale))

func build_campfire(root: Node3D, held: bool) -> void:
    var scale := 0.86 if held else 1.0
    for angle in [deg_to_rad(42.0), deg_to_rad(-42.0)]:
        add_cylinder(root, 0.035 * scale, 0.52 * scale, materials["wood"], Vector3(0.0, -0.06 * scale, 0.0), Vector3(0.0, 0.0, angle), 7)
    add_cylinder(root, 0.05 * scale, 0.30 * scale, materials["flame"], Vector3(0.0, 0.12 * scale, 0.0), Vector3.ZERO, 6, 0.0)
    add_item_light_rig(root, "campfire", held, scale, Vector3(0.0, 0.22 * scale, 0.0))

func build_torch(root: Node3D, held: bool) -> void:
    var scale := 0.92 if held else 1.0
    add_cylinder(root, 0.026 * scale, 0.72 * scale, materials["wood"], Vector3(0.0, -0.05 * scale, 0.0), Vector3(0.0, 0.0, deg_to_rad(12.0)), 7)
    add_box(root, Vector3(0.12, 0.12, 0.12) * scale, materials["wood_dark"], Vector3(0.0, 0.28 * scale, 0.0), Vector3(0.0, 0.0, deg_to_rad(12.0)))
    add_sphere(root, 0.09 * scale, materials["flame"], Vector3(0.0, 0.40 * scale, 0.0), Vector3(0.82, 1.25, 0.82))
    add_item_light_rig(root, "torch", held, scale, Vector3(0.0, 0.62 * scale, -0.18 * scale))

func build_spike_trap(root: Node3D, held: bool) -> void:
    var scale := 0.86 if held else 1.0
    add_box(root, Vector3(0.48, 0.06, 0.48) * scale, materials["wood_dark"], Vector3(0.0, -0.16 * scale, 0.0))
    for x in [-0.14, 0.0, 0.14]:
        add_cylinder(root, 0.055 * scale, 0.34 * scale, materials["stone"], Vector3(x * scale, 0.00, 0.0), Vector3.ZERO, 4, 0.0)

func build_ward_object(root: Node3D, item_id: String, held: bool) -> void:
    var scale := 0.84 if held else 1.0
    var core_material: Material = materials["ward"] if item_id != "riftAnchor" else materials["rift"]
    add_sphere(root, 0.20 * scale, core_material, Vector3.ZERO, Vector3(0.85, 1.18, 0.85))
    add_box(root, Vector3(0.08, 0.42, 0.08) * scale, materials["gold"], Vector3(0.0, 0.0, 0.0), Vector3(deg_to_rad(35.0), 0.0, deg_to_rad(45.0)))
    if item_id == "sanctuaryBeacon" or item_id == "riftAnchor":
        add_box(root, Vector3(0.42, 0.06, 0.42) * scale, materials["stone_dark"], Vector3(0.0, -0.24 * scale, 0.0))
    if item_id == "riftAnchor":
        add_item_light_rig(root, "riftAnchor", held, scale, Vector3(0.0, 0.36 * scale, -0.12 * scale))
    elif item_id == "sanctuaryBeacon":
        add_item_light_rig(root, "sanctuaryBeacon", held, scale, Vector3(0.0, 0.38 * scale, -0.12 * scale))
    else:
        add_item_light_rig(root, "wardLantern", held, scale, Vector3(0.0, 0.38 * scale, -0.12 * scale))

func build_tool(root: Node3D, item_id: String, held: bool) -> void:
    var scale := 0.92 if held else 1.0
    var head_material := material_for(item_id)
    var is_sword := item_id.ends_with("Sword") or item_id == "nightBlade"
    if is_sword:
        add_cylinder(root, 0.030 * scale, 0.32 * scale, materials["wood"], Vector3(0.0, -0.30 * scale, 0.0), Vector3.ZERO, 7)
        add_box(root, Vector3(0.34, 0.045, 0.055) * scale, head_material, Vector3(0.0, -0.10 * scale, 0.0))
        add_box(root, Vector3(0.075, 0.68, 0.040) * scale, head_material, Vector3(0.0, 0.26 * scale, 0.0))
        if item_id == "nightBlade":
            add_box(root, Vector3(0.035, 0.54, 0.050) * scale, materials["ward"], Vector3(0.0, 0.30 * scale, 0.025 * scale))
        return

    add_cylinder(root, 0.032 * scale, 0.82 * scale, materials["wood"], Vector3(0.0, -0.08 * scale, 0.0), Vector3(0.0, 0.0, deg_to_rad(8.0)), 7)
    if item_id.ends_with("Pickaxe"):
        add_box(root, Vector3(0.56, 0.070, 0.060) * scale, head_material, Vector3(0.0, 0.34 * scale, 0.0))
        add_box(root, Vector3(0.09, 0.16, 0.055) * scale, head_material, Vector3(-0.29 * scale, 0.32 * scale, 0.0), Vector3(0.0, 0.0, deg_to_rad(-28.0)))
    elif item_id.ends_with("Shovel"):
        add_box(root, Vector3(0.20, 0.26, 0.055) * scale, head_material, Vector3(0.0, 0.38 * scale, 0.0), Vector3(0.0, 0.0, deg_to_rad(-7.0)))
        add_box(root, Vector3(0.08, 0.08, 0.060) * scale, head_material, Vector3(0.0, 0.24 * scale, 0.0))
    else:
        add_box(root, Vector3(0.34, 0.19, 0.065) * scale, head_material, Vector3(0.12 * scale, 0.34 * scale, 0.0), Vector3(0.0, 0.0, deg_to_rad(-10.0)))
        add_box(root, Vector3(0.08, 0.24, 0.060) * scale, head_material, Vector3(-0.08 * scale, 0.31 * scale, 0.0), Vector3(0.0, 0.0, deg_to_rad(16.0)))

func build_bow(root: Node3D, item_id: String, held: bool) -> void:
    var scale := 0.92 if held else 1.0
    var bow_material := material_for(item_id)
    if item_id == "ironCrossbow":
        add_box(root, Vector3(0.12, 0.58, 0.075) * scale, bow_material, Vector3(0.0, -0.08 * scale, 0.0), Vector3(0.0, 0.0, deg_to_rad(90.0)))
        add_box(root, Vector3(0.72, 0.050, 0.060) * scale, bow_material, Vector3(0.0, 0.16 * scale, 0.0))
        add_cylinder(root, 0.012 * scale, 0.58 * scale, materials["string"], Vector3(0.02 * scale, 0.16 * scale, 0.06 * scale), Vector3(0.0, 0.0, deg_to_rad(90.0)), 5)
        add_box(root, Vector3(0.10, 0.12, 0.050) * scale, materials["wood_dark"], Vector3(0.0, -0.32 * scale, 0.0))
        return

    for side in [-1, 1]:
        add_cylinder(root, 0.024 * scale, 0.48 * scale, bow_material, Vector3(0.0, float(side) * 0.20 * scale, 0.0), Vector3(0.0, 0.0, deg_to_rad(18.0 * side)), 7)
    add_cylinder(root, 0.007 * scale, 0.78 * scale, materials["string"], Vector3(-0.08 * scale, 0.0, 0.0), Vector3(0.0, 0.0, 0.0), 4)
    add_cylinder(root, 0.012 * scale, 0.54 * scale, materials["string"], Vector3(0.04 * scale, 0.0, 0.06 * scale), Vector3(0.0, 0.0, deg_to_rad(90.0)), 5)

func build_fishing_rod(root: Node3D, held: bool) -> void:
    var scale := 0.94 if held else 1.0
    add_cylinder(root, 0.020 * scale, 0.96 * scale, materials["wood"], Vector3(0.0, 0.04 * scale, 0.0), Vector3(0.0, 0.0, deg_to_rad(-24.0)), 7)
    add_cylinder(root, 0.004 * scale, 0.58 * scale, materials["string"], Vector3(-0.12 * scale, 0.42 * scale, -0.16 * scale), Vector3(deg_to_rad(84.0), 0.0, 0.0), 4)
    add_sphere(root, 0.035 * scale, materials["fish"], Vector3(-0.12 * scale, 0.10 * scale, -0.44 * scale), Vector3(1.0, 0.75, 1.0))

func build_armor(root: Node3D, item_id: String, held: bool) -> void:
    var scale := 0.86 if held else 1.0
    var mat := material_for(item_id)
    add_box(root, Vector3(0.42, 0.52, 0.18) * scale, mat)
    add_box(root, Vector3(0.18, 0.16, 0.20) * scale, mat, Vector3(-0.23 * scale, 0.12 * scale, 0.0))
    add_box(root, Vector3(0.18, 0.16, 0.20) * scale, mat, Vector3(0.23 * scale, 0.12 * scale, 0.0))
    add_box(root, Vector3(0.30, 0.040, 0.20) * scale, materials["wood_dark"], Vector3(0.0, 0.02 * scale, 0.10 * scale))

func build_pack(root: Node3D, item_id: String, held: bool) -> void:
    var scale := 0.86 if held else 1.0
    var mat: Material = materials["cloth_teal"] if item_id == "expeditionPack" else materials["leather"]
    add_box(root, Vector3(0.38, 0.50, 0.22) * scale, mat)
    add_box(root, Vector3(0.18, 0.18, 0.24) * scale, materials["wood"], Vector3(0.0, -0.12 * scale, 0.14 * scale))
    add_box(root, Vector3(0.05, 0.54, 0.03) * scale, materials["wood_dark"], Vector3(-0.15 * scale, 0.0, 0.13 * scale))
    add_box(root, Vector3(0.05, 0.54, 0.03) * scale, materials["wood_dark"], Vector3(0.15 * scale, 0.0, 0.13 * scale))

func build_trinket(root: Node3D, item_id: String, held: bool) -> void:
    var scale := 0.90 if held else 1.0
    if item_id == "compass":
        add_cylinder(root, 0.22 * scale, 0.045 * scale, materials["gold"], Vector3.ZERO, Vector3(deg_to_rad(90.0), 0.0, 0.0), 16)
        add_box(root, Vector3(0.03, 0.22, 0.018) * scale, materials["ward"], Vector3(0.0, 0.0, 0.03 * scale), Vector3(0.0, 0.0, deg_to_rad(28.0)))
    elif item_id == "surveyLens":
        add_cylinder(root, 0.22 * scale, 0.035 * scale, materials["glass"], Vector3.ZERO, Vector3(deg_to_rad(90.0), 0.0, 0.0), 16)
        add_box(root, Vector3(0.34, 0.04, 0.04) * scale, materials["copper"], Vector3(0.0, -0.24 * scale, 0.0), Vector3(0.0, 0.0, deg_to_rad(-28.0)))
    else:
        add_sphere(root, 0.18 * scale, material_for(item_id), Vector3.ZERO, Vector3(1.0, 1.0, 0.38))
        add_cylinder(root, 0.012 * scale, 0.54 * scale, materials["string"], Vector3(0.0, 0.08 * scale, 0.0), Vector3(0.0, 0.0, deg_to_rad(90.0)), 6)

func build_basic_resource(root: Node3D, item_id: String, held: bool) -> void:
    var scale := 0.88 if held else 1.0
    if item_id == "logs":
        for z in [-0.08, 0.08]:
            add_cylinder(root, 0.095 * scale, 0.52 * scale, materials["wood"], Vector3(0.0, 0.0, z * scale), Vector3(0.0, 0.0, deg_to_rad(90.0)), 8)
    elif item_id == "stones":
        add_sphere(root, 0.15 * scale, materials["stone"], Vector3(-0.08 * scale, 0.0, 0.02 * scale), Vector3(1.1, 0.72, 0.9))
        add_sphere(root, 0.12 * scale, materials["stone_dark"], Vector3(0.12 * scale, -0.02 * scale, -0.04 * scale), Vector3(0.9, 0.78, 1.1))
    else:
        add_box(root, Vector3(0.36, 0.22, 0.36) * scale, material_for(item_id))

func build_forage(root: Node3D, item_id: String, held: bool) -> void:
    var scale := 0.88 if held else 1.0
    if item_id == "berries" or item_id == "cookedBerries":
        for i in range(4):
            var offset := Vector3((float(i % 2) - 0.5) * 0.16, (float(i / 2) - 0.5) * 0.10, 0.0) * scale
            add_sphere(root, 0.075 * scale, material_for(item_id), offset)
    elif item_id == "aloe":
        for angle in [-28.0, 0.0, 28.0]:
            add_cylinder(root, 0.045 * scale, 0.34 * scale, materials["herb"], Vector3.ZERO, Vector3(0.0, 0.0, deg_to_rad(angle)), 5, 0.0)
    elif item_id == "mirecap":
        add_cylinder(root, 0.050 * scale, 0.18 * scale, materials["snow"], Vector3(0.0, -0.08 * scale, 0.0), Vector3.ZERO, 7)
        add_sphere(root, 0.16 * scale, material_for(item_id), Vector3(0.0, 0.05 * scale, 0.0), Vector3(1.0, 0.48, 1.0))
    else:
        add_cylinder(root, 0.075 * scale, 0.34 * scale, materials["frost"], Vector3.ZERO, Vector3.ZERO, 5, 0.0)

func build_food(root: Node3D, item_id: String, held: bool) -> void:
    var scale := 0.88 if held else 1.0
    if item_id in ["rawFish", "cookedFish"]:
        add_box(root, Vector3(0.42, 0.12, 0.18) * scale, material_for(item_id))
        add_cylinder(root, 0.065 * scale, 0.06 * scale, material_for(item_id), Vector3(0.24 * scale, 0.0, 0.0), Vector3(0.0, 0.0, deg_to_rad(90.0)), 3, 0.0)
    elif item_id in ["rawMeat", "cookedMeat", "fieldRation"]:
        add_box(root, Vector3(0.34, 0.16, 0.24) * scale, material_for(item_id), Vector3.ZERO, Vector3(0.0, 0.0, deg_to_rad(7.0)))
    elif item_id == "hunterStew":
        add_cylinder(root, 0.20 * scale, 0.18 * scale, materials["stone_dark"], Vector3.ZERO, Vector3.ZERO, 12)
        add_sphere(root, 0.15 * scale, materials["cooked"], Vector3(0.0, 0.11 * scale, 0.0), Vector3(1.0, 0.28, 1.0))
    else:
        add_cylinder(root, 0.13 * scale, 0.30 * scale, material_for(item_id), Vector3.ZERO, Vector3.ZERO, 10)
        add_box(root, Vector3(0.18, 0.035, 0.18) * scale, materials["gold"], Vector3(0.0, 0.17 * scale, 0.0))

func build_crafting_resource(root: Node3D, item_id: String, held: bool) -> void:
    var scale := 0.88 if held else 1.0
    if item_id == "arrows":
        for z in [-0.05, 0.05]:
            add_cylinder(root, 0.011 * scale, 0.62 * scale, materials["string"], Vector3(0.0, 0.0, z * scale), Vector3(0.0, 0.0, deg_to_rad(90.0)), 5)
            add_cylinder(root, 0.040 * scale, 0.055 * scale, materials["stone"], Vector3(0.32 * scale, 0.0, z * scale), Vector3(0.0, 0.0, deg_to_rad(90.0)), 4, 0.0)
    elif item_id.ends_with("Ingot"):
        add_box(root, Vector3(0.42, 0.12, 0.24) * scale, material_for(item_id), Vector3.ZERO, Vector3(0.0, 0.0, deg_to_rad(-5.0)))
        add_box(root, Vector3(0.30, 0.025, 0.16) * scale, materials["snow"], Vector3(0.0, 0.07 * scale, 0.0))
    elif item_id in ["nightShard", "relicFragment", "riftCore"]:
        add_sphere(root, 0.18 * scale, material_for(item_id), Vector3.ZERO, Vector3(0.82, 1.20, 0.82))
        add_box(root, Vector3(0.05, 0.34, 0.05) * scale, material_for(item_id), Vector3.ZERO, Vector3(deg_to_rad(35.0), 0.0, deg_to_rad(45.0)))
    else:
        add_sphere(root, 0.18 * scale, material_for(item_id), Vector3.ZERO, Vector3(1.08, 0.78, 0.92))

func build_generic(root: Node3D, item_id: String, held: bool) -> void:
    var scale := 0.88 if held else 1.0
    add_box(root, Vector3(0.34, 0.20, 0.34) * scale, material_for(item_id))

func is_tool(item_id: String) -> bool:
    return item_id.ends_with("Axe") or item_id.ends_with("Pickaxe") or item_id.ends_with("Shovel") or item_id.ends_with("Sword") or item_id == "nightBlade"

func material_for(item_id: String) -> Material:
    if item_id == "nightBlade" or item_id == "nightShard":
        return materials["night"]
    if item_id == "riftCore" or item_id == "riftAnchor":
        return materials["rift"]
    if item_id.find("ward") >= 0 or item_id == "sanctuaryBeacon" or item_id == "surveyLens":
        return materials["ward"]
    if item_id.find("iron") >= 0:
        return materials["iron"]
    if item_id.find("copper") >= 0:
        return materials["copper"]
    if item_id.find("stone") >= 0 or item_id in ["stones", "cobblestonePath", "furnace", "anvil", "relicFragment"]:
        return materials["stone"]
    if item_id.find("wood") >= 0 or item_id in ["logs", "workbench", "door", "chest", "campfire", "torch", "hunterBow", "fishingRod"]:
        return materials["wood"]
    if item_id in ["dirt", "dirtBlock", "mud"]:
        return materials["dirt"]
    if item_id == "sand":
        return materials["sand"]
    if item_id == "snow":
        return materials["snow"]
    if item_id == "glass":
        return materials["glass"]
    if item_id in ["grass", "aloe"]:
        return materials["herb"]
    if item_id in ["berries", "cookedBerries"]:
        return materials["berry"]
    if item_id == "mirecap":
        return materials["cloth_red"]
    if item_id == "frostHerb":
        return materials["frost"]
    if item_id == "rawFish":
        return materials["fish"]
    if item_id in ["cookedFish", "cookedMeat", "hunterStew", "fieldRation"]:
        return materials["cooked"]
    if item_id == "rawMeat":
        return materials["cloth_red"]
    if item_id in ["hide", "hideVest", "trailPack", "trailCharm"]:
        return materials["leather"]
    if item_id == "expeditionPack":
        return materials["cloth_teal"]
    if item_id in ["compass", "wardAmulet", "aloeSalve", "wardTonic"]:
        return materials["gold"]
    return materials["stone"]

func held_rotation(item_id: String) -> Vector3:
    if item_id == "hunterBow" or item_id == "ironCrossbow":
        return Vector3(deg_to_rad(8.0), deg_to_rad(-14.0), deg_to_rad(-10.0))
    if item_id == "fishingRod":
        return Vector3(deg_to_rad(4.0), deg_to_rad(6.0), deg_to_rad(-24.0))
    if is_tool(item_id):
        return Vector3(deg_to_rad(10.0), deg_to_rad(-92.0), deg_to_rad(-20.0))
    return Vector3(deg_to_rad(14.0), deg_to_rad(-20.0), deg_to_rad(8.0))

func pickup_rotation(item_id: String) -> Vector3:
    if item_id == "logs" or item_id == "arrows":
        return Vector3(0.0, 0.0, deg_to_rad(90.0))
    if is_tool(item_id):
        return Vector3(0.0, randf() * TAU, deg_to_rad(18.0))
    return Vector3(deg_to_rad(10.0), randf() * TAU, deg_to_rad(6.0))

func held_scale(item_id: String) -> float:
    if item_id.ends_with("Block") or item_id in ["glass", "cobblestonePath"]:
        return 0.92
    if is_tool(item_id) or item_id in ["hunterBow", "ironCrossbow", "fishingRod"]:
        return 1.02
    return 0.98

func should_mirror_right_hand_item(item_id: String) -> bool:
    return is_tool(item_id)
