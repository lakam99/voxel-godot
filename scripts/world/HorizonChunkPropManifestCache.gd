extends RefCounted
class_name HorizonChunkPropManifestCache

const ManifestScript := preload("res://scripts/world/ChunkPropVisualManifest.gd")
const MAX_ENTRIES := 64

## A bounded acceleration for complete surface-only roots from the seeded
## producer. The cache never decides candidates or installation; it retains a
## prior capture only while the producer's installed source data is identical.
var _entries: Dictionary = {}
var _clock := 0


func clear() -> void:
	_entries.clear()
	_clock = 0


func capture_or_refresh(main: Node, chunk: Node3D, chunk_key: Vector2i,
		seed: String, scan_revision: String, scan_complete: bool,
		cell_scale: float, chunk_size: int, surface_only: bool) -> Dictionary:
	if not scan_complete or not surface_only or not is_instance_valid(chunk) \
			or not bool(chunk.get_meta("horizon_visual_only", false)):
		return ManifestScript.capture(chunk, chunk_key, seed, scan_revision,
			scan_complete, cell_scale, surface_only)
	var validation_started := Time.get_ticks_usec()
	var witness := _producer_witness(main, chunk, chunk_key, scan_revision, chunk_size)
	var validation_usec := maxi(0, Time.get_ticks_usec() - validation_started)
	if witness.has("blocked"):
		_entries.erase(chunk_key)
		return {"status": "pending", "reason": String(witness.blocked),
			"retryable": true, "chunk": chunk_key}
	if witness.is_empty():
		_entries.erase(chunk_key)
		return ManifestScript.capture(chunk, chunk_key, seed, scan_revision,
			scan_complete, cell_scale, surface_only)
	var cached: Dictionary = _entries.get(chunk_key, {})
	if not cached.is_empty() and cached.get("witness") == witness \
			and String(cached.get("seed", "")) == seed \
			and is_equal_approx(float(cached.get("cellScale", 0.0)), cell_scale):
		var refresh_started := Time.get_ticks_usec()
		var refreshed: Dictionary = ManifestScript.refresh_cached(cached.manifest, chunk)
		var refresh_usec := maxi(0, Time.get_ticks_usec() - refresh_started)
		if bool(refreshed.get("scanComplete", false)):
			_clock += 1
			cached.lastUse = _clock
			_entries[chunk_key] = cached
			refreshed["candidateSnapshotCacheHit"] = true
			refreshed["candidateSnapshotValidationUsec"] = validation_usec
			refreshed["candidateSnapshotRefreshUsec"] = refresh_usec
			return refreshed
	_entries.erase(chunk_key)
	var capture_started := Time.get_ticks_usec()
	var captured: Dictionary = ManifestScript.capture(chunk, chunk_key, seed,
		scan_revision, scan_complete, cell_scale, surface_only)
	var capture_usec := maxi(0, Time.get_ticks_usec() - capture_started)
	if bool(captured.get("scanComplete", false)):
		_clock += 1
		_entries[chunk_key] = {"seed": seed, "cellScale": cell_scale,
			"witness": witness, "manifest": captured, "lastUse": _clock}
		_evict_oldest()
	captured["candidateSnapshotCacheHit"] = false
	captured["candidateSnapshotValidationUsec"] = validation_usec
	captured["candidateSnapshotCaptureUsec"] = capture_usec
	return captured


func _producer_witness(main: Node, chunk: Node3D,
		chunk_key: Vector2i, scan_revision: String, chunk_size: int) -> Dictionary:
	if not is_instance_valid(main) or not is_instance_valid(chunk) or chunk_size <= 0 \
			or not chunk.is_inside_tree() or chunk.is_queued_for_deletion() \
			or scan_revision.is_empty() \
			or String(chunk.get_meta("chunk_surface_candidate_source_revision", "")) != scan_revision \
			or not bool(chunk.get_meta("chunk_surface_candidate_scan_complete", false)):
		return {}
	var world := main.get("world_generation_system") as Object
	if not is_instance_valid(world) or not world.has_method("terrain_volume_chunk_revision"):
		return {}
	var terrain_revision := int(world.call("terrain_volume_chunk_revision",
		chunk_key, chunk_size))
	if int(chunk.get_meta("horizon_chunk_revision", -1)) != terrain_revision:
		return {"blocked": "horizon_terrain_source_revision_changed"}
	var removed: Variant = main.get("removed_props")
	if not removed is Dictionary:
		return {}
	var children: Array = []
	for child_value in chunk.get_children():
		var child := child_value as Node3D
		if not is_instance_valid(child) or child.is_queued_for_deletion(): return {}
		if child.has_meta("prop_id"):
			var prop_id := String(child.get_meta("prop_id", ""))
			if prop_id.is_empty(): return {}
			if removed.has(prop_id):
				return {"blocked": "horizon_removed_candidate_pending"}
			var wildlife := child.has_meta("wildlife_variant")
			var spawn_position: Variant = child.get_meta("wildlife_home", Vector3.INF) \
				if wildlife else child.global_transform
			if wildlife and (not spawn_position is Vector3 \
					or not (spawn_position as Vector3).is_finite()):
				return {"blocked": "wildlife_seeded_home_missing"}
			children.append([child.get_instance_id(), prop_id,
				child.has_meta("tree_visual_state"), wildlife,
				String(child.get_meta("tree_recipe_signature", "")),
				String(child.get_meta("material", "")),
				String(child.get_meta("ore_type", "")),
				String(child.get_meta("wildlife_variant", "")), spawn_position])
		elif String(child.get_meta("kind", "")) == "decor":
			var batches: Array = []
			for batch_value in child.get_children():
				var batch := batch_value as MultiMeshInstance3D
				if not is_instance_valid(batch) or batch.is_queued_for_deletion() \
						or batch.multimesh == null or batch.multimesh.mesh == null:
					return {}
				var multimesh := batch.multimesh
				var publisher := batch.get_meta("visual_detail_receipt_publisher", null) as Object
				if not is_instance_valid(publisher) \
						or not publisher.has_method("candidate_snapshot"):
					return {"blocked": "detail_batch_publisher_missing"}
				var publisher_instances: Array = publisher.call("candidate_snapshot")
				if publisher_instances.size() != multimesh.instance_count:
					return {"blocked": "detail_batch_instance_data_changed"}
				var instances: Array = []
				for index in multimesh.instance_count:
					var transform := multimesh.get_instance_transform(index)
					var color := multimesh.get_instance_color(index) \
						if multimesh.use_colors else Color.WHITE
					var custom := multimesh.get_instance_custom_data(index) \
						if multimesh.use_custom_data else Color.WHITE
					if not publisher_instances[index] is Dictionary:
						return {"blocked": "detail_batch_instance_data_changed"}
					var published: Dictionary = publisher_instances[index]
					if int(published.get("instanceIndex", -1)) != index \
							or published.get("instanceTransform") != transform \
							or published.get("instanceColor") != color \
							or published.get("instanceCustomData") != custom:
						return {"blocked": "detail_batch_instance_data_changed"}
					instances.append([transform, color, custom])
				batches.append([batch.get_instance_id(), batch.global_transform,
					String(batch.get_meta("detail_type", "")),
					batch.visibility_range_end, multimesh.get_instance_id(),
					multimesh.mesh.get_instance_id(), multimesh.instance_count,
					multimesh.use_colors, multimesh.use_custom_data, instances])
			children.append([child.get_instance_id(), "decor", batches])
		else:
			# The production surface prop root contains only direct prop bodies and
			# its decorative batch root. Unknown children require a full capture.
			return {}
	return {"rootInstanceId": chunk.get_instance_id(),
		"rootTransform": chunk.global_transform,
		"scanRevision": scan_revision,
		"terrainChunkRevision": terrain_revision,
		"removedPropsRevision": int(main.get("removed_props_revision")),
		"detailDensity": (main.get("visual_quality") as Dictionary).get("decorativeDensity", 0.74),
		"detailCap": (main.get("visual_quality") as Dictionary).get("decorativeDetailCap", 72),
		"expectedDetailBatches": chunk.get_meta("visual_detail_expected_batches", []).duplicate(true),
		"children": children}


func _evict_oldest() -> void:
	while _entries.size() > MAX_ENTRIES:
		var oldest_key: Variant = null
		var oldest_use := 9223372036854775807
		for key in _entries:
			var use := int((_entries[key] as Dictionary).get("lastUse", 0))
			if use < oldest_use:
				oldest_use = use
				oldest_key = key
		_entries.erase(oldest_key)
