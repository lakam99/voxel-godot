extends RefCounted
## Shared transform + independent color + custom-data layout for worker packets
## and bounded conversion of remaining part families. No render resources here.
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const LAYOUT_SCHEMA := Attributes.LAYOUT_SCHEMA
const FLOATS_PER_INSTANCE := Attributes.FLOATS_PER_INSTANCE
const SEGMENT_INSTANCES := 256

static func encode(transform: Transform3D, custom: Color,
		instance_color: Color = Color.WHITE) -> PackedFloat32Array:
	return Attributes.encode(transform, custom, instance_color)

static func compile(transforms: Array, custom: Array, frame: Transform3D,
		continuation: Callable, stage := "publication_masonry_packet",
		instance_colors: Array = []) -> Array:
	if custom.size() != transforms.size() \
			or (not instance_colors.is_empty() and instance_colors.size() != transforms.size()):
		return []
	var segments: Array = []
	var cursor := 0
	while cursor < transforms.size():
		if continuation.is_valid() and continuation.call(stage) != true: return []
		var final_transforms: Array[Transform3D] = []
		var final_custom: Array[Color] = []
		var final_colors: Array[Color] = []
		# Packed arrays cannot be frozen in Godot. Seal float32-rounded values in
		# a typed readonly Array; main converts at most 256 instances per unit.
		var buffer: Array[float] = []
		var final_bounds := AABB()
		var end := mini(cursor + SEGMENT_INSTANCES, transforms.size())
		while cursor < end:
			# Keep the original multiplication and float32 rounding order.
			var transform: Transform3D = frame * (transforms[cursor] as Transform3D)
			var data: Color = custom[cursor]
			var instance_color: Color = instance_colors[cursor] if not instance_colors.is_empty() else Color.WHITE
			if not Attributes.is_finite_color(data) or not Attributes.is_finite_color(instance_color):
				return []
			var bounds: AABB = transform * AABB(Vector3(-0.5,-0.5,-0.5),Vector3.ONE)
			final_bounds = bounds if final_transforms.is_empty() else final_bounds.merge(bounds)
			final_transforms.append(transform)
			final_custom.append(data)
			final_colors.append(instance_color)
			buffer.append_array(Array(encode(transform,data,instance_color)))
			cursor += 1
		final_transforms.make_read_only()
		final_custom.make_read_only()
		final_colors.make_read_only()
		buffer.make_read_only()
		var segment := {"instanceAttributeLayout":LAYOUT_SCHEMA,
			"transforms":final_transforms,"instanceColors":final_colors,
			"customData":final_custom,"buffer":buffer,
			"bounds":final_bounds,"instanceCount":final_transforms.size()}
		segment.make_read_only()
		segments.append(segment)
	segments.make_read_only()
	return segments
