extends RefCounted
class_name PhysicalChunkPropManifestCache

const ManifestScript := preload("res://scripts/world/ChunkPropVisualManifest.gd")
const MAX_ENTRIES := 64

## Keeps completed producer captures across moving view revisions. A hit only
## saves candidate enumeration: the caller submits to the new ledger and every
## receipt is checked against the live installation again.
var _entries: Dictionary = {}
var _clock := 0
var _hits := 0
var _misses := 0
var _invalidations := 0


func clear() -> void:
	_entries.clear()
	_clock = 0
	_hits = 0
	_misses = 0
	_invalidations = 0


func diagnostics() -> Dictionary:
	return {"entries": _entries.size(), "hits": _hits,
		"misses": _misses, "invalidations": _invalidations}


func recall(main: Object, chunk: Node3D, chunk_key: Vector2i,
		seed: String, scan_revision: String, surface_only: bool,
		cell_scale: float) -> Dictionary:
	var cache_key := "%d,%d:%d" % [chunk_key.x, chunk_key.y, int(surface_only)]
	var entry: Dictionary = _entries.get(cache_key, {})
	if entry.is_empty():
		_misses += 1
		return {}
	var witness := _witness(main, chunk, chunk_key, scan_revision, surface_only)
	if witness.is_empty() or witness != entry.get("witness") \
			or String(entry.get("seed", "")) != seed \
			or not is_equal_approx(float(entry.get("cellScale", 0.0)), cell_scale):
		_entries.erase(cache_key)
		_invalidations += 1
		return {}
	var refreshed: Dictionary = ManifestScript.refresh_cached(entry.manifest, chunk)
	if not bool(refreshed.get("scanComplete", false)):
		_entries.erase(cache_key)
		_invalidations += 1
		return {}
	_clock += 1
	entry.lastUse = _clock
	_entries[cache_key] = entry
	_hits += 1
	refreshed["candidateSnapshotCacheHit"] = true
	return refreshed


func remember(main: Object, chunk: Node3D, chunk_key: Vector2i,
		seed: String, scan_revision: String, surface_only: bool,
		cell_scale: float, manifest: Dictionary) -> void:
	if not bool(manifest.get("scanComplete", false)): return
	var witness := _witness(main, chunk, chunk_key, scan_revision, surface_only)
	if witness.is_empty(): return
	_clock += 1
	_entries["%d,%d:%d" % [chunk_key.x, chunk_key.y, int(surface_only)]] = {"witness": witness,
		"seed": seed, "cellScale": cell_scale,
		"manifest": manifest, "lastUse": _clock}
	while _entries.size() > MAX_ENTRIES:
		var oldest_key: Variant = null
		var oldest_clock := 9223372036854775807
		for key in _entries:
			var last_use := int((_entries[key] as Dictionary).get("lastUse", 0))
			if last_use < oldest_clock:
				oldest_clock = last_use
				oldest_key = key
		_entries.erase(oldest_key)


func _witness(main: Object, chunk: Node3D, chunk_key: Vector2i,
		scan_revision: String, surface_only: bool) -> Dictionary:
	if not is_instance_valid(main) or not is_instance_valid(chunk) \
			or not chunk.is_inside_tree() or chunk.is_queued_for_deletion() \
			or scan_revision.is_empty() or not main.get("chunks") is Dictionary \
			or (main.get("chunks") as Dictionary).get(chunk_key) != chunk:
		return {}
	var complete_key := "chunk_surface_candidate_scan_complete" if surface_only \
		else "chunk_prop_candidate_scan_complete"
	var revision_key := "chunk_surface_candidate_source_revision" if surface_only \
		else "chunk_prop_candidate_source_revision"
	if not bool(chunk.get_meta(complete_key, false)) \
			or String(chunk.get_meta(revision_key, "")) != scan_revision:
		return {}
	var children: Array = []
	for child_value in chunk.get_children():
		if not _append_witness(child_value as Node, children): return {}
	return {"chunkInstanceId": chunk.get_instance_id(),
		"chunkTransform": chunk.global_transform,
		"scanRevision": scan_revision,
		"removedPropsRevision": int(main.get("removed_props_revision")),
		"expectedDetailBatches": chunk.get_meta(
			"visual_detail_expected_batches", []).duplicate(true),
		"children": children}


func _append_witness(node: Node, rows: Array) -> bool:
	if not is_instance_valid(node) or node.is_queued_for_deletion(): return false
	var row: Array = [node.get_instance_id()]
	if node.has_meta("detail_type"):
		var batch := node as MultiMeshInstance3D
		if batch == null or batch.multimesh == null or batch.multimesh.mesh == null:
			return false
		var publisher := batch.get_meta("visual_detail_receipt_publisher", null) as Object
		if not is_instance_valid(publisher) or not publisher.has_method("source_identity") \
				or not publisher.has_method("candidate_count"):
			return false
		var instances: Array = []
		for index in batch.multimesh.instance_count:
			instances.append([batch.multimesh.get_instance_transform(index),
				batch.multimesh.get_instance_color(index) if batch.multimesh.use_colors \
					else Color.WHITE,
				batch.multimesh.get_instance_custom_data(index) \
					if batch.multimesh.use_custom_data else Color.WHITE])
		row.append(["detail", String(batch.get_meta("detail_type", "")),
			publisher.get_instance_id(), publisher.call("source_identity"),
			publisher.call("candidate_count"), batch.multimesh.get_instance_id(),
			batch.multimesh.mesh.get_instance_id(), batch.multimesh.instance_count,
			batch.multimesh.use_colors, batch.multimesh.use_custom_data,
			batch.global_transform, batch.visibility_range_end, instances])
		rows.append(row)
		return true
	if node.has_meta("prop_id"):
		var body := node as Node3D
		if body == null: return false
		row.append(["prop", String(node.get_meta("prop_id", "")),
			String(node.get_meta("kind", "")),
			node.get_meta("wildlife_home", body.global_position),
			body.global_transform if not node.has_meta("wildlife_variant") else null,
			node.has_meta("tree_visual_state"),
			node.is_in_group("generated_tree_trunks"),
			String(node.get_meta("tree_recipe_signature", "")),
			String(node.get_meta("material", "")),
			String(node.get_meta("ore_type", "")),
			String(node.get_meta("wildlife_variant", ""))])
	var descendants: Array = []
	for child_value in node.get_children():
		if not _append_witness(child_value as Node, descendants): return false
	row.append(descendants)
	rows.append(row)
	return true
