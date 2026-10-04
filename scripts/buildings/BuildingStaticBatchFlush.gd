extends RefCounted
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const InstanceBuffer = preload("res://scripts/buildings/BuildingInstanceBuffer.gd")
const InstanceAttributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const MeshFingerprint = preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
## One existing static-batch boundary, prepared in small main-thread units.
## No Node references survive a call. The owner pauses part publication until
## ready, and retains retired containers until its existing worker disposal.
var state := "idle"
var reason := ""
var max_atomic_usec := 0
var max_slice_usec := 0
var units := 0
var _groups: Dictionary = {}
var _records: Dictionary = {}
var _keys: Array = []
var _metadata: Dictionary = {}
var _copy_stack: Array = []
var _record_keys: Array = []
var _record_index := 0
var _record_key: Variant
var _record_source: Dictionary = {}
var _record_copy: Dictionary = {}
var _record_binding := ""
var _cache: Dictionary = {}
var _cache_hits := 0
var _copies := 0
var _copied_encoded_bytes := 0
var _record_reusable := true
var _unsupported_copies := 0
var _record_containers: Array = []
var _freeze_index := 0
var _all_records_prepared := true
var _prepared_hits := 0
var _group_index := 0
var _instance_index := 0
var _mesh: MultiMesh
var _transforms: Array = []
var _custom: Array = []
var _material: Material
var _parent: WeakRef
var _segments: Dictionary = {}
var _buffer := PackedFloat32Array()
var _retired_buffers: Array = []
var _publication_boundary: Dictionary = {}
var _packet_segments: Array = []
var _packet_segment_index := 0
var _packet_backend: Node
var _packet_chunk: Node3D
var _packet_source_id := ""
var _packet_source_revision := ""
var _packet_digest := ""
var _packet_mesh_content_digest := ""
var _packet_generation := 0
var _packet_owner_cell := Vector2i.ZERO
var _packet_hash: HashingContext
var _packet_instance_count := 0
var _packet_local_to_chunk := Transform3D.IDENTITY
var _packet_retire_parts: Array[String] = []
var _packet_retire_part_index := 0
var _packet_retire_sources: Array[String] = []
var _packet_retire_source_index := 0
var _replay_only := false
var replay_source_id := ""

func begin(groups: Dictionary, records: Dictionary, parent: Node3D, publication_boundary: Dictionary = {}) -> void:
	if state != "idle": return
	if not is_instance_valid(parent):
		state = "failed"; reason = "static_flush_parent_lost"; return
	_groups = groups
	_records = records
	_publication_boundary = publication_boundary
	_parent = weakref(parent)
	state = "keys"


func begin_replay(group: Dictionary, parent: Node3D) -> void:
	if state != "idle" or not is_instance_valid(parent):
		state="failed"; reason="static_packet_replay_owner_unavailable"; return
	_groups={"replay":group}
	_records={}
	_publication_boundary={}
	_parent=weakref(parent)
	_replay_only=true
	replay_source_id=String(group.get("sourceId",""))
	state="keys"


func cancel() -> void:
	if is_instance_valid(_packet_backend) and _packet_generation>0:
		_packet_backend.call("abort_packet",_packet_source_id,_packet_generation)
	_packet_backend=null
	_packet_chunk=null
	_packet_segments=[]
	state="idle"


func _packet_owner_is_current(publisher) -> bool:
	if not is_instance_valid(_packet_backend) or not is_instance_valid(_packet_chunk): return false
	var current: Dictionary=publisher.resolve_chunk_render_packet_backend(_packet_owner_cell)
	return current.get("status")=="ready" and is_same(current.get("backend"),_packet_backend) \
		and is_same(current.get("chunk"),_packet_chunk)

func advance(publisher, budget_usec: int = 2500) -> Dictionary:
	if budget_usec < 1 or budget_usec > 4000:
		return {"status":"failed","reason":"invalid_slice_budget"}
	var started := Time.get_ticks_usec()
	var count := 0
	while state not in ["ready", "failed", "idle"] and (count == 0 or Time.get_ticks_usec()-started < budget_usec):
		var atomic_started := Time.get_ticks_usec()
		var stage := state
		_step(publisher)
		if state=="failed" and is_instance_valid(_packet_backend) and _packet_generation>0:
			_packet_backend.call("abort_packet",_packet_source_id,_packet_generation)
			_packet_backend=null
		var elapsed := Time.get_ticks_usec()-atomic_started
		max_atomic_usec = maxi(max_atomic_usec, elapsed)
		publisher._record_publication_stage("static_flush_"+stage,elapsed,str(_transforms.size()) if stage in ["group","upload"] else "")
		count += 1
		units += 1
	max_slice_usec = maxi(max_slice_usec, Time.get_ticks_usec()-started)
	return {"status":state if state in ["ready","failed"] else "pending_budget", "reason":reason,
		"maxAtomicUsec":max_atomic_usec, "maxSliceUsec":max_slice_usec, "units":units}

func _step(publisher) -> void:
	var parent: Node3D = _parent.get_ref() as Node3D
	if not is_instance_valid(parent) or parent.is_queued_for_deletion():
		state = "failed"; reason = "static_flush_parent_lost"; return
	match state:
		"keys":
			_keys = _groups.keys()
			_keys.sort()
			state = "group"
		"group":
			if _group_index >= _keys.size():
				state = "ready" if _replay_only else "metadata_begin"
				return
			var group: Dictionary = _groups[_keys[_group_index]]
			_transforms = group.get("transforms",[])
			_custom = group.get("customData",[])
			_segments = group.get("preparedSegments",{})
			_buffer = PackedFloat32Array()
			_material = group.material
			if _transforms.is_empty() and int(group.get("packetInstanceCount",0))<=0:
				_group_index += 1
				return
			if publisher.static_packet_group_eligible(group,parent):
				_packet_owner_cell=group.renderChunkKey
				_packet_source_revision=String(group.sourceRevision)
				var site_identity: String=publisher.publication_site_id if not publisher.publication_site_id.is_empty() else publisher.source_blueprint_id
				_packet_source_id="building:%s:%s:%d,%d:%s:%s" % [site_identity,String(group.sourcePartId),
					_packet_owner_cell.x,_packet_owner_cell.y,
					(String(group.materialKey)+"|"+String(group.renderTier)).sha256_text(),publisher.source_blueprint_id]
				_packet_segment_index=0
				_packet_instance_count=0
				var segment_indices: Array = _segments.keys()
				segment_indices.sort()
				_packet_segments=[]
				for segment_index: Variant in segment_indices:
					var segment: Dictionary = _segments[segment_index]
					_packet_segments.append({"id":"segment:%06d" % int(segment_index),"segment":segment})
					_packet_instance_count+=int(segment.instanceCount)
				state="packet_owner"
				return
			_mesh = publisher.create_mesh_batch()
			_mesh.transform_format = MultiMesh.TRANSFORM_3D
			_mesh.use_colors = true
			_mesh.use_custom_data = true
			_mesh.instance_count = _transforms.size()
			publisher.static_batch_peak_instances = maxi(publisher.static_batch_peak_instances,_transforms.size())
			_mesh.mesh = publisher.unit_box
			_instance_index = 0
			state = "instances"
		"instances":
			if _segments.has(_instance_index):
				var segment = _segments[_instance_index]
				_buffer.append_array(PackedFloat32Array(segment.buffer))
				_instance_index += segment.instanceCount
			else:
				_buffer.append_array(InstanceBuffer.encode(_transforms[_instance_index],_custom[_instance_index]))
				_instance_index += 1
			if _instance_index == _transforms.size(): state = "upload"
		"upload":
			publisher.submit_mesh_batch_buffer(_mesh,_buffer)
			_retired_buffers.append(_buffer) # Released with this flush on the owning retirement worker.
			state = "attach"
		"attach":
			var instance := MultiMeshInstance3D.new()
			instance.name = "ConstructionStaticVisualBatch"
			instance.multimesh = _mesh
			instance.material_override = _material
			var group: Dictionary = _groups[_keys[_group_index]]
			var tier := String(group.get("renderTier","structural"))
			var owner_cell: Vector2i = group.get("ownerCell",Vector2i.ZERO)
			var source_part_id := String(group.get("sourcePartId",""))
			publisher.apply_static_visual_render_policy(instance,tier)
			instance.set_meta("building_owner_cell",owner_cell)
			instance.set_meta("building_source_part_id",source_part_id)
			instance.set_meta("building_source_blueprint",publisher.source_blueprint_id)
			parent.add_child(instance)
			publisher.published_nodes.append(instance)
			publisher.visual_batch_count += 1
			_mesh = null
			_group_index += 1
			state = "group"
		"packet_owner":
			var packet_group: Dictionary=_groups[_keys[_group_index]]
			var owner: Dictionary = publisher.resolve_chunk_render_packet_backend(_packet_owner_cell)
			if owner.get("status")=="pending": return
			if owner.get("status")!="ready":
				if String(owner.get("reason","")) in ["current_world_scene_unavailable","current_world_chunk_registry_missing"]:
					_mesh = publisher.create_mesh_batch()
					_mesh.transform_format = MultiMesh.TRANSFORM_3D
					_mesh.use_colors = true
					_mesh.use_custom_data = true
					_mesh.instance_count = _transforms.size()
					publisher.static_batch_peak_instances = maxi(publisher.static_batch_peak_instances,_transforms.size())
					_mesh.mesh = publisher.unit_box
					_instance_index = 0
					state = "instances"
					return
				state="failed"; reason=String(owner.get("reason","chunk_packet_owner_unavailable")); return
			_packet_backend=owner.backend as Node
			_packet_chunk=owner.chunk as Node3D
			if not is_instance_valid(_packet_backend) or not is_instance_valid(_packet_chunk):
				state="failed"; reason="chunk_packet_owner_lost"; return
			var installed: Dictionary = _packet_backend.call("installed_snapshot",_packet_source_id)
			_packet_generation=publisher.next_chunk_static_packet_generation(installed)
			_packet_local_to_chunk=_packet_chunk.global_transform.affine_inverse()*parent.global_transform
			_packet_hash=HashingContext.new()
			var policy: Dictionary=publisher.static_packet_policy(String(packet_group.renderTier))
			var transform_bytes:=PackedFloat32Array([
				_packet_local_to_chunk.basis.x.x,_packet_local_to_chunk.basis.y.x,_packet_local_to_chunk.basis.z.x,_packet_local_to_chunk.origin.x,
				_packet_local_to_chunk.basis.x.y,_packet_local_to_chunk.basis.y.y,_packet_local_to_chunk.basis.z.y,_packet_local_to_chunk.origin.y,
				_packet_local_to_chunk.basis.x.z,_packet_local_to_chunk.basis.y.z,_packet_local_to_chunk.basis.z.z,_packet_local_to_chunk.origin.z
			]).to_byte_array()
			var packet_mesh: Mesh=packet_group.get("mesh",publisher.unit_box)
			var mesh_identity: Dictionary=MeshFingerprint.inspect(packet_mesh)
			if mesh_identity.get("status")!="ready":
				state="failed"; reason=String(mesh_identity.get("reason","chunk_packet_mesh_identity_failed")); return
			_packet_mesh_content_digest=String(mesh_identity.contentDigest)
			var mesh_size: Vector3=packet_mesh.size if packet_mesh is BoxMesh else publisher.unit_box.size
			var mesh_bytes:=PackedFloat32Array([mesh_size.x,mesh_size.y,mesh_size.z]).to_byte_array()
			var header: String="%s\n%s\n%s\n%s\n%d\n%d\n%s\n%s\n%s\n%s\n%s" % [
				_packet_source_id,_packet_source_revision,str(_packet_owner_cell),InstanceAttributes.LAYOUT_SCHEMA,
				_packet_segments.size(),_packet_instance_count,
				String(packet_group.materialKey),String(packet_group.renderTier),str(policy),"unit_box_v1",
				_packet_mesh_content_digest]
			if _packet_hash.start(HashingContext.HASH_SHA256)!=OK \
					or _packet_hash.update(header.to_utf8_buffer())!=OK \
					or _packet_hash.update(transform_bytes)!=OK or _packet_hash.update(mesh_bytes)!=OK:
				state="failed"; reason="chunk_packet_digest_start_failed"; return
			state="packet_hash"
		"packet_hash":
			if _packet_segment_index>=_packet_segments.size():
				_packet_digest=_packet_hash.finish().hex_encode()
				state="packet_begin"
				return
			var entry: Dictionary=_packet_segments[_packet_segment_index]
			var segment: Dictionary=entry.segment
			var batch_id: String=entry.id
			var bounds: AABB=segment.bounds
			var geometry_bytes:=PackedFloat32Array([bounds.position.x,bounds.position.y,bounds.position.z,
				bounds.size.x,bounds.size.y,bounds.size.z]).to_byte_array()
			var buffer_bytes:=PackedFloat32Array(segment.buffer).to_byte_array()
			if _packet_hash.update((batch_id+"\n"+String(_groups[_keys[_group_index]].renderTier)+"\n").to_utf8_buffer())!=OK \
					or _packet_hash.update(geometry_bytes)!=OK or _packet_hash.update(buffer_bytes)!=OK:
				state="failed"; reason="chunk_packet_digest_update_failed"; return
			_packet_segment_index+=1
		"packet_begin":
			if not _packet_owner_is_current(publisher): state="failed"; reason="chunk_packet_owner_replaced_before_begin"; return
			var packet_group: Dictionary=_groups[_keys[_group_index]]
			publisher.expect_chunk_static_packet(String(packet_group.sourcePartId),_packet_source_id,_packet_owner_cell,
				_packet_generation,_packet_source_revision,_packet_digest,_replay_only)
			var begin: Dictionary=_packet_backend.call("begin_packet",_packet_source_id,_packet_owner_cell,_packet_generation,
				_packet_source_revision,_packet_digest,_packet_local_to_chunk,_packet_segments.size(),_packet_instance_count)
			if begin.get("status")=="backpressure":
				publisher._record_publication_stage("static_flush_packet_backpressure",0,String(begin.get("reason",""))+":"+_packet_source_id)
				return
			if begin.get("reason")=="stale_packet_generation":
				_packet_generation=publisher.next_chunk_static_packet_generation(_packet_backend.call("installed_snapshot",_packet_source_id))
				publisher.expect_chunk_static_packet(String(packet_group.sourcePartId),_packet_source_id,_packet_owner_cell,
					_packet_generation,_packet_source_revision,_packet_digest,_replay_only)
				return
			if begin.get("status") not in ["ready_to_append","ready_to_commit"]:
				state="failed"; reason=String(begin.get("reason","chunk_packet_begin_failed")); return
			_packet_segment_index=0
			state="packet_append" if not _packet_segments.is_empty() else "packet_advance"
		"packet_append":
			if not _packet_owner_is_current(publisher): state="failed"; reason="chunk_packet_owner_replaced_during_append"; return
			if _packet_segment_index>=_packet_segments.size(): state="packet_advance"; return
			var entry: Dictionary=_packet_segments[_packet_segment_index]
			var segment: Dictionary=entry.segment
			var group: Dictionary=_groups[_keys[_group_index]]
			var tier:=String(group.renderTier)
			var policy: Dictionary=publisher.static_packet_policy(tier)
			var appended: Dictionary=_packet_backend.call("append_batch",_packet_source_id,_packet_generation,entry.id,
				group.get("mesh",publisher.unit_box),_packet_mesh_content_digest,group.material,
				PackedFloat32Array(segment.buffer),segment.bounds,tier,
				bool(policy.castShadows),float(policy.visibilityRange),float(policy.fadeMargin))
			if appended.get("status")=="backpressure": return
			if appended.get("status")!="accepted":
				state="failed"; reason=String(appended.get("reason","chunk_packet_append_failed")); return
			_packet_segment_index+=1
		"packet_advance":
			if not _packet_owner_is_current(publisher): state="failed"; reason="chunk_packet_owner_replaced_during_upload"; return
			var advanced: Dictionary=_packet_backend.call("advance_packet",_packet_source_id,_packet_generation,1)
			if advanced.get("status")=="pending": return
			if advanced.get("status")=="failed": state="failed"; reason=String(advanced.get("reason","chunk_packet_upload_failed")); return
			if advanced.get("status")=="ready_to_commit": state="packet_commit"
		"packet_commit":
			if not _packet_owner_is_current(publisher): state="failed"; reason="chunk_packet_owner_replaced_before_commit"; return
			if not publisher.validate_static_flush_source(): state="failed"; reason="stale_static_flush_source"; return
			if not _publication_boundary.is_empty() and not publisher._publication_boundary_is_current(_publication_boundary):
				state="failed"; reason="publication_boundary_owner_changed"; return
			var committed: Dictionary=_packet_backend.call("commit_packet",_packet_source_id,_packet_generation)
			if committed.get("status")=="backpressure":
				var capacity_reason:=String(committed.get("reason",""))
				if capacity_reason=="installed_packet_capacity":
					# Installed-packet capacity cannot clear through retrying this same
					# staged generation. Abort it and surface a terminal publication
					# failure; transient upload/registration backpressure remains retryable.
					var aborted: Dictionary=_packet_backend.call("abort_packet",_packet_source_id,_packet_generation)
					state="failed"
					reason="chunk_packet_installed_capacity" if aborted.get("status")=="aborted" \
						else "chunk_packet_installed_capacity_abort_unacknowledged"
					return
				return
			if committed.get("status")!="ready" or not _packet_backend.call("receipt_installed",_packet_source_id,
					_packet_generation,_packet_source_revision,_packet_digest):
				state="failed"; reason=String(committed.get("reason","chunk_packet_receipt_rejected")); return
			var group: Dictionary=_groups[_keys[_group_index]]
			publisher.record_chunk_static_packet_receipt(String(group.sourcePartId),_packet_source_id,_packet_owner_cell,
				_packet_generation,_packet_source_revision,_packet_digest,_packet_backend,_packet_chunk)
			if not _replay_only:
				publisher.retain_chunk_static_packet_recipe(_packet_source_id,group,_packet_segments,publisher.unit_box)
			_packet_backend=null
			_packet_chunk=null
			_packet_segments=[]
			_group_index+=1
			state="group"
		"metadata_begin":
			# Each prefix dictionary is independent. Its nested record values are
			# immutable, allowing exact unchanged records to be shared safely.
			_metadata = _records.duplicate(false)
			_record_keys = _records.keys()
			state = "metadata"
		"metadata":
			if _record_index >= _record_keys.size():
				state="commit"
				return
			_record_key=_record_keys[_record_index]
			if not _records.has(_record_key) or not _records[_record_key] is Dictionary:
				state="failed"; reason="metadata_collection_changed_during_copy"; return
			_record_source=_records[_record_key]
			var prepared: Dictionary = publisher._prepared_static_records.get(_record_key,{})
			if not prepared.is_empty() and is_same(_record_source,prepared):
				_metadata[_record_key]=prepared
				_cache[_record_key]={"source":publisher._prepared_static_bindings[_record_key],"value":prepared,"reusable":true}
				_prepared_hits+=1
				_record_index+=1
				return
			_all_records_prepared=false
			if not _encoding_graph_safe(_record_source):
				state="failed"; reason="unsupported_metadata_graph"; return
			_record_binding=Preparation.static_record_binding(_record_source)
			if _record_binding.is_empty():
				state="failed"; reason="metadata_encoding_failed"; return
			var cached: Dictionary = publisher._static_record_cache.get(_record_key,{})
			# Exact bytes bind order, types and all nested values, not a lossy hash
			# or mutable object identity. Cache updates remain private until commit.
			if not cached.is_empty() and cached.get("reusable",false) and cached.source==_record_binding:
				_metadata[_record_key]=cached.value
				_cache[_record_key]=cached
				_cache_hits+=1
				_record_index+=1
				return
			_record_copy=_record_source.duplicate(false)
			_record_reusable=_shareable_container(_record_source)
			_record_containers=[_record_copy]
			_freeze_index=0
			_metadata[_record_key]=_record_copy
			_copy_stack.append({"source":_record_source,"target":_record_copy,"keys":_record_source.keys(),"index":0})
			state="metadata_copy"
		"metadata_copy":
			if _copy_stack.is_empty():
				state="metadata_freeze" if _record_reusable else "metadata_finish"
				return
			var frame: Dictionary = _copy_stack[-1]
			var source: Variant = frame.source
			if source is Dictionary and source.keys()!=frame.keys:
				state="failed"; reason="metadata_source_changed_during_copy"; return
			if frame.index >= source.size():
				_copy_stack.pop_back()
				return
			var key: Variant = frame.keys[frame.index] if source is Dictionary else frame.index
			if source is Dictionary and not source.has(key):
				state="failed"; reason="metadata_source_changed_during_copy"; return
			if not _immutable_leaf(key): _record_reusable=false
			frame.index+=1
			var value: Variant = source[key]
			if value is Dictionary or value is Array:
				if _copy_stack.size()>=128:
					state="failed"; reason="unsupported_metadata_graph"; return
				for ancestor in _copy_stack:
					if is_same(ancestor.source,value):
						state="failed"; reason="unsupported_metadata_graph"; return
				var copy: Variant = value.duplicate(false)
				if not _shareable_container(value): _record_reusable=false
				frame.target[key]=copy
				_record_containers.append(copy)
				_copy_stack.append({"source":value,"target":copy,"keys":value.keys() if value is Dictionary else [],"index":0})
			elif not _immutable_leaf(value):
				# Packed arrays, Resources, RIDs, callables and signals are not made
				# immutable by freezing a containing Array/Dictionary. Preserve the
				# old copy semantics but never reuse such a record across prefixes.
				_record_reusable=false
		"metadata_freeze":
			if _freeze_index<_record_containers.size():
				_record_containers[_freeze_index].make_read_only()
				_freeze_index+=1
			else:
				state="metadata_finish"
		"metadata_finish":
			if not _encoding_graph_safe(_records.get(_record_key)) or not _encoding_graph_safe(_record_source):
				state="failed"; reason="unsupported_metadata_graph"; return
			if not _records.has(_record_key) or Preparation.static_record_binding(_records[_record_key])!=_record_binding or Preparation.static_record_binding(_record_source)!=_record_binding or Preparation.static_record_binding(_record_copy)!=_record_binding:
				state="failed"; reason="metadata_source_changed_during_copy"; return
			_cache[_record_key]={"source":_record_binding,"value":_record_copy,"reusable":_record_reusable}
			_copies+=1
			if not _record_reusable: _unsupported_copies+=1
			_copied_encoded_bytes+=_record_binding.length() >> 1
			_record_index+=1
			state="metadata"
		"commit":
			if _records.keys()!=_record_keys:
				state="failed"; reason="metadata_collection_changed_during_copy"; return
			if _all_records_prepared:
				# The compiler owns these deeply frozen values. Validate every
				# selected reference and ordered membership, not dictionary equality.
				for key in _record_keys:
					if not is_same(_records[key],publisher._prepared_static_records.get(key)) or not is_same(_metadata[key],_records[key]):
						state="failed"; reason="metadata_source_changed_during_copy"; return
			elif not _encoding_graph_safe(_records):
				state="failed"; reason="unsupported_metadata_graph"; return
			elif Preparation.static_record_binding(_records)!=Preparation.static_record_binding(_metadata):
				# Mutable compatibility inputs require exact final content proof,
				# including earlier selections. This cost stays visible in metrics.
				state="failed"; reason="metadata_source_changed_during_copy"; return
			# No yield or callbacks between this proof and metadata replacement.
			# Rejection leaves the previously published snapshot untouched.
			if not publisher.validate_static_flush_source():
				state="failed"; reason="stale_static_flush_source"; return
			if not _publication_boundary.is_empty() and not publisher._publication_boundary_is_current(_publication_boundary):
				state="failed"; reason="publication_boundary_owner_changed"; return
			if not _records.is_empty() and (not is_instance_valid(publisher.static_collision_body) \
					or publisher.static_collision_body.is_queued_for_deletion() or publisher.static_collision_body.get_parent()!=parent):
				state="failed"; reason="static_collision_owner_lost"; return
			if is_instance_valid(publisher.static_collision_body):
				if publisher.static_collision_body.has_meta("building_part_records"):
					publisher._publication_retirement.append(publisher.static_collision_body.get_meta("building_part_records"))
				publisher.static_collision_body.set_meta("building_part_records", _metadata)
			publisher._publication_retirement.append(_groups)
			publisher._static_record_cache=_cache
			publisher._static_record_cache_stats.copies+=_copies
			publisher._static_record_cache_stats.hits+=_cache_hits
			publisher._static_record_cache_stats.preparedHits+=_prepared_hits
			publisher._static_record_cache_stats.copiedEncodedBytes+=_copied_encoded_bytes
			publisher._static_record_cache_stats.unsupportedCopies+=_unsupported_copies
			publisher.static_visual_batches = {}
			publisher.static_visual_transform_count = 0
			publisher.incremental_static_flush_count += 1
			if not _publication_boundary.is_empty() and not publisher._commit_publication_boundary(_publication_boundary):
				state="failed"; reason="publication_boundary_owner_changed"; return
			state = "packet_retire_begin" if not _publication_boundary.is_empty() else "ready"
		"packet_retire_begin":
			_packet_retire_parts=publisher.chunk_static_packet_part_ids()
			_packet_retire_part_index=0
			_packet_retire_sources=[]
			_packet_retire_source_index=0
			state="packet_retire"
		"packet_retire":
			if _packet_retire_part_index>=_packet_retire_parts.size():
				state="ready"
				return
			var part_id: String=_packet_retire_parts[_packet_retire_part_index]
			if _packet_retire_sources.is_empty():
				_packet_retire_sources=publisher.chunk_static_packet_source_ids(part_id)
				_packet_retire_source_index=0
				if _packet_retire_sources.is_empty():
					_packet_retire_part_index+=1
				return
			if _packet_retire_source_index>=_packet_retire_sources.size():
				_packet_retire_part_index+=1
				_packet_retire_sources=[]
				_packet_retire_source_index=0
				return
			if not publisher.retire_chunk_static_packet_if_unexpected(part_id,_packet_retire_sources[_packet_retire_source_index]):
				state="failed"; reason="chunk_packet_retirement_not_acknowledged"; return
			_packet_retire_source_index+=1

static func _immutable_leaf(value: Variant) -> bool:
	# Godot's value-only Variant types through NodePath; later enum members
	# include handles, Objects and mutable/copy-on-write collection wrappers.
	return typeof(value)<=TYPE_NODE_PATH

static func _shareable_container(value: Variant) -> bool:
	# Empty typed Object containers still promise future mutable handles; match
	# compiler eligibility rather than freezing them because they have no leaves.
	if value is Dictionary:
		return value.get_typed_key_builtin()<=TYPE_NODE_PATH and _shareable_value_type(value.get_typed_value_builtin())
	return _shareable_value_type(value.get_typed_builtin())

static func _shareable_value_type(kind: int) -> bool:
	return kind<=TYPE_NODE_PATH or kind==TYPE_ARRAY or kind==TYPE_DICTIONARY

static func _encoding_graph_safe(value: Variant, ancestors: Array = []) -> bool:
	# Only the mutable compatibility path needs this guard. Prepared graphs were
	# checked/frozen on the worker. Packed arrays and handles keep legacy semantics.
	if not value is Dictionary and not value is Array: return true
	if ancestors.size()>=128: return false
	for ancestor in ancestors:
		if is_same(ancestor,value): return false
	ancestors.append(value)
	if value is Dictionary:
		for key in value:
			if not _encoding_graph_safe(key,ancestors) or not _encoding_graph_safe(value[key],ancestors):
				ancestors.pop_back(); return false
	else:
		for item in value:
			if not _encoding_graph_safe(item,ancestors):
				ancestors.pop_back(); return false
	ancestors.pop_back()
	return true
