extends RefCounted
## Budgeted install session for one immutable opaque section candidate.
##
## This is the bridge from prepared section snapshots to the native chunk
## renderer. It owns no world authority: the caller supplies the immutable
## candidate plus material/mesh bindings, while the native backend owns staged
## and installed render roots. The previous slot remains visible until commit.

const Grid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const SnapshotBuilder = preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const SNAPSHOT_ENVELOPE_SCHEMA := "prepared-static-section-snapshot-envelope/v1"


static func slot_id(world_id: String, section_key: Vector3i) -> String:
	return "section:%s:%d,%d,%d" % [world_id.sha256_text().substr(0, 16),
		section_key.x, section_key.y, section_key.z]

var state := "idle"
var reason := ""
var units := 0
var _backend_ref: WeakRef
var _chunk_ref: WeakRef
var _backend_id := 0
var _chunk_id := 0
var _candidate: Dictionary = {}
var _batches: Array[Dictionary] = []
var _batch_index := 0
var _segment_index := 0
var _source_id := ""
var _source_revision := ""
var _generation := 0
var _owner_cell := Vector2i.ZERO


func begin(backend: Node, chunk: Node3D, candidate: Dictionary,
		material_bindings: Dictionary, mesh_bindings: Dictionary) -> Dictionary:
	if state != "idle":
		return _failed("section_install_session_already_started")
	if not is_instance_valid(backend) or not is_instance_valid(chunk) \
			or not backend.is_inside_tree() or backend.get_parent() != chunk:
		return _failed("section_install_owner_unavailable")
	if not candidate.is_read_only() or String(candidate.get("schema", "")) != SNAPSHOT_ENVELOPE_SCHEMA:
		return _failed("mutable_or_invalid_section_candidate")
	var world_id := String(candidate.get("worldId", ""))
	var section_key_value: Variant = candidate.get("sectionKey")
	var generation_value: Variant = candidate.get("generation")
	var digest := String(candidate.get("contentManifestDigest", ""))
	var snapshot_value: Variant = candidate.get("snapshot")
	if world_id.is_empty() or not section_key_value is Vector3i \
			or not generation_value is int or generation_value <= 0 or digest.is_empty() \
			or not snapshot_value is Dictionary or not snapshot_value.is_read_only():
		return _failed("incomplete_section_candidate_identity")
	var section_key: Vector3i = section_key_value
	var snapshot: Dictionary = snapshot_value
	if SnapshotBuilder._snapshot_digest(snapshot, world_id, int(generation_value), section_key) != digest:
		return _failed("section_candidate_manifest_digest_mismatch")
	var expected_owner := Grid.chunk_key_for_section(section_key)
	if snapshot.get("sectionKey") != section_key or snapshot.get("streamChunkKey") != expected_owner:
		return _failed("section_snapshot_owner_mismatch")
	var dependencies_value: Variant = snapshot.get("streamChunkDependencies")
	if not dependencies_value is Array or not dependencies_value.is_read_only() \
			or not dependencies_value.has(expected_owner):
		return _failed("section_residency_manifest_missing_owner")
	for dependency_value: Variant in dependencies_value:
		if not dependency_value is Vector2i:
			return _failed("invalid_section_residency_dependency")
		# This backend is attached to one streamed chunk. Until dependency pinning
		# is supplied by the world section owner, reject candidates spanning other
		# chunks rather than allowing unload to hide still-visible geometry.
		if Vector2i(dependency_value) != expected_owner:
			return _failed("section_residency_dependency_not_pinned")
	var batches_value: Variant = snapshot.get("batches")
	if not batches_value is Dictionary or not batches_value.is_read_only():
		return _failed("invalid_section_batch_manifest")
	var batch_keys: Array[String] = []
	for key_value: Variant in batches_value:
		if not key_value is String:
			return _failed("invalid_section_batch_key")
		batch_keys.append(String(key_value))
	batch_keys.sort()
	var expected_instances := 0
	for batch_key: String in batch_keys:
		var batch_value: Variant = batches_value[batch_key]
		if not batch_value is Dictionary or not batch_value.is_read_only():
			return _failed("mutable_or_invalid_section_batch")
		var batch: Dictionary = batch_value
		if String(batch.get("renderLayer", "")) != "opaque" \
				or String(batch.get("transparencySortPolicy", "")) != "none":
			return _failed("native_section_backend_layer_not_supported")
		var material_key := String(batch.get("materialKey", ""))
		var mesh_key := String(batch.get("meshKey", ""))
		var material: Variant = material_bindings.get(material_key)
		var mesh: Variant = mesh_bindings.get(mesh_key)
		var segments_value: Variant = batch.get("segments")
		if material_key.is_empty() or mesh_key.is_empty() \
				or not material is Material or not mesh is Mesh \
				or not segments_value is Array or not segments_value.is_read_only():
			return _failed("section_render_resource_binding_missing")
		for segment_value: Variant in segments_value:
			if not segment_value is Dictionary or not segment_value.is_read_only():
				return _failed("mutable_or_invalid_section_segment")
			var segment: Dictionary = segment_value
			var buffer_value: Variant = segment.get("buffer")
			var bounds_value: Variant = segment.get("bounds")
			var count_value: Variant = segment.get("instanceCount")
			if not buffer_value is Array or buffer_value.get_typed_builtin() != TYPE_FLOAT \
					or not buffer_value.is_read_only() or not bounds_value is AABB \
					or not count_value is int or count_value <= 0 \
					or buffer_value.size() != count_value * 16:
				return _failed("invalid_section_segment_payload")
			expected_instances += count_value
			_batches.append({"batchKey":batch_key, "batch":batch,
				"segment":segment, "mesh":mesh, "material":material})
	if expected_instances != int(snapshot.get("instanceCount", -1)) \
			or _batches.size() != int(snapshot.get("segmentCount", -1)):
		return _failed("section_candidate_content_count_mismatch")
	_candidate = candidate
	_backend_ref = weakref(backend)
	_chunk_ref = weakref(chunk)
	_backend_id = backend.get_instance_id()
	_chunk_id = chunk.get_instance_id()
	_owner_cell = expected_owner
	_generation = int(generation_value)
	_source_id = slot_id(world_id, section_key)
	_source_revision = "%s:%d" % [world_id, _generation]
	var installed: Dictionary = backend.call("installed_snapshot", _source_id)
	if installed.get("status") == "ready" and _generation <= int(installed.get("generation", 0)):
		return _failed("stale_section_slot_generation")
	var section_transform := Transform3D(Basis.IDENTITY, Grid.origin_for_key(section_key))
	var local_to_chunk: Transform3D = chunk.global_transform.affine_inverse() * section_transform
	var begun: Dictionary = backend.call("begin_packet", _source_id, _owner_cell,
		_generation, _source_revision, digest, local_to_chunk,
		_batches.size(), expected_instances)
	if begun.get("status") not in ["ready_to_append", "ready_to_commit"]:
		return _failed(String(begun.get("reason", "native_section_candidate_begin_failed")))
	state = "append" if not _batches.is_empty() else "upload"
	return {"status":"begun", "sectionKey":section_key, "generation":_generation,
		"batchCount":_batches.size(), "instanceCount":expected_instances}


func advance(max_upload_units: int = 1) -> Dictionary:
	if state in ["idle", "installed", "failed", "cancelled"]:
		return {"status":state, "reason":reason}
	if max_upload_units < 1 or max_upload_units > 64:
		return _fail("invalid_section_install_budget")
	var backend := _current_backend()
	var chunk := _current_chunk()
	if backend == null or chunk == null:
		return _fail("section_install_owner_replaced")
	if state == "append":
		if _batch_index >= _batches.size():
			state = "upload"
			return {"status":"pending", "stage":state}
		var entry: Dictionary = _batches[_batch_index]
		var segment: Dictionary = entry.segment
		var batch: Dictionary = entry.batch
		var batch_id := String(entry.get("batchKey", "")) + ":" + String(segment.get("segmentId", ""))
		var policy := {"castShadows":batch.get("castShadows", true),
			"visibilityRangeEnd":batch.get("visibilityRangeEnd", 0.0),
			"fadeMargin":batch.get("fadeMargin", 0.0)}
		var appended: Dictionary = backend.call("append_batch", _source_id,
			_generation, batch_id, entry.mesh, entry.material,
			PackedFloat32Array(segment.buffer), segment.bounds,
			String(batch.get("renderTier", "structural")),
			bool(policy.castShadows), float(policy.visibilityRangeEnd), float(policy.fadeMargin))
		if appended.get("status") == "backpressure":
			return {"status":"pending", "reason":appended.get("reason", "backpressure")}
		if appended.get("status") != "accepted":
			return _fail(String(appended.get("reason", "native_section_candidate_append_failed")))
		_batch_index += 1
		units += 1
		return {"status":"pending", "stage":"append", "completedBatches":_batch_index}
	if state == "upload":
		var advanced: Dictionary = backend.call("advance_packet", _source_id, _generation, max_upload_units)
		if advanced.get("status") == "pending":
			return {"status":"pending", "reason":advanced.get("reason", "upload_pending")}
		if advanced.get("status") == "failed":
			return _fail(String(advanced.get("reason", "native_section_candidate_upload_failed")))
		if advanced.get("status") != "ready_to_commit":
			return _fail("native_section_candidate_upload_unacknowledged")
		state = "commit"
		return {"status":"pending", "stage":state}
	if state == "commit":
		var committed: Dictionary = backend.call("commit_packet", _source_id, _generation)
		if committed.get("status") == "backpressure":
			return {"status":"pending", "reason":committed.get("reason", "commit_backpressure")}
		if committed.get("status") != "ready" \
				or not backend.call("receipt_installed", _source_id, _generation,
					_source_revision, String(_candidate.contentManifestDigest)):
			return _fail(String(committed.get("reason", "native_section_candidate_receipt_rejected")))
		state = "installed"
		return {"status":"installed", "receipt":_receipt(backend, chunk)}
	return _fail("invalid_section_install_state")


func cancel() -> Dictionary:
	var backend := _current_backend()
	if backend != null and _generation > 0 and not _source_id.is_empty():
		backend.call("abort_packet", _source_id, _generation)
	state = "cancelled"
	return {"status":"cancelled", "sectionKey":_candidate.get("sectionKey")}


func _receipt(backend: Node, chunk: Node3D) -> Dictionary:
	var receipt := {"status":"installed", "worldId":String(_candidate.worldId),
		"sectionKey":_candidate.sectionKey, "generation":_generation,
		"contentManifestDigest":String(_candidate.contentManifestDigest),
		"ownerCell":_owner_cell, "backendInstanceId":backend.get_instance_id(),
		"chunkInstanceId":chunk.get_instance_id(),
		"residencyDependencies":_candidate.snapshot.streamChunkDependencies.duplicate()}
	receipt.make_read_only()
	return receipt


func _current_backend() -> Node:
	if _backend_ref == null:
		return null
	var backend: Node = _backend_ref.get_ref() as Node
	if not is_instance_valid(backend) or backend.get_instance_id() != _backend_id \
			or not backend.is_inside_tree():
		return null
	return backend


func _current_chunk() -> Node3D:
	if _chunk_ref == null:
		return null
	var chunk: Node3D = _chunk_ref.get_ref() as Node3D
	if not is_instance_valid(chunk) or chunk.get_instance_id() != _chunk_id \
			or not chunk.is_inside_tree() or chunk.get_name() != "Chunk_%d_%d" % [_owner_cell.x, _owner_cell.y] \
			or _current_backend() == null or _current_backend().get_parent() != chunk:
		return null
	return chunk


func _fail(value: String) -> Dictionary:
	reason = value
	var backend := _current_backend()
	if backend != null and _generation > 0 and not _source_id.is_empty():
		backend.call("abort_packet", _source_id, _generation)
	state = "failed"
	return {"status":"failed", "reason":reason}


func _failed(value: String) -> Dictionary:
	reason = value
	state = "failed"
	return {"status":"failed", "reason":reason}
