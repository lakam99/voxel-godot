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
var _generation_revision := 0

func setup() -> bool:
    _generation_revision += 1
    loaded = false
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
    _generation_revision += 1
    loaded = false
    var ok := true
    for asset_id in assets_by_id.keys():
        var asset: Dictionary = assets_by_id[asset_id]
        var resource_path := String(asset.get("path", ""))
        var absolute_path := ProjectSettings.globalize_path(resource_path)
        if not FileAccess.file_exists(absolute_path):
            last_errors.append("%s missing file %s" % [asset_id, absolute_path])
            ok = false
            continue
        var packed := ResourceLoader.load(resource_path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE) as PackedScene
        if packed == null:
            last_errors.append("%s imported PackedScene load failed: %s" % [asset_id, resource_path])
            ok = false
            continue
        scene_cache[asset_id] = packed
    loaded = ok and scene_cache.size() == assets_by_id.size()
    return loaded

func is_ready() -> bool:
    return loaded

func generation_receipt() -> Dictionary:
    return {"ownerInstanceId": get_instance_id(), "revision": _generation_revision, "ready": loaded}

## Explicit capture boundary; never called by the per-frame presentation path.
## The imported PackedScenes remain owned by this registry. A partial scene or
## missing expected clip is not admitted as a native wildlife presentation.
func capture_active_presentation() -> Dictionary:
    if not loaded or _generation_revision <= 0:
        return {"ok": false, "reason": "registry_not_ready"}
    var before := generation_receipt()
    var first := _read_active_presentation_values()
    if not bool(first.get("ok", false)):
        return first
    var middle := generation_receipt()
    var second := _read_active_presentation_values()
    var after := generation_receipt()
    if before != middle or middle != after or not bool(second.get("ok", false)) \
            or first.get("assets") != second.get("assets"):
        return {"ok": false, "reason": "registry_changed_during_capture"}
    var values := {"domain": "animated_asset_registry_presentation", "schemaVersion": 1,
        "assets": first.assets}
    var context := HashingContext.new()
    context.start(HashingContext.HASH_SHA256)
    context.update(JSON.stringify(values).to_utf8_buffer())
    return {"ok": true, "schemaVersion": 1, "ownerReceipt": before.duplicate(true),
        "contentIdentity": context.finish().hex_encode(), "assets": (first.assets as Array).duplicate(true)}

func _read_active_presentation_values() -> Dictionary:
    var rows: Array[Dictionary] = []
    var ids := asset_ids()
    if ids.is_empty() or scene_cache.size() != ids.size():
        return {"ok": false, "reason": "scene_cache_incomplete"}
    for asset_id in ids:
        var row = assets_by_id.get(asset_id)
        var scene := scene_cache.get(asset_id) as PackedScene
        if not row is Dictionary or String(row.get("id", "")) != asset_id \
                or scene == null or String(row.get("path", "")) != scene.resource_path:
            return {"ok": false, "reason": "asset_row_or_scene_invalid:" + asset_id}
        var expected := String(row.get("expected", ""))
        if expected == "":
            return {"ok": false, "reason": "expected_clip_missing:" + asset_id}
        var raw_instance := scene.instantiate()
        var instance := raw_instance as Node3D
        if instance == null:
            if raw_instance != null:
                raw_instance.free()
            return {"ok": false, "reason": "scene_root_invalid:" + asset_id}
        var player := find_animation_player(instance)
        var names := PackedStringArray()
        var player_path := ""
        if player != null:
            names = player.get_animation_list()
            names.sort()
            player_path = String(instance.get_path_to(player))
        var has_expected := player != null and names.has(expected)
        instance.free()
        if not has_expected:
            return {"ok": false, "reason": "expected_clip_unavailable:" + asset_id}
        rows.append({"id": asset_id, "definition": (row as Dictionary).duplicate(true),
            "sceneResourcePath": scene.resource_path, "sceneInstanceId": scene.get_instance_id(),
            "animationPlayerPath": player_path, "availableClips": Array(names)})
    return {"ok": true, "assets": rows}

func presentation_capture_is_current(snapshot: Dictionary) -> bool:
    if not bool(snapshot.get("ok", false)) or int(snapshot.get("schemaVersion", -1)) != 1 \
            or not snapshot.get("assets") is Array \
            or not snapshot.get("contentIdentity") is String \
            or snapshot.get("ownerReceipt") != generation_receipt():
        return false
    var current := capture_active_presentation()
    return bool(current.get("ok", false)) \
        and current.get("ownerReceipt") == snapshot.get("ownerReceipt") \
        and current.get("contentIdentity") == snapshot.get("contentIdentity") \
        and current.get("assets") == snapshot.get("assets")

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
