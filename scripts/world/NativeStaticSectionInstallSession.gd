extends RefCounted
## Budgeted install session for one immutable layered section candidate.
##
## This is the bridge from prepared section snapshots to the native chunk
## renderer. It owns no world authority: the caller supplies the immutable
## candidate plus material/mesh bindings, while the native backend owns staged
## and installed render roots. The previous slot remains visible until commit.

const Grid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const SnapshotBuilder = preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const MeshFingerprint = preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Attributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SNAPSHOT_ENVELOPE_SCHEMA := "prepared-static-section-snapshot-envelope/v1"


static func slot_id(world_id: String, section_key: Vector3i) -> String:
	return "section:%s:%d,%d,%d" % [world_id.sha256_text().substr(0, 16),
		section_key.x, section_key.y, section_key.z]


static func resolve_current_world_callback_coordinator() -> Object:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return null
	for property: Dictionary in tree.current_scene.get_property_list():
		if String(property.get("name", "")) != "world_static_section_coordinator":
			continue
		var coordinator: Variant = tree.current_scene.get("world_static_section_coordinator")
		if coordinator is Object and is_instance_valid(coordinator) \
				and coordinator.has_method("register_pending_frame_presentation") \
				and coordinator.has_method("cancel_pending_frame_presentation"):
			return coordinator
	return null

var state := "idle"
var reason := ""
var units := 0
var _backend_ref: WeakRef
var _chunk_ref: WeakRef
var _backend_id := 0
var _chunk_id := 0
var _candidate: Dictionary = {}
var _batches: Array[Dictionary] = []
var _layer_manifest: Array[Dictionary] = []
var _batch_index := 0
var _segment_index := 0
var _source_id := ""
var _source_revision := ""
var _generation := 0
var _translucent_pov_revision := -1
var _owner_cell := Vector2i.ZERO
var _production_metadata: Dictionary = {}
var _presentation_token := ""
var _presentation_root_id := 0
var _previous_root_id := 0
var _previous_generation := 0
var _frame_callback_requested := false
var _frame_drawn := false
var _frame_callback_coordinator_ref: WeakRef


func begin(backend: Node, chunk: Node3D, candidate: Dictionary,
		material_bindings: Dictionary, mesh_bindings: Dictionary,
		frame_callback_coordinator: Object = null) -> Dictionary:
	if state != "idle":
		return _failed("section_install_session_already_started")
	_batches.clear()
	_layer_manifest.clear()
	if not is_instance_valid(backend) or not is_instance_valid(chunk) \
			or not backend.is_inside_tree() or backend.get_parent() != chunk:
		return _failed("section_install_owner_unavailable")
	var callback_coordinator: Object = frame_callback_coordinator
	if callback_coordinator == null:
		callback_coordinator = resolve_current_world_callback_coordinator()
	if callback_coordinator != null:
		if not is_instance_valid(callback_coordinator) \
				or not callback_coordinator.has_method("register_pending_frame_presentation") \
				or not callback_coordinator.has_method("cancel_pending_frame_presentation"):
			return _failed("section_frame_callback_coordinator_unavailable")
		_frame_callback_coordinator_ref = weakref(callback_coordinator)
	if not candidate.is_read_only():
		return _failed("mutable_or_invalid_section_candidate")
	var submitted_candidate := candidate
	_production_metadata = {}
	if String(submitted_candidate.get("schema", "")) == "world-static-section-production-candidate/v1":
		var envelope_value: Variant = submitted_candidate.get("candidate", null)
		if not envelope_value is Dictionary or not envelope_value.is_read_only() \
				or String(envelope_value.get("schema", "")) != SNAPSHOT_ENVELOPE_SCHEMA \
				or submitted_candidate.get("sectionKey") != envelope_value.get("sectionKey") \
				or submitted_candidate.get("worldId") != envelope_value.get("worldId") \
				or submitted_candidate.get("generation") != envelope_value.get("generation") \
				or submitted_candidate.get("contentManifestDigest") != envelope_value.get("contentManifestDigest") \
				or String(submitted_candidate.get("censusDigest", "")).is_empty():
			return _failed("inconsistent_production_section_candidate_envelope")
		_production_metadata = {
			"censusDigest":String(submitted_candidate.get("censusDigest", "")),
			"sourceRevisions":submitted_candidate.get("sourceRevisions", {}),
			"removalRevisions":submitted_candidate.get("removalRevisions", {}),
			"providerCoverage":submitted_candidate.get("providerCoverage", [])}
		candidate = envelope_value
	if String(candidate.get("schema", "")) != SNAPSHOT_ENVELOPE_SCHEMA:
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
	if String(snapshot.get("instanceAttributeLayout", "")) != Attributes.LAYOUT_SCHEMA:
		return _failed("section_snapshot_instance_attribute_layout_mismatch")
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
	# These are capture/source coverage keys, not installed-owner leases. The
	# section root is independently owned and the immutable candidate plus its
	# exact contributor revisions survive source gameplay-chunk retirement.
	var batches_value: Variant = snapshot.get("batches")
	if not batches_value is Dictionary or not batches_value.is_read_only():
		return _failed("invalid_section_batch_manifest")
	var render_layers_value: Variant = snapshot.get("renderLayers")
	if not render_layers_value is Array or not render_layers_value.is_read_only():
		return _failed("section_render_layer_manifest_missing")
	var layer_counts := {
		"opaque":{"batchCount":0, "instanceCount":0},
		"cutout":{"batchCount":0, "instanceCount":0},
		"translucent":{"batchCount":0, "instanceCount":0}}
	var batch_keys: Array[String] = []
	for key_value: Variant in batches_value:
		if not key_value is String:
			return _failed("invalid_section_batch_key")
		batch_keys.append(String(key_value))
	batch_keys.sort()
	var expected_instances := 0
	_translucent_pov_revision = -1
	for batch_key: String in batch_keys:
		var batch_value: Variant = batches_value[batch_key]
		if not batch_value is Dictionary or not batch_value.is_read_only():
			return _failed("mutable_or_invalid_section_batch")
		var batch: Dictionary = batch_value
		if String(batch.get("instanceAttributeLayout", "")) != Attributes.LAYOUT_SCHEMA:
			return _failed("section_batch_instance_attribute_layout_mismatch")
		var render_layer := String(batch.get("renderLayer", ""))
		var sort_policy := String(batch.get("transparencySortPolicy", ""))
		var segments_value: Variant = batch.get("segments")
		if not layer_counts.has(render_layer):
			return _failed("native_section_backend_layer_not_supported")
		if render_layer in ["opaque", "cutout"] and sort_policy != "none":
			return _failed("section_order_independent_layer_has_sort_policy")
		if render_layer == "translucent":
			if sort_policy != "camera_depth":
				return _failed("section_translucent_sort_policy_unsupported")
			var descriptor_check := _validate_translucent_sort_descriptor(batch,
				mesh_bindings.get(String(batch.get("meshKey", ""))), section_key,
				int(generation_value))
			if descriptor_check.get("status") != "ready":
				return _failed(String(descriptor_check.get("reason", "invalid_translucent_sort_descriptor")))
			var descriptor: Dictionary = batch.get("translucentSortDescriptor", {})
			var descriptor_pov_revision := int(descriptor.get("povRevision", -1))
			if _translucent_pov_revision not in [-1, descriptor_pov_revision]:
				return _failed("section_translucent_pov_revision_mismatch")
			_translucent_pov_revision = descriptor_pov_revision
			var translucent_instances := 0
			for segment_value: Variant in segments_value:
				if segment_value is Dictionary:
					translucent_instances += int((segment_value as Dictionary).get("instanceCount", 0))
			if translucent_instances != 1:
				return _failed("section_translucent_batch_requires_one_baked_instance")
		var material_key := String(batch.get("materialKey", ""))
		var mesh_key := String(batch.get("meshKey", ""))
		var material: Variant = material_bindings.get(material_key)
		var mesh: Variant = mesh_bindings.get(mesh_key)
		var mesh_digest := String(batch.get("meshContentDigest", ""))
		if material_key.is_empty() or mesh_key.is_empty() \
				or not material is Material or not mesh is Mesh \
				or not segments_value is Array or not segments_value.is_read_only():
			return _failed("section_render_resource_binding_missing")
		var mesh_identity: Dictionary = MeshFingerprint.inspect(mesh)
		if mesh_identity.get("status") != "ready" \
				or String(mesh_identity.get("contentDigest", "")) != mesh_digest:
			return _failed("section_mesh_binding_content_digest_mismatch")
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
					or buffer_value.size() != count_value * Attributes.FLOATS_PER_INSTANCE:
				return _failed("invalid_section_segment_payload")
			expected_instances += count_value
			var counts: Dictionary = layer_counts[render_layer]
			counts.batchCount = int(counts.batchCount) + 1
			counts.instanceCount = int(counts.instanceCount) + count_value
			_batches.append({"batchKey":batch_key, "batch":batch,
				"segment":segment, "mesh":mesh, "material":material})
	var seen_layers: Dictionary = {}
	if render_layers_value.size() != layer_counts.size():
		return _failed("section_render_layer_manifest_count_mismatch")
	for layer_value: Variant in render_layers_value:
		if not layer_value is Dictionary or not layer_value.is_read_only():
			return _failed("mutable_or_invalid_section_render_layer_manifest")
		var layer: Dictionary = layer_value
		var layer_name := String(layer.get("layer", ""))
		if not layer_counts.has(layer_name) or seen_layers.has(layer_name):
			return _failed("invalid_or_duplicate_section_render_layer")
		seen_layers[layer_name] = true
		var counts: Dictionary = layer_counts[layer_name]
		if int(layer.get("expectedBatchCount", -1)) != int(counts.batchCount) \
				or int(layer.get("expectedInstanceCount", -1)) != int(counts.instanceCount):
			return _failed("section_render_layer_manifest_count_mismatch")
		_layer_manifest.append({"layer":layer_name,
			"expectedBatchCount":int(counts.batchCount),
			"expectedInstanceCount":int(counts.instanceCount)})
	_layer_manifest.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("layer", "")) < String(b.get("layer", "")))
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
	if _translucent_pov_revision > 0:
		_source_revision += ":pov:%d" % _translucent_pov_revision
	var installed: Dictionary = backend.call("installed_snapshot", _source_id)
	if installed.get("status") == "ready" and _generation <= int(installed.get("generation", 0)):
		return _failed("stale_section_slot_generation")
	var section_transform := Transform3D(Basis.IDENTITY, Grid.origin_for_key(section_key))
	var local_to_chunk: Transform3D = chunk.global_transform.affine_inverse() * section_transform
	var begun: Dictionary = backend.call("begin_packet_with_layers", _source_id, _owner_cell,
		_generation, _source_revision, digest, local_to_chunk,
		_batches.size(), expected_instances, _layer_manifest)
	if begun.get("status") not in ["ready_to_append", "ready_to_commit"]:
		return _failed(String(begun.get("reason", "native_section_candidate_begin_failed")))
	state = "append" if not _batches.is_empty() else "upload"
	return {"status":"begun", "sectionKey":section_key, "generation":_generation,
		"batchCount":_batches.size(), "instanceCount":expected_instances}


func advance(max_upload_units: int = 1, current_translucent_pov_revision: int = -1) -> Dictionary:
	if state in ["idle", "installed", "failed", "cancelled"]:
		return {"status":state, "reason":reason}
	if state == "awaiting_frame":
		if _current_backend() == null or _current_chunk() == null:
			var rollback := rollback_presentation()
			if rollback.get("status") != "cancelled":
				return _rollback_failed_step("section_install_owner_replaced", rollback)
			return {"status":"failed", "reason":"section_install_owner_replaced",
				"rollback":rollback}
		if _translucent_pov_revision > 0 \
				and current_translucent_pov_revision != _translucent_pov_revision:
			var pov_rollback := rollback_presentation()
			if pov_rollback.get("status") != "cancelled":
				return _rollback_failed_step("section_translucent_pov_revision_stale", pov_rollback)
			return {"status":"failed", "reason":"section_translucent_pov_revision_stale",
				"rollback":pov_rollback}
		return {"status":"pending_presentation", "stage":state,
			"presentationToken":_presentation_token, "sectionKey":_candidate.get("sectionKey"),
			"generation":_generation, "frameDrawn":_frame_drawn}
	if max_upload_units < 1 or max_upload_units > 64:
		return _fail("invalid_section_install_budget")
	if _translucent_pov_revision > 0 \
			and current_translucent_pov_revision != _translucent_pov_revision:
		return _fail("section_translucent_pov_revision_stale")
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
		var mesh_content_digest := String(batch.get("meshContentDigest", ""))
		var policy := {"castShadows":batch.get("castShadows", true),
			"visibilityRangeEnd":batch.get("visibilityRangeEnd", 0.0),
			"fadeMargin":batch.get("fadeMargin", 0.0)}
		var appended: Dictionary = backend.call("append_batch_in_layer", _source_id,
			_generation, batch_id, entry.mesh, mesh_content_digest, entry.material,
			PackedFloat32Array(segment.buffer), segment.bounds,
			String(batch.get("renderTier", "structural")),
			bool(policy.castShadows), float(policy.visibilityRangeEnd), float(policy.fadeMargin),
			String(batch.get("renderLayer", "")))
		if appended.get("status") == "backpressure":
			return {"status":"pending", "reason":appended.get("reason", "backpressure")}
		if appended.get("status") != "accepted":
			var failure := _fail(String(appended.get("reason", "native_section_candidate_append_failed")))
			var bounds: AABB = segment.bounds
			var append_buffer := PackedFloat32Array(segment.buffer)
			var mesh := entry.mesh as Mesh
			failure["nativeAppend"] = {"sourceId":_source_id,
				"batchId":batch_id, "batchKey":String(entry.get("batchKey", "")),
				"segmentId":String(segment.get("segmentId", "")),
				"meshClass":mesh.get_class() if is_instance_valid(mesh) else "null",
				"meshSurfaceCount":mesh.get_surface_count() if is_instance_valid(mesh) else -1,
				"materialClass":entry.material.get_class() if is_instance_valid(entry.material) else "null",
				"meshContentDigestLength":mesh_content_digest.length(),
				"bufferFloatCount":append_buffer.size(),
				"floatsPerInstance":Attributes.FLOATS_PER_INSTANCE,
				"renderLayer":String(batch.get("renderLayer", "")),
				"renderTier":String(batch.get("renderTier", "structural")),
				"visibilityRangeEnd":float(policy.visibilityRangeEnd),
				"fadeMargin":float(policy.fadeMargin),
				"boundsPosition":[bounds.position.x, bounds.position.y, bounds.position.z],
				"boundsSize":[bounds.size.x, bounds.size.y, bounds.size.z]}
			return failure
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
		var committed: Dictionary = backend.call("commit_packet", _source_id, _generation, true)
		if committed.get("status") == "backpressure":
			return {"status":"pending", "reason":committed.get("reason", "commit_backpressure")}
		if committed.get("status") != "pending_presentation" \
				or String(committed.get("token", "")).is_empty() \
				or int(committed.get("generation", 0)) != _generation \
				or String(committed.get("sourceRevision", "")) != _source_revision \
				or String(committed.get("packetDigest", "")) \
					!= String(_candidate.contentManifestDigest):
			return _fail(String(committed.get("reason", "native_section_candidate_receipt_rejected")))
		_presentation_token = String(committed.get("token", ""))
		_presentation_root_id = int(committed.get("rootInstanceId", 0))
		_previous_root_id = int(committed.get("previousRootInstanceId", 0))
		_previous_generation = int(committed.get("previousGeneration", 0))
		state = "awaiting_frame"
		var callback_request: Dictionary = _request_frame_drawn_callback()
		if callback_request.get("status") != "queued":
			var callback_rollback := rollback_presentation(_presentation_token)
			if callback_rollback.get("status") != "cancelled":
				return _rollback_failed_step("section_frame_callback_registration_failed",
					callback_rollback)
			return _fail(String(callback_request.get("reason",
				"section_frame_callback_registration_failed")))
		return {"status":"pending_presentation", "stage":state,
			"presentationToken":_presentation_token,
			"presentationRootInstanceId":_presentation_root_id,
			"previousRootInstanceId":_previous_root_id,
			"previousGeneration":_previous_generation,
			"frameDrawn":_frame_drawn,
			"receipt":_pending_receipt(backend, chunk)}
	return _fail("invalid_section_install_state")


func finalize_presentation(token: String) -> Dictionary:
	if state != "awaiting_frame" or token.is_empty() or token != _presentation_token:
		return _failed("section_presentation_token_mismatch")
	if not _frame_drawn:
		return {"status":"pending_presentation", "reason":"section_frame_not_drawn",
			"presentationToken":_presentation_token}
	var backend := _current_backend()
	var chunk := _current_chunk()
	if backend == null or chunk == null:
		return _rollback_then_fail(token, "section_install_owner_replaced")
	var pending: Dictionary = backend.call("pending_presentation_snapshot", _source_id)
	if pending.get("status") != "pending_presentation" \
			or String(pending.get("token", "")) != token \
			or int(pending.get("generation", 0)) != _generation \
			or String(pending.get("sourceRevision", "")) != _source_revision \
			or String(pending.get("packetDigest", "")) \
				!= String(_candidate.contentManifestDigest) \
			or int(pending.get("rootInstanceId", 0)) != _presentation_root_id \
			or int(pending.get("previousRootInstanceId", 0)) != _previous_root_id \
			or int(pending.get("previousGeneration", 0)) != _previous_generation:
		return _rollback_then_fail(token, "section_pending_presentation_identity_stale")
	var finalized: Dictionary = backend.call("finalize_presentation", _source_id,
		_generation, token)
	if finalized.get("status") != "ready" \
			or not backend.call("receipt_installed", _source_id, _generation,
				_source_revision, String(_candidate.contentManifestDigest)):
			return _rollback_then_fail(token,
			String(finalized.get("reason", "section_presentation_finalize_failed")))
	state = "installed"
	var coordinator: Object = _frame_callback_coordinator_ref.get_ref() \
		if _frame_callback_coordinator_ref != null else null
	var callback_completion: Dictionary = {"status":"already_drained"}
	if coordinator != null and is_instance_valid(coordinator) \
			and coordinator.has_method("complete_pending_frame_presentation"):
		callback_completion = coordinator.call("complete_pending_frame_presentation", self, token)
	return {"status":"installed", "receipt":_receipt(backend, chunk),
		"frameAckToken":token, "callbackCompletion":callback_completion}


func _request_frame_drawn_callback() -> Dictionary:
	if state != "awaiting_frame" or _frame_callback_requested or _presentation_token.is_empty():
		return {"status":"failed", "reason":"invalid_section_frame_callback_state"}
	var coordinator: Object = _frame_callback_coordinator_ref.get_ref() \
		if _frame_callback_coordinator_ref != null else null
	if coordinator == null or not is_instance_valid(coordinator):
		return {"status":"failed", "reason":"section_frame_callback_coordinator_unavailable"}
	var registered: Dictionary = coordinator.call("register_pending_frame_presentation", self,
		_presentation_token)
	if registered.get("status") != "queued":
		return registered
	_frame_callback_requested = true
	return registered


func accept_frame_drawn_callback(token: String) -> bool:
	if state == "awaiting_frame" and token == _presentation_token:
		_frame_drawn = true
		return true
	return false


func _tombstone_frame_drawn_callback() -> void:
	if not _frame_callback_requested or _presentation_token.is_empty():
		return
	var coordinator: Object = _frame_callback_coordinator_ref.get_ref() \
		if _frame_callback_coordinator_ref != null else null
	if coordinator == null or not is_instance_valid(coordinator):
		return
	coordinator.call("cancel_pending_frame_presentation", self, _presentation_token)


func _rollback_then_fail(token: String, failure_reason: String) -> Dictionary:
	var rolled_back := rollback_presentation(token)
	if rolled_back.get("status") != "cancelled":
		return _rollback_failed_step(failure_reason, rolled_back)
	return _failed(failure_reason)


func _rollback_failed_step(failure_reason: String, rollback: Dictionary) -> Dictionary:
	return {"status":"rollback_failed", "reason":"section_presentation_rollback_failed",
		"failureReason":failure_reason, "rollback":rollback,
		"presentationToken":_presentation_token, "generation":_generation,
		"retryable":true}


func rollback_presentation(token := "") -> Dictionary:
	if state != "awaiting_frame":
		return {"status":"not_pending"}
	var expected := _presentation_token if token.is_empty() else token
	if expected != _presentation_token:
		return {"status":"rollback_failed", "reason":"section_presentation_token_mismatch",
			"presentationToken":_presentation_token, "retryable":true}
	var backend := _bound_backend_for_rollback()
	if backend == null:
		return {"status":"rollback_failed", "reason":"section_install_rollback_backend_unavailable",
			"presentationToken":_presentation_token, "retryable":true}
	var rolled_back: Dictionary = backend.call("rollback_presentation", _source_id,
		_generation, _presentation_token)
	if rolled_back.get("status") != "rolled_back":
		return {"status":"rollback_failed", "reason":String(rolled_back.get("reason",
			"section_presentation_rollback_failed")), "presentationToken":_presentation_token,
			"nativeRollback":rolled_back, "retryable":true}
	state = "cancelled"
	_tombstone_frame_drawn_callback()
	return {"status":"cancelled", "sectionKey":_candidate.get("sectionKey"),
		"generation":_generation, "rollback":rolled_back}


func _bound_backend_for_rollback() -> Node:
	if _backend_ref == null:
		return null
	var backend: Node = _backend_ref.get_ref() as Node
	if not is_instance_valid(backend) or backend.get_instance_id() != _backend_id \
			or not backend.has_method("rollback_presentation"):
		return null
	return backend


func cancel() -> Dictionary:
	if state == "awaiting_frame":
		return rollback_presentation()
	var backend := _current_backend()
	if backend != null and _generation > 0 and not _source_id.is_empty():
		backend.call("abort_packet", _source_id, _generation)
	state = "cancelled"
	return {"status":"cancelled", "sectionKey":_candidate.get("sectionKey")}


func _pending_receipt(backend: Node, chunk: Node3D) -> Dictionary:
	var receipt := {"status":"pending_presentation", "worldId":String(_candidate.worldId),
		"sectionKey":_candidate.sectionKey, "generation":_generation,
		"contentManifestDigest":String(_candidate.contentManifestDigest),
		"sourceRevision":_source_revision, "ownerCell":_owner_cell,
		"backendInstanceId":backend.get_instance_id(),
		"chunkInstanceId":chunk.get_instance_id(),
		"presentationToken":_presentation_token,
		"presentationRootInstanceId":_presentation_root_id,
		"previousRootInstanceId":_previous_root_id,
		"previousGeneration":_previous_generation}
	if not _production_metadata.is_empty():
		receipt["candidateSchema"] = "world-static-section-production-candidate/v1"
		receipt["censusDigest"] = String(_production_metadata.get("censusDigest", ""))
		receipt["sourceRevisions"] = _production_metadata.get("sourceRevisions", {})
		receipt["removalRevisions"] = _production_metadata.get("removalRevisions", {})
		receipt["providerCoverage"] = _production_metadata.get("providerCoverage", [])
	receipt.make_read_only()
	return receipt


func _receipt(backend: Node, chunk: Node3D) -> Dictionary:
	var receipt := {"status":"installed", "worldId":String(_candidate.worldId),
		"sectionKey":_candidate.sectionKey, "generation":_generation,
		"contentManifestDigest":String(_candidate.contentManifestDigest),
		"sourceRevision":_source_revision,
		"ownerCell":_owner_cell, "backendInstanceId":backend.get_instance_id(),
		"chunkInstanceId":chunk.get_instance_id(),
		"sourceCaptureChunkKeys":_candidate.snapshot.streamChunkDependencies.duplicate()}
	if _translucent_pov_revision > 0:
		receipt["translucentPovRevision"] = _translucent_pov_revision
	if not _production_metadata.is_empty():
		receipt["candidateSchema"] = "world-static-section-production-candidate/v1"
		receipt["censusDigest"] = String(_production_metadata.get("censusDigest", ""))
		receipt["sourceRevisions"] = _production_metadata.get("sourceRevisions", {})
		receipt["removalRevisions"] = _production_metadata.get("removalRevisions", {})
		receipt["providerCoverage"] = _production_metadata.get("providerCoverage", [])
	receipt.make_read_only()
	return receipt


func _validate_translucent_sort_descriptor(batch: Dictionary, mesh_value: Variant,
		section_key: Vector3i, generation: int) -> Dictionary:
	var mesh_digest := String(batch.get("meshContentDigest", ""))
	var descriptor_value: Variant = batch.get("translucentSortDescriptor", null)
	if not descriptor_value is Dictionary or not descriptor_value.is_read_only():
		return {"status":"failed", "reason":"section_translucent_sort_descriptor_missing_or_mutable"}
	var descriptor: Dictionary = descriptor_value
	var camera_value: Variant = descriptor.get("cameraPosition")
	var pov_revision: Variant = descriptor.get("povRevision")
	var groups_by_surface: Variant = descriptor.get("surfaces")
	if String(descriptor.get("schema", "")) != "section-translucent-face-groups/v1" \
			or descriptor.get("sectionKey") != section_key \
			or int(descriptor.get("sectionGeneration", -1)) != generation \
			or not pov_revision is int or pov_revision <= 0 \
			or not camera_value is Vector3 or not camera_value.is_finite() \
			or String(descriptor.get("meshContentDigest", "")) != mesh_digest \
			or not groups_by_surface is Array or not groups_by_surface.is_read_only() \
			or not mesh_value is Mesh:
		return {"status":"failed", "reason":"section_translucent_sort_descriptor_identity_invalid"}
	var mesh := mesh_value as Mesh
	if mesh.get_surface_count() <= 0 or groups_by_surface.size() != mesh.get_surface_count():
		return {"status":"failed", "reason":"section_translucent_sort_surface_manifest_mismatch"}
	var seen_surfaces: Dictionary = {}
	for surface_value: Variant in groups_by_surface:
		if not surface_value is Dictionary or not surface_value.is_read_only():
			return {"status":"failed", "reason":"section_translucent_surface_manifest_mutable"}
		var surface_row: Dictionary = surface_value
		var surface_index_value: Variant = surface_row.get("surfaceIndex")
		var face_groups_value: Variant = surface_row.get("faceGroups")
		if not surface_index_value is int or surface_index_value < 0 \
				or surface_index_value >= mesh.get_surface_count() \
				or seen_surfaces.has(surface_index_value) \
				or not face_groups_value is Array or not face_groups_value.is_read_only() \
				or mesh.surface_get_primitive_type(surface_index_value) != Mesh.PRIMITIVE_TRIANGLES:
			return {"status":"failed", "reason":"section_translucent_surface_manifest_invalid"}
		seen_surfaces[surface_index_value] = true
		var arrays: Array = mesh.surface_get_arrays(surface_index_value)
		if arrays.size() != Mesh.ARRAY_MAX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			return {"status":"failed", "reason":"section_translucent_mesh_surface_arrays_invalid"}
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices_value: Variant = arrays[Mesh.ARRAY_INDEX]
		var indices := PackedInt32Array()
		if indices_value is PackedInt32Array:
			indices = indices_value
		elif indices_value != null:
			return {"status":"failed", "reason":"section_translucent_mesh_index_array_invalid"}
		var primitive_count := indices.size() if not indices.is_empty() else vertices.size()
		var cursor := 0
		var group_ids: Dictionary = {}
		var prior_distance := INF
		var prior_group_id := ""
		for group_value: Variant in face_groups_value:
			if not group_value is Dictionary or not group_value.is_read_only():
				return {"status":"failed", "reason":"section_translucent_face_group_mutable"}
			var group: Dictionary = group_value
			var group_id := String(group.get("groupId", ""))
			var first_index: Variant = group.get("firstIndex")
			var index_count: Variant = group.get("indexCount")
			var declared_centroid: Variant = group.get("centroid")
			if group_id.is_empty() or group_ids.has(group_id) \
					or not first_index is int or not index_count is int \
					or first_index != cursor or index_count <= 0 or index_count % 6 != 0 \
					or first_index + index_count > primitive_count \
					or not declared_centroid is Vector3 or not declared_centroid.is_finite():
				return {"status":"failed", "reason":"section_translucent_face_group_range_invalid"}
			group_ids[group_id] = true
			var unique_indices: Dictionary = {}
			for primitive_index: int in range(first_index, first_index + index_count):
				var vertex_index := int(indices[primitive_index]) if not indices.is_empty() else primitive_index
				if vertex_index < 0 or vertex_index >= vertices.size():
					return {"status":"failed", "reason":"section_translucent_mesh_index_out_of_range"}
				unique_indices[vertex_index] = true
			var actual_centroid := Vector3.ZERO
			for vertex_index_value: Variant in unique_indices:
				actual_centroid += vertices[int(vertex_index_value)]
			actual_centroid /= float(unique_indices.size())
			if actual_centroid.distance_squared_to(declared_centroid) > 0.000001:
				return {"status":"failed", "reason":"section_translucent_face_group_centroid_mismatch"}
			var distance_squared := actual_centroid.distance_squared_to(camera_value)
			if distance_squared > prior_distance + 0.000001 \
					or (is_equal_approx(distance_squared, prior_distance) \
					and not prior_group_id.is_empty() and group_id < prior_group_id):
				return {"status":"failed", "reason":"section_translucent_face_groups_not_camera_sorted"}
			prior_distance = distance_squared
			prior_group_id = group_id
			cursor += index_count
		if cursor != primitive_count or face_groups_value.is_empty():
			return {"status":"failed", "reason":"section_translucent_face_group_coverage_incomplete"}
	return {"status":"ready", "povRevision":int(pov_revision)}


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
	var scene := Engine.get_main_loop() as SceneTree
	if scene == null or scene.current_scene == null \
			or not scene.current_scene.has_method("get_static_section_render_owner"):
		return null
	var resolved: Variant = scene.current_scene.call("get_static_section_render_owner",
		_owner_cell, false)
	if not resolved is Dictionary or resolved.get("status") != "ready" \
			or not is_same(resolved.get("owner"), chunk) \
			or not is_same(resolved.get("backend"), _current_backend()):
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
