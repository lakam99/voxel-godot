extends RefCounted
class_name ActiveVisualAssetSnapshot

## Capture-only value boundary. Selection and imported-scene ownership stay in
## VisualAssetRegistry; this does not instantiate, import, or repair an asset.

const SCHEMA_VERSION := 1

static func capture(registry: VisualAssetRegistry) -> Dictionary:
	if registry == null or not registry.is_ready():
		return _failed("registry_not_ready")
	var before := registry.generation_receipt()
	if not bool(before.get("ready", false)) or int(before.get("revision", 0)) <= 0:
		return _failed("registry_receipt_invalid")
	var first := _read_values(registry)
	if not bool(first.get("ok", false)):
		return first
	var middle := registry.generation_receipt()
	var second := _read_values(registry)
	var after := registry.generation_receipt()
	if before != middle or middle != after or not bool(second.get("ok", false)) \
			or first.get("contentIdentity") != second.get("contentIdentity"):
		return _failed("registry_changed_during_capture")
	return {"ok": true, "schemaVersion": SCHEMA_VERSION, "ownerReceipt": before.duplicate(true),
		"contentIdentity": first.contentIdentity, "assets": (first.assets as Array).duplicate(true),
		"families": (first.families as Array).duplicate(true),
		"disabledIds": (first.disabledIds as Array).duplicate(true),
		"sceneCache": (first.sceneCache as Array).duplicate(true)}

static func is_current(registry: VisualAssetRegistry, snapshot: Dictionary) -> bool:
	if not bool(snapshot.get("ok", false)) or int(snapshot.get("schemaVersion", -1)) != SCHEMA_VERSION \
			or not snapshot.get("assets") is Array or not snapshot.get("families") is Array \
			or not snapshot.get("disabledIds") is Array or not snapshot.get("sceneCache") is Array \
			or not snapshot.get("contentIdentity") is String \
			or registry == null or not registry.is_ready() \
			or registry.generation_receipt() != snapshot.get("ownerReceipt", {}):
		return false
	var current := capture(registry)
	return bool(current.get("ok", false)) and current.get("ownerReceipt") == snapshot.get("ownerReceipt") \
		and current.get("contentIdentity") == snapshot.get("contentIdentity") \
		and current.get("assets") == snapshot.get("assets") \
		and current.get("families") == snapshot.get("families") \
		and current.get("disabledIds") == snapshot.get("disabledIds") \
		and current.get("sceneCache") == snapshot.get("sceneCache")

static func _read_values(registry: VisualAssetRegistry) -> Dictionary:
	var ids: Array[String] = []
	for id_value in registry.assets_by_id.keys():
		ids.append(String(id_value))
	ids.sort()
	var assets: Array[Dictionary] = []
	for id in ids:
		var asset = registry.assets_by_id.get(id)
		if not asset is Dictionary or String(asset.get("id", "")) != id \
				or String(asset.get("family", "")) == "":
			return _failed("asset_invalid:" + id)
		assets.append({"id": id, "value": (asset as Dictionary).duplicate(true)})
	var families: Array[Dictionary] = []
	var family_names: Array[String] = []
	for family_value in registry.assets_by_family.keys():
		family_names.append(String(family_value))
	family_names.sort()
	for family in family_names:
		var original = registry.assets_by_family.get(family)
		if not original is Array:
			return _failed("family_list_invalid:" + family)
		var ordered_ids: Array[String] = []
		for id_value in original:
			var id := String(id_value)
			if not registry.assets_by_id.has(id):
				return _failed("family_member_missing:" + id)
			ordered_ids.append(id)
		families.append({"family": family, "orderedIds": ordered_ids})
	var disabled: Array[String] = []
	for id_value in registry.disabled_asset_ids.keys():
		disabled.append(String(id_value))
	disabled.sort()
	var cached: Array[Dictionary] = []
	var cache_ids: Array[String] = []
	for id_value in registry.scene_cache.keys():
		cache_ids.append(String(id_value))
	cache_ids.sort()
	for id in cache_ids:
		var scene := registry.scene_cache.get(id) as PackedScene
		if scene == null or not registry.assets_by_id.has(id):
			return _failed("scene_cache_invalid:" + id)
		var asset: Dictionary = registry.assets_by_id[id]
		var expected_path := "res://%s" % String(asset.get("path", ""))
		if expected_path == "res://" or scene.resource_path != expected_path:
			return _failed("scene_path_mismatch:" + id)
		var state := scene.get_state()
		if state == null or state.get_node_count() <= 0:
			return _failed("scene_root_missing:" + id)
		var root_type := String(state.get_node_type(0))
		if root_type != "Node3D" and not ClassDB.is_parent_class(root_type, "Node3D"):
			return _failed("scene_root_not_node3d:" + id)
		cached.append({"id": id, "resourcePath": scene.resource_path,
			"resourceInstanceId": scene.get_instance_id(), "rootType": root_type})
	for id in ids:
		var asset: Dictionary = registry.assets_by_id[id]
		if not registry.is_complete_tree_asset(asset) and not registry.scene_cache.has(id):
			return _failed("scene_cache_incomplete:" + id)
	# The cache is the sole import-readiness evidence. A selected but missing
	# scene remains non-instantiable; no replacement candidate is synthesized.
	var values := {"domain": "visual_asset_registry_active_values", "schemaVersion": SCHEMA_VERSION,
		"assets": assets, "families": families, "disabledIds": disabled, "sceneCache": cached}
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(JSON.stringify(values).to_utf8_buffer())
	return {"ok": true, "contentIdentity": context.finish().hex_encode(),
		"assets": assets, "families": families, "disabledIds": disabled, "sceneCache": cached}

static func _failed(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
