extends StaticBody3D
class_name StoryInteractable

const CELL := 1.35

var site := {}

func configure(site_data: Dictionary) -> void:
    site = site_data.duplicate(true)
    var site_id := String(site.get("id", "story_site"))
    name = "StoryInteractable_%s" % site_id.replace(":", "_").replace(",", "_")
    set_meta("kind", "story_interactable")
    set_meta("storyInteractionId", site_id)
    set_meta("storySite", site.duplicate(true))
    set_meta("storyRegionId", String(site.get("regionId", "")))
    set_meta("storyPrompt", String(site.get("prompt", "Inspect")))
    var cell := site_cell(site)
    global_position = Vector3(float(cell.x) * CELL, float(site.get("worldY", 0.0)) + 0.12, float(cell.y) * CELL)
    build_fallback_visual(String(site.get("kind", "")), String(site.get("clueKind", "")))

func build_fallback_visual(kind: String, clue_kind: String) -> void:
    for child in get_children():
        child.queue_free()
    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "StoryVisual"
    mesh_instance.mesh = visual_mesh(kind, clue_kind)
    mesh_instance.material_override = visual_material(kind, clue_kind)
    mesh_instance.position.y = 0.32
    add_child(mesh_instance)
    var shape := CollisionShape3D.new()
    shape.name = "StoryCollision"
    var sphere := SphereShape3D.new()
    sphere.radius = 0.72
    shape.shape = sphere
    shape.position.y = 0.42
    add_child(shape)

func visual_mesh(kind: String, clue_kind: String) -> Mesh:
    if kind == "boundary_stone" or clue_kind == "historical":
        var cylinder := CylinderMesh.new()
        cylinder.top_radius = 0.28
        cylinder.bottom_radius = 0.34
        cylinder.height = 1.0
        cylinder.radial_segments = 6
        return cylinder
    if kind == "encounter_marker":
        var prism := PrismMesh.new()
        prism.size = Vector3(0.8, 0.9, 0.8)
        return prism
    var box := BoxMesh.new()
    box.size = Vector3(0.72, 0.42, 0.72)
    return box

func visual_material(kind: String, clue_kind: String) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.roughness = 0.88
    if clue_kind == "historical":
        material.albedo_color = Color(0.58, 0.55, 0.42)
    elif kind == "boundary_stone":
        material.albedo_color = Color(0.42, 0.48, 0.52)
        material.emission_enabled = true
        material.emission = Color(0.36, 0.54, 0.68)
        material.emission_energy_multiplier = 0.16
    elif kind == "encounter_marker":
        material.albedo_color = Color(0.24, 0.28, 0.34)
    else:
        material.albedo_color = Color(0.62, 0.66, 0.58)
    return material

func site_cell(site_data: Dictionary) -> Vector2i:
    var cell_value = site_data.get("cell", [])
    if cell_value is Array and cell_value.size() >= 2:
        return Vector2i(int(cell_value[0]), int(cell_value[1]))
    return Vector2i.ZERO
