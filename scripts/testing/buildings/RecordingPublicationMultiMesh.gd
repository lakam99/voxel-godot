extends MultiMesh
## Explicit test spy: records script submissions, NOT GPU readback. Every
## adapter call still calls each native setter exactly once. Native methods are
## nonvirtual, so this deliberately does NOT pretend to override their dispatch.
var submissions: Array = []
var configuration: Array = []

func _capture_configuration() -> void:
	if configuration.is_empty():
		configuration=[transform_format,use_custom_data,use_colors,instance_count,
			mesh.get_class(),mesh.get_mesh_arrays() if mesh is PrimitiveMesh else []]

func record_submission(index: int, transform: Transform3D, data: Color) -> void:
	_capture_configuration()
	submissions.append(["transform",index,transform])
	submissions.append(["custom",index,data])
	set_instance_transform(index,transform)
	set_instance_custom_data(index,data)
