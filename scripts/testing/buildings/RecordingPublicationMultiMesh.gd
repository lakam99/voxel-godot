extends MultiMesh
## Explicit test spy: records script submissions, NOT GPU readback. Every
## adapter call still calls each native setter exactly once. Native methods are
## nonvirtual, so this deliberately does NOT pretend to override their dispatch.
var submissions: Array = []
var configuration: Array = []
var buffer_submissions := 0

func record_buffer(values: PackedFloat32Array) -> void:
	_capture_configuration()
	buffer_submissions += 1
	for index in instance_count:
		var offset := index * 20
		var transform := Transform3D(Basis(
			Vector3(values[offset],values[offset+4],values[offset+8]),
			Vector3(values[offset+1],values[offset+5],values[offset+9]),
			Vector3(values[offset+2],values[offset+6],values[offset+10])),
			Vector3(values[offset+3],values[offset+7],values[offset+11]))
		var data := Color(values[offset+12],values[offset+13],values[offset+14],values[offset+15])
		submissions.append(["transform",index,transform])
		submissions.append(["custom",index,data])
	# Actual new production boundary, not replaying individual setters.
	buffer = values

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
