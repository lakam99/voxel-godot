extends RefCounted
class_name CharacterAssetRegistry

const MANIFEST_PATH := "res://assets/visual/generated/characters/character-manifest.json"

var assets_by_id := {}
var assets_by_family := {}
var scene_cache := {}
var disabled_asset_ids := {}
var last_errors: Array[String] = []
var loaded := false

func setup() -> bool:
    assets_by_id.clear()
    assets_by_family.clear()
    scene_cache.clear()
    disabled_asset_ids.clear()
    last_errors.clear()
    loaded = load_manifest() and cache_asset_scenes()
    return loaded

func load_manifest() -> bool:
    var manifest_text := read_text(MANIFEST_PATH)
    if manifest_text == "":
        last_errors.append("Missing character manifest %s" % MANIFEST_PATH)
        return false
    var manifest_variant = JSON.parse_string(manifest_text)
    if not (manifest_variant is Dictionary):
        last_errors.append("Invalid character manifest JSON")
        return false
    var manifest: Dictionary = manifest_variant
    var assets: Array = manifest.get("assets", [])
    for asset_variant in assets:
        if not (asset_variant is Dictionary):
            last_errors.append("Skipping non-dictionary character asset row")
            continue
        var asset: Dictionary = asset_variant
        var asset_id := String(asset.get("id", ""))
        var family := String(asset.get("family", ""))
        if asset_id == "" or family == "":
            last_errors.append("Skipping character asset with missing id/family")
            continue
        assets_by_id[asset_id] = asset
        if not assets_by_family.has(family):
            assets_by_family[family] = []
        assets_by_family[family].append(asset_id)
    for family in assets_by_family.keys():
        assets_by_family[family].sort()
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

func family_count() -> int:
    return assets_by_family.size()

func has_asset(asset_id: String) -> bool:
    return assets_by_id.has(asset_id)

func select_family_asset(family: String, stable_key: String) -> String:
    var candidates: Array = assets_by_family.get(family, [])
    var enabled: Array[String] = []
    for value in candidates:
        var asset_id := String(value)
        if not disabled_asset_ids.has(asset_id):
            enabled.append(asset_id)
    if enabled.is_empty():
        return ""
    enabled.sort()
    return enabled[stable_index("%s:%s" % [family, stable_key], enabled.size())]

func select_exact_or_family(asset_id: String, family: String, stable_key: String) -> String:
    if has_asset(asset_id) and not disabled_asset_ids.has(asset_id):
        return asset_id
    return select_family_asset(family, stable_key)

func instantiate_asset(asset_id: String) -> Node3D:
    if asset_id == "" or disabled_asset_ids.has(asset_id):
        return null
    var scene := scene_cache.get(asset_id) as PackedScene
    if scene == null:
        return null
    var instance := scene.instantiate()
    var node := instance as Node3D
    if node == null:
        if instance:
            instance.queue_free()
        return null
    node.set_meta("visual_source", "character_asset")
    node.set_meta("visual_asset_id", asset_id)
    apply_render_policy(node)
    return node

func apply_render_policy(node: Node3D) -> void:
    apply_render_policy_recursive(node)
    node.set_meta("shadow_policy", GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
    node.set_meta("visibility_range_end", 140.0)

func apply_render_policy_recursive(node: Node) -> void:
    if node is MeshInstance3D:
        var mesh_instance := node as MeshInstance3D
        mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
        mesh_instance.visibility_range_end = 140.0
        mesh_instance.visibility_range_end_margin = 18.0
        mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
    for child in node.get_children():
        apply_render_policy_recursive(child)

func instantiate_family(family: String, stable_key: String) -> Node3D:
    return instantiate_asset(select_family_asset(family, stable_key))

func instantiate_exact_or_family(asset_id: String, family: String, stable_key: String) -> Node3D:
    return instantiate_asset(select_exact_or_family(asset_id, family, stable_key))

func apply_material_map(node: Node, material_map: Dictionary) -> void:
    if node == null:
        return
    if node is MeshInstance3D:
        apply_material_map_to_mesh(node as MeshInstance3D, material_map)
    for child in node.get_children():
        apply_material_map(child, material_map)

func apply_material_map_to_mesh(instance: MeshInstance3D, material_map: Dictionary) -> void:
    if instance.mesh == null:
        return
    for surface in range(instance.mesh.get_surface_count()):
        var material := instance.mesh.surface_get_material(surface)
        var material_name := material.resource_name if material != null else ""
        if material_map.has(material_name):
            instance.set_surface_override_material(surface, material_map[material_name])

func disable_asset_for_test(asset_id: String) -> void:
    if asset_id != "":
        disabled_asset_ids[asset_id] = true

func disable_all_for_test() -> void:
    for asset_id in assets_by_id.keys():
        disabled_asset_ids[String(asset_id)] = true

func clear_test_disabled_assets() -> void:
    disabled_asset_ids.clear()

func stable_index(text: String, modulo: int) -> int:
    if modulo <= 0:
        return 0
    return abs(stable_hash(text)) % modulo

func stable_hash(text: String) -> int:
    var h := 2166136261
    for i in range(text.length()):
        h = int((h ^ text.unicode_at(i)) * 16777619) & 0xffffffff
    return h
