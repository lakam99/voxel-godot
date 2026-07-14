extends RefCounted
class_name VisualAssetRegistry

const MANIFEST_PATH := "res://assets/visual/generated/visual-manifest.json"
const PROFILE_PATHS := [
    "res://resources/visual/biomes/default.tres",
    "res://resources/visual/biomes/plains.tres",
    "res://resources/visual/biomes/forest.tres",
    "res://resources/visual/biomes/taiga.tres",
    "res://resources/visual/biomes/snow.tres",
    "res://resources/visual/biomes/tundra.tres",
    "res://resources/visual/biomes/alpine.tres",
    "res://resources/visual/biomes/savanna.tres",
    "res://resources/visual/biomes/desert.tres",
    "res://resources/visual/biomes/swamp.tres",
    "res://resources/visual/biomes/beach.tres",
]

var assets_by_id := {}
var assets_by_family := {}
var profiles_by_biome := {}
var scene_cache := {}
var disabled_asset_ids := {}
var last_errors: Array[String] = []
var loaded := false

func setup() -> bool:
    assets_by_id.clear()
    assets_by_family.clear()
    profiles_by_biome.clear()
    scene_cache.clear()
    disabled_asset_ids.clear()
    last_errors.clear()
    load_profiles()
    loaded = load_manifest() and cache_asset_scenes()
    return loaded

func load_profiles() -> void:
    for path in PROFILE_PATHS:
        var profile := load(path) as Resource
        if profile == null:
            last_errors.append("Missing visual profile %s" % path)
            continue
        profiles_by_biome[String(profile.get("biome_id"))] = profile

func load_manifest() -> bool:
    var manifest_text := read_text(MANIFEST_PATH)
    if manifest_text == "":
        last_errors.append("Missing visual manifest %s" % MANIFEST_PATH)
        return false
    var manifest_variant = JSON.parse_string(manifest_text)
    if not (manifest_variant is Dictionary):
        last_errors.append("Invalid visual manifest JSON")
        return false
    var manifest: Dictionary = manifest_variant
    var assets: Array = manifest.get("assets", [])
    for asset_variant in assets:
        if not (asset_variant is Dictionary):
            last_errors.append("Skipping non-dictionary asset row")
            continue
        var asset: Dictionary = asset_variant
        var asset_id := String(asset.get("id", ""))
        var family := String(asset.get("family", ""))
        if asset_id == "" or family == "":
            last_errors.append("Skipping asset with missing id/family")
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
        apply_render_policy(root, asset_id)
        root.set_meta("render_policy_preapplied", true)
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

func cached_asset_ids() -> Array[String]:
    var result: Array[String] = []
    for asset_id_value in scene_cache.keys():
        result.append(String(asset_id_value))
    result.sort()
    return result

func profile_count() -> int:
    return profiles_by_biome.size()

func select_tree_asset_id(biome: String, prop_id: String) -> String:
    var profile := profile_for_biome(biome)
    var families := PackedStringArray(["broadleaf_tree"])
    if profile != null:
        families = profile.get("tree_families")
    return select_asset_id(families, biome, prop_id, "tree")

func select_rock_asset_id(biome: String, prop_id: String) -> String:
    var profile := profile_for_biome(biome)
    var families := PackedStringArray(["rock"])
    if profile != null:
        families = profile.get("rock_families")
    return select_asset_id(families, biome, prop_id, "rock")

func profile_for_biome(biome: String) -> Resource:
    var key := biome
    if profiles_by_biome.has(key):
        return profiles_by_biome[key]
    return profiles_by_biome.get("default") as Resource

func select_asset_id(families: PackedStringArray, biome: String, prop_id: String, role: String) -> String:
    var candidates: Array[String] = []
    for family in families:
        var family_ids: Array = assets_by_family.get(String(family), [])
        for id_variant in family_ids:
            var asset_id := String(id_variant)
            var asset: Dictionary = assets_by_id.get(asset_id, {})
            var tags: Array = asset.get("biomeTags", [])
            if tags.is_empty() or tags.has(biome):
                candidates.append(asset_id)
    if candidates.is_empty():
        for family in families:
            var family_ids: Array = assets_by_family.get(String(family), [])
            for id_variant in family_ids:
                candidates.append(String(id_variant))
    if candidates.is_empty():
        return ""
    candidates.sort()
    var index := stable_index("%s:%s:%s" % [role, biome, prop_id], candidates.size())
    return candidates[index]

func instantiate_tree_visual(biome: String, prop_id: String) -> Node3D:
    return instantiate_asset(select_tree_asset_id(biome, prop_id))

func instantiate_rock_visual(biome: String, prop_id: String) -> Node3D:
    return instantiate_asset(select_rock_asset_id(biome, prop_id))

func instantiate_family(family: String, stable_key: String) -> Node3D:
    return instantiate_asset(select_asset_id(PackedStringArray([family]), "", stable_key, family))

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
    node.set_meta("visual_source", "generated_asset")
    node.set_meta("visual_asset_id", asset_id)
    if not bool(node.get_meta("render_policy_preapplied", false)):
        apply_render_policy(node, asset_id)
    return node

func apply_render_policy(node: Node3D, asset_id: String) -> void:
    var asset: Dictionary = assets_by_id.get(asset_id, {})
    var family := String(asset.get("family", ""))
    var shadow_policy := shadow_policy_for_family(family)
    var visibility_end := visibility_range_for_family(family)
    apply_render_policy_recursive(node, shadow_policy, visibility_end)
    node.set_meta("shadow_policy", shadow_policy)
    node.set_meta("visibility_range_end", visibility_end)

func shadow_policy_for_family(family: String) -> int:
    if family == "bush":
        return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func visibility_range_for_family(family: String) -> float:
    match family:
        "broadleaf_tree", "conifer_tree", "savanna_tree":
            return 260.0
        "rock":
            return 220.0
        "stump_log":
            return 160.0
        "bush":
            return 120.0
    return 180.0

func apply_render_policy_recursive(node: Node, shadow_policy: int, visibility_end: float) -> void:
    if node is MeshInstance3D:
        var mesh_instance := node as MeshInstance3D
        mesh_instance.cast_shadow = shadow_policy
        mesh_instance.visibility_range_end = visibility_end
        mesh_instance.visibility_range_end_margin = minf(24.0, visibility_end * 0.12)
        mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
    for child in node.get_children():
        apply_render_policy_recursive(child, shadow_policy, visibility_end)

func asset_size(asset_id: String) -> Vector3:
    var asset: Dictionary = assets_by_id.get(asset_id, {})
    var bounds: Dictionary = asset.get("boundingBox", {})
    var size: Array = bounds.get("size", [])
    if size.size() < 3:
        return Vector3.ONE
    return Vector3(float(size[0]), float(size[1]), float(size[2]))

func tree_scale_for_biome(biome: String) -> float:
    var profile := profile_for_biome(biome)
    return float(profile.get("tree_scale")) if profile else 1.0

func rock_scale_for_biome(biome: String) -> float:
    var profile := profile_for_biome(biome)
    return float(profile.get("rock_scale")) if profile else 1.0

func disable_asset_for_test(asset_id: String) -> void:
    if asset_id != "":
        disabled_asset_ids[asset_id] = true

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
