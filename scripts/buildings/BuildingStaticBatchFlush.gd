extends RefCounted
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
var _group_index := 0
var _instance_index := 0
var _mesh: MultiMesh
var _transforms: Array = []
var _custom: Array = []
var _material: Material
var _parent: WeakRef

func begin(groups: Dictionary, records: Dictionary, parent: Node3D) -> void:
	if state != "idle": return
	if not is_instance_valid(parent):
		state = "failed"; reason = "static_flush_parent_lost"; return
	_groups = groups
	_records = records
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
		publisher._record_publication_stage("static_flush_"+stage,elapsed)
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
			_material = group.material
			if _transforms.is_empty():
				_group_index += 1
				return
			_mesh = publisher.create_mesh_batch()
			_mesh.transform_format = MultiMesh.TRANSFORM_3D
			_mesh.use_custom_data = true
			_mesh.instance_count = _transforms.size()
			_mesh.mesh = publisher.unit_box
			_instance_index = 0
			state = "instances"
		"instances":
			publisher.submit_mesh_batch_instance(_mesh,_instance_index,_transforms[_instance_index],_custom[_instance_index])
			_instance_index += 1
			if _instance_index == _transforms.size(): state = "attach"
		"attach":
			var instance := MultiMeshInstance3D.new()
			instance.name = "ConstructionStaticVisualBatch"
			instance.multimesh = _mesh
			instance.material_override = _material
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			parent.add_child(instance)
			publisher.published_nodes.append(instance)
			publisher.visual_batch_count += 1
			_mesh = null
			_group_index += 1
			state = "group"
		"metadata_begin":
			# A single source part can contain a large nested recipe. Shallow-copy
			# each container, then replace child containers one at a time. This
			# preserves typed arrays/dictionaries without an atomic deep clone.
			_metadata = _records.duplicate(false)
			_copy_stack.append({"source":_records,"target":_metadata,"keys":_records.keys(),"index":0})
			state = "metadata"
		"metadata":
			if _copy_stack.is_empty():
				state="commit"
				return
			var frame: Dictionary = _copy_stack[-1]
			var source: Variant = frame.source
			if frame.index >= source.size():
				_copy_stack.pop_back()
				return
			var key: Variant = frame.keys[frame.index] if source is Dictionary else frame.index
			frame.index+=1
			var value: Variant = source[key]
			if value is Dictionary or value is Array:
				var copy: Variant = value.duplicate(false)
				frame.target[key]=copy
				_copy_stack.append({"source":value,"target":copy,"keys":value.keys() if value is Dictionary else [],"index":0})
		"commit":
			# No yield or callbacks between this proof and metadata replacement.
			# Rejection leaves the previously published snapshot untouched.
			if not publisher.validate_static_flush_source():
				state="failed"; reason="stale_static_flush_source"; return
			if is_instance_valid(publisher.static_collision_body):
				if publisher.static_collision_body.has_meta("building_part_records"):
					publisher._publication_retirement.append(publisher.static_collision_body.get_meta("building_part_records"))
				publisher.static_collision_body.set_meta("building_part_records", _metadata)
			publisher._publication_retirement.append(_groups)
			publisher.static_visual_batches = {}
			publisher.static_visual_transform_count = 0
			publisher.incremental_static_flush_count += 1
			state = "ready"
