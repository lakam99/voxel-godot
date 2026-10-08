extends RefCounted
class_name VisualAssetRegistry

const MANIFEST_PATH := "res://assets/visual/generated/visual-manifest.json"
const BiomeEnvironmentCatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const TreeRuntimeRequestBuilderScript := preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")
const ActiveBiomeEnvironmentSnapshotScript := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const StaticRenderMeshFingerprintScript := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const StaticRenderMaterialFingerprintScript := preload("res://scripts/world/StaticRenderMaterialFingerprint.gd")
const TREE_WIND_SHADER := preload("res://resources/visual/tree_wind_material.gdshader")
const TREE_WIND_CULL_MARGIN := 1.25
const INVALID_TREE_CELL := Vector2i(2147483647, 2147483647)
const WIND_TREE_FAMILIES := {
    "broadleaf_tree": true,
    "conifer_tree": true,
    "savanna_tree": true,
    "mature_broadleaf_tree": true,
    "old_growth_broadleaf_tree": true,
    "mature_conifer_tree": true,
    "mature_savanna_tree": true,
    "ecological_broadleaf_tree": true,
    "ecological_conifer_tree": true,
    "ecological_savanna_tree": true
}

var _assets_by_id: Dictionary = {}
var _assets_by_family: Dictionary = {}
var environment_catalog: BiomeEnvironmentCatalog
var tree_runtime_request_builder
var tree_spawn_service
var _scene_cache: Dictionary = {}
var tree_wind_material_cache := {}
var _disabled_asset_ids: Dictionary = {}
var _rock_support_envelope_cache: Dictionary = {}
var _published_core_snapshot: Dictionary = {}
var _published_catalog_snapshot: Dictionary = {}
var _published_static_descriptors: Dictionary = {}
var _bound_visual_resources: Dictionary = {}
var _published_profile_digest := ""
var _published_biome_publication: Dictionary = {}
var _capture_runtime_resources: Dictionary = {}
var _publication_invalidated := false
var publication_seal_count := 0
var descriptor_scan_count := 0
var last_errors: Array[String] = []
var loaded := false
var generation_revision := 0

# Compatibility reads are detached. Resource map reads deep-duplicate cached
# scenes so callers cannot mutate the registry's imported scene state.
var assets_by_id: Dictionary:
    get:
        return _assets_by_id.duplicate(true)
var assets_by_family: Dictionary:
    get:
        return _assets_by_family.duplicate(true)
var disabled_asset_ids: Dictionary:
    get:
        return _disabled_asset_ids.duplicate(true)
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
var rock_support_envelope_cache: Dictionary:
    get:
        return _rock_support_envelope_cache.duplicate(true)

func setup(catalog: BiomeEnvironmentCatalog = null) -> bool:
    var previous := {
        "assets":_assets_by_id, "families":_assets_by_family, "scenes":_scene_cache,
        "windMaterials":tree_wind_material_cache, "disabled":_disabled_asset_ids,
        "rockCache":_rock_support_envelope_cache, "errors":last_errors,
        "loaded":loaded, "revision":generation_revision, "catalog":environment_catalog,
        "requestBuilder":tree_runtime_request_builder, "spawnService":tree_spawn_service,
        "core":_published_core_snapshot, "publication":_published_catalog_snapshot,
        "staticDescriptors":_published_static_descriptors,
        "boundResources":_bound_visual_resources,
        "profileDigest":_published_profile_digest,
        "biomePublication":_published_biome_publication,
        "invalidated":_publication_invalidated}
    generation_revision = int(previous.revision) + 1
    loaded = false
    _assets_by_id = {}
    _assets_by_family = {}
    _scene_cache = {}
    tree_wind_material_cache = {}
    _disabled_asset_ids = {}
    _rock_support_envelope_cache = {}
    _published_core_snapshot = {}
    _published_catalog_snapshot = {}
    _published_static_descriptors = {}
    _bound_visual_resources = {}
    _published_profile_digest = ""
    _published_biome_publication = {}
    _publication_invalidated = false
    last_errors = []
    environment_catalog = catalog
    if environment_catalog == null:
        environment_catalog = BiomeEnvironmentCatalogScript.new()
        environment_catalog.setup()
    tree_runtime_request_builder = TreeRuntimeRequestBuilderScript.new()
    tree_spawn_service = TreeSpawnServiceScript.new()
    # Prewarm shared procedural geometry while the game is still in its loading
    # path. The first streamed tree then cannot pay mesh construction in a
    # player movement frame.
    tree_spawn_service.prewarm_visuals()
    var candidate_ready := load_manifest() and cache_asset_scenes()
    loaded = candidate_ready
    if not candidate_ready:
        _assets_by_id = previous.assets
        _assets_by_family = previous.families
        _scene_cache = previous.scenes
        tree_wind_material_cache = previous.windMaterials
        _disabled_asset_ids = previous.disabled
        _rock_support_envelope_cache = previous.rockCache
        last_errors = previous.errors
        loaded = bool(previous.loaded)
        generation_revision = int(previous.revision)
        environment_catalog = previous.catalog
        tree_runtime_request_builder = previous.requestBuilder
        tree_spawn_service = previous.spawnService
        _published_core_snapshot = previous.core
        _published_catalog_snapshot = previous.publication
        _published_static_descriptors = previous.staticDescriptors
        _bound_visual_resources = previous.boundResources
        _published_profile_digest = String(previous.profileDigest)
        _published_biome_publication = previous.biomePublication
        _publication_invalidated = bool(previous.invalidated)
    else:
        _disconnect_visual_resource_changes(previous.boundResources)
    return candidate_ready

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
        if not bool(asset.get("runtimeEnabled", true)):
            continue
        var asset_id := String(asset.get("id", ""))
        var family := String(asset.get("family", ""))
        if asset_id == "" or family == "":
            last_errors.append("Skipping asset with missing id/family")
            continue
        _assets_by_id[asset_id] = asset.duplicate(true)
        if not _assets_by_family.has(family):
            _assets_by_family[family] = []
        _assets_by_family[family].append(asset_id)
    for family in _assets_by_family.keys():
        _assets_by_family[family].sort()
    return not _assets_by_id.is_empty()

func cache_asset_scenes() -> bool:
    var ok := true
    for asset_id in _assets_by_id.keys():
        var asset: Dictionary = _assets_by_id[asset_id]
        # Complete tree GLBs are retained as Blender-reference/import assets
        # during migration, but they no longer participate in runtime loading.
        # Natural trees are now recipe-driven from profile + ecology inputs.
        if is_complete_tree_asset(asset):
            continue
        var resource_path := "res://%s" % String(asset.get("path", ""))
        var absolute_path := ProjectSettings.globalize_path(resource_path)
        if not FileAccess.file_exists(absolute_path):
            last_errors.append("%s missing file %s" % [asset_id, absolute_path])
            ok = false
            continue
        # Runtime GLBs are project assets. Keep the importer-owned PackedScene
        # and hydrate nodes from it on the main thread; repacking a generated
        # GLTF tree retains transient render resources after its source tree is
        # freed, which produces invalid RIDs in the headless dummy renderer.
        var packed := ResourceLoader.load(resource_path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE) as PackedScene
        if packed == null:
            last_errors.append("%s imported PackedScene load failed: %s" % [asset_id, resource_path])
            ok = false
            continue
        _scene_cache[asset_id] = packed
    return ok

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

func generation_receipt() -> Dictionary:
    return {
        "ownerInstanceId": get_instance_id(),
        "publicationRevision": generation_revision,
        "ready": loaded,
        "biomeOwnerInstanceId": int(environment_catalog.generation_receipt().get("ownerInstanceId", 0)) \
            if environment_catalog != null else 0,
        "biomePublicationRevision": int(environment_catalog.generation_receipt().get("publicationRevision", 0)) \
            if environment_catalog != null else 0
    }

func published_catalog_snapshot(biome_publication: Dictionary = {}) -> Dictionary:
    if not loaded or _publication_invalidated:
        return {"schema":"producer-catalog-owner-publication/v1",
            "ownerKind":"visual_assets", "status":"pending",
            "reason":"visual_catalog_publication_invalidated"}
    if biome_publication.is_empty():
        return {"schema":"producer-catalog-owner-publication/v1",
            "ownerKind":"visual_assets", "status":"pending",
            "reason":"biome_publication_required"}
    if environment_catalog == null or not is_instance_valid(environment_catalog):
        return {"schema":"producer-catalog-owner-publication/v1",
            "ownerKind":"visual_assets", "status":"pending",
            "reason":"biome_owner_unavailable"}
    var active_biome_publication := environment_catalog.published_catalog_snapshot()
    if String(active_biome_publication.get("status", "")) != "ready" \
            or not is_same(active_biome_publication, biome_publication):
        return {"schema":"producer-catalog-owner-publication/v1",
            "ownerKind":"visual_assets", "status":"pending",
            "reason":"biome_publication_owner_mismatch"}
    if String(biome_publication.get("status", "")) != "ready" \
            or not biome_publication.get("payload", null) is Dictionary \
            or String(biome_publication.get("contentDigest", "")).length() != 64:
        return {"schema":"producer-catalog-owner-publication/v1",
            "ownerKind":"visual_assets", "status":"pending",
            "reason":"biome_publication_invalid"}
    var biome_digest := String(biome_publication.contentDigest)
    if not _published_catalog_snapshot.is_empty() \
            and _published_profile_digest == biome_digest \
            and is_same(_published_biome_publication, biome_publication):
        return _published_catalog_snapshot
    var core_result := _ensure_visual_core_snapshot()
    if not bool(core_result.get("ok", false)):
        return {"schema":"producer-catalog-owner-publication/v1",
            "ownerKind":"visual_assets", "status":"pending",
            "reason":String(core_result.get("reason", "visual_core_capture_failed"))}
    var descriptor_result := _seal_static_descriptors()
    if not bool(descriptor_result.get("ok", false)):
        return {"schema":"producer-catalog-owner-publication/v1",
            "ownerKind":"visual_assets", "status":"pending",
            "reason":String(descriptor_result.get("reason", "static_descriptor_capture_failed"))}
    var rock_envelope := describe_rock_support_envelope(biome_publication.payload)
    if String(rock_envelope.get("status", "")) != "ready":
        return {"schema":"producer-catalog-owner-publication/v1",
            "ownerKind":"visual_assets", "status":String(rock_envelope.get("status", "pending")),
            "reason":String(rock_envelope.get("reason", "rock_support_envelope_pending"))}
    var normalized_rock := _semantic_rock_support_envelope(rock_envelope,
        biome_digest, String(_published_core_snapshot.contentDigest))
    var payload := {
        "assets":_published_core_snapshot.assets,
        "families":_published_core_snapshot.families,
        "disabledIds":_published_core_snapshot.disabledIds,
        "sceneCache":_published_core_snapshot.sceneCache,
        "staticDescriptors":_semantic_static_descriptors(),
        "rockSupportEnvelope":normalized_rock}
    _freeze_visual_value(payload)
    var digest := _static_descriptor_digest(payload)
    if digest.length() != 64:
        return {"schema":"producer-catalog-owner-publication/v1",
            "ownerKind":"visual_assets", "status":"failed",
            "reason":"visual_catalog_content_digest_unavailable"}
    var owner_receipt := _visual_owner_receipt(biome_digest)
    _freeze_visual_value(owner_receipt)
    _published_profile_digest = biome_digest
    _published_biome_publication = biome_publication
    _published_catalog_snapshot = {
        "schema":"producer-catalog-owner-publication/v1",
        "ownerKind":"visual_assets", "status":"ready",
        "contentDigest":digest, "ownerReceipt":owner_receipt, "payload":payload}
    _freeze_visual_value(_published_catalog_snapshot)
    publication_seal_count += 1
    return _published_catalog_snapshot

func _seal_static_descriptors() -> Dictionary:
    if not _published_static_descriptors.is_empty():
        return {"ok":true}
    var ids: Array[String] = []
    for key: Variant in _assets_by_id:
        var asset: Dictionary = _assets_by_id[key]
        if not is_complete_tree_asset(asset):
            ids.append(String(key))
    ids.sort()
    var staged_descriptors: Dictionary = {}
    for asset_id in ids:
        var descriptor := _read_static_asset_descriptor(asset_id)
        if String(descriptor.get("status", "")) != "ready":
            return {"ok":false, "reason":"static_descriptor_unavailable:%s:%s" % [
                asset_id, String(descriptor.get("reason", "unknown"))]}
        _freeze_visual_value(descriptor)
        staged_descriptors[asset_id] = descriptor
    _published_static_descriptors = staged_descriptors
    for asset_id in ids:
        _bind_static_descriptor_resources(_published_static_descriptors[asset_id])
    _freeze_visual_value(_published_static_descriptors)
    return {"ok":true}

func _bind_static_descriptor_resources(descriptor: Dictionary) -> void:
    var packed := _scene_cache.get(String(descriptor.get("assetId", ""))) as PackedScene
    if packed != null:
        var packed_id := packed.get_instance_id()
        _bound_visual_resources[packed_id] = packed
        var packed_changed := Callable(self, "_on_published_visual_resource_changed").bind(packed_id)
        if not packed.changed.is_connected(packed_changed):
            packed.changed.connect(packed_changed)
    for member_value: Variant in descriptor.get("renderMembers", []):
        if not member_value is Dictionary:
            continue
        var member: Dictionary = member_value
        for key in ["mesh", "material"]:
            var resource: Variant = member.get(key, null)
            if not resource is Resource:
                continue
            var resource_id := (resource as Resource).get_instance_id()
            _bound_visual_resources[resource_id] = resource
            var changed_callable := Callable(self, "_on_published_visual_resource_changed").bind(resource_id)
            if not (resource as Resource).changed.is_connected(changed_callable):
                (resource as Resource).changed.connect(changed_callable)

func _on_published_visual_resource_changed(resource_id: int) -> void:
    if _bound_visual_resources.has(resource_id):
        _publication_invalidated = true
        generation_revision += 1

func _disconnect_visual_resource_changes(resources: Dictionary) -> void:
    for resource_id_value: Variant in resources:
        var resource: Variant = resources[resource_id_value]
        if not resource is Resource:
            continue
        var changed_callable := Callable(self, "_on_published_visual_resource_changed").bind(
            int(resource_id_value))
        if (resource as Resource).changed.is_connected(changed_callable):
            (resource as Resource).changed.disconnect(changed_callable)

func _ensure_visual_core_snapshot() -> Dictionary:
    if not _published_core_snapshot.is_empty():
        return {"ok":true, "snapshot":_published_core_snapshot}
    var assets: Array[Dictionary] = []
    var asset_ids: Array[String] = []
    for value: Variant in _assets_by_id.keys():
        asset_ids.append(String(value))
    asset_ids.sort()
    for asset_id in asset_ids:
        var asset: Variant = _assets_by_id.get(asset_id)
        if not asset is Dictionary or String(asset.get("id", "")) != asset_id:
            return {"ok":false, "reason":"visual_asset_manifest_invalid:%s" % asset_id}
        assets.append({"id":asset_id, "value":(asset as Dictionary).duplicate(true)})
    var families: Array[Dictionary] = []
    var family_ids: Array[String] = []
    for value: Variant in _assets_by_family.keys():
        family_ids.append(String(value))
    family_ids.sort()
    for family in family_ids:
        var ids: Array[String] = []
        for value: Variant in _assets_by_family.get(family, []):
            ids.append(String(value))
        families.append({"family":family, "orderedIds":ids})
    var disabled: Array[String] = []
    for value: Variant in _disabled_asset_ids.keys():
        disabled.append(String(value))
    disabled.sort()
    var scenes: Array[Dictionary] = []
    for asset_id in asset_ids:
        var packed := _scene_cache.get(asset_id) as PackedScene
        if packed == null:
            continue
        var state := packed.get_state()
        if state == null or state.get_node_count() <= 0:
            return {"ok":false, "reason":"visual_scene_state_unavailable:%s" % asset_id}
        var root_type := String(state.get_node_type(0))
        if root_type != "Node3D" and not ClassDB.is_parent_class(root_type, "Node3D"):
            return {"ok":false, "reason":"visual_scene_root_invalid:%s" % asset_id}
        scenes.append({"id":asset_id, "resourcePath":packed.resource_path,
            "rootType":root_type})
    var semantic := {"assets":assets, "families":families,
        "disabledIds":disabled, "sceneCache":scenes}
    var digest := _static_descriptor_digest(semantic)
    if digest.length() != 64:
        return {"ok":false, "reason":"visual_core_digest_unavailable"}
    _freeze_visual_value(semantic)
    _published_core_snapshot = {"contentDigest":digest,
        "assets":semantic.assets, "families":semantic.families,
        "disabledIds":semantic.disabledIds, "sceneCache":semantic.sceneCache}
    _freeze_visual_value(_published_core_snapshot)
    return {"ok":true, "snapshot":_published_core_snapshot}

func _semantic_static_descriptors() -> Array:
    if not _published_static_descriptors.is_empty():
        var rows: Array = []
        var ids: Array[String] = []
        for key: Variant in _published_static_descriptors:
            ids.append(String(key))
        ids.sort()
        for asset_id in ids:
            var descriptor: Dictionary = _published_static_descriptors[asset_id]
            var members: Array[Dictionary] = []
            for member_value: Variant in descriptor.get("renderMembers", []):
                if not member_value is Dictionary:
                    continue
                var member: Dictionary = member_value
                members.append({"memberId":String(member.get("memberId", "")),
                    "meshResourcePath":String(member.get("meshResourcePath", "")),
                    "meshContentDigest":String(member.get("meshContentDigest", "")),
                    "materialResourcePath":String(member.get("materialResourcePath", "")),
                    "materialContentDigest":String(member.get("materialContentDigest", "")),
                    "renderLayer":String(member.get("renderLayer", "")),
                    "transform":member.get("transform"),
                    "meshBounds":member.get("meshBounds"),
                    "localBounds":member.get("localBounds"),
                    "primitiveType":int(member.get("primitiveType", -1))})
            rows.append({"assetId":asset_id,
                "catalogContentDigest":String(descriptor.get("catalogContentDigest", "")),
                "sceneContentDigest":String(descriptor.get("sceneContentDigest", "")),
                "rootType":String(descriptor.get("rootType", "")),
                "aggregateLocalBounds":descriptor.get("aggregateLocalBounds"),
                "renderMembers":members})
        return rows
    return []

func _semantic_rock_support_envelope(source: Dictionary, biome_digest: String,
        visual_digest: String) -> Dictionary:
    var result := source.duplicate(true)
    # Owner revisions are runtime provenance. The section policy is semantic
    # content, so bind its identity to the two admitted catalog digests.
    result["profileCatalogRevision"] = biome_digest
    result["registryRevision"] = visual_digest
    result["biomeCatalogRevision"] = biome_digest
    result["assetCatalogDigest"] = visual_digest
    var rows: Variant = result.get("assetRows", null)
    var ids: Variant = result.get("eligibleAssetIds", null)
    if not rows is Array or not ids is Array:
        return {}
    result["assetSetDigest"] = _static_descriptor_digest(rows)
    result["eligibleAssetSetDigest"] = _static_descriptor_digest({
        "profileCatalogRevision":biome_digest, "registryRevision":visual_digest,
        "biomeCatalogRevision":biome_digest, "eligibleAssetIds":ids,
        "assetRows":rows,
        "profileAssetRows":result.get("profileAssetRows", [])})
    result.erase("digest")
    result["digest"] = _static_descriptor_digest(result)
    return result

func _visual_owner_receipt(biome_digest: String) -> Dictionary:
    var resource_rows: Array[Dictionary] = []
    for binding_id_value: Variant in _bound_visual_resources:
        var resource: Variant = _bound_visual_resources[binding_id_value]
        if resource is Resource:
            resource_rows.append({"instanceId":int(binding_id_value),
                "resourcePath":String((resource as Resource).resource_path),
                "class":String((resource as Resource).get_class())})
    resource_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return int(a.instanceId) < int(b.instanceId))
    var biome_receipt := environment_catalog.generation_receipt() \
        if environment_catalog != null else {}
    return {"ownerInstanceId":get_instance_id(),
        "publicationRevision":generation_revision, "ready":loaded,
        "biomeContentDigest":biome_digest,
        "biomeOwnerInstanceId":int(biome_receipt.get("ownerInstanceId", 0)),
        "biomePublicationRevision":int(biome_receipt.get("publicationRevision", 0)),
        "resources":resource_rows}

func _freeze_visual_value(value: Variant) -> void:
    if value is Dictionary:
        var dictionary: Dictionary = value
        for key: Variant in dictionary.keys():
            _freeze_visual_value(dictionary[key])
        dictionary.make_read_only()
    elif value is Array:
        var array: Array = value
        for item: Variant in array:
            _freeze_visual_value(item)
        array.make_read_only()

func rock_source_descriptor_for_publication(expected_owner_receipt: Dictionary,
        biome: String, prop_id: String) -> Dictionary:
    var publication := _published_catalog_snapshot
    if not loaded or _publication_invalidated or publication.is_empty() \
            or not is_same(expected_owner_receipt, publication.get("ownerReceipt")):
        return {"status":"stale", "reason":"visual_owner_receipt_stale"}
    var biome_publication := environment_catalog.published_catalog_snapshot() \
        if environment_catalog != null else {}
    var active_biome_receipt: Dictionary = biome_publication.get("ownerReceipt", {})
    if String(biome_publication.get("status", "")) != "ready" \
            or String(biome_publication.get("contentDigest", "")) \
                != String(publication.get("ownerReceipt", {}).get("biomeContentDigest", "")) \
            or int(active_biome_receipt.get("ownerInstanceId", 0)) \
                != int(expected_owner_receipt.get("biomeOwnerInstanceId", -1)) \
            or int(active_biome_receipt.get("publicationRevision", 0)) \
                != int(expected_owner_receipt.get("biomePublicationRevision", -1)):
        return {"status":"stale", "reason":"biome_owner_receipt_stale"}
    var payload: Dictionary = biome_publication.get("payload", {})
    var profiles: Variant = payload.get("profiles", null)
    if not profiles is Array:
        return {"status":"failed", "reason":"biome_profiles_unavailable"}
    var profile: Dictionary = {}
    for row_value: Variant in profiles:
        if row_value is Dictionary and String(row_value.get("biomeId", "")) == biome:
            profile = row_value
            break
    if profile.is_empty():
        for row_value: Variant in profiles:
            if row_value is Dictionary and String(row_value.get("biomeId", "")) == "default":
                profile = row_value
                break
    if profile.is_empty():
        return {"status":"failed", "reason":"biome_profile_unavailable"}
    var families: Variant = profile.get("rock_families", null)
    if not families is Array:
        return {"status":"failed", "reason":"rock_families_unavailable"}
    var packed_families := PackedStringArray()
    for value: Variant in families:
        packed_families.append(String(value))
    var selected_id := select_asset_id(packed_families, biome, prop_id, "rock")
    var descriptor: Dictionary = _published_static_descriptors.get(selected_id, {})
    if selected_id.is_empty() or descriptor.is_empty() \
            or String(descriptor.get("status", "")) != "ready":
        return {"status":"pending", "reason":"selected_rock_descriptor_unavailable"}
    var envelope: Dictionary = publication.get("payload", {}).get("rockSupportEnvelope", {})
    var eligible_ids: Variant = envelope.get("eligibleAssetIds", null)
    if not eligible_ids is Array or not eligible_ids.has(selected_id):
        return {"status":"failed", "reason":"selected_rock_not_in_published_support_envelope"}
    var scale_field: Variant = profile.get("rock_scale", null)
    var scale: Variant = scale_field.get("value", null) if scale_field is Dictionary else scale_field
    if not scale is float and not scale is int:
        return {"status":"failed", "reason":"rock_scale_unavailable"}
    if not is_finite(float(scale)) or float(scale) <= 0.0:
        return {"status":"failed", "reason":"rock_scale_invalid"}
    var size := asset_size(selected_id)
    return {"status":"ready", "ownerReceipt":expected_owner_receipt,
        "assetId":selected_id, "descriptor":descriptor, "assetSize":size,
        "profileScale":float(scale),
        "assetDescriptorDigest":_static_descriptor_digest([
            String(descriptor.get("catalogContentDigest", "")),
            String(descriptor.get("sceneContentDigest", ""))]),
        "sourceVisualContentDigest":String(publication.get("contentDigest", "")),
        "sourceBiomeContentDigest":String(biome_publication.get("contentDigest", ""))}

func asset_count() -> int:
    return _assets_by_id.size()

func cached_scene_count() -> int:
    return _scene_cache.size()

func cached_asset_ids() -> Array[String]:
    var result: Array[String] = []
    for asset_id_value in _scene_cache.keys():
        result.append(String(asset_id_value))
    result.sort()
    return result

func profile_count() -> int:
    return environment_catalog.profile_count() if environment_catalog != null else 0

func select_tree_asset_id(
    biome: String,
    prop_id: String,
    world_cell := INVALID_TREE_CELL,
    world_seed := ""
) -> String:
    var profile := profile_for_biome(biome)
    var families := PackedStringArray(["broadleaf_tree"])
    var ecology := {}
    if profile != null:
        families = profile.get("tree_families")
        ecology = tree_ecology_spec(biome, prop_id, world_cell, world_seed)
        if not ecology.is_empty() and families_contain_ecological_tree(families):
            return select_tree_asset_for_age_band(
                families,
                biome,
                prop_id,
                String(ecology.get("ageBand", "mature"))
            )
        var old_growth_chance := clampf(float(profile.get("old_growth_chance")), 0.0, 1.0)
        if families.has("mature_broadleaf_tree") \
            and old_growth_chance > 0.0 \
            and stable_unit("tree-old-growth:%s:%s" % [biome, prop_id]) < old_growth_chance:
            families = PackedStringArray(["old_growth_broadleaf_tree"])
    return select_asset_id(families, biome, prop_id, "tree")

func tree_ecology_spec(
    biome: String,
    prop_id: String,
    world_cell := INVALID_TREE_CELL,
    world_seed := ""
) -> Dictionary:
    var profile := profile_for_biome(biome) as BiomeEnvironmentProfile
    if profile == null or tree_runtime_request_builder == null:
        return {}
    return tree_runtime_request_builder.sample_ecology(profile, biome, prop_id, world_cell, world_seed)

func families_contain_ecological_tree(families: PackedStringArray) -> bool:
    for family in families:
        if String(family).begins_with("ecological_"):
            return true
    return false

func select_tree_asset_for_age_band(
    families: PackedStringArray,
    biome: String,
    prop_id: String,
    age_band: String
) -> String:
    var candidates: Array[String] = []
    for family in families:
        for id_variant in _assets_by_family.get(String(family), []):
            var asset_id := String(id_variant)
            var asset: Dictionary = _assets_by_id.get(asset_id, {})
            var tags: Array = asset.get("biomeTags", [])
            var phenotype: Dictionary = asset.get("treePhenotype", {})
            if String(phenotype.get("ageBand", "")) == age_band \
                and (tags.is_empty() or tags.has(biome)):
                candidates.append(asset_id)
    if candidates.is_empty():
        return select_asset_id(families, biome, prop_id, "tree")
    candidates.sort()
    return candidates[stable_index("tree-phenotype:%s:%s:%s" % [biome, age_band, prop_id], candidates.size())]

func select_rock_asset_id(biome: String, prop_id: String) -> String:
    var profile := profile_for_biome(biome)
    var families := PackedStringArray(["rock"])
    if profile != null:
        families = profile.get("rock_families")
    return select_asset_id(families, biome, prop_id, "rock")


func describe_rock_support_envelope(profile_snapshot: Dictionary) -> Dictionary:
    var result := {"schema":"rock-static-descriptor-envelope/v1", "status":"pending",
        "reason":"", "profileCatalogRevision":str(profile_snapshot.get("contentIdentity", ""))}
    if not loaded or not is_instance_valid(environment_catalog) \
            or int(profile_snapshot.get("schemaVersion", -1)) != 1 \
            or String(profile_snapshot.get("fallbackId", "")) != "default" \
            or str(profile_snapshot.get("contentIdentity", "")).length() != 64 \
            or not profile_snapshot.get("profiles", null) is Array:
        result["status"] = "pending"
        result["reason"] = "rock_support_catalog_or_registry_not_ready"
        return result
    var profile_receipt := environment_catalog.generation_receipt()
    var asset_catalog_digest := _static_descriptor_digest({
        "assetsById":_assets_by_id, "assetsByFamily":_assets_by_family,
        "disabledAssetIds":_disabled_asset_ids})
    var support_script := get_script() as GDScript
    if support_script == null or support_script.source_code.is_empty():
        result["reason"] = "rock_support_algorithm_source_unavailable"
        return result
    var support_algorithm_digest := _static_descriptor_digest(support_script.source_code)
    var cache_key := "%d|%s|%s" % [generation_revision,
        str(profile_snapshot.contentIdentity),
        _static_descriptor_digest([profile_receipt, asset_catalog_digest,
            support_algorithm_digest])]
    var cached: Variant = _rock_support_envelope_cache.get(cache_key, null)
    if cached is Dictionary:
        var cached_policy := cached as Dictionary
        if str(cached_policy.get("registryRevision", "")) == str(generation_revision) \
                and str(cached_policy.get("profileCatalogRevision", "")) \
                    == str(profile_snapshot.contentIdentity) \
                and str(cached_policy.get("biomeCatalogRevision", "")) \
                    == str(profile_receipt.get("publicationRevision", "")) \
                and str(cached_policy.get("assetCatalogDigest", "")) == asset_catalog_digest \
                and str(cached_policy.get("supportAlgorithmDigest", "")) \
                    == support_algorithm_digest \
                and _cached_rock_support_descriptors_are_current(cached_policy):
            return cached_policy.duplicate(true)
        _rock_support_envelope_cache.erase(cache_key)
        result["reason"] = "cached_rock_support_descriptor_stale"
        return result
    var max_horizontal := 0.0
    var max_vertical := 0.0
    var profile_asset_rows: Array[Dictionary] = []
    var eligible_asset_ids: Dictionary = {}
    for profile_value: Variant in profile_snapshot.profiles:
        if not profile_value is Dictionary:
            result["status"] = "failed"
            result["reason"] = "rock_support_profile_row_invalid"
            return result
        var profile: Dictionary = profile_value
        var biome := String(profile.get("biomeId", ""))
        var rock_scale_value: Variant = (profile.get("rock_scale", {}) as Dictionary).get("value", null) \
            if profile.get("rock_scale", null) is Dictionary else null
        if biome.is_empty() or not rock_scale_value is float and not rock_scale_value is int \
                or not profile.get("rock_families", null) is Array:
            result["status"] = "failed"
            result["reason"] = "rock_support_profile_inputs_invalid"
            return result
        var profile_scale := float(rock_scale_value)
        if not is_finite(profile_scale) or profile_scale <= 0.0:
            result["status"] = "failed"
            result["reason"] = "rock_support_profile_scale_invalid"
            return result
        var families: Array = profile.rock_families
        var filtered: Array[String] = []
        var fallback: Array[String] = []
        for family_value: Variant in families:
            var family := String(family_value)
            for asset_value: Variant in _assets_by_family.get(family, []):
                var asset_id := String(asset_value)
                var asset: Dictionary = _assets_by_id.get(asset_id, {})
                var tags: Array = asset.get("biomeTags", [])
                fallback.append(asset_id)
                if tags.is_empty() or tags.has(biome):
                    filtered.append(asset_id)
        var candidates := filtered if not filtered.is_empty() else fallback
        candidates.sort()
        candidates = _deduplicate_strings(candidates)
        if candidates.is_empty():
            result["status"] = "failed"
            result["reason"] = "rock_support_profile_has_no_assets:%s" % biome
            return result
        for asset_id: String in candidates:
            eligible_asset_ids[asset_id] = true
        profile_asset_rows.append({"biomeId":biome, "rockScale":profile_scale,
            "candidateAssetIds":candidates})
    # Unknown biomes resolve through BiomeEnvironmentCatalog's default profile.
    # The underground producer uses the biome key "underground", so include
    # that exact fallback lookup and tag filter in the same eligible-set proof.
    var fallback_id := String(profile_snapshot.get("fallbackId", ""))
    var fallback_profile: Dictionary = {}
    for profile_value: Variant in profile_snapshot.profiles:
        if profile_value is Dictionary \
                and String((profile_value as Dictionary).get("biomeId", "")) == fallback_id:
            fallback_profile = profile_value
            break
    if fallback_profile.is_empty():
        result["status"] = "failed"
        result["reason"] = "rock_support_fallback_profile_missing"
        return result
    var underground_families: Variant = fallback_profile.get("rock_families", null)
    var underground_scale_value: Variant = (fallback_profile.get("rock_scale", {}) as Dictionary).get("value", null) \
        if fallback_profile.get("rock_scale", null) is Dictionary else null
    if not underground_families is Array or not underground_scale_value is float \
            and not underground_scale_value is int:
        result["status"] = "failed"
        result["reason"] = "rock_support_fallback_profile_invalid"
        return result
    var underground_filtered: Array[String] = []
    var underground_fallback: Array[String] = []
    for family_value: Variant in underground_families:
        var family := String(family_value)
        for asset_value: Variant in _assets_by_family.get(family, []):
            var asset_id := String(asset_value)
            var asset: Dictionary = _assets_by_id.get(asset_id, {})
            var tags: Array = asset.get("biomeTags", [])
            underground_fallback.append(asset_id)
            if tags.is_empty() or tags.has("underground"):
                underground_filtered.append(asset_id)
    var underground_candidates := underground_filtered if not underground_filtered.is_empty() \
        else underground_fallback
    underground_candidates.sort()
    underground_candidates = _deduplicate_strings(underground_candidates)
    if underground_candidates.is_empty():
        result["status"] = "failed"
        result["reason"] = "rock_support_underground_has_no_assets"
        return result
    for asset_id: String in underground_candidates:
        eligible_asset_ids[asset_id] = true
    profile_asset_rows.append({"biomeId":"underground",
        "rockScale":float(underground_scale_value),
        "candidateAssetIds":underground_candidates,
        "resolvedProfileId":fallback_id})
    var asset_rows: Array[Dictionary] = []
    var sorted_ids: Array[String] = []
    for asset_id_value: Variant in eligible_asset_ids.keys():
        sorted_ids.append(String(asset_id_value))
    sorted_ids.sort()
    # Evaluate each profile/asset combination because the same scene can use a
    # different canonical rock_scale in each biome. Root spec extrema come
    # directly from RockRecipeBuilder.build_visual_spec.
    for profile_row: Dictionary in profile_asset_rows:
        var biome := String(profile_row.biomeId)
        var profile_scale := float(profile_row.rockScale)
        for asset_id: String in profile_row.candidateAssetIds:
            if _disabled_asset_ids.has(asset_id):
                result["status"] = "pending"
                result["reason"] = "eligible_rock_asset_disabled:%s" % asset_id
                return result
            var descriptor := describe_static_asset_without_instantiation(asset_id)
            if String(descriptor.get("status", "")) != "ready" \
                    or not static_asset_descriptor_is_current(descriptor):
                result["status"] = "pending"
                result["reason"] = "eligible_rock_asset_descriptor_unavailable:%s:%s" \
                    % [asset_id, String(descriptor.get("reason", "descriptor_stale"))]
                return result
            var declared_size := self.asset_size(asset_id)
            if declared_size.x <= 0.0 or declared_size.y <= 0.0 or declared_size.z <= 0.0:
                result["status"] = "failed"
                result["reason"] = "eligible_rock_asset_size_invalid:%s" % asset_id
                return result
            var root_scale := Vector3(
                (2.0 * 1.25 * 1.75) / maxf(0.1, declared_size.x),
                (1.25 * 1.55 * 1.30) / maxf(0.1, declared_size.z),
                (2.0 * 1.25 * 1.50) / maxf(0.1, declared_size.y)) * profile_scale
            var member_rows: Array[Dictionary] = []
            var asset_max_horizontal := 0.0
            var asset_max_vertical := 0.0
            for member_value: Variant in descriptor.get("renderMembers", []):
                if not member_value is Dictionary:
                    result["status"] = "failed"
                    result["reason"] = "eligible_rock_asset_member_invalid:%s" % asset_id
                    return result
                var member: Dictionary = member_value
                var mesh_bounds: Variant = member.get("meshBounds", null)
                var member_transform: Variant = member.get("transform", null)
                var member_local_bounds: Variant = member.get("localBounds", null)
                if not mesh_bounds is AABB or not member_transform is Transform3D \
                        or not member_local_bounds is AABB:
                    result["status"] = "failed"
                    result["reason"] = "eligible_rock_asset_member_bounds_unproven:%s" % asset_id
                    return result
                var member_transform_value: Transform3D = member_transform
                if not _static_aabb_is_valid(mesh_bounds) \
                        or not _static_aabb_is_valid(member_local_bounds) \
                        or not (member_transform_value * (mesh_bounds as AABB)).is_equal_approx(
                            member_local_bounds):
                    result["status"] = "failed"
                    result["reason"] = "eligible_rock_asset_member_local_bounds_disagree:%s" % asset_id
                    return result
                var asset_transform := Transform3D(Basis.IDENTITY.scaled(root_scale), Vector3.ZERO) \
                    * member_transform_value
                var transformed: AABB = asset_transform * (mesh_bounds as AABB)
                var radius := 0.0
                for x: float in [transformed.position.x, transformed.end.x]:
                    for z: float in [transformed.position.z, transformed.end.z]:
                        radius = maxf(radius, Vector2(x, z).length())
                var vertical := maxf(absf(transformed.position.y), absf(transformed.end.y))
                asset_max_horizontal = maxf(asset_max_horizontal, radius)
                asset_max_vertical = maxf(asset_max_vertical, vertical)
                member_rows.append({"memberId":String(member.get("memberId", "")),
                    "meshContentDigest":String(member.get("meshContentDigest", "")),
                    "materialContentDigest":String(member.get("materialContentDigest", "")),
                    "transform":member_transform, "meshBounds":mesh_bounds,
                    "transformedBounds":transformed})
            max_horizontal = maxf(max_horizontal, asset_max_horizontal)
            max_vertical = maxf(max_vertical, asset_max_vertical)
            var asset_digest := _static_descriptor_digest({
                "assetId":asset_id, "catalogContentDigest":descriptor.catalogContentDigest,
                "sceneContentDigest":descriptor.sceneContentDigest,
                "rootScale":root_scale, "members":member_rows})
            asset_rows.append({"assetId":asset_id, "biomeId":biome,
                "catalogContentDigest":String(descriptor.catalogContentDigest),
                "sceneContentDigest":String(descriptor.sceneContentDigest),
                "assetEnvelopeDigest":asset_digest,
                "maxHorizontalSupportMeters":asset_max_horizontal,
                "maxVerticalSupportMeters":asset_max_vertical})
    var safe_max_horizontal := max_horizontal + 0.0001
    var safe_max_vertical := max_vertical + 0.0001
    var policy := {"schema":"rock-static-descriptor-envelope/v1", "status":"ready",
        "profileCatalogRevision":String(profile_snapshot.contentIdentity),
        "registryRevision":str(generation_revision),
        "biomeCatalogRevision":str(profile_receipt.get("publicationRevision", "")),
        "assetCatalogDigest":asset_catalog_digest,
        "supportAlgorithmDigest":support_algorithm_digest,
        "eligibleAssetIds":sorted_ids, "assetRows":asset_rows,
        "profileAssetRows":profile_asset_rows,
        "maxHorizontalSupportMeters":safe_max_horizontal,
        "maxVerticalSupportMeters":safe_max_vertical,
        "rockRecipeRevision":"rock-source-recipe/v1",
        "assetSetDigest":_static_descriptor_digest(asset_rows)}
    policy["eligibleAssetSetDigest"] = _static_descriptor_digest({
        "profileCatalogRevision":String(profile_snapshot.contentIdentity),
        "registryRevision":str(generation_revision),
        "biomeCatalogRevision":str(profile_receipt.get("publicationRevision", "")),
        "eligibleAssetIds":sorted_ids, "assetRows":asset_rows,
        "profileAssetRows":profile_asset_rows})
    policy["digest"] = _static_descriptor_digest(policy)
    _rock_support_envelope_cache[cache_key] = policy.duplicate(true)
    return policy


func _cached_rock_support_descriptors_are_current(policy: Dictionary) -> bool:
    var eligible_ids: Variant = policy.get("eligibleAssetIds", null)
    var rows: Variant = policy.get("assetRows", null)
    if not eligible_ids is Array or not rows is Array or eligible_ids.is_empty() or rows.is_empty():
        return false
    for asset_id_value: Variant in eligible_ids:
        var asset_id := String(asset_id_value)
        var descriptor := describe_static_asset_without_instantiation(asset_id)
        if String(descriptor.get("status", "")) != "ready" \
                or not static_asset_descriptor_is_current(descriptor):
            return false
        var matching_rows := 0
        for row_value: Variant in rows:
            if not row_value is Dictionary or String(row_value.get("assetId", "")) != asset_id:
                continue
            matching_rows += 1
            if String(row_value.get("catalogContentDigest", "")) \
                    != String(descriptor.get("catalogContentDigest", "")) \
                    or String(row_value.get("sceneContentDigest", "")) \
                    != String(descriptor.get("sceneContentDigest", "")):
                return false
        if matching_rows <= 0:
            return false
    return true


func _deduplicate_strings(values: Array[String]) -> Array[String]:
    var result: Array[String] = []
    var seen: Dictionary = {}
    for value: String in values:
        if not seen.has(value):
            seen[value] = true
            result.append(value)
    return result

func profile_for_biome(biome: String) -> Resource:
    return environment_catalog.profile_for_biome(biome) if environment_catalog != null else null

func select_asset_id(families: PackedStringArray, biome: String, prop_id: String, role: String) -> String:
    var candidates: Array[String] = []
    for family in families:
        var family_ids: Array = _assets_by_family.get(String(family), [])
        for id_variant in family_ids:
            var asset_id := String(id_variant)
            var asset: Dictionary = _assets_by_id.get(asset_id, {})
            var tags: Array = asset.get("biomeTags", [])
            if tags.is_empty() or tags.has(biome):
                candidates.append(asset_id)
    if candidates.is_empty():
        for family in families:
            var family_ids: Array = _assets_by_family.get(String(family), [])
            for id_variant in family_ids:
                candidates.append(String(id_variant))
    if candidates.is_empty():
        return ""
    candidates.sort()
    var index := stable_index("%s:%s:%s" % [role, biome, prop_id], candidates.size())
    return candidates[index]

func instantiate_tree_visual(biome: String, prop_id: String) -> Node3D:
    var node := instantiate_asset(select_tree_asset_id(biome, prop_id))
    configure_tree_wind_instance(node, biome, prop_id)
    return node

func instantiate_procedural_tree_visual(
    biome: String,
    prop_id: String,
    runtime_spec: Dictionary,
    world_seed := ""
) -> Node3D:
    if tree_spawn_service == null:
        return null
    if not is_procedural_tree_family(String(runtime_spec.get("family", ""))):
        return null
    var request := runtime_spec.duplicate(true)
    request["treeId"] = prop_id
    request["biome"] = biome
    request["worldSeed"] = world_seed
    request["presentation"] = "runtime"
    return tree_spawn_service.spawn_tree(request)

func instantiate_rock_visual(biome: String, prop_id: String) -> Node3D:
    return instantiate_asset(select_rock_asset_id(biome, prop_id))

func instantiate_family(family: String, stable_key: String) -> Node3D:
    return instantiate_asset(select_asset_id(PackedStringArray([family]), "", stable_key, family))

func instantiate_asset(asset_id: String) -> Node3D:
    if asset_id == "" or _disabled_asset_ids.has(asset_id):
        return null
    var scene := _scene_cache.get(asset_id) as PackedScene
    if scene == null:
        return null
    # Imported GLB meshes are renderer presentation, not world or collision
    # authority. Godot's dummy renderer can load and retain the importer-owned
    # PackedScene, but hydrating that scene may hand an imported ArrayMesh RID to
    # an incompatible dummy mesh owner. Preserve deterministic asset selection
    # and source identity headlessly without asking the renderer to publish it.
    if not imported_scene_visual_publication_supported(DisplayServer.get_name()):
        return headless_imported_scene_proxy(asset_id, scene)
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

static func imported_scene_visual_publication_supported(display_server_name: String) -> bool:
    return display_server_name.strip_edges().to_lower() != "headless"

func headless_imported_scene_proxy(asset_id: String, scene: PackedScene) -> Node3D:
    var proxy := Node3D.new()
    proxy.name = "HeadlessImportedVisualProxy"
    proxy.set_meta("visual_source", "generated_asset")
    proxy.set_meta("visual_asset_id", asset_id)
    proxy.set_meta("headless_visual_proxy", true)
    proxy.set_meta("visual_publication", "headless_imported_scene_proxy")
    proxy.set_meta("imported_scene_resource_path", scene.resource_path if scene != null else "")
    apply_render_policy(proxy, asset_id)
    return proxy

func apply_render_policy(node: Node3D, asset_id: String) -> void:
    var asset: Dictionary = _assets_by_id.get(asset_id, {})
    var family := String(asset.get("family", ""))
    var shadow_policy := shadow_policy_for_family(family)
    var visibility_end := visibility_range_for_family(family)
    var render_members: Array[Dictionary] = []
    apply_render_policy_recursive(node, family, shadow_policy, visibility_end,
        Transform3D.IDENTITY, "", true, render_members)
    node.set_meta("shadow_policy", shadow_policy)
    node.set_meta("visibility_range_end", visibility_end)
    node.set_meta("shared_tree_wind_material", WIND_TREE_FAMILIES.has(family))
    if family == "rock":
        render_members.make_read_only()
        node.set_meta("static_render_member_values", render_members)

func shadow_policy_for_family(family: String) -> int:
    if family == "bush":
        return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func visibility_range_for_family(family: String) -> float:
    match family:
        "broadleaf_tree", "conifer_tree", "savanna_tree":
            return 260.0
        "mature_broadleaf_tree", "mature_conifer_tree", "mature_savanna_tree":
            return 340.0
        "old_growth_broadleaf_tree":
            return 380.0
        "ecological_broadleaf_tree", "ecological_conifer_tree", "ecological_savanna_tree":
            return 440.0
        "rock":
            return 220.0
        "stump_log":
            return 160.0
        "bush":
            return 120.0
    return 180.0

func apply_render_policy_recursive(node: Node, family: String, shadow_policy: int,
        visibility_end: float, parent_transform := Transform3D.IDENTITY,
        parent_path := "", is_asset_root := false,
        render_members: Array[Dictionary] = []) -> void:
    var node_transform := parent_transform
    if not is_asset_root and node is Node3D:
        node_transform = parent_transform * (node as Node3D).transform
    var node_path := parent_path
    if not is_asset_root:
        var sibling_index := node.get_index() if node.get_parent() != null else 0
        node_path = "%s/%s#%d" % [parent_path, String(node.name), sibling_index]
    if node is MeshInstance3D:
        var mesh_instance := node as MeshInstance3D
        mesh_instance.cast_shadow = shadow_policy
        mesh_instance.visibility_range_end = visibility_end
        mesh_instance.visibility_range_end_margin = minf(24.0, visibility_end * 0.12)
        mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
        if WIND_TREE_FAMILIES.has(family):
            apply_tree_wind_materials(mesh_instance)
            mesh_instance.extra_cull_margin = TREE_WIND_CULL_MARGIN
        if family == "bush":
            apply_bush_materials(mesh_instance)
        if family == "rock":
            _append_asset_render_members(mesh_instance, node_path, node_transform,
                asset_id_for_family_instance(mesh_instance), render_members)
    for child in node.get_children():
        apply_render_policy_recursive(child, family, shadow_policy, visibility_end,
            node_transform, node_path, false, render_members)

func asset_id_for_family_instance(node: Node) -> String:
    var root: Node = node
    while root.get_parent() != null:
        root = root.get_parent()
    return String(root.get_meta("visual_asset_id", ""))

func _append_asset_render_members(mesh_instance: MeshInstance3D, node_path: String,
        node_transform: Transform3D, asset_id: String,
        render_members: Array[Dictionary]) -> void:
    var mesh := mesh_instance.mesh
    if not is_instance_valid(mesh) or not mesh is ArrayMesh or asset_id.is_empty():
        return
    var array_mesh := mesh as ArrayMesh
    for surface_index in range(array_mesh.get_surface_count()):
        var material := mesh_instance.material_override
        if material == null:
            material = mesh_instance.get_surface_override_material(surface_index)
        if material == null:
            material = array_mesh.surface_get_material(surface_index)
        var layer := _static_asset_render_layer(material)
        var surface_mesh := _asset_surface_mesh(array_mesh, surface_index, material)
        var member_id := "%s:%s:surface:%d" % [asset_id, node_path, surface_index]
        var row := {"memberId":member_id, "status":"ready" if surface_mesh != null \
            and material is Material and not layer.is_empty() else "pending",
            "reason":"" if surface_mesh != null and material is Material \
            and not layer.is_empty() else "generated_asset_surface_material_or_mesh_unsupported",
            "mesh":surface_mesh, "material":material,
            "materialKey":"visual_asset:%s:%s:surface:%d" % [asset_id, node_path, surface_index],
            "renderLayer":layer, "transform":node_transform,
            "meshSurfaceIndex":surface_index, "nodePath":node_path}
        row.make_read_only()
        render_members.append(row)

const STATIC_SCENE_DESCRIPTOR_SCHEMA := "visual.static_scene_descriptor.v1"

func describe_static_asset_without_instantiation(asset_id: String) -> Dictionary:
    var cached: Dictionary = _published_static_descriptors.get(asset_id, {})
    if not cached.is_empty() and not _publication_invalidated:
        return cached
    if not _published_static_descriptors.is_empty() and not _publication_invalidated:
        return {"schema":STATIC_SCENE_DESCRIPTOR_SCHEMA, "status":"failed",
            "reason":"asset_not_in_sealed_static_catalog", "assetId":asset_id}
    return _read_static_asset_descriptor(asset_id)

func _read_static_asset_descriptor(asset_id: String) -> Dictionary:
    descriptor_scan_count += 1
    var result := {"schema":STATIC_SCENE_DESCRIPTOR_SCHEMA, "status":"pending",
        "reason":"", "assetId":asset_id}
    if not loaded or asset_id.is_empty() or _disabled_asset_ids.has(asset_id):
        result["status"] = "failed"
        result["reason"] = "registry_or_asset_unavailable"
        return result
    var asset_variant = _assets_by_id.get(asset_id)
    var packed := _scene_cache.get(asset_id) as PackedScene
    if not (asset_variant is Dictionary) or packed == null:
        result["status"] = "failed"
        result["reason"] = "asset_manifest_or_packed_scene_unavailable"
        return result
    var asset: Dictionary = asset_variant
    var expected_path := "res://%s" % String(asset.get("path", ""))
    if expected_path == "res://" or packed.resource_path != expected_path:
        result["status"] = "failed"
        result["reason"] = "packed_scene_path_mismatch"
        return result
    if not packed.can_instantiate():
        result["status"] = "failed"
        result["reason"] = "packed_scene_cannot_instantiate"
        return result
    var state := packed.get_state()
    if state == null or state.get_node_count() <= 0:
        result["status"] = "failed"
        result["reason"] = "packed_scene_state_empty"
        return result
    var state_digest_data: Array = []
    var node_records: Array[Dictionary] = []
    var path_to_record := {}
    var root_type := ""
    for state_index in range(state.get_node_count()):
        var node_path := state.get_node_path(state_index)
        var type_name := state.get_node_type(state_index)
        if type_name.is_empty() or not ClassDB.class_exists(type_name) \
                or int(ClassDB.class_get_api_type(type_name)) != int(ClassDB.API_CORE):
            result["status"] = "failed"
            result["reason"] = "non_core_or_unknown_scene_node_type:%s" % type_name
            return result
        if state.is_node_instance_placeholder(state_index) \
                or not state.get_node_instance_placeholder(state_index).is_empty() \
                or state.get_node_instance(state_index) != null:
            result["status"] = "failed"
            result["reason"] = "instanced_or_placeholder_scene_node:%s" % String(node_path)
            return result
        if state_index == 0:
            root_type = type_name
            if not ClassDB.is_parent_class(type_name, "Node3D"):
                result["status"] = "failed"
                result["reason"] = "scene_root_not_node3d"
                return result
        var properties := {}
        for property_index in range(state.get_node_property_count(state_index)):
            var property_name := state.get_node_property_name(state_index, property_index)
            var property_value = state.get_node_property_value(state_index, property_index)
            properties[property_name] = property_value
            if property_name == "script" and property_value != null:
                result["status"] = "failed"
                result["reason"] = "script_attached_to_scene_node:%s" % String(node_path)
                return result
        var path_text := String(node_path)
        var parent_text := ""
        if path_text != "." and path_text != "":
            var slash := path_text.rfind("/")
            parent_text = "." if slash < 0 else path_text.substr(0, slash)
        var sibling_index := state.get_node_index(state_index)
        var node_name := String(node_path.get_name(node_path.get_name_count() - 1)) \
            if node_path.get_name_count() > 0 else "Root"
        var render_path := ""
        if state_index > 0:
            var parent_render_path := String(path_to_record.get(parent_text, ""))
            render_path = "%s/%s#%d" % [parent_render_path, node_name, sibling_index]
        var record := {"stateIndex":state_index, "path":path_text, "parent":parent_text,
            "renderPath":render_path, "type":type_name, "properties":properties}
        node_records.append(record)
        path_to_record[path_text] = render_path
        state_digest_data.append({"path":path_text, "type":type_name,
            "siblingIndex":sibling_index, "properties":_static_descriptor_value(properties, 0, {})})
    # Inherited scenes add serialized state outside the flattened node list on
    # some import paths. Reject them until that state can be attested recursively.
    if state.get_base_scene_state() != null:
        result["status"] = "failed"
        result["reason"] = "inherited_scene_state_not_attested"
        return result

    var render_members: Array[Dictionary] = []
    var aggregate_bounds := AABB()
    var has_bounds := false
    var resource_receipts: Array[Dictionary] = []
    for record in node_records:
        var type_name := String(record["type"])
        if not ClassDB.is_parent_class(type_name, "MeshInstance3D"):
            continue
        var properties: Dictionary = record["properties"]
        var mesh := properties.get("mesh") as Mesh
        if mesh == null or not mesh is ArrayMesh:
            result["status"] = "failed"
            result["reason"] = "mesh_missing_or_not_array_mesh:%s" % String(record["path"])
            return result
        var local_transform: Variant = _static_scene_node_transform(properties)
        if local_transform == null:
            result["status"] = "failed"
            result["reason"] = "mesh_node_transform_unattested:%s" % String(record["path"])
            return result
        var parent_transform: Variant = _static_scene_parent_transform(String(record["parent"]), node_records)
        if parent_transform == null:
            result["status"] = "failed"
            result["reason"] = "parent_transform_unattested:%s" % String(record["path"])
            return result
        var member_transform: Transform3D = parent_transform * (local_transform as Transform3D)
        var array_mesh := mesh as ArrayMesh
        if array_mesh.get_surface_count() <= 0:
            result["status"] = "failed"
            result["reason"] = "mesh_has_no_surfaces:%s" % String(record["path"])
            return result
        var mesh_fingerprint: Dictionary = StaticRenderMeshFingerprintScript.inspect(array_mesh)
        if String(mesh_fingerprint.get("status", "")) != "ready":
            result["status"] = "failed"
            result["reason"] = "mesh_content_digest_unavailable:%s:%s" % [
                String(record["path"]), String(mesh_fingerprint.get("reason", "unknown"))]
            return result
        var mesh_content_digest := String(mesh_fingerprint.get("contentDigest", ""))
        if mesh_content_digest.length() != 64:
            result["status"] = "failed"
            result["reason"] = "mesh_content_digest_invalid:%s" % String(record["path"])
            return result
        for surface_index in range(array_mesh.get_surface_count()):
            var material := properties.get("material_override") as Material
            if material == null:
                material = _static_scene_surface_override(properties, surface_index)
            if material == null:
                material = array_mesh.surface_get_material(surface_index)
            if material == null:
                result["status"] = "failed"
                result["reason"] = "surface_material_missing:%s:%d" % [String(record["path"]), surface_index]
                return result
            var layer := _static_asset_render_layer(material)
            if layer.is_empty():
                result["status"] = "failed"
                result["reason"] = "surface_material_layer_unresolved:%s:%d" % [String(record["path"]), surface_index]
                return result
            var surface_arrays := array_mesh.surface_get_arrays(surface_index)
            if surface_arrays.is_empty() or surface_arrays.size() <= Mesh.ARRAY_VERTEX \
                    or not (surface_arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array):
                result["status"] = "failed"
                result["reason"] = "surface_vertex_data_unavailable:%s:%d" % [String(record["path"]), surface_index]
                return result
            var vertices: PackedVector3Array = surface_arrays[Mesh.ARRAY_VERTEX]
            if vertices.is_empty():
                result["status"] = "failed"
                result["reason"] = "surface_vertex_data_empty:%s:%d" % [String(record["path"]), surface_index]
                return result
            var mesh_bounds := _static_vertices_bounds(vertices)
            var member_bounds := _static_transform_aabb(mesh_bounds, member_transform)
            aggregate_bounds = member_bounds if not has_bounds else aggregate_bounds.merge(member_bounds)
            has_bounds = true
            # The renderer binds the whole Mesh resource. Keep surface index
            # in member identity and its material digest surface-specific, but
            # attest geometry with the same complete-resource fingerprint the
            # candidate assembler and native installer verify.
            var mesh_digest := mesh_content_digest
            var material_content := _static_material_content(material, 0, {})
            if material_content.is_empty():
                result["status"] = "failed"
                result["reason"] = "material_content_unattested:%s:%d" % [String(record["path"]), surface_index]
                return result
            var material_fingerprint: Dictionary = StaticRenderMaterialFingerprintScript.inspect(material)
            if String(material_fingerprint.get("status", "")) != "ready":
                result["status"] = "failed"
                result["reason"] = "material_render_fingerprint_unavailable:%s:%d:%s" % [
                    String(record["path"]), surface_index,
                    String(material_fingerprint.get("reason", "unknown"))]
                return result
            var material_digest := String(material_fingerprint.get("contentDigest", ""))
            var member_id := "%s:%s:surface:%d" % [asset_id, String(record["renderPath"]), surface_index]
            var member := {
                "memberId":member_id, "status":"ready", "mesh":mesh,
                "material":material, "materialKey":"visual_asset:%s:%s:surface:%d" \
                    % [asset_id, String(record["renderPath"]), surface_index],
                "renderLayer":layer, "transform":member_transform,
                "meshSurfaceIndex":surface_index, "nodePath":String(record["renderPath"]),
                "meshBounds":mesh_bounds, "localBounds":member_bounds,
                "meshResourcePath":mesh.resource_path, "meshResourceId":mesh.get_instance_id(),
                "meshContentDigest":mesh_digest,
                "materialResourcePath":material.resource_path,
                "materialResourceId":material.get_instance_id(),
                "materialContentDigest":material_digest,
                "primitiveType":array_mesh.surface_get_primitive_type(surface_index)
            }
            render_members.append(member)
            resource_receipts.append({"meshPath":mesh.resource_path,
                "meshId":mesh.get_instance_id(), "meshDigest":mesh_digest,
                "materialPath":material.resource_path, "materialId":material.get_instance_id(),
                "materialDigest":material_digest})
    if render_members.is_empty() or not has_bounds:
        result["status"] = "failed"
        result["reason"] = "scene_has_no_proven_render_members"
        return result
    var receipt := generation_receipt()
    result.merge({"status":"ready", "reason":"", "registryReceipt":receipt,
        "catalogAssetDigest":_static_descriptor_digest(_static_descriptor_value(asset, 0, {})),
        "catalogContentDigest":_static_descriptor_digest(_static_descriptor_value(asset, 0, {})),
        "packedScenePath":packed.resource_path, "packedSceneId":packed.get_instance_id(),
        "sceneStateDigest":_static_descriptor_digest(state_digest_data),
        "sceneContentDigest":_static_descriptor_digest(state_digest_data),
        "rootType":root_type, "aggregateLocalBounds":aggregate_bounds,
        "renderMembers":render_members, "resourceReceipts":resource_receipts}, true)
    return result

func static_asset_descriptor_is_current(descriptor: Dictionary) -> bool:
    if String(descriptor.get("schema", "")) != STATIC_SCENE_DESCRIPTOR_SCHEMA \
            or String(descriptor.get("status", "")) != "ready" \
            or _publication_invalidated:
        return false
    var asset_id := String(descriptor.get("assetId", ""))
    var current: Dictionary = _published_static_descriptors.get(asset_id, {})
    return not current.is_empty() and is_same(current, descriptor)

func _static_scene_node_transform(properties: Dictionary) -> Variant:
    if properties.has("transform"):
        var transform_value = properties.get("transform")
        return transform_value if transform_value is Transform3D else null
    var position_value = properties.get("position", Vector3.ZERO)
    var rotation_value = properties.get("rotation", Vector3.ZERO)
    var scale_value = properties.get("scale", Vector3.ONE)
    if not position_value is Vector3 or not rotation_value is Vector3 or not scale_value is Vector3:
        return null
    var basis := Basis.from_euler(rotation_value, EULER_ORDER_YXZ).scaled(scale_value)
    return Transform3D(basis, position_value)

func _static_scene_parent_transform(parent_path: String, records: Array[Dictionary]) -> Variant:
    if parent_path.is_empty() or parent_path == ".":
        return Transform3D.IDENTITY
    for record in records:
        if String(record["path"]) == parent_path:
            var properties: Dictionary = record["properties"]
            var local_transform = _static_scene_node_transform(properties) \
                if ClassDB.is_parent_class(String(record["type"]), "Node3D") else Transform3D.IDENTITY
            if local_transform == null:
                return null
            var parent_transform = _static_scene_parent_transform(String(record["parent"]), records)
            if parent_transform == null:
                return null
            return (parent_transform as Transform3D) * (local_transform as Transform3D)
    return null

func _static_scene_surface_override(properties: Dictionary, surface_index: int) -> Material:
    var key := "surface_material_override/%d" % surface_index
    if not properties.has(key):
        return null
    return properties[key] as Material

func _static_vertices_bounds(vertices: PackedVector3Array) -> AABB:
    var bounds := AABB(vertices[0], Vector3.ZERO)
    for index in range(1, vertices.size()):
        bounds = bounds.expand(vertices[index])
    return bounds

func _static_transform_aabb(bounds: AABB, transform: Transform3D) -> AABB:
    var first := true
    var result := AABB()
    for x in [bounds.position.x, bounds.end.x]:
        for y in [bounds.position.y, bounds.end.y]:
            for z in [bounds.position.z, bounds.end.z]:
                var point := transform * Vector3(x, y, z)
                if first:
                    result = AABB(point, Vector3.ZERO)
                    first = false
                else:
                    result = result.expand(point)
    return result

func _static_aabb_is_valid(bounds: AABB) -> bool:
    return bounds.position.is_finite() and bounds.size.is_finite() \
        and bounds.end.is_finite() and bounds.size.x > 0.0 \
        and bounds.size.y > 0.0 and bounds.size.z > 0.0

func _static_material_content(material: Material, depth: int, visited: Dictionary) -> Dictionary:
    if material == null or depth > 8:
        return {}
    var instance_id := material.get_instance_id()
    if visited.has(instance_id):
        return {"cycleRef":String(material.get_class()), "path":material.resource_path}
    visited[instance_id] = true
    var properties := []
    var property_list := material.get_property_list()
    property_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return String(a.get("name", "")) < String(b.get("name", "")))
    for property in property_list:
        if (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
            continue
        var property_name := String(property.get("name", ""))
        var value = material.get(property_name)
        var converted: Variant = _static_content_value(value, depth + 1, visited)
        if converted == null and value != null:
            return {}
        properties.append([property_name, converted])
    visited.erase(instance_id)
    return {"class":material.get_class(), "path":material.resource_path,
        "properties":properties}

func _static_resource_content(resource: Resource, depth: int, visited: Dictionary) -> Dictionary:
    if resource == null or depth > 8:
        return {}
    var instance_id := resource.get_instance_id()
    if visited.has(instance_id):
        return {"cycleRef":resource.get_class(), "path":resource.resource_path}
    visited[instance_id] = true
    var properties := []
    var property_list := resource.get_property_list()
    property_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return String(a.get("name", "")) < String(b.get("name", "")))
    for property in property_list:
        if (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
            continue
        var property_name := String(property.get("name", ""))
        var value = resource.get(property_name)
        var converted: Variant = _static_content_value(value, depth + 1, visited)
        if converted == null and value != null:
            return {}
        properties.append([property_name, converted])
    visited.erase(instance_id)
    return {"class":resource.get_class(), "path":resource.resource_path,
        "properties":properties}

func _static_content_value(value: Variant, depth: int, visited: Dictionary) -> Variant:
    if depth > 8:
        return null
    if value is Resource:
        var content := _static_resource_content(value as Resource, depth + 1, visited)
        return null if content.is_empty() else content
    if value is Object:
        return null
    if value is Dictionary:
        var keys: Array = value.keys()
        keys.sort()
        var result := []
        for key in keys:
            var child = value[key]
            var converted = _static_content_value(child, depth + 1, visited)
            if converted == null and child != null:
                return null
            result.append([key, converted])
        return result
    if value is Array:
        var result := []
        for child in value:
            var converted = _static_content_value(child, depth + 1, visited)
            if converted == null and child != null:
                return null
            result.append(converted)
        return result
    return value

func _static_descriptor_value(value: Variant, depth: int, visited: Dictionary) -> Variant:
    if depth > 8:
        return "depth_limit"
    if value is Resource:
        return _static_resource_content(value as Resource, depth + 1, visited)
    if value is Object:
        return {"objectClass":value.get_class()}
    if value is Dictionary:
        var keys: Array = value.keys()
        keys.sort()
        var result := []
        for key in keys:
            result.append([key, _static_descriptor_value(value[key], depth + 1, visited)])
        return result
    if value is Array:
        var result := []
        for item in value:
            result.append(_static_descriptor_value(item, depth + 1, visited))
        return result
    return value

func _static_descriptor_digest(value: Variant) -> String:
    var context := HashingContext.new()
    if context.start(HashingContext.HASH_SHA256) != OK:
        return ""
    if context.update(var_to_bytes(value)) != OK:
        return ""
    return context.finish().hex_encode()

func _asset_surface_mesh(source_mesh: ArrayMesh, surface_index: int,
        material: Material) -> ArrayMesh:
    if surface_index < 0 or surface_index >= source_mesh.get_surface_count():
        return null
    var arrays := source_mesh.surface_get_arrays(surface_index)
    if arrays.is_empty():
        return null
    var result := ArrayMesh.new()
    result.add_surface_from_arrays(source_mesh.surface_get_primitive_type(surface_index), arrays)
    if material != null:
        result.surface_set_material(0, material)
    return result

func _static_asset_render_layer(material: Material) -> String:
    if material is ShaderMaterial:
        var shader := (material as ShaderMaterial).shader
        if shader == null or shader.code.is_empty() or shader.code.contains("ALPHA") \
                or shader.code.contains("discard") or shader.code.contains("blend_"):
            return ""
        return "opaque"
    if material is BaseMaterial3D:
        var base := material as BaseMaterial3D
        if base.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
                and base.albedo_color.a >= 0.999:
            return "opaque"
        if base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
            return "cutout"
    return "translucent"

func apply_tree_wind_materials(mesh_instance: MeshInstance3D) -> void:
    if mesh_instance.mesh == null:
        return
    for surface_index in range(mesh_instance.mesh.get_surface_count()):
        var source_material := mesh_instance.get_surface_override_material(surface_index)
        if source_material == null:
            source_material = mesh_instance.mesh.surface_get_material(surface_index)
        mesh_instance.set_surface_override_material(surface_index, shared_tree_wind_material(source_material))


func apply_bush_materials(mesh_instance: MeshInstance3D) -> void:
    if mesh_instance.mesh == null:
        return
    for surface_index in range(mesh_instance.mesh.get_surface_count()):
        var source_material := mesh_instance.get_surface_override_material(surface_index)
        if source_material == null:
            source_material = mesh_instance.mesh.surface_get_material(surface_index)
        var role := "leaf_primary"
        if source_material != null:
            role = String(source_material.resource_name).to_lower()
        var material := StandardMaterial3D.new()
        material.resource_name = role
        material.roughness = 0.92
        if "trunk" in role or "stem" in role:
            material.albedo_color = Color(0.18, 0.075, 0.025)
        elif "secondary" in role:
            material.albedo_color = Color(0.13, 0.255, 0.085)
        else:
            material.albedo_color = Color(0.19, 0.34, 0.115)
        mesh_instance.set_surface_override_material(surface_index, material)

func shared_tree_wind_material(source_material: Material) -> ShaderMaterial:
    var role := "tree_default"
    var base_color := Color(0.26, 0.48, 0.22, 1.0)
    var roughness := 0.82
    if source_material != null:
        role = source_material.resource_name.strip_edges()
        if role == "":
            role = "tree_default"
        if source_material is BaseMaterial3D:
            var base_material := source_material as BaseMaterial3D
            base_color = base_material.albedo_color
            roughness = base_material.roughness
    if tree_wind_material_cache.has(role):
        return tree_wind_material_cache[role] as ShaderMaterial
    var material := ShaderMaterial.new()
    material.resource_name = "shared_tree_wind_%s" % role
    material.shader = TREE_WIND_SHADER
    material.set_shader_parameter("base_color", base_color)
    material.set_shader_parameter("roughness", roughness)
    material.set_shader_parameter("main_bend_meters", 0.48)
    material.set_shader_parameter("detail_flutter_meters", 0.075 if foliage_material_role(role) else 0.018)
    var bark_role := role == "trunk" or role == "bark_dark"
    material.set_shader_parameter("bark_enabled", 1.0 if bark_role else 0.0)
    material.set_shader_parameter("bark_accent_color", base_color.darkened(0.30) if bark_role else base_color)
    material.set_shader_parameter("bark_grain_contrast", 0.34 if role == "trunk" else 0.46)
    tree_wind_material_cache[role] = material
    return material

func foliage_material_role(role: String) -> bool:
    return role.begins_with("leaf_") or role.begins_with("needle_") or role == "savanna_leaf"

func configure_tree_wind_instance(node: Node3D, biome: String, prop_id: String, visual_scale := 1.0) -> void:
    if node == null:
        return
    var profile := profile_for_biome(biome)
    var response := clampf(float(profile.get("wind_response")) if profile != null else 1.0, 0.0, 2.0)
    var phase := stable_unit("tree-wind-phase:%s:%s" % [biome, prop_id]) * TAU
    var variation := stable_unit("tree-wind-stiffness:%s:%s" % [biome, prop_id])
    var stiffness := clampf(1.18 - response * 0.18 + variation * 0.22, 0.68, 1.32)
    var bark_scale := maxf(0.1, float(visual_scale))
    configure_tree_wind_instance_recursive(node, phase, stiffness, response, bark_scale)
    node.set_meta("tree_wind_phase", phase)
    node.set_meta("tree_wind_stiffness", stiffness)
    node.set_meta("tree_wind_response", response)
    node.set_meta("tree_bark_scale", bark_scale)

func configure_tree_wind_instance_recursive(node: Node, phase: float, stiffness: float, response: float, bark_scale: float) -> void:
    if node is MeshInstance3D:
        var mesh_instance := node as MeshInstance3D
        mesh_instance.set_instance_shader_parameter("tree_phase", phase)
        mesh_instance.set_instance_shader_parameter("tree_stiffness", stiffness)
        mesh_instance.set_instance_shader_parameter("tree_response", response)
        mesh_instance.set_instance_shader_parameter("bark_scale", Vector2(bark_scale, bark_scale))
    for child in node.get_children():
        configure_tree_wind_instance_recursive(child, phase, stiffness, response, bark_scale)

func tree_wind_material_count() -> int:
    return tree_wind_material_cache.size()

func tree_wind_material_roles() -> Array[String]:
    var roles: Array[String] = []
    for role_variant in tree_wind_material_cache.keys():
        roles.append(String(role_variant))
    roles.sort()
    return roles

func asset_size(asset_id: String) -> Vector3:
    var asset: Dictionary = _assets_by_id.get(asset_id, {})
    var bounds: Dictionary = asset.get("boundingBox", {})
    var size: Array = bounds.get("size", [])
    if size.size() < 3:
        return Vector3.ONE
    return Vector3(float(size[0]), float(size[1]), float(size[2]))

func asset_record(asset_id: String) -> Dictionary:
    var asset: Dictionary = _assets_by_id.get(asset_id, {})
    return asset.duplicate(true)

func tree_runtime_spec(
    biome: String,
    prop_id: String,
    fallback_height := 4.0,
    world_cell := INVALID_TREE_CELL,
    world_seed := ""
) -> Dictionary:
    var profile := profile_for_biome(biome)
    if profile == null or tree_runtime_request_builder == null:
        return {}
    var catalog_snapshot := ActiveBiomeEnvironmentSnapshotScript.capture(environment_catalog)
    return tree_runtime_request_builder.build(profile, biome, prop_id, fallback_height,
        world_cell, world_seed, catalog_snapshot)

func tree_biome_parameters(profile: BiomeEnvironmentProfile) -> Dictionary:
    return TreeRuntimeRequestBuilderScript.biome_parameters_for_profile(profile)

func select_tree_family(profile: BiomeEnvironmentProfile, biome: String, prop_id: String, world_seed: String) -> String:
    return TreeRuntimeRequestBuilderScript.select_tree_family(profile, biome, prop_id, world_seed)

func architecture_for_tree_family(family: String) -> String:
    return TreeRuntimeRequestBuilderScript.architecture_for_tree_family(family)

func species_grammar_for_tree(family: String, biome: String, prop_id: String, world_seed: String) -> String:
    # The registry turns ecology into a request; canonical grammar authority lives
    # in TreeSpawnService so the PoC and the live world cannot silently diverge.
    return TreeSpawnServiceScript.grammar_for_architecture(architecture_for_tree_family(family))

func is_procedural_tree_family(family: String) -> bool:
    return architecture_for_tree_family(family) != ""

func is_complete_tree_asset(asset: Dictionary) -> bool:
    return is_procedural_tree_family(String(asset.get("family", "")))

func tree_scale_for_biome(biome: String) -> float:
    var profile := profile_for_biome(biome)
    return float(profile.get("tree_scale")) if profile else 1.0

func rock_scale_for_biome(biome: String) -> float:
    var profile := profile_for_biome(biome)
    return float(profile.get("rock_scale")) if profile else 1.0

func disable_asset_for_test(asset_id: String) -> void:
    if asset_id != "" and not _disabled_asset_ids.has(asset_id):
        generation_revision += 1
        _rock_support_envelope_cache.clear()
        _disabled_asset_ids[asset_id] = true
        _published_core_snapshot = {}
        _published_catalog_snapshot = {}
        _published_profile_digest = ""
        _published_biome_publication = {}

func clear_test_disabled_assets() -> void:
    if not _disabled_asset_ids.is_empty():
        generation_revision += 1
        _rock_support_envelope_cache.clear()
    _disabled_asset_ids.clear()
    _published_core_snapshot = {}
    _published_catalog_snapshot = {}
    _published_profile_digest = ""
    _published_biome_publication = {}

func stable_index(text: String, modulo: int) -> int:
    if modulo <= 0:
        return 0
    return abs(stable_hash(text)) % modulo

func stable_unit(text: String) -> float:
    return float(abs(stable_hash(text)) % 100000) / 100000.0

func stable_hash(text: String) -> int:
    var h := 2166136261
    for i in range(text.length()):
        h = int((h ^ text.unicode_at(i)) * 16777619) & 0xffffffff
    return h
