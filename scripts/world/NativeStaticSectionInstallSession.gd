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
const PresentationMembers = preload("res://scripts/world/StaticSectionPresentationMembers.gd")
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
		if is_instance_valid(coordinator) and coordinator is Object \
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
var _attachment_bindings: Dictionary = {}
var _attachment_identity: Dictionary = {}
var _presentation_attachment_roots: Array = []
# Preserve the generic Array encoding used by the sealed manifest digest.
var _presentation_manifest: Array = []
var _presentation_manifest_digest := ""
var _presentation_bindings: Dictionary = {}
var _presentation_binding_identity: Dictionary = {}
var _last_append_step_wall_usec := 0
var _max_append_step_wall_usec := 0
var _last_append_buffer_float_count := 0
var _max_append_buffer_float_count := 0
var _last_append_mesh_surface_bytes := -1
var _max_append_mesh_surface_bytes := -1
var _last_upload_call_wall_usec := 0
var _max_upload_call_wall_usec := 0
var _last_upload_cursor := -1
var _last_upload_processed_units := -1
var _last_upload_expected_batches := -1


func begin(backend: Node, chunk: Node3D, candidate: Dictionary,
		material_bindings: Dictionary, mesh_bindings: Dictionary,
		frame_callback_coordinator: Object = null, attachment_bindings: Dictionary = {}) -> Dictionary:
	if state != "idle":
		return _failed("section_install_session_already_started")
	_batches.clear()
	_layer_manifest.clear()
	_last_append_step_wall_usec = 0
	_max_append_step_wall_usec = 0
	_last_append_buffer_float_count = 0
	_max_append_buffer_float_count = 0
	_last_append_mesh_surface_bytes = -1
	_max_append_mesh_surface_bytes = -1
	_last_upload_call_wall_usec = 0
	_max_upload_call_wall_usec = 0
	_last_upload_cursor = -1
	_last_upload_processed_units = -1
	_last_upload_expected_batches = -1
	_attachment_bindings.clear()
	_attachment_identity.clear()
	_presentation_attachment_roots.clear()
	_presentation_manifest.clear()
	_presentation_manifest_digest = ""
	_presentation_bindings.clear()
	_presentation_binding_identity.clear()
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
			"providerCoverage":submitted_candidate.get("providerCoverage", []),
			"supportCoverageIdentities":submitted_candidate.get(
				"supportCoverageIdentities", [])}
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
		var attachment_key := String(batch.get("attachmentKey", ""))
		if not attachment_key.is_empty():
			var binding_value: Variant = attachment_bindings.get(attachment_key)
			if not binding_value is Dictionary or not batch.get("neutralParentToWorld") is Transform3D \
					or not batch.get("sweptWorldBounds") is AABB:
				return _failed("section_attachment_binding_missing")
			var binding: Dictionary = binding_value
			if not batch.get("producerSourceRevision") is String \
					or String(batch.producerSourceRevision).is_empty() \
					or binding.get("producerSourceRevision") != batch.producerSourceRevision:
				return _failed("section_attachment_producer_revision_mismatch")
			if binding.get("neutralParentToWorld") != batch.get("neutralParentToWorld") \
					or binding.get("motion") != batch.get("motion"):
				return _failed("section_attachment_neutral_transform_mismatch")
			if not _attachment_bindings.has(attachment_key):
				_attachment_bindings[attachment_key] = binding
				_attachment_identity[attachment_key] = {
					"parentInstanceId":binding.get("parentInstanceId"),
					"bodyInstanceId":binding.get("bodyInstanceId"),
					"sourceRevision":binding.get("sourceRevision"),
					"producerSourceRevision":binding.get("producerSourceRevision"),
					"publisherInstanceId":binding.get("publisherInstanceId"),
					"publicationEpoch":binding.get("publicationEpoch"),
					"bodyToWorld":binding.get("bodyToWorld"),
					"neutralParentToWorld":binding.get("neutralParentToWorld"), "motion":binding.get("motion"),
					"legacyVisuals":binding.get("legacyVisuals")}
		if String(batch.get("instanceAttributeLayout", "")) != Attributes.LAYOUT_SCHEMA:
			return _failed("section_batch_instance_attribute_layout_mismatch")
		var render_layer := String(batch.get("renderLayer", ""))
		var intended_visible_value: Variant = batch.get("intendedVisible", null)
		if not intended_visible_value is bool:
			return _failed("section_batch_intended_visibility_missing")
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
				"segment":segment, "mesh":mesh, "material":material,
				"meshSurfaceBytes":int(mesh_identity.get("cpuArrayBytes", -1))})
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
	var attachment_manifest_result := _build_presentation_manifest(snapshot, attachment_bindings)
	if attachment_manifest_result.get("status") != "ready":
		return _failed(String(attachment_manifest_result.get("reason",
			"section_presentation_manifest_invalid")))
	_presentation_manifest = attachment_manifest_result.members
	_presentation_manifest_digest = String(attachment_manifest_result.digest)
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
	var declared: Dictionary = backend.call("declare_attachment_manifest", _source_id,
		_generation, _presentation_manifest, _presentation_manifest_digest)
	if declared.get("status") != "manifest_declared" \
			or int(declared.get("memberCount", -1)) != _presentation_manifest.size() \
			or String(declared.get("manifestDigest", "")) != _presentation_manifest_digest:
		return _fail(String(declared.get("reason", "section_attachment_manifest_declaration_failed")))
	if not _attachments_current():
		return _fail("section_attachment_binding_stale")
	for attachment_key: String in _attachment_bindings:
		var binding: Dictionary = _attachment_bindings[attachment_key]
		var legacy_visuals: Array = []
		for reference: WeakRef in binding.get("legacyVisuals", []):
			legacy_visuals.append(reference.get_ref())
		var registered: Dictionary = backend.call("register_packet_attachment", _source_id,
			_generation, attachment_key, binding.parent.get_ref(), binding.body.get_ref(),
			binding.neutralParentToWorld, binding.motion, legacy_visuals)
		if registered.get("status") != "registered":
			return _fail(String(registered.get("reason", "section_attachment_registration_failed")))
	for attachment_key: String in _presentation_bindings:
		var binding: Dictionary = _presentation_bindings[attachment_key]
		var legacy_visuals: Array = []
		for reference: WeakRef in binding.get("legacyVisuals", []):
			legacy_visuals.append(reference.get_ref())
		var registered: Dictionary = backend.call("register_borrowed_presentation",
			_source_id, _generation, attachment_key, String(binding.sourceId),
			String(binding.sourcePartId), String(binding.presentationMemberId),
			binding.mount.get_ref(), binding.parent.get_ref(), binding.body.get_ref(),
			binding.neutralParentToWorld, binding.mountLocalTransform, binding.motion,
			bool(binding.intendedVisible), legacy_visuals)
		if registered.get("status") != "registered_borrowed":
			return _fail(String(registered.get("reason", "borrowed_presentation_registration_failed")))
	state = "append" if not _batches.is_empty() else "upload"
	return {"status":"begun", "sectionKey":section_key, "generation":_generation,
		"batchCount":_batches.size(), "instanceCount":expected_instances}


func _build_presentation_manifest(snapshot: Dictionary,
		attachment_bindings: Dictionary) -> Dictionary:
	var rows_by_key: Dictionary = {}
	var borrowed_keys: Dictionary = {}
	var borrowed_values: Variant = snapshot.get("presentationMembers", null)
	if not borrowed_values is Array or not borrowed_values.is_read_only():
		return _failed("section_presentation_member_manifest_missing")
	for value: Variant in borrowed_values:
		if not value is Dictionary or not value.is_read_only():
			return _failed("section_presentation_member_manifest_invalid")
		var member: Dictionary = value
		var key := String(member.get("attachmentKey", ""))
		if key.is_empty() or rows_by_key.has(key):
			return _failed("section_presentation_member_identity_duplicate")
		var validation := PresentationMembers.validate(member, String(member.get("sourceId", "")),
			String(member.get("sourcePartId", "")), String(member.get("sourceRevision", "")))
		if validation.get("status") != "ready":
			return validation
		var binding_value: Variant = attachment_bindings.get(key)
		if not binding_value is Dictionary:
			return _failed("borrowed_presentation_binding_missing")
		var binding: Dictionary = binding_value
		var binding_status := _validate_borrowed_presentation_binding(binding, member)
		if binding_status.get("status") != "ready": return binding_status
		rows_by_key[key] = _canonical_presentation_row(member)
		borrowed_keys[key] = true
		_presentation_bindings[key] = binding
		_presentation_binding_identity[key] = {
			"mountInstanceId":binding.mount.get_ref().get_instance_id(),
			"parentInstanceId":binding.parent.get_ref().get_instance_id(),
			"bodyInstanceId":binding.body.get_ref().get_instance_id(),
			"sourceId":String(binding.sourceId), "sourcePartId":String(binding.sourcePartId),
			"sourceRevision":String(binding.sourceRevision),
			"producerSourceRevision":String(binding.producerSourceRevision),
			"presentationMemberId":String(binding.presentationMemberId),
			"attachmentKey":String(binding.attachmentKey),
			"ownershipKind":String(binding.ownershipKind),
			"publisherInstanceId":int(binding.publisherInstanceId),
			"publicationEpoch":int(binding.publicationEpoch),
			"bodyToWorld":binding.bodyToWorld,
			"mountLocalTransform":binding.mountLocalTransform,
			"neutralParentToWorld":binding.neutralParentToWorld,
			"sweptWorldBounds":binding.sweptWorldBounds,
			"motion":binding.motion, "intendedVisible":bool(binding.intendedVisible)}
	# Geometry anchors remain native-owned roots. Their immutable member rows are
	# derived from the candidate's sealed source manifest, never from live Nodes.
	var batches_value: Variant = snapshot.get("batches", null)
	var source_manifest_value: Variant = snapshot.get("manifest", null)
	if not batches_value is Dictionary or not source_manifest_value is Array \
			or not source_manifest_value.is_read_only():
		return _failed("section_geometry_attachment_manifest_unavailable")
	for batch_key_value: Variant in batches_value:
		if not batch_key_value is String: return _failed("section_geometry_attachment_batch_key_invalid")
		var batch: Variant = batches_value[batch_key_value]
		if not batch is Dictionary or not batch.is_read_only():
			return _failed("section_geometry_attachment_batch_invalid")
		var key := String(batch.get("attachmentKey", ""))
		if key.is_empty(): continue
		if borrowed_keys.has(key):
			return _failed("geometry_and_borrowed_attachment_key_collision")
		var source_identity: Dictionary = {}
		for manifest_value: Variant in source_manifest_value:
			if not manifest_value is Dictionary or not manifest_value.is_read_only():
				return _failed("section_geometry_source_manifest_invalid")
			var source_row: Dictionary = manifest_value
			var row_batch_keys: Variant = source_row.get("batchKeys", null)
			if not row_batch_keys is Array or not row_batch_keys.is_read_only():
				return _failed("section_geometry_source_batch_keys_invalid")
			if row_batch_keys.has(String(batch_key_value)):
				var identity := {"sourceId":String(source_row.get("sourceId", "")),
					"sourcePartId":String(source_row.get("sourcePartId", "")),
					"sourceRevision":String(source_row.get("sourceRevision", ""))}
				if identity.sourceId.is_empty() or identity.sourcePartId.is_empty() \
						or identity.sourceRevision.is_empty():
					return _failed("section_geometry_source_identity_invalid")
				if not source_identity.is_empty() and source_identity != identity:
					return _failed("section_geometry_attachment_has_multiple_source_owners")
				source_identity = identity
		if source_identity.is_empty():
			return _failed("section_geometry_attachment_source_owner_missing")
		var neutral: Variant = batch.get("neutralParentToWorld", null)
		var swept: Variant = batch.get("sweptWorldBounds", null)
		var motion: Variant = batch.get("motion", null)
		if not neutral is Transform3D or not swept is AABB or not motion is Dictionary \
				or not motion.is_read_only():
			return _failed("section_geometry_attachment_spatial_contract_missing")
		var row := {"schema":PresentationMembers.SCHEMA,
			"sourceId":source_identity.sourceId,
			"sourcePartId":source_identity.sourcePartId,
			"sourceRevision":source_identity.sourceRevision,
			"producerSourceRevision":String(batch.producerSourceRevision),
			"attachmentKey":key,
			"presentationMemberId":"geometry:" + key,
			# Attachment activation is independent of each batch's original local
			# visibility. The latter is sealed on the batch and applied below.
			"ownershipKind":"backend_owned_geometry", "intendedVisible":true,
			"neutralParentToWorld":neutral, "sweptWorldBounds":swept, "motion":motion}
		row.make_read_only()
		row = _canonical_presentation_row(row)
		if rows_by_key.has(key):
			if rows_by_key[key] != row:
				return _failed("section_geometry_attachment_identity_conflict")
		else:
			rows_by_key[key] = row
		if not attachment_bindings.get(key) is Dictionary \
				or not _attachment_bindings.has(key):
			return _failed("section_geometry_attachment_binding_missing")
		var geometry_binding: Dictionary = _attachment_bindings[key]
		if geometry_binding.get("sourceRevision") != source_identity.sourceRevision \
				or geometry_binding.get("producerSourceRevision") != row.producerSourceRevision:
			return _failed("section_geometry_attachment_binding_revision_mismatch")
	var keys: Array[String] = []
	for key_value: Variant in rows_by_key: keys.append(String(key_value))
	keys.sort()
	if keys.size() > PresentationMembers.MAX_MEMBERS:
		return _failed("section_presentation_member_capacity")
	var rows: Array = []
	var member_ids: Dictionary = {}
	for key: String in keys: rows.append(rows_by_key[key])
	for row_value: Variant in rows:
		var row: Dictionary = row_value
		var member_id := String(row.get("presentationMemberId", ""))
		if member_id.is_empty() or member_ids.has(member_id):
			return _failed("section_presentation_member_identity_duplicate")
		member_ids[member_id] = true
	rows.make_read_only()
	var hashing := HashingContext.new()
	if hashing.start(HashingContext.HASH_SHA256) != OK \
			or hashing.update(var_to_bytes(rows)) != OK:
		return _failed("section_presentation_manifest_hash_failed")
	return {"status":"ready", "members":rows, "digest":hashing.finish().hex_encode()}


func _canonical_presentation_row(value: Dictionary) -> Dictionary:
	# Keep insertion order identical to the native canonical manifest serializer.
	var source_motion: Dictionary = value.motion
	var motion := {"kind":String(source_motion.kind),
		"closedParentToBody":source_motion.closedParentToBody,
		"raiseOffset":source_motion.raiseOffset, "swing":float(source_motion.swing)}
	motion.make_read_only()
	var row := {"schema":String(value.schema), "sourceId":String(value.sourceId),
		"sourcePartId":String(value.sourcePartId), "sourceRevision":String(value.sourceRevision),
		"producerSourceRevision":String(value.producerSourceRevision),
		"attachmentKey":String(value.attachmentKey),
		"presentationMemberId":String(value.presentationMemberId),
		"ownershipKind":String(value.ownershipKind), "intendedVisible":bool(value.intendedVisible),
		"neutralParentToWorld":value.neutralParentToWorld,
		"sweptWorldBounds":value.sweptWorldBounds, "motion":motion}
	row.make_read_only()
	return row


func _attachment_receipts_match_manifest(receipts_value: Variant,
		visible_claim: bool) -> bool:
	if not receipts_value is Array or receipts_value.size() != _presentation_manifest.size():
		return false
	var expected_by_key: Dictionary = {}
	for member: Dictionary in _presentation_manifest:
		expected_by_key[String(member.attachmentKey)] = member
	var seen: Dictionary = {}
	var seen_roots: Dictionary = {}
	for receipt_value: Variant in receipts_value:
		if not receipt_value is Dictionary: return false
		var receipt: Dictionary = receipt_value
		var key := String(receipt.get("attachmentKey", ""))
		if key.is_empty() or seen.has(key) or not expected_by_key.has(key): return false
		seen[key] = true
		var expected: Dictionary = expected_by_key[key]
		var motion: Dictionary = expected.motion
		if String(receipt.get("memberSourceId", "")) != String(expected.sourceId) \
				or String(receipt.get("sourcePartId", "")) != String(expected.sourcePartId) \
				or String(receipt.get("sourceRevision", "")) != String(expected.sourceRevision) \
				or String(receipt.get("producerSourceRevision", "")) != String(expected.producerSourceRevision) \
				or String(receipt.get("presentationMemberId", "")) != String(expected.presentationMemberId) \
				or String(receipt.get("ownershipKind", "")) != String(expected.ownershipKind) \
				or bool(receipt.get("intendedVisible", false)) != bool(expected.intendedVisible) \
				or bool(receipt.get("activeClaim", false)) != (visible_claim and bool(expected.intendedVisible)) \
				or bool(receipt.get("rootVisible", false)) != (visible_claim and bool(expected.intendedVisible)) \
				or receipt.get("neutralParentToWorld") != expected.neutralParentToWorld \
				or receipt.get("sweptWorldBounds") != expected.sweptWorldBounds \
				or int(receipt.get("rootInstanceId", 0)) <= 0 \
				or int(receipt.get("parentInstanceId", 0)) <= 0 \
				or int(receipt.get("bodyInstanceId", 0)) <= 0 \
				or String(receipt.get("motionKind", "")) != String(motion.kind) \
				or receipt.get("closedParentToBody") != motion.closedParentToBody \
				or receipt.get("raiseOffset") != motion.raiseOffset \
				or not is_equal_approx(float(receipt.get("swing", INF)), float(motion.swing)):
			return false
		var root_id := int(receipt.get("rootInstanceId", 0))
		if seen_roots.has(root_id): return false
		seen_roots[root_id] = true
		var binding: Dictionary = _presentation_bindings.get(key, _attachment_bindings.get(key, {}))
		if binding.is_empty() or not binding.get("parent") is WeakRef \
				or not binding.get("body") is WeakRef:
			return false
		var parent: Object = binding.parent.get_ref()
		var body: Object = binding.body.get_ref()
		if not is_instance_valid(parent) or not is_instance_valid(body) \
				or int(receipt.get("parentInstanceId", 0)) != parent.get_instance_id() \
				or int(receipt.get("bodyInstanceId", 0)) != body.get_instance_id() \
				or int(receipt.get("publisherInstanceId", 0)) != int(binding.get("publisherInstanceId", 0)) \
				or int(receipt.get("publicationEpoch", -1)) != int(binding.get("publicationEpoch", -1)):
			return false
		if String(expected.ownershipKind) == "borrowed_presentation":
			if not binding.get("mount") is WeakRef \
					or not is_instance_valid(binding.mount.get_ref()) \
					or root_id != binding.mount.get_ref().get_instance_id(): return false
		var receipt_legacy: Variant = receipt.get("legacyVisuals", null)
		var expected_legacy: Variant = binding.get("legacyVisuals", null)
		if not receipt_legacy is Array or not expected_legacy is Array \
				or receipt_legacy.size() != expected_legacy.size(): return false
		var legacy_ids: Dictionary = {}
		for reference: Variant in expected_legacy:
			if not reference is WeakRef or not is_instance_valid(reference.get_ref()): return false
			legacy_ids[reference.get_ref().get_instance_id()] = true
		for legacy_value: Variant in receipt_legacy:
			if not legacy_value is Dictionary: return false
			var legacy_receipt: Dictionary = legacy_value
			var visual_id := int(legacy_receipt.get("visualInstanceId", 0))
			if not legacy_ids.has(visual_id) or not bool(legacy_receipt.get("hidden", false)):
				return false
			legacy_ids.erase(visual_id)
		if not legacy_ids.is_empty(): return false
	return seen.size() == expected_by_key.size()


func _validate_borrowed_presentation_binding(binding: Dictionary, member: Dictionary) -> Dictionary:
	if not binding.is_read_only():
		return _failed("borrowed_presentation_binding_mutable")
	for field: String in ["sourceId", "sourcePartId", "sourceRevision", "producerSourceRevision",
			"presentationMemberId", "attachmentKey", "ownershipKind"]:
		if not binding.get(field) is String or String(binding[field]).is_empty():
			return _failed("borrowed_presentation_binding_identity_invalid:" + field)
	if not binding.get("intendedVisible") is bool \
			or not binding.get("publisherInstanceId") is int \
			or not binding.get("publicationEpoch") is int \
			or not binding.get("neutralParentToWorld") is Transform3D \
			or not binding.get("sweptWorldBounds") is AABB \
			or not binding.get("motion") is Dictionary \
			or not binding.motion.is_read_only() \
			or not binding.get("legacyVisuals") is Array \
			or not binding.legacyVisuals.is_read_only():
		return _failed("borrowed_presentation_binding_shape_invalid")
	for field: String in ["parent", "body", "mount"]:
		if not binding.get(field) is WeakRef or not is_instance_valid(binding[field].get_ref()) \
				or not binding[field].get_ref() is Node3D:
			return _failed("borrowed_presentation_owner_binding_invalid:" + field)
	var parent: Node3D = binding.parent.get_ref()
	var body: Node3D = binding.body.get_ref()
	var mount: Node3D = binding.mount.get_ref()
	var legacy: Variant = binding.get("legacyVisuals", null)
	if parent.is_queued_for_deletion() or body.is_queued_for_deletion() \
			or mount.is_queued_for_deletion() or not parent.is_inside_tree() \
			or not body.is_inside_tree() or not mount.is_inside_tree() \
			or mount.get_parent() != parent or (parent != body and not body.is_ancestor_of(parent)):
		return _failed("borrowed_presentation_owner_binding_stale")
	if not binding.get("mountLocalTransform") is Transform3D \
			or not binding.get("bodyToWorld") is Transform3D \
			or binding.get("neutralParentToWorld") != member.neutralParentToWorld \
			or binding.get("motion") != member.motion \
			or String(binding.get("sourceId", "")) != String(member.sourceId) \
			or String(binding.get("sourcePartId", "")) != String(member.sourcePartId) \
			or String(binding.get("sourceRevision", "")) != String(member.sourceRevision) \
			or String(binding.get("producerSourceRevision", "")) != String(member.producerSourceRevision) \
			or String(binding.get("presentationMemberId", "")) != String(member.presentationMemberId) \
			or String(binding.get("attachmentKey", "")) != String(member.attachmentKey) \
			or String(binding.get("ownershipKind", "")) != String(member.ownershipKind) \
			or binding.get("sweptWorldBounds") != member.sweptWorldBounds \
			or bool(binding.get("intendedVisible", false)) != bool(member.intendedVisible):
		return _failed("borrowed_presentation_binding_identity_mismatch")
	if not binding.get("mountLocalTransform").is_finite() \
			or not binding.get("bodyToWorld").is_finite() \
			or is_zero_approx(binding.mountLocalTransform.basis.determinant()) \
			or is_zero_approx(binding.bodyToWorld.basis.determinant()) \
			or not mount.transform.is_equal_approx(binding.mountLocalTransform) \
			or String(mount.get_meta("section_attachment_presentation_member_id", "")) != String(member.presentationMemberId) \
			or not binding.bodyToWorld.is_equal_approx(body.global_transform) \
			or int(binding.get("publisherInstanceId", 0)) == 0 \
			or int(binding.get("publicationEpoch", -1)) < 0 \
			or String(body.get_meta("section_attachment_source_revision", "")) != String(member.producerSourceRevision) \
			or int(body.get_meta("section_attachment_publisher_instance_id", 0)) != int(binding.publisherInstanceId) \
			or int(body.get_meta("section_attachment_publication_epoch", -1)) != int(binding.publicationEpoch):
		return _failed("borrowed_presentation_source_boundary_stale")
	# A light-only source has no legacy geometry to suppress. Its exact empty
	# roster is still part of the binding and checked against the native receipt.
	if not legacy is Array or not legacy.is_read_only():
		return _failed("borrowed_presentation_legacy_visual_manifest_missing")
	for reference: Variant in legacy:
		if not reference is WeakRef or not is_instance_valid(reference.get_ref()) \
				or not reference.get_ref() is GeometryInstance3D \
				or reference.get_ref().is_queued_for_deletion() \
				or not body.is_ancestor_of(reference.get_ref()):
			return _failed("borrowed_presentation_legacy_visual_manifest_invalid")
	return {"status":"ready"}


func advance(max_upload_units: int = 1, current_translucent_pov_revision: int = -1) -> Dictionary:
	if state in ["idle", "installed", "failed", "cancelled"]:
		return {"status":state, "reason":reason}
	if state == "awaiting_frame":
		var cancellation := _settle_presentation_cancellation()
		if cancellation.get("status") == "cancelled":
			var cancelled_failure := _failed("section_presentation_cancelled")
			cancelled_failure["requiresAuthoritativeReassembly"] = true
			cancelled_failure["ownershipCleanup"] = cancellation
			return cancelled_failure
		if cancellation.get("status") != "not_applicable": return cancellation
	if not _attachments_current():
		if state == "awaiting_frame":
			return _rollback_then_fail(_presentation_token, "section_attachment_binding_stale")
		return _fail("section_attachment_binding_stale")
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
		var append_arguments: Array = [_source_id,
			_generation, batch_id, entry.mesh, mesh_content_digest, entry.material,
			PackedFloat32Array(segment.buffer), segment.bounds,
			String(batch.get("renderTier", "structural")),
			bool(policy.castShadows), float(policy.visibilityRangeEnd), float(policy.fadeMargin),
			String(batch.get("renderLayer", ""))]
		var append_method := "append_batch_in_layer"
		if not String(batch.get("attachmentKey", "")).is_empty():
			append_method = "append_batch_in_attachment"
			append_arguments.append(String(batch.attachmentKey))
		append_arguments.append(bool(batch.intendedVisible))
		var append_buffer_float_count := int(segment.buffer.size())
		var append_mesh_surface_bytes := int(entry.get("meshSurfaceBytes", -1))
		var append_started_usec := Time.get_ticks_usec()
		var appended: Dictionary = backend.callv(append_method, append_arguments)
		_last_append_step_wall_usec = maxi(0, Time.get_ticks_usec() - append_started_usec)
		_max_append_step_wall_usec = maxi(_max_append_step_wall_usec,
			_last_append_step_wall_usec)
		_last_append_buffer_float_count = append_buffer_float_count
		_max_append_buffer_float_count = maxi(_max_append_buffer_float_count,
			append_buffer_float_count)
		_last_append_mesh_surface_bytes = append_mesh_surface_bytes
		if append_mesh_surface_bytes >= 0:
			_max_append_mesh_surface_bytes = maxi(_max_append_mesh_surface_bytes,
				append_mesh_surface_bytes)
		if appended.get("status") == "backpressure":
			var backpressure := {"status":"pending",
				"reason":appended.get("reason", "backpressure")}
			backpressure["appendTelemetry"] = append_telemetry()
			return backpressure
		if appended.get("status") != "accepted":
			var failure := _fail(String(appended.get("reason", "native_section_candidate_append_failed")))
			var bounds: AABB = segment.bounds
			var mesh := entry.mesh as Mesh
			failure["nativeAppend"] = {"sourceId":_source_id,
				"batchId":batch_id, "batchKey":String(entry.get("batchKey", "")),
				"segmentId":String(segment.get("segmentId", "")),
				"meshClass":mesh.get_class() if is_instance_valid(mesh) else "null",
				"meshSurfaceCount":mesh.get_surface_count() if is_instance_valid(mesh) else -1,
				"materialClass":entry.material.get_class() if is_instance_valid(entry.material) else "null",
				"meshContentDigestLength":mesh_content_digest.length(),
				"bufferFloatCount":append_buffer_float_count,
				"meshSurfacePayloadBytes":append_mesh_surface_bytes,
				"appendStepWallUsec":_last_append_step_wall_usec,
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
		var append_pending := {"status":"pending", "stage":"append",
			"completedBatches":_batch_index}
		append_pending["appendTelemetry"] = append_telemetry()
		return append_pending
	if state == "upload":
		var upload_started_usec := Time.get_ticks_usec()
		var advanced: Dictionary = backend.call("advance_packet", _source_id, _generation, max_upload_units)
		_last_upload_call_wall_usec = maxi(0, Time.get_ticks_usec() - upload_started_usec)
		_max_upload_call_wall_usec = maxi(_max_upload_call_wall_usec,
			_last_upload_call_wall_usec)
		_last_upload_cursor = int(advanced.get("uploadCursor",
			advanced.get("uploadedBatches", -1)))
		_last_upload_processed_units = int(advanced.get("units", -1))
		_last_upload_expected_batches = int(advanced.get("expectedBatches", _batches.size()))
		if advanced.get("status") == "pending":
			return _with_install_telemetry({"status":"pending",
				"reason":advanced.get("reason", "upload_pending")})
		if advanced.get("status") == "failed":
			return _with_install_telemetry(_fail(String(advanced.get("reason",
				"native_section_candidate_upload_failed"))))
		if advanced.get("status") != "ready_to_commit":
			return _with_install_telemetry(_fail("native_section_candidate_upload_unacknowledged"))
		state = "commit"
		return _with_install_telemetry({"status":"pending", "stage":state})
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
		if not bool(committed.get("attachmentManifestDeclared", false)) \
				or String(committed.get("attachmentManifestDigest", "")) != _presentation_manifest_digest \
				or int(committed.get("attachmentManifestCount", -1)) != _presentation_manifest.size() \
				or not _attachment_receipts_match_manifest(committed.get("attachmentRoots", []), true):
			return _fail("native_section_attachment_manifest_receipt_mismatch")
		_presentation_token = String(committed.get("token", ""))
		_presentation_root_id = int(committed.get("rootInstanceId", 0))
		_presentation_attachment_roots = committed.get("attachmentRoots", []).duplicate(true)
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


func append_telemetry() -> Dictionary:
	return {"lastAppendStepWallUsec":_last_append_step_wall_usec,
		"maxAppendStepWallUsec":_max_append_step_wall_usec,
		"lastAppendBufferFloatCount":_last_append_buffer_float_count,
		"maxAppendBufferFloatCount":_max_append_buffer_float_count,
		"lastAppendMeshSurfaceBytes":_last_append_mesh_surface_bytes,
		"maxAppendMeshSurfaceBytes":_max_append_mesh_surface_bytes,
		"lastUploadAdvanceWallUsec":_last_upload_call_wall_usec,
		"maxUploadAdvanceWallUsec":_max_upload_call_wall_usec,
		"lastUploadCursor":_last_upload_cursor,
		"lastUploadProcessedUnits":_last_upload_processed_units,
		"lastUploadExpectedBatches":_last_upload_expected_batches,
		"installBatchCount":_batches.size()}


func _with_install_telemetry(result: Dictionary) -> Dictionary:
	result["appendTelemetry"] = append_telemetry()
	return result


func finalize_presentation(token: String) -> Dictionary:
	if state != "awaiting_frame":
		return {"status":"failed","reason":"section_presentation_not_pending"}
	if token.is_empty() or token != _presentation_token:
		return _rollback_failed_step("section_presentation_token_mismatch", {})
	var cancellation := _settle_presentation_cancellation()
	if cancellation.get("status") == "cancelled":
		var cancelled_failure := _failed("section_presentation_cancelled")
		cancelled_failure["requiresAuthoritativeReassembly"] = true
		cancelled_failure["ownershipCleanup"] = cancellation
		return cancelled_failure
	if cancellation.get("status") != "not_applicable": return cancellation
	if not _frame_drawn:
		return {"status":"pending_presentation", "reason":"section_frame_not_drawn",
			"presentationToken":_presentation_token}
	if not _attachments_current():
		return _rollback_then_fail(token, "section_attachment_binding_stale")
	var backend := _current_backend()
	var chunk := _current_chunk()
	if backend == null or chunk == null:
		return _rollback_then_fail(token, "section_install_owner_replaced")
	var pending: Dictionary = backend.call("pending_presentation_snapshot", _source_id)
	if pending.get("attachmentRoots", []) != _presentation_attachment_roots:
		return _rollback_then_fail(token, "section_attachment_root_set_replaced")
	if pending.get("status") != "pending_presentation" \
			or not bool(pending.get("attachmentManifestDeclared", false)) \
			or String(pending.get("attachmentManifestDigest", "")) != _presentation_manifest_digest \
			or int(pending.get("attachmentManifestCount", -1)) != _presentation_manifest.size() \
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
	var installed_snapshot: Dictionary = backend.call("installed_snapshot", _source_id)
	if finalized.get("status") != "ready" \
			or not backend.call("receipt_installed", _source_id, _generation,
				_source_revision, String(_candidate.contentManifestDigest)) \
			or not bool(installed_snapshot.get("attachmentManifestDeclared", false)) \
			or String(installed_snapshot.get("attachmentManifestDigest", "")) != _presentation_manifest_digest \
			or int(installed_snapshot.get("attachmentManifestCount", -1)) != _presentation_manifest.size() \
			or not _attachment_receipts_match_manifest(installed_snapshot.get("attachmentRoots", []), true):
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
	var failed := _failed(failure_reason)
	failed["ownershipCleanup"] = rolled_back
	if bool(rolled_back.get("requiresAuthoritativeReassembly", false)):
		failed["requiresAuthoritativeReassembly"] = true
	return failed


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
	var cancellation := _settle_presentation_cancellation(true)
	if cancellation.get("status") != "not_applicable": return cancellation
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


func _settle_presentation_cancellation(withdrawal_requested := false) -> Dictionary:
	var backend := _bound_backend_for_rollback()
	if backend == null:
		return _rollback_failed_step("section_presentation_cancellation_backend_unavailable", {})
	var owner_loss: Dictionary = backend.call("settle_presentation_cancellation", _source_id,
		_generation, _presentation_token, withdrawal_requested)
	if owner_loss.get("status") == "cancelled":
		if not bool(owner_loss.get("ownershipReleased", false)) \
				or not bool(owner_loss.get("candidateQuiesced", false)) \
				or owner_loss.get("sourceId") != _source_id \
				or owner_loss.get("generation") != _generation \
				or owner_loss.get("presentationToken") != _presentation_token:
			return _rollback_failed_step("section_presentation_cancellation_proof_invalid", owner_loss)
		state = "cancelled"
		_tombstone_frame_drawn_callback()
		return {"status":"cancelled", "sectionKey":_candidate.get("sectionKey"),
			"generation":_generation, "cancellationSettlement":owner_loss,
			"requiresAuthoritativeReassembly":true}
	if owner_loss.get("status") != "not_applicable":
		return _rollback_failed_step("section_presentation_cancellation_unsettled", owner_loss)
	return owner_loss


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
	var aborted := _abort_owned_packet()
	if aborted.get("status") != "cancelled":
		return aborted
	state = "cancelled"
	return {"status":"cancelled", "sectionKey":_candidate.get("sectionKey")}


func _abort_owned_packet() -> Dictionary:
	if _generation <= 0 or _source_id.is_empty():
		return {"status":"cancelled"}
	var backend := _bound_backend_for_rollback()
	if backend == null:
		return _rollback_failed_step(reason, {"reason":"section_install_abort_backend_unavailable"})
	var aborted: Dictionary = backend.call("abort_packet", _source_id, _generation)
	if aborted.get("status") not in ["aborted", "missing", "rolled_back"]:
		return _rollback_failed_step(reason, aborted)
	return {"status":"cancelled", "nativeAbort":aborted}


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
		"previousGeneration":_previous_generation,
		"presentationManifestDigest":_presentation_manifest_digest,
		"presentationMemberCount":_presentation_manifest.size(),
		"attachmentRoots":_presentation_attachment_roots.duplicate(true)}
	if not _production_metadata.is_empty():
		receipt["candidateSchema"] = "world-static-section-production-candidate/v1"
		receipt["censusDigest"] = String(_production_metadata.get("censusDigest", ""))
		receipt["sourceRevisions"] = _production_metadata.get("sourceRevisions", {})
		receipt["removalRevisions"] = _production_metadata.get("removalRevisions", {})
		receipt["providerCoverage"] = _production_metadata.get("providerCoverage", [])
		receipt["supportCoverageIdentities"] = _production_metadata.get(
			"supportCoverageIdentities", [])
	receipt.make_read_only()
	return receipt


func _receipt(backend: Node, chunk: Node3D) -> Dictionary:
	var receipt := {"status":"installed", "worldId":String(_candidate.worldId),
		"sectionKey":_candidate.sectionKey, "generation":_generation,
		"contentManifestDigest":String(_candidate.contentManifestDigest),
		"sourceRevision":_source_revision,
		"ownerCell":_owner_cell, "backendInstanceId":backend.get_instance_id(),
		"chunkInstanceId":chunk.get_instance_id(),
		"sourceCaptureChunkKeys":_candidate.snapshot.streamChunkDependencies.duplicate(),
		"presentationManifestDigest":_presentation_manifest_digest,
		"presentationMemberCount":_presentation_manifest.size(),
		"attachmentRoots":_presentation_attachment_roots.duplicate(true)}
	if _translucent_pov_revision > 0:
		receipt["translucentPovRevision"] = _translucent_pov_revision
	if not _production_metadata.is_empty():
		receipt["candidateSchema"] = "world-static-section-production-candidate/v1"
		receipt["censusDigest"] = String(_production_metadata.get("censusDigest", ""))
		receipt["sourceRevisions"] = _production_metadata.get("sourceRevisions", {})
		receipt["removalRevisions"] = _production_metadata.get("removalRevisions", {})
		receipt["providerCoverage"] = _production_metadata.get("providerCoverage", [])
		receipt["supportCoverageIdentities"] = _production_metadata.get(
			"supportCoverageIdentities", [])
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


func _attachments_current() -> bool:
	for attachment_key: String in _attachment_bindings:
		var binding: Dictionary = _attachment_bindings[attachment_key]
		var identity: Dictionary = _attachment_identity[attachment_key]
		if not binding.is_read_only() or not identity.get("bodyToWorld") is Transform3D:
			return false
		for identity_key: String in identity:
			if binding.get(identity_key) != identity[identity_key]:
				return false
		if not binding.get("parent") is WeakRef or not binding.get("body") is WeakRef:
			return false
		var legacy: Variant = binding.get("legacyVisuals")
		if not legacy is Array or not legacy.is_read_only() or legacy.is_empty(): return false
		for reference: Variant in legacy:
			if not reference is WeakRef or not is_instance_valid(reference.get_ref()) \
					or not reference.get_ref() is GeometryInstance3D \
					or reference.get_ref().is_queued_for_deletion(): return false
		var parent: Node3D = binding.parent.get_ref() as Node3D
		var body: Node3D = binding.body.get_ref() as Node3D
		if not is_instance_valid(parent) or not is_instance_valid(body) \
				or parent.is_queued_for_deletion() or body.is_queued_for_deletion() \
				or not parent.is_inside_tree() or not body.is_inside_tree() \
				or parent.get_instance_id() != int(identity.get("parentInstanceId", 0)) \
				or body.get_instance_id() != int(identity.get("bodyInstanceId", 0)) \
				or (parent != body and not body.is_ancestor_of(parent)):
			return false
		if not body.global_transform.is_equal_approx(identity.bodyToWorld):
			return false
		if String(body.get_meta("section_attachment_source_revision", "")) != String(identity.get("producerSourceRevision", "")) \
				or int(body.get_meta("section_attachment_publisher_instance_id", 0)) != int(identity.get("publisherInstanceId", -1)) \
				or int(body.get_meta("section_attachment_publication_epoch", -1)) != int(identity.get("publicationEpoch", -2)):
			return false
	for attachment_key: String in _presentation_bindings:
		var binding: Dictionary = _presentation_bindings[attachment_key]
		var identity: Dictionary = _presentation_binding_identity.get(attachment_key, {})
		if not binding.is_read_only() or not binding.get("motion") is Dictionary \
				or not binding.motion.is_read_only(): return false
		var parent_ref: Variant = binding.get("parent", null)
		var body_ref: Variant = binding.get("body", null)
		var mount_ref: Variant = binding.get("mount", null)
		if not parent_ref is WeakRef or not body_ref is WeakRef or not mount_ref is WeakRef:
			return false
		var parent: Node3D = parent_ref.get_ref() as Node3D
		var body: Node3D = body_ref.get_ref() as Node3D
		var mount: Node3D = mount_ref.get_ref() as Node3D
		if not is_instance_valid(parent) or not is_instance_valid(body) \
				or not is_instance_valid(mount) or parent.is_queued_for_deletion() \
				or body.is_queued_for_deletion() or mount.is_queued_for_deletion() \
				or not parent.is_inside_tree() or not body.is_inside_tree() \
				or not mount.is_inside_tree() or mount.get_parent() != parent \
				or (parent != body and not body.is_ancestor_of(parent)) \
				or parent.get_instance_id() != int(identity.get("parentInstanceId", 0)) \
				or body.get_instance_id() != int(identity.get("bodyInstanceId", 0)) \
				or mount.get_instance_id() != int(identity.get("mountInstanceId", 0)) \
				or String(binding.get("sourceId", "")) != String(identity.get("sourceId", "")) \
				or String(binding.get("sourcePartId", "")) != String(identity.get("sourcePartId", "")) \
				or String(binding.get("sourceRevision", "")) != String(identity.get("sourceRevision", "")) \
				or String(binding.get("producerSourceRevision", "")) != String(identity.get("producerSourceRevision", "")) \
				or String(binding.get("presentationMemberId", "")) != String(identity.get("presentationMemberId", "")) \
				or String(binding.get("attachmentKey", "")) != String(identity.get("attachmentKey", "")) \
				or String(binding.get("ownershipKind", "")) != String(identity.get("ownershipKind", "")) \
				or int(binding.get("publisherInstanceId", 0)) != int(identity.get("publisherInstanceId", -1)) \
				or int(binding.get("publicationEpoch", -1)) != int(identity.get("publicationEpoch", -2)) \
				or binding.get("bodyToWorld") != identity.get("bodyToWorld") \
				or binding.get("mountLocalTransform") != identity.get("mountLocalTransform") \
				or binding.get("neutralParentToWorld") != identity.get("neutralParentToWorld") \
				or binding.get("sweptWorldBounds") != identity.get("sweptWorldBounds") \
				or binding.get("motion") != identity.get("motion") \
				or binding.get("intendedVisible") != identity.get("intendedVisible") \
				or not body.global_transform.is_equal_approx(identity.get("bodyToWorld", Transform3D())) \
				or not mount.transform.is_equal_approx(identity.get("mountLocalTransform", Transform3D.IDENTITY)) \
				or String(body.get_meta("section_attachment_source_revision", "")) != String(identity.get("producerSourceRevision", "")) \
				or int(body.get_meta("section_attachment_publisher_instance_id", 0)) != int(identity.get("publisherInstanceId", -1)) \
				or int(body.get_meta("section_attachment_publication_epoch", -1)) != int(identity.get("publicationEpoch", -2)):
			return false
		var legacy: Variant = binding.get("legacyVisuals", null)
		if not legacy is Array or not legacy.is_read_only(): return false
		for reference: Variant in legacy:
			if not reference is WeakRef or not is_instance_valid(reference.get_ref()) \
					or not reference.get_ref() is GeometryInstance3D \
					or reference.get_ref().is_queued_for_deletion() \
					or not body.is_ancestor_of(reference.get_ref()): return false
	return true


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
	if state == "awaiting_frame":
		return _rollback_then_fail(_presentation_token, value)
	var aborted := _abort_owned_packet()
	if aborted.get("status") != "cancelled":
		return aborted
	var failed := _failed(value)
	var proof: Dictionary = aborted.get("nativeAbort", {})
	if bool(proof.get("requiresAuthoritativeReassembly", false)) \
			and bool(proof.get("ownershipReleased", false)) \
			and bool(proof.get("candidateQuiesced", false)) \
			and proof.get("sourceId") == _source_id and proof.get("generation") == _generation:
		failed["requiresAuthoritativeReassembly"] = true
		failed["ownershipCleanup"] = aborted
	return failed


func _failed(value: String) -> Dictionary:
	reason = value
	state = "failed"
	var result := {"status":"failed", "reason":reason}
	if value in ["section_attachment_binding_stale", "attachment_binding_stale",
			"attachment_source_boundary_missing", "attachment_root_set_stale",
			"pending_attachment_root_set_stale"]:
		result["requiresAuthoritativeReassembly"] = true
	return result
