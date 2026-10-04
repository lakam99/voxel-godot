extends RefCounted
## Canonical per-instance packet ABI shared by section producers, partitioning,
## immutable snapshots and the native MultiMesh installer.
## Float lanes are Transform3D (12), instance color (4), custom data (4).

const LAYOUT_SCHEMA := "static-instance-transform-color-custom/v2"
const FLOATS_PER_INSTANCE := 20
const TRANSFORM_FLOATS := 12
const COLOR_OFFSET := 12
const CUSTOM_DATA_OFFSET := 16


static func encode(transform: Transform3D, custom_data: Color,
		instance_color: Color = Color.WHITE) -> PackedFloat32Array:
	return PackedFloat32Array([
		transform.basis.x.x, transform.basis.y.x, transform.basis.z.x, transform.origin.x,
		transform.basis.x.y, transform.basis.y.y, transform.basis.z.y, transform.origin.y,
		transform.basis.x.z, transform.basis.y.z, transform.basis.z.z, transform.origin.z,
		instance_color.r, instance_color.g, instance_color.b, instance_color.a,
		custom_data.r, custom_data.g, custom_data.b, custom_data.a
	])


static func decode_transform(buffer: Array, offset: int) -> Transform3D:
	var basis := Basis(
		Vector3(float(buffer[offset]), float(buffer[offset + 4]), float(buffer[offset + 8])),
		Vector3(float(buffer[offset + 1]), float(buffer[offset + 5]), float(buffer[offset + 9])),
		Vector3(float(buffer[offset + 2]), float(buffer[offset + 6]), float(buffer[offset + 10])))
	return Transform3D(basis, Vector3(float(buffer[offset + 3]),
		float(buffer[offset + 7]), float(buffer[offset + 11])))


static func encode_transform(transform: Transform3D, source_buffer: Array,
		source_offset: int, instance_color: Color) -> Array[float]:
	return [
		transform.basis.x.x, transform.basis.y.x, transform.basis.z.x, transform.origin.x,
		transform.basis.x.y, transform.basis.y.y, transform.basis.z.y, transform.origin.y,
		transform.basis.x.z, transform.basis.y.z, transform.basis.z.z, transform.origin.z,
		instance_color.r, instance_color.g, instance_color.b, instance_color.a,
		float(source_buffer[source_offset + CUSTOM_DATA_OFFSET]),
		float(source_buffer[source_offset + CUSTOM_DATA_OFFSET + 1]),
		float(source_buffer[source_offset + CUSTOM_DATA_OFFSET + 2]),
		float(source_buffer[source_offset + CUSTOM_DATA_OFFSET + 3])
	]


static func is_finite_color(value: Color) -> bool:
	return is_finite(value.r) and is_finite(value.g) \
		and is_finite(value.b) and is_finite(value.a)
