extends Node3D

const AnimatedAssetRegistryScript := preload("res://scripts/visual/AnimatedAssetRegistry.gd")

var registry = null

func _ready() -> void:
    setup_preview_stage()
    registry = AnimatedAssetRegistryScript.new()
    var loaded: bool = registry.setup()
    var validation: Dictionary = registry.validate_animations()
    if loaded:
        spawn_preview_assets()
    else:
        push_error("Animated asset registry failed: %s" % "; ".join(registry.last_errors))
    print("Animated asset preview: loaded=%s ok=%s %s" % [str(loaded), str(bool(validation.get("ok", false))), String(validation.get("details", ""))])
    if OS.has_environment("VOXEL_ANIMATED_PREVIEW_QUIT"):
        get_tree().quit(0 if loaded and bool(validation.get("ok", false)) else 1)

func setup_preview_stage() -> void:
    var camera := Camera3D.new()
    camera.name = "PreviewCamera"
    camera.position = Vector3(0.0, 2.4, 5.8)
    camera.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
    camera.current = true
    add_child(camera)

    var sun := DirectionalLight3D.new()
    sun.name = "PreviewSun"
    sun.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
    sun.light_energy = 1.65
    sun.shadow_enabled = true
    add_child(sun)

    var floor_mesh := PlaneMesh.new()
    floor_mesh.size = Vector2(8.0, 4.0)
    var floor_material := StandardMaterial3D.new()
    floor_material.albedo_color = Color(0.34, 0.40, 0.34)
    floor_material.roughness = 0.92
    var floor := MeshInstance3D.new()
    floor.name = "PreviewFloor"
    floor.mesh = floor_mesh
    floor.material_override = floor_material
    add_child(floor)

func spawn_preview_assets() -> void:
    var ids: PackedStringArray = registry.asset_ids()
    var count: int = maxi(1, ids.size())
    for index in range(ids.size()):
        var asset_id := String(ids[index])
        var node: Node3D = registry.instantiate_asset(asset_id)
        if node == null:
            continue
        node.name = "Preview_%s" % asset_id
        node.position = Vector3((float(index) - float(count - 1) * 0.5) * 2.25, 0.0, 0.0)
        add_child(node)
        var player: AnimationPlayer = registry.find_animation_player(node)
        if player != null:
            var names: PackedStringArray = player.get_animation_list()
            if names.size() > 0:
                player.play(names[0])
