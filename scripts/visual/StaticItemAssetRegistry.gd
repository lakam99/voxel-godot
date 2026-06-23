extends RefCounted
class_name StaticItemAssetRegistry

const MANIFEST_PATH := "res://assets/generated/static/static-item-manifest.json"

var assets_by_id := {}
var assets_by_family := {}
var scene_cache := {}
var last_errors: Array[String] = []
var loaded := false

func setup() -> bool:
    assets_by_id.clear()
    assets_by_family.clear()
    scene_cache.clear()
    last_errors.clear()
    loaded = load_manifest() and cache_asset_scenes()
    return loaded

func load_manifest() -> bool:
    var manifest_text := read_text(MANIFEST_PATH)
    if manifest_text == "":
        last_errors.append("Missing static item manifest %s" % MANIFEST_PATH)
        return false
    var manifest_variant = JSON.parse_string(manifest_text)
    if not (manifest_variant is Dictionary):
        last_errors.append("Invalid static item manifest JSON")
        return false
    var manifest: Dictionary = manifest_variant
    var assets: Array = manifest.get("assets", [])
    for asset_variant in assets:
        if not (asset_variant is Dictionary):
            continue
        var asset: Dictionary = asset_variant
        var asset_id := String(asset.get("id", ""))
        var family := String(asset.get("family", ""))
        if asset_id == "" or family == "":
            last_errors.append("Skipping static item asset with missing id/family")
            continue
        assets_by_id[asset_id] = asset
        if not assets_by_family.has(family):
            assets_by_family[family] = []
        assets_by_family[family].append(asset_id)
    for family_key in assets_by_family.keys():
        assets_by_family[family_key].sort()
    return not assets_by_id.is_empty()

func cache_asset_scenes() -> bool:
    var ok := true
    for asset_id in assets_by_id.keys():
        var asset: Dictionary = assets_by_id[asset_id]
        var resource_path := "res://%s" % String(asset.get("path", ""))
        var absolute_path := ProjectSettings.globalize_path(resource_path)
        if not FileAccess.file_exists(absolute_path):
            last_errors.append("%s missing file %s" % [asset_id, absolute_path])
            ok = false
            continue
        var document := GLTFDocument.new()
        var state := GLTFState.new()
        var import_error := document.append_from_file(absolute_path, state)
        if import_error != OK:
            last_errors.append("%s GLB import failed: %s" % [asset_id, str(import_error)])
            ok = false
            continue
        var root := document.generate_scene(state)
        if root == null:
            last_errors.append("%s GLB generated no scene" % asset_id)
            ok = false
            continue
        root.name = asset_id
        var packed := PackedScene.new()
        var pack_error := packed.pack(root)
        root.free()
        if pack_error != OK:
            last_errors.append("%s PackedScene pack failed: %s" % [asset_id, str(pack_error)])
            ok = false
            continue
        scene_cache[asset_id] = packed
    return ok and scene_cache.size() == assets_by_id.size()

func read_text(path: String) -> String:
    if not FileAccess.file_exists(path):
        return ""
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return ""
    var text := file.get_as_text()
    file.close()
    return text

func is_ready() -> bool:
    return loaded

func asset_count() -> int:
    return assets_by_id.size()

func cached_scene_count() -> int:
    return scene_cache.size()

func has_asset(asset_id: String) -> bool:
    return loaded and scene_cache.has(asset_id)

func asset_ids() -> PackedStringArray:
    var ids := PackedStringArray()
    for asset_id in assets_by_id.keys():
        ids.append(String(asset_id))
    ids.sort()
    return ids

func family_ids(family: String) -> PackedStringArray:
    var ids := PackedStringArray()
    for asset_id in assets_by_family.get(family, []):
        ids.append(String(asset_id))
    ids.sort()
    return ids

func instantiate_item(asset_id: String) -> Node3D:
    var scene := scene_cache.get(asset_id) as PackedScene
    if scene == null:
        return null
    var instance := scene.instantiate()
    var node := instance as Node3D
    if node == null:
        if instance:
            instance.queue_free()
        return null
    node.name = "GeneratedStatic_%s" % asset_id
    node.set_meta("visual_source", "generated_static_asset")
    node.set_meta("static_asset_id", asset_id)
    apply_render_policy(node)
    return node

func apply_render_policy(node: Node) -> void:
    if node is MeshInstance3D:
        var mesh_instance := node as MeshInstance3D
        mesh_instance.cast_shadow = shadow_policy_for_mesh(mesh_instance)
        mesh_instance.visibility_range_end = 160.0
        mesh_instance.visibility_range_end_margin = 20.0
        mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
    for child in node.get_children():
        apply_render_policy(child)

func shadow_policy_for_mesh(mesh_instance: MeshInstance3D) -> int:
    var mesh_name := mesh_instance.name.to_lower()
    if (
        mesh_name.find("flame") >= 0
        or mesh_name.find("ember") >= 0
        or mesh_name.find("glow") >= 0
        or mesh_name.find("glass") >= 0
        or mesh_name.find("core") >= 0
        or mesh_name.find("crystal") >= 0
    ):
        return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    for surface_index in range(mesh_instance.get_surface_override_material_count()):
        var material := mesh_instance.get_surface_override_material(surface_index)
        if material_casts_no_shadow(material):
            return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    if mesh_instance.mesh != null:
        for surface_index in range(mesh_instance.mesh.get_surface_count()):
            var material := mesh_instance.mesh.surface_get_material(surface_index)
            if material_casts_no_shadow(material):
                return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func material_casts_no_shadow(material: Material) -> bool:
    var base := material as BaseMaterial3D
    if base == null:
        return false
    return base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or base.emission_enabled

func mesh_count(asset_id: String) -> int:
    var instance := instantiate_item(asset_id)
    if instance == null:
        return 0
    var count := count_meshes(instance)
    instance.free()
    return count

func count_meshes(node: Node) -> int:
    var count := 0
    if node is MeshInstance3D:
        count += 1
    for child in node.get_children():
        count += count_meshes(child)
    return count

func validate_assets() -> Dictionary:
    var ok := is_ready()
    var details := []
    for asset_id in asset_ids():
        var asset: Dictionary = assets_by_id.get(asset_id, {})
        var count := mesh_count(asset_id)
        var min_meshes := int(asset.get("minMeshes", 1))
        ok = ok and count >= min_meshes
        details.append("%s:%d/%d" % [asset_id, count, min_meshes])
    return {
        "ok": ok,
        "details": ", ".join(details),
        "errors": "; ".join(last_errors),
    }
