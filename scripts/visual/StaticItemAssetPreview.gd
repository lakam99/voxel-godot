extends Node3D

const StaticItemAssetRegistryScript := preload("res://scripts/visual/StaticItemAssetRegistry.gd")

var registry = null

func _ready() -> void:
    setup_preview_stage()
    registry = StaticItemAssetRegistryScript.new()
    var loaded: bool = registry.setup()
    var validation: Dictionary = registry.validate_assets()
    if loaded:
        spawn_preview_assets()
    else:
        push_error("Static item asset registry failed: %s" % "; ".join(registry.last_errors))
    print("Static item asset preview: loaded=%s ok=%s assets=%d cached=%d %s" % [
        str(loaded),
        str(bool(validation.get("ok", false))),
        int(registry.asset_count()),
        int(registry.cached_scene_count()),
        summarize_details(String(validation.get("details", "")))
    ])
    if OS.has_environment("VOXEL_STATIC_ITEM_PREVIEW_QUIT"):
        get_tree().quit(0 if loaded and bool(validation.get("ok", false)) else 1)

func setup_preview_stage() -> void:
    var camera := Camera3D.new()
    camera.name = "PreviewCamera"
    camera.position = Vector3(0.0, 4.3, 9.8)
    camera.rotation_degrees = Vector3(-25.0, 0.0, 0.0)
    camera.current = true
    add_child(camera)

    var sun := DirectionalLight3D.new()
    sun.name = "PreviewSun"
    sun.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
    sun.light_energy = 1.75
    sun.shadow_enabled = true
    add_child(sun)

    var floor_mesh := PlaneMesh.new()
    floor_mesh.size = Vector2(16.0, 10.0)
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
    var columns := 9
    for index in range(ids.size()):
        var asset_id := String(ids[index])
        var node: Node3D = registry.instantiate_item(asset_id)
        if node == null:
            continue
        node.name = "Preview_%s" % asset_id
        var col := index % columns
        var row := index / columns
        node.position = Vector3((float(col) - 4.0) * 1.45, 0.0, (float(row) - 2.0) * 1.55)
        node.scale *= 0.88
        add_child(node)

func summarize_details(details: String) -> String:
    if details.length() <= 220:
        return details
    return "%s..." % details.substr(0, 220)
