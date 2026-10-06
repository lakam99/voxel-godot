extends RefCounted
class_name ActiveVisualAssetSnapshot

## Capture-only value boundary. Selection and imported-scene ownership stay in
## VisualAssetRegistry; this does not instantiate, import, or repair an asset.

const SCHEMA_VERSION := 1

static func capture(registry: VisualAssetRegistry) -> Dictionary:
    if registry == null or not registry.is_ready() or registry.environment_catalog == null:
        return _failed("registry_not_ready")
    var biome_publication := registry.environment_catalog.published_catalog_snapshot()
    var publication := registry.published_catalog_snapshot(biome_publication)
    if String(publication.get("status", "")) != "ready":
        return _failed(String(publication.get("reason", "visual_catalog_not_ready")))
    var payload: Dictionary = publication.payload
    var snapshot := {"ok":true, "schemaVersion":SCHEMA_VERSION,
        "ownerReceipt":publication.ownerReceipt,
        "contentIdentity":String(publication.contentDigest),
        "assets":payload.assets, "families":payload.families,
        "disabledIds":payload.disabledIds, "sceneCache":payload.sceneCache,
        "publication":publication}
    snapshot.make_read_only()
    return snapshot

static func is_current(registry: VisualAssetRegistry, snapshot: Dictionary) -> bool:
    if not bool(snapshot.get("ok", false)) or int(snapshot.get("schemaVersion", -1)) != SCHEMA_VERSION \
            or not snapshot.get("assets") is Array or not snapshot.get("families") is Array \
            or not snapshot.get("disabledIds") is Array or not snapshot.get("sceneCache") is Array \
            or not snapshot.get("contentIdentity") is String \
            or registry == null or not registry.is_ready() or registry.environment_catalog == null \
            or not snapshot.get("publication", null) is Dictionary:
        return false
    var current: Dictionary = snapshot.publication
    var active := registry.published_catalog_snapshot(
        registry.environment_catalog.published_catalog_snapshot())
    return String(active.get("status", "")) == "ready" \
        and is_same(active, current) \
        and is_same(active.get("ownerReceipt"), snapshot.get("ownerReceipt")) \
        and String(active.get("contentDigest", "")) == String(snapshot.get("contentIdentity", "")) \
        and is_same(active.payload.get("assets"), snapshot.get("assets")) \
        and is_same(active.payload.get("families"), snapshot.get("families")) \
        and is_same(active.payload.get("disabledIds"), snapshot.get("disabledIds")) \
        and is_same(active.payload.get("sceneCache"), snapshot.get("sceneCache"))

static func _failed(reason: String) -> Dictionary:
    return {"ok":false, "reason":reason}
