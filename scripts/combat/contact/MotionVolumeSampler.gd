extends RefCounted
class_name MotionVolumeSampler

const MotionVolumeSampleScript := preload("res://scripts/combat/contact/MotionVolumeSample.gd")
const MotionVolumeSweepSampleScript := preload("res://scripts/combat/contact/MotionVolumeSweepSample.gd")

## Pure bridge from approved motion output to generic local contact geometry.
## It deliberately does not know whether a volume ever touches anything.

static func sample(volume_recipe, motion_sample) -> MotionVolumeSample:
	if volume_recipe == null or motion_sample == null:
		return MotionVolumeSampleScript.new()
	var phase := String(motion_sample.phase).strip_edges().to_lower()
	var active: bool = bool(motion_sample.active) and volume_recipe.allows_phase(phase)
	if not active:
		return MotionVolumeSampleScript.new({
			"instanceId": motion_sample.instance_id,
			"anchorId": motion_sample.anchor_id,
			"normalizedTime": motion_sample.normalized_time,
			"localTime": motion_sample.local_time,
			"phase": phase,
			"shapeId": volume_recipe.shape_id,
			"facing": motion_sample.facing
		})
	return sample_geometry(volume_recipe, motion_sample)


## Geometry-only sampling is useful for visual inspection outside a contact
## window. Its `active` flag remains false until the recipe's declared phase,
## so rendering a wind-up capsule cannot be mistaken for contact resolution.
static func sample_geometry(volume_recipe, motion_sample) -> MotionVolumeSample:
	if volume_recipe == null or motion_sample == null:
		return MotionVolumeSampleScript.new()
	var phase := String(motion_sample.phase).strip_edges().to_lower()
	var active: bool = bool(motion_sample.active) and volume_recipe.allows_phase(phase)
	if not bool(motion_sample.active):
		return MotionVolumeSampleScript.new({
			"instanceId": motion_sample.instance_id,
			"anchorId": motion_sample.anchor_id,
			"normalizedTime": motion_sample.normalized_time,
			"localTime": motion_sample.local_time,
			"phase": phase,
			"shapeId": volume_recipe.shape_id,
			"facing": motion_sample.facing
		})
	var span_start := float(volume_recipe.value("spanStart", 0.40))
	var span_end := float(volume_recipe.value("spanEnd", 1.0))
	var segment_start: Vector3 = motion_sample.origin.lerp(motion_sample.tip, span_start)
	var segment_end: Vector3 = motion_sample.origin.lerp(motion_sample.tip, span_end)
	return MotionVolumeSampleScript.new({
		"instanceId": motion_sample.instance_id,
		"anchorId": motion_sample.anchor_id,
		"normalizedTime": motion_sample.normalized_time,
		"localTime": motion_sample.local_time,
		"phase": phase,
		"shapeId": volume_recipe.shape_id,
		"active": active,
		"segmentStart": segment_start,
		"segmentEnd": segment_end,
		"radius": float(volume_recipe.value("radius", 0.24)),
		"facing": motion_sample.facing
	})


static func samples_for_stack(stack, volume_recipe, global_time: float) -> Array:
	var results: Array = []
	if stack == null or not stack.has_method("samples_at"):
		return results
	for motion_sample in stack.samples_at(global_time):
		var volume_sample = sample(volume_recipe, motion_sample)
		if volume_sample.active:
			results.append(volume_sample)
	return results


static func geometry_samples_for_stack(stack, volume_recipe, global_time: float) -> Array:
	var results: Array = []
	if stack == null or not stack.has_method("samples_at"):
		return results
	for motion_sample in stack.samples_at(global_time):
		var volume_sample = sample_geometry(volume_recipe, motion_sample)
		if volume_sample.shape_id != "" and volume_sample.radius > 0.0:
			results.append(volume_sample)
	return results


static func sweep(previous, current) -> MotionVolumeSweepSample:
	if current == null or not current.active:
		return MotionVolumeSweepSampleScript.new()
	var has_previous: bool = previous != null and previous.active and previous.instance_id == current.instance_id
	var from_sample = previous if has_previous else current
	return MotionVolumeSweepSampleScript.new({
		"instanceId": current.instance_id,
		"normalizedTime": current.normalized_time,
		"active": true,
		"fromSegmentStart": from_sample.segment_start,
		"fromSegmentEnd": from_sample.segment_end,
		"toSegmentStart": current.segment_start,
		"toSegmentEnd": current.segment_end,
		"radius": maxf(float(from_sample.radius), float(current.radius))
	})
