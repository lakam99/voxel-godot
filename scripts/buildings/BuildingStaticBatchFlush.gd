extends RefCounted
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const InstanceBuffer = preload("res://scripts/buildings/BuildingInstanceBuffer.gd")
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

func begin(groups: Dictionary, records: Dictionary, parent: Node3D, publication_boundary: Dictionary = {}) -> void:
	if state != "idle": return
	if not is_instance_valid(parent):
		state = "failed"; reason = "static_flush_parent_lost"; return
	_groups = groups
	_records = records
	_publication_boundary = publication_boundary
	_parent = weakref(parent)
	state = "keys"

func advance(publisher, budget_usec: int = 2500) -> Dictionary:
	if budget_usec < 1 or budget_usec > 4000:
		return {"status":"failed","reason":"invalid_slice_budget"}
	var started := Time.get_ticks_usec()
	var count := 0
	while state not in ["ready", "failed", "idle"] and (count == 0 or Time.get_ticks_usec()-started < budget_usec):
		var atomic_started := Time.get_ticks_usec()
		var stage := state
		_step(publisher)
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
				state = "metadata_begin"
				return
			var group: Dictionary = _groups[_keys[_group_index]]
			_transforms = group.transforms
			_custom = group.customData
			_segments = group.get("preparedSegments",{})
			_buffer = PackedFloat32Array()
			_material = group.material
			if _transforms.is_empty():
				_group_index += 1
				return
			_mesh = publisher.create_mesh_batch()
			_mesh.transform_format = MultiMesh.TRANSFORM_3D
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
			state = "ready"

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
