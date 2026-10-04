extends RefCounted
class_name ActiveRemovedPropsSnapshot

## Capture-only boundary for Main.removed_props. The dictionary remains the
## gameplay/save authority; this value copy is only an N3/N4 admission input.
const SCHEMA_VERSION := 1
const MAX_IDS := 65536
const MAX_ID_BYTES := 1024
const MAX_SCOPED_IDS := 4096

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


## Capture removal state only for IDs admitted by one immutable producer snapshot.
## This keeps chunk-local rendering work independent of the world-wide tombstone
## count while still checking the authoritative map twice for these exact IDs.
static func capture_for_ids(main: Object, requested_ids: Array) -> Dictionary:
	if main == null or not is_instance_valid(main):
		return _failed("main_missing")
	if requested_ids.size() > MAX_SCOPED_IDS:
		return _failed("too_many_scoped_ids")
	var owner_id := main.get_instance_id()
	var seed_value: Variant = main.get("seed_text")
	var revision: Variant = main.get("removed_props_revision")
	var source_value: Variant = main.get("removed_props")
	if not seed_value is String or (seed_value as String).is_empty():
		return _failed("seed_invalid")
	if not revision is int or revision < 0:
		return _failed("revision_invalid")
	if not source_value is Dictionary:
		return _failed("removed_props_not_dictionary")
	var checked_ids: Array[String] = []
	for id_value: Variant in requested_ids:
		if not id_value is String:
			return _failed("scoped_id_not_string")
		var id := String(id_value)
		if id.is_empty() or id.to_utf8_buffer().size() > MAX_ID_BYTES:
			return _failed("scoped_id_bounds_invalid")
		if id not in checked_ids:
			checked_ids.append(id)
	checked_ids.sort()
	var first := _read_scoped_presence(source_value, checked_ids)
	if not bool(first.get("ok", false)):
		return first
	var second := _read_scoped_presence(source_value, checked_ids)
	if not bool(second.get("ok", false)) or first.get("presence") != second.get("presence") \
			or not is_instance_valid(main) or main.get_instance_id() != owner_id \
			or main.get("seed_text") != seed_value \
			or main.get("removed_props_revision") != revision \
			or main.get("removed_props") != source_value:
		return _failed("source_changed_during_scoped_capture")
	var removed_ids: Array[String] = []
	for row_value: Variant in first.get("presence", []):
		if row_value is Array and row_value.size() == 2 and bool(row_value[1]):
			removed_ids.append(String(row_value[0]))
	return {"ok":true, "schemaVersion":SCHEMA_VERSION, "scope":"requested_ids",
		"ownerInstanceId":owner_id, "seed":seed_value, "revision":revision,
		"checkedIds":checked_ids, "ids":removed_ids,
		"contentIdentity":_scoped_identity(first.get("presence", []))}


static func is_current_for_ids(main: Object, snapshot: Dictionary,
		requested_ids: Array) -> bool:
	if String(snapshot.get("scope", "")) != "requested_ids":
		return is_current(main, snapshot)
	if main == null or not is_instance_valid(main) or not bool(snapshot.get("ok", false)) \
			or snapshot.get("schemaVersion") != SCHEMA_VERSION \
			or snapshot.get("ownerInstanceId") != main.get_instance_id() \
			or snapshot.get("seed") != main.get("seed_text") \
			or snapshot.get("revision") != main.get("removed_props_revision"):
		return false
	var fresh := capture_for_ids(main, requested_ids)
	return bool(fresh.get("ok", false)) \
		and snapshot.get("checkedIds") == fresh.get("checkedIds") \
		and snapshot.get("ids") == fresh.get("ids") \
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


static func _read_scoped_presence(source: Dictionary, checked_ids: Array) -> Dictionary:
	var presence: Array = []
	for id: String in checked_ids:
		presence.append([id, source.has(id)])
	return {"ok":true, "presence":presence}


static func _scoped_identity(presence: Array) -> String:
	return Marshalls.raw_to_base64(var_to_bytes(presence)).sha256_text()

static func _failed(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
