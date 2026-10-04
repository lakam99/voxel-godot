extends RefCounted
class_name EcologySourceValueLedger

## Value-only capture for deterministic static ecology producer inputs.
## It deliberately does not inspect scene children or own render/collision nodes.

const SCHEMA := "ecology-source-values/v1"

var world_seed := ""
var chunk_key := Vector2i.ZERO
var source_revision := ""
var terrain_revision := -1
var removed_props_revision := -1
var _records: Dictionary = {}
var _tombstones: Dictionary = {}
var _complete_categories: Dictionary = {}
var _sealed := false

const STATIC_PROP_CATEGORIES := ["surface_rocks", "ore", "forage", "underground_props"]

func configure(seed_text: String, key: Vector2i, revision: String,
		removed_revision: int, terrain_revision_value := -1) -> void:
	world_seed = seed_text
	chunk_key = key
	source_revision = revision
	terrain_revision = terrain_revision_value
	removed_props_revision = removed_revision
	_records.clear()
	_tombstones.clear()
	_complete_categories.clear()
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
	_complete_categories.erase(String(value.get("category", "")))
	return true

func record_tombstone(source_id: String, reason := "harvested") -> bool:
	if _sealed or source_id.strip_edges() == "":
		return false
	var previous: Variant = _records.get(source_id, null)
	if previous is Dictionary:
		_complete_categories.erase(String(previous.get("category", "")))
	_tombstones[source_id] = reason
	_records.erase(source_id)
	return true


## Called only by the authoritative bounded producer after the full family
## decision/publication pass has completed for this chunk revision. An empty
## member list without this proof remains unknown, never empty success.
func mark_category_complete(category: String, provenance: Dictionary) -> bool:
	if _sealed or category not in STATIC_PROP_CATEGORIES or provenance.is_empty():
		return false
	if category == "underground_props" and String(provenance.get("scanRevision", "")).is_empty():
		return false
	var producer_revision := String(provenance.get("sourceRevision", ""))
	if producer_revision != source_revision or provenance.get("chunk", null) != chunk_key \
			or int(provenance.get("terrainRevision", -1)) != terrain_revision \
			or not bool(provenance.get("producerComplete", false)):
		return false
	var value := provenance.duplicate(true)
	value["category"] = category
	for record_value: Variant in _records.values():
		if record_value is Dictionary and String(record_value.get("category", "")) == category \
				and String(record_value.get("renderStatus", "")) != "ready":
			return false
	value["completeRevision"] = _digest(value)
	if String(value.completeRevision).is_empty():
		return false
	_complete_categories[category] = value
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

func snapshot(seal_ledger := true, content_scope := "complete") -> Dictionary:
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
	var tree_source_ids: Array[String] = []
	for candidate_value: Variant in candidates:
		if candidate_value is Dictionary and String(candidate_value.get("kind", "")) == "trees_foliage":
			tree_source_ids.append(String(candidate_value.get("sourceId", "")))
	tree_source_ids.sort()
	var tree_family_proof := {"producer":"finalized_chunk_prop_spawn",
		"chunk":chunk_key, "sourceRevision":source_revision,
		"producerComplete":true, "sourceIds":tree_source_ids}
	tree_family_proof["contentRevision"] = _digest(tree_family_proof)
	var result := {
		"schema": SCHEMA,
		"scope": "partial_static_ecology_producer_values",
		"lifetime": "streamed_chunk_owner; regenerated from seed and durable removals after unload",
		"worldSeed": world_seed,
		"chunk": chunk_key,
		"sourceRevision": source_revision,
		"terrainRevision": terrain_revision,
		"removedPropsRevision": removed_props_revision,
		"contentScope": content_scope,
		"deferredCategories": ["underground_props"] \
			if content_scope == "surface_pending_underground" else [],
		"candidates": candidates,
		"tombstones": tombstones,
		"treeFamilyProof":tree_family_proof,
		"coverage": ["trees_foliage_recipe_inputs", "surface_detail_instances",
			"realized_surface_ore_forage_and_fallback_rock_outputs",
			"realized_underground_rock_ore_and_forage_outputs"],
		"completeCategories": _complete_category_names(),
		"categoryProofs": _complete_categories.duplicate(true),
		"limitations": ["generated rock scene geometry remains pending until immutable asset member data is available",
			"wildlife remains an independent actor and is not captured as static ecology",
			"tree geometry remains the deterministic recipe builder input, not compiled mesh data"]
	}
	result["contentRevision"] = _digest(result)
	if seal_ledger:
		_sealed = true
	return result.duplicate(true)


func _complete_category_names() -> Array[String]:
	var result: Array[String] = []
	for category_value: Variant in _complete_categories.keys():
		result.append(String(category_value))
	result.sort()
	return result

func _candidate_is_valid(candidate: Dictionary) -> bool:
	var source_id := String(candidate.get("sourceId", ""))
	var kind := String(candidate.get("kind", ""))
	var layers: Variant = candidate.get("renderLayers")
	var materials: Variant = candidate.get("materials")
	var transform: Variant = candidate.get("transform")
	var bounds: Variant = candidate.get("localBounds")
	if kind == "realized_static_prop":
		var category := String(candidate.get("category", ""))
		var members: Variant = candidate.get("renderMembers", null)
		var provenance: Variant = candidate.get("provenance", null)
		var render_status := String(candidate.get("renderStatus", ""))
		if source_id.is_empty() or category not in STATIC_PROP_CATEGORIES \
				or not members is Array or not provenance is Dictionary \
				or render_status not in ["ready", "pending"]:
			return false
		for member_value: Variant in members:
			if not member_value is Dictionary:
				return false
			var member: Dictionary = member_value
			if String(member.get("memberId", "")).is_empty() \
					or String(member.get("meshContentDigest", "")).length() != 64 \
					or not member.get("transform") is Transform3D \
					or not member.get("localBounds") is AABB \
					or String(member.get("materialKey", "")).is_empty() \
					or String(member.get("renderLayer", "")).is_empty():
				return false
		return (render_status == "ready" and not members.is_empty() \
			or render_status == "pending" and not String(candidate.get("pendingReason", "")).is_empty()) \
			and String(provenance.get("sourceRevision", "")) == source_revision \
			and provenance.get("chunk", null) == chunk_key \
			and int(provenance.get("terrainRevision", -1)) == terrain_revision \
			and bool(provenance.get("creatorOutputComplete", false)) \
			and (category != "underground_props" or not String(provenance.get("scanRevision", "")).is_empty())
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
	if value is Vector3i:
		return [value.x, value.y, value.z]
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
