extends RefCounted
class_name AnimatedAssetRegistry

static func _default_asset_rows() -> Array:
    return [
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

var _assets_by_id: Dictionary = {}
var _scene_cache: Dictionary = {}
var _published_snapshot: Dictionary = {}
var _published_native_presentation: Dictionary = {}
var _published_descriptors: Dictionary = {}
var _bound_scene_resources: Dictionary = {}
var _capture_runtime_resources: Dictionary = {}
var _publication_invalidated := false
var last_errors: Array[String] = []
var loaded := false
var _generation_revision := 0
var publication_seal_count := 0
var descriptor_scan_count := 0

# Compatibility reads are detached copies. Mutating these values cannot alter
# the registry's manifest or imported scene ownership.
var assets_by_id: Dictionary:
    get:
        return _assets_by_id.duplicate(true)
var scene_cache: Dictionary:
    get:
        var detached: Dictionary = {}
        for asset_id_value: Variant in _scene_cache:
            var scene_value: Variant = _scene_cache[asset_id_value]
            if scene_value is Resource:
                detached[asset_id_value] = (scene_value as Resource).duplicate(true)
            else:
                detached[asset_id_value] = scene_value
        return detached

func setup() -> bool:
    var previous_assets := _assets_by_id
    var previous_scenes := _scene_cache
    var previous_errors := last_errors
    var previous_loaded := loaded
    var previous_revision := _generation_revision
    var previous_snapshot := _published_snapshot
    var previous_native_presentation := _published_native_presentation
    var previous_descriptors := _published_descriptors
    var previous_bound_resources := _bound_scene_resources
    var previous_invalidated := _publication_invalidated
    _generation_revision = previous_revision + 1
    loaded = false
    _assets_by_id = {}
    _scene_cache = {}
    _published_snapshot = {}
    _published_native_presentation = {}
    _published_descriptors = {}
    _bound_scene_resources = {}
    _publication_invalidated = false
    last_errors = []
    var candidate_ready := false
    for row in _default_asset_rows():
        var asset_id := String(row.get("id", ""))
        if asset_id != "":
            _assets_by_id[asset_id] = row.duplicate(true)
    loaded = _load_scene_cache()
    if loaded:
        loaded = _seal_publication()
    candidate_ready = loaded
    if not loaded:
        var candidate_errors := last_errors.duplicate()
        _assets_by_id = previous_assets
        _scene_cache = previous_scenes
        last_errors = candidate_errors if not candidate_errors.is_empty() else previous_errors
        loaded = previous_loaded
        _generation_revision = previous_revision
        _published_snapshot = previous_snapshot
        _published_native_presentation = previous_native_presentation
        _published_descriptors = previous_descriptors
        _bound_scene_resources = previous_bound_resources
        _publication_invalidated = previous_invalidated
    return candidate_ready

func cache_asset_scenes() -> bool:
    return setup()

func _load_scene_cache() -> bool:
    var ok := true
    for asset_id in _assets_by_id.keys():
        var asset: Dictionary = _assets_by_id[asset_id]
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
        _scene_cache[asset_id] = packed
    loaded = ok and _scene_cache.size() == _assets_by_id.size()
    return loaded

func is_ready() -> bool:
    return loaded

func generation_receipt() -> Dictionary:
    return {"ownerInstanceId": get_instance_id(), "publicationRevision": _generation_revision,
        "ready": loaded and not _publication_invalidated}

func published_catalog_snapshot() -> Dictionary:
    if not loaded or _publication_invalidated:
        return {"schema":"producer-catalog-owner-publication/v1",
            "ownerKind":"animated_assets", "status":"pending",
            "reason":"animated_catalog_publication_invalidated"}
    return _published_snapshot

func asset_definition_copy(asset_id: String) -> Dictionary:
    var value: Variant = _assets_by_id.get(asset_id, null)
    return value.duplicate(true) if value is Dictionary else {}

func cached_scene_binding(asset_id: String) -> Dictionary:
    var scene := _scene_cache.get(asset_id) as PackedScene
    if scene == null:
        return {}
    return {"resourcePath":scene.resource_path, "resourceInstanceId":scene.get_instance_id()}

func _seal_publication() -> bool:
    _capture_runtime_resources = {}
    var semantic_assets: Array[Dictionary] = []
    var semantic_descriptors: Array[Dictionary] = []
    var owner_scene_rows: Array[Dictionary] = []
    var descriptors: Dictionary = {}
    var resource_bindings: Dictionary = {}
    var ids := asset_ids()
    if ids.is_empty() or _scene_cache.size() != ids.size():
        last_errors.append("animated catalog scene cache incomplete")
        return false
    for asset_id in ids:
        var descriptor: Dictionary = _read_asset_presentation(asset_id)
        if not bool(descriptor.get("ok", false)):
            last_errors.append("%s descriptor failed: %s" % [asset_id,
                String(descriptor.get("reason", "unknown"))])
            return false
        descriptors[asset_id] = descriptor
        var definition: Dictionary = _assets_by_id[asset_id]
        var semantic_dependencies: Array[Dictionary] = []
        var runtime_dependencies: Array[Dictionary] = []
        for dependency_value: Variant in descriptor.get("dependencies", []):
            if not dependency_value is Dictionary:
                continue
            var dependency: Dictionary = dependency_value
            var semantic_dependency: Dictionary = {}
            var runtime_dependency: Dictionary = {}
            for key in ["resourcePath", "sceneStatePath"]:
                if dependency.has(key):
                    semantic_dependency[key] = dependency[key]
                    runtime_dependency[key] = dependency[key]
            if dependency.has("resourceInstanceId"):
                runtime_dependency["resourceInstanceId"] = dependency.resourceInstanceId
            if not semantic_dependency.is_empty():
                semantic_dependencies.append(semantic_dependency)
            if not runtime_dependency.is_empty():
                runtime_dependencies.append(runtime_dependency)
        semantic_dependencies.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
            return JSON.stringify(a) < JSON.stringify(b))
        runtime_dependencies.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
            return JSON.stringify(a) < JSON.stringify(b))
        semantic_assets.append({"id":asset_id, "definition":definition.duplicate(true)})
        semantic_descriptors.append({"assetId":asset_id,
            "descriptorStatus":String(descriptor.status),
            "descriptorReason":String(descriptor.reason),
            "semanticSceneStateSchema":String(descriptor.semanticSceneStateSchema),
                "semanticSceneStateDigest":String(descriptor.semanticSceneStateDigest),
                "rootNodeType":String(descriptor.rootNodeType),
                "animationPlayerPresent":bool(descriptor.animationPlayerPresent),
                "animationPlayerPath":String(descriptor.animationPlayerPath),
                "availableClips":descriptor.availableClips.duplicate(),
                "expectedClip":String(descriptor.expectedClip),
                "expectedClipAvailable":bool(descriptor.expectedClipAvailable),
                "dependencyPaths":semantic_dependencies})
        owner_scene_rows.append({"id":asset_id,
            "sceneResourcePath":String(descriptor.sceneResourcePath),
            "sceneInstanceId":int(descriptor.sceneInstanceId),
            "sceneStateDigest":String(descriptor.sceneStateDigest),
            "dependencies":runtime_dependencies})
        var scene := _scene_cache.get(asset_id) as PackedScene
        if scene == null:
            return false
        resource_bindings[scene.get_instance_id()] = scene
        for resource_id: Variant in _capture_runtime_resources:
            var captured_resource: Variant = _capture_runtime_resources[resource_id]
            if captured_resource is Resource:
                resource_bindings[int(resource_id)] = captured_resource
        for dependency: Dictionary in runtime_dependencies:
            var dependency_path := String(dependency.get("resourcePath", ""))
            if dependency_path.is_empty():
                continue
            var dependency_resource := ResourceLoader.load(dependency_path)
            if dependency_resource is Resource:
                resource_bindings[(dependency_resource as Resource).get_instance_id()] = dependency_resource
    semantic_assets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return String(a.get("id", "")) < String(b.get("id", "")))
    semantic_descriptors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return String(a.get("assetId", "")) < String(b.get("assetId", "")))
    owner_scene_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return String(a.get("id", "")) < String(b.get("id", "")))
    var payload := {"assets":semantic_assets, "descriptors":semantic_descriptors}
    _freeze_owned_value(payload)
    var content_digest := _digest_value(payload)
    if content_digest.length() != 64:
        last_errors.append("animated catalog semantic digest unavailable")
        return false
    var owner_receipt := {"ownerInstanceId":get_instance_id(),
        "publicationRevision":_generation_revision, "ready":true,
        "resourceBindings":owner_scene_rows,
        "dependencyResourceInstanceIds":_sorted_int_keys(resource_bindings)}
    _freeze_owned_value(owner_receipt)
    _freeze_owned_value(descriptors)
    _published_descriptors = descriptors
    _published_snapshot = {"schema":"producer-catalog-owner-publication/v1",
        "ownerKind":"animated_assets", "status":"ready", "contentDigest":content_digest,
        "ownerReceipt":owner_receipt, "payload":payload}
    _freeze_owned_value(_published_snapshot)
    # The historical N4 consumer has an exact value ABI. Project it once from
    # this same admitted publication; it is not an independently sampled catalog.
    var native_rows: Array[Dictionary] = []
    for asset_id in ids:
        var descriptor: Dictionary = descriptors[asset_id]
        native_rows.append({"id":asset_id, "definition":_assets_by_id[asset_id].duplicate(true),
            "sceneResourcePath":String(descriptor.sceneResourcePath),
            "sceneInstanceId":int(descriptor.sceneInstanceId),
            "animationPlayerPath":String(descriptor.animationPlayerPath),
            "availableClips":descriptor.availableClips.duplicate()})
    var native_owner := {"ownerInstanceId":get_instance_id(),
        "revision":_generation_revision, "ready":true}
    var native_identity := _digest_value({"domain":"animated_asset_registry_presentation",
        "schemaVersion":1, "assets":native_rows})
    _published_native_presentation = {"ok":true, "schemaVersion":1,
        "ownerReceipt":native_owner, "contentIdentity":native_identity, "assets":native_rows}
    _freeze_owned_value(_published_native_presentation)
    _disconnect_resource_changes(_bound_scene_resources)
    _bound_scene_resources = resource_bindings
    for binding_id: int in _bound_scene_resources:
        var resource: Resource = _bound_scene_resources[binding_id]
        if resource is AnimationLibrary:
            var library := resource as AnimationLibrary
            var library_changed := Callable(self, "_on_published_animation_library_changed").bind(binding_id)
            var library_renamed := Callable(self, "_on_published_animation_library_renamed").bind(binding_id)
            if not library.animation_added.is_connected(library_changed):
                library.animation_added.connect(library_changed)
            if not library.animation_changed.is_connected(library_changed):
                library.animation_changed.connect(library_changed)
            if not library.animation_removed.is_connected(library_changed):
                library.animation_removed.connect(library_changed)
            if not library.animation_renamed.is_connected(library_renamed):
                library.animation_renamed.connect(library_renamed)
        else:
            var changed_callable := Callable(self, "_on_published_scene_resource_changed").bind(binding_id)
            if not resource.changed.is_connected(changed_callable):
                resource.changed.connect(changed_callable)
    publication_seal_count += 1
    return true

func _on_published_scene_resource_changed(binding_id: int) -> void:
    _invalidate_published_resource(binding_id)

func _on_published_animation_library_changed(_animation_name: StringName,
        binding_id: int) -> void:
    _invalidate_published_resource(binding_id)

func _on_published_animation_library_renamed(_old_name: StringName,
        _new_name: StringName, binding_id: int) -> void:
    _invalidate_published_resource(binding_id)

func _invalidate_published_resource(binding_id: int) -> void:
    if _bound_scene_resources.has(binding_id):
        _publication_invalidated = true
        _generation_revision += 1

func _disconnect_resource_changes(resources: Dictionary) -> void:
    for binding_id_value: Variant in resources:
        var resource: Variant = resources[binding_id_value]
        if not resource is Resource:
            continue
        var changed_callable := Callable(self, "_on_published_scene_resource_changed").bind(
            int(binding_id_value))
        if (resource as Resource).changed.is_connected(changed_callable):
            (resource as Resource).changed.disconnect(changed_callable)
        if resource is AnimationLibrary:
            var library := resource as AnimationLibrary
            var library_changed := Callable(self, "_on_published_animation_library_changed").bind(
                int(binding_id_value))
            var library_renamed := Callable(self, "_on_published_animation_library_renamed").bind(
                int(binding_id_value))
            if library.animation_added.is_connected(library_changed):
                library.animation_added.disconnect(library_changed)
            if library.animation_changed.is_connected(library_changed):
                library.animation_changed.disconnect(library_changed)
            if library.animation_removed.is_connected(library_changed):
                library.animation_removed.disconnect(library_changed)
            if library.animation_renamed.is_connected(library_renamed):
                library.animation_renamed.disconnect(library_renamed)

func _sorted_int_keys(values: Dictionary) -> Array[int]:
    var result: Array[int] = []
    for key: Variant in values:
        result.append(int(key))
    result.sort()
    return result

func _freeze_owned_value(value: Variant) -> void:
    if value is Dictionary:
        var dictionary_value: Dictionary = value
        for key: Variant in dictionary_value.keys():
            _freeze_owned_value(dictionary_value[key])
        dictionary_value.make_read_only()
    elif value is Array:
        var array_value: Array = value
        for child_value: Variant in array_value:
            _freeze_owned_value(child_value)
        array_value.make_read_only()

## Explicit capture boundary; never called by the per-frame presentation path.
## The imported PackedScenes remain owned by this registry. A partial scene or
## missing expected clip is not admitted as a native wildlife presentation.
func capture_active_presentation() -> Dictionary:
    var publication := published_catalog_snapshot()
    if String(publication.get("status", "")) != "ready":
        return {"ok": false, "reason":String(publication.get("reason",
            "registry_not_ready"))}
    return _published_native_presentation

## Describes one cached PackedScene using its serialized SceneState only. No
## scene Nodes are instantiated. Any script, unresolved instance, extension
## node type, inheritance ambiguity, cycle, or incomplete animation metadata
## makes this proof unavailable.
func describe_asset_presentation_without_instantiation(asset_id: String) -> Dictionary:
    var cached: Variant = _published_descriptors.get(asset_id, null)
    if not _publication_invalidated and cached is Dictionary:
        return (cached as Dictionary).duplicate(true)
    return _read_asset_presentation(asset_id)

func _read_asset_presentation(asset_id: String) -> Dictionary:
    descriptor_scan_count += 1
    if not loaded or _generation_revision <= 0:
        return _descriptor_failure(asset_id, "registry_not_ready")
    var asset_value: Variant = _assets_by_id.get(asset_id, null)
    var scene_value: Variant = _scene_cache.get(asset_id, null)
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
            or _publication_invalidated \
            or descriptor.get("registryReceipt") != generation_receipt():
        return false
    var asset_id := String(descriptor.get("assetId", ""))
    var current: Variant = _published_descriptors.get(asset_id, null)
    return current is Dictionary and current == descriptor


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
    var animation_library := property_value as AnimationLibrary
    _capture_runtime_resources[animation_library.get_instance_id()] = animation_library
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
    for animation_name: StringName in animation_library.get_animation_list():
        var animation := animation_library.get_animation(animation_name)
        if animation != null:
            _capture_runtime_resources[animation.get_instance_id()] = animation
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
            or not snapshot.get("contentIdentity") is String:
        return false
    var publication := published_catalog_snapshot()
    return String(publication.get("status", "")) == "ready" \
        and is_same(_published_native_presentation, snapshot)

func presentation_descriptor_for_publication(expected_owner_receipt: Dictionary,
        asset_id: String) -> Dictionary:
    var publication := published_catalog_snapshot()
    if String(publication.get("status", "")) != "ready" \
            or not is_same(expected_owner_receipt, publication.get("ownerReceipt", {})):
        return {"ok":false, "status":"stale",
            "reason":"animated_catalog_owner_receipt_stale"}
    var descriptor: Variant = _published_descriptors.get(asset_id, null)
    if not descriptor is Dictionary:
        return {"ok":false, "status":"failed",
            "reason":"animated_descriptor_not_published"}
    return descriptor

func asset_ids() -> PackedStringArray:
    var ids := PackedStringArray()
    for asset_id in _assets_by_id.keys():
        ids.append(String(asset_id))
    ids.sort()
    return ids

func instantiate_asset(asset_id: String) -> Node3D:
    var scene := _scene_cache.get(asset_id) as PackedScene
    if scene == null:
        return null
    var instance := scene.instantiate()
    var node := instance as Node3D
    if node == null:
        if instance:
            instance.queue_free()
        return null
    if not _make_instance_animation_libraries_private(node):
        node.free()
        return null
    node.set_meta("visual_source", "generated_animated_asset")
    node.set_meta("animated_asset_id", asset_id)
    return node

func _make_instance_animation_libraries_private(root: Node) -> bool:
    var players: Array[AnimationPlayer] = []
    _collect_animation_players(root, players)
    for player in players:
        var library_names := player.get_animation_library_list()
        for library_name: StringName in library_names:
            var source_library := player.get_animation_library(library_name)
            if source_library == null:
                return false
            var private_library := AnimationLibrary.new()
            private_library.resource_name = source_library.resource_name
            var animation_names := source_library.get_animation_list()
            animation_names.sort()
            for animation_name: StringName in animation_names:
                var source_animation := source_library.get_animation(animation_name)
                if source_animation == null:
                    return false
                var private_animation := source_animation.duplicate(true) as Animation
                if private_animation == null or is_same(private_animation, source_animation) \
                        or private_library.add_animation(animation_name, private_animation) != OK:
                    return false
            player.remove_animation_library(library_name)
            if player.add_animation_library(library_name, private_library) != OK:
                return false
    return true

func _collect_animation_players(node: Node, output: Array[AnimationPlayer]) -> void:
    if node is AnimationPlayer:
        output.append(node as AnimationPlayer)
    for child: Node in node.get_children():
        _collect_animation_players(child, output)

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
    var asset: Dictionary = _assets_by_id.get(asset_id, {})
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
