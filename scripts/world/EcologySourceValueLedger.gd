extends RefCounted
class_name EcologySourceValueLedger

## Value-only capture for deterministic static ecology producer inputs.
## It deliberately does not inspect scene children or own render/collision nodes.

const SCHEMA := "ecology-source-values/v1"

var world_seed := ""
var chunk_key := Vector2i.ZERO
var source_revision := ""
var removed_props_revision := -1
var _records: Dictionary = {}
var _tombstones: Dictionary = {}
var _sealed := false

func configure(seed_text: String, key: Vector2i, revision: String,
		removed_revision: int) -> void:
	world_seed = seed_text
	chunk_key = key
	source_revision = revision
	removed_props_revision = removed_revision
	_records.clear()
	_tombstones.clear()
	_sealed = false

func record_candidate(candidate: Dictionary) -> bool:
	if _sealed or not _candidate_is_valid(candidate):
		return false
	var source_id := String(candidate.get("sourceId", ""))
	var value := candidate.duplicate(true)
	value["contentRevision"] = _digest(value)
	if _records.has(source_id):
		if String(_records[source_id].get("contentRevision", "")) != String(value.contentRevision):
			return false
		return true
	_records[source_id] = value
	_tombstones.erase(source_id)
	return true

func record_tombstone(source_id: String, reason := "harvested") -> bool:
	if _sealed or source_id.strip_edges() == "":
		return false
	_tombstones[source_id] = reason
	_records.erase(source_id)
	return true

func apply_removed_props(removed_props: Dictionary, revision := -1) -> void:
	if _sealed:
		return
	if revision >= 0:
		removed_props_revision = revision
	for source_id_value in _records.keys():
		var record: Dictionary = _records[source_id_value]
		var prop_id := String(record.get("propId", ""))
		if not prop_id.is_empty() and removed_props.has(prop_id):
			record_tombstone(String(source_id_value), "removed_props")

func snapshot() -> Dictionary:
	var source_ids: Array = _records.keys()
	source_ids.sort()
	var candidates: Array[Dictionary] = []
	for source_id_value in source_ids:
		candidates.append((_records[source_id_value] as Dictionary).duplicate(true))
	var tombstone_ids: Array = _tombstones.keys()
	tombstone_ids.sort()
	var tombstones: Array[Dictionary] = []
	for source_id_value in tombstone_ids:
		tombstones.append({"sourceId": String(source_id_value),
			"reason": String(_tombstones[source_id_value])})
	var result := {
		"schema": SCHEMA,
		"scope": "partial_static_ecology_producer_values",
		"lifetime": "streamed_chunk_owner; regenerated from seed and durable removals after unload",
		"worldSeed": world_seed,
		"chunk": chunk_key,
		"sourceRevision": source_revision,
		"removedPropsRevision": removed_props_revision,
		"candidates": candidates,
		"tombstones": tombstones,
		"coverage": ["trees_foliage_recipe_inputs", "surface_detail_instances"],
		"limitations": ["surface rocks, ore, forage, wildlife, and underground props are not captured",
			"tree geometry remains the deterministic recipe builder input, not compiled mesh data"]
	}
	result["contentRevision"] = _digest(result)
	_sealed = true
	return result.duplicate(true)

func _candidate_is_valid(candidate: Dictionary) -> bool:
	var source_id := String(candidate.get("sourceId", ""))
	var kind := String(candidate.get("kind", ""))
	var layers: Variant = candidate.get("renderLayers")
	var materials: Variant = candidate.get("materials")
	var transform: Variant = candidate.get("transform")
	var bounds: Variant = candidate.get("localBounds")
	return not source_id.is_empty() and kind in ["trees_foliage", "surface_detail"] \
		and layers is Array and not layers.is_empty() \
		and materials is Array and not materials.is_empty() \
		and transform is Transform3D and transform.is_finite() \
		and bounds is AABB and bounds.size.x >= 0.0 and bounds.size.y >= 0.0 and bounds.size.z >= 0.0

func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(JSON.stringify(_canonical(value)).to_utf8_buffer())
	return context.finish().hex_encode()

func _canonical(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var dictionary_entries: Array = []
		for key_value in keys:
			dictionary_entries.append([String(key_value), _canonical(value[key_value])])
		return dictionary_entries
	if value is Array:
		var array_entries: Array = []
		for item in value:
			array_entries.append(_canonical(item))
		return array_entries
	if value is Vector2i:
		return [value.x, value.y]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	if value is Transform3D:
		return [value.basis.x.x, value.basis.x.y, value.basis.x.z,
			value.basis.y.x, value.basis.y.y, value.basis.y.z,
			value.basis.z.x, value.basis.z.y, value.basis.z.z,
			value.origin.x, value.origin.y, value.origin.z]
	if value is AABB:
		return [_canonical(value.position), _canonical(value.size)]
	return value
