extends RefCounted
class_name ActiveRemovedPropsSnapshot

## Capture-only boundary for Main.removed_props. The dictionary remains the
## gameplay/save authority; this value copy is only an N3/N4 admission input.
const SCHEMA_VERSION := 1
const MAX_IDS := 65536
const MAX_ID_BYTES := 1024

static func capture(main: Object) -> Dictionary:
	if main == null or not is_instance_valid(main):
		return _failed("main_missing")
	var owner_id := main.get_instance_id()
	var seed_value: Variant = main.get("seed_text")
	var revision: Variant = main.get("removed_props_revision")
	if not seed_value is String or (seed_value as String).is_empty():
		return _failed("seed_invalid")
	if not revision is int or revision < 0:
		return _failed("revision_invalid")
	var first := _read_ids(main)
	if not bool(first.get("ok", false)):
		return first
	var second := _read_ids(main)
	if not bool(second.get("ok", false)) or first.get("ids") != second.get("ids") \
			or not is_instance_valid(main) or main.get_instance_id() != owner_id \
			or main.get("seed_text") != seed_value \
			or main.get("removed_props_revision") != revision:
		return _failed("source_changed_during_capture")
	return {"ok": true, "schemaVersion": SCHEMA_VERSION, "ownerInstanceId": owner_id,
		"seed": seed_value, "revision": revision, "ids": (first.ids as Array).duplicate(),
		"contentIdentity": _identity(first.ids)}

static func is_current(main: Object, snapshot: Dictionary) -> bool:
	if main == null or not is_instance_valid(main) or not bool(snapshot.get("ok", false)) \
			or snapshot.get("schemaVersion") != SCHEMA_VERSION \
			or snapshot.get("ownerInstanceId") != main.get_instance_id() \
			or snapshot.get("seed") != main.get("seed_text") \
			or snapshot.get("revision") != main.get("removed_props_revision") \
			or not snapshot.get("ids") is Array or not snapshot.get("contentIdentity") is String:
		return false
	var fresh := capture(main)
	return bool(fresh.get("ok", false)) and snapshot.get("ids") == fresh.get("ids") \
		and snapshot.get("contentIdentity") == fresh.get("contentIdentity")

static func _read_ids(main: Object) -> Dictionary:
	var source: Variant = main.get("removed_props")
	if not source is Dictionary:
		return _failed("removed_props_not_dictionary")
	var keys: Array = (source as Dictionary).keys()
	if keys.size() > MAX_IDS:
		return _failed("too_many_ids")
	var ids: Array[String] = []
	for key in keys:
		if not key is String:
			return _failed("id_not_string")
		var id: String = key
		if id.is_empty() or id.to_utf8_buffer().size() > MAX_ID_BYTES:
			return _failed("id_bounds_invalid")
		ids.append(id)
	ids.sort()
	return {"ok": true, "ids": ids}

static func _identity(ids: Array) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	for id: String in ids:
		var bytes := id.to_utf8_buffer()
		var size := PackedByteArray()
		size.resize(4)
		size.encode_u32(0, bytes.size())
		context.update(size)
		context.update(bytes)
	return context.finish().hex_encode()

static func _failed(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
