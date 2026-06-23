extends RefCounted
class_name AnimatedAssetRegistry

const ASSETS := [
    {
        "id": "door_open_close",
        "path": "res://assets/generated/animated/door_open_close.glb",
        "expected": "door_open_close",
    },
    {
        "id": "chest_open_close",
        "path": "res://assets/generated/animated/chest_open_close.glb",
        "expected": "chest_open_close",
    },
    {
        "id": "boar_idle_walk",
        "path": "res://assets/generated/animated/boar_idle_walk.glb",
        "expected": "boar_idle_walk",
    },
    {
        "id": "deer_idle_walk",
        "path": "res://assets/generated/animated/deer_idle_walk.glb",
        "expected": "deer_idle_walk",
    },
    {
        "id": "hare_idle_walk",
        "path": "res://assets/generated/animated/hare_idle_walk.glb",
        "expected": "hare_idle_walk",
    },
]

var assets_by_id := {}
var scene_cache := {}
var last_errors: Array[String] = []
var loaded := false

func setup() -> bool:
    assets_by_id.clear()
    scene_cache.clear()
    last_errors.clear()
    for row in ASSETS:
        var asset_id := String(row.get("id", ""))
        if asset_id != "":
            assets_by_id[asset_id] = row
    loaded = cache_asset_scenes()
    return loaded

func cache_asset_scenes() -> bool:
    var ok := true
    for asset_id in assets_by_id.keys():
        var asset: Dictionary = assets_by_id[asset_id]
        var resource_path := String(asset.get("path", ""))
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

func is_ready() -> bool:
    return loaded

func asset_ids() -> PackedStringArray:
    var ids := PackedStringArray()
    for asset_id in assets_by_id.keys():
        ids.append(String(asset_id))
    ids.sort()
    return ids

func instantiate_asset(asset_id: String) -> Node3D:
    var scene := scene_cache.get(asset_id) as PackedScene
    if scene == null:
        return null
    var instance := scene.instantiate()
    var node := instance as Node3D
    if node == null:
        if instance:
            instance.queue_free()
        return null
    node.set_meta("visual_source", "generated_animated_asset")
    node.set_meta("animated_asset_id", asset_id)
    return node

func animation_names(asset_id: String) -> PackedStringArray:
    var names := PackedStringArray()
    var instance := instantiate_asset(asset_id)
    if instance == null:
        return names
    var player := find_animation_player(instance)
    if player != null:
        names = player.get_animation_list()
    instance.free()
    return names

func expected_animation_name(asset_id: String) -> String:
    var asset: Dictionary = assets_by_id.get(asset_id, {})
    return String(asset.get("expected", ""))

func find_animation_player(node: Node) -> AnimationPlayer:
    if node is AnimationPlayer:
        return node as AnimationPlayer
    for child in node.get_children():
        var found := find_animation_player(child)
        if found != null:
            return found
    return null

func validate_animations() -> Dictionary:
    var details := []
    var ok := is_ready()
    for asset_id in asset_ids():
        var names := animation_names(asset_id)
        var expected := expected_animation_name(asset_id)
        var has_animation := names.size() > 0
        var has_expected := expected == "" or names.has(expected)
        ok = ok and has_animation and has_expected
        details.append("%s:%s" % [asset_id, ",".join(Array(names))])
    return {
        "ok": ok,
        "details": "; ".join(details),
        "errors": "; ".join(last_errors),
    }
