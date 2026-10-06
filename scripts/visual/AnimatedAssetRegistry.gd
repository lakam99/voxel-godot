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

## Describes one cached PackedScene using its serialized SceneState only. No
## scene Nodes are instantiated. Any script, unresolved instance, extension
## node type, inheritance ambiguity, cycle, or incomplete animation metadata
## makes this proof unavailable.
func describe_asset_presentation_without_instantiation(asset_id: String) -> Dictionary:
    if not loaded or _generation_revision <= 0:
        return _descriptor_failure(asset_id, "registry_not_ready")
    var asset_value: Variant = assets_by_id.get(asset_id, null)
    var scene_value: Variant = scene_cache.get(asset_id, null)
    if not asset_value is Dictionary or String(asset_value.get("id", "")) != asset_id:
        return _descriptor_failure(asset_id, "asset_definition_unavailable")
    if not scene_value is PackedScene:
        return _descriptor_failure(asset_id, "packed_scene_unavailable")
    var scene := scene_value as PackedScene
    var resource_path := String(asset_value.get("path", ""))
    if resource_path.is_empty() or scene.resource_path != resource_path:
        return _descriptor_failure(asset_id, "packed_scene_path_mismatch")
    if not scene.can_instantiate():
        return _descriptor_failure(asset_id, "packed_scene_has_no_nodes")

    var nodes_by_path: Dictionary = {}
    var dependencies: Array[Dictionary] = []
    var roots: Array[Dictionary] = []
    var scan := _scan_packed_scene_state(scene, "", [], [], nodes_by_path,
        dependencies, roots)
    if not bool(scan.get("ok", false)):
        return _descriptor_failure(asset_id, String(scan.get("reason", "scene_state_unavailable")),
            scan.get("diagnostic", {}) as Dictionary)
    if roots.is_empty():
        return _descriptor_failure(asset_id, "scene_root_unavailable")
    var root_type := String(roots[0].get("nodeType", ""))
    if not _is_core_node3d_type(root_type):
        return _descriptor_failure(asset_id, "scene_root_not_node3d:" + root_type)

    var player_rows: Array[Dictionary] = []
    var node_paths: Array = nodes_by_path.keys()
    node_paths.sort()
    for path_value: Variant in node_paths:
        var node_row: Dictionary = nodes_by_path[path_value]
        var node_type := String(node_row.get("nodeType", ""))
        if ClassDB.class_exists(node_type) \
                and (node_type == "AnimationPlayer" \
                    or ClassDB.is_parent_class(node_type, &"AnimationPlayer")):
            player_rows.append(node_row)
    if player_rows.size() > 1:
        return _descriptor_failure(asset_id, "multiple_animation_players_order_unproven")

    var available_clips: Array[String] = []
    var player_path := ""
    if not player_rows.is_empty():
        var player_row: Dictionary = player_rows[0]
        player_path = String(player_row.get("path", ""))
        var clips_value: Variant = player_row.get("animations", null)
        if not bool(player_row.get("animationLibrariesPresent", false)) \
                or not clips_value is Array:
            return _descriptor_failure(asset_id, "animation_library_state_unavailable", {
                "nodePath": player_path,
                "properties": player_row.get("animationLibraryProperties", []),
                "assetPath": scene.resource_path
            })
        available_clips.assign(clips_value)
    available_clips.sort()
    var expected_clip := String(asset_value.get("expected", ""))
    if expected_clip.is_empty():
        return _descriptor_failure(asset_id, "expected_clip_unavailable")
    var expected_available := available_clips.has(expected_clip)
    var ordered_nodes := _ordered_node_rows(nodes_by_path)
    var state_identity := {
        "schemaVersion": 1,
        "assetId": asset_id,
        "resourcePath": scene.resource_path,
        "resourceInstanceId": scene.get_instance_id(),
        "rootNodeType": root_type,
        "animationPlayerPath": player_path,
        "availableClips": available_clips,
        "dependencies": dependencies,
        "nodes": ordered_nodes
    }
    var state_digest := _digest_value(state_identity)
    if state_digest.is_empty():
        return _descriptor_failure(asset_id, "scene_state_digest_unavailable")
    var semantic_dependencies: Array[Dictionary] = []
    for dependency_value: Variant in dependencies:
        var dependency: Dictionary = dependency_value
        var semantic_dependency := {}
        if dependency.has("resourcePath"):
            semantic_dependency["resourcePath"] = dependency.resourcePath
        if dependency.has("sceneStatePath"):
            semantic_dependency["sceneStatePath"] = dependency.sceneStatePath
        semantic_dependencies.append(semantic_dependency)
    semantic_dependencies.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return JSON.stringify(a) < JSON.stringify(b))
    var semantic_nodes: Array[Dictionary] = []
    for node_value: Variant in ordered_nodes:
        var node: Dictionary = node_value
        semantic_nodes.append({
            "path": node.get("path", ""),
            "nodeType": node.get("nodeType", ""),
            "siblingIndex": node.get("siblingIndex", -1),
            "animationLibraryProperties": node.get("animationLibraryProperties", []),
            "animations": node.get("animations", [])
        })
    # Keep semantic catalog identity independent of Resource instance IDs.
    # The full digest and receipt below still bind this descriptor to its
    # current runtime owner and import lifetime.
    var semantic_state_identity := {
        "schema": "animated-scene-semantic-state/v1",
        "assetId": asset_id,
        "resourcePath": scene.resource_path,
        "rootNodeType": root_type,
        "animationPlayerPath": player_path,
        "availableClips": available_clips,
        "dependencyPaths": semantic_dependencies,
        "nodes": semantic_nodes
    }
    var semantic_state_digest := _digest_value(semantic_state_identity)
    if semantic_state_digest.is_empty():
        return _descriptor_failure(asset_id, "semantic_scene_state_digest_unavailable")
    return {
        "ok": expected_available,
        "status": "ready" if expected_available else "failed",
        "reason": "" if expected_available else "expected_clip_missing:" + expected_clip,
        "schemaVersion": 1,
        "assetId": asset_id,
        "registryReceipt": generation_receipt(),
        "sceneResourcePath": scene.resource_path,
        "sceneInstanceId": scene.get_instance_id(),
        "sceneStateDigest": state_digest,
        "semanticSceneStateDigest": semantic_state_digest,
        "semanticSceneStateSchema": "animated-scene-semantic-state/v1",
        "rootNodeType": root_type,
        "rootNode3DCompatible": true,
        "branchProofAvailable": true,
        "animationPlayerPresent": not player_rows.is_empty(),
        "animationPlayerPath": player_path,
        "availableClips": available_clips,
        "expectedClip": expected_clip,
        "expectedClipAvailable": expected_available,
        "dependencies": dependencies.duplicate(true)
    }


## Recomputes the static description and compares it with the original owner,
## resource and state bindings. This validator never instantiates Nodes.
func asset_presentation_descriptor_is_current(descriptor: Dictionary) -> bool:
    if not bool(descriptor.get("ok", false)) \
            or int(descriptor.get("schemaVersion", -1)) != 1 \
            or descriptor.get("registryReceipt") != generation_receipt():
        return false
    var asset_id := String(descriptor.get("assetId", ""))
    var current := describe_asset_presentation_without_instantiation(asset_id)
    return bool(current.get("ok", false)) \
        and current.get("registryReceipt") == descriptor.get("registryReceipt") \
        and current.get("sceneResourcePath") == descriptor.get("sceneResourcePath") \
        and current.get("sceneInstanceId") == descriptor.get("sceneInstanceId") \
        and current.get("sceneStateDigest") == descriptor.get("sceneStateDigest") \
        and current.get("semanticSceneStateDigest") == descriptor.get("semanticSceneStateDigest") \
        and current.get("dependencies") == descriptor.get("dependencies")


func _scan_packed_scene_state(scene: PackedScene, path_prefix: String,
        packed_stack: Array, state_stack: Array, nodes_by_path: Dictionary,
        dependencies: Array[Dictionary], roots: Array[Dictionary]) -> Dictionary:
    if scene == null or scene.resource_path.is_empty():
        return {"ok": false, "reason": "external_or_unresolved_packed_scene"}
    var packed_id := scene.get_instance_id()
    if packed_stack.has(packed_id):
        return {"ok": false, "reason": "packed_scene_cycle:" + scene.resource_path}
    var state: SceneState = scene.get_state()
    if state == null:
        return {"ok": false, "reason": "packed_scene_state_unavailable:" + scene.resource_path}
    var dependency := {"resourcePath": scene.resource_path,
        "resourceInstanceId": packed_id}
    if not dependencies.has(dependency):
        dependencies.append(dependency)
    packed_stack.append(packed_id)
    var scanned := _scan_scene_state(state, path_prefix, packed_stack, state_stack,
        nodes_by_path, dependencies, roots)
    packed_stack.pop_back()
    return scanned


func _scan_scene_state(state: SceneState, path_prefix: String, packed_stack: Array,
        state_stack: Array, nodes_by_path: Dictionary,
        dependencies: Array[Dictionary], roots: Array[Dictionary]) -> Dictionary:
    if state == null:
        return {"ok": false, "reason": "scene_state_unavailable"}
    var state_id := state.get_instance_id()
    if state_stack.has(state_id):
        return {"ok": false, "reason": "scene_state_cycle:" + String(state.get_path())}
    var node_count := state.get_node_count()
    if node_count <= 0:
        return {"ok": false, "reason": "scene_state_empty:" + String(state.get_path())}
    var state_path_identity := {"sceneStatePath": String(state.get_path())}
    if not dependencies.has(state_path_identity):
        dependencies.append(state_path_identity)
    state_stack.append(state_id)
    var root_index := -1
    var root_type := ""
    var nested_rows: Array[Dictionary] = []
    var failure_reason := ""
    var failure_diagnostic: Dictionary = {}
    for node_index in range(node_count):
        var node_path := String(state.get_node_path(node_index))
        var node_type := String(state.get_node_type(node_index))
        if node_path == ".":
            root_index = node_index
            root_type = node_type
            roots.append({"path": _join_scene_path(path_prefix, node_path),
                "nodeType": node_type})
        if node_type.is_empty() or not ClassDB.class_exists(node_type):
            failure_reason = "unknown_scene_node_type:" + node_type
            break
        if int(ClassDB.class_get_api_type(node_type)) != int(ClassDB.API_CORE):
            failure_reason = "non_core_scene_node_type:" + node_type
            break
        var full_path := _join_scene_path(path_prefix, node_path)
        var node_row := {"path": full_path, "nodeType": node_type,
            "siblingIndex": state.get_node_index(node_index), "animations": [],
            "animationLibraryKeys": {}, "animationLibraryProperties": [],
            "animationLibrariesPresent": false}
        for property_index in range(state.get_node_property_count(node_index)):
            var property_name := String(state.get_node_property_name(node_index, property_index))
            var property_value: Variant = state.get_node_property_value(node_index, property_index)
            if property_name == "script" and property_value != null:
                failure_reason = "script_can_change_scene_hierarchy:" + full_path
                break
            var is_animation_player := node_type == "AnimationPlayer" \
                or ClassDB.is_parent_class(node_type, &"AnimationPlayer")
            # SceneState exposes AnimationPlayer libraries as flattened
            # `libraries/<name>` properties, with the AnimationLibrary
            # Resource as the value. The empty suffix is the default library.
            if is_animation_player and (property_name == "libraries" \
                    or property_name.begins_with("libraries/")):
                var library_result := _record_scene_state_animation_library(
                    node_row, full_path, property_name, property_value)
                if not bool(library_result.get("ok", false)):
                    failure_reason = String(library_result.get("reason", "animation_library_state_invalid"))
                    var diagnostic: Dictionary = library_result.get("diagnostic", {})
                    diagnostic["sceneStatePath"] = state.get_path()
                    diagnostic["nodePath"] = full_path
                    failure_diagnostic = diagnostic
                    break
        if not failure_reason.is_empty():
            break
        var existing: Variant = nodes_by_path.get(full_path, null)
        if existing is Dictionary and String(existing.get("nodeType", "")) != node_type:
            failure_reason = "scene_node_type_conflict:" + full_path
            break
        if not existing is Dictionary \
                or (not bool(existing.get("animationLibrariesPresent", false)) \
                    and bool(node_row.get("animationLibrariesPresent", false))) \
                or node_type != "AnimationPlayer":
            nodes_by_path[full_path] = node_row
        if state.is_node_instance_placeholder(node_index) \
                or not state.get_node_instance_placeholder(node_index).is_empty():
            failure_reason = "unresolved_scene_instance_placeholder:" + full_path
            break
        var nested_scene := state.get_node_instance(node_index)
        if nested_scene != null:
            nested_rows.append({"scene": nested_scene, "path": full_path})
    if failure_reason.is_empty() and root_index < 0:
        failure_reason = "scene_state_root_missing:" + String(state.get_path())
    if failure_reason.is_empty() and root_index >= 0 \
            and not _is_core_node3d_type(root_type):
        failure_reason = "scene_root_not_node3d:" + root_type
    if failure_reason.is_empty():
        for nested_row: Dictionary in nested_rows:
            var nested_scene: PackedScene = nested_row.scene
            var nested_result := _scan_packed_scene_state(nested_scene,
                String(nested_row.path), packed_stack, state_stack,
                nodes_by_path, dependencies, roots)
            if not bool(nested_result.get("ok", false)):
                failure_reason = String(nested_result.get("reason", "nested_scene_state_failed"))
                failure_diagnostic = nested_result.get("diagnostic", {})
                break
    if failure_reason.is_empty():
        var base_state := state.get_base_scene_state()
        if base_state != null:
            var base_result := _scan_scene_state(base_state, path_prefix,
                packed_stack, state_stack, nodes_by_path, dependencies, roots)
            if not bool(base_result.get("ok", false)):
                failure_reason = String(base_result.get("reason", "base_scene_state_failed"))
                failure_diagnostic = base_result.get("diagnostic", {})
    state_stack.pop_back()
    if not failure_reason.is_empty():
        var failed := {"ok": false, "reason": failure_reason}
        if not failure_diagnostic.is_empty():
            failed["diagnostic"] = failure_diagnostic
        return failed
    return {"ok": true}


func _record_scene_state_animation_library(node_row: Dictionary, node_path: String,
        property_name: String, property_value: Variant) -> Dictionary:
    var diagnostic := {"nodePath": node_path, "propertyName": property_name,
        "propertyVariantType": type_string(typeof(property_value)),
        "propertyClass": property_value.get_class() if property_value is Object else ""}
    if not property_name.begins_with("libraries/"):
        return {"ok": false, "reason": "animation_library_property_encoding_unsupported",
            "diagnostic": diagnostic}
    var library_key := property_name.trim_prefix("libraries/")
    if library_key.contains("/"):
        return {"ok": false, "reason": "animation_library_key_invalid",
            "diagnostic": diagnostic}
    if not property_value is AnimationLibrary:
        return {"ok": false, "reason": "animation_library_resource_unavailable",
            "diagnostic": diagnostic}
    var library_keys: Dictionary = node_row.get("animationLibraryKeys", {})
    if library_keys.has(library_key):
        return {"ok": false, "reason": "animation_library_key_ambiguous",
            "diagnostic": diagnostic}
    library_keys[library_key] = true
    node_row["animationLibraryKeys"] = library_keys
    var properties: Array = node_row.get("animationLibraryProperties", [])
    properties.append(property_name)
    properties.sort()
    node_row["animationLibraryProperties"] = properties
    var animations: Array = node_row.get("animations", [])
    for animation_name: StringName in (property_value as AnimationLibrary).get_animation_list():
        var full_name := String(animation_name) if library_key.is_empty() \
            else library_key + "/" + String(animation_name)
        if animations.has(full_name):
            return {"ok": false, "reason": "animation_clip_name_ambiguous",
                "diagnostic": diagnostic}
        animations.append(full_name)
    animations.sort()
    node_row["animations"] = animations
    node_row["animationLibrariesPresent"] = true
    return {"ok": true}


func _is_core_node3d_type(node_type: String) -> bool:
    return ClassDB.class_exists(node_type) \
        and int(ClassDB.class_get_api_type(node_type)) == int(ClassDB.API_CORE) \
        and (node_type == "Node3D" or ClassDB.is_parent_class(node_type, &"Node3D"))


func _join_scene_path(prefix: String, path: String) -> String:
    if path == ".":
        return prefix
    var relative := path.trim_prefix("./")
    if prefix.is_empty():
        return relative
    return prefix + "/" + relative


func _ordered_node_rows(nodes_by_path: Dictionary) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var paths: Array = nodes_by_path.keys()
    paths.sort()
    for path_value: Variant in paths:
        result.append((nodes_by_path[path_value] as Dictionary).duplicate(true))
    return result


func _digest_value(value: Variant) -> String:
    var hash := HashingContext.new()
    if hash.start(HashingContext.HASH_SHA256) != OK:
        return ""
    hash.update(JSON.stringify(value).to_utf8_buffer())
    return hash.finish().hex_encode()


func _descriptor_failure(asset_id: String, reason: String,
        diagnostic: Dictionary = {}) -> Dictionary:
    var result := {"ok": false, "status": "failed", "reason": reason,
        "schemaVersion": 1, "assetId": asset_id,
        "registryReceipt": generation_receipt()}
    if not diagnostic.is_empty():
        result["diagnostic"] = diagnostic.duplicate(true)
    return result

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
