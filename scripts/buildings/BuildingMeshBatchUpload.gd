extends RefCounted
## Populates one unchanged mesh batch without attaching a partial MultiMesh.
## All Resource construction and scene attachment remain on the main thread.
var state := "allocate"
var reason := ""
var max_atomic_usec := 0
var _mesh: Mesh
var _transforms: Array
var _custom: Array
var _material: Material
var _name: String
var _frame: Transform3D
var _track: bool
var _render_tier: String
var _source_part_id: String
var _parent: WeakRef
var _result: WeakRef
var _multi: MultiMesh
var _cursor := 0

func _init(mesh: Mesh, transforms: Array, custom: Array, material: Material,
		node_name: String, parent: Node3D, frame: Transform3D, track: bool,
		render_tier := "structural", source_part_id := "") -> void:
	_mesh=mesh; _transforms=transforms; _custom=custom; _material=material
	_name=node_name; _frame=frame; _track=track; _render_tier=render_tier
	_source_part_id=source_part_id; _parent=weakref(parent)
	if transforms.is_empty(): state="ready"
	elif mesh==null or custom.size()!=transforms.size():
		state="failed"; reason="invalid_mesh_batch"

func advance(publisher, budget_usec: int = 2500) -> Dictionary:
	if budget_usec<1 or budget_usec>4000: return {"status":"failed","reason":"invalid_slice_budget"}
	var started:=Time.get_ticks_usec()
	var units:=0
	while state not in ["ready","failed"] and (units==0 or Time.get_ticks_usec()-started<budget_usec):
		var atomic_started:=Time.get_ticks_usec()
		var stage:=state
		_step(publisher)
		var elapsed:=Time.get_ticks_usec()-atomic_started
		max_atomic_usec=maxi(max_atomic_usec,elapsed)
		publisher._record_publication_stage("mesh_upload_"+stage,elapsed)
		units+=1
	return {"status":state if state in ["ready","failed"] else "pending_budget","reason":reason,"maxAtomicUsec":max_atomic_usec}

func result() -> MultiMeshInstance3D:
	return _result.get_ref() as MultiMeshInstance3D if _result!=null else null

func _step(publisher) -> void:
	var parent: Node3D = _parent.get_ref() as Node3D
	if not is_instance_valid(parent) or parent.is_queued_for_deletion():
		state="failed"; reason="mesh_batch_parent_lost"; return
	match state:
		"allocate":
			_multi=publisher.create_mesh_batch()
			_multi.transform_format=MultiMesh.TRANSFORM_3D
			_multi.use_colors=true
			_multi.use_custom_data=true
			_multi.instance_count=_transforms.size()
			_multi.mesh=_mesh
			state="instances"
		"instances":
			var transform: Transform3D = _transforms[_cursor]
			if _track: transform=_frame*transform
			publisher.submit_mesh_batch_instance(_multi,_cursor,transform,_custom[_cursor])
			_cursor+=1
			if _cursor==_transforms.size(): state="attach"
		"attach":
			var instance:=MultiMeshInstance3D.new()
			instance.name=_name
			instance.multimesh=_multi
			instance.material_override=_material
			if _track: publisher.apply_static_visual_render_policy(instance,_render_tier)
			else: instance.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			parent.add_child(instance)
			if _track: publisher.register_published_visual(instance, _source_part_id)
			publisher.visual_batch_count+=1
			_result=weakref(instance)
			state="ready"
