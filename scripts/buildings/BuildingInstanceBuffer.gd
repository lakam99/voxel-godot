extends RefCounted
## Godot TRANSFORM_3D + custom-data layout, shared by worker packets and the
## bounded conversion of remaining part families. No rendering resources here.
const FLOATS_PER_INSTANCE := 16
const SEGMENT_INSTANCES := 256

static func encode(transform: Transform3D, custom: Color) -> PackedFloat32Array:
	return PackedFloat32Array([
		transform.basis.x.x, transform.basis.y.x, transform.basis.z.x, transform.origin.x,
		transform.basis.x.y, transform.basis.y.y, transform.basis.z.y, transform.origin.y,
		transform.basis.x.z, transform.basis.y.z, transform.basis.z.z, transform.origin.z,
		custom.r, custom.g, custom.b, custom.a])

static func compile(transforms: Array, custom: Array, frame: Transform3D, continuation: Callable, stage := "publication_masonry_packet") -> Array:
	var segments: Array = []
	var cursor := 0
	while cursor < transforms.size():
		if continuation.is_valid() and continuation.call(stage) != true: return []
		var final_transforms: Array[Transform3D] = []
		var final_custom: Array[Color] = []
		# Packed arrays cannot be frozen in Godot. Seal float32-rounded values in
		# a typed readonly Array; main converts at most 256 instances per unit.
		var buffer: Array[float] = []
		var final_bounds := AABB()
		var end := mini(cursor + SEGMENT_INSTANCES, transforms.size())
		while cursor < end:
			# Keep the original multiplication and float32 rounding order.
			var transform: Transform3D = frame * (transforms[cursor] as Transform3D)
			var data: Color = custom[cursor]
			var bounds: AABB = transform * AABB(Vector3(-0.5,-0.5,-0.5),Vector3.ONE)
			final_bounds = bounds if final_transforms.is_empty() else final_bounds.merge(bounds)
			final_transforms.append(transform)
			final_custom.append(data)
			buffer.append_array(Array(encode(transform,data)))
			cursor += 1
		final_transforms.make_read_only()
		final_custom.make_read_only()
		buffer.make_read_only()
		var segment := {"transforms":final_transforms,"customData":final_custom,"buffer":buffer,
			"bounds":final_bounds,"instanceCount":final_transforms.size()}
		segment.make_read_only()
		segments.append(segment)
	segments.make_read_only()
	return segments
